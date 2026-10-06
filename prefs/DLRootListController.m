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

// ⭐ v0.1.19：面板自己的版本号（与 control / Info.plist 保持一致）。
//    ⚠️ 必须手写在这里 —— prefs bundle 不加载插件 dylib，
//       拿不到 DLCommon.h 里的 DL_VERSION。
//    诊断页会拿它跟「插件启动横幅」里的版本对比，
//    一眼看出 SpringBoard 里跑的到底是不是新版。
static NSString *const kDLPrefsVersion = @"0.1.20";

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

// ---------------------------------------------------------------------------
// ⚠️ 设置进程里**不能**用插件的 DLProbe（那个实现在 DecoyLock.dylib 里，
//    「设置」进程根本不加载它 → 链接不到）。这里自己写一份，格式与插件端一致，
//    这样两边日志都落在同一个 _probe.txt 里，排查时一眼能对上时间线。
// ---------------------------------------------------------------------------
// ⭐ v0.1.18a：加 NS_FORMAT_FUNCTION(1,2) —— 让编译器像检查 NSLog 一样检查这里的
//    格式串（字面 % 必须写 %%）。多一道编译期防线，避免写出会崩的日志调用。
static void DLPrefsLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void DLPrefsLog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@ (pid %d)\n",
                      [df stringFromDate:[NSDate date]], body, (int)getpid()];

    NSString *path = DLPrefsProbePath();
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    }
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
// ⭐ v0.1.19：这一个页面同时管两件事（两节）
//   第 0 节 = 勾选「假空间里显示哪些 App」
//   第 1 节 = 单选「点哪个 App 退出」
//   合并的原因：单独给退出选择器做一行 PSLinkCell / PSMultiValueSpecifier 都点不动
//   （v0.1.16 手搓控制器点不了、v0.1.18 换 PSMultiValueSpecifier 还是点不了，
//    用户实测两轮都一样）。而这个页面是**已经验证能正常打开、能正常点击**的，
//    把设置项挂进已验证的页面里，是唯一稳妥的做法。
//   入口传 focusExitSection=YES 即从「退出」侧进入（v0.1.20 起该入口是个按钮行）。
@property (nonatomic, assign) BOOL focusExitSection;   // 从「选择退出用的 App」进来时滚动到第 1 节
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

    // ⭐ v0.1.18：换了退出 App → 自动把它加进「显示的 App」列表。
    // 否则用户选了「设置」但假空间里没显示设置，会以为功能坏了。
    if ([key isEqualToString:@"decoy_exit_app"]) {
        DLPrefsLog(@"[设置] 退出App 改为「%@」", value);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
            NSArray *cur = cfg[@"decoy_apps"];
            if (![cur isKindOfClass:[NSArray class]] || !cur.count) cur = DLDefaultSelection();
            if (![cur containsObject:value]) {
                NSMutableArray *ordered = [NSMutableArray array];
                for (NSDictionary *a in DLFakeApps()) {
                    NSString *aid = a[@"id"];
                    if ([aid isEqualToString:value] || [cur containsObject:aid]) {
                        [ordered addObject:aid];
                    }
                }
                cfg[@"decoy_apps"] = ordered;
                DLPrefsLog(@"[设置] 已把「%@」自动加入显示列表（共 %lu 个）",
                           value, (unsigned long)ordered.count);
            }
        }
    }

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

