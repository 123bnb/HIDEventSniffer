// HIDEventSniffer —— 蓝牙翻页器 HID 事件抓取诊断（注入 SpringBoard）
// 只观察、只记录，绝不修改/吞掉任何事件，不影响系统（安全模式风险为零）。
// 日志：/var/mobile/Documents/HIDEventSniffer.log （同时 NSLog 到系统日志）
//
// 抓两类来源：
//   A. 自己创建一个 IOHIDEventSystemClient 被动监听全部事件（主力，不干扰系统原有客户端）
//   B. MSHookFunction hook 系统的 RegisterEventCallback / RegisterEventBlock（对照）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <substrate.h>

// ===== IOKit 私有 HID 接口类型（自行声明，不依赖私有头）=====
typedef struct __IOHIDEvent *SnifIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *SnifIOHIDEventSystemClientRef;
typedef void (*SnifHIDCallback)(void *target, void *refcon, SnifIOHIDEventRef event, void *sender);
typedef void (^SnifHIDBlock)(void *target, SnifIOHIDEventRef event, void *sender);

// IOHIDEventType（IOKit/hid/IOHIDEventTypes.h）
enum { SnifEvtKeyboard = 3, SnifEvtMouse = 5, SnifEvtScroll = 9, SnifEvtDigitizer = 11 };
static inline uint32_t SnifField(uint32_t type, uint32_t index) { return (type << 16) | index; }

// ===== 运行时解析的 C 函数指针（dlsym，跨版本稳定）=====
static uint32_t (*pGetType)(SnifIOHIDEventRef);
static CFIndex  (*pGetInt)(SnifIOHIDEventRef, uint32_t);
static CFArrayRef (*pGetChildren)(SnifIOHIDEventRef);
static SnifIOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static void (*pSchedule)(SnifIOHIDEventSystemClientRef, dispatch_queue_t);
static void (*pRegCb)(SnifIOHIDEventSystemClientRef, SnifHIDCallback, void *, CFDictionaryRef);
static void (*pRegBlock)(SnifIOHIDEventSystemClientRef, SnifHIDBlock, void *, CFDictionaryRef);

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

// 鼠标纯移动限流（80ms 一条，足够看出滑动方向又不刷屏）
static NSTimeInterval gLastMouseMoveLog = 0;

static void SnifDumpEvent(SnifIOHIDEventRef event, int depth) {
    if (!event || !pGetType) return;
    uint32_t t = pGetType(event);
    NSMutableString *m = [NSMutableString stringWithFormat:@"%*s", depth * 2, ""];
    [m appendFormat:@"t=%u(%@)", t, SnifTypeName(t)];

    if (t == SnifEvtKeyboard) {
        for (uint32_t i = 0; i < 4; i++) { CFIndex v = pGetInt(event, SnifField(t, i)); if (v) [m appendFormat:@" f%u=%lld", i, (long long)v]; }
        CFIndex page = pGetInt(event, SnifField(3, 0));
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
        SnifLog(m);
    } else if (t == SnifEvtMouse) {
        CFIndex x = pGetInt(event, SnifField(5, 0));
        CFIndex y = pGetInt(event, SnifField(5, 1));
        CFIndex btn = pGetInt(event, SnifField(5, 10));
        if (btn == 0) { // 纯移动
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now - gLastMouseMoveLog >= 0.08) {
                gLastMouseMoveLog = now;
                [m appendFormat:@"  >>> MOVE x=%lld y=%lld", (long long)x, (long long)y];
                SnifLog(m);
            }
        } else { // 按键（点击）
            for (uint32_t i = 0; i < 16; i++) { CFIndex v = pGetInt(event, SnifField(t, i)); if (v) [m appendFormat:@" f%u=%lld", i, (long long)v]; }
            [m appendFormat:@"  >>> CLICK x=%lld y=%lld btnMask=0x%llx", (long long)x, (long long)y, (long long)btn];
            SnifLog(m);
        }
    } else if (t == SnifEvtScroll) {
        for (uint32_t i = 0; i < 4; i++) { CFIndex v = pGetInt(event, SnifField(t, i)); if (v) [m appendFormat:@" f%u=%lld", i, (long long)v]; }
        [m appendString:@"  >>> 滚轮"];
        SnifLog(m);
    } else if (t == SnifEvtDigitizer) {
        // 手指触摸屏幕事件，极高频，默认忽略（遥控器用不到）
    } else {
        for (uint32_t i = 0; i < 8; i++) { CFIndex v = pGetInt(event, SnifField(t, i)); if (v) [m appendFormat:@" f%u=%lld", i, (long long)v]; }
        SnifLog(m);
    }
    CFArrayRef ch = pGetChildren ? pGetChildren(event) : NULL;
    CFIndex n = ch ? CFArrayGetCount(ch) : 0;
    for (CFIndex i = 0; i < n; i++) SnifDumpEvent((SnifIOHIDEventRef)CFArrayGetValueAtIndex(ch, i), depth + 1);
}

