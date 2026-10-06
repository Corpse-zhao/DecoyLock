#import <UIKit/UIKit.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
// MSHookMessageEx —— 用 objc_getClassList 枚举挂钩需要它（见 Hook 组 C）
// substrate.h 由 Theos 提供（$THEOS/vendor/include），用 __has_include 做容错：
// 万一某天 theos 分支把 vendor 头挪了位置，退回手动声明，不至于编译挂掉。
#if __has_include(<substrate.h>)
#import <substrate.h>
#elif __has_include(<CydiaSubstrate/CydiaSubstrate.h>)
#import <CydiaSubstrate/CydiaSubstrate.h>
#else
// 手动声明（ElleKit / libhooker 环境同样导出这个符号）
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);
#endif
#import "DLCommon.h"
#import "DLDecoyController.h"

// ===========================================================================
// 伪锁屏 · SpringBoard 侧钩子（v0.1.14 主动取词版）
// ===========================================================================
//
// ⭐⭐ v0.1.14 架构转向（前 13 版全部在「等系统回调」，这条路已证明走不通）
//
//   v0.1.13 日志的决定性证据：
//     用户敲完 6 位密码 → 系统**没有**执行
//       coverSheetViewController:unlockWithRequest:completion:      （0 次）
//       coverSheetPresentationManager:unlockWithRequest:completion: （0 次）
//       它直接走了：
//         23:00:29.812 [侦查] SBUIPasscodeLockViewSimpleFixedDigitKeypad -resetForFailedPasscode
//         23:00:29.814 [失败回调] ★ resetForFailedPasscode → 系统判定密码错误
//     → 密码错误路径上，系统**不外露任何携带密码的调用**。
//       挂再多系统方法也只能知道「错了」，永远拿不到「错的是什么」。
//
//   ✅ 新思路：不问了，自己数。
//      Hook 组 A 从 v0.1.9 起就 100% 能拿到用户每次按键（日志可证）。
//      所以插件自己做比对：输入长度 = 伪密码长度时，立刻比对；
//        命中 → 自己把假空间盖上去（不等系统，且覆盖系统随后的错误界面）
//        不命中 → 什么都不做，系统原生流程照跑（用户看到正常的错误+锁定）
//
//   安全性：不吞系统调用、不改写返回值、不等系统回调。
//           判断错误最多是「没进/多进假空间」，绝不可能锁死设备。
//
// ---------------------------------------------------------------------------
// （以下为历史沿革，保留作为踩坑记录）
//
// v0.1.5 的三个致命错误（已在 v0.1.8 全部修掉）：
//
//  ❌ 错误 1：%hook UIResponder / -insertText:
//     `insertText:` 不是 UIResponder 自己实现的方法，而是 UIKeyInput 协议要求
//     的实现方方法。对一个不实现它的类做 %hook，Logos 生成的
//     class_getInstanceMethod 拿到 NULL，`%orig;` 在 dylib 里就是跳 NULL →
//     SpringBoard 一按键盘就崩（或静默失效）。**必须挂在真正实现它的类上。**
//
//  ❌ 错误 2：%hook NSObject / -setText:
//     灾难性写法。`setText:` 不是 NSObject 的方法，Logos 会把它当成
//     NSObject 的分类方法加进类里 → 运行时对**整个进程的所有对象**暴露
//     `-setText:`，任何消息转发/响应性探测（respondsToSelector:）都会被污染。
//
//  ❌ 错误 3：钩子目标全是「猜测的类名」
//     Logos 对不存在的类/方法**不报错**，CI 全绿、装上也毫无反应。
// ===========================================================================

static NSString *const kDLBundleID = @"com.apple.springboard";

// 判定窗口：密码框最后一次被写入后，多久内的解锁调用算数
static const NSTimeInterval kDLWindowSeconds = 25.0;

// 记录密码框当前内容 + 最近一次写入的时间戳
static NSMutableString *gDLInput = nil;
static CFAbsoluteTime   gDLInputStamp = 0.0;
static NSString        *gDLLastSrc = @"";

// ⭐⭐ v0.1.17：抑制系统提交（本版核心）
//
// 用户反馈：「输入假密码后还是显示密码错误，然后还要刷脸才能进入假空间」
//   → 说明两件事同时成立：
//     ① 系统**真的收到了**这 6 位伪密码，所以走了「验证失败」流程
//        （显示密码错误 + 触发刷脸重试 + 累计错误次数锁定）
//     ② 我们的假空间窗口其实在锁屏 UI **底下**，所以「密码错误/刷脸」看得见，
//        必须等刷脸把锁屏顶掉，假空间才露出来
//
//  修法（配合 DLDecoyController 的窗口层级修正）：
//    判定命中伪密码的那一刻，**把这一位按键吞掉，不交给系统** ——
//    系统的密码框永远收不满 6 位，就不会触发校验，
//    自然没有「密码错误」、没有刷脸、也没有锁定惩罚。
//    随后我们自己的假空间（此时已在最上层）立刻盖上来 → 体感是「秒进」。
//
//  ⚠️ 只吞「伪密码」这一次；真实密码一位都不会少（假密码 ≠ 真密码 → 不吞）。
static BOOL          gDLSuppressOrig = NO;    // 是否吞掉下一次系统调用
static CFAbsoluteTime gDLSuppressAt  = 0.0;   // 设置时间（防止迟到消费）

// 安全清空密码框：
//   ⚠️ 绝不用 [field clear] / %orig(@"") —— 这两个都依赖「原实现存在」，
//      如果该类没实现（或 Logos 给不存在的类补了方法），%orig 就是跳 NULL → 崩。
//      做法：用 MSHookMessageEx 手动挂 clear 并**保存原 IMP**，只有拿非 NULL
//      才调用；否则退回到「清内部真正的 UITextField」（UIKit 公开 API，零风险）。
static IMP gDLOrigClear = NULL;

static NSMutableString *DLInputBuffer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDLInput = [NSMutableString string];
    });
    return gDLInput;
}

static BOOL DLIsSpringBoard(void) {
    static BOOL isSB = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        isSB = [bid isEqualToString:kDLBundleID];
    });
    return isSB;
}

static void DLResetInput(void) {
    [DLInputBuffer() setString:@""];
    gDLInputStamp = 0.0;
}

// v0.1.10：输入捕获自检（定义在后面，先声明）
static void DLLogInputCapture(NSString *src);

