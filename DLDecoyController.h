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

/// ⭐ v0.1.19 安全接口：无条件拆除窗口并把 key window 还给系统。
/// 用于「锁屏消失 / 用户去解锁 / 系统重建锁屏」这些**必须确保清理**的时机。
/// 与 dismissDecoy 的区别：不标记「用户主动退出」，纯清理。
+ (void)forceTeardown;

/// ⭐ v0.1.19：假空间已展示的秒数；未展示时返回 -1。
/// 调用方用它判断「这次的锁屏变动是不是我们刚铺界面引起的」，
/// 避免把我们自己刚呈现的界面立刻拆掉。
+ (NSTimeInterval)shownDuration;

/// ⭐ v0.1.14：伪造锁屏界面的「密码错误」反馈 —— 闪红 + 抖动 + 清空输入。
/// 用户输入了伪密码但用户自己没配「伪密码位数」时（无法判定该不该进假空间），
/// 用它把界面上看起来像「密码错了」，避免暴露插件。
+ (void)showFakeWrongFeedback;

#pragma mark - ⭐ v0.1.14 主动取词：由 Tweak 直接询问「这串输入该怎么处理」

typedef NS_ENUM(NSInteger, DLPasscodeVerdict) {
    DLPasscodeVerdictNative = 0,   // 交给系统原生流程（放行）
    DLPasscodeVerdictDecoy,        // 命中伪密码 → 进假空间
};

/// 核心决策：拿着用户刚敲完的一串数字，判断该不该进假空间。
/// @param digits 用户已输入的完整数字串（来自密码框钩子）
/// @return 该走哪条路
+ (DLPasscodeVerdict)handleCapturedPasscode:(NSString *)digits;

@end

#endif /* DLDecoyController_h */
