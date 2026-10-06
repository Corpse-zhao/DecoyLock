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
                                if (![sn hasSuffix:@":"]) continue;         // 要带参数（setter）
                                if ([sn rangeOfString:@"Matching"].location == NSNotFound &&
                                    [sn rangeOfString:@"Enabled"].location == NSNotFound &&
                                    [sn rangeOfString:@"Match"].location == NSNotFound) continue;
                                if (![hits containsObject:sn]) [hits addObject:sn];
                            }
                            if (mlist) free(mlist);
                        }
                        if (hits.count) {
                            DLProbe(@"[FaceID][侦查] %@ (%@) 的匹配相关 setter：%@",
                                    cn, NSStringFromClass(icls),
                                    [hits componentsJoinedByString:@", "]);
                            for (NSString *sn in hits) {
                                [sBioSetters addObject:[NSString stringWithFormat:@"%@|%@|%@",
                                                        cn,
                                                        NSStringFromClass(icls),
                                                        sn]];
                            }
                        }
                    }
                }
                DLProbe(@"[FaceID][侦查] 共找到 %lu 条候选 setter 路径",
                        (unsigned long)sBioSetters.count);
            }
        }
    }

    // ---- 用侦查到的候选路径去调 ----
    if (!sBioSetters.count) {
        DLProbe(@"[FaceID] ⚠️ 侦查未找到任何可用的匹配 setter → 无法干预生物识别"
                @"（这行说明：本机的匹配开关不在 Objective-C 层，或类名完全不同）");
        return;
    }

    for (NSString *entry in sBioSetters) {
        NSArray<NSString *> *parts = [entry componentsSeparatedByString:@"|"];
        if (parts.count < 3) continue;
        SEL sel = NSSelectorFromString(parts[2]);
        if (!sel) continue;

        // ⭐ 用**同一个**实例解析函数，保证「侦查时看到的东西」和「调用时拿到的对象」
        //    是同一批（否则会出现「日志说找到了 setter，却没调成」的鬼故事）。
        for (id inst in DLBioInstancesFor(parts[0], parts[1])) {
            if (![inst respondsToSelector:sel]) continue;
            ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, sel, want);
            sBioMatchingOff = wantOff;
            DLProbe(@"[FaceID] 已%@生物识别匹配（%@）→ 命中路径 %@ (%@) -%@",
                    enabled ? @"恢复" : @"暂停",
                    enabled ? @"退出假空间" : @"假空间展示期间",
                    parts[0], parts[1], parts[2]);
            return;
        }
    }

    DLProbe(@"[FaceID] ⚠️ 侦查到 %lu 条候选，但**全部调用失败**"
            @"（说明方法存在但调用无效，可能需先停下某个 monitor）",
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