// ===== A. 自建客户端被动监听 =====
static SnifIOHIDEventSystemClientRef gOwnClient = NULL;
static void SnifOwnCallback(void *target, void *refcon, SnifIOHIDEventRef event, void *sender) {
    @try { SnifDumpEvent(event, 0); } @catch (__unused NSException *e) {}
}
static void SnifStartOwnClient(void) {
    @try {
        if (!pCreate || !pSchedule || !pRegCb) { SnifLog(@"[A] IOKit 函数未解析，无法自建客户端"); return; }
        gOwnClient = pCreate(kCFAllocatorDefault);
        if (!gOwnClient) { SnifLog(@"[A] 自建 HID 客户端失败（NULL）"); return; }
        pSchedule(gOwnClient, dispatch_get_main_queue());
        // 用原始（未 hook）注册函数，避免被自己的 hook 再包一层
        void (*realReg)(SnifIOHIDEventSystemClientRef, SnifHIDCallback, void *, CFDictionaryRef) = pRegCb;
        realReg(gOwnClient, SnifOwnCallback, NULL, NULL);
        SnifLog(@"[A] 自建 HID 客户端已注册，正在被动监听全部事件");
    } @catch (NSException *e) { SnifLog([@"[A] 异常: " stringByAppendingString:e.reason]); }
}

// ===== B. hook 系统注册函数（对照）=====
static SnifHIDCallback gOrigCallback = NULL;
static SnifHIDBlock gOrigBlock = nil;
static SnifHIDBlock gWrapBlock = nil;

static void SnifWrapCallback(void *target, void *refcon, SnifIOHIDEventRef event, void *sender) {
    @try { SnifDumpEvent(event, 0); } @catch (__unused NSException *e) {}
    if (gOrigCallback) gOrigCallback(target, refcon, event, sender);
}

static void (*orig_RegCb)(SnifIOHIDEventSystemClientRef, SnifHIDCallback, void *, CFDictionaryRef);
static void hook_RegCb(SnifIOHIDEventSystemClientRef client, SnifHIDCallback cb, void *ctx, CFDictionaryRef match) {
    gOrigCallback = cb;
    SnifLog([NSString stringWithFormat:@"[B] 系统 RegisterEventCallback client=%p（已挂钩）", client]);
    if (orig_RegCb) orig_RegCb(client, SnifWrapCallback, ctx, match);
}

static void (*orig_RegBlock)(SnifIOHIDEventSystemClientRef, SnifHIDBlock, void *, CFDictionaryRef);
static void hook_RegBlock(SnifIOHIDEventSystemClientRef client, SnifHIDBlock block, void *ctx, CFDictionaryRef match) {
    gOrigBlock = [block copy];
    SnifLog([NSString stringWithFormat:@"[B] 系统 RegisterEventBlock client=%p（已挂钩）", client]);
    if (!gWrapBlock) {
        gWrapBlock = [^(void *target, SnifIOHIDEventRef event, void *sender) {
            @try { SnifDumpEvent(event, 0); } @catch (__unused NSException *e) {}
            if (gOrigBlock) gOrigBlock(target, event, sender);
        } copy];
    }
    if (orig_RegBlock) orig_RegBlock(client, gWrapBlock, ctx, match);
}

%ctor {
    @autoreleasepool {
        SnifLog(@"==================================================");
        SnifLog([NSString stringWithFormat:@"HIDEventSniffer 已注入 SpringBoard，iOS %@", UIDevice.currentDevice.systemVersion]);
        SnifLog(@"请把翻页器每个按钮（音量+/-、四方向、点击）各按 2~3 下");
        SnifLog(@"==================================================");

        @try {
            void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
            if (iokit) {
                pGetType     = (void *)dlsym(iokit, "IOHIDEventGetType");
                pGetInt      = (void *)dlsym(iokit, "IOHIDEventGetIntegerValue");
                pGetChildren = (void *)dlsym(iokit, "IOHIDEventGetChildren");
                pCreate      = (void *)dlsym(iokit, "IOHIDEventSystemClientCreate");
                pSchedule    = (void *)dlsym(iokit, "IOHIDEventSystemClientScheduleWithDispatchQueue");
                pRegCb       = (void *)dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback");
                pRegBlock    = (void *)dlsym(iokit, "IOHIDEventSystemClientRegisterEventBlock");
                SnifLog([NSString stringWithFormat:@"IOKit 解析: GetType=%d GetInt=%d Create=%d RegCb=%d RegBlock=%d",
                         pGetType != NULL, pGetInt != NULL, pCreate != NULL, pRegCb != NULL, pRegBlock != NULL]);
                if (pRegCb)    MSHookFunction((void *)pRegCb, (void *)hook_RegCb, (void **)&orig_RegCb);
                if (pRegBlock) MSHookFunction((void *)pRegBlock, (void *)hook_RegBlock, (void **)&orig_RegBlock);
            } else {
                SnifLog(@"dlopen IOKit 失败");
            }
        } @catch (NSException *e) { SnifLog([@"初始化 hook 异常: " stringByAppendingString:e.reason]); }

        dispatch_async(dispatch_get_main_queue(), ^{ SnifStartOwnClient(); });
    }
}
