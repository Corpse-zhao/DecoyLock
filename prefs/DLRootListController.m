#import "DLRootListController.h"
#import <notify.h>

// ---------------------------------------------------------------------------
// 设置面板（运行在「设置」App 进程，不受沙盒限制）
// 配置写共享目录 /var/mobile/Documents/伪锁屏/_config.plist + NSUserDefaults(suite)
// ---------------------------------------------------------------------------

static NSString *const kDLDomain = @"com.blr.decoylock";

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

#pragma mark - 前向声明（类扩展须写在所有实现之前）

@interface DLAppPickerController ()
@property (nonatomic, strong) NSArray *apps;
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

// 首次进入时把推荐默认值落盘（避免插件读到空配置）
- (void)migrateDefaultsIfNeeded {
    NSMutableDictionary *cfg = DLPrefsLoad();
    BOOL changed = NO;
    if (!cfg[@"decoy_title"])  { cfg[@"decoy_title"] = @"我的 iPhone"; changed = YES; }
    if (!cfg[@"decoy_apps"]) {
        cfg[@"decoy_apps"] = @[@"phone", @"message", @"camera", @"settings"];
        changed = YES;
    }
    if (!cfg[@"enabled"])      { cfg[@"enabled"] = @NO; changed = YES; }
    if (changed) DLPrefsSave(cfg);
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    NSDictionary *cfg = DLPrefsLoad();
    id v = cfg[key];
    if (v) return v;

    // 兜底：Plist 里声明的 default
    id def = [spec propertyForKey:@"default"];
    return def;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key.length) return;
    NSMutableDictionary *cfg = DLPrefsLoad();
    cfg[key] = value;
    DLPrefsSave(cfg);

    // 伪密码改动 → 清一次诊断日志，方便对照
    if ([key isEqualToString:@"decoy_passcode"]) {
        [[NSFileManager defaultManager] removeItemAtPath:DLPrefsProbePath() error:NULL];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"伪锁屏";
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

    // 诊断里补上「配置当前状态」，一行看清问题出在哪
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

@end

#pragma mark - 假 App 选择器

@implementation DLAppPickerController

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier new];
    [group setValue:@"勾选后显示在假空间里。点右上角「完成」保存。" forKey:@"footerText"];
    [group setValue:@"假空间 App" forKey:@"label"];
    [specs addObject:group];

    for (NSDictionary *a in DLFakeApps()) {
        PSSpecifier *s = [PSSpecifier new];
        [s setValue:a[@"name"] forKey:@"label"];
        [s setValue:a[@"id"] forKey:@"appid"];
        [s setValue:( [self.selected containsObject:a[@"id"]] ? @1 : @0 ) forKey:@"checked"];
        [specs addObject:s];
    }

    _specifiers = specs;
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"假空间 App";

    NSMutableDictionary *cfg = DLPrefsLoad();
    NSArray *cur = cfg[@"decoy_apps"];
    if (![cur isKindOfClass:[NSArray class]] || !cur.count) {
        cur = @[@"phone", @"message", @"camera", @"settings"];
    }
    self.selected = [NSMutableSet setWithArray:cur];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(save)];
}

- (void)save {
    NSMutableDictionary *cfg = DLPrefsLoad();
    NSArray *ordered = [self.apps orderWithSelection:self.selected];
    cfg[@"decoy_apps"] = ordered;
    DLPrefsSave(cfg);
    [self.navigationController popViewControllerAnimated:YES];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [super tableView:tv cellForRowAtIndexPath:ip];
    if (ip.section == 0 && ip.row > 0) {
        NSInteger idx = ip.row - 1;
        NSArray *all = DLFakeApps();
        if (idx < (NSInteger)all.count) {
            NSString *ident = all[(NSUInteger)idx][@"id"];
            BOOL on = [self.selected containsObject:ident];
            cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (ip.section == 0 && ip.row == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0 || ip.row == 0) return;
    NSInteger idx = ip.row - 1;
    NSArray *all = DLFakeApps();
    if (idx < 0 || idx >= (NSInteger)all.count) return;
    NSString *ident = all[(NSUInteger)idx][@"id"];

    if ([self.selected containsObject:ident]) [self.selected removeObject:ident];
    else                                     [self.selected addObject:ident];

    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSArray *)apps {
    return DLFakeApps();
}

@end

// NSArray 的便捷排序（保持内置清单顺序，不按勾选顺序）
@implementation NSArray (DLOrder)
- (NSArray *)orderWithSelection:(NSSet *)sel {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *a in DLFakeApps()) {
        if ([sel containsObject:a[@"id"]]) [out addObject:a[@"id"]];
    }
    return out;
}
@end
