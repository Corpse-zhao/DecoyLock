#import <UIKit/UIKit.h>
#import "DLCommon.h"
#import "DLDecoyController.h"

// ---------------------------------------------------------------------------
// 伪锁屏 Tweak 入口（注入 SpringBoard）
//
// 核心思路：
//   1) 无侵入监听锁屏密码框输入的内容
//   2) 用户按确认/解锁时，先比对是否为「伪密码」
//   3) 命中伪密码 → 不把密码交给系统（系统继续处于锁定态），只呈现假空间
//   4) 未命中 → 放行走原生流程
//
// 兼容性设计：iOS 16 的锁屏密码视图是私有类，且不同越狱环境（roothide / 无根）
// 类名可能有差异。因此采取「候选类名列表 + 运行时探测」的方式，
// 全部失败时退化为「不干预」（宁可没效果，也不能锁死用户的设备）。
// ---------------------------------------------------------------------------

static NSString *const kDLBundleID = @"com.apple.springboard";

// 记录最近一次输入到密码框里的内容
static NSMutableString *gDLInput = nil;
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

// 判定「设置/修改密码界面」不应该被劫持 —— 只在锁屏解锁流程生效
// 这里用一个宽松但有效的判据：伪密码必须是 4~8 位纯数字，且与输入完全相等
static BOOL DLMatchesDecoy(NSString *input) {
    NSString *decoy = DLDecoyPasscode();
    if (!decoy.length || !input.length) return NO;
    return [input isEqualToString:decoy];
}

// 清空缓冲
static void DLResetInput(void) {
    [DLInputBuffer() setString:@""];
}

// 记录输入
static void DLAppendInput(NSString *text) {
    if (!text.length) return;
    [DLInputBuffer() appendString:text];
    // 保险：缓冲长度上限
    if (DLInputBuffer().length > 64) {
        NSRange r = NSMakeRange(DLInputBuffer().length - 32, 32);
        [DLInputBuffer() setString:[DLInputBuffer() substringWithRange:r]];
    }
    DLProbe(@"passcode 输入缓冲 len=%lu", (unsigned long)DLInputBuffer().length);
}

// ---------------------------------------------------------------------------
// 拦截入口：在「密码正确」的判定点前插入。
// 若输入等于伪密码 → 呈现假空间并吞掉本次解锁（返回，不调用 %orig 的后续解锁）
// ---------------------------------------------------------------------------

static BOOL DLShouldHijackUnlock(void) {
    if (!DLIsSpringBoard()) return NO;
    if (!DLEnabled()) return NO;

    NSString *decoy = DLDecoyPasscode();
    if (!decoy.length) return NO;

    NSString *input = [DLInputBuffer() copy];
    if (!DLMatchesDecoy(input)) return NO;

    DLProbe(@"*** 命中伪密码（len=%lu），劫持解锁并呈现假空间", (unsigned long)input.length);
    DLResetInput();

    dispatch_async(dispatch_get_main_queue(), ^{
        [DLDecoyController presentIfConfigured];
    });
    return YES;
}

// ---------------------------------------------------------------------------
// Hook 1：通用密码框输入监听
// iOS 的密码输入视图（SBUIPasscodeEntryField / SBPearlPasscodeEntryField 等）
// 都会有 -setText: / -insertText: 之类的入口。用宽泛的候选列表挂钩。
// ---------------------------------------------------------------------------

@interface SBUIPasscodeEntryField : UIView
@end

@interface SBUIPasscodeNumberPadButton : UIView
@end

// --- 通用：任何 UIKeyInput 的 insertText: ---
%hook UIResponder
- (void)insertText:(NSString *)text {
    %orig;
    if (DLIsSpringBoard() && DLEnabled()) {
        // 只在密码相关视图里记录：父链上含 Passcode 关键字
        UIView *v = (UIView *)self;
        BOOL inPasscode = NO;
        NSUInteger guard = 0;
        while (v && guard++ < 12) {
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"Passcode"] || [cls containsString:@"Pearl"]) {
                inPasscode = YES;
                break;
            }
            v = v.superview;
        }
        if (inPasscode) DLAppendInput(text);
    }
}
%end

