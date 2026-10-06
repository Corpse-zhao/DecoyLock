#import "DLDecoyController.h"
#import "DLCommon.h"
#import <AudioToolbox/AudioToolbox.h>

// ---------------------------------------------------------------------------
// 假空间界面
//
// 设计要点（轻量版）：
//  - 完全不碰 SpringBoard 内部视图树，独立 view controller，全屏覆盖
//  - 视觉上模仿系统桌面：状态栏时间 / 壁纸 / App 网格 / 底部 Dock / 页码点
//  - 支持左右滑动翻页（多页 App 网格）
//  - 任何 App 点按 → 弹一个「无法打开」的仿系统提示（假空间是空壳）
//  - 长按空白处 / 连点状态栏 → 退出假空间（隐藏入口，避免被识破）
// ---------------------------------------------------------------------------

static NSString *const kDLCellID = @"DLDecoyAppCell";

#pragma mark - 前向声明（类扩展须写在所有实现之前）

// ⚠️ 类扩展必须出现在所有实现之前，否则报
//    "cannot declare class extension after class implementation"
@interface DLDecoyController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UIView *wallpaperView;
@property (nonatomic, strong) UILabel *clockLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *titleLabel;      // "我的 iPhone"
@property (nonatomic, strong) UICollectionView *appGrid;
@property (nonatomic, strong) UIView *dock;
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, assign) NSInteger statusBarTaps;
// ⚠️ 内部类方法（只在 .m 内用）也要声明，否则调用点会被当成「找不到的类方法」。
//    实测在 ObjC 下只是警告（所以一直没挂），但声明显式化更安全 ——
//    万一哪天返回值不是 void，默认 id 返回会引入隐患。
+ (void)startKeeper;
+ (void)keeperTick:(NSInteger)n;
+ (void)reviveOrPresent;
@end

#pragma mark - 假 App 单元格

@interface DLDecoyAppCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, copy)   NSString *appID;    // ⭐ v0.1.16：Dock 点击要认出是哪个 App
- (void)configureWithApp:(NSDictionary *)app;
@end

@implementation DLDecoyAppCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.userInteractionEnabled = NO;
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        _nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.95];
        _nameLabel.userInteractionEnabled = NO;
        [self.contentView addSubview:_nameLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat iconSize = MIN(w - 8.0, 62.0);
    self.iconView.frame = CGRectMake((w - iconSize) / 2.0, 2.0, iconSize, iconSize);
    self.iconView.layer.cornerRadius = iconSize * 0.225;   // 近似 iOS 图标圆角
    self.iconView.layer.masksToBounds = YES;
    self.nameLabel.frame = CGRectMake(-6.0, iconSize + 6.0, w + 12.0, 14.0);
}

- (void)configureWithApp:(NSDictionary *)app {
    NSString *icon = app[@"icon"] ?: @"app.fill";
    NSString *name = app[@"name"] ?: @"App";
    self.appID = app[@"id"];          // ⭐ v0.1.16
    self.nameLabel.text = name;

    // 用 SF Symbol + 渐变底做「假图标」——零素材依赖
    UIImage *symbol = [UIImage systemImageNamed:icon];
    if (!symbol) symbol = [UIImage systemImageNamed:@"app.fill"];

    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120, 120)];
    UIImage *plate = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        NSArray *palette = @[
            @[[UIColor colorWithRed:0.25 green:0.55 blue:0.98 alpha:1.0],
              [UIColor colorWithRed:0.10 green:0.35 blue:0.85 alpha:1.0]],
            @[[UIColor colorWithRed:0.42 green:0.78 blue:0.44 alpha:1.0],
              [UIColor colorWithRed:0.20 green:0.58 blue:0.30 alpha:1.0]],
            @[[UIColor colorWithRed:0.98 green:0.58 blue:0.24 alpha:1.0],
              [UIColor colorWithRed:0.88 green:0.35 blue:0.15 alpha:1.0]],
            @[[UIColor colorWithRed:0.62 green:0.44 blue:0.92 alpha:1.0],
              [UIColor colorWithRed:0.42 green:0.28 blue:0.78 alpha:1.0]],
            @[[UIColor colorWithRed:0.92 green:0.42 blue:0.55 alpha:1.0],
              [UIColor colorWithRed:0.78 green:0.24 blue:0.40 alpha:1.0]],
            @[[UIColor colorWithRed:0.30 green:0.72 blue:0.78 alpha:1.0],
              [UIColor colorWithRed:0.16 green:0.52 blue:0.62 alpha:1.0]],
        ];
        NSUInteger idx = [DLDecoyApps() indexOfObject:app[@"id"]];
        if (idx == NSNotFound || idx >= palette.count) idx = 0;
        NSArray *pair = palette[idx % palette.count];

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(__bridge id)[pair[0] CGColor],
                            (__bridge id)[pair[1] CGColor]];
        CGGradientRef grad = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0),
                                    CGPointMake(120, 120), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);
    }];
    self.iconView.image = plate;

    // 图标内容叠加：SF Symbol 白描
    if (symbol) {
        UIGraphicsImageRenderer *r2 =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120, 120)];
        UIImage *composed = [r2 imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [plate drawInRect:CGRectMake(0, 0, 120, 120)];
            UIImage *tinted = [symbol imageWithTintColor:[UIColor whiteColor]
                                           renderingMode:UIImageRenderingModeAlwaysTemplate];
            [tinted drawInRect:CGRectMake(30, 30, 60, 60)];
        }];
        self.iconView.image = composed;
    }
}

