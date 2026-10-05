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
// 伪锁屏 · SpringBoard 侧钩子（v0.1.6 重写）
// ===========================================================================
//
// v0.1.5 的三个致命错误（本轮全部修掉）：
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
//     SBLockScreenViewController -passcodeEntryFieldDidSucceed: /
//     SBLockScreenManager -unlockWithIntent: —— iOS 16 上这两个方法
//     **都不存在**（前者是 iOS 14 时代的名字，后者签名完全对不上）。
//     Logos 对不存在的类/方法**不报错**，所以 CI 全绿、装上也毫无反应。
//
// 本版策略（不再猜类名，改成「运行时反射 + 通配钩子 + 时间窗」）：
//
//  ① 输入捕获：hook **SBUIPasscodeEntryField** 的 setText: / clear /
//     appendString: 与 UITextField 的 deleteBackward —— 前者是锁屏密码框
//     的通用基类（iOS 6~17 都在），后者是键盘删除键的事实标准。
//     另加 **yield 模式**：解锁判定那一瞬间，直接遍历所有 UIWindow 找
//     「类名含 Passcode 且响应 text 选择器」的视图，读它当前文本。
//     → 这一路完全不依赖任何钩子命中，是本版的**主路径**。
//
//  ② 解锁判定点：用 `-attemptUnlockWithPasscode:`（iOS 6~17 恒存在的
//     「尝试用密码解锁」点），并以 `$` 前缀让 Logos 对**所有类的同名方法**
//     生效 —— 不去赌它挂在 SBDeviceLockController 还是 SBLockScreenManager。
//     → 这是「不用猜类名」的关键技巧，见 SKILL §0.0.12。
//
//  ③ 判定窗口：密码框输入后 25 秒内到达的解锁调用才算「本次输入的结果」。
//     解决「SBLockScreenViewController 生命周期太长，缓冲区被历史输入污染」
//     的问题，同时避免旧输入串门触发假空间。
//
//  ④ 绝不锁死设备：任何一步失败都直接放行原生流程（return %orig）。
//     伪空间失败最多「没效果」，不可能让用户进不去系统。
// ===========================================================================

static NSString *const kDLBundleID = @"com.apple.springboard";

// 判定窗口：密码框最后一次被写入后，多久内的解锁调用算数
static const NSTimeInterval kDLWindowSeconds = 25.0;

// 记录密码框当前内容 + 最近一次写入的时间戳
static NSMutableString *gDLInput = nil;
static CFAbsoluteTime   gDLInputStamp = 0.0;
static NSString        *gDLLastSrc = @"";

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
// ===========================================================================

// 侦查挂钩（定义在 Hook 组 C2，先给前向声明 —— C 要求先声明后用）
static void DLReconOpenWindow(void);
static void DLEnsureReconForPasscodeField(id field);

@interface SBUIPasscodeEntryField : UIView
@end

