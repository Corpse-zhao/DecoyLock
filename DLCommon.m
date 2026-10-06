#import "DLCommon.h"
#import <notify.h>

// ---------------------------------------------------------------------------
// 共享目录：/var/mobile/Documents/伪锁屏/
// SpringBoard 进程（越狱环境未受沙盒约束）与「设置」进程都写这里。
// 同时把配置写一份到 NSUserDefaults(suite)，读取时以文件为准。
// ---------------------------------------------------------------------------

NSString *DLSharedDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = @"/var/mobile/Documents";
        if (![[NSFileManager defaultManager] fileExistsAtPath:base]) {
            base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES).firstObject;
        }
        dir = [base stringByAppendingPathComponent:@"伪锁屏"];
    });
    return dir;
}

static void DLEnsureDir(void) {
    NSString *d = DLSharedDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:d isDirectory:&isDir] && isDir) return;
    [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    // Filza 友好：允许 mobile 读写
    [fm setAttributes:@{NSFilePosixPermissions: @(0777)} ofItemAtPath:d error:NULL];
}

NSString *DLConfigPath(void) {
    return [DLSharedDir() stringByAppendingPathComponent:@"_config.plist"];
}

NSString *DLProbePath(void) {
    return [DLSharedDir() stringByAppendingPathComponent:@"_probe.txt"];
}

// ------------------------------ 配置读写 ------------------------------

NSDictionary *DLConfigAll(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // 1) NSUserDefaults(suite) 打底（「设置」进程写这里最方便）
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:DL_PREFS_DOMAIN];
    NSDictionary *snap = [d dictionaryRepresentation];
    if (snap.count) [out addEntriesFromDictionary:snap];

    // 2) 共享文件覆盖（插件侧权威）
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:DLConfigPath()];
    if (file.count) [out addEntriesFromDictionary:file];

    return out;
}

id DLConfigGet(NSString *key) {
    if (!key.length) return nil;
    return DLConfigAll()[key];
}

void DLConfigSet(NSString *key, id value) {
    if (!key.length) return;
    DLEnsureDir();

    // 写共享文件（读-改-写）
    NSMutableDictionary *cfg =
        [NSMutableDictionary dictionaryWithContentsOfFile:DLConfigPath()] ?: [NSMutableDictionary dictionary];
    if (value) cfg[key] = value; else [cfg removeObjectForKey:key];
    [cfg writeToFile:DLConfigPath() atomically:YES];

    // 同步写 NSUserDefaults
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:DL_PREFS_DOMAIN];
    if (value) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
    [d synchronize];
}

void DLPostPrefsChanged(void) {
    notify_post("com.blr.decoylock/prefschanged");
}

// ------------------------------ 便捷读取 ------------------------------

static BOOL DLBoolValue(NSString *key, BOOL def) {
    id v = DLConfigGet(key);
    if (!v) return def;
    return [v boolValue];
}

static NSString *DLStringValue(NSString *key, NSString *def) {
    id v = DLConfigGet(key);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return def;
}

BOOL DLEnabled(void) {
    return DLBoolValue(@"enabled", NO);   // 默认关闭：未配置密码前不干预锁屏
}

NSString *DLDecoyPasscode(void) {
    return DLStringValue(@"decoy_passcode", @"");
}

NSString *DLDecoyTitle(void) {
    return DLStringValue(@"decoy_title", @"我的 iPhone");
}

NSString *DLDecoySubtitle(void) {
    return DLStringValue(@"decoy_subtitle", @"");
}