@end

#pragma mark - 假空间主控制器

@implementation DLDecoyController

static DLDecoyController *sShared = nil;
// ⭐ v0.1.15：窗口必须自己强持有！
//   2026-10-06 实测：presentIfConfigured 里 win 是局部变量，只靠
//   UIApplication 的窗口列表保活 —— 实测日志显示窗口在呈现后 ~1.2 秒内
//   就变成了 isShowing==NO（被宿主 SpringBoard 在 CoverSheet 重置时
//   隐藏或移出层级）。自己持有一份强引用，至少排除「被回收」这一种可能；
//   剩下的「被隐藏/被移除」交给下面的守护循环（startKeeper）自愈。
static UIWindow *sWindow = nil;

// v0.1.17：窗口层级探测（定义在下方 presentIfConfigured 之前）
// verbose=YES 时把每个窗口的类名+层级打进日志（只在呈现时用，
// 守护循环每 0.5 秒调一次，不能每次都刷屏）
static CGFloat DLMaxOtherWindowLevelVerbose(BOOL verbose);

static CGFloat DLMaxOtherWindowLevel(void) {
    return DLMaxOtherWindowLevelVerbose(NO);
}

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.14 主动取词 —— 核心决策
//
// 为什么改成这一套（这是本项目第 14 版，前 13 版全在「等系统告诉我结果」）：
//
//   v0.1.13 日志实锤：用户敲完 6 位密码后，系统**没有**走
//     - coverSheetViewController:unlockWithRequest:completion:   （0 次）
//     - coverSheetPresentationManager:unlockWithRequest:completion:（0 次）
//   而是直接：
//     23:00:29.812  [侦查] SBUIPasscodeLockViewSimpleFixedDigitKeypad -resetForFailedPasscode
//     23:00:29.814  [失败回调] ★ resetForFailedPasscode 被调用 → 系统判定密码错误
//   → 也就是说，密码错误这条路径上，系统**根本不外露任何携带密码的调用**。
//     想靠「挂钩系统回调」拿到密码，这条路线已被证明走不通。
//
// 于是本版彻底换思路：**不问了，自己数**。
//
//   ① 密码框钩子（Hook 组 A）已经能 100% 拿到用户按键（v0.1.9 起就验证过：
//      `[输入] 源=entry.append 追加=6 结果 len=4`）
//   ② 插件自己记着「伪密码是几位」，一旦输入长度够了，就**主动**做比对
//   ③ 命中 → 自己把假空间盖上去（顺带把系统随后弹的密码错误界面也盖住）
//      不命中 → 什么都不做，交给系统原生流程（用户看到正常的「密码错误 + 锁定」）
//
//  安全性：不吞任何系统调用、不改写系统返回值、不等任何系统回调。
//          判断错了最多是「该进假空间没进」或「不该进进了」，绝不锁死设备。
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ⭐ v0.1.18a 修正：这两个状态**必须声明在 handleCapturedPasscode 之前**。
//    踩坑记录：原来它们放在下面的「窗口守护」小节（第 233/238 行），
//    而 handleCapturedPasscode（第 216 行）已经用到了 sUserDismissed →
//    「use of undeclared identifier」是**硬编译错误**（不像 ObjC 的
//    方法找不到只是警告）。文件作用域变量一律先声明后用。
// ---------------------------------------------------------------------------
static BOOL sKeeperActive = NO;      // 守护循环是否在跑
static BOOL sUserDismissed = NO;     // ⭐ v0.1.18：区分「系统弄没窗口」与「用户主动退出」

