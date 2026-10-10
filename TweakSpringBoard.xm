// HIDEventSniffer v1.0.2 SpringBoard 端 —— 蓝牙翻页器事件抓取（统一日志接收）
// 职责：
//   1. 保留自建 HID 客户端被动监听（系统级事件，能收则收）
//   2. 监听 Darwin 通知 com.yourname.hidsniffer.event，把 App 进程转发来的
//      方向键/点击/触摸事件写入同一份日志
// 日志：/var/mobile/Documents/HIDEventSniffer.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

extern CFNotificationCenterRef CFNotificationCenterGetDarwinCenter(void); // 私有API声明

// ===== IOKit 私有 HID 接口类型（自行声明，不依赖私有头）=====
typedef struct __IOHIDEvent *SnifIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *SnifIOHIDEventSystemClientRef;
typedef void (*SnifHIDCallback)(void *target, void *refcon, SnifIOHIDEventRef event, void *sender);

// IOHIDEventType（IOKit/hid/IOHIDEventTypes.h）
enum { SnifEvtKeyboard = 3, SnifEvtMouse = 5, SnifEvtScroll = 9, SnifEvtDigitizer = 11 };
static inline uint32_t SnifField(uint32_t type, uint32_t index) { return (type << 16) | index; }

// ===== 运行时解析的 C 函数指针（dlsym，跨版本稳定）=====
static uint32_t (*pGetType)(SnifIOHIDEventRef);
static CFIndex  (*pGetInt)(SnifIOHIDEventRef, uint32_t);
static SnifIOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static void (*pSchedule)(SnifIOHIDEventSystemClientRef, dispatch_queue_t);
static void (*pRegCb)(SnifIOHIDEventSystemClientRef, SnifHIDCallback, void *, CFDictionaryRef);

// ===== 日志 =====
static NSString *const kLogPath = @"/var/mobile/Documents/HIDEventSniffer.log";
static void SnifLog(NSString *s) {
    NSLog(@"HIDSniffer %@", s);
    @synchronized ([NSDate class]) {
        @try {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = @"HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], s];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:@"/var/mobile/Documents" withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm fileExistsAtPath:kLogPath]) [fm createFileAtPath:kLogPath contents:nil attributes:nil];
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
            if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
        } @catch (__unused NSException *e) {}
    }
}
static NSString *SnifTypeName(uint32_t t) {
    switch (t) {
        case SnifEvtKeyboard:  return @"Keyboard";
        case SnifEvtMouse:     return @"Mouse";
        case SnifEvtScroll:    return @"Scroll";
        case SnifEvtDigitizer: return @"Digitizer";
        default: return [NSString stringWithFormat:@"Type%u", t];
    }
}

// 鼠标纯移动限流（100ms 一条，够看方向又不刷屏）
static NSTimeInterval gLastMouseMoveLog = 0;

// 只做「描述字符串」，不做 children 递归（递归是崩溃高发区）。@try 无法捕获 C 内存错，
// 因此这里只访问最安全的事件字段。
static NSString *SnifDescribe(SnifIOHIDEventRef event, uint32_t t) {
    if (!event || !pGetInt) return nil;
    NSMutableString *m = [NSMutableString stringWithFormat:@"t=%u(%@)", t, SnifTypeName(t)];
    if (t == SnifEvtKeyboard) {
        CFIndex page  = pGetInt(event, SnifField(3, 0));
        CFIndex usage = pGetInt(event, SnifField(3, 1));
        CFIndex down  = pGetInt(event, SnifField(3, 2));
        [m appendFormat:@"  >>> page=0x%llx usage=0x%llx down=%lld", (long long)page, (long long)usage, (long long)down];
        if (page == 0x0C) { // Consumer 消费者键（音量/媒体）
            if (usage == 0xE9)      [m appendString:@"  [音量+]"];
            else if (usage == 0xEA) [m appendString:@"  [音量-]"];
            else if (usage == 0xE2) [m appendString:@"  [静音]"];
            else if (usage == 0xCD) [m appendString:@"  [播放/暂停]"];
            else if (usage == 0xB5) [m appendString:@"  [下一曲]"];
            else if (usage == 0xB6) [m appendString:@"  [上一曲]"];
        } else if (page == 0x07) { // Keyboard/Keypad 键盘键
            if (usage == 0x52)      [m appendString:@"  [方向↑]"];
            else if (usage == 0x51) [m appendString:@"  [方向↓]"];
            else if (usage == 0x50) [m appendString:@"  [方向←]"];
            else if (usage == 0x4F) [m appendString:@"  [方向→]"];
            else if (usage == 0x28) [m appendString:@"  [回车]"];
            else if (usage == 0x29) [m appendString:@"  [ESC]"];
        }
    } else if (t == SnifEvtMouse) {
        CFIndex x = pGetInt(event, SnifField(5, 0));
        CFIndex y = pGetInt(event, SnifField(5, 1));
        CFIndex btn = pGetInt(event, SnifField(5, 10));
        if (btn == 0) { // 纯移动
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now - gLastMouseMoveLog < 0.1) return nil; // 限流
            gLastMouseMoveLog = now;
            [m appendFormat:@"  >>> MOVE x=%lld y=%lld", (long long)x, (long long)y];
        } else { // 点击
            [m appendFormat:@"  >>> CLICK x=%lld y=%lld btnMask=0x%llx", (long long)x, (long long)y, (long long)btn];
        }
    } else if (t == SnifEvtScroll) {
        CFIndex x = pGetInt(event, SnifField(9, 0));
        CFIndex y = pGetInt(event, SnifField(9, 1));
        [m appendFormat:@"  >>> 滚轮 x=%lld y=%lld", (long long)x, (long long)y];
    } else if (t == SnifEvtDigitizer) {
        return nil; // 手指触摸，忽略
    } else {
        for (uint32_t i = 0; i < 4; i++) { CFIndex v = pGetInt(event, SnifField(t, i)); if (v) [m appendFormat:@" f%u=%lld", i, (long long)v]; }
    }
    return m;
}

