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

// v0.1.10：输入捕获自检（定义在后面，先声明）
static void DLLogInputCapture(NSString *src);

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
    // v0.1.10：每次输入都沿「视图/响应者/delegate」链上行侦查（内部幂等）
    DLEnsureReconForPasscodeField(self);
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
    gDLReconUntil = CFAbsoluteTimeGetCurrent() + 20.0;
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

// ⭐ 日志：整体 @try + 限流。磁盘 IO 失败绝不能影响 SpringBoard。
static void DLReconLog(id self, SEL _cmd) {
    @try {
        if (!DLReconInWindow()) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - gDLReconLastLog < 0.5) return;    // 限流：2 条/秒
        gDLReconLastLog = now;
        if (gDLReconLogCount++ > 400) return;       // 单次窗口封顶
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
    DLProbe(@"========== DecoyLock %@ 启动（Tweak.x v0.1.10 上行链侦查版）==========", DL_VERSION);
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
            int wlCount = 0;
            NSArray *wl = DLReconWhiteList();
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            if (ms) {
                for (unsigned int j = 0; j < mc; j++) {
                    if ([wl containsObject:NSStringFromSelector(method_getName(ms[j]))])
                        wlCount++;
                }
                free(ms);
            }
            [suspects addObject:[NSString stringWithFormat:@"%@(%@,白名单%d)",
                                 n, imgName, wlCount]];
        }
        free(allClasses);
    }
    DLProbe(@"[清点] 名字可疑的类共 %lu 个：%@",
            (unsigned long)suspects.count,
            [suspects componentsJoinedByString:@" | "]);
}

// ---------------------------------------------------------------------------
// ⭐ v0.1.10：输入捕获自检（用户说「输够 6 位」时立即打一行）
//    这样能立刻区分两种失败：
//      a) 系统根本没走 appendString:（len 涨不上去）→ 输入捕获失效
//      b) len 到了 6 但从没进判定分支 → 阈值/判定条件写错了
// ---------------------------------------------------------------------------
static void DLLogInputCapture(NSString *src) {
    NSUInteger len = DLInputBuffer().length;
    if (len == DLDecoyPasscode().length && len > 0) {
        DLProbe(@"✅ 输入长度已达伪密码位数（%lu 位，源=%@）→ 等待系统验证调用",
                (unsigned long)len, src);
    }
}

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
        }

        // 侦查挂钩：对嫌疑类挂钩，日志会告诉我们真实的密码验证方法名
        Class sm = NSClassFromString(@"SBLockScreenManager");
        if (sm) DLReconClass(sm, @"启动侦查");

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