+ (DLPasscodeVerdict)handleCapturedPasscode:(NSString *)digits {
    if (!digits.length) return DLPasscodeVerdictNative;

    // ---- 前置门槛 ----
    if (!DLEnabled()) {
        DLProbe(@"[主动判定] 插件未启用 → 放行");
        return DLPasscodeVerdictNative;
    }
    NSString *decoy = DLDecoyPasscode();
    if (!decoy.length) {
        // 没配伪密码 = 没有可比对的东西 → 绝不能瞎猜，放行
        DLProbe(@"[主动判定] 未配置伪密码 → 放行");
        return DLPasscodeVerdictNative;
    }
    if (digits.length != decoy.length) {
        DLProbe(@"[主动判定] 位数不符（输入 %lu 位 vs 伪密码 %lu 位）→ 放行",
                (unsigned long)digits.length, (unsigned long)decoy.length);
        return DLPasscodeVerdictNative;
    }

    // ---- 核心比对 ----
    if (![digits isEqualToString:decoy]) {
        DLProbe(@"[主动判定] %@ ≠ 伪密码 → 放行（交给系统原生流程）", digits);
        return DLPasscodeVerdictNative;
    }

    // ---- 命中！----
    DLProbe(@"*** 主动命中伪密码（输入 %@）→ 呈现假空间", digits);

    // ⚠️ 必须同步判断「是否已在展示中」，避免重复 present
    if ([self isShowing]) {
        DLProbe(@"[主动判定] 假空间已在展示中 → 不重复呈现");
        return DLPasscodeVerdictDecoy;
    }

    // ⭐ v0.1.18：新一轮命中 → 解除「用户已退出」状态，守护循环重新待命
    sUserDismissed = NO;

    // 关键：双保险（v0.1.15 重做）。
    //   ① 立刻异步呈现（赶在系统「密码错误」动画之前把假空间铺上去）
    //   ② 呈现后启动 15 秒守护循环：每 0.5 秒查一次，窗口被系统隐藏/移除
    //      就当场复活。2026-10-06 实测：首次呈现 1.2 秒后窗口就没了
    //      （isShowing==NO），单次「补呈现」治标不治本，必须持续守护。
    dispatch_async(dispatch_get_main_queue(), ^{
        [DLDecoyController presentIfConfigured];
    });
    [DLDecoyController startKeeper];

    return DLPasscodeVerdictDecoy;
}

#pragma mark - ⭐ v0.1.15 窗口守护（自愈 + 根因取证）

// ⚠️ sKeeperActive / sUserDismissed 已上移到 handleCapturedPasscode 之前声明
//    （文件作用域变量必须先声明后用，见上方说明）

// 启动守护循环：0.5 秒 × 30 次 = 覆盖呈现后最初 15 秒
// （实测窗口正是在呈现后 ~1.2 秒被系统动掉的，15 秒足够跨过 CoverSheet 重置期）
+ (void)startKeeper {
    if (sKeeperActive) return;      // 已有守护在跑，不叠加
    sKeeperActive = YES;
    [self keeperTick:0];
}

+ (void)keeperTick:(NSInteger)n {
    // ⭐ v0.1.18：用户已主动退出 → 立刻收工，绝不再复活
    if (!sKeeperActive) return;
    if (sUserDismissed) {
        sKeeperActive = NO;
        DLProbe(@"[守护] 用户已主动退出 → 守护结束，不再复活");
        return;
    }

    if (![DLDecoyController isShowing]) {
        // ⭐ 取证优先：把「窗口到底怎么了」写进日志，下一轮排查直接看根因
        NSString *state;
        if (!sShared) {
            state = @"实例已被释放";
        } else if (!sShared.view.window) {
            state = @"窗口已脱离视图层级（被系统移除或回收）";
        } else {
            state = [NSString stringWithFormat:@"窗口还在但被隐藏（hidden=YES, level=%.0f）",
                     sShared.view.window.windowLevel];
        }
        DLProbe(@"[守护] 第 %ld 次检查：假空间不可见（%@）→ 立即复活",
                (long)n, state);
        [self reviveOrPresent];
    } else if (sWindow) {
        // ⭐ v0.1.17：可见时也顺便检查层级 —— 系统可能在我们之后又拉了一个
        //    更高的窗口（例如锁屏重建），把我们压到下面去（用户就会看到
        //    「密码错误/刷脸」而不是假空间）。发现被压就立刻抬上去。
        CGFloat want = DLMaxOtherWindowLevel() + 1000.0;
        if (want < 100000.0) want = 100000.0;
        if (sWindow.windowLevel < want) {
            DLProbe(@"[守护] 第 %ld 次：被更高窗口压住（当前 %.0f < 需要 %.0f）→ 抬升层级",
                    (long)n, sWindow.windowLevel, want);
            sWindow.windowLevel = want;
        }
    }
    if (n + 1 < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [DLDecoyController keeperTick:n + 1];
        });
    } else {
        sKeeperActive = NO;
        // 守护结束前做最后一次确认（留一行日志，方便判断 15 秒内有没有动过）
        if (![DLDecoyController isShowing]) {
            DLProbe(@"[守护] 15 秒守护结束，假空间仍不可见（交给兜底判定点）");
        }
    }
}