// v0.1.17：清空密码框（定义在后面 Hook 组 A 之前，先声明 —— 视图树遍历要用）
static void DLClearField(id field);

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.19 安全拆除：只在「假空间已经展示了一会儿」时才动手拆。
//
// 为什么需要它（2026-10-06 实测事故）：
//   用户反馈「正常输入密码界面点不动了」。根因是我们自建的高层级窗口
//   在锁屏消失 / 用户去解锁时**没有被拆掉**，变成了一个看不见却挡触摸的挡板。
//   而 `[win makeKeyAndVisible]` 还会把系统锁屏的 key window 抢走，
//   我们一隐藏窗口，锁屏就彻底接不到触摸。
//
// 但也不能无脑拆 —— 我们「吞掉密码最后一位」这个动作本身就会让系统的
// 锁屏 UI 发生变动，可能顺带触发锁屏生命周期回调。所以加一个时间闸：
// 只有展示时长超过 `after` 秒（说明不是我们刚铺上去的）才允许拆。
// ---------------------------------------------------------------------------
static void DLSafeTeardownIfStale(NSTimeInterval after, const char *why) {
    if (!DLIsSpringBoard()) return;
    if (![DLDecoyController isShowing]) return;
    NSTimeInterval d = [DLDecoyController shownDuration];
    if (d < 0.0 || d < after) return;
    DLProbe(@"[安全] %s（假空间已展示 %.1fs > %.0fs）→ 拆除窗口，把锁屏还给系统",
            why, d, after);
    [DLDecoyController forceTeardown];
}

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.19 键盘保护阀（fail-open 的最后一道闸）
//
// 事故背景：v0.1.17 引入「命中伪密码就吞掉这一位按键」，本意是让系统收不满密码
// 从而不判错。但这套机制一旦被误触发（例如用户把伪密码设成了真实密码、
// 或判定逻辑出现异常），**用户就再也无法用密码解锁** —— 这是不可接受的。
//
// 所以加一个硬闸：不管什么原因，只要「吞键」在短时间内过于频繁，
// 就立刻停止吞键、把控制权完全交还系统。功能可以失效，设备不能锁死。
// ---------------------------------------------------------------------------
static BOOL DLSafeToSuppress(void) {
    static CFAbsoluteTime windowStart = 0.0;
    static int count = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 10.0) {
        windowStart = now;
        count = 0;
    }
    count++;
    if (count > 3) {
        DLProbe(@"!!! [保护阀] 10 秒内已吞键 %d 次 → 停止吞键（fail-open，键盘保证可用）",
                count);
        return NO;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.14 核心：输入长度够了就**主动**判定，不再等系统回调
//
// 这是本版与 v0.1.13 的唯一本质区别：
//   旧：输入 → 等系统调用某个带密码的方法 → 在那里面比对（等不到，永远不触发）
//   新：输入 → 自己发现「够位数了」→ 自己去比对（不依赖系统任何行为）
//
// 只在「长度恰好等于伪密码位数」时触发一次，避免每敲一键都跑一遍；
// 判完之后把缓冲清掉，防止同一次输入被判两次。
// ---------------------------------------------------------------------------
static void DLTriggerActiveVerdict(NSString *src) {
    if (!DLIsSpringBoard()) return;

    NSString *digits = [DLInputBuffer() copy];
    NSUInteger need = DLDecoyPasscode().length;

    // 长度没到 / 超过 → 不判（超过说明用户在继续输入，交给系统原生流程）
    if (need == 0 || digits.length != need) return;

    // ⚠️ 防重复（v0.1.15 修正）：只挡「2 秒内的同串重复判定」。
    //    v0.1.14 用的是永久 static 去重 —— 跨锁屏会话残留，用户第二次输入
    //    同样的伪密码会被误判为「已判定过 → 跳过」（2026-10-06 实测日志实锤：
    //    45.852 一行 `151111 已判定过 → 跳过`，主判定路径被拦，靠兜底救回）。
    //    时间窗的用意：同一次输入里 setText/append 可能双触发（毫秒级），
    //    挡住它们就够了；新一轮尝试必然间隔 >2 秒，绝不能拦。
    static NSString *lastJudged = nil;
    static CFAbsoluteTime lastJudgeAt = 0;
    CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
    if (lastJudged && [lastJudged isEqualToString:digits] &&
        (nowT - lastJudgeAt) < 2.0) {
        DLProbe(@"[主动判定] %@ 刚判定过（%.1f 秒内）→ 跳过",
                digits, nowT - lastJudgeAt);
        return;
    }
    lastJudged = [digits copy];
    lastJudgeAt = nowT;

    DLProbe(@"[主动判定] 输入已达 %lu 位（源=%@）→ 开始比对伪密码",
            (unsigned long)digits.length, src);

    DLPasscodeVerdict v = [DLDecoyController handleCapturedPasscode:digits];

    if (v == DLPasscodeVerdictDecoy) {
        // ⭐ v0.1.19：吞键之前先过「键盘保护阀」。
        //    理由：吞键是**唯一**能让用户键盘失效的机制（万一伪密码被设成了真实密码，
        //    或者判定逻辑被写成每键都命中，就会把用户彻底锁在外面）。
        //    10 秒内超过 3 次就判定异常，立刻停止吞键 —— 宁可功能失效，绝不锁死键盘。
        if (!DLSafeToSuppress()) {
            DLProbe(@"!!! [主动判定] 吞键次数异常 → 本次不吞，交给系统（fail-open）");
        } else {
            gDLSuppressOrig = YES;
            gDLSuppressAt = CFAbsoluteTimeGetCurrent();
            DLProbe(@"[主动判定] ✅ 命中伪密码 → 已挂起「抑制系统提交」（无密码错误/无刷脸/无锁定）");
        }
        DLResetInput();       // 清掉，避免残留影响下一次
    } else {
        DLProbe(@"[主动判定] ➡️ 非伪密码 → 不干预，交给系统原生流程");
        // ⚠️ 不清空：不清空的话用户继续输入时 lastJudged 逻辑仍能防重；
        //    清空的话会丢掉「用户真实密码」的痕迹，没必要。
    }
}

// ---------------------------------------------------------------------------
// v0.1.17：判断「抑制」是否仍然有效（防止跨调用误吞）
// 命中判定与消费抑制的调用栈是紧挨着的（同一个 hook 内），
// 这里只做 2 秒保险，避免任何异常路径把 flag 留到下一次输入。
// ---------------------------------------------------------------------------
static BOOL DLConsumeSuppress(void) {
    if (!gDLSuppressOrig) return NO;
    BOOL ok = (CFAbsoluteTimeGetCurrent() - gDLSuppressAt) < 2.0;
    gDLSuppressOrig = NO;       // 无论如何都消费掉
    return ok;
}

// ---------------------------------------------------------------------------
// 覆盖式写入：密码框给什么，缓冲就是什么。
// 直接用 setText: 的真实内容，比「自己 append 按键」准确得多
// （退格、粘贴、自动填充全都自动正确）。
// ---------------------------------------------------------------------------
static void DLSetInput(NSString *text, NSString *src) {
    if (!DLIsSpringBoard()) return;

    NSString *t = text ?: @"";
    [DLInputBuffer() setString:t];
    gDLInputStamp = CFAbsoluteTimeGetCurrent();
    gDLLastSrc = src ?: @"?";

    DLProbe(@"[输入] 源=%@ 内容=%@ len=%lu",
            gDLLastSrc, t.length ? t : @"(空)", (unsigned long)t.length);
    DLLogInputCapture(gDLLastSrc);
    DLTriggerActiveVerdict(gDLLastSrc);          // ⭐ v0.1.14 主动判定
}

static void DLAppendInput(NSString *text, NSString *src) {
    if (!DLIsSpringBoard() || !text.length) return;
    [DLInputBuffer() appendString:text];
    if (DLInputBuffer().length > 64) {
        [DLInputBuffer() setString:
            [DLInputBuffer() substringFromIndex:DLInputBuffer().length - 32]];
    }
    gDLInputStamp = CFAbsoluteTimeGetCurrent();
    gDLLastSrc = src ?: @"?";
    DLProbe(@"[输入] 源=%@ 追加=%@ 结果 len=%lu",
            gDLLastSrc, text, (unsigned long)DLInputBuffer().length);
    DLLogInputCapture(gDLLastSrc);      // v0.1.10：长度够了就打一行
    DLTriggerActiveVerdict(gDLLastSrc); // ⭐ v0.1.14 主动判定
}

// ---------------------------------------------------------------------------
// yield 兜底：直接去视图树里把密码框的文本抠出来。
// 完全不依赖任何钩子是否命中 —— 这是本版的主路径。
// ---------------------------------------------------------------------------

@interface UIView (DLTextSniff)
@end
@implementation UIView (DLTextSniff)

static void DLScanPasscodeText(UIView *v, NSString **out, int depth) {
    if (!v || *out || depth > 14) return;

    NSString *cls = NSStringFromClass([v class]);
    BOOL looksPasscode = [cls containsString:@"Passcode"] ||
                         [cls containsString:@"Pearl"] ||
                         [cls containsString:@"PasscodeEntry"];
    // 排除设置/添加密码那种「旧密码+新密码」的界面
    BOOL looksSetup = [cls containsString:@"ChangePasscode"] ||
                      [cls containsString:@"PasscodeSet"] ||
                      [cls containsString:@"PasscodeCreation"];

    if (looksPasscode && !looksSetup) {
        SEL sel = @selector(text);
        if ([v respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id t = [v performSelector:sel];
#pragma clang diagnostic pop
            if ([t isKindOfClass:[NSString class]] && [(NSString *)t length]) {
                *out = [(NSString *)t copy];
                return;
            }
        }
    }
    for (UIView *sub in v.subviews) {
        DLScanPasscodeText(sub, out, depth + 1);
        if (*out) return;
    }
}

@end

// 把当前锁屏密码框的文本抠出来（找不到返回 nil）
static NSString *DLSniffPasscodeFromWindows(void) {
    if (!DLIsSpringBoard()) return nil;

    NSMutableArray *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                [wins addObjectsFromArray:((UIWindowScene *)sc).windows];
            }
        }
    }
    if (!wins.count) [wins addObjectsFromArray:UIApplication.sharedApplication.windows];

    for (UIWindow *w in wins) {
        NSString *found = nil;
        DLScanPasscodeText(w, &found, 0);
        if (found.length) return found;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// ⭐ v0.1.17：在视图树里找「密码输入框对象」本身（不是它的文本）
//   退出假空间前要用它把锁屏密码框清干净，否则用户回到锁屏会看到半截密码，
//   再敲一位就凑成一个错误密码 → 又触发系统错误惩罚（很坑）。
// ---------------------------------------------------------------------------
static UIView *DLFindPasscodeFieldIn(UIView *v, int depth) {
    if (!v || depth > 24) return nil;

    NSString *cls = NSStringFromClass([v class]);
    BOOL isEntry = [cls containsString:@"PasscodeEntryField"] ||
                   [cls containsString:@"FixedDigitPasscodeEntry"];
    BOOL isSetup = [cls containsString:@"ChangePasscode"] ||
                   [cls containsString:@"PasscodeSet"] ||
                   [cls containsString:@"PasscodeCreation"];
    if (isEntry && !isSetup) return v;

    for (UIView *sub in v.subviews) {
        UIView *r = DLFindPasscodeFieldIn(sub, depth + 1);
        if (r) return r;
    }
    return nil;
}

static UIView *DLFindPasscodeField(void) {
    if (!DLIsSpringBoard()) return nil;

    NSMutableArray *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                [wins addObjectsFromArray:((UIWindowScene *)sc).windows];
            }
        }
    }
    if (!wins.count) [wins addObjectsFromArray:UIApplication.sharedApplication.windows];

    for (UIWindow *w in wins) {
        UIView *f = DLFindPasscodeFieldIn(w, 0);
        if (f) return f;
    }
    return nil;
}

