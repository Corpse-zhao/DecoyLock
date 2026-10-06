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
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>

// libproc.h 不在 iOS SDK 中，但函数在 libSystem 里 —— 手动声明
#define PROC_ALL_PIDS 1
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(pid_t pid, void *buffer, uint32_t buffersize);

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
    // ⭐ v0.1.16：默认退出 App = 设置（插件端 DLDecoyExitApp() 默认值保持一致）
    if (!cfg[@"decoy_exit_app"]) { cfg[@"decoy_exit_app"] = @"settings"; changed = YES; }
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
            DLDoRespring();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// killall 的真实路径：rootful 在 /usr/bin；roothide 在随机 jbroot 里。
// ⚠️ jbroot 路径不能写死 —— 用 dladdr 拿到自身 bundle 二进制的物理路径，
//    截取 <jbroot> 前缀（/<...>/​.jbroot-XXXX/Library/PreferenceBundles/...）
static NSString *DLKillallPath(void) {
    if (access("/usr/bin/killall", X_OK) == 0) return @"/usr/bin/killall";

    Dl_info info;
    if (dladdr((void *)&DLKillallPath, &info) && info.dli_fname) {
        NSString *self_ = [NSString stringWithUTF8String:info.dli_fname];
        NSRange r = [self_ rangeOfString:@"/Library/PreferenceBundles/"];
        if (r.location != NSNotFound) {
            NSString *jbroot = [self_ substringToIndex:r.location];
            NSString *cand = [jbroot stringByAppendingPathComponent:@"usr/bin/killall"];
            if (access([cand fileSystemRepresentation], X_OK) == 0) return cand;
        }
    }
    return nil;
}

// ⚠️ respring 首选：proc_listpids 枚举 + kill(SIGKILL) —— 无子进程、无 PATH 依赖。
//    （posix_spawn /usr/bin/killall 在 roothide 的沙盒设置进程里可能被静默拦掉，
//     用户实测「点了没反应」；system() 在 iOS SDK 被 unavailable。）
static void DLDoRespring(void) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n > 0) {
        pid_t *pids = (pid_t *)calloc(1, (NSUInteger)n + 64);
        int m = proc_listpids(PROC_ALL_PIDS, 0, pids, n + 64);
        for (int i = 0; i < m / (int)sizeof(pid_t); i++) {
            char name[256] = {0};
            if (proc_name(pids[i], name, sizeof(name)) <= 0) continue;
            if (strcmp(name, "SpringBoard") == 0) {
                kill(pids[i], SIGKILL);
                break;
            }
        }
        free(pids);
    }

    // 备用（前面失败时仍能杀到）：spawn killall
    NSString *kp = DLKillallPath();
    if (kp) {
        pid_t pid = 0;
        int st = 0;
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, [kp fileSystemRepresentation], NULL, NULL,
                    (char *const *)args, NULL);
        waitpid(pid, &st, 0);
    }
}