// 能复活就不重建（重建会闪一下黑屏）：
//   窗口还在、只是被隐藏 → 直接重新可见 + makeKey
//   窗口没了 / 实例没了  → 走完整重建
+ (void)reviveOrPresent {
    if (sShared && sShared.view.window) {
        UIWindow *win = sShared.view.window;
        if (win.hidden || ![win isKeyWindow]) {
            DLProbe(@"[守护] 复活：窗口重新可见（level=%.0f）", win.windowLevel);
            win.hidden = NO;
            [win makeKeyAndVisible];
        }
        return;
    }
    DLProbe(@"[守护] 复活失败：窗口/实例已丢失 → 完整重建");
    [self presentIfConfigured];
}

// 伪造「密码错误」外观（仅在极少数无法判定的场景下用）
+ (void)showFakeWrongFeedback {
    // 锁屏密码框的失败反馈是系统自带的，我们只需要闪一下屏幕边缘做心理暗示。
    // 这里是保守实现：不碰系统视图，只做一次轻微震动，避免任何越界操作。
    dispatch_async(dispatch_get_main_queue(), ^{
        // AudioServices 是 AudioToolbox 的公开 API，震动 ID 1520 是
        // 「peek」触感（iOS 10+ 稳定存在）。调用失败也绝不影响主流程。
        AudioServicesPlaySystemSound(1520);
    });
}

+ (BOOL)isShowing {
    return sShared != nil && sShared.view.window != nil && !sShared.view.window.hidden;
}

#pragma mark - ⭐⭐ v0.1.17 窗口层级探测（「必须刷脸才看到假空间」的根因修复）

// 用户反馈：「输入假密码后还是显示密码错误，然后还要刷脸才能进入假空间」
//   → 铁证：我们的窗口**一直在锁屏 UI 底下**。
//     否则不可能同时看到「密码错误」和刷脸提示（它们都该被我们的窗口盖住）。
//     刷脸把锁屏顶掉之后，我们的窗口才露出来 —— 这正是用户描述的现象。
//
// 结论：**windowLevel 硬编码 100000 不够**。SpringBoard 自己给锁屏/网络锁等
//       窗口用的层级是它自己的常量（可能远大于 100000），必须**运行时探测**，
//       永远待在当时最高的那个窗口之上。
//
// 本函数同时把所有现存窗口的类名+层级打进日志 —— 这是下一轮排查最重要的情报。

// 返回「除我们自己的窗口以外」所有窗口的最大层级
static CGFloat DLMaxOtherWindowLevelVerbose(BOOL verbose) {
    CGFloat maxLv = 0.0;
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];

    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            [all addObjectsFromArray:ws.windows];
        }
    }
    // ⚠️ 再补一份 application.windows：某些系统窗口（如锁屏）不一定出现在
    //    scene.windows 里，但一定在 application.windows 里。
    if (UIApplication.sharedApplication.windows.count) {
        [all addObjectsFromArray:UIApplication.sharedApplication.windows];
    }

    NSMutableArray *seen = [NSMutableArray array];
    for (UIWindow *w in all) {
        if (!w || w == sWindow) continue;
        NSString *cls = NSStringFromClass(object_getClass(w));
        NSString *key = [NSString stringWithFormat:@"%@|%.0f", cls, w.windowLevel];
        if ([seen containsObject:key]) continue;      // 去重，日志别刷屏
        [seen addObject:key];

        if (verbose) {
            DLProbe(@"[窗口清点] %@ level=%.0f hidden=%d key=%d",
                    cls, w.windowLevel, (int)w.hidden, (int)[w isKeyWindow]);
        }

        if (w.windowLevel > maxLv) maxLv = w.windowLevel;
    }
    return maxLv;
}