// ⭐ v0.1.17：退出假空间前调用 —— 把系统锁屏的密码框清干净
//（导出给 DLDecoyController 用，见 DLCommon.h 声明）
void DLPrepareNativeLockScreen(void) {
    if (!DLIsSpringBoard()) return;
    @try {
        UIView *field = DLFindPasscodeField();
        if (field) {
            DLProbe(@"[退出清理] 找到密码框 %@ → 清空",
                    NSStringFromClass(object_getClass(field)));
            DLClearField(field);
        } else {
            DLProbe(@"[退出清理] 未找到密码框（可能锁屏已收起，正常）");
        }
        DLResetInput();
    } @catch (__unused NSException *e) { }
}

// ---------------------------------------------------------------------------
// 判定：是否应当劫持这次解锁
// ---------------------------------------------------------------------------
static BOOL DLShouldHijackUnlock(NSString *from) {
    if (!DLIsSpringBoard()) return NO;
    if (!DLEnabled()) {
        DLProbe(@"[判定] 来自 %@ 但插件未启用 → 放行", from);
        return NO;
    }

    NSString *decoy = DLDecoyPasscode();
    if (!decoy.length) {
        DLProbe(@"[判定] 来自 %@ 但未配置伪密码 → 放行", from);
        return NO;
    }

    // ---- 第一步：先看钩子缓冲 ----
    NSString *input = [DLInputBuffer() copy];
    NSTimeInterval age = gDLInputStamp > 0
        ? CFAbsoluteTimeGetCurrent() - gDLInputStamp : 1e9;

    DLProbe(@"[判定] 来自 %@ 缓冲=%@(len=%lu, 源=%@, %.1fs前) 期望=%@",
            from, input.length ? input : @"(空)",
            (unsigned long)input.length, gDLLastSrc, age, decoy);

    // ---- 第二步：钩子没抓到 → 直接抠视图树（yield 主路径）----
    if (!input.length || age > kDLWindowSeconds) {
        NSString *sniffed = DLSniffPasscodeFromWindows();
        DLProbe(@"[判定] yield 抠取结果=%@", sniffed.length ? sniffed : @"(失败)");
        if (sniffed.length) {
            input = sniffed;
            age = 0.0;
        }
    }

    if (!input.length) {
        DLProbe(@"[判定] 无输入可用 → 放行（不干预）");
        return NO;
    }

    if (age > kDLWindowSeconds) {
        DLProbe(@"[判定] 输入已过期（%.1fs > %.0fs）→ 放行", age, kDLWindowSeconds);
        return NO;
    }

    if (![input isEqualToString:decoy]) {
        DLProbe(@"[判定] 不匹配伪密码 → 放行");
        return NO;
    }

    // ---- 命中！----
    DLProbe(@"*** 命中伪密码（来源 %@）→ 劫持解锁，呈现假空间", from);
    DLResetInput();

    dispatch_async(dispatch_get_main_queue(), ^{
        [DLDecoyController presentIfConfigured];
    });
    return YES;
}

// ===========================================================================
// Hook 组 A：密码输入框（真正实现 setText: 的类）
// ⭐ v0.1.14：这里是**主动取词的主入口** —— appendString:/setText: 一命中，
//    立刻检查长度，够位数就直接比对（见 DLTriggerActiveVerdict）。
// ===========================================================================

// 侦查挂钩（定义在 Hook 组 C2，先给前向声明 —— C 要求先声明后用）
static void DLReconOpenWindow(void);
static void DLEnsureReconForPasscodeField(id field);

// ---------------------------------------------------------------------------
// ⭐ v0.1.17：安全清空密码框
//   触发场景：命中伪密码后吞掉按键，此时框里还留着前 N-1 位，
//   要清干净，否则用户退出假空间后会看到半截密码（再敲一位就会凑成错误密码）。
//
//   ⚠️ 为什么不用 [field clear]：该类的 clear 不一定存在，Logos 给不存在的
//      方法补 hook 后 %orig 就是跳 NULL → 直接崩。改用 MSHookMessageEx 手动挂，
//      只有拿到非 NULL 的原 IMP 才调用（见 DLSetupClearHook）。
//   ⚠️ 为什么不用 %orig(@""): 同理依赖原实现存在。
//   兜底：清内部真正的 UITextField（UIKit 公开 API，零风险）。
// ---------------------------------------------------------------------------
static void DLClearField(id field) {
    if (!field) return;

    if (gDLOrigClear) {
        @try {
            ((void (*)(id, SEL))gDLOrigClear)(field, @selector(clear));
            DLProbe(@"[抑制] 已用原生 clear 清空密码框");
            return;
        } @catch (__unused NSException *e) { }
    }

    // 兜底：清内部 UITextField（最多下探 3 层）
    if ([field isKindOfClass:[UITextField class]]) {
        [(UITextField *)field setText:@""];
        DLProbe(@"[抑制] 已清空内部 UITextField");
        return;
    }
    if ([field isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)field;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
        int guard = 0;
        while (stack.count && guard++ < 40) {
            UIView *cur = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if ([cur isKindOfClass:[UITextField class]]) {
                [(UITextField *)cur setText:@""];
                DLProbe(@"[抑制] 已清空子视图里的 UITextField");
                return;
            }
            [stack addObjectsFromArray:cur.subviews];
        }
    }
    DLProbe(@"[抑制] 未能清空密码框（无可用途径）");
}

@interface SBUIPasscodeEntryField : UIView
@end

%hook SBUIPasscodeEntryField
// ⚠️ 顺序很重要（v0.1.17 调整）：**先判定、后放行**。
//    旧版是 %orig 在前，等于系统已经吃下这一位我们才判定 —— 太晚了。
- (void)appendString:(NSString *)s {
    DLAppendInput(s, @"entry.append");     // 更新缓冲 + 主动判定（内部会设抑制标志）

    if (DLConsumeSuppress()) {
        DLProbe(@"[抑制] 吞掉这一位「%@」→ 系统收不满密码，不会触发校验",
                s ?: @"?");
        DLClearField(self);                // 清掉前 N-1 位残留
        return;                            // ⚠️ 不调 %orig：系统拿不到这一位
    }

    %orig;
    DLReconOpenWindow();
    // v0.1.10：每次输入都沿「视图/响应者/delegate」链上行侦查（内部幂等）
    DLEnsureReconForPasscodeField(self);
}
- (void)setText:(NSString *)text {
    DLSetInput(text, @"entry.set");        // 先判定（同上，顺序调整）
    DLReconOpenWindow();

    if (DLConsumeSuppress()) {
        DLProbe(@"[抑制] 吞掉这次 setText（len=%lu）→ 系统不会看到完整伪密码",
                (unsigned long)(text ? text.length : 0));
        DLClearField(self);
        return;                            // ⚠️ 不调 %orig
    }

    %orig;
}
- (void)deleteBackward {
    %orig;
    if (DLInputBuffer().length) {
        [DLInputBuffer() deleteCharactersInRange:
            NSMakeRange(DLInputBuffer().length - 1, 1)];
        gDLInputStamp = CFAbsoluteTimeGetCurrent();
        gDLLastSrc = @"entry.del";
    }
}
%end

// ---------------------------------------------------------------------------
// v0.1.17：clear 改为**手动挂钩**（不再用 Logos %hook）
//
// 旧版 `%hook SBUIPasscodeEntryField - (void)clear` 有隐患：
// 如果该类根本没实现 clear，Logos 仍会把方法加到类上（%orig 指向 NULL），
// 一旦有代码调用 / respondsToSelector: 探测到并调用 → 跳 NULL 崩溃。
// 手动挂钩能**拿到原 IMP 并判空**，这才安全 —— 而且 DLClearField 正好需要它
// 来安全清空密码框（见上面的说明）。
// ---------------------------------------------------------------------------
static void DLHookedClear(id self, SEL _cmd) {
    if (gDLOrigClear) ((void (*)(id, SEL))gDLOrigClear)(self, _cmd);
    DLResetInput();
    DLProbe(@"[输入] 源=entry.clear 已清空");
}

static void DLSetupClearHook(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    Class c = NSClassFromString(@"SBUIPasscodeEntryField");
    if (!c) {
        DLProbe(@"[挂钩] clear：找不到 SBUIPasscodeEntryField（跳过）");
        return;
    }
    if (!class_getInstanceMethod(c, @selector(clear))) {
        // ⚠️ DLProbe 带 NS_FORMAT_FUNCTION(1,2)，字面 % 必须写成 %%
        DLProbe(@"[挂钩] clear：该类未实现 → 不挂钩（避免 %%orig 跳 NULL）");
        return;
    }
    MSHookMessageEx(c, @selector(clear), (IMP)&DLHookedClear, &gDLOrigClear);
    DLProbe(@"[挂钩] ✅ SBUIPasscodeEntryField clear（orig=%p）", (void *)gDLOrigClear);
}

// ===========================================================================
// Hook 组 B：键盘删除键（UITextField 是密码框内部真正的编辑视图）
// ===========================================================================

