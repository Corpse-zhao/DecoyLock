//
//  DLRootListController.m
//  伪锁屏 DecoyLock 设置面板
//
//  ⚠️ 架构决策（v0.1.4，推翻 v0.1.3 的 specifier 手搓方案）：
//    - 主面板：仍然用 PSListController + Root.plist（plist 驱动的开关/输入框，最稳）
//    - 输入框：改用 PSEditTextCell（PSLinkCell 跳转），不再用 PSTextFieldSpecifier
//      —— 后者现代 iOS 上点击常无反应（用户实测「伪密码点击不了」）
//    - App 选择器：改用【纯原生 UITableViewController】，彻底不碰 PSSpecifier 私有构造
//      —— [PSSpecifier new] + setValue:forKey: 极脆弱，是「点击闪退」的根因
//
#import "DLRootListController.h"
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>

// 配置域
static NSString *const kDLDomain = @"com.blr.decoylock";

// ---------------------------------------------------------------------------
// 配置读写（共享目录 + NSUserDefaults，SpringBoard 侧可读）
// ---------------------------------------------------------------------------

static NSString *DLPrefsDir(void) {
    NSString *base = @"/var/mobile/Documents";
    if (![[NSFileManager defaultManager] fileExistsAtPath:base]) {
        base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                   NSUserDomainMask, YES).firstObject;
    }
    NSString *d = [base stringByAppendingPathComponent:@"伪锁屏"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    return d;
}

static NSString *DLPrefsConfigPath(void) {
    return [DLPrefsDir() stringByAppendingPathComponent:@"_config.plist"];
}

static NSString *DLPrefsProbePath(void) {
    return [DLPrefsDir() stringByAppendingPathComponent:@"_probe.txt"];
}

static NSMutableDictionary *DLPrefsLoad(void) {
    return [NSMutableDictionary dictionaryWithContentsOfFile:DLPrefsConfigPath()]
           ?: [NSMutableDictionary dictionary];
}

static void DLPrefsSave(NSDictionary *cfg) {
    [cfg writeToFile:DLPrefsConfigPath() atomically:YES];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDLDomain];
    for (NSString *k in cfg) [d setObject:cfg[k] forKey:k];
    [d synchronize];
    notify_post("com.blr.decoylock/prefschanged");
}

// 内置假 App 清单（与插件端 DLCommon.m 的 DLAllFakeApps 保持一致）
static NSArray *DLFakeApps(void) {
    return @[
        @{@"id": @"phone",    @"name": @"电话"},
        @{@"id": @"message",  @"name": @"信息"},
        @{@"id": @"mail",     @"name": @"邮件"},
        @{@"id": @"safari",   @"name": @"Safari"},
        @{@"id": @"camera",   @"name": @"相机"},
        @{@"id": @"photos",   @"name": @"照片"},
        @{@"id": @"notes",    @"name": @"备忘录"},
        @{@"id": @"calendar", @"name": @"日历"},
        @{@"id": @"clock",    @"name": @"时钟"},
        @{@"id": @"weather",  @"name": @"天气"},
        @{@"id": @"settings", @"name": @"设置"},
        @{@"id": @"maps",     @"name": @"地图"},
        @{@"id": @"music",    @"name": @"音乐"},
        @{@"id": @"wallet",   @"name": @"钱包"},
        @{@"id": @"files",    @"name": @"文件"},
        @{@"id": @"health",   @"name": @"健康"},
    ];
}

static NSArray *DLDefaultSelection(void) {
    return @[@"phone", @"message", @"camera", @"settings"];
}

#pragma mark - 前向声明（类扩展须写在所有实现之前）

@interface DLAppPickerController ()
@property (nonatomic, strong) NSMutableSet *selected;
@end

@interface DLTextEditController : PSListController
@property (nonatomic, copy) NSString *cfgKey;
@property (nonatomic, copy) NSString *cfgTitle;
@property (nonatomic, assign) BOOL numericOnly;
@end

#pragma mark - 主面板

@implementation DLRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self migrateDefaultsIfNeeded];
    }
    return _specifiers;
}