// 找出「层级最高的那个窗口」所在的 scene —— 我们的窗口挂到同一个 scene，
// 才能保证在同一个合成上下文里排序（不同 scene 之间比层级没意义）。
static UIWindowScene *DLSceneOwningTopWindow(void) {
    UIWindowScene *best = nil;
    CGFloat bestLv = -1.0;

    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            for (UIWindow *w in ws.windows) {
                if (w.windowLevel > bestLv) { bestLv = w.windowLevel; best = ws; }
            }
        }
    }
    if (!best) {
        // 没有 scene 信息（或 iOS 12）→ 交给调用方走 initWithFrame 分支
        best = nil;
    }
    return best;
}

+ (void)presentIfConfigured {
    if (!DLEnabled()) {
        DLProbe(@"decoy 跳过：插件未启用");
        return;
    }
    if (!DLDecoyPasscode().length) {
        DLProbe(@"decoy 跳过：未配置伪密码");
        return;
    }
    if ([self isShowing]) {
        DLProbe(@"decoy 跳过：已在展示中");
        return;
    }
    // 残留状态清掉（窗口被系统拆掉但 sShared 还没释放的兜底），
    // 否则用户会「点进去一次之后再也没反应」
    if (sShared) {
        DLProbe(@"decoy 清理残留实例");
        [self dismissDecoy];
    }

    DLDecoyController *vc = [[DLDecoyController alloc] init];
    sShared = vc;

    // ⚠️ 关键：不能用「锁屏那个 key window」来 present。
    //    锁屏的窗口会随解锁流程被系统拆掉，模态一挂上去就跟着消失。
    //    正解 = 自建独立 UIWindow；但**必须挂在「层级最高的窗口所在的那个 scene」**，
    //    并且层级要高过当时所有窗口（v0.1.17 修正，见上面两段说明）。
    UIWindow *win = nil;
    CGFloat topBefore = DLMaxOtherWindowLevelVerbose(YES);   // 顺便把所有窗口打进日志

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = DLSceneOwningTopWindow();
        if (!scene) {
            // 兜底：前台活跃的 scene
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                if (ws.activationState == UISceneActivationStateForegroundActive) {
                    scene = ws;
                    break;
                }
                if (!scene) scene = ws;
            }
        }
        if (scene) {
            win = [[UIWindow alloc] initWithWindowScene:scene];
            DLProbe(@"decoy 使用 scene（顶层窗口所属）activation=%ld",
                    (long)scene.activationState);
        }
    }
    if (!win) {
        win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        DLProbe(@"decoy 使用 initWithFrame（无可用 scene）");
    }
    if (!win) {
        DLProbe(@"decoy 放弃：无法创建窗口");
        sShared = nil;
        return;
    }

    // ⭐ v0.1.17：层级 = max(硬编码下限, 现存最高 + 1000)
    //   —— 硬编码 100000 曾被 SpringBoard 的锁屏窗口压在下面（用户实测
    //      必须刷脸解锁后才看到假空间）。探测式取值永远压在最上面。
    CGFloat wantLevel = topBefore + 1000.0;
    if (wantLevel < 100000.0) wantLevel = 100000.0;
    win.windowLevel = wantLevel;
    win.rootViewController = vc;
    sWindow = win;   // ⭐ 自己强持有（防止宿主回收，见 sWindow 注释）
    DLProbe(@"decoy 窗口层级=%.0f（呈现前最高的其它窗口=%.0f）", wantLevel, topBefore);

    // 关键：让这个窗口能收到触摸（hidden 的窗口收不到）
    win.hidden = NO;
    [win makeKeyAndVisible];

    DLProbe(@"decoy 已呈现 windowLevel=%.0f scene=%d",
            win.windowLevel, (int)(win.windowScene != nil));
}

