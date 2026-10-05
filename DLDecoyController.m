#import "DLDecoyController.h"
#import "DLCommon.h"

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
@end

#pragma mark - 假 App 单元格

@interface DLDecoyAppCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
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

+ (BOOL)isShowing {
    return sShared != nil && sShared.view.window != nil;
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

    NSString *decoy = DLDecoyPasscode();
    (void)decoy;

    DLDecoyController *vc = [[DLDecoyController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    sShared = vc;

    // 拿到当前最上层窗口呈现
    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    if (!win) {
        DLProbe(@"decoy 放弃：找不到可用窗口");
        sShared = nil;
        return;
    }

    UIViewController *root = win.rootViewController;
    DLProbe(@"decoy 呈现中 root=%@ win=%@", NSStringFromClass([root class]), NSStringFromClass([win class]));
    [root presentViewController:vc animated:NO completion:^{
        DLProbe(@"decoy 已呈现完成");
    }];
}

+ (void)dismissDecoy {
    if (!sShared) return;
    DLProbe(@"decoy 退出假空间");
    DLDecoyController *vc = sShared;
    [vc dismissViewControllerAnimated:NO completion:^{
        sShared = nil;
    }];
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

    // 壁纸随屏幕尺寸变化时重设渐变 frame
    wp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
}

#pragma mark - 状态区（时间 / 日期 / 机型名）

- (void)buildStatusArea {
    CGFloat w = self.view.bounds.size.width;
    BOOL large = w > 400.0;

    NSString *title = DLDecoyTitle();
    NSString *sub = DLDecoySubtitle();

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
    DLProbe(@"decoy 点击假 App %@", app[@"name"]);

    // 假空间是空壳：弹一个仿系统的「无法打开」
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:app[@"name"]
                         message:@"此设备尚未启用该应用。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