// ⚠️ v0.1.6：诊断页从「UIAlert 弹窗」改为【自建全屏可滚动查看器】。
//    原因：日志是几十行，UIAlert 的 message 区域根本显示不全，
//    用户没法把内容抄出来发给我 —— 这是上一轮排查卡住的关键。
- (void)showProbe {
    DLProbeController *vc = [[DLProbeController alloc] initWithStyle:UITableViewStylePlain];
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

// ⚠️ App 选择器也走同一条已验证的 push 通道 —— 绝不用 plist 的 detail 键：
//    Preferences 框架对 detail 控制器有 PSListController 体系假设，
//    给纯原生 UITableViewController 会在框架内部实例化时崩溃（用户实测闪退）。
- (void)pushAppPicker:(PSSpecifier *)spec {
    DLAppPickerController *vc = [[DLAppPickerController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

// ⭐ v0.1.16：退出 App 选择器
- (void)pushExitAppPicker:(PSSpecifier *)spec {
    DLExitAppPickerController *vc = [[DLExitAppPickerController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - 诊断日志查看器（自建，纯原生）
// ⚠️ 不能用 UIAlertController 的 message 显示长日志 —— 显示不全且无法复制。
//    这里用 UITableView：每行一条日志，可滚动；右上角一键复制全文。
//    行高固定 22pt + numberOfLines = 0，日志换行也能完整展开。

@implementation DLProbeController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行诊断";
    self.tableView.rowHeight = 22.0;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(copyAll)];
    [self reload];
}

- (void)reload {
    NSMutableDictionary *cfg = DLPrefsLoad();

    NSString *raw = [NSString stringWithContentsOfFile:DLPrefsProbePath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (!raw.length) raw = @"（暂无日志）";

    NSMutableArray *lines = [NSMutableArray array];

    // ---- 配置摘要（放最前面，一眼能看出「开关没开」/「密码没设」）----
    [lines addObject:[NSString stringWithFormat:@"═══ 当前配置 ═══"]];
    [lines addObject:[NSString stringWithFormat:@"总开关: %@",
        [cfg[@"enabled"] boolValue] ? @"✅ 已开启" : @"❌ 未开启（插件不生效！）"]];
    [lines addObject:[NSString stringWithFormat:@"伪密码: %@",
        ([cfg[@"decoy_passcode"] length] > 0)
            ? [NSString stringWithFormat:@"✅ 已设置（%lu 位）",
                (unsigned long)[cfg[@"decoy_passcode"] length]]
            : @"❌ 未设置（插件不生效！）"]];
    [lines addObject:[NSString stringWithFormat:@"假空间App: %@",
        [cfg[@"decoy_apps"] count] ? [cfg[@"decoy_apps"] componentsJoinedByString:@","] : @"(默认)"]];

    // ⭐ v0.1.16：退出 App（用户反馈原隐藏退出太难，改点 App 退出）
    NSString *exitID = cfg[@"decoy_exit_app"];
    if (![exitID isKindOfClass:[NSString class]]) exitID = @"settings";
    NSString *exitName = @"(未设置)";
    if (exitID.length) {
        for (NSDictionary *a in DLFakeApps()) {
            if ([a[@"id"] isEqualToString:exitID]) { exitName = a[@"name"]; break; }
        }
        if (![exitName isEqualToString:@"(未设置)"]) exitName = [exitName stringByAppendingFormat:@"(%@)", exitID];
    }
    [lines addObject:[NSString stringWithFormat:@"退出App: %@", exitName]];

    [lines addObject:[NSString stringWithFormat:@"配置文件: %@", DLPrefsConfigPath()]];
    [lines addObject:[NSString stringWithFormat:@"文件存在: %@",
        [[NSFileManager defaultManager] fileExistsAtPath:DLPrefsConfigPath()] ? @"是" : @"否"]];
    [lines addObject:@" "];
    [lines addObject:@"═══ 运行日志（最新在最后）═══"];

    // 日志太长只取尾部 —— 关心的永远是最近一次锁屏操作
    NSString *tail = raw;
    if (tail.length > 12000) {
        tail = [tail substringFromIndex:tail.length - 12000];
    }
    for (NSString *l in [tail componentsSeparatedByString:@"\n"]) {
        [lines addObject:l];
    }

    self.lines = lines;
    self.plain = [lines componentsJoinedByString:@"\n"];
    [self.tableView reloadData];

    // 自动滚到底部（最新一条）
    NSUInteger n = self.lines.count;
    if (n > 0) {
        [self.tableView scrollToRowAtIndexPath:
            [NSIndexPath indexPathForRow:(NSInteger)n - 1 inSection:0]
                              atScrollPosition:UITableViewScrollPositionBottom
                                      animated:NO];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.lines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"DLProbeCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;

        // 错误时不需要打印整行日志，所以保留等宽字体便于对齐阅读
        cell.textLabel.font = [UIFont fontWithName:@"Menlo" size:10.5]
                              ?: [UIFont systemFontOfSize:10.5];
    }
    if (ip.row < 0 || ip.row >= (NSInteger)self.lines.count) return cell;

    NSString *line = self.lines[(NSUInteger)ip.row];
    cell.textLabel.text = line;

    // 关键行着色，方便肉眼快速定位
    if ([line hasPrefix:@"═══"]) {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:11.0];
    } else if ([line containsString:@"***"] || [line containsString:@"✅"] ||
               [line containsString:@"命中"]) {
        cell.textLabel.textColor = [UIColor systemGreenColor];
        cell.textLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:10.5]
                              ?: [UIFont boldSystemFontOfSize:10.5];
    } else if ([line containsString:@"❌"] || [line containsString:@"失败"] ||
               [line containsString:@"不存在"]) {
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.font = [UIFont fontWithName:@"Menlo" size:10.5]
                              ?: [UIFont systemFontOfSize:10.5];
    } else {
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.font = [UIFont fontWithName:@"Menlo" size:10.5]
                              ?: [UIFont systemFontOfSize:10.5];
    }
    return cell;
}

- (void)copyAll {
    [UIPasteboard generalPasteboard].string = self.plain ?: @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"已复制"
                         message:@"全部诊断内容已复制到剪贴板，直接粘贴发给我即可。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 纯原生 App 选择器（不碰 PSSpecifier）

@implementation DLAppPickerController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}- (void)viewDidLoad {
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

    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - ⭐ v0.1.16 退出 App 选择器（单选，点一下即保存并返回）
// 背景：用户反馈「好难退出去」——原来的隐藏退出（标题连点 8 次 / 长按壁纸 3 秒）
// 太难记住。改成在假空间里点指定 App 直接退出，这里选是哪个 App。
//
// ⚠️ 关键一步：保存时若该 App 不在「展示的 App」列表里，**自动加进去** ——
//    否则用户选了「设置」但假空间里没显示设置，会以为功能坏了。

@implementation DLExitAppPickerController

- (NSArray *)rows {
    NSMutableArray *r = [NSMutableArray array];
    // 第 0 行 = 关闭该功能（只能用隐藏手势）
    [r addObject:@{@"id": @"", @"name": @"不设置（仅用隐藏手势退出）"}];
    for (NSDictionary *a in DLFakeApps()) {
        [r addObject:@{@"id": a[@"id"], @"name": a[@"name"]}];
    }
    return r;
}

- (NSString *)currentExitID {
    id v = DLPrefsLoad()[@"decoy_exit_app"];
    if ([v isKindOfClass:[NSString class]]) return v;
    return @"settings";      // 与插件端 DLDecoyExitApp() 的默认值保持一致
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"点哪个 App 退出";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)[self rows].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @"在假空间里点这个 App 即退出。点一下即保存（已自动勾选为显示）。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"DLExitAppCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID];
    }
    NSArray *rows = [self rows];
    if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return cell;

    NSString *ident = rows[(NSUInteger)ip.row][@"id"];
    cell.textLabel.text = rows[(NSUInteger)ip.row][@"name"];
    cell.accessoryType = [ident isEqualToString:[self currentExitID]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *rows = [self rows];
    if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return;

    NSString *ident = rows[(NSUInteger)ip.row][@"id"];
    NSMutableDictionary *cfg = DLPrefsLoad();
    cfg[@"decoy_exit_app"] = ident;

    // ⚠️ 自动把选中的 App 加进展示列表 —— 否则假空间里根本看不到它
    if (ident.length) {
        NSArray *cur = cfg[@"decoy_apps"];
        if (![cur isKindOfClass:[NSArray class]] || !cur.count) cur = DLDefaultSelection();
        if (![cur containsObject:ident]) {
            NSMutableArray *ordered = [NSMutableArray array];
            for (NSDictionary *a in DLFakeApps()) {
                NSString *aid = a[@"id"];
                if ([aid isEqualToString:ident] || [cur containsObject:aid]) {
                    [ordered addObject:aid];
                }
            }
            cfg[@"decoy_apps"] = ordered;
        }
    }

    DLPrefsSave(cfg);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - 纯原生文本编辑页（替代 PSTextFieldSpecifier）
// ⚠️ 布局用 NSLayoutConstraint 锚定 safeArea —— 绝不在 viewDidLoad 里用
//    self.view.bounds 算固定坐标（那时布局未完成，会跑出屏幕，用户实测「大小不对」）

@implementation DLTextEditController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.cfgTitle ?: @"编辑";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];

    id hint = self.numericOnly ? @"4~8 位纯数字" : nil;

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectZero];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    if (self.numericOnly) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.secureTextEntry = YES;
    }
    tf.text = DLPrefsLoad()[self.cfgKey] ?: @"";
    self.textField = tf;
    [self.view addSubview:tf];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
    lb.text = hint;
    lb.font = [UIFont systemFontOfSize:13.0];
    lb.textColor = [UIColor secondaryLabelColor];
    lb.hidden = (hint == nil);
    [self.view addSubview:lb];

    tf.translatesAutoresizingMaskIntoConstraints = NO;
    lb.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [tf.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [tf.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [tf.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [tf.heightAnchor constraintEqualToConstant:44],
        [lb.topAnchor constraintEqualToAnchor:tf.bottomAnchor constant:8],
        [lb.leadingAnchor constraintEqualToAnchor:tf.leadingAnchor],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(viewTapped)];
    [self.view addGestureRecognizer:tap];

    [tf becomeFirstResponder];
}

- (void)viewTapped {
    [self.view endEditing:YES];
}

- (void)save {
    NSString *v = self.textField.text ?: @"";
    if (self.numericOnly) {
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

@end