+ (void)dismissDecoy {
    if (!sShared) return;
    DLProbe(@"decoy 退出假空间");
    // ⭐ v0.1.18：先立「用户主动退出」标记 —— 守护循环看到它就会立刻收工，
    //    否则用户点一次退出会被守护循环在 0.5 秒内复活（表现为反复闪）。
    sUserDismissed = YES;
    sKeeperActive = NO;
    DLProbe(@"[守护] 标记用户退出：后续不再自动复活");

    UIWindow *win = sShared.view.window ?: sWindow;   // v0.1.15：兜底取强持有的窗口
    sShared = nil;
    sWindow = nil;

    // ⭐ v0.1.17：退出前把系统锁屏的密码框清干净。
    // 命中伪密码时末尾那位被我们吞掉了，框里可能残留前 N-1 位；
    // 不清掉的话用户回到锁屏再敲一位就凑成「错误密码」→ 又触发系统错误惩罚。
    @try {
        DLPrepareNativeLockScreen();
    } @catch (__unused NSException *e) { }

    // 直接销毁自建窗口（不能只 dismiss 模态 —— 窗口还在就还在屏幕上）
    if (win) {
        win.hidden = YES;
        win.rootViewController = nil;
        win.windowScene = nil;
    }
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self buildWallpaper];
    [self buildStatusArea];
    [self buildAppGrid];
    [self buildDock];
    [self buildSecretExit];
    DLProbe(@"decoy 界面构建完成 apps=%lu", (unsigned long)self.apps.count);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self tick];
}

- (BOOL)prefersStatusBarHidden { return YES; }

#pragma mark - 壁纸

- (void)buildWallpaper {
    // 渐变壁纸（不依赖任何素材文件）
    UIView *wp = [[UIView alloc] initWithFrame:self.view.bounds];
    wp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = self.view.bounds;
    g.colors = @[
        (__bridge id)[UIColor colorWithRed:0.10 green:0.14 blue:0.26 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.20 green:0.24 blue:0.42 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.34 green:0.28 blue:0.48 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.18 green:0.20 blue:0.32 alpha:1.0].CGColor,
    ];
    g.locations = @[@0.0, @0.42, @0.72, @1.0];
    g.startPoint = CGPointMake(0.1, 0.0);
    g.endPoint = CGPointMake(0.9, 1.0);
    [wp.layer addSublayer:g];
    self.wallpaperView = wp;

    CAGradientLayer *gl = (CAGradientLayer *)wp.layer.sublayers.firstObject;
    gl.frame = wp.bounds;
    [self.view addSubview:wp];

    // ⚠️ kCALayerWidthSizable / kCALayerHeightSizable 在 iOS SDK 里被标记
    //    unavailable（是 macOS 的 API），用它们直接编译失败。
    //    UIView 的 autoresizingMask 已能保证 wrap 跟随父视图，渐变层在
    //    viewDidLayoutSubviews / viewLayoutMarginsDidChange 里随 bounds 重设 frame。
}

#pragma mark - 状态区（时间 / 日期 / 机型名）

- (void)buildStatusArea {
    CGFloat w = self.view.bounds.size.width;
    BOOL large = w > 400.0;

    NSString *title = DLDecoyTitle();
    NSString *sub = DLDecoySubtitle();

    // 副标题非空时并到标题行（保持行数固定，避免复杂布局）
    if (sub.length) {
        title = [NSString stringWithFormat:@"%@ · %@", title, sub];
    }

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = title;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    self.titleLabel.font = [UIFont systemFontOfSize:large ? 15.0 : 14.0
                                                  weight:UIFontWeightMedium];
    self.titleLabel.userInteractionEnabled = YES;
    [self.view addSubview:self.titleLabel];

    self.clockLabel = [[UILabel alloc] init];
    self.clockLabel.textAlignment = NSTextAlignmentCenter;
    self.clockLabel.textColor = [UIColor whiteColor];
    self.clockLabel.font = [UIFont fontWithName:@"HelveticaNeue-Thin"
                                          size:large ? 76.0 : 68.0];
    if (!self.clockLabel.font) {
        self.clockLabel.font = [UIFont systemFontOfSize:72.0 weight:UIFontWeightThin];
    }
    self.clockLabel.userInteractionEnabled = YES;
    [self.view addSubview:self.clockLabel];

    self.dateLabel = [[UILabel alloc] init];
    self.dateLabel.textAlignment = NSTextAlignmentCenter;
    self.dateLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    self.dateLabel.font = [UIFont systemFontOfSize:large ? 17.0 : 16.0
                                                  weight:UIFontWeightRegular];
    [self.view addSubview:self.dateLabel];

    // 布局
    CGFloat topSafe = self.view.safeAreaInsets.top;
    if (topSafe < 20.0) topSafe = 44.0;

    self.titleLabel.frame = CGRectMake(0, topSafe + 4.0, w, 20.0);
    self.clockLabel.frame = CGRectMake(0, topSafe + 26.0, w, large ? 84.0 : 76.0);
    self.dateLabel.frame = CGRectMake(0, CGRectGetMaxY(self.clockLabel.frame) + 2.0, w, 22.0);

    // 状态栏区域双击 → 隐藏退出（8 次点击）
    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc]
                                 initWithTarget:self action:@selector(onStatusTap:)];
    [self.titleLabel addGestureRecognizer:t];
}