// ===== 自建客户端被动监听 =====
static SnifIOHIDEventSystemClientRef gOwnClient = NULL;

static void SnifOwnCallback(void *target, void *refcon, SnifIOHIDEventRef event, void *sender) {
    @try {
        if (!event || !pGetType) return;
        uint32_t t = pGetType(event);
        NSString *line = SnifDescribe(event, t);
        if (!line) return;
        // 切到主队列写日志，避免在 HID 回调线程做 I/O
        dispatch_async(dispatch_get_main_queue(), ^{ SnifLog(line); });
    } @catch (__unused NSException *e) {}
}

static void SnifStartOwnClient(void) {
    @try {
        if (!pCreate || !pSchedule || !pRegCb) { SnifLog(@"[A] IOKit 函数未解析，无法自建客户端"); return; }
        gOwnClient = pCreate(kCFAllocatorDefault);
        if (!gOwnClient) { SnifLog(@"[A] 自建 HID 客户端失败（NULL）"); return; }
        pSchedule(gOwnClient, dispatch_get_main_queue());
        pRegCb(gOwnClient, SnifOwnCallback, NULL, NULL); // matching=NULL 监听全部
        SnifLog(@"[A] 自建 HID 客户端已注册，正在被动监听（v1.0.2）");
    } @catch (NSException *e) {
        SnifLog([@"[A] 自建客户端异常: " stringByAppendingString:e.reason]);
    }
}

// ===== 接收 App 进程转发的方向键/点击事件 =====
static void SnifOnAppEvent(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (object) {
        SnifLog([NSString stringWithFormat:@"[app] %@", (__bridge NSString *)object]);
    }
}

%ctor {
    @autoreleasepool {
        SnifLog(@"==================================================");
        SnifLog([NSString stringWithFormat:@"HIDEventSniffer v1.0.2 已注入 SpringBoard，iOS %@", UIDevice.currentDevice.systemVersion]);
        SnifLog(@"请打开任意 App，把翻页器每个按钮（音量+/-、四方向、点击）各按 2~3 下");
        SnifLog(@"==================================================");

        // 注册 Darwin 通知，接收 App 进程转发的事件
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinCenter(), NULL,
                                        SnifOnAppEvent,
                                        CFSTR("com.yourname.hidsniffer.event"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        @try {
            void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
            if (iokit) {
                void *hGetType  = dlsym(iokit, "IOHIDEventGetType");
                void *hGetInt   = dlsym(iokit, "IOHIDEventGetIntegerValue");
                void *hCreate   = dlsym(iokit, "IOHIDEventSystemClientCreate");
                void *hSchedule = dlsym(iokit, "IOHIDEventSystemClientScheduleWithDispatchQueue");
                void *hRegCb    = dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback");
                pGetType = (__typeof__(pGetType))hGetType;
                pGetInt  = (__typeof__(pGetInt))hGetInt;
                pCreate  = (__typeof__(pCreate))hCreate;
                pSchedule = (__typeof__(pSchedule))hSchedule;
                pRegCb   = (__typeof__(pRegCb))hRegCb;
                SnifLog([NSString stringWithFormat:@"IOKit 解析: GetType=%d GetInt=%d Create=%d RegCb=%d",
                         pGetType != NULL, pGetInt != NULL, pCreate != NULL, pRegCb != NULL]);
            } else {
                SnifLog(@"dlopen IOKit 失败");
            }
        } @catch (NSException *e) { SnifLog([@"初始化异常: " stringByAppendingString:e.reason]); }

        dispatch_async(dispatch_get_main_queue(), ^{ SnifStartOwnClient(); });
    }
}