NSArray *DLAllFakeApps(void) {
    // 内置可选假 App：identifier, 显示名, SF Symbol 名, 角标
    return @[
        @{@"id": @"phone",   @"name": @"电话",   @"icon": @"phone.fill"},
        @{@"id": @"message", @"name": @"信息",   @"icon": @"message.fill"},
        @{@"id": @"mail",    @"name": @"邮件",   @"icon": @"envelope.fill"},
        @{@"id": @"safari",  @"name": @"Safari", @"icon": @"safari.fill"},
        @{@"id": @"camera",  @"name": @"相机",   @"icon": @"camera.fill"},
        @{@"id": @"photos",  @"name": @"照片",   @"icon": @"photo.fill"},
        @{@"id": @"notes",   @"name": @"备忘录", @"icon": @"note.text"},
        @{@"id": @"calendar",@"name": @"日历",   @"icon": @"calendar"},
        @{@"id": @"clock",   @"name": @"时钟",   @"icon": @"clock.fill"},
        @{@"id": @"weather", @"name": @"天气",   @"icon": @"cloud.sun.fill"},
        @{@"id": @"settings",@"name": @"设置",   @"icon": @"gearshape.fill"},
        @{@"id": @"maps",    @"name": @"地图",   @"icon": @"map.fill"},
        @{@"id": @"music",   @"name": @"音乐",   @"icon": @"music.note"},
        @{@"id": @"wallet",  @"name": @"钱包",   @"icon": @"creditcard.fill"},
        @{@"id": @"files",   @"name": @"文件",   @"icon": @"folder.fill"},
        @{@"id": @"health",  @"name": @"健康",   @"icon": @"heart.fill"},
    ];
}

NSArray *DLDecoyApps(void) {
    id v = DLConfigGet(@"decoy_apps");
    if ([v isKindOfClass:[NSArray class]] && [(NSArray *)v count]) return v;
    // 默认：电话 / 信息 / 相机 / 设置
    return @[@"phone", @"message", @"camera", @"settings"];
}

// ⭐ v0.1.16：假空间里的「退出 App」
// 用户反馈「好难退出去」（连点 8 次 / 长按 3 秒太隐蔽），改成点这个 App 直接退出。
// 默认 "settings"（设置）—— 用户最可能记得住的入口。
// 返回空串表示「不设置」，此时只能用隐藏手势退出。
NSString *DLDecoyExitApp(void) {
    id v = DLConfigGet(@"decoy_exit_app");
    if ([v isKindOfClass:[NSString class]]) return v;   // 允许空串 = 明确关闭
    return @"settings";
}

// ------------------------------ 探针 ------------------------------

static NSString *DLTimestamp(void) {
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    return [df stringFromDate:[NSDate date]];
}

void DLProbe(NSString *fmt, ...) {
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    DLEnsureDir();
    NSString *line = [NSString stringWithFormat:@"[%@] %@ (pid %d)\n",
                      DLTimestamp(), body, (int)getpid()];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = DLProbePath();
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    // 512KB 封顶：超了就整份重写，避免无限增长（本项目踩过 253MB 的坑）
    unsigned long long size = [[fm attributesOfItemAtPath:path error:NULL] fileSize];
    if (size > 512 * 1024) {
        [data writeToFile:path atomically:YES];
        return;
    }
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}

