// RootListController — HIDEventSniffer 设置页（极简日志页）
// 页面内容：
//   - 顶部说明：打开本页后，用蓝牙翻页器按键，下方日志实时显示
//   - 「刷新日志」按钮（也自动刷新：0.6s 轮询，进页即实时）
//   - 日志区：最新一行在最上面（旧的下沉）
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
@property (nonatomic, strong) NSTimer *timer;
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
    self.hint.text = @"打开本页后，用蓝牙翻页器按键（音量+/-、四方向、点击），下方实时显示捕获的键码。";
    self.hint.numberOfLines = 0;
    self.hint.font = [UIFont systemFontOfSize:13];
    self.hint.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.hint];

    // 蓝牙设备对照
    self.btLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 42, self.view.bounds.size.width - 32, 30)];
    self.btLabel.text = [NSString stringWithFormat:@"已连接蓝牙: %@", ConnectedBTDevices()];
    self.btLabel.numberOfLines = 2;
    self.btLabel.font = [UIFont systemFontOfSize:12];
    self.btLabel.textColor = [UIColor systemBlueColor];
    [self.view addSubview:self.btLabel];

    CGFloat btnY = top + 78;
    // 刷新按钮
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(16, btnY, (self.view.bounds.size.width - 48) / 2, 40);
    [refresh setTitle:@"刷新日志" forState:UIControlStateNormal];
    refresh.backgroundColor = [UIColor tertiarySystemFillColor];
    refresh.layer.cornerRadius = 8;
    [refresh addTarget:self action:@selector(refreshLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:refresh];

    // 清空按钮
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(24 + (self.view.bounds.size.width - 48) / 2, btnY, (self.view.bounds.size.width - 48) / 2, 40);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.backgroundColor = [UIColor tertiarySystemFillColor];
    clear.layer.cornerRadius = 8;
    [clear addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clear];

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

    [self refreshLog];

    // 自动刷新 0.6s
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self
                                                selector:@selector(refreshLog)
                                                userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
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
        if ([content isEqualToString:self.lastText]) return; // 没变化不刷新，避免闪烁
        // 最新在上：拆行反转
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        NSMutableArray *rev = [NSMutableArray array];
        for (NSInteger i = lines.count - 1; i >= 0; i--) {
            NSString *ln = lines[i];
            if (ln.length) [rev addObject:ln];
        }
        self.tv.text = [rev componentsJoinedByString:@"\n"];
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

@end
