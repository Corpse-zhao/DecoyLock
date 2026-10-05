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

// 文本编辑页（替代不稳定的 PSTextFieldSpecifier）
@interface DLTextEditController : UITableViewController
@property (nonatomic, copy)   NSString *cfgKey;
@property (nonatomic, copy)   NSString *cfgTitle;
@property (nonatomic, assign) BOOL numericOnly;
@property (nonatomic, strong) UITextField *textField;
@end

#endif /* DLRootListController_h */
