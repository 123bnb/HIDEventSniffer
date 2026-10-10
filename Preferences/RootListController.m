// RootListController — HIDEventSniffer 设置页（手动刷新日志页）
// 页面内容：
//   - 顶部说明 + 已连接蓝牙设备（固定不动）
//   - 「刷新日志」按钮（手动刷新，不做自动轮询）
//   - 日志区：诊断行([诊断]开头)固定置顶，事件日志最新在上（旧的下沉）
//   - 「清空」按钮
// 日志读取 Preferences 沙盒 Documents/HIDEventSniffer.log（与 Tweak 同一路径）

#import <Preferences/PSViewController.h>
#import <Preferences/PSSpecifier.h>

@interface PSViewController (Private)
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier;
@end

static NSString *SnifLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"HIDEventSniffer.log"];
}

// 当前已连接的蓝牙设备（名称+地址），用于对照识别翻页器
static NSString *ConnectedBTDevices(void) {
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
    return out.count ? [out componentsJoinedByString:@"  "] : @"（未检测到已连接蓝牙设备）";
}

@interface RootListController : PSViewController
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UILabel *btLabel;
@property (nonatomic, strong) NSString *lastText;
@end

@implementation RootListController

- (id)initWithSpecifier:(PSSpecifier *)specifier {
    self = [super initWithSpecifier:specifier];
    if (self) self.title = @"HIDEventSniffer";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 避开灵动岛/导航栏：iOS16 顶部约 100pt 起步
    CGFloat top = 100;
    if (self.view.safeAreaInsets.top > 20) top = self.view.safeAreaInsets.top + 60;

    // 说明文字
    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 32, 40)];
    self.hint.text = @"打开本页后，用蓝牙翻页器按键，点「刷新日志」查看捕获的键码。诊断行固定在顶部。";
    self.hint.numberOfLines = 0;
    self.hint.font = [UIFont systemFontOfSize:13];
    self.hint.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.hint];

    // 蓝牙设备对照（固定头部，不滚动）
    self.btLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 42, self.view.bounds.size.width - 32, 30)];
    self.btLabel.text = [NSString stringWithFormat:@"已连接蓝牙: %@", ConnectedBTDevices()];
    self.btLabel.numberOfLines = 2;
    self.btLabel.font = [UIFont systemFontOfSize:12];
    self.btLabel.textColor = [UIColor systemBlueColor];
    [self.view addSubview:self.btLabel];

    CGFloat btnY = top + 78;
    // 三个按钮一行：刷新日志 / 清空 / 重启插件
    CGFloat btnW = (self.view.bounds.size.width - 16 * 2 - 8 * 2) / 3;
    // 刷新按钮（手动）
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(16, btnY, btnW, 40);
    [refresh setTitle:@"刷新日志" forState:UIControlStateNormal];
    refresh.backgroundColor = [UIColor tertiarySystemFillColor];
    refresh.layer.cornerRadius = 8;
    [refresh addTarget:self action:@selector(refreshLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:refresh];

    // 清空按钮
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(16 + btnW + 8, btnY, btnW, 40);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.backgroundColor = [UIColor tertiarySystemFillColor];
    clear.layer.cornerRadius = 8;
    [clear addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

    // 重启插件按钮：清空日志并重写诊断信息（等同插件重新初始化）
    UIButton *restart = [UIButton buttonWithType:UIButtonTypeSystem];
    restart.frame = CGRectMake(16 + (btnW + 8) * 2, btnY, btnW, 40);
    [restart setTitle:@"重启插件" forState:UIControlStateNormal];
    restart.backgroundColor = [UIColor tertiarySystemFillColor];
    restart.layer.cornerRadius = 8;
    [restart addTarget:self action:@selector(restartPlugin) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:restart];

    // 日志区
    CGFloat logY = btnY + 52;
    self.tv = [[UITextView alloc] initWithFrame:CGRectMake(8, logY, self.view.bounds.size.width - 16,
                                                            self.view.bounds.size.height - logY - 24)];
    self.tv.editable = NO;
    self.tv.selectable = YES;
    self.tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.tv.textColor = [UIColor labelColor];
    self.tv.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tv.layer.cornerRadius = 8;
    [self.view addSubview:self.tv];

    // 手动刷新：进页刷一次，之后只靠按钮
    [self refreshLog];
}

- (void)refreshLog {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:SnifLogPath()];
        if (!data) {
            if (![self.lastText isEqualToString:@"（暂无日志：请先用翻页器按键）"]) {
                self.lastText = @"（暂无日志：请先用翻页器按键）";
                self.tv.text = self.lastText;
            }
            return;
        }
        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!content.length) return;
        if ([content isEqualToString:self.lastText]) return; // 没变化不重绘，避免闪烁/选中失效
        // 拆行；[诊断]行固定置顶，其余事件日志最新在上
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        NSMutableArray *diag = [NSMutableArray array];
        NSMutableArray *events = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
            NSString *ln = lines[i];
            if (!ln.length) continue;
            if ([ln hasPrefix:@"[诊断]"]) [diag addObject:ln];
            else [events addObject:ln];
        }
        NSMutableArray *revEvents = [NSMutableArray array];
        for (NSInteger i = events.count - 1; i >= 0; i--) [revEvents addObject:events[i]];
        NSMutableArray *all = [NSMutableArray array];
        [all addObjectsFromArray:diag];
        [all addObjectsFromArray:revEvents];
        self.tv.text = [all componentsJoinedByString:@"\n"];
        self.lastText = content;
    } @catch (__unused NSException *e) {}
}

- (void)clearLog {
    @try {
        [@"" writeToFile:SnifLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        self.lastText = @"";
        self.tv.text = @"（已清空）";
    } @catch (__unused NSException *e) {}
}

// 重启插件：发 darwin 通知让 Tweak 清空日志并重写诊断信息（等同插件重新初始化）
- (void)restartPlugin {
    @try {
        extern CFNotificationCenterRef CFNotificationCenterGetDarwinCenter(void);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinCenter(),
                                              CFSTR("com.yourname.hideventsniffer/reload"),
                                              NULL, NULL, YES);
        self.lastText = @"";
        self.tv.text = @"（已发送重启指令，等待诊断重写…）";
        // 0.8s 后自动拉一次，显示新诊断
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self refreshLog];
        });
    } @catch (__unused NSException *e) {}
}

@end