%hook UITextField
- (void)deleteBackward {
    %orig;
    if (!DLIsSpringBoard()) return;
    NSString *cls = NSStringFromClass(object_getClass(self));
    BOOL related = [cls containsString:@"Passcode"] ||
                   [cls containsString:@"Pearl"];
    if (!related) {
        // 也可能是被 SBUIPasscodeEntryField 持有的普通 UITextField
        UIView *p = self.superview;
        int guard = 0;
        while (p && guard++ < 6) {
            NSString *pc = NSStringFromClass([p class]);
            if ([pc containsString:@"Passcode"] || [pc containsString:@"Pearl"]) {
                related = YES;
                break;
            }
            p = p.superview;
        }
    }
    if (related && DLInputBuffer().length) {
        [DLInputBuffer() deleteCharactersInRange:
            NSMakeRange(DLInputBuffer().length - 1, 1)];
        gDLInputStamp = CFAbsoluteTimeGetCurrent();
        gDLLastSrc = @"tf.del";
        DLProbe(@"[输入] 源=tf.del 退格后 len=%lu", (unsigned long)DLInputBuffer().length);
    }
}
%end

// ===========================================================================
// Hook 组 C：解锁判定点 —— 用 objc_getClassList 全类枚举，不赌类名
//
// ⭐ 为什么不能写 `%hook $` / `- (BOOL)$foo:`（已从 Logos 源码实锤，别被网上
//    「$ 是通配符」的说法骗了）：
//
//    Logos 里 `$` 的**唯一**用途是「符号名分隔符」——
//    logos.pl:14  `sub sigil { return "_logos_".join("\$", @_); }`
//    生成的符号长这样：`_logos_method$_ungrouped$ClassName$selector`
//    （见官方 README 的 Tweak.x.m 示例输出）。
//
//    `_new_selector`（Method.pm:107）里那个 join("\$", ...)
//    是用来拼**内部符号名**的，不是让 selector 变成通配。
//    `%hook $Foo` 最终会生成 `MSHookMessageEx(objc_getClass("$Foo"), ...)`
//    —— 去运行时找**名字真的叫 "$Foo" 的类**，找不到就是 NULL，
//    整个 hook 静默失效（甚至崩）。Logos 源码里也没有任何 wildcard 逻辑。
//
//    ✅ 正确做法：自己用 objc_getClassList 遍历进程内所有类，
//       逐个检查是否**自身实现**了 `-attemptUnlockWithPasscode:`，
//       命中就用 MSHookMessageEx 挂上。这正是「不赌类名」的正解。
//
//    为什么必须这样做：
//      iOS 16.6 上该方法挂在 SBDeviceLockController（DeviceLock.framework）。
//      Apple 随时可能挪类/换框架，硬编码类名一挪就失效、且**静默失效**。
// ===========================================================================

// ---------------------------------------------------------------------------
// 通用：把「所有自身实现了 selector 的类」挂钩到一个 C 函数上
// ---------------------------------------------------------------------------

// 被 hook 到的类们（用于日志）
static NSMutableArray *gDLHookedClasses = nil;

// 原始实现指针（按类分别保存，%orig 等价物）
static NSMutableDictionary<NSString *, NSValue *> *gDLOrigIMPs = nil;

// 我们的替换实现签名：BOOL (*)(id, SEL, id)
typedef BOOL (*DLAttemptIMP)(id, SEL, id);

// 替换实现
static BOOL DLAttemptUnlockReplacement(id self, SEL _cmd, id passcode) {
    if (DLShouldHijackUnlock(@"runtime.attemptUnlockWithPasscode")) {
        DLProbe(@"[放行控制] %@ 的解锁调用被吞掉（返回 NO）",
                NSStringFromClass(object_getClass(self)));
        return NO;      // 告诉系统「解锁失败」，密码框留在锁屏
    }

    // 放行：找到该类自己的原始 IMP
    // ⚠️ 用 object_getClass(self) 而不是 [self class] —— KVO/动态子类场景下
    //    后者会返回「被观察前的类名」，查表会查空 → 行为被改写。
    Class realClass = object_getClass(self);
    NSString *key = NSStringFromClass(realClass);
    NSValue *boxed = gDLOrigIMPs[key];
    if (!boxed) {
        // 兜底：往继承链上方找（上限 24 层防环）
        Class c = class_getSuperclass(realClass);
        int guard = 0;
        while (c && !boxed && guard++ < 24) {
            boxed = gDLOrigIMPs[NSStringFromClass(c)];
            c = class_getSuperclass(c);
        }
    }
    if (boxed) {
        DLAttemptIMP orig = (DLAttemptIMP)[boxed pointerValue];
        return orig(self, _cmd, passcode);
    }
    // 找不到原始实现 → 保守返回 NO（宁可不解锁，也不能崩）
    DLProbe(@"[放行控制] 警告：%@ 找不到原始 IMP，保守返回 NO", key);
    return NO;
}

// 遍历所有类，给「自身实现 attemptUnlockWithPasscode:」的类挂钩
//
// ⚠️ 安全边界：本 dylib 只注入 com.apple.springboard（见 DecoyLock.plist 的
//    filter），所以在 SpringBoard 进程里枚举到的类几乎都是系统类。但仍要
//    排掉两类：
//      ① 类名以 _ 开头的运行时内部类（NSZombie 之类）
//      ② 不在系统镜像里的类（第三方框架被 SpringBoard 加载的情形，极少，
//         但一旦命中就把别人的密码框搞坏了）
//    判据：`dladdr(class_getImageName(c))` 的路径必须落在 /System/Library
//    或 /usr/lib（iOS 系统镜像），其余一律跳过。
static void DLHookAllAttemptUnlock(void) {
    // ⚠️ 幂等：重试时不能重置字典，否则先前挂上的 orig 丢失
    //    → 转发时查不到原 IMP → 行为被改写。只挂一次。
    static BOOL done = NO;
    if (done) return;
    done = YES;

    gDLOrigIMPs = [NSMutableDictionary dictionary];
    gDLHookedClasses = [NSMutableArray array];

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) {
        DLProbe(@"[挂钩] objc_copyClassList 失败");
        return;
    }

    SEL target = NSSelectorFromString(@"attemptUnlockWithPasscode:");
    unsigned int skipped = 0;

    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;

        NSString *cname = NSStringFromClass(c);
        if (!cname.length || [cname hasPrefix:@"_"]) continue;

        // ① 只认系统镜像里的类 —— 绝不碰第三方框架
        const char *image = class_getImageName(c);
        if (!image) continue;
        NSString *imgPath = [NSString stringWithUTF8String:image];
        BOOL isSystem = [imgPath hasPrefix:@"/System/Library/"] ||
                        [imgPath hasPrefix:@"/usr/lib/"];
        if (!isSystem) { skipped++; continue; }

        // ② 只看「自身实现」—— class_getInstanceMethod 会沿继承链找，
        //    会导致父类也被重复误挂。
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        BOOL owns = NO;
        if (ms) {
            for (unsigned int j = 0; j < mc; j++) {
                if (sel_isEqual(method_getName(ms[j]), target)) { owns = YES; break; }
            }
            free(ms);
        }
        if (!owns) continue;

        IMP old = NULL;
        MSHookMessageEx(c, target, (IMP)&DLAttemptUnlockReplacement, &old);
        if (old) {
            gDLOrigIMPs[cname] = [NSValue valueWithPointer:(void *)old];
        }
        [gDLHookedClasses addObject:cname];
        DLProbe(@"[挂钩] ✅ 已挂 %@ 的 attemptUnlockWithPasscode:（orig=%p, 镜像=%@）",
                cname, (void *)old, [imgPath lastPathComponent]);
    }

    free(classes);

    if (!gDLHookedClasses.count) {
        DLProbe(@"[挂钩] ❌ 系统镜像里没有任何类自身实现 attemptUnlockWithPasscode:"
                @"（跳过非系统类 %u 个）—— 这个判定点在本系统不可用，"
                @"将只依赖密码框输入捕获 + yield 兜底", skipped);
    } else {
        DLProbe(@"[挂钩] 共挂上 %lu 个类（跳过非系统类 %u 个）: %@",
                (unsigned long)gDLHookedClasses.count, skipped,
                [gDLHookedClasses componentsJoinedByString:@", "]);
    }
}
// ===========================================================================
// Hook 组 C2：侦查挂钩（v0.1.7）
//
// ⭐ 背景：v0.1.6 实测证明「输入捕获已工作」（entry.append 命中），
//    但输完密码后没有任何 [判定] 日志 —— 说明我们挂上的
//    attemptUnlockWithPasscode:（单参数）【不在 iOS 16.6 的验证路径上】。
//    真正的验证方法名未知 → 不猜，让日志告诉我们。
//
//    做法：对「嫌疑类」的**白名单方法**做挂钩，
//      输入后 20 秒内（侦查窗口）每次被调用都打一行日志。
//      用户再输一次伪密码，真凶直接现形。
//
// ===========================================================================
// ⛔⛔ v0.1.7 翻车记录（用户实测：锁屏就进安全模式）—— 三个致命错误
// ===========================================================================
//
//  ❌ 错误 1：**按方法名子串筛选挂钩 = 会挂到签名不兼容的方法上**
//     上一版筛 `lowercase 含 unlock/passcode/verify/auth/credential`，
//     然后再按「返回值 void/id × 参数 0~3」挑转发函数。这有个致命漏洞：
//     **参数类型不是只有 id**。比如挂上 `-（void)setAuthContext:(BOOL)x`，
//     x 走的是 w0 寄存器（32 位），我们的转发函数把它当 id（64 位指针）
//     读到 x1 —— **一旦原实现里要解引用这个"指针"，立刻野指针崩溃**。
//     同理 float/double 参数走 s0/d0，通用转发会把垃圾传进去。
//     → 修法：**只挂钩显式白名单里的方法名**（精确字符串相等），
//       并且**逐个校验 type encoding**（见下）。
//
//  ❌ 错误 2：**白名单外的调用也一律进转发函数，任何异常都直接崩 SpringBoard**
//     上一版转发函数体里没有 @try/@catch，一旦内部出问题（查表、打日志、
//     原 IMP 转发）就是 SpringBoard 直接挂 → 安全模式。
//     → 修法：**每个转发函数第一行就包 @try**，catch 里**无条件转原 IMP**；
//       连打日志都单独包一层（磁盘 IO 失败绝不能影响系统）。
//
//  ❌ 错误 3：**原 IMP 查不到时"保守返回"**（上一版返回 NO/nil）
//     `attemptUnlock` 返回 NO 是"解锁失败"，`unlockUI...` 返回 nil 可能被
//     上层拿去用 → 行为被改写。而且查表用的是 `[self class]`，
//     子类实例走父类 IMP 时会查空。
//     → 修法：**查不到就沿继承链找；实在找不到就什么都不做直接返回**
//       （void 方法 return，id 方法 return nil，但绝不主动改写语义）。
//
// ===========================================================================
// v0.1.8 的侦查策略（保守版，只观察不改写）
// ===========================================================================
//
//  ① 只挂钩**显式白名单**里的方法名（字符串精确相等，不做子串匹配）
//  ② 每个待挂方法都要过 `DLReconSignatureOK()`：返回值必须是 void 或 id，
//     参数必须**全是对象类型**（@、# 也算指针，安全）；出现 BOOL/int/float/
//     struct 等一律跳过 —— 宁可不侦查，也不能崩
//  ③ 嫌疑类仍从「零猜测」来源取：SBLockScreenManager + 密码框 delegate
//  ④ **不再吞掉任何调用**。侦查阶段只记录，验证路径完全交给系统原生逻辑
//     （命中伪密码的劫持由 Hook 组 A 的输入缓冲 + Hook 组 C 的
//       attemptUnlockWithPasscode: 承担，不靠侦查挂钩）
//  ⑤ 日志写入每 0.5 秒最多一次（限流），避免文件 IO 把主线程拖崩
// ===========================================================================

