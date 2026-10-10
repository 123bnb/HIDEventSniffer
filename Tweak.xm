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
#import <objc/runtime.h>
#import <dlfcn.h>

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

// IOKit 私有 HID 接口（dlsym 动态解析，避免链接问题）
typedef struct __IOHIDEvent *HIDEventRef;
static uint64_t (*pGetSenderID)(HIDEventRef);
static CFStringRef (*pGetSenderUniqueID)(HIDEventRef);
static uint32_t (*pGetEventType)(HIDEventRef);
static CFTypeID (*pGetTypeID)(void);
static int64_t (*pGetIntegerValue)(HIDEventRef, uint32_t); // IOHIDEventGetIntegerValue，读 vid/pid

// IOHIDEvent 字段（IOKit hid 私有枚举）：vendorID=0x5 productID=0x6
#define KHIDFieldVendorID 0x00000005
#define KHIDFieldProductID 0x00000006

// 缓存 HID ivar（UIEvent/UITouch），首次扫描后复用，避免每次事件都扫
static Ivar gHIDIvarUIEvent = NULL;
static Ivar gHIDIvarUITouch = NULL;

static Ivar FindHIDIvar(Class cls, Ivar *cache) {
    if (*cache) return *cache;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    Ivar found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = ivar_getName(ivars[i]);
        if (!nm) continue;
        NSString *n = [NSString stringWithUTF8String:nm];
        if ([n rangeOfString:@"hid" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            found = ivars[i];
            break;
        }
    }
    free(ivars);
    *cache = found;
    return found;
}

// 从 obj 的 ivar 偏移直接读 HIDEventRef 指针，并用 CFTypeID 验证合法性
static HIDEventRef HIDFromIvar(id obj, Ivar ivar) {
    if (!obj || !ivar || !pGetTypeID) return NULL;
    @try {
        char *base = (char *)(__bridge void *)obj;
        void *addr = base + ivar_getOffset(ivar);
        HIDEventRef h = *(HIDEventRef *)addr;
        if (h && CFGetTypeID(h) == pGetTypeID()) return h;
    } @catch (__unused NSException *e) {}
    return NULL;
}

// 从 UIEvent 取底层 IOHIDEventRef：多路探测
//   路1: KVC _hidEvent / hidEvent（常见 tweak 写法）
//   路2: ivar 偏移直读（不依赖 KVC）
//   路3: 触摸事件时从 UITouch 取（_hidEvent 可能在 touch 上）
static HIDEventRef SnifHIDEvent(UIEvent *event) {
    if (!event) return NULL;
    // 路1
    @try {
        id v = [event valueForKey:@"_hidEvent"];
        if (v && pGetTypeID && CFGetTypeID((__bridge CFTypeRef)v) == pGetTypeID()) return (__bridge HIDEventRef)v;
    } @catch (__unused NSException *e) {}
    @try {
        id v = [event valueForKey:@"hidEvent"];
        if (v && pGetTypeID && CFGetTypeID((__bridge CFTypeRef)v) == pGetTypeID()) return (__bridge HIDEventRef)v;
    } @catch (__unused NSException *e) {}
    // 路2
    HIDEventRef h = HIDFromIvar(event, FindHIDIvar([UIEvent class], &gHIDIvarUIEvent));
    if (h) return h;
    // 路3
    if (event.type == UIEventTypeTouches) {
        UITouch *t = [event.allTouches anyObject];
        if (t) {
            @try {
                id v = [t valueForKey:@"_hidEvent"];
                if (v && pGetTypeID && CFGetTypeID((__bridge CFTypeRef)v) == pGetTypeID()) return (__bridge HIDEventRef)v;
            } @catch (__unused NSException *e) {}
            h = HIDFromIvar(t, FindHIDIvar([UITouch class], &gHIDIvarUITouch));
            if (h) return h;
        }
    }
    return NULL;
}

