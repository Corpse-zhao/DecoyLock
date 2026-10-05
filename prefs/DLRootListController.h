#ifndef DLRootListController_h
#define DLRootListController_h

#import <UIKit/UIKit.h>

// PSListController 的私有声明（不链接 Preferences.framework）
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

@interface DLRootListController : PSListController
@end

@interface DLAppPickerController : PSListController
@end

// 保持内置清单顺序的便捷方法（实现见 .m）
@interface NSArray (DLOrder)
- (NSArray *)dlOrderWithSelection:(NSSet *)sel;
@end

#endif /* DLRootListController_h */
