// HIDEventSniffer v1.0.5 —— 蓝牙翻页器按键抓取（注入 Preferences 进程）
//
// 用户方案（比之前所有版本都干净）：
//   系统设置 → HIDEventSniffer → 极简设置页（只显示日志+刷新）
//   打开设置页（Preferences 前台），用蓝牙翻页器在设置页里按键，
//   按键事件由 backboardd 路由给前台 App（Preferences）→ 本插件在进程内捕获 →
//   写入日志 → 设置页定时刷新实时显示。
//
// v1.0.5 新增：设备溯源
//   - 从事件底层 HID 数据读 设备ID(senderID) + 设备唯一标识(uniqueID)
//   - 区分：屏幕(手指) / 蓝牙HID / 其它外部HID
//   - 设置页顶部列出当前已连接的蓝牙设备（名称+地址），对照识别翻页器
//
// 只注入 Preferences 一个进程，完全不碰 SpringBoard，安全模式风险归零。
// 只观察、只记录，绝不修改/吞掉事件。
//
// 日志双写：
//   1. Preferences 沙盒 Documents/HIDEventSniffer.log（设置页直接读这个）
//   2. /var/mobile/Documents/HIDEventSniffer.log（若权限允许，Filza 可读）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// IOKit 私有 HID 接口
typedef struct __IOHIDEvent *HIDEventRef;
static uint64_t (*pGetSenderID)(HIDEventRef);
static CFStringRef (*pGetSenderUniqueID)(HIDEventRef);

static NSString *SnifLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"HIDEventSniffer.log"];
}

static void SnifLog(NSString *s) {
    NSLog(@"HIDSniffer %@", s);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        // 主日志：Preferences 沙盒（一定可写）
        NSString *path = SnifLogPath();
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
        // 双写 /var/mobile/Documents（权限允许则写，失败忽略）
        @try {
            NSString *alt = @"/var/mobile/Documents/HIDEventSniffer.log";
            [fm createDirectoryAtPath:@"/var/mobile/Documents" withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm fileExistsAtPath:alt]) [fm createFileAtPath:alt contents:nil attributes:nil];
            NSFileHandle *h2 = [NSFileHandle fileHandleForWritingAtPath:alt];
            if (h2) { [h2 seekToEndOfFile]; [h2 writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h2 closeFile]; }
        } @catch (__unused NSException *e) {}
    } @catch (__unused NSException *e) {}
}

// 从 UIEvent 取底层 IOHIDEventRef（私有 ivar，KVC 安全取值）
static HIDEventRef SnifHIDEvent(UIEvent *event) {
    if (!event) return NULL;
    @try {
        id v = [event valueForKey:@"_hidEvent"];
        if (v) return (__bridge HIDEventRef)v;
    } @catch (__unused NSException *e) {}
    return NULL;
}

// 设备溯源：senderID + uniqueID 区分 屏幕/蓝牙/外部
static NSString *SnifDeviceDesc(UIEvent *event) {
    HIDEventRef hid = SnifHIDEvent(event);
    if (!hid || !pGetSenderID) return @"设备=未知";
    uint64_t sid = pGetSenderID(hid);
    NSString *uid = nil;
    if (pGetSenderUniqueID) {
        CFStringRef u = pGetSenderUniqueID(hid);
        if (u) uid = (__bridge NSString *)u;
    }
    if (sid == 0 && uid.length == 0) return @"设备=屏幕(手指)";
    if (uid.length) return [NSString stringWithFormat:@"设备=蓝牙HID id=0x%llx uid=%@", sid, uid];
    return [NSString stringWithFormat:@"设备=外部HID id=0x%llx", sid];
}