// 设备溯源：senderID + uniqueID + HID事件类型 + vendorID/productID。
// vid/pid 是设备固件写死的，重启/重连不变 —— 这是认住翻页器的稳定特征
static NSString *SnifDeviceDesc(UIEvent *event) {
    HIDEventRef hid = SnifHIDEvent(event);
    if (!hid) return @"设备=未知(HIDRef=NULL)";
    if (!pGetSenderID) return @"设备=未知(IOHIDEventGetSenderID解析失败)";
    uint64_t sid = pGetSenderID(hid);
    NSString *uid = nil;
    if (pGetSenderUniqueID) {
        CFStringRef u = pGetSenderUniqueID(hid);
        if (u) uid = (__bridge NSString *)u;
    }
    NSString *typeStr = @"?";
    if (pGetEventType) typeStr = [NSString stringWithFormat:@"%u", (unsigned)pGetEventType(hid)];
    NSString *vpStr = @"vid=? pid=?";
    if (pGetIntegerValue) {
        int64_t vid = pGetIntegerValue(hid, KHIDFieldVendorID);
        int64_t pid = pGetIntegerValue(hid, KHIDFieldProductID);
        vpStr = [NSString stringWithFormat:@"vid=0x%llx pid=0x%llx", vid, pid];
    }
    if (sid == 0 && uid.length == 0)
        return [NSString stringWithFormat:@"设备=屏幕(手指) id=0x%llx %@ hidType=%@", sid, vpStr, typeStr];
    if (uid.length)
        return [NSString stringWithFormat:@"设备=蓝牙HID id=0x%llx uid=%@ %@ hidType=%@", sid, uid, vpStr, typeStr];
    return [NSString stringWithFormat:@"设备=外部HID id=0x%llx uid=(null) %@ hidType=%@", sid, vpStr, typeStr];
}

// 诊断：打印 UIEvent/UITouch 里所有含 hid/event 的 ivar 名+类型
static NSString *DumpHIDIvars(Class cls) {
    NSMutableArray *arr = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = ivar_getName(ivars[i]);
        const char *ty = ivar_getTypeEncoding(ivars[i]);
        if (!nm) continue;
        NSString *n = [NSString stringWithUTF8String:nm];
        if ([n rangeOfString:@"hid" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"event" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [arr addObject:[NSString stringWithFormat:@"%@:%s", n, ty ?: "?"]];
        }
    }
    free(ivars);
    return arr.count ? [arr componentsJoinedByString:@" "] : @"(无)";
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

// IOBluetooth 私有框架（更底层，HID 设备也能看到）：列已配对设备
static NSString *SnifIOBluetoothDevices(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        // 先尝试 dlopen 私有框架，让类可被发现
        dlopen("/System/Library/PrivateFrameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW);
        Class cls = NSClassFromString(@"IOBluetoothDevice");
        if (cls) {
            NSArray *devs = [cls performSelector:NSSelectorFromString(@"pairedDevices")];
            for (id d in devs) {
                NSString *name = [d performSelector:NSSelectorFromString(@"nameOrAddress")];
                NSString *addr = [d performSelector:NSSelectorFromString(@"addressString")];
                if (name.length) {
                    [out addObject:[NSString stringWithFormat:@"%@(%@)", name, addr.length ? addr : @"?"]];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return out.count ? [out componentsJoinedByString:@"  "] : @"（IOBluetooth无已配对设备）";
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
                pGetEventType = (__typeof__(pGetEventType))dlsym(iokit, "IOHIDEventGetType");
                pGetTypeID = (__typeof__(pGetTypeID))dlsym(iokit, "IOHIDEventGetTypeID");
                pGetIntegerValue = (__typeof__(pGetIntegerValue))dlsym(iokit, "IOHIDEventGetIntegerValue");
            }
        } @catch (__unused NSException *e) {}

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        // [诊断] 前缀行在设置页固定置顶显示，不会被事件日志刷掉
        SnifLog(@"[诊断] ==================================================");
        SnifLog([NSString stringWithFormat:@"[诊断] HIDEventSniffer v1.0.7 已注入 Preferences（bundle=%@）", bundleID]);
        SnifLog([NSString stringWithFormat:@"[诊断] IOKit符号: SenderID=%d UniqueID=%d Type=%d TypeID=%d GetInteger=%d",
                 pGetSenderID != NULL, pGetSenderUniqueID != NULL, pGetEventType != NULL, pGetTypeID != NULL, pGetIntegerValue != NULL]);
        SnifLog([NSString stringWithFormat:@"[诊断] UIEvent含hid/event的ivar: %@", DumpHIDIvars([UIEvent class])]);
        SnifLog([NSString stringWithFormat:@"[诊断] UITouch含hid/event的ivar: %@", DumpHIDIvars([UITouch class])]);
        SnifLog([NSString stringWithFormat:@"[诊断] BluetoothManager已连接: %@", SnifConnectedBTDevices()]);
        SnifLog([NSString stringWithFormat:@"[诊断] IOBluetooth已配对: %@", SnifIOBluetoothDevices()]);
        SnifLog(@"[诊断] 请打开本设置页，用翻页器按键：音量+/-、四方向、点击，各按2~3下");
        SnifLog([NSString stringWithFormat:@"[诊断] 日志路径: %@", SnifLogPath()]);
        SnifLog(@"[诊断] ==================================================");
    }
}