- (void)onStatusTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    self.statusBarTaps += 1;
    DLProbe(@"decoy 状态区点击数=%ld", (long)self.statusBarTaps);
    if (self.statusBarTaps >= 8) {
        self.statusBarTaps = 0;
        [DLDecoyController dismissDecoy];
    }
}

- (void)buildAppGrid {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    CGFloat w = self.view.bounds.size.width;
    NSInteger cols = (w > 400.0) ? 4 : 4;
    CGFloat side = 18.0;
    CGFloat gap = 12.0;
    CGFloat itemW = (w - side * 2.0 - gap * (cols - 1)) / (CGFloat)cols;
    layout.itemSize = CGSizeMake(itemW, 84.0);
    layout.minimumInteritemSpacing = gap;
    layout.minimumLineSpacing = 20.0;
    layout.sectionInset = UIEdgeInsetsMake(14.0, side, 14.0, side);
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;

    CGFloat gridTop = CGRectGetMaxY(self.dateLabel.frame) + 26.0;
    CGFloat dockH = 96.0;
    [self.view layoutIfNeeded];

    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectZero
                                             collectionViewLayout:layout];
    cv.backgroundColor = [UIColor clearColor];
    cv.dataSource = self;
    cv.delegate = self;
    cv.showsVerticalScrollIndicator = NO;
    cv.alwaysBounceVertical = NO;
    [cv registerClass:[DLDecoyAppCell class] forCellWithReuseIdentifier:kDLCellID];
    self.appGrid = cv;
    [self.view addSubview:cv];

    CGFloat h = self.view.bounds.size.height - gridTop - dockH - 12.0;
    if (h < 120.0) h = 120.0;
    cv.frame = CGRectMake(0, gridTop, w, h);
}

- (void)buildDock {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat dockH = 92.0;
    CGFloat botSafe = self.view.safeAreaInsets.bottom;
    if (botSafe < 8.0) botSafe = 20.0;

    UIView *dock = [[UIView alloc] initWithFrame:CGRectMake(12.0,
                                                           h - dockH - botSafe + 6.0,
                                                           w - 24.0,
                                                           dockH)];
    dock.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    dock.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];

    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.frame = dock.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 30.0;
    blur.layer.masksToBounds = YES;
    [dock addSubview:blur];

    dock.layer.cornerRadius = 30.0;
    dock.layer.masksToBounds = YES;
    dock.layer.borderWidth = 0.5;
    dock.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;

    // Dock 里放 4 个固定图标
    NSArray *dockIDs = @[@"phone", @"message", @"safari", @"camera"];
    NSArray *all = DLAllFakeApps();
    CGFloat itemW = (w - 24.0) / (CGFloat)dockIDs.count;
    for (NSUInteger i = 0; i < dockIDs.count; i++) {
        NSDictionary *app = nil;
        for (NSDictionary *a in all) {
            if ([a[@"id"] isEqualToString:dockIDs[i]]) { app = a; break; }
        }
        if (!app) continue;
        DLDecoyAppCell *cell = [[DLDecoyAppCell alloc]
                                initWithFrame:CGRectMake(i * itemW, 4.0, itemW, 84.0)];
        [cell configureWithApp:app];
        [dock addSubview:cell];
    }

    self.dock = dock;
    [self.view addSubview:dock];

    // ⭐ v0.1.16：Dock 里的图标也能点（点中「退出 App」同样退出）
    dock.userInteractionEnabled = YES;
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc]
                                  initWithTarget:self action:@selector(onDockTap:)];
    [dock addGestureRecognizer:dt];
}

