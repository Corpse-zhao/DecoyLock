#ifndef DLRootListController_h
#define DLRootListController_h

#import <UIKit/UIKit.h>

// PSListController 的私有声明（dynamic_lookup，不链接 Preferences.framework）
// ⚠️ `_specifiers` ivar 必须声明在基类接口里 —— PSListController 的表格数据源
//    直接访问自己的 _specifiers ivar（编译期绑定），子类写别处基类永远看到 nil，
//    现象就是「能点进面板但整页空白」。
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    @protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (UITableView *)table;
@end

// 主面板：保留 PSListController（Root.plist 驱动，最稳）
// 暴露 pushTextEditor: 给 plist 里的 PSLinkCell 用
@interface DLRootListController : PSListController
@end

// ⚠️ 以下两个控制器【不继承 PSListController】，纯原生 UIKit
//    原因：手搓 PSSpecifier（[PSSpecifier new] + setValue:forKey:）极脆弱，
//    用户实测「假空间 APP 点击闪退」。改用原生 UITableViewController 后零私有 API 依赖。

@interface DLAppPickerController : UITableViewController
@end

// ⭐ v0.1.16：退出 App 选择器（单选）。
// 用户反馈「好难退出去」（连点 8 次 / 长按 3 秒太隐蔽），改成在假空间里
// 点指定 App 直接退出。这里让它自己选是哪个 App。
@interface DLExitAppPickerController : UITableViewController
@end

// 文本编辑页（替代不稳定的 PSTextFieldSpecifier）—— 纯 UIViewController + autolayout
@interface DLTextEditController : UIViewController
@property (nonatomic, copy)   NSString *cfgKey;
@property (nonatomic, copy)   NSString *cfgTitle;
@property (nonatomic, assign) BOOL numericOnly;
@property (nonatomic, strong) UITextField *textField;
@end

// 诊断日志查看器（v0.1.6 新增）—— 纯原生 UITableViewController。
// ⚠️ 以前用 UIAlertController 的 message 显示日志，内容一长就显示不全、
//    也没法复制 —— 排查时用户根本没法把日志发出来。改成长列表 + 一键复制。
@interface DLProbeController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *lines;
@property (nonatomic, copy)   NSString *plain;   // 供「复制」按钮用的全文
@end

#endif /* DLRootListController_h */
