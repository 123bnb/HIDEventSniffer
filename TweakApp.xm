// HIDEventSniffer v1.0.2 App 端 —— 在 App 进程捕获蓝牙翻页器事件并转发给 SpringBoard 记录
//
// 原理：iOS 16 上蓝牙键盘/鼠标事件由 backboardd 路由到「前台 App」，
//       SpringBoard 自建 HID 客户端收不到（v1.0.1 实测为空）。
//       所以抓取必须发生在 App 进程 —— 本 dylib 注入所有 App（UIKit Filter）：
//   - hook UIApplication -sendEvent:，识别：
//       * UIEventTypePresses：蓝牙键盘按键（方向键↑↓←→、回车），key.keyCode 即 HID usage
//       * UIEventTypeTouches：触摸/鼠标点击，记录相位与坐标
//       * UIEventTypeScroll：滚轮
//   - 识别到的事件 → Darwin 通知 com.yourname.hidsniffer.event 转发 → SpringBoard 统一写日志
//
// 只观察、只记录，绝不修改事件、绝不影响 App 正常运行。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern CFNotificationCenterRef CFNotificationCenterGetDarwinCenter(void); // 私有API声明

static NSString *const kNotifName = @"com.yourname.hidsniffer.event";

// 转发给 SpringBoard 写日志（object 即事件描述字符串）
static void PostEvent(NSString *desc) {
    if (!desc.length) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinCenter(),
                                         (__bridge CFStringRef)kNotifName,
                                         (__bridge CFStringRef)desc, NULL, true);
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

// 触摸限流（点击记录 began/ended，200ms 内同相位只记一条）
static NSTimeInterval gLastTouchLog = 0;

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    @try {
        if (event) {
            NSMutableString *d = [NSMutableString string];
            if (event.type == UIEventTypePresses) {
                // 蓝牙键盘按键（方向键/回车等）
                for (UIPress *p in event.presses) {
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
                PostEvent([NSString stringWithFormat:@"type=%ld %@", (long)event.type, d]);
            }
        }
    } @catch (__unused NSException *e) {}
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // 注：日志由 SpringBoard 端统一写 /var/mobile/Documents/HIDEventSniffer.log
        // App 沙盒内无法写该路径，因此只做转发。NSLog 留一份进程标识便于排错。
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        NSLog(@"HIDSniffer App端 已注入 bundle=%@", bundleID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinCenter(),
                                             (__bridge CFStringRef)kNotifName,
                                             (__bridge CFStringRef)[NSString stringWithFormat:@"[app注入] bundle=%@", bundleID],
                                             NULL, true);
    }
}