static CFAbsoluteTime gDLReconUntil = 0.0;          // 侦查窗口截止时间
static NSMutableArray<NSString *> *gDLReconClasses = nil;   // 已侦查挂钩的类
static NSMutableDictionary<NSString *, NSValue *> *gDLReconOrig = nil; // 原始 IMP
static CFAbsoluteTime gDLReconLastLog = 0.0;        // 日志限流
static int gDLReconLogCount = 0;                    // 本次窗口已记录条数

static void DLReconOpenWindow(void) {
    // ⭐ v0.1.11：窗口从 20 秒拉到 60 秒 —— 锁屏输错后有「惩罚倒计时」，
    //    验证回调可能比输入晚很多；窗口太短会漏掉关键调用。
    gDLReconUntil = CFAbsoluteTimeGetCurrent() + 60.0;
}

static BOOL DLReconInWindow(void) {
    return CFAbsoluteTimeGetCurrent() < gDLReconUntil;
}

// 查原始 IMP：先按「类名+selector」查，找不到沿继承链向上
// ⚠️ 用 object_getClass(self) 而不是 [self class] —— 后者在 KVO 动态子类
//    场景下会拿到假的类名，查不到表。
static id DLReconOrigLookup(id self, SEL _cmd) {
    @try {
        Class c = object_getClass(self);
        SEL s = _cmd;
        int guard = 0;
        while (c && guard++ < 24) {
            NSString *key = [NSStringFromClass(c)
                             stringByAppendingString:NSStringFromSelector(s)];
            NSValue *boxed = gDLReconOrig[key];
            if (boxed) return boxed;
            c = class_getSuperclass(c);
        }
    } @catch (__unused NSException *e) { }
    return nil;
}

// ⭐ 日志：整体 @try + 轻限流。磁盘 IO 失败绝不能影响 SpringBoard。
//
// ⚠️ v0.1.10 教训：限流 0.5 秒（2 条/秒）+ 封顶 400 条
//    → 锁屏验证是**突发**调用（几百毫秒内几十次），被限流吃掉后
//      日志里一行 `[侦查]` 都看不到，白白浪费一轮排查。
//    改为：**只做最小限流**（50ms，20 条/秒）+ 提高封顶（1500 条），
//    保证突发调用能全部落盘。日志变长一点可以接受 —— 定位比简短重要。
static void DLReconLog(id self, SEL _cmd) {
    @try {
        if (!DLReconInWindow()) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - gDLReconLastLog < 0.05) return;   // 20 条/秒
        gDLReconLastLog = now;
        if (gDLReconLogCount++ > 1500) return;
        DLProbe(@"[侦查] %@ -%@",
                NSStringFromClass(object_getClass(self)),
                NSStringFromSelector(_cmd));
    } @catch (__unused NSException *e) { }
}

// ---- 4 个通用转发函数（仅「返回 void / 参数全是对象」的方法会用到）----
// ⭐ 每个函数体整体包 @try；catch 里无条件转原 IMP。
//    不吞任何调用 —— 侦查阶段只观察，不改写系统行为。

static void DLReconV0(id self, SEL _cmd) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL))[b pointerValue])(self, _cmd);
}
static void DLReconV1(id self, SEL _cmd, id a) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL, id))[b pointerValue])(self, _cmd, a);
}
static void DLReconV2(id self, SEL _cmd, id a, id b2) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL, id, id))[b pointerValue])(self, _cmd, a, b2);
}
static void DLReconV3(id self, SEL _cmd, id a, id b2, id c2) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL, id, id, id))[b pointerValue])(self, _cmd, a, b2, c2);
}

static id DLReconI0(id self, SEL _cmd) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL))[b pointerValue])(self, _cmd);
    return nil;
}
static id DLReconI1(id self, SEL _cmd, id a) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL, id))[b pointerValue])(self, _cmd, a);
    return nil;
}
static id DLReconI2(id self, SEL _cmd, id a, id b2) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL, id, id))[b pointerValue])(self, _cmd, a, b2);
    return nil;
}
static id DLReconI3(id self, SEL _cmd, id a, id b2, id c2) {
    DLReconLog(self, _cmd);
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL, id, id, id))[b pointerValue])(self, _cmd, a, b2, c2);
    return nil;
}

// ---------------------------------------------------------------------------
// ⭐ 签名校验：决定这个方法能不能被「通用转发」安全挂钩
//
//   ObjC 方法返回/参数的 type encoding 首字符：
//     @  对象        → 指针，安全
//     #  类对象      → 指针，安全
//     :  selector    → 指针，安全
//     ^  指针        → 指针，安全
//     c/C/i/I/s/S/l/L/q/Q → 整数（BOOL 是 c 或 B）→ **不安全**（窄于 64 位，
//                          通用转发按 64 位读会读到垃圾/越界）
//     f/d            → 浮点（走 s0/d0 寄存器）→ **不安全**
//     { ( [          → struct/union/array → **不安全**
//     v              → void 返回，安全（返回值不用管）
//     ?              → 未知，跳过
// ---------------------------------------------------------------------------
static BOOL DLReconTypeIsSafePointer(const char *t) {
    if (!t || !t[0]) return NO;
    switch (t[0]) {
        case '@': case '#': case ':': case '^': return YES;
        default: return NO;
    }
}

static BOOL DLReconSignatureOK(Method m, BOOL *outIsVoid, unsigned int *outNArgs) {
    char *ret = method_copyReturnType(m);
    BOOL retVoid = (ret && ret[0] == 'v');
    BOOL retSafe = retVoid || DLReconTypeIsSafePointer(ret);
    free(ret);
    if (!retSafe) return NO;

    unsigned int total = method_getNumberOfArguments(m);
    if (total < 2) return NO;
    unsigned int n = total - 2;
    if (n > 3) return NO;

    // 逐个参数检查：必须全是「指针类」编码
    for (unsigned int i = 2; i < total; i++) {
        char *at = method_copyArgumentType(m, i);
        BOOL safe = DLReconTypeIsSafePointer(at);
        free(at);
        if (!safe) return NO;
    }
    *outIsVoid = retVoid;
    *outNArgs = n;
    return YES;
}