NSString *DLProbeRead(void) {
    NSString *s = [NSString stringWithContentsOfFile:DLProbePath()
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    return s ?: @"";
}

void DLProbeClear(void) {
    [[NSFileManager defaultManager] removeItemAtPath:DLProbePath() error:NULL];
}

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.22：暂停 / 恢复 Face ID 匹配
//
// 用户实测：输伪密码后假空间铺上去了，系统也没判错，但真机仍被 Face ID 解开
// （用户感知 = 「还是要刷脸」；退出假空间后直接落在真桌面）。
//
// 做法：SpringBoard 里有个 SBUIBiometricResource（生物识别资源），
// 关掉它的 matchingEnabled 即可让锁屏不再自动尝试 Face ID。
//
// ⚠️ 安全约束（必须严格遵守）：
//    1. 全程 respondsToSelector 保护 —— 不同 iOS 版本类名/方法可能不同，
//       拿不到就**静默跳过**，只写一行日志，绝不崩、绝不强改。
//    2. 只在假空间存在期间关闭；一旦拆除**必须恢复**（两条拆除路径都会调）。
//    3. ⭐ 幂等：状态没变就不重复调系统 API ——
//       否则重建窗口时会「恢复→暂停」抖动一次，那一瞬间 Face ID 真的会去匹配。
// ---------------------------------------------------------------------------

// 我们当前是否处于「已暂停生物识别匹配」的状态（供兜底守护查询）
static BOOL sBioMatchingOff = NO;

// 注：v0.2.1 曾引入 sBioWasMatching / sBioWasMatchingValid（记录干预前系统是否在匹配），
// 但 v0.2.2 改成运行时侦查后没有用到它们 —— 留着会被 -Werror,-Wunused-variable 拦下编译。
// 现在「系统原本开不开匹配」这件事由 sBioMatchingOff 的幂等状态 + DLResumeBiometric()
// 的显式恢复保证，不需要额外的基线记录。故已删除。

BOOL DLBiometricMatchingIsOff(void) { return sBioMatchingOff; }

// ⭐⭐⭐ v0.2.2 重做：Face ID 临时停用（**运行时自动侦查**，不再手写候选清单）
//
// 🔥 v0.2.0 血泪：只试了 `SBUIBiometricResource -setMatchingEnabled:` 一条路，
//    真机日志一路 `实例不支持 setMatchingEnabled: → 跳过（不干预）`
//    → **暂停从未生效过**，刷脸自然一直在（v0.1.22/v0.1.23 的努力全白费）。
//
// 🔥🔥 v0.2.1 血泪：我改成手写「2 个类 × 3 个方法名」的候选清单，
//    真机日志：`⚠️ 所有候选路径都没命中（类=SBUIBiometricEventMonitor,
//    SBUIBiometricResource；方法=_setMatchingEnabled:,setMatchingEnabled:,
//    setMatchingEnabledForFaceID:）→ 无法干预生物识别`
//    → **手写清单 = 我在猜**；猜错了就永远命不中，而且下一轮还得继续猜。
//
// 🔥🔥🔥 v0.2.2 正解：**让运行时自己告诉我有哪些类、哪些方法**，然后按语义挑。
//    ① objc_getClassList 枚举所有已注册类，筛类名含 "Biometric" 的；
//    ② 在它们身上取 sharedInstance / manager / delegate 等实例；
//    ③ 沿**继承链**找「名字含 Matching/Enabled/Match 且以 : 结尾」的实例方法（setter）；
//    ④ 逐个 respondsToSelector 后调用；
//    ⑤ **把侦查结果写进日志** —— 无论成功失败，下一轮都不用再猜。
//
// 已知线索（theapplewiki.com Dev:BiometricKit.framework）：
//   manager = [objc_getClass("BiometricKit") manager];
//   SBUIBiometricEventMonitor *m = manager.delegate;   // ← 匹配开关在它身上
//   [m _setMatchingEnabled:NO];                        // 停：不再发起匹配
//   侦查逻辑天然覆盖这条路径（"BiometricKit" 含 "Biometric"；delegate 会被展开）。
//
// ⚠️ 依旧全程 respondsToSelector 显式探测 —— 不存在的类/方法直接 msgSend 是崩溃级风险。

// ---------------------------------------------------------------------------
// ⭐⭐⭐ v0.2.3：候选选择器「语义打分」
//
// 🔥 v0.2.2 血泪（真机日志实锤）：侦查成功了，但**选错了方法**。
//    日志：
//      [FaceID][侦查] 共找到 14 条候选 setter 路径
//      [FaceID] 已暂停生物识别匹配 → 命中路径 CSBiometricMatchMonitor -getBiometricMatchResultForTriggerTimeStamp:
//    这是一条**取值器**（查询匹配结果），对 Face ID 没有任何影响；
//    紧接着系统日志就出现了 `passcodeLockViewPasscodeEnteredViaMesa:`（Mesa = Face ID 代号）
//    → 照样刷脸。**「筛选到了」不等于「选对了」。**
//
//    根因：v0.2.2 的筛选条件是「以 : 结尾 + 名字含 Match」——
//    `getBiometricMatchResultForTriggerTimeStamp:` 恰好也带一个参数，于是混进了候选，
//    又因为「谁先枚举到就调谁」，第一个类的取值器就被选中了。
//
// 打分规则（越高越优先，<=0 直接淘汰）：
//   +100  「匹配断言」机制 —— **这才是 iOS 16 的真实开关**（见下面真机证据）
//   +90   setMatchingEnabled: / _setMatchingEnabled:（旧思路，本机不存在但留着兼容）
//   +60   其它「使能/开关」语义（Enable/Disable/Toggle）
//   +30   其它带 Match/Matching 的动词
//   -100  取值器（get / _get / is / has 开头，或结果类名词 Result/Event/Info/State）
//
// 真机证据（v0.2.2 日志，SBUIBiometricResource 上真实存在的方法）：
//   _addMatchingAssertion:          ← 加一个「要求匹配」的断言
//   _removeMatchingAssertion:       ← 移除它 = 不再要求匹配
//   acquireMatchingAssertionWithMode:reason:
//   _activateMatchAssertion: / resumeMatchingForAssertion:advisory:
//   → **停 Face ID 的正确姿势是「移除匹配断言」，不是「调 setter 传 NO」**。
// ---------------------------------------------------------------------------
static int DLBioScoreSelector(Class icls, NSString *sel) {
    if (!sel.length) return 0;
    NSString *clsName = NSStringFromClass(icls) ?: @"";

    // ---- ① 淘汰取值器 ----
    // 取值器的特征：以 get/is/has 开头（getLastBiometricMatchEvent:atTime: 等），
    // 或名字里出现「结果/事件/信息/状态」这类名词（getBiometricMatchResultForTriggerTimeStamp:）。
    if ([sel hasPrefix:@"get"] || [sel hasPrefix:@"_get"] ||
        [sel hasPrefix:@"is"]  || [sel hasPrefix:@"has"]) {
        return -100;
    }
    for (NSString *noun in @[@"Result", @"Event", @"Info", @"State", @"Status",
                             @"TimeStamp", @"Timestamp"]) {
        if ([sel rangeOfString:noun].location != NSNotFound) return -100;
    }

    int score = 10;

    // ---- ② 匹配断言机制（本机真实开关）----
    if ([sel rangeOfString:@"Assertion"].location != NSNotFound) {
        score = 100;
        // 「移除断言」= 直接达成「不匹配」→ 最优先
        if ([sel hasPrefix:@"_remove"] || [sel hasPrefix:@"remove"]) score = 130;
        // 「加断言」需要传参数，语义不明确 → 略微降级，但仍高于普通 setter
        if ([sel hasPrefix:@"_add"] || [sel hasPrefix:@"add"]) score = 110;
    }
    // ---- ③ 经典 setter（旧思路，兼容其它 iOS 版本）----
    else if ([sel rangeOfString:@"MatchingEnabled"].location != NSNotFound ||
             [sel rangeOfString:@"setMatchingEnabled"].location != NSNotFound) {
        score = 90;
    }
    // ---- ④ 其它「使能/开关」语义 ----
    else if ([sel rangeOfString:@"Enable"].location != NSNotFound ||
             [sel rangeOfString:@"Disable"].location != NSNotFound ||
             [sel rangeOfString:@"Toggle"].location != NSNotFound) {
        score = 60;
    }
    // ---- ⑤ 其它匹配相关动词（resume/prearm/…）----
    else if ([sel rangeOfString:@"Match"].location != NSNotFound ||
             [sel rangeOfString:@"Matching"].location != NSNotFound) {
        // 「resume（恢复匹配）」方向相反，降级；「prearm（预匹配）」也是开启方向
        if ([sel rangeOfString:@"Resume"].location != NSNotFound ||
            [sel rangeOfString:@"resume"].location != NSNotFound ||
            [sel rangeOfString:@"prearm"].location != NSNotFound) {
            score = 15;
        } else {
            score = 30;
        }
    }

    // ---- ⑥ 类名加权：真正的「资源/控制器」比「监控器/日志器」更可能是开关持有者 ----
    if ([clsName rangeOfString:@"Resource"].location != NSNotFound) score += 20;
    if ([clsName rangeOfString:@"Monitor"].location != NSNotFound)  score -= 10;
    if ([clsName rangeOfString:@"Logger"].location != NSNotFound)   score -= 20;

    return score;
}

// ---------------------------------------------------------------------------
// ⭐⭐⭐ v0.2.2：运行时侦查的「实例解析」统一入口
//
// 给定 (类名, 实例类名)，返回**候选实例列表**（含单例本身 + 其 delegate）。
// 侦查阶段和调用阶段**共用这一个函数** —— 这是刻意的：
//   如果两边各解析一次，就可能「侦查时看到 setter，调用时却拿不到那个对象」，
//   出现「日志说找到了却没调成」的鬼故事。共用 = 两边必然一致。
// ---------------------------------------------------------------------------
static NSArray<id> *DLBioInstancesFor(NSString *ownerClassName, NSString *instClassName) {
    Class c = objc_getClass(ownerClassName.UTF8String);
    if (!c) return @[];

    NSMutableArray<id> *insts = [NSMutableArray array];
    for (NSString *sing in @[@"sharedInstance", @"manager", @"sharedManager",
                             @"sharedConnection"]) {
        SEL s = NSSelectorFromString(sing);
        if (![c respondsToSelector:s]) continue;
        id v = ((id (*)(id, SEL))objc_msgSend)(c, s);
        if (v) [insts addObject:v];
    }
    // delegate 也要看（BiometricKit.manager.delegate == SBUIBiometricEventMonitor）
    for (id inst in [insts copy]) {
        SEL dsel = NSSelectorFromString(@"delegate");
        if (![inst respondsToSelector:dsel]) continue;
        id d = ((id (*)(id, SEL))objc_msgSend)(inst, dsel);
        if (d) [insts addObject:d];
    }

    // 若给了期望的实例类名，把匹配的排到前面（优先在「当初发现 setter 的那个类」上调用）
    if (instClassName.length) {
        [insts sortUsingComparator:^NSComparisonResult(id a, id b) {
            BOOL ma = [NSStringFromClass([a class]) isEqualToString:instClassName];
            BOOL mb = [NSStringFromClass([b class]) isEqualToString:instClassName];
            if (ma == mb) return NSOrderedSame;
            return ma ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    return insts;
}

void DLSetBiometricMatching(BOOL enabled) {
    // ⭐ 幂等短路：状态没变直接返回（不重复调系统 API，避免匹配抖动）
    if (enabled && !sBioMatchingOff) return;
    if (!enabled && sBioMatchingOff) return;

    BOOL want = enabled;                       // 目标状态
    BOOL wantOff = !enabled;

    // ⭐⭐⭐ v0.2.2：**不再手写候选清单**，改为「运行时自动侦查」。
    //
    // 血泪：v0.2.1 我手写了 2 个类 × 3 个方法名，真机日志说「所有候选路径都没命中」。
    //   手写清单 = 我在猜；猜错了就永远命不中，而且下一轮还得继续猜。
    //   正解 = **让运行时自己告诉我有哪些类、哪些方法**，然后按语义挑。
    //
    // 做法：
    //   ① 枚举所有已注册类，筛出类名含 "Biometric" 的（BiometricKit / SBUIBiometric* 等）；
    //   ② 取 sharedInstance / manager 之类的单例；
    //   ③ 在该单例及其 delegate 上，找出所有「名字里含 Matching/Enabled 且以 : 结尾」的方法；
    //   ④ 直接调它。
    //   ⑤ 把**侦查到的东西**写进日志 —— 无论成功失败，下一轮都不用再猜。
    static NSMutableArray<NSString *> *sBioSetters = nil;   // 命中的 (类名, 选择器) 组合
    static BOOL sBioReconDone = NO;

    if (!sBioReconDone) {
        sBioReconDone = YES;
        sBioSetters = [NSMutableArray array];

        int cnt = objc_getClassList(NULL, 0);
        if (cnt > 0) {
            Class *all = (Class *)malloc(sizeof(Class) * (size_t)cnt);
            if (all) {
                cnt = objc_getClassList(all, cnt);
                NSMutableArray<NSString *> *seen = [NSMutableArray array];
                for (int i = 0; i < cnt; i++) {
                    Class c = all[i];
                    if (!c) continue;
                    const char *nm = class_getName(c);
                    if (!nm) continue;
                    NSString *cn = @(nm);
                    if ([cn rangeOfString:@"Biometric"].location == NSNotFound &&
                        [cn rangeOfString:@"biometric"].location == NSNotFound) continue;
                    [seen addObject:cn];
                }
                free(all);
                if (seen.count) {
                    DLProbe(@"[FaceID][侦查] 运行时含 Biometric 的类（%lu 个）：%@",
                            (unsigned long)seen.count,
                            [seen componentsJoinedByString:@", "]);
                } else {
                    DLProbe(@"[FaceID][侦查] 运行时**没有**任何类名含 Biometric —— "
                            @"说明匹配能力在别的框架（可能要查 BiometricKit 的 C 接口）");
                }

                // 对每个候选类：取单例 → 找 setter 方法（含 Matching/Enabled）
                for (NSString *cn in seen) {
                    Class c = objc_getClass(cn.UTF8String);
                    if (!c) continue;

                    NSArray<id> *insts = DLBioInstancesFor(cn, nil);

                    for (id inst in insts) {
                        // ⚠️ 两台机器上都踩过的坑：
                        //   ① 这里**不能**用 object_getClass(inst) —— 那拿到的是**元类**，
                        //      名字会打印成 "XXXMeta"，且 class_copyMethodList(元类) 列出的是
                        //      **类方法**，而我们要找的 setter 全是**实例方法** → 一条都找不到。
                        //      正解 = 用 [inst class]（实例的真实类）。
                        //   ② **必须沿继承链往上走** —— setter 常常定义在父类/基类上
                        //      （例如 _setMatchingEnabled: 在某个基类 monitor 里），
                        //      只在自身类里找会漏。
                        Class icls = [inst class];
                        NSMutableArray<NSString *> *hits = [NSMutableArray array];
                        for (Class walk = icls; walk && walk != [NSObject class];
                             walk = class_getSuperclass(walk)) {
                            unsigned int mc = 0;
                            Method *mlist = class_copyMethodList(walk, &mc);
                            for (unsigned int k = 0; mlist && k < mc; k++) {
                                NSString *sn = NSStringFromSelector(method_getName(mlist[k]));
                                if (!sn.length) continue;
                                if (![sn hasSuffix:@":"]) continue;         // 要带参数
                                if ([sn rangeOfString:@"Matching"].location == NSNotFound &&
                                    [sn rangeOfString:@"Enabled"].location == NSNotFound &&
                                    [sn rangeOfString:@"Match"].location == NSNotFound) continue;
                                if (![hits containsObject:sn]) [hits addObject:sn];
                            }
                            if (mlist) free(mlist);
                        }
                        if (hits.count) {
                            DLProbe(@"[FaceID][侦查] %@ (%@) 的匹配相关候选：%@",
                                    cn, NSStringFromClass(icls),
                                    [hits componentsJoinedByString:@", "]);
                            for (NSString *sn in hits) {
                                int score = DLBioScoreSelector(icls, sn);
                                [sBioSetters addObject:[NSString stringWithFormat:@"%d|%@|%@|%@",
                                                        score, cn,
                                                        NSStringFromClass(icls),
                                                        sn]];
                            }
                        }
                    }
                }

                // ⭐⭐⭐ v0.2.3：**按语义打分排序**，而不是像 v0.2.2 那样「谁先被枚举到就调谁」。
                //
                // 🔥 v0.2.2 血泪（真机日志实锤）：侦查本身成功了（73 个类、14 条候选），
                //    但选中的是：
                //       命中路径 CSBiometricMatchMonitor -getBiometricMatchResultForTriggerTimeStamp:
                //    这是一个**取值器（getter）**！调它只是「查询匹配结果」，对 Face ID 毫无影响。
                //    结果：照样刷脸（日志随后出现 passcodeLockViewPasscodeEnteredViaMesa:）。
                //
                //    根因：我的筛选条件「以 : 结尾 + 名字含 Match」**无法区分 getter 和 setter**
                //    —— `getBiometricMatchResultForTriggerTimeStamp:` 恰好也带一个参数。
                //    再加上「先枚举到谁就用谁」，于是第一个类（CSBiometricMatchMonitor）
                //    的取值器就被选中了。
                //
                //    修法：① 剔除取值器（get/_get 前缀）；② 按语义打分，优先真正的
                //    「匹配断言」机制（这正是 iOS 16 的真实开关，见下）。
                [sBioSetters sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                    int sa = [[a componentsSeparatedByString:@"|"].firstObject intValue];
                    int sb = [[b componentsSeparatedByString:@"|"].firstObject intValue];
                    if (sa == sb) return NSOrderedSame;
                    return (sa > sb) ? NSOrderedAscending : NSOrderedDescending;
                }];

                DLProbe(@"[FaceID][侦查] 共找到 %lu 条候选，按语义排序后前 5 名：",
                        (unsigned long)sBioSetters.count);
                for (NSUInteger i = 0; i < MIN((NSUInteger)5, sBioSetters.count); i++) {
                    NSArray<NSString *> *p = [sBioSetters[i] componentsSeparatedByString:@"|"];
                    if (p.count >= 4) {
                        DLProbe(@"[FaceID][侦查]   第 %lu 名 分数=%d  %@ (%@) -%@",
                                (unsigned long)(i + 1), [p[0] intValue], p[1], p[2], p[3]);
                    }
                }
            }
        }
    }

    // ---- 用侦查到的候选路径去调 ----
    if (!sBioSetters.count) {
        DLProbe(@"[FaceID] ⚠️ 侦查未找到任何可用的匹配 setter → 无法干预生物识别"
                @"（这行说明：本机的匹配开关不在 Objective-C 层，或类名完全不同）");
        return;
    }

    // ⭐⭐⭐ v0.2.3：调用阶段要**按方法语义分派**，不能无脑传 BOOL。
    //
    // 🔥 v0.2.2 的教训是双重的：
    //   ① 选错了方法（选了取值器）→ 已在打分阶段修掉；
    //   ② 就算选对了名字，**参数类型也未必是 BOOL**！
    //      例如 `_removeMatchingAssertion:remover:` 收的是「断言对象」，
    //      `acquireMatchingAssertionWithMode:reason:` 收的是「模式 + 原因」。
    //      无脑 `((void(*)(id,SEL,BOOL))objc_msgSend)(inst, sel, want)` 会传垃圾参数。
    //
    // 因此这里只调用「**参数形状确定**」的方法，其余一律跳过（宁可不调，不可乱调）：
    //   A. 参数是单个 BOOL 的 setter（setMatchingEnabled: / _setMatchingEnabled:）
    //   B. 单个参数的断言方法 —— 但只在能拿到合法参数时才调
    for (NSString *entry in sBioSetters) {
        NSArray<NSString *> *parts = [entry componentsSeparatedByString:@"|"];
        if (parts.count < 4) continue;                 // 新格式：分数|类名|实例类|选择器
        int score = [parts[0] intValue];
        if (score <= 0) continue;                      // 已被打分淘汰（取值器等）
        NSString *ownerCls = parts[1], *instCls = parts[2], *selName = parts[3];
        SEL sel = NSSelectorFromString(selName);
        if (!sel) continue;

        // 只处理「单参数」或「已知形状」的方法
        NSInteger argc = 0;
        for (NSUInteger i = 0; i < selName.length; i++) {
            if ([selName characterAtIndex:i] == ':') argc++;
        }
        if (argc != 1) continue;                       // 多参数的形状不明 → 跳过

        for (id inst in DLBioInstancesFor(ownerCls, instCls)) {
            if (![inst respondsToSelector:sel]) continue;

            // ---- A. 经典 BOOL setter ----
            if ([selName rangeOfString:@"MatchingEnabled"].location != NSNotFound ||
                [selName rangeOfString:@"Enable"].location != NSNotFound ||
                [selName rangeOfString:@"Disable"].location != NSNotFound) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, sel, want);
                sBioMatchingOff = wantOff;
                DLProbe(@"[FaceID] 已%@生物识别匹配（%@）→ 命中路径 [分数 %d] %@ (%@) -%@",
                        enabled ? @"恢复" : @"暂停",
                        enabled ? @"退出假空间" : @"假空间展示期间",
                        score, ownerCls, instCls, selName);
                return;
            }

            // ---- B. 匹配断言机制（本机真实开关）----
            // ⚠️ 关键：**暂停**时应该「移除断言」，而不是「添加一个（传 nil 的）断言」。
            //    日志实锤本机 `_removeMatchingAssertion:` 存在。
            //    但移除需要传入「当初那个断言对象」，我们并没有 —— 所以这里**不硬调**，
            //    只在能确定参数合法性时尝试，否则交给下一步（LD 层 hook）。
            if ([selName rangeOfString:@"Assertion"].location != NSNotFound) {
                DLProbe(@"[FaceID][侦查] ⚠️ 本机开关是「匹配断言」机制（%@ -%@），"
                        @"需要断言对象才能操作 → 本次未直接调用，改由 hook 层拦截",
                        instCls, selName);
                break;
            }
        }
    }

    DLProbe(@"[FaceID] ⚠️ 侦查到 %lu 条候选，但没有一条能「确定参数形状」地安全调用"
            @"（多为断言机制，需要对象参数）→ 生物识别未被直接停用",
            (unsigned long)sBioSetters.count);
}

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.23：会话级 Face ID 暂停（提前到「用户开始输密码」）
//
// 用户实测（v0.1.22）：假空间出来了，但**中间还是闪了一下刷脸**。
// 根因 = v0.1.22 在「假空间铺完之后」才暂停，而系统在按完最后一位的
// 那一瞬间就已经发起了 Face ID 匹配 → 我们晚了半步。
//
// 正解：用户敲下密码框第一位（SBUIPasscodeEntryField appendString: 首次调用）
// 就把匹配暂停掉，从源头掐断。
// ---------------------------------------------------------------------------
static BOOL sPasscodeSession = NO;

BOOL DLPasscodeSessionActive(void) { return sPasscodeSession; }

void DLBeginPasscodeSession(void) {
    if (sPasscodeSession) return;       // 已在会话中，不重复
    sPasscodeSession = YES;
    DLProbe(@"[FaceID] 用户开始输入密码 → 提前暂停生物识别匹配");
    DLSetBiometricMatching(NO);
}

void DLEndPasscodeSession(void) {
    if (!sPasscodeSession) return;
    sPasscodeSession = NO;
    DLProbe(@"[FaceID] 输密码会话结束 → 恢复生物识别匹配");
    DLSetBiometricMatching(YES);
}

// ---------------------------------------------------------------------------
// ⭐⭐⭐ v0.2.0：锁屏贴纸模式（不解锁真机进入假空间）
//
// 用户要求：「在手机解锁的情况下进入假空间」—— 不，是**在不解锁的情况下**。
// 此前所有版本都走「先解锁 → 假空间盖在真桌面」，所以必然刷脸。
//
// 本模式只记录一个状态位，真正的窗口层级/场景选择在 DLDecoyController 里做。
// 这里保留状态是为了：
//   ① 让恢复逻辑能判断「当前是不是锁屏贴纸模式」；
//   ② 让兜底守护知道该不该压制 Face ID。
// ---------------------------------------------------------------------------
static BOOL sPinnedToLock = NO;

BOOL DLPinnedToLockScreen(void) { return sPinnedToLock; }

void DLPinToLockScreen(void) {
    if (sPinnedToLock) return;
    sPinnedToLock = YES;
    DLProbe(@"★★ [锁屏贴纸] 进入「不解锁真机」模式 —— 假空间将贴在锁屏之上");
}

void DLUnpinFromLockScreen(void) {
    if (!sPinnedToLock) return;
    sPinnedToLock = NO;
    DLProbe(@"[锁屏贴纸] 退出「不解锁真机」模式 —— 恢复为正常锁屏");
}