// 当前已连接的蓝牙设备（名称+地址），用于对照识别翻页器
static NSString *SnifConnectedBTDevices(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id bt = [NSClassFromString(@"BluetoothManager") performSelector:NSSelectorFromString(@"sharedInstance")];
        if (bt) {
            NSArray *devs = [bt performSelector:NSSelectorFromString(@"connectedDevices")];
            for (id d in devs) {
                NSString *name = [d performSelector:NSSelectorFromString(@"name")];
                NSString *addr = [d performSelector:NSSelectorFromString(@"address")];
                if (name.length) {
                    [out addObject:[NSString stringWithFormat:@"%@(%@)", name, addr.length ? addr : @"?"]];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return out.count ? [out componentsJoinedByString:@" "] : @"（未检测到已连接蓝牙设备）";
}

// 按键名映射（HID usage，UIKeyboardHIDUsage）
static NSString *KeyName(long long kc) {
    switch (kc) {
        case 0x52: return @"方向↑";
        case 0x51: return @"方向↓";
        case 0x50: return @"方向←";
        case 0x4F: return @"方向→";
        case 0x28: return @"回车";
        case 0x29: return @"ESC";
        case 0xE9: return @"音量+";
        case 0xEA: return @"音量-";
        case 0xE2: return @"静音";
        case 0xCD: return @"播放/暂停";
        case 0xB5: return @"下一曲";
        case 0xB6: return @"上一曲";
        case 0x2C: return @"空格";
        default: return nil;
    }
}

// 相位中文化
static NSString *TouchPhaseName(NSInteger ph) {
    switch (ph) {
        case UITouchPhaseBegan:     return @"按下";
        case UITouchPhaseMoved:     return @"移动";
        case UITouchPhaseStationary:return @"静止";
        case UITouchPhaseEnded:     return @"弹起";
        case UITouchPhaseCancelled: return @"取消";
        default: return [NSString stringWithFormat:@"相位%ld", (long)ph];
    }
}
static NSString *PressPhaseName(NSInteger ph) {
    switch (ph) {
        case 0: return @"按下";
        case 1: return @"变化";
        case 2: return @"静止";
        case 3: return @"弹起";
        case 4: return @"取消";
        default: return [NSString stringWithFormat:@"相位%ld", (long)ph];
    }
}

// 触摸生命周期跟踪（单指/翻页器场景；多指时以第一个触摸为准做判定）
static NSTimeInterval gTouchBeganTime = 0;
static CGPoint gTouchBeganPoint = {0, 0};
static BOOL gTouchMoved = NO;
static NSTimeInterval gLastMoveLog = 0; // 移动限流 100ms

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event) {
            NSMutableString *d = [NSMutableString string];
            NSString *dev = SnifDeviceDesc(event); // 设备溯源：屏幕/蓝牙HID id/uid
            if (event.type == UIEventTypePresses) {
                // 蓝牙键盘按键（方向键/回车等）。UIEvent.presses 是私有属性，用 KVC 安全取值
                NSSet *presses = [event valueForKey:@"presses"];
                if ([presses isKindOfClass:[NSSet class]]) {
                    for (UIPress *p in presses) {
                        UIKey *k = p.key;
                        if (!k) continue;
                        long long kc = (long long)k.keyCode;
                        NSString *name = KeyName(kc) ?: @"未知键";
                        [d appendFormat:@"PRESS key=0x%llx(%@) %@ ", kc, name, PressPhaseName(p.phase)];
                    }
                }
            } else if (event.type == UIEventTypeTouches) {
                // 触摸 / 鼠标点击：分辨 按下/移动/弹起/取消 + 判定 单击/连点/长按/拖动
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                NSInteger idx = 0;
                for (UITouch *t in event.allTouches) {
                    CGPoint pt = [t locationInView:nil];
                    if (t.phase == UITouchPhaseBegan) {
                        gTouchBeganTime = now;
                        gTouchBeganPoint = pt;
                        gTouchMoved = NO;
                        [d appendFormat:@"TOUCH#%ld 按下 x=%.0f y=%.0f tap=%ld ", (long)idx, pt.x, pt.y, (long)t.tapCount];
                    } else if (t.phase == UITouchPhaseMoved) {
                        if (now - gLastMoveLog > 0.1) {
                            CGFloat dx = pt.x - gTouchBeganPoint.x, dy = pt.y - gTouchBeganPoint.y;
                            if (dx * dx + dy * dy > 4) gTouchMoved = YES;
                            [d appendFormat:@"TOUCH#%ld 移动 x=%.0f y=%.0f (自起点 dx=%.0f dy=%.0f) ", (long)idx, pt.x, pt.y, dx, dy];
                            gLastMoveLog = now;
                        }
                    } else if (t.phase == UITouchPhaseEnded) {
                        CGFloat dx = pt.x - gTouchBeganPoint.x, dy = pt.y - gTouchBeganPoint.y;
                        CGFloat dist = sqrt(dx * dx + dy * dy);
                        CGFloat dur = now - gTouchBeganTime;
                        NSString *verdict;
                        if (t.tapCount >= 2) {
                            verdict = [NSString stringWithFormat:@"连点%ld次", (long)t.tapCount];
                        } else if (dist >= 12) {
                            verdict = [NSString stringWithFormat:@"拖动/滑动(位移%.0fpt 时长%.2fs)", dist, dur];
                        } else if (dur >= 0.6) {
                            verdict = [NSString stringWithFormat:@"长按(%.2fs)", dur];
                        } else {
                            verdict = [NSString stringWithFormat:@"单击(位移%.0fpt 时长%.2fs)", dist, dur];
                        }
                        [d appendFormat:@"TOUCH#%ld 弹起 x=%.0f y=%.0f → %@ ", (long)idx, pt.x, pt.y, verdict];
                    } else if (t.phase == UITouchPhaseCancelled) {
                        [d appendFormat:@"TOUCH#%ld 取消 x=%.0f y=%.0f ", (long)idx, pt.x, pt.y];
                    }
                    idx++;
                }
            } else if (event.type == UIEventTypeScroll) {
                [d appendString:@"SCROLL 滚轮/滚动事件 "];
            }
            if (d.length) {
                SnifLog([NSString stringWithFormat:@"%@ type=%ld %@", dev, (long)event.type, d]);
            }
        }
    } @catch (__unused NSException *e) {}
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // 解析 IOKit 设备溯源函数
        @try {
            void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
            if (iokit) {
                pGetSenderID = (__typeof__(pGetSenderID))dlsym(iokit, "IOHIDEventGetSenderID");
                pGetSenderUniqueID = (__typeof__(pGetSenderUniqueID))dlsym(iokit, "IOHIDEventGetSenderUniqueID");
            }
        } @catch (__unused NSException *e) {}

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        SnifLog(@"==================================================");
        SnifLog([NSString stringWithFormat:@"HIDEventSniffer v1.0.5 已注入 Preferences（bundle=%@）", bundleID]);
        SnifLog([NSString stringWithFormat:@"SenderID解析=%d UniqueID解析=%d", pGetSenderID != NULL, pGetSenderUniqueID != NULL]);
        SnifLog([NSString stringWithFormat:@"已连接蓝牙设备: %@", SnifConnectedBTDevices()]);
        SnifLog(@"请打开本设置页，用翻页器按键：音量+/-、四方向、点击，各按2~3下");
        SnifLog([NSString stringWithFormat:@"日志路径: %@", SnifLogPath()]);
        SnifLog(@"==================================================");
    }
}
