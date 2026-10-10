// HIDEventSniffer v1.0.3 —— 蓝牙翻页器按键抓取（注入 Preferences 进程）
//
// 用户方案（比之前所有版本都干净）：
//   系统设置 → HIDEventSniffer → 极简设置页（只显示日志+刷新）
//   打开设置页（Preferences 前台），用蓝牙翻页器在设置页里按键，
//   按键事件由 backboardd 路由给前台 App（Preferences）→ 本插件在进程内捕获 →
//   写入日志 → 设置页定时刷新实时显示。
//
// 只注入 Preferences 一个进程，完全不碰 SpringBoard，安全模式风险归零。
// 只观察、只记录，绝不修改/吞掉事件。
//
// 日志双写：
//   1. Preferences 沙盒 Documents/HIDEventSniffer.log（设置页直接读这个）
//   2. /var/mobile/Documents/HIDEventSniffer.log（若权限允许，Filza 可读）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

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

// 触摸限流（点击记录 began/ended，150ms 内同相位只记一条）
static NSTimeInterval gLastTouchLog = 0;

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event) {
            NSMutableString *d = [NSMutableString string];
            if (event.type == UIEventTypePresses) {
                // 蓝牙键盘按键（方向键/回车等）。UIEvent.presses 是私有属性，用 KVC 安全取值
                NSSet *presses = [event valueForKey:@"presses"];
                if ([presses isKindOfClass:[NSSet class]]) {
                    for (UIPress *p in presses) {
                        UIKey *k = p.key;
                        if (!k) continue;
                        long long kc = (long long)k.keyCode;
                        NSString *name = KeyName(kc);
                        if (name) {
                            [d appendFormat:@"PRESS key=0x%llx(%@) phase=%ld ", kc, name, (long)p.phase];
                        } else {
                            [d appendFormat:@"PRESS key=0x%llx phase=%ld ", kc, (long)p.phase];
                        }
                    }
                }
            } else if (event.type == UIEventTypeTouches) {
                // 触摸 / 鼠标点击
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - gLastTouchLog > 0.15) {
                    for (UITouch *t in event.allTouches) {
                        if (t.phase == UITouchPhaseBegan || t.phase == UITouchPhaseEnded) {
                            CGPoint pt = [t locationInView:nil];
                            [d appendFormat:@"TOUCH phase=%ld x=%.0f y=%.0f ", (long)t.phase, pt.x, pt.y];
                        }
                    }
                    if (d.length) gLastTouchLog = now;
                }
            } else if (event.type == UIEventTypeScroll) {
                [d appendString:@"SCROLL "];
            }
            if (d.length) {
                SnifLog([NSString stringWithFormat:@"type=%ld %@", (long)event.type, d]);
            }
        }
    } @catch (__unused NSException *e) {}
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        SnifLog(@"==================================================");
        SnifLog([NSString stringWithFormat:@"HIDEventSniffer v1.0.3 已注入 Preferences（bundle=%@）", bundleID]);
        SnifLog(@"请打开本设置页，用翻页器按键：音量+/-、四方向、点击，各按2~3下");
        SnifLog([NSString stringWithFormat:@"日志路径: %@", SnifLogPath()]);
        SnifLog(@"==================================================");
    }
}