%hook SBUIPasscodeEntryField
- (void)setText:(NSString *)text {
    %orig;
    DLSetInput(text, @"entry.set");
    DLReconOpenWindow();
}
- (void)appendString:(NSString *)s {
    %orig;
    DLAppendInput(s, @"entry.append");
    DLReconOpenWindow();
    DLEnsureReconForPasscodeField(self);   // delegate 类侦查（幂等）
}
- (void)clear {
    %orig;
    DLResetInput();
    DLProbe(@"[输入] 源=entry.clear 已清空");
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

// ===========================================================================
// Hook 组 B：键盘删除键（UITextField 是密码框内部真正的编辑视图）
// ===========================================================================

%hook UITextField
- (void)deleteBackward {
    %orig;
    if (!DLIsSpringBoard()) return;
    NSString *cls = NSStringFromClass([self class]);
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
                NSStringFromClass([self class]));
        return NO;      // 告诉系统「解锁失败」，密码框留在锁屏
    }

    // 放行：找到该类自己的原始 IMP
    NSString *key = NSStringFromClass([self class]);
    NSValue *boxed = gDLOrigIMPs[key];
    if (!boxed) {
        // 兜底：往继承链上方找
        Class c = class_getSuperclass([self class]);
        while (c && !boxed) {
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
// Hook 组 C2：侦查挂钩（v0.1.7 新增）
//
// ⭐ 背景：v0.1.6 实测证明「输入捕获已工作」（entry.append 命中），
//    但输完密码后没有任何 [判定] 日志 —— 说明我们挂上的
//    attemptUnlockWithPasscode:（单参数）【不在 iOS 16.6 的验证路径上】。
//    真正的验证方法名未知 → 不猜，让日志告诉我们。
//
//    做法：对「嫌疑类」的全部实例方法做**方法名筛选挂钩**：
//      筛 lowercase 含 unlock / passcode / verify / auth / credential 的方法，
//      用 MSHookMessageEx 挂上通用记录函数 —— 输入后 20 秒内（侦查窗口）
//      每次被调用都打一行日志。用户再输一次伪密码，真凶直接现形。
//
//    嫌疑类来源：
//      ① SBLockScreenManager（已知存在，lockUIFromSource: 已证实 hook 生效）
//      ② 密码框的 delegate 类（输完密码后 field 一定回调 delegate，
//         delegate 才是「验证发起者」—— 运行时取，零猜测）
//
//    通用替换函数的可行性（arm64）：
//      - ObjC 方法参数走 x0-x7 寄存器，前两个固定 self/_cmd；
//        我们不 deref 参数只转发，指针/整数（含 BOOL/int）都安全。
//        float/double/struct 参数会坏 → 按 type encoding 跳过这些方法。
//      - 按返回值分两组：void 用 V 系列，其他用 I 系列
//        （I 系列返回 id，BOOL 返回的低位截断自然兼容）。
// ===========================================================================

static CFAbsoluteTime gDLReconUntil = 0.0;          // 侦查窗口截止时间
static NSMutableArray<NSString *> *gDLReconClasses = nil;   // 已侦查挂钩的类
static NSMutableDictionary<NSString *, NSValue *> *gDLReconOrig = nil; // 原始 IMP

static void DLReconOpenWindow(void) {
    gDLReconUntil = CFAbsoluteTimeGetCurrent() + 20.0;
}

static BOOL DLReconInWindow(void) {
    return CFAbsoluteTimeGetCurrent() < gDLReconUntil;
}

// 查原始 IMP：先按「实际类+selector」查，找不到沿继承链向上（继承场景）
static id DLReconOrigLookup(id self, SEL _cmd) {
    NSString *key = [NSStringFromClass([self class])
                     stringByAppendingString:NSStringFromSelector(_cmd)];
    NSValue *boxed = gDLReconOrig[key];
    Class c = class_getSuperclass([self class]);
    while (c && !boxed) {
        boxed = gDLReconOrig[[NSStringFromClass(c)
                              stringByAppendingString:NSStringFromSelector(_cmd)]];
        c = class_getSuperclass(c);
    }
    return boxed;
}

static void DLReconLog(id self, SEL _cmd) {
    if (!DLReconInWindow()) return;
    DLProbe(@"[侦查] ★ %@ -%@ 被调用（输入后！）",
            NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

// 侦查中命中伪密码 → 吞掉「发起解锁」语义的方法（其余只记录）
static BOOL DLReconSwallow(id self, SEL _cmd) {
    NSString *sel = NSStringFromSelector(_cmd);
    if ([sel hasPrefix:@"attemptUnlock"] ||
        [sel hasPrefix:@"unlockUI"] ||
        [sel hasPrefix:@"unlockWithIntent"] ||
        [sel hasPrefix:@"unlockDevice"]) {
        return DLShouldHijackUnlock(
            [NSString stringWithFormat:@"recon.%@", sel]);
    }
    return NO;
}

// ---- 8 个通用替换函数（void/id × 0~3 参）----
static void DLReconV0(id self, SEL _cmd) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL))[b pointerValue])(self, _cmd);
}
static void DLReconV1(id self, SEL _cmd, id a) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL, id))[b pointerValue])(self, _cmd, a);
}
static void DLReconV2(id self, SEL _cmd, id a, id b2) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL, id, id))[b pointerValue])(self, _cmd, a, b2);
}
static void DLReconV3(id self, SEL _cmd, id a, id b2, id c2) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) ((void (*)(id, SEL, id, id, id))[b pointerValue])(self, _cmd, a, b2, c2);
}
static id DLReconI0(id self, SEL _cmd) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return nil;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL))[b pointerValue])(self, _cmd);
    return nil;
}
static id DLReconI1(id self, SEL _cmd, id a) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return nil;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL, id))[b pointerValue])(self, _cmd, a);
    return nil;
}
static id DLReconI2(id self, SEL _cmd, id a, id b2) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return nil;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL, id, id))[b pointerValue])(self, _cmd, a, b2);
    return nil;
}
static id DLReconI3(id self, SEL _cmd, id a, id b2, id c2) {
    DLReconLog(self, _cmd);
    if (DLReconSwallow(self, _cmd)) return nil;
    id b = DLReconOrigLookup(self, _cmd);
    if (b) return ((id (*)(id, SEL, id, id, id))[b pointerValue])(self, _cmd, a, b2, c2);
    return nil;
}