// ---------------------------------------------------------------------------
// ⭐ 白名单：只挂钩这些方法名（字符串精确相等）
//
//    宁可不侦查，也不能崩。子串匹配（含 unlock/passcode/...）已被证明会
//    挂到签名不兼容的方法上（v0.1.7 锁屏进安全模式的根因之一）。
// ---------------------------------------------------------------------------
static NSArray<NSString *> *DLReconWhiteList(void) {
    static NSArray<NSString *> *w = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        w = @[
            // —— 密码校验类 ——
            @"verifyPasscode:", @"verifyPasscode:forUser:", @"verifyPasscode:options:",
            @"verifyPassword:", @"verifyPassword:forUser:",
            @"checkPasscode:", @"checkPassword:",
            @"isPasscodeCorrect:", @"isPasswordCorrect:",
            @"validatePasscode:", @"validatePassword:",
            @"authenticateWithPasscode:", @"authenticateWithPassword:",
            @"authenticateWithOptions:",
            @"attemptUnlockWithPasscode:",
            @"attemptUnlockWithPasscode:forUser:",
            @"passcodeEntryFieldDidSucceed:",
            @"passcodeEntryField:didEnterPasscode:",
            @"passcodeEntryFieldDidCancelEntry:",
            @"passcodeEntryFieldDidBeginEntry:",
            @"didEnterPasscode:", @"didEnterPassword:",
            @"submitPasscode:", @"submitPassword:",
            // —— 解锁动作类 ——
            @"unlockWithIntent:", @"unlockUIFromSource:withOptions:",
            @"unlockDevice:", @"unlockDeviceWithIntent:",
            @"attemptUnlockForReason:",
            // —— 提示/失败回调（用于确认真凶路径）——
            @"notePasscodeEntryFailed", @"notePasscodeEntryCannotAttempt:",
            @"noteIncorrectPasscodeWithCompletion:",
            @"showPasscodeFailure", @"passcodeEntryDidFail",
        ];
    });
    return w;
}

// 对一个类做侦查挂钩（幂等：同一类只挂一次）
static void DLReconClass(Class c, NSString *reason) {
    @try {
        if (!c || !DLIsSpringBoard()) return;
        NSString *cn = NSStringFromClass(c);
        if (!cn.length || [cn hasPrefix:@"_"]) return;
        // ⭐ 只认系统镜像 —— 绝不碰第三方框架
        const char *image = class_getImageName(c);
        if (!image) return;
        NSString *imgPath = [NSString stringWithUTF8String:image];
        if (![imgPath hasPrefix:@"/System/Library/"] &&
            ![imgPath hasPrefix:@"/usr/lib/"]) return;

        if (!gDLReconClasses) {
            gDLReconClasses = [NSMutableArray array];
            gDLReconOrig = [NSMutableDictionary dictionary];
        }
        if ([gDLReconClasses containsObject:cn]) return;
        [gDLReconClasses addObject:cn];

        NSArray *wl = DLReconWhiteList();
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        int hooked = 0, skipped = 0;
        for (unsigned int i = 0; i < mc; i++) {
            NSString *selName = NSStringFromSelector(method_getName(ms[i]));

            // ① 白名单精确匹配
            if (![wl containsObject:selName]) continue;

            // ② 签名校验（返回值 + 参数类型）
            BOOL isVoid = NO;
            unsigned int nargs = 0;
            if (!DLReconSignatureOK(ms[i], &isVoid, &nargs)) {
                skipped++;
                continue;
            }

            // ③ 挑转发函数
            IMP repl;
            if (isVoid) {
                if (nargs == 0)      repl = (IMP)DLReconV0;
                else if (nargs == 1) repl = (IMP)DLReconV1;
                else if (nargs == 2) repl = (IMP)DLReconV2;
                else                 repl = (IMP)DLReconV3;
            } else {
                if (nargs == 0)      repl = (IMP)DLReconI0;
                else if (nargs == 1) repl = (IMP)DLReconI1;
                else if (nargs == 2) repl = (IMP)DLReconI2;
                else                 repl = (IMP)DLReconI3;
            }

            IMP old = NULL;
            MSHookMessageEx(c, method_getName(ms[i]), repl, &old);
            if (old) {
                gDLReconOrig[[cn stringByAppendingString:selName]] =
                    [NSValue valueWithPointer:(void *)old];
                hooked++;
                DLProbe(@"[侦查挂] %@ -%@（%u参，%@）", cn, selName, nargs,
                        isVoid ? @"void" : @"id");
            } else {
                skipped++;
            }
        }
        if (ms) free(ms);
        DLProbe(@"[侦查挂] %@（%@）：挂 %d 个，跳过 %d 个",
                cn, reason ?: @"?", hooked, skipped);
    } @catch (__unused NSException *e) { }
}

// ---------------------------------------------------------------------------
// ⭐ v0.1.11 新增：重点类「全量侦查」（不筛方法名，只筛签名安全性）
//
// v0.1.10 的教训：白名单是**我猜的**，猜不中就永远找不到真凶。
// 但全量挂所有类的所有方法风险太大（v0.1.7 就是这么崩的）。
//
// 折中方案：只对**极少数几个「确定存在且一定在锁屏生命周期里」的类**
// 做全量签名安全挂钩 —— 这些类的方法数量有限（几十个），日志不会爆，
// 且签名校验保证不会崩。
//
// 与 DLReconClass 的唯一区别：**不筛方法名，只筛签名**。
// ---------------------------------------------------------------------------
static void DLReconClassAllMethods(Class c, NSString *reason) {
    @try {
        if (!c || !DLIsSpringBoard()) return;
        NSString *cn = NSStringFromClass(c);
        if (!cn.length || [cn hasPrefix:@"_"]) return;

        const char *image = class_getImageName(c);
        if (!image) return;
        NSString *imgPath = [NSString stringWithUTF8String:image];
        if (![imgPath hasPrefix:@"/System/Library/"] &&
            ![imgPath hasPrefix:@"/usr/lib/"]) return;

        static NSMutableSet *done = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ done = [NSMutableSet set]; });
        NSString *tag = [cn stringByAppendingString:@"#ALL"];
        if ([done containsObject:tag]) return;
        [done addObject:tag];

        if (!gDLReconClasses) {
            gDLReconClasses = [NSMutableArray array];
            gDLReconOrig = [NSMutableDictionary dictionary];
        }

        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        int hooked = 0, skipped = 0;
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned int i = 0; i < mc; i++) {
            NSString *selName = NSStringFromSelector(method_getName(ms[i]));
            if (!selName.length) continue;
            // 跳过明显无关的（getter/setter/内存管理/描述）—— 纯粹为了日志可读
            if ([selName hasPrefix:@"set"] || [selName hasPrefix:@"_"] ||
                [selName hasPrefix:@"."] || [selName isEqualToString:@"description"] ||
                [selName isEqualToString:@"dealloc"] ||
                [selName isEqualToString:@"class"] ||
                [selName isEqualToString:@"hash"] ||
                [selName isEqualToString:@"isEqual:"]) continue;

            // ⭐ 唯一筛选：签名必须能安全通用转发
            BOOL isVoid = NO;
            unsigned int nargs = 0;
            if (!DLReconSignatureOK(ms[i], &isVoid, &nargs)) { skipped++; continue; }

            IMP repl;
            if (isVoid) {
                if (nargs == 0)      repl = (IMP)DLReconV0;
                else if (nargs == 1) repl = (IMP)DLReconV1;
                else if (nargs == 2) repl = (IMP)DLReconV2;
                else                 repl = (IMP)DLReconV3;
            } else {
                if (nargs == 0)      repl = (IMP)DLReconI0;
                else if (nargs == 1) repl = (IMP)DLReconI1;
                else if (nargs == 2) repl = (IMP)DLReconI2;
                else                 repl = (IMP)DLReconI3;
            }

            IMP old = NULL;
            MSHookMessageEx(c, method_getName(ms[i]), repl, &old);
            if (old) {
                gDLReconOrig[[cn stringByAppendingString:selName]] =
                    [NSValue valueWithPointer:(void *)old];
                hooked++;
                [names addObject:[NSString stringWithFormat:@"%@(%u参,%@)",
                                  selName, nargs, isVoid ? @"void" : @"id"]];
            } else {
                skipped++;
            }
        }
        if (ms) free(ms);
        DLProbe(@"[全量挂] %@（%@）：挂 %d 个，跳过 %d 个",
                cn, reason ?: @"?", hooked, skipped);
        if (names.count) {
            DLProbe(@"[全量挂] %@ 方法清单：%@", cn,
                    [names componentsJoinedByString:@", "]);
        }
    } @catch (__unused NSException *e) { }
}

