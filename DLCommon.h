#ifndef DLCommon_h
#define DLCommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

#define DL_VERSION      @"0.1.18"
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

#endif /* DLCommon_h */
