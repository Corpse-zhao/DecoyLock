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

// ⭐ v0.2.1：干预前记录「系统原本是否在匹配」，作为恢复时的兜底依据。
//    为什么需要：万一我们的暂停成功了、但恢复路径全部没走到，
//    下次进程内还能凭这个值把系统还原回去（不可让用户能力被永久关死）。
static BOOL sBioWasMatching = NO;
static BOOL sBioWasMatchingValid = NO;

BOOL DLBiometricMatchingIsOff(void) { return sBioMatchingOff; }

// ⭐⭐⭐ v0.2.1 重做：Face ID 临时停用（多路径探测）
//
// 🔥 v0.2.0 血泪：只试了 `SBUIBiometricResource -setMatchingEnabled:` 一条路，
//    真机日志一路 `实例不支持 setMatchingEnabled: → 跳过（不干预）`
//    → **暂停从未生效过**，刷脸自然一直在（v0.1.22/v0.1.23 的努力全白费）。
//
// iOS 16 实测正确的入口是 **`SBUIBiometricEventMonitor`**（不是 BiometricResource），
// 方法名是私有的 **`_setMatchingEnabled:`**（带下划线）。
// 为兼容性，这里按优先级**依次尝试**，并**把命中的路径打进日志** ——
// 这样即使某个类名在这台机器上不存在，下一次日志也能告诉我们真实情况。
//
// 参考：theapplewiki.com Dev:BiometricKit.framework
//   monitor = [objc_getClass("SBUIBiometricEventMonitor") sharedInstance];
//   _wasMatching = [[monitor valueForKey:@"_matchingEnabled"] boolValue];
//   [monitor _setMatchingEnabled:NO];   // 停：不再发起匹配
//
// ⚠️ 依旧全程 respondsToSelector 显式探测 —— 不存在的类/方法直接 msgSend 是崩溃级风险。

void DLSetBiometricMatching(BOOL enabled) {
    // ⭐ 幂等短路：状态没变直接返回（不重复调系统 API，避免匹配抖动）
    if (enabled && !sBioMatchingOff) return;
    if (!enabled && sBioMatchingOff) return;

    BOOL want = enabled;                       // 目标状态
    BOOL wantOff = !enabled;

    // 方法名候选（私有 API，不同版本名字不同，依次试）
    NSArray<NSString *> *setterNames = @[
        @"_setMatchingEnabled:",               // ⭐ iOS 16 实测（带下划线）
        @"setMatchingEnabled:",                // 旧版 / 部分版本
        @"setMatchingEnabledForFaceID:",
    ];

    // 类候选（按可靠性排序）
    NSArray<NSString *> *classNames = @[
        @"SBUIBiometricEventMonitor",          // ⭐ iOS 16 实测入口
        @"SBUIBiometricResource",
    ];

    // 每次调用前，先把「当前匹配状态」记下来，便于恢复时对照
    for (NSString *cn in classNames) {
        Class cls = objc_getClass(cn.UTF8String);
        if (!cls) continue;

        id inst = nil;
        if ([cls respondsToSelector:@selector(sharedInstance)]) {
            inst = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
        }
        if (!inst) continue;

        // 命中前先把「原状态」读出来（仅首次），供恢复时兜底
        if (sBioWasMatchingValid == NO &&
            [inst respondsToSelector:NSSelectorFromString(@"_matchingEnabled")]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(inst, NSSelectorFromString(@"_matchingEnabled"));
            if ([v respondsToSelector:@selector(boolValue)]) {
                sBioWasMatching = [v boolValue];
                sBioWasMatchingValid = YES;
            }
        }

        for (NSString *sn in setterNames) {
            SEL sel = NSSelectorFromString(sn);
            if (!sel || ![inst respondsToSelector:sel]) continue;

            ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, sel, want);
            sBioMatchingOff = wantOff;     // ⚠️ 只有真正调用成功后才改状态
            DLProbe(@"[FaceID] 已%@生物识别匹配（%@）→ 命中路径 %@ -%@",
                    enabled ? @"恢复" : @"暂停",
                    enabled ? @"退出假空间" : @"假空间展示期间",
                    cn, sn);

            // ⭐ 恢复时再校一次：若系统原状态本就是「不匹配」，
            //    说明这次恢复是多余的，记一行日志便于排查抖动。
            if (enabled && sBioWasMatchingValid && !sBioWasMatching) {
                DLProbe(@"[FaceID] 提示：干预前系统本就未在匹配（已按原值恢复）");
            }
            return;
        }
    }

    // 全部路径都没命中 → 明确记日志（这条日志是下一轮的诊断依据）
    DLProbe(@"[FaceID] ⚠️ 所有候选路径都没命中（类=%@；方法=%@）→ 无法干预生物识别",
            [classNames componentsJoinedByString:@","],
            [setterNames componentsJoinedByString:@","]);
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