// 密码框的 delegate 才是「验证发起者」—— 运行时取它的类来侦查，零猜测
static void DLEnsureReconForPasscodeField(id field) {
    @try {
        if (!field || !DLIsSpringBoard()) return;

        // ⭐ v0.1.10 关键修正
        //
        // v0.1.9 日志：「[侦查挂] SBUIPasscodeLockViewSimpleFixedDigitKeypad
        //              （delegate）：挂 0 个，跳过 0 个」
        //   → 密码框的 delegate 只是一个「画键盘的 view」，
        //     它不负责验证密码，自然不会实现白名单里的验证方法。
        //
        //   验证者其实是**上一层的锁屏 view controller**（在它的视图树里）。
        //   但 SBLockScreenViewController 这个类名在本系统不存在（自检已 ❌），
        //   所以不能硬编码 —— 改成**沿「视图 / 响应者 / delegate」链一路上行**，
        //   每一层的类都试一次侦查挂钩（幂等，挂不到就跳过，完全安全）。
        NSMutableArray<Class> *candidates = [NSMutableArray array];

        // ① 自己
        if ([field isKindOfClass:[NSObject class]]) [candidates addObject:[field class]];

        // ② delegate
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([field respondsToSelector:@selector(delegate)]) {
            id dlg = [field performSelector:@selector(delegate)];
            if (dlg) [candidates addObject:[dlg class]];
        }
        // ③ superview 链（最多 12 层）—— 密码框往上找，锁屏 VC 一定在这一串里
        if ([field isKindOfClass:[UIView class]]) {
            UIView *p = [(UIView *)field superview];
            int guard = 0;
            while (p && guard++ < 12) {
                [candidates addObject:[p class]];
                p = p.superview;
            }
        }
        // ④ nextResponder 链（最多 12 层）—— UIViewController 就是靠这个上来的
        if ([field respondsToSelector:@selector(nextResponder)]) {
            id r = [field performSelector:@selector(nextResponder)];
            int guard = 0;
            while (r && guard++ < 12) {
                [candidates addObject:[r class]];
                r = [r respondsToSelector:@selector(nextResponder)]
                    ? [r performSelector:@selector(nextResponder)] : nil;
            }
        }
#pragma clang diagnostic pop

        // 去重后逐个尝试（DLReconClass 内部幂等 + 自动跳过非系统镜像/无白名单方法的类）
        NSMutableSet *seen = [NSMutableSet set];
        for (Class c in candidates) {
            if (!c) continue;
            NSString *cn = NSStringFromClass(c);
            if (!cn.length || [seen containsObject:cn]) continue;
            [seen addObject:cn];
            DLReconClass(c, @"上行链");
        }
    } @catch (__unused NSException *e) { }
}

// ===========================================================================
// Hook 组 D：锁屏生命周期 —— 已合并进 v0.1.13 的 SBLockScreenManager 钩子块
// （Logos 同一个类只能有一个 %hook 块，否则重复挂钩/行为不可预期）
// ===========================================================================

// ===========================================================================
// 启动
// ===========================================================================

static void DLDumpEnvironment(void) {
    DLProbe(@"========== DecoyLock %@ 启动（Tweak.x v0.1.20 安全加固版 + 退出App选择修复）==========", DL_VERSION);
    DLProbe(@"bundle=%@ pid=%d", [NSBundle mainBundle].bundleIdentifier, (int)getpid());
    DLProbe(@"已启用=%d 伪密码已配置=%d",
            DLEnabled(), DLDecoyPasscode().length > 0);
    DLProbe(@"共享目录=%@", DLSharedDir());
    DLProbe(@"配置存在=%d",
            [[NSFileManager defaultManager] fileExistsAtPath:DLConfigPath()]);
    DLProbe(@"伪 App 数量=%lu", (unsigned long)DLDecoyApps().count);

    // 自检：关键私有类是否存在、有没有实现我们要的方法
    // 用户只要把诊断日志发回来，就能一眼看出钩子挂空在哪
    NSArray *probeClasses = @[
        @"SBUIPasscodeEntryField", @"SBUIPasscodeLockViewWithKeypad",
        @"SBUIPasscodeEntryFieldAccessibility", @"SBLockScreenManager",
        @"SBDeviceLockController", @"SBLockScreenViewController",
        @"SBPearlPasscodeEntryField", @"SBPasscodeEntryField",
    ];
    for (NSString *cn in probeClasses) {
        Class c = NSClassFromString(cn);
        if (!c) {
            DLProbe(@"[自检] 类 %@ : ❌ 不存在", cn);
            continue;
        }
        BOOL hasSetText = class_getInstanceMethod(c, @selector(setText:)) != NULL;
        Method am = class_getInstanceMethod(c,
            NSSelectorFromString(@"attemptUnlockWithPasscode:"));
        DLProbe(@"[自检] 类 %@ : ✅ 存在  setText:=%d  attempt=%d",
                cn, hasSetText, am != NULL);
    }

    // -----------------------------------------------------------------------
    // ⭐ v0.1.10：环境清点（只观察，不挂钩）
    //
    // v0.1.9 日志告诉我们三件事：
    //   ① 输入捕获 ✅（entry.append 走通）
    //   ② attemptUnlockWithPasscode: 挂在 SBLockScreenManager 上，但没被调用
    //   ③ 密码框 delegate 的类 = SBUIPasscodeLockViewSimpleFixedDigitKeypad，
    //      它**自身没实现**任何白名单方法（挂 0 跳过 0）
    //      → 验证方法在**别的对象**上。最可能是「锁屏 view controller」。
    //      但 SBLockScreenViewController 这个类名在本系统不存在（上面已 ❌）。
    //      → 所以本版直接把 runtime 里**所有**名字可疑的类清点出来，
    //        用户下次一锁屏输入，日志就会列出真正的验证者类名。
    // -----------------------------------------------------------------------
    NSMutableArray *suspects = [NSMutableArray array];
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    if (allClasses) {
        for (unsigned int i = 0; i < classCount; i++) {
            Class c = allClasses[i];
            if (!c) continue;
            NSString *n = NSStringFromClass(c);
            if (!n.length) continue;
            // 只看有嫌疑的名字（视图控制器 / 密码 / 锁屏 / 设备锁）
            BOOL suspect = ([n containsString:@"Passcode"] ||
                            [n containsString:@"LockScreen"] ||
                            [n containsString:@"DeviceLock"] ||
                            [n containsString:@"Pearl"]);
            if (!suspect) continue;
            // 排除我们自己/系统无关的
            if ([n hasPrefix:@"DL"]) continue;
            const char *img = class_getImageName(c);
            NSString *imgName = img ? [[NSString stringWithUTF8String:img] lastPathComponent]
                                    : @"?";
            // 统计它实现的「白名单」方法数，方便一眼看出谁是验证者
            // ⭐ v0.1.11：不只数个数，**把命中的方法名也打出来**
            //    （v0.1.10 只打了计数 → 看到「白名单1」却不知道是哪个方法，白跑一轮）
            int wlCount = 0;
            NSMutableArray *wlHits = [NSMutableArray array];
            NSArray *wl = DLReconWhiteList();
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            if (ms) {
                for (unsigned int j = 0; j < mc; j++) {
                    NSString *sn = NSStringFromSelector(method_getName(ms[j]));
                    if ([wl containsObject:sn]) {
                        wlCount++;
                        [wlHits addObject:sn];
                    }
                }
                free(ms);
            }
            [suspects addObject:[NSString stringWithFormat:@"%@(%@,白名单%d%@)",
                                 n, imgName, wlCount,
                                 wlHits.count
                                     ? [@"=" stringByAppendingString:
                                        [wlHits componentsJoinedByString:@"+"]]
                                     : @""]];
        }
        free(allClasses);
    }
    DLProbe(@"[清点] 名字可疑的类共 %lu 个：%@",
            (unsigned long)suspects.count,
            [suspects componentsJoinedByString:@" | "]);
}

// ---------------------------------------------------------------------------
// ⭐ v0.1.10：输入捕获自检（用户说「输够 N 位」时立即打一行）
//    这样能立刻区分两种失败：
//      a) 系统根本没走 appendString:（len 涨不上去）→ 输入捕获失效
//      b) len 到了 N 但没进判定 → 阈值/判定条件写错了
//
//    v0.1.14：不再说「等待系统验证调用」—— 现在是**插件自己主动判定**，
//    所以这行后面紧跟的应该就是 `[主动判定]` 那一行。
// ---------------------------------------------------------------------------
static void DLLogInputCapture(NSString *src) {
    NSUInteger len = DLInputBuffer().length;
    if (len == DLDecoyPasscode().length && len > 0) {
        DLProbe(@"✅ 输入长度已达伪密码位数（%lu 位，源=%@）→ 立即主动判定",
                (unsigned long)len, src);
    }
}

// ---------------------------------------------------------------------------
// ⭐⭐ v0.1.13：真正的解锁请求路径 —— 直接挂实测暴露的方法名
//
// v0.1.12 日志把 `SBLockScreenManager` 的**方法清单**全打出来了，里面有：
//   attemptUnlockWithPasscode:(1参,void)                       ← 我一直在挂的（从不被调用）
//   coverSheetViewControllerHandleUnlockAttemptSucceeded:(1参,void)  ← 解锁**成功**回调
//   coverSheetViewController:unlockWithRequest:completion:(3参,void) ← ⭐ 带 request 的解锁
//   coverSheetPresentationManager:unlockWithRequest:completion:(3参,void)
//
// 关键洞察：
//   ① `HandleUnlockAttemptSucceeded:` 是**成功**回调 → 那一定有个「尝试」的入口
//   ② `unlockWithRequest:completion:` 里的 **Request** 才是 CoverSheet 架构的真实载体
//      —— 它的第 1 个参数就是请求对象（很可能携带密码/验证结果）
//   ③ 我一路猜的 `attemptUnlockWithPasscode:` 从不被调用 → 别再把宝押在它身上
//
// 本组做法：对这几个方法做**精确挂钩**，并从 `request` 对象上
//   用 KVC 尽力捞密码（`_passcode` / `passcode` / `credential` / `_credential`）
//   —— 只观察、只记录，**不改写任何行为**。
// ---------------------------------------------------------------------------

