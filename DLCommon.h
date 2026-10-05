#ifndef DLCommon_h
#define DLCommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

#define DL_VERSION      @"0.1.6"
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

// 探针（诊断日志，Filza 友好）
FOUNDATION_EXPORT void DLProbe(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *DLProbeRead(void);
FOUNDATION_EXPORT void DLProbeClear(void);

// 调用「设置」进程刷新面板（跨进程通知）
FOUNDATION_EXPORT void DLPostPrefsChanged(void);

#endif /* DLCommon_h */