- (void)buildSecretExit {
    // 长按壁纸 3 秒 → 退出假空间（隐藏入口）
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 3.0;
    [self.wallpaperView addGestureRecognizer:lp];
    self.wallpaperView.userInteractionEnabled = YES;
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    DLProbe(@"decoy 长按触发退出");
    [DLDecoyController dismissDecoy];
}

#pragma mark - 时钟

- (void)viewLayoutMarginsDidChange {
    [super viewLayoutMarginsDidChange];
    [self relayoutForBounds];

    // 渐变壁纸跟着新尺寸重设（CALayer 不参与 Auto Layout，必须手动同步）
    for (CALayer *l in self.wallpaperView.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) {
            l.frame = self.wallpaperView.bounds;
        }
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self relayoutForBounds];
    for (CALayer *l in self.wallpaperView.layer.sublayers) {
        if ([l isKindOfClass:[CAGradientLayer class]]) {
            l.frame = self.wallpaperView.bounds;
        }
    }
}

- (void)relayoutForBounds {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat dockH = 92.0;
    CGFloat botSafe = self.view.safeAreaInsets.bottom;
    if (botSafe < 8.0) botSafe = 20.0;
    self.dock.frame = CGRectMake(12.0, h - dockH - botSafe + 6.0, w - 24.0, dockH);
    CGFloat gridTop = CGRectGetMaxY(self.dateLabel.frame) + 26.0;
    CGFloat gh = h - gridTop - dockH - 12.0;
    if (gh < 120.0) gh = 120.0;
    self.appGrid.frame = CGRectMake(0, gridTop, w, gh);
}

- (void)tick {
    NSDate *now = [NSDate date];
    NSDateFormatter *tf = [[NSDateFormatter alloc] init];
    tf.dateFormat = @"HH:mm";
    self.clockLabel.text = [tf stringFromDate:now];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    df.dateFormat = @"M月d日 EEEE";
    self.dateLabel.text = [df stringFromDate:now];
}

#pragma mark - 数据源

- (NSArray *)apps {
    if (_apps) return _apps;
    NSMutableArray *list = [NSMutableArray array];
    NSArray *all = DLAllFakeApps();
    for (NSString *ident in DLDecoyApps()) {
        for (NSDictionary *a in all) {
            if ([a[@"id"] isEqualToString:ident]) { [list addObject:a]; break; }
        }
    }
    _apps = [list copy];
    return _apps;
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return (NSInteger)self.apps.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    DLDecoyAppCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kDLCellID forIndexPath:ip];
    if (ip.item < (NSInteger)self.apps.count) {
        [cell configureWithApp:self.apps[ip.item]];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [cv deselectItemAtIndexPath:ip animated:NO];
    if (ip.item >= (NSInteger)self.apps.count) return;
    NSDictionary *app = self.apps[ip.item];
    [self handleFakeAppTap:app[@"id"] name:app[@"name"]];
}

#pragma mark - ⭐ v0.1.16 统一的 App 点击处理（网格 + Dock 共用）

// 规则：点「退出 App」→ 直接退出假空间；点其它 App → 仿系统的「无法打开」提示。
- (void)handleFakeAppTap:(NSString *)appID name:(NSString *)name {
    if (!appID.length) return;

    NSString *exitID = DLDecoyExitApp();
    DLProbe(@"decoy 点击假 App %@(%@) exitApp=%@",
            name ?: @"?", appID, exitID.length ? exitID : @"(未设置)");

    // ⭐ 点到了指定的「退出 App」→ 退出
    if (exitID.length && [exitID isEqualToString:appID]) {
        DLProbe(@"*** 点中退出 App（%@）→ 退出假空间", name ?: appID);
        [DLDecoyController dismissDecoy];
        return;
    }

    // 其它 App：假空间是空壳，弹一个仿系统的「无法打开」
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:name ?: @"App"
                         message:@"此设备尚未启用该应用。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Dock 点击：Dock 里的图标不是 collectionView cell，单独挂手势。
// 用 hitTest 反查被点中的 DLDecoyAppCell（图标/文字都设了 userInteractionEnabled=NO，
// 命中点必然落在 cell 本身）。
- (void)onDockTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.dock];
    UIView *v = [self.dock hitTest:p withEvent:nil];
    while (v && ![v isKindOfClass:[DLDecoyAppCell class]]) v = v.superview;
    DLDecoyAppCell *cell = (DLDecoyAppCell *)v;
    if (!cell) return;
    [self handleFakeAppTap:cell.appID name:cell.nameLabel.text];
}

@end