// 对一个类做侦查挂钩（幂等：同一类只挂一次）
static void DLReconClass(Class c, NSString *reason) {
    if (!c || !DLIsSpringBoard()) return;
    NSString *cn = NSStringFromClass(c);
    if (!cn.length || [cn hasPrefix:@"_"]) return;

    if (!gDLReconClasses) {
        gDLReconClasses = [NSMutableArray array];
        gDLReconOrig = [NSMutableDictionary dictionary];
    }
    if ([gDLReconClasses containsObject:cn]) return;
    [gDLReconClasses addObject:cn];

    unsigned int mc = 0;
    Method *ms = class_copyMethodList(c, &mc);
    int hooked = 0, skipped = 0;
    for (unsigned int i = 0; i < mc; i++) {
        SEL m = method_getName(ms[i]);
        NSString *selName = NSStringFromSelector(m);
        NSString *low = [selName lowercaseString];

        BOOL interesting = [low containsString:@"unlock"] ||
                           [low containsString:@"passcode"] ||
                           [low containsString:@"verify"] ||
                           [low containsString:@"auth"] ||
                           [low containsString:@"credential"];
        if (!interesting) continue;
        // attemptUnlockWithPasscode: 已有专门挂钩（Hook 组 C），避免双层
        if ([low hasPrefix:@"attemptunlockwithpasscode"]) continue;

        // struct 返回的方法跳过（通用转发会破坏 ABI）
        char *rt = method_copyReturnType(ms[i]);
        BOOL isStruct = rt && rt[0] == '{';
        free(rt);
        if (isStruct) { skipped++; continue; }

        unsigned int nargs = method_getNumberOfArguments(ms[i]) - 2;
        if (nargs > 3) { skipped++; continue; }

        char *retT = method_copyReturnType(ms[i]);
        BOOL isVoid = retT && strcmp(retT, "v") == 0;
        free(retT);

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
        MSHookMessageEx(c, m, repl, &old);
        if (old) {
            gDLReconOrig[[cn stringByAppendingString:selName]] =
                [NSValue valueWithPointer:(void *)old];
        }
        hooked++;
        DLProbe(@"[侦查挂] %@ -%@（%u参，%s）", cn, selName, nargs,
                isVoid ? "void" : "ret");
    }
    if (ms) free(ms);
    DLProbe(@"[侦查挂] %@（%@）：挂 %d 个，跳过 %d 个",
            cn, reason ?: @"?", hooked, skipped);
}

// 密码框的 delegate 才是「验证发起者」—— 运行时取它的类来侦查，零猜测
static void DLEnsureReconForPasscodeField(id field) {
    if (!field || !DLIsSpringBoard()) return;
    if (![field respondsToSelector:@selector(delegate)]) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id dlg = [field performSelector:@selector(delegate)];
#pragma clang diagnostic pop
    if (!dlg) return;
    DLReconClass([dlg class], @"delegate");
}

// ===========================================================================
// Hook 组 D：锁屏生命周期 —— 锁屏出现/消失时清空缓冲，避免串门
// ===========================================================================

@interface SBLockScreenManager : NSObject
@end

%hook SBLockScreenManager
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    DLResetInput();
    DLProbe(@"锁屏出现 → 清空输入缓冲");
    %orig;
}
- (void)noteLockScreenUIDidDisappear {
    // 进真桌面时清掉一切痕迹（避免下次锁屏被上次输入污染）
    DLResetInput();
    %orig;
}
%end

// ===========================================================================
// 启动
// ===========================================================================

static void DLDumpEnvironment(void) {
    DLProbe(@"========== DecoyLock %@ 启动（Tweak.x v0.1.7 侦查版）==========", DL_VERSION);
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
}

%ctor {
    @autoreleasepool {
        if (DLIsSpringBoard()) {
            DLDumpEnvironment();

            // ⭐ 关键：枚举所有类，挂钩 attemptUnlockWithPasscode:
            //    必须在 springboard 起来之后、用户解锁之前完成。
            //    构造器阶段 SpringBoard 的锁屏类可能还没注册，
            //    所以延后 3 秒再挂一次（挂不上就说明系统不用这个方法，
            //    此时依赖密码框捕获 + yield 兜底，不会锁死设备）。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DLHookAllAttemptUnlock();
                // ⭐ 侦查挂钩：对锁屏管理器做方法名筛选挂钩，
                //    日志会告诉我们 iOS 16.6 真正的密码验证方法名
                Class sm = NSClassFromString(@"SBLockScreenManager");
                if (sm) DLReconClass(sm, @"启动侦查");
                DLProbe(@"[自检] 3 秒后复读配置：已启用=%d 伪密码已配置=%d",
                        DLEnabled(), DLDecoyPasscode().length > 0);
            });
        }
    }
}