- (void)migrateDefaultsIfNeeded {
    NSMutableDictionary *cfg = DLPrefsLoad();
    BOOL changed = NO;
    if (!cfg[@"decoy_title"])  { cfg[@"decoy_title"] = @"我的 iPhone"; changed = YES; }
    if (!cfg[@"decoy_apps"])   { cfg[@"decoy_apps"] = DLDefaultSelection(); changed = YES; }
    if (!cfg[@"enabled"])      { cfg[@"enabled"] = @NO; changed = YES; }
    if (changed) DLPrefsSave(cfg);
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSDictionary *cfg = DLPrefsLoad();
    id v = cfg[key];
    if (v) return v;
    return [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key.length) return;
    NSMutableDictionary *cfg = DLPrefsLoad();
    cfg[key] = value;
    DLPrefsSave(cfg);

    if ([key isEqualToString:@"decoy_passcode"]) {
        [[NSFileManager defaultManager] removeItemAtPath:DLPrefsProbePath() error:NULL];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"伪锁屏";
}

// 从 plist 里读当前值（给自定义编辑页用）
- (id)valueForKey:(NSString *)key fallback:(id)fb {
    id v = DLPrefsLoad()[key];
    return v ?: fb;
}

// ------------------------------ 按钮动作 ------------------------------

- (void)respring {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"重启桌面"
                         message:@"将结束 SpringBoard 使其重新加载插件。屏幕会短暂黑屏，属正常现象。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        pid_t pid = 0;
        int status = 0;
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
        waitpid(pid, &status, 0);
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showProbe {
    NSString *text = [NSString stringWithContentsOfFile:DLPrefsProbePath()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!text.length) text = @"（暂无日志）\n\n请先：① 确认总开关已打开 ② 设好伪密码\n③ 执行一次「重启桌面」 ④ 在锁屏输入伪密码";

    NSMutableDictionary *cfg = DLPrefsLoad();
    NSString *header = [NSString stringWithFormat:
        @"【当前配置】\n启用=%@\n伪密码=%@\n假App=%@\n配置路径=%@\n\n【运行日志（尾部）】\n",
        [cfg[@"enabled"] boolValue] ? @"是" : @"否",
        ([cfg[@"decoy_passcode"] length] > 0) ? @"已设置" : @"未设置",
        [cfg[@"decoy_apps"] componentsJoinedByString:@","] ?: @"(默认)",
        DLPrefsConfigPath()];

    NSMutableString *body = [NSMutableString stringWithString:header];
    if (text.length > 6000) {
        [body appendString:[text substringFromIndex:text.length - 6000]];
    } else {
        [body appendString:text];
    }

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.text = body;
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:11.0] ?: [UIFont systemFontOfSize:11.0];
    tv.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    vc.title = @"运行诊断";
    tv.frame = vc.view.bounds;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [vc.view addSubview:tv];

    [self.navigationController pushViewController:vc animated:YES];
}

- (void)clearProbe {
    [[NSFileManager defaultManager] removeItemAtPath:DLPrefsProbePath() error:NULL];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已清除"
                                                               message:@"诊断日志已清空。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ⚠️ plist 里的 PSLinkCell 会调这个方法跳到自定义编辑页
- (void)pushTextEditor:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"cfgKey"] ?: [spec propertyForKey:@"key"];
    DLTextEditController *vc = [[DLTextEditController alloc] init];
    vc.cfgKey = key;
    vc.cfgTitle = [spec propertyForKey:@"label"] ?: @"编辑";
    vc.numericOnly = [[spec propertyForKey:@"numericOnly"] boolValue];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - 纯原生 App 选择器（不碰 PSSpecifier）

@implementation DLAppPickerController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"假空间 App";

    NSMutableDictionary *cfg = DLPrefsLoad();
    NSArray *cur = cfg[@"decoy_apps"];
    if (![cur isKindOfClass:[NSArray class]] || !cur.count) cur = DLDefaultSelection();
    self.selected = [NSMutableSet setWithArray:cur];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(save)];
}

- (void)save {
    NSMutableDictionary *cfg = DLPrefsLoad();
    // 保持内置清单顺序
    NSMutableArray *ordered = [NSMutableArray array];
    for (NSDictionary *a in DLFakeApps()) {
        if ([self.selected containsObject:a[@"id"]]) [ordered addObject:a[@"id"]];
    }
    cfg[@"decoy_apps"] = ordered;
    DLPrefsSave(cfg);
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)DLFakeApps().count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @"勾选后显示在假空间里，点右上角「完成」保存";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"DLAppPickerCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID];
    }
    NSArray *all = DLFakeApps();
    if (ip.row < 0 || ip.row >= (NSInteger)all.count) return cell;

    NSString *ident = all[(NSUInteger)ip.row][@"id"];
    cell.textLabel.text = all[(NSUInteger)ip.row][@"name"];
    cell.accessoryType = [self.selected containsObject:ident]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *all = DLFakeApps();
    if (ip.row < 0 || ip.row >= (NSInteger)all.count) return;

    NSString *ident = all[(NSUInteger)ip.row][@"id"];
    if ([self.selected containsObject:ident]) [self.selected removeObject:ident];
    else                                      [self.selected addObject:ident];

    [tv reloadRowsAtIndexPaths:@[ip] withAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - 纯原生文本编辑页（替代 PSTextFieldSpecifier）

@implementation DLTextEditController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.cfgTitle ?: @"编辑";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(20, 0,
                            self.view.bounds.size.width - 40, 44)];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    if (self.numericOnly) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.secureTextEntry = YES;
    }
    tf.text = DLPrefsLoad()[self.cfgKey] ?: @"";
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.textField = tf;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
                            self.view.bounds.size.width, 60)];
    header.backgroundColor = [UIColor clearColor];
    tf.center = CGPointMake(header.bounds.size.width / 2.0, 30);
    [header addSubview:tf];

    UITableView *tv = (UITableView *)self.view;
    tv.tableHeaderView = header;
    [tf becomeFirstResponder];
}

- (void)save {
    NSString *v = self.textField.text ?: @"";
    if (self.numericOnly) {
        // 只保留数字
        NSMutableString *digits = [NSMutableString string];
        for (NSUInteger i = 0; i < v.length; i++) {
            unichar c = [v characterAtIndex:i];
            if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        }
        v = digits;
    }
    NSMutableDictionary *cfg = DLPrefsLoad();
    cfg[self.cfgKey] = v;
    DLPrefsSave(cfg);

    if ([self.cfgKey isEqualToString:@"decoy_passcode"]) {
        [[NSFileManager defaultManager] removeItemAtPath:DLPrefsProbePath() error:NULL];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 0; }

@end
