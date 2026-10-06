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

#define DL_VERSION      @"0.2.6"
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

// ⭐⭐ v0.1.23：会话级 Face ID 暂停（把暂停时机**提前到用户开始输密码**）。
//
// 背景（2026-10-06 用户录屏 + 口述实锤）：v0.1.22 是「假空间铺上之后」才暂停 Face ID，
// 用户反馈「假空间出来了，但中间还是闪了一下刷脸」。
// 原因：系统在用户按完最后一位的**那一瞬间**就开始 Face ID 匹配，
// 我们等假空间铺完才暂停 —— **晚了半步**，那一下已经被放行了。
//
// 正解：把暂停提前到「用户敲下密码框第一位」的时刻（SBUIPasscodeEntryField
// appendString: 第一次被调用）。从那一刻起系统就无法发起匹配。
//
// ⚠️⚠️ 恢复约束（比 v0.1.22 更严）：
//   会话可能以任何方式结束（用户放弃输密码走开、锁屏消失、假空间退出...），
//   所以除了原有的恢复点外，**锁屏生命周期结束时必须无恢复条件地恢复**。
//   绝不使用户的 Face ID 被永久关死。
FOUNDATION_EXPORT void DLBeginPasscodeSession(void);   // 用户开始输密码 → 暂停 Face ID
FOUNDATION_EXPORT void DLEndPasscodeSession(void);     // 会话结束 → 恢复 Face ID
FOUNDATION_EXPORT BOOL DLPasscodeSessionActive(void);  // 是否处于输密码会话中

// ⭐⭐⭐ v0.2.0：**在不解锁真机的前提下进入假空间**（本项目的正确形态）
//
// 用户明确要求（2026-10-06 14:27）：
//   「我的要求是，**在手机不解锁的情况下进入假空间**，
//     现在都是输入完假空间密码，必须要刷脸才能进入假空间」
//
// 此前 v0.1.x 全部走的是「让系统先解锁 → 假空间盖在真桌面上」这条路 ——
// 所以**必然要刷脸**（区别只是闪不闪一下）。
//
// 正确做法：假空间 = **贴在锁屏上面的一层**，真机自始至终保持锁定。
// 前置条件：① 不发起任何解锁请求（不调系统解锁）；
//          ② 窗口挂在**锁屏所在的 scene + lockScreen 窗口层级之上**，
//             而不是挂在「解锁后才出现的最顶层」之上；
//          ③ 期间压制 Face ID 匹配（沿用 v0.1.23 的会话机制）。
//
// ⚠️ 安全约束：一旦离开假空间，必须恢复到「正常锁屏」状态，绝不能让用户
//    卡在一个既进不去真系统、也回不到锁屏的死角。
FOUNDATION_EXPORT void DLPinToLockScreen(void);        // 进入「锁屏贴纸」模式
FOUNDATION_EXPORT void DLUnpinFromLockScreen(void);    // 退出该模式
FOUNDATION_EXPORT BOOL DLPinnedToLockScreen(void);     // 是否处于该模式

// ⭐⭐⭐⭐⭐ v0.2.5：**「拦截决策点」机制** —— 这是真正停用 Face ID 的正解。
//
// 🔥🔥🔥 血泪根因（v0.2.2 日志实锤，我信了整整三个版本）：
//   v0.2.2 日志写着：「[FaceID] 已暂停生物识别匹配（假空间展示期间）
//                      → 命中路径 CSBiometricMatchMonitor
//                        -getBiometricMatchResultForTriggerTimeStamp:」
//   看起来成功了 —— 但 `getBiometricMatchResultForTriggerTimeStamp:` 是个 **getter**
//   （读取匹配结果），调用它**什么都不改变**。**Face ID 从未被停用过一次。**
//   这是一条「假成功」日志，把排查方向带偏了三轮。
//
// 🔥 为什么「命令式暂停」这条路走不通：
//   `SBUIBiometricResource` 上的真实开关是**断言机制**：
//       _addMatchingAssertion: / _removeMatchingAssertion:
//       acquireMatchingAssertionWithMode:reason:
//   它们**都需要一个「断言对象」参数** —— 而那个对象是系统在开启匹配时创建的，
//   我们**造不出来**（私有类型、需要特定 mode/reason）。所以我们永远无法
//   「命令系统把匹配关掉」。
//
// ✅ 正解 = **不命令，改拦截**：
//   系统在决定「要不要让 Face ID 匹配」时，一定会**问**某个方法
//   （`isMatchingEnabled` / `hasMatchingAssertions` / `isMatchingAllowed` ...）。
//   这类查询**没有参数、返回 BOOL** —— 拦它 = 在假空间展示期间直接回答 NO。
//   不需要任何对象参数，不需要猜私有的构造方式。**这是唯一可行的路。**
//
// 实现（Tweak.x）：运行时枚举所有含 Biometric 的类 → 找出「名字像匹配开关查询
//   且返回 BOOL 且无参」的方法 → 全部挂钩 → 假空间期间强制返回 NO → 退出恢复。
//   并把「系统实际问了哪个方法」打进日志（下一轮不用再猜）。
FOUNDATION_EXPORT BOOL DLShouldBlockBiometricMatching(void);   // 现在要不要压制匹配
FOUNDATION_EXPORT void DLNoteBiometricGateHit(NSString *cls, NSString *sel);  // 记一笔命中

#endif /* DLCommon_h */