@interface SBLockScreenManager : NSObject
@end

%hook SBLockScreenManager

// —— 锁屏生命周期（原 Hook 组 D，v0.1.13 并入本块）——
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    DLResetInput();
    DLProbe(@"锁屏出现 → 清空输入缓冲");
    // ⭐ v0.1.19：锁屏重建时，若我们的窗口已经挂了很久（>8 秒），
    //    说明它不是刚铺上去的，而是以「残留挡板」的形式留在界面上 →
    //    必须拆掉，否则用户看得见锁屏却点不动。
    DLSafeTeardownIfStale(8.0, "锁屏重建");
    %orig;
}
- (void)noteLockScreenUIDidDisappear {
    // 进真桌面时清掉一切痕迹（避免下次锁屏被上次输入污染）
    DLResetInput();
    // ⭐ v0.1.19：锁屏消失 = 用户大概率去解锁了（真实密码 / Face ID）。
    //    此时**必须**把我们自建的窗口拆掉 —— 否则它会以一个
    //    「看不见却挡触摸」的高层级窗口留在界面上，用户就会出现
    //    「正常输入密码界面点不动」的现象（2026-10-06 实测事故）。
    DLSafeTeardownIfStale(3.0, "锁屏消失（用户去解锁）");
    %orig;
}

// ⭐ 核心：带 request 的解锁。request 很可能就是密码载体
- (void)coverSheetViewController:(id)vc
                unlockWithRequest:(id)request
                       completion:(id)completion {
    DLProbe(@"[解锁请求] coverSheetViewController:unlockWithRequest:completion: 被调用 "
            @"request=%@", request);
    if (request) {
        // 只读 KVC 探测（任何异常都吞掉，绝不影响系统）
        @try {
            NSArray *keys = @[@"passcode", @"_passcode", @"password", @"_password",
                              @"credential", @"_credential", @"passcodeString",
                              @"_passcodeString", @"requestType", @"type", @"source"];
            NSMutableString *dump = [NSMutableString string];
            for (NSString *k in keys) {
                @try {
                    id v = [request valueForKey:k];
                    if (v) [dump appendFormat:@"%@=%@ ", k, v];
                } @catch (__unused NSException *e) { }
            }
            DLProbe(@"[解锁请求] request KVC 探测：%@",
                    dump.length ? dump : @"(无可用键)");
        } @catch (__unused NSException *e) { }
    }
    %orig;
}

- (void)coverSheetPresentationManager:(id)mgr
                    unlockWithRequest:(id)request
                           completion:(id)completion {
    DLProbe(@"[解锁请求] coverSheetPresentationManager:unlockWithRequest:completion: 被调用 "
            @"request=%@", request);
    %orig;
}

// 解锁**成功**回调 —— 出现它说明系统认可了这次解锁
- (void)coverSheetViewControllerHandleUnlockAttemptSucceeded:(id)vc {
    DLProbe(@"[解锁请求] ★★ HandleUnlockAttemptSucceeded 被调用（系统认可解锁）");
    // ⭐ v0.1.19：系统真的认可了解锁 = 用户已经/即将进真桌面 →
    //    我们的窗口一律拆掉（哪怕只展示了 1 秒）。这是最强的清理信号。
    DLSafeTeardownIfStale(0.5, "系统认可解锁");
    %orig;
}

// 保留：老的判定点（若某些系统版本真的走它，仍能生效）
- (void)attemptUnlockWithPasscode:(id)passcode {
    DLProbe(@"[解锁请求] attemptUnlockWithPasscode: 被调用 passcode=%@", passcode);
    %orig;
}

%end

// ---------------------------------------------------------------------------
// ⭐ v0.1.14：失败回调 —— **兜底**判定点（不再只是日志）
//
// 主路径是「输入够位数就主动判定」（见 DLTriggerActiveVerdict）。
// 但存在一种边界情况：用户用某种输入方式（粘贴 / 自动填充 / 键盘直接
// 替换整个字符串）绕过了 appendString:，导致我们的缓冲没抓到。
//
// 此时系统仍然会走 resetForFailedPasscode（v0.1.13 实测确认它 100% 触发）。
// 所以这里做**第二道防线**：在系统判定失败的那一刻，再从视图树里
// 把密码框的文本抠出来比对一次（DLSniffPasscodeFromWindows）。
// 命中伪密码 → 照样把假空间盖上去。
// ---------------------------------------------------------------------------
@interface SBUIPasscodeLockViewBase : UIView
@end

%hook SBUIPasscodeLockViewBase
- (void)resetForFailedPasscode {
    DLProbe(@"[失败回调] ★ resetForFailedPasscode 被调用 → 系统判定密码错误");

    // ---- 兜底：主路径没抓到输入时，这里补一次 ----
    @try {
        if (DLEnabled() && DLDecoyPasscode().length) {
            NSString *sniffed = DLSniffPasscodeFromWindows();
            DLProbe(@"[失败回调] 兜底抠取密码框文本=%@",
                    sniffed.length ? sniffed : @"(失败)");
            if (sniffed.length) {
                DLPasscodeVerdict v = [DLDecoyController handleCapturedPasscode:sniffed];
                if (v == DLPasscodeVerdictDecoy) {
                    DLProbe(@"[失败回调] ✅ 兜底命中伪密码 → 呈现假空间（盖住错误界面）");
                    DLResetInput();
                }
            }
        }
    } @catch (__unused NSException *e) { }

    %orig;
}
%end

// ---------------------------------------------------------------------------
// 启动时的挂钩编排：跑一轮，失败/挂空则退避重试
//
// ⚠️ 为什么需要重试：SpringBoard 起来时锁屏类可能还没注册完，
//    一次性挂在空类上就永远没机会了（v0.1.5 的教训）。
//    10 次 × 递增退避（2,4,6,...,20 秒），足够覆盖锁屏加载窗口。
// ---------------------------------------------------------------------------
static int gDLBootRounds = 0;

static void DLBootRound(void) {
    @try {
        if (!DLIsSpringBoard()) return;
        gDLBootRounds++;

        if (gDLBootRounds == 1) {
            DLHookAllAttemptUnlock();
            DLSetupClearHook();      // ⭐ v0.1.17：安全清空密码框要用原 IMP
        }

        // 侦查挂钩：对嫌疑类挂钩，日志会告诉我们真实的密码验证方法名
        Class sm = NSClassFromString(@"SBLockScreenManager");
        if (sm) DLReconClass(sm, @"启动侦查");

        // ⭐ v0.1.11：重点类「全量侦查」（不筛方法名，只筛签名安全性）
        //
        // 为什么只挑这几个类（而不是全 runtime）：
        //   v0.1.10 白名单是我猜的，猜不中就没有答案。
        //   但全量挂所有类会重演 v0.1.7 的崩溃。
        //   → 折中：只挂「确认存在 + 一定在锁屏生命周期里」的类。
        //     这些类方法数有限（几十个），日志不会爆，
        //     且签名校验保证转发安全。
        if (gDLBootRounds == 1) {
            NSArray *allRecon = @[
                // ⭐ v0.1.11 实测定位：真凶在 CoverSheet 框架里
                @"CSPasscodeViewController",
                @"CSModalPresentationViewController",
                @"CSCoverSheetViewController",
                // 真正的输入视图（SBUIPasscodeEntryField 是它的父类）
                @"SBUISimpleFixedDigitPasscodeEntryField",
                // 这两个「白名单命中 1」→ 真的实现了某个我们列的方法名，重点看
                @"SBUIPasscodeLockViewWithKeypad",
                @"SBUIPasscodeLockViewWithKeyboard",
                // 老目标保留
                @"SBLockScreenManager",
                @"SBLockScreenView",
                @"SBLockScreenLockingViewController",
                @"SBLockScreenCombinedLockViewController",
            ];
            for (NSString *cn in allRecon) {
                Class c = NSClassFromString(cn);
                if (c) DLReconClassAllMethods(c, @"全量侦查");
            }
        }

        DLProbe(@"[自检] 第 %d 轮挂钩完成：已启用=%d 伪密码已配置=%d",
                gDLBootRounds, DLEnabled(), DLDecoyPasscode().length > 0);

        // 还没到上限就安排下一轮（幂等，重复调用无副作用）
        if (gDLBootRounds < 10) {
            double delay = 2.0 * (gDLBootRounds + 1);   // 4,6,8,...,20 秒
            if (delay > 20.0) delay = 20.0;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ DLBootRound(); });
        }
    } @catch (__unused NSException *e) { }
}

%ctor {
    @autoreleasepool {
        if (DLIsSpringBoard()) {
            DLDumpEnvironment();

            // 首次侦查：构造器阶段先挂一遍（多数情况锁屏类已注册）
            // 之后由 DLBootRound 自己按退避节奏重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ DLBootRound(); });
        }
    }
}
