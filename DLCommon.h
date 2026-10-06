#ifndef DLCommon_h
#define DLCommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

// ⭐ v0.1.18a 修正：objc 运行时函数（object_getClass / class_getInstanceMethod /
//    MSHookMessageEx 等）必须在此统一声明。
//    踩坑记录：原先只有 Tweak.x 单独 #import <objc/runtime.h>，
//    DLDecoyController.m 是**独立编译单元**，用了 object_getClass 却没有声明 →
//    CI 报 4 连错（implicit declaration / conflicting types）。
//    放进共享头文件 = 一劳永逸，任何新 .m 都不会再犯。
#import <objc/runtime.h>
#import <objc/message.h>

#define DL_VERSION      @"0.1.22"
#define DL_PREFS_DOMAIN @"com.blr.decoylock"

// 共享配置目录（SpringBoard 进程与「设置」进程都能写的位置）
FOUNDATION_EXPORT NSString *DLSharedDir(void);
FOUNDATION_EXPORT NSString *DLConfigPath(void);
FOUNDATION_EXPORT NSString *DLProbePath(void);

// 读写配置
FOUNDATION_EXPORT id      DLConfigGet(NSString *key);
FOUNDATION_EXPORT void    DLConfigSet(NSString *key, id value);
FOUNDATION_EXPORT NSDictionary *DLConfigAll(void);

// 便捷读取
FOUNDATION_EXPORT BOOL      DLEnabled(void);
FOUNDATION_EXPORT NSString *DLDecoyPasscode(void);   // 伪密码（明文，存共享配置）
FOUNDATION_EXPORT NSString *DLDecoyTitle(void);
FOUNDATION_EXPORT NSString *DLDecoySubtitle(void);
FOUNDATION_EXPORT NSArray  *DLDecoyApps(void);       // 假空间展示的 App 标识数组
FOUNDATION_EXPORT NSArray  *DLAllFakeApps(void);     // 内置可选假 App 清单
// ⭐ v0.1.16：在假空间里点哪个 App 就退出（默认 "settings" = 设置）
// 返回空串 = 不设置（只能用隐藏手势退出）
FOUNDATION_EXPORT NSString *DLDecoyExitApp(void);

// 探针（诊断日志，Filza 友好）
FOUNDATION_EXPORT void DLProbe(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *DLProbeRead(void);
FOUNDATION_EXPORT void DLProbeClear(void);

// 调用「设置」进程刷新面板（跨进程通知）
FOUNDATION_EXPORT void DLPostPrefsChanged(void);

// ⭐ v0.1.17：退出假空间前调用 —— 把系统锁屏的密码框清干净。
// 背景：命中伪密码时我们吞掉了最后一位（系统收不满 → 不判错，无密码错误/无刷脸），
// 但密码框里可能残留前 N-1 位。若不清掉，用户回到锁屏后再敲一位就会凑成
// 一个「错误密码」→ 触发系统错误惩罚。实现见 Tweak.x。
FOUNDATION_EXPORT void DLPrepareNativeLockScreen(void);

// ⭐⭐ v0.1.22：假空间展示期间暂停 / 恢复 Face ID（生物识别）匹配。
//
// 背景（2026-10-06 用户日志实锤）：输伪密码后假空间**确实**铺上去了
// （`decoy 已呈现 windowLevel=10001011`），而且系统**并没有**判密码错误
// （日志里完全没有 `resetForFailedPasscode`）。但用户仍然反馈「要刷脸」，
// 且退出假空间后 `[退出清理] 未找到密码框（可能锁屏已收起）`
// —— 说明**真机被系统自己通过 Face ID 解开了**，不是我们放行的。
//
// 所以要在「假空间存在的这段时间」把生物识别匹配关掉，
// 退出时再恢复。为什么不直接判错拦截：iOS 16.6 上密码提交不走
// `attemptUnlockWithPasscode:`（用户日志证明该钩子从未被调用）。
//
// ⚠️ 实现必须**全程 respondsToSelector 保护**、拿不到就静默跳过 ——
//    绝不允许因为系统版本差异而崩进程或强改系统行为。
//    （实现见 DLCommon.m，内部带幂等状态，重复调用不会抖动匹配）
FOUNDATION_EXPORT void DLSetBiometricMatching(BOOL enabled);

// 查询我们当前是否处于「已暂停生物识别匹配」状态（供兜底守护判断）
FOUNDATION_EXPORT BOOL DLBiometricMatchingIsOff(void);

#endif /* DLCommon_h */