// ⚠️ 前置声明：DLDoRespring 的实现在文件下方（要用到 proc_listpids）。
//    不声明就调用 → C 的隐式声明把返回值当 int（实测 ObjC 下仅是警告，
//    所以 v0.1.16 侥幸编译通过）。但这是真隐患：万一哪天函数改成返回指针，
//    隐式 int 会把 64 位指针截成 32 位 → 崩溃。显式声明掉。
static void DLDoRespring(void);

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
    DLPrefsLog(@"[设置] ✅ 点中「选择要显示的 App」（action 已触发）");
    DLAppPickerController *vc = [[DLAppPickerController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

// ⭐⭐ v0.1.20：第三次返工 —— 改用**与「重启桌面生效 / 查看运行诊断」完全同款**的
//      `PSButtonCell` + **无参** action。
//
//     为什么是这套：
//     - 用户实测「重启桌面生效」「查看运行诊断」「清除诊断日志」这三个按钮**都能点**，
//       它们就是 PSButtonCell + 无参 action（`respring` / `showProbe` / `clearProbe`）。
//     - 而「选择要显示的 App」「设置伪密码」是 PSLinkCell + 带参 selector，也能点。
//     - 唯独「点哪个 App 退出」这一行，先后用过
//         v0.1.16 自建控制器（detail 键）        → 点不动 / 闪退
//         v0.1.18 PSMultiValueSpecifier          → 点不动
//         v0.1.19 PSLinkCell + 带参 action       → 点不动
//       三种写法都失败，且 v0.1.19 的 plist 定义与**同页能用的那一行逐字段完全一致**
//       （已逐字段 dump 比对）—— 静态代码层面无法定位。
//       既然如此，就换成**在用户本机已被证明可用**的那一套（PSButtonCell + 无参 action），
//       不再赌第四种写法。
//
//     另外这里带了两道自检日志：
//       ① 进入方法即写日志 → 能确证 action 到底有没有被触发；
//       ② push 前检查 navigationController，为 nil 就退回 present，
//          避免「action 触发了但 push 不出去」造成的静默失败。
- (void)dlPickExitApp {
    DLPrefsLog(@"[设置] ✅ 点中「选择退出用的 App」（action 已触发）");

    DLAppPickerController *vc = [[DLAppPickerController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    vc.focusExitSection = YES;      // 进来直接滚到「退出 App」那一节

    UINavigationController *nav = self.navigationController;
    DLPrefsLog(@"[设置] navigationController = %@", nav ? @"存在" : @"nil(!)");
    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        // 兜底：拿不到导航栈就直接模态呈现，绝不静默失败
        DLPrefsLog(@"[设置] ⚠️ 导航栈不可用 → 改用 present 呈现");
        [self presentViewController:vc animated:YES completion:nil];
    }
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

    // ⭐⭐⭐ v0.1.19：**版本自检**（放最最前面）
    //   这是排查「装了新版却没生效」的唯一可靠手段 ——
    //   从探针里找插件启动时写的横幅，拿到 SpringBoard 里真正在跑的版本号。
    //   面板版本 = prefs bundle 版本（每次打开设置都是新的）；
    //   运行版本 = 插件 dylib 版本（只有重启桌面才会更新）。
    //   两者不一致 → 100% 是「装了新版但没重启桌面」，不用再猜。
    {
        NSString *runningVer = @"(未检测到)";
        for (NSString *ln in [raw componentsSeparatedByString:@"\n"]) {
            if ([ln rangeOfString:@"DecoyLock"].location == NSNotFound) continue;
            if ([ln rangeOfString:@"启动"].location == NSNotFound) continue;
            NSRange r = [ln rangeOfString:@"DecoyLock "];
            if (r.location == NSNotFound) continue;
            NSString *tail = [ln substringFromIndex:NSMaxRange(r)];
            NSRange sp = [tail rangeOfString:@" "];
            runningVer = (sp.location == NSNotFound)
                ? [tail stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                : [tail substringToIndex:sp.location];
            break;
        }

        BOOL same = [runningVer isEqualToString:kDLPrefsVersion];
        if (same) {
            [lines addObject:[NSString stringWithFormat:
                @"版本: 面板 %@ ／ 插件 %@ ✅ 一致", kDLPrefsVersion, runningVer]];
        } else {
            [lines addObject:@"⚠️⚠️ 版本不一致 —— 插件没生效的直接原因 ⚠️⚠️"];
            [lines addObject:[NSString stringWithFormat:
                @"  面板版本 = %@（设置页是新版）", kDLPrefsVersion]];
            [lines addObject:[NSString stringWithFormat:
                @"  插件版本 = %@（SpringBoard 里跑的）", runningVer]];
            [lines addObject:@"  → 说明装了新版但 SpringBoard 还在跑旧代码。"];
            [lines addObject:@"  → 修法：点上面「重启桌面生效」，或手动 respring。"];
        }
        [lines addObject:@""];
    }

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
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.focusExitSection ? @"选择退出用的 App" : @"假空间 App 与退出";
    DLPrefsLog(@"[设置] App 选择页已打开（focusExitSection=%d）", (int)self.focusExitSection);

    NSMutableDictionary *cfg = DLPrefsLoad();
    NSArray *cur = cfg[@"decoy_apps"];
    if (![cur isKindOfClass:[NSArray class]] || !cur.count) cur = DLDefaultSelection();
    self.selected = [NSMutableSet setWithArray:cur];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(save)];

    // ⭐ v0.1.19：点「点哪个 App 退出」进来时，自动滚到第 1 节，
    //    免得用户以为打开错了页面。
    if (self.focusExitSection && [self respondsToSelector:@selector(tableView)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:1];
            if ([self.tableView numberOfSections] > 1 &&
                [self.tableView numberOfRowsInSection:1] > 0) {
                [self.tableView scrollToRowAtIndexPath:ip
                                      atScrollPosition:UITableViewScrollPositionMiddle
                                              animated:NO];
            }
        });
    }
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

#pragma mark - 数据源

// 第 0 节 = 显示的 App（勾选）；第 1 节 = 点哪个 App 退出（单选）
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return (NSInteger)DLFakeApps().count;
    return (NSInteger)DLFakeApps().count + 1;   // ⭐ 第 1 节第 0 行 = 「不设置」
}

// ⭐ 第 1 节的「第 n 行 → App 标识」：第 0 行固定是空串（= 不设置，只能用隐藏手势）
- (NSString *)exitRowIdent:(NSInteger)row {
    if (row <= 0) return @"";
    NSInteger idx = row - 1;
    NSArray *all = DLFakeApps();
    if (idx >= (NSInteger)all.count) return nil;
    return all[(NSUInteger)idx][@"id"];
}

- (NSString *)exitRowName:(NSInteger)row {
    if (row <= 0) return @"不设置（仅用隐藏手势退出）";
    NSInteger idx = row - 1;
    NSArray *all = DLFakeApps();
    if (idx >= (NSInteger)all.count) return @"?";
    return all[(NSUInteger)idx][@"name"];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"勾选后显示在假空间里，点右上角「完成」保存";
    return @"在假空间里点下面这个 App 即退出（点一下即生效）";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) {
        return @"⚠️ 建议选「设置」或某个你不常用的 App。"
                "如果它没被勾选为显示，选中后会自动加入显示列表。";
    }
    return nil;
}

