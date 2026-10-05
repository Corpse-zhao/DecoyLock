#ifndef DLDecoyController_h
#define DLDecoyController_h

#import <UIKit/UIKit.h>

/// 假空间：进入伪密码后呈现的界面。
/// 轻量版实现 = 一个仿系统桌面的页面（状态栏时间 + 壁纸 + App 网格 + 底部 Dock）。
/// 不触碰 SpringBoard 内部结构，独立成页，安全可控。
@interface DLDecoyController : UIViewController

/// 单例入口：由 Tweak 在锁屏解锁回调里触发
+ (void)presentIfConfigured;

/// 是否正在展示假空间（Tweak 用，避免重复呈现）
+ (BOOL)isShowing;

/// 主动退出假空间（回到真锁屏）
+ (void)dismissDecoy;

@end

#endif /* DLDecoyController_h */