// --- 通用：密码输入框 setText: 兜底（程序化设置时） ---
%hook NSObject
- (void)setText:(NSString *)text {
    %orig;
    if (!DLIsSpringBoard() || !DLEnabled()) return;
    NSString *cls = NSStringFromClass([self class]);
    if ([cls containsString:@"Passcode"] || [cls containsString:@"Pearl"]) {
        [DLInputBuffer() setString:text ?: @""];
        DLProbe(@"passcode setText 同步缓冲 %@ len=%lu",
                cls, (unsigned long)DLInputBuffer().length);
    }
}
%end

// ---------------------------------------------------------------------------
// Hook 2：解锁判定点
// SBLockScreenViewController 家族上负责「密码验证结果」的方法。
// 这里采用「结果回调」方式：系统验完密码、认为成功时，我们抢在真正解锁前
// 判断是不是伪密码。
// ---------------------------------------------------------------------------

@interface SBLockScreenViewController : UIViewController
@end

@interface SBUIPasscodeLockViewWithKeyboard : UIView
@end

%hook SBLockScreenViewController
// 密码验证成功回调（多个候选方法名，iOS 版本差异）
- (void)passcodeEntryFieldDidSucceed:(id)field {
    DLProbe(@"hook passcodeEntryFieldDidSucceed, 缓冲=%@", [DLInputBuffer() copy]);
    if (DLShouldHijackUnlock()) return;      // 吞掉，不解锁
    DLResetInput();
    %orig;
}

- (void)notePasscodeEntryFieldDidSucceed:(id)field {
    DLProbe(@"hook notePasscodeEntryFieldDidSucceed, 缓冲=%@", [DLInputBuffer() copy]);
    if (DLShouldHijackUnlock()) return;
    DLResetInput();
    %orig;
}
%end

// ---------------------------------------------------------------------------
// Hook 3：更底层 —— 密码验证器。无论上层 UI 类名怎么变，验证器通常稳定。
// SBUIPasscodeLockView 系列最终都会把输入交给 SBLockScreenManager / 
// SBPasscodeController 之类。这里 hook 一个更通用的点：
// 「密码验证通过后调用」的方法群。全部走同一道 DLShouldHijackUnlock 闸门。
// ---------------------------------------------------------------------------

@interface SBLockScreenManager : NSObject
@end

%hook SBLockScreenManager
- (void)unlockWithIntent:(int)intent {
    NSString *cls __attribute__((unused)) = NSStringFromClass([self class]);
    DLProbe(@"hook unlockWithIntent 前, 缓冲=%@", [DLInputBuffer() copy]);
    if (DLShouldHijackUnlock()) return;
    DLResetInput();
    %orig;
}
%end

// ---------------------------------------------------------------------------
// Hook 4：锁屏消失/重现时清空输入缓冲，避免跨会话污染
// ---------------------------------------------------------------------------

%hook SBUIPasscodeEntryField
- (void)setText:(NSString *)text {
    %orig;
    if (!DLEnabled()) return;
    [DLInputBuffer() setString:text ?: @""];
}
%end

%hook SBUIPasscodeEntryField
- (void)clear {
    %orig;
    DLResetInput();
}
%end

// ---------------------------------------------------------------------------
// 启动日志 + 心跳
// ---------------------------------------------------------------------------

static void DLDumpEnvironment(void) {
    DLProbe(@"========== DecoyLock %@ 启动 ==========", DL_VERSION);
    DLProbe(@"bundle=%@ pid=%d", [NSBundle mainBundle].bundleIdentifier, (int)getpid());
    DLProbe(@"已启用=%d 伪密码已配置=%d", DLEnabled(), DLDecoyPasscode().length > 0);
    DLProbe(@"共享目录=%@", DLSharedDir());
    DLProbe(@"配置存在=%d",
            [[NSFileManager defaultManager] fileExistsAtPath:DLConfigPath()]);
    DLProbe(@"伪 App 数量=%lu", (unsigned long)DLDecoyApps().count);
}

%ctor {
    @autoreleasepool {
        // 只有 SpringBoard 需要这个功能
        if (DLIsSpringBoard()) {
            DLDumpEnvironment();
        }
    }
}