- (NSString *)currentExitID {
    id v = DLPrefsLoad()[@"decoy_exit_app"];
    if ([v isKindOfClass:[NSString class]]) return v;
    return @"settings";      // 与插件端 DLDecoyExitApp() 的默认值保持一致
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellID = @"DLAppPickerCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellID];
    }
    cell.textLabel.textColor = [UIColor labelColor];

    if (ip.section == 0) {
        NSArray *all = DLFakeApps();
        if (ip.row < 0 || ip.row >= (NSInteger)all.count) return cell;
        NSString *ident = all[(NSUInteger)ip.row][@"id"];
        cell.textLabel.text = all[(NSUInteger)ip.row][@"name"];
        cell.accessoryType = [self.selected containsObject:ident]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        NSString *ident = [self exitRowIdent:ip.row];
        if (ident == nil) return cell;
        cell.textLabel.text = [self exitRowName:ip.row];
        cell.accessoryType = [ident isEqualToString:[self currentExitID]]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}

#pragma mark - 点击

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) {
        // 第 0 节：切勾选状态（保存时统一落盘）
        NSArray *all = DLFakeApps();
        if (ip.row < 0 || ip.row >= (NSInteger)all.count) return;
        NSString *ident = all[(NSUInteger)ip.row][@"id"];
        if ([self.selected containsObject:ident]) [self.selected removeObject:ident];
        else                                      [self.selected addObject:ident];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    // ⭐ 第 1 节：选「点哪个 App 退出」—— 点一下**立即保存**，
    //    不依赖「完成」按钮（少一个可能失效的环节）。
    NSString *ident = [self exitRowIdent:ip.row];
    if (ident == nil) return;

    NSMutableDictionary *cfg = DLPrefsLoad();
    cfg[@"decoy_exit_app"] = ident;

    // 自动把它加进显示列表 —— 否则假空间里根本看不到它，用户会以为功能坏了
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
            self.selected = [NSMutableSet setWithArray:ordered];
        }
    }
    DLPrefsSave(cfg);
    DLPrefsLog(@"[设置] 退出 App 已改为「%@」（id=%@）",
               [self exitRowName:ip.row], ident.length ? ident : @"(空)");

    [tv reloadSections:[NSIndexSet indexSetWithIndex:1]
      withRowAnimation:UITableViewRowAnimationNone];
    [tv reloadSections:[NSIndexSet indexSetWithIndex:0]
      withRowAnimation:UITableViewRowAnimationNone];
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
