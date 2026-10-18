//
//  CLButlerViewController.m
//  Jy's charge
//
//  简约主界面。三个信息块：
//    1) 实时温度 + 温度色带 + 当前限速档位（governor 闭环输出）
//    2) 温控总开关 + 最大充电百分比（到顶停充）
//    3) 温控起点（轻度档阈值，其余档位按固定偏移推导）
//  全部设置写 set_conf，daemon 下一轮电池事件即生效，不需要重启服务。
//

#import "CLButlerViewController.h"
#import "CLAPIClient.h"

// ---- 配色（暗色科技感）----
static UIColor *CLColorBG(void)      { return [UIColor colorWithRed:0.043 green:0.071 blue:0.125 alpha:1.0]; }
static UIColor *CLColorBG2(void)     { return [UIColor colorWithRed:0.067 green:0.098 blue:0.161 alpha:1.0]; }
static UIColor *CLColorCard(void)    { return [UIColor colorWithWhite:1.0 alpha:0.055]; }
static UIColor *CLColorStroke(void)  { return [UIColor colorWithWhite:1.0 alpha:0.09]; }
static UIColor *CLColorText(void)    { return [UIColor colorWithWhite:0.97 alpha:1.0]; }
static UIColor *CLColorSub(void)     { return [UIColor colorWithWhite:0.62 alpha:1.0]; }
static UIColor *CLColorTeal(void)    { return [UIColor colorWithRed:0.20 green:0.90 blue:0.80 alpha:1.0]; }
static UIColor *CLColorAmber(void)   { return [UIColor colorWithRed:1.00 green:0.74 blue:0.25 alpha:1.0]; }
static UIColor *CLColorOrange(void)  { return [UIColor colorWithRed:1.00 green:0.52 blue:0.22 alpha:1.0]; }
static UIColor *CLColorRed(void)     { return [UIColor colorWithRed:1.00 green:0.34 blue:0.34 alpha:1.0]; }

#pragma mark - 温度色带

@interface CLGaugeView : UIView
@property (nonatomic, assign) CGFloat progress;   // 0...1
@end

@implementation CLGaugeView {
    UIView *_fill;
    CAGradientLayer *_grad;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        self.layer.cornerRadius = 5;
        self.clipsToBounds = YES;
        _fill = [[UIView alloc] init];
        _fill.clipsToBounds = YES;
        _fill.layer.cornerRadius = 5;
        _grad = [CAGradientLayer layer];
        _grad.colors = @[(id)CLColorTeal().CGColor,
                         (id)CLColorAmber().CGColor,
                         (id)CLColorOrange().CGColor,
                         (id)CLColorRed().CGColor];
        _grad.startPoint = CGPointMake(0, 0.5);
        _grad.endPoint = CGPointMake(1, 0.5);
        [_fill.layer addSublayer:_grad];
        [self addSubview:_fill];
    }
    return self;
}

- (void)setProgress:(CGFloat)progress {
    _progress = MAX(0.0, MIN(1.0, progress));
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds) * _progress;
    _fill.frame = CGRectMake(0, 0, w, CGRectGetHeight(self.bounds));
    _grad.frame = CGRectMake(0, 0, MAX(w, 1.0), CGRectGetHeight(self.bounds));
}

@end

#pragma mark - 主控制器

@interface CLButlerViewController ()

@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UILabel *socLabel;
@property (nonatomic, strong) UILabel *levelLabel;
@property (nonatomic, strong) UIView *levelDot;
@property (nonatomic, strong) CLGaugeView *gauge;
@property (nonatomic, strong) UILabel *gaugeHint;

@property (nonatomic, strong) UISwitch *thermalSwitch;
@property (nonatomic, strong) UISlider *maxSlider;
@property (nonatomic, strong) UILabel *maxValueLabel;
@property (nonatomic, strong) UISlider *startSlider;
@property (nonatomic, strong) UILabel *startValueLabel;
@property (nonatomic, strong) UILabel *startDetailLabel;

@property (nonatomic, strong) NSDictionary *batInfo;
@property (nonatomic, strong) NSDictionary *conf;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, assign) BOOL applyingRemoteValues;
// 用户正在拖动/刚提交：2 秒内不用远端值回填，避免"松手弹回"（轮询与用户操作竞争）。
@property (nonatomic, assign) BOOL userEditing;
@property (nonatomic, assign) NSTimeInterval lastUserWriteTs;
// 主开关自愈只尝试一次，避免与 daemon 状态形成写循环。
@property (nonatomic, assign) BOOL masterFixAttempted;
// 容量键同步只做一次：历史版本里 charge_above 可能因 -403 没写进去，
// 与界面显示的 jy_max_percent 不一致（设置 84% 却按 80% 停充）。
@property (nonatomic, assign) BOOL capacitySynced;
// 保存结果反馈：写入被拒绝时不能静默装作成功。
@property (nonatomic, strong) UILabel *statusLabel;
// 运行日志面板（默认折叠）
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logInfoLabel;
@property (nonatomic, strong) NSLayoutConstraint *logHeight;
@property (nonatomic, strong) NSTimer *logTimer;
@property (nonatomic, strong) UISwitch *logSwitch;

// 显式声明（避免"方法定义在使用之后"的实例方法解析差异，编译更稳）
- (void)refresh;
- (void)ensureMasterEnabled;
- (void)syncCapacityKeys;
- (void)renderBattery;
- (void)renderLevel;
- (void)renderSettings;
- (void)updateMaxLabel;
- (void)updateStartLabel;
- (void)thermalToggled:(UISwitch *)sender;
- (void)maxChanged:(UISlider *)sender;
- (void)startChanged:(UISlider *)sender;
- (void)commitMax;
- (void)commitStart;
- (void)writeKey:(NSString *)key value:(id)value;
- (void)showStatus:(NSString *)text ok:(BOOL)ok;
- (void)clearStatus;
- (void)toggleLog;
- (void)loadLog;
- (void)clearLog;
- (void)logToggled:(UISwitch *)sender;

@end

@implementation CLButlerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    [self buildBackground];
    [self buildLayout];
    [self refresh];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(refresh)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)dealloc {
    [_refreshTimer invalidate];
    [_logTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appDidBecomeActive {
    [self refresh];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark - 视图搭建

- (void)buildBackground {
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.colors = @[(id)CLColorBG2().CGColor, (id)CLColorBG().CGColor];
    grad.startPoint = CGPointMake(0.1, 0.0);
    grad.endPoint = CGPointMake(0.9, 1.0);
    grad.frame = self.view.bounds;
    grad.name = @"bg";
    [self.view.layer insertSublayer:grad atIndex:0];
    self.view.backgroundColor = CLColorBG();
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *l in self.view.layer.sublayers) {
        if ([l.name isEqualToString:@"bg"]) {
            l.frame = self.view.bounds;
            break;
        }
    }
}

- (UIView *)card {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = CLColorCard();
    v.layer.cornerRadius = 20;
    v.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    v.layer.borderColor = CLColorStroke().CGColor;
    return v;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    return l;
}

- (void)buildLayout {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-40],
    ]];

    // ---- 标题 ----
    UILabel *title = [self label:@"Jy's charge" size:20 weight:UIFontWeightSemibold color:CLColorText()];
    UILabel *subtitle = [self label:@"智能温控充电" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.spacing = 3;
    [stack addArrangedSubview:titleStack];

    // ---- 温度卡 ----
    UIView *hero = [self card];
    [stack addArrangedSubview:hero];

    self.tempLabel = [self label:@"--.-" size:76 weight:UIFontWeightThin color:CLColorText()];
    self.tempLabel.adjustsFontSizeToFitWidth = YES;
    UILabel *unit = [self label:@"℃" size:26 weight:UIFontWeightLight color:CLColorSub()];
    self.gauge = [[CLGaugeView alloc] init];
    self.gauge.translatesAutoresizingMaskIntoConstraints = NO;
    self.gaugeHint = [self label:@"电池温度" size:12 weight:UIFontWeightRegular color:CLColorSub()];

    self.levelDot = [[UIView alloc] init];
    self.levelDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.levelDot.layer.cornerRadius = 4;
    self.levelLabel = [self label:@"待机" size:13 weight:UIFontWeightMedium color:CLColorSub()];
    self.socLabel = [self label:@"--" size:13 weight:UIFontWeightRegular color:CLColorSub()];
    self.socLabel.textAlignment = NSTextAlignmentRight;

    [hero addSubview:self.tempLabel];
    [hero addSubview:unit];
    [hero addSubview:self.gauge];
    [hero addSubview:self.gaugeHint];
    [hero addSubview:self.levelDot];
    [hero addSubview:self.levelLabel];
    [hero addSubview:self.socLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tempLabel.topAnchor constraintEqualToAnchor:hero.topAnchor constant:22],
        [self.tempLabel.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:22],
        [self.tempLabel.widthAnchor constraintEqualToAnchor:hero.widthAnchor multiplier:0.62],

        [unit.leadingAnchor constraintEqualToAnchor:self.tempLabel.trailingAnchor constant:2],
        [unit.firstBaselineAnchor constraintEqualToAnchor:self.tempLabel.firstBaselineAnchor constant:-12],

        [self.gauge.topAnchor constraintEqualToAnchor:self.tempLabel.bottomAnchor constant:16],
        [self.gauge.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:22],
        [self.gauge.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-22],
        [self.gauge.heightAnchor constraintEqualToConstant:10],

        [self.gaugeHint.topAnchor constraintEqualToAnchor:self.gauge.bottomAnchor constant:8],
        [self.gaugeHint.leadingAnchor constraintEqualToAnchor:self.gauge.leadingAnchor],

        [self.socLabel.centerYAnchor constraintEqualToAnchor:self.gaugeHint.centerYAnchor],
        [self.socLabel.trailingAnchor constraintEqualToAnchor:self.gauge.trailingAnchor],

        [self.levelDot.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:22],
        [self.levelDot.topAnchor constraintEqualToAnchor:self.gaugeHint.bottomAnchor constant:22],
        [self.levelDot.widthAnchor constraintEqualToConstant:8],
        [self.levelDot.heightAnchor constraintEqualToConstant:8],

        [self.levelLabel.leadingAnchor constraintEqualToAnchor:self.levelDot.trailingAnchor constant:7],
        [self.levelLabel.centerYAnchor constraintEqualToAnchor:self.levelDot.centerYAnchor],
        [self.levelLabel.trailingAnchor constraintLessThanOrEqualToAnchor:hero.trailingAnchor constant:-22],
        [self.levelLabel.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-22],
    ]];

    // ---- 温控开关卡 ----
    UIView *switchCard = [self card];
    [stack addArrangedSubview:switchCard];
    UILabel *swTitle = [self label:@"温控充电" size:16 weight:UIFontWeightMedium color:CLColorText()];
    UILabel *swDesc = [self label:@"按温度实时下调充电功率，不断电重连" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    swDesc.numberOfLines = 0;
    self.thermalSwitch = [[UISwitch alloc] init];
    self.thermalSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.thermalSwitch.onTintColor = CLColorTeal();
    [self.thermalSwitch addTarget:self action:@selector(thermalToggled:)
                 forControlEvents:UIControlEventValueChanged];
    [switchCard addSubview:swTitle];
    [switchCard addSubview:swDesc];
    [switchCard addSubview:self.thermalSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [swTitle.topAnchor constraintEqualToAnchor:switchCard.topAnchor constant:18],
        [swTitle.leadingAnchor constraintEqualToAnchor:switchCard.leadingAnchor constant:20],
        [swTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.thermalSwitch.leadingAnchor constant:-12],

        [self.thermalSwitch.centerYAnchor constraintEqualToAnchor:swTitle.centerYAnchor],
        [self.thermalSwitch.trailingAnchor constraintEqualToAnchor:switchCard.trailingAnchor constant:-18],

        [swDesc.topAnchor constraintEqualToAnchor:swTitle.bottomAnchor constant:6],
        [swDesc.leadingAnchor constraintEqualToAnchor:swTitle.leadingAnchor],
        [swDesc.trailingAnchor constraintEqualToAnchor:switchCard.trailingAnchor constant:-20],
        [swDesc.bottomAnchor constraintEqualToAnchor:switchCard.bottomAnchor constant:-18],
    ]];

    // ---- 最大充电卡 ----
    UIView *maxCard = [self card];
    [stack addArrangedSubview:maxCard];
    UILabel *maxTitle = [self label:@"最大充电" size:16 weight:UIFontWeightMedium color:CLColorText()];
    self.maxValueLabel = [self label:@"80%" size:26 weight:UIFontWeightLight color:CLColorTeal()];
    self.maxValueLabel.textAlignment = NSTextAlignmentRight;
    UILabel *maxDesc = [self label:@"达到该电量后停止充电，回落 5% 后恢复" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    maxDesc.numberOfLines = 0;
    self.maxSlider = [[UISlider alloc] init];
    self.maxSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.maxSlider.minimumValue = 50;
    self.maxSlider.maximumValue = 100;
    self.maxSlider.minimumTrackTintColor = CLColorTeal();
    self.maxSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [self.maxSlider addTarget:self action:@selector(maxChanged:) forControlEvents:UIControlEventValueChanged];
    [self.maxSlider addTarget:self action:@selector(maxChanged:) forControlEvents:UIControlEventTouchDown];

    [maxCard addSubview:maxTitle];
    [maxCard addSubview:self.maxValueLabel];
    [maxCard addSubview:self.maxSlider];
    [maxCard addSubview:maxDesc];
    [NSLayoutConstraint activateConstraints:@[
        [maxTitle.topAnchor constraintEqualToAnchor:maxCard.topAnchor constant:18],
        [maxTitle.leadingAnchor constraintEqualToAnchor:maxCard.leadingAnchor constant:20],

        [self.maxValueLabel.centerYAnchor constraintEqualToAnchor:maxTitle.centerYAnchor],
        [self.maxValueLabel.trailingAnchor constraintEqualToAnchor:maxCard.trailingAnchor constant:-20],

        [self.maxSlider.topAnchor constraintEqualToAnchor:maxTitle.bottomAnchor constant:14],
        [self.maxSlider.leadingAnchor constraintEqualToAnchor:maxCard.leadingAnchor constant:20],
        [self.maxSlider.trailingAnchor constraintEqualToAnchor:maxCard.trailingAnchor constant:-20],

        [maxDesc.topAnchor constraintEqualToAnchor:self.maxSlider.bottomAnchor constant:10],
        [maxDesc.leadingAnchor constraintEqualToAnchor:maxTitle.leadingAnchor],
        [maxDesc.trailingAnchor constraintEqualToAnchor:maxCard.trailingAnchor constant:-20],
        [maxDesc.bottomAnchor constraintEqualToAnchor:maxCard.bottomAnchor constant:-18],
    ]];

    // ---- 温控起点卡 ----
    UIView *startCard = [self card];
    [stack addArrangedSubview:startCard];
    UILabel *stTitle = [self label:@"温控起点" size:16 weight:UIFontWeightMedium color:CLColorText()];
    self.startValueLabel = [self label:@"35℃" size:26 weight:UIFontWeightLight color:CLColorAmber()];
    self.startValueLabel.textAlignment = NSTextAlignmentRight;
    self.startSlider = [[UISlider alloc] init];
    self.startSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.startSlider.minimumValue = 30;
    self.startSlider.maximumValue = 40;
    self.startSlider.minimumTrackTintColor = CLColorAmber();
    self.startSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [self.startSlider addTarget:self action:@selector(startChanged:) forControlEvents:UIControlEventValueChanged];
    [self.startSlider addTarget:self action:@selector(startChanged:) forControlEvents:UIControlEventTouchDown];
    self.startDetailLabel = [self label:@"轻度 35℃ · 中度 39℃ · 紧急 44℃" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    self.startDetailLabel.numberOfLines = 0;

    [startCard addSubview:stTitle];
    [startCard addSubview:self.startValueLabel];
    [startCard addSubview:self.startSlider];
    [startCard addSubview:self.startDetailLabel];
    [NSLayoutConstraint activateConstraints:@[
        [stTitle.topAnchor constraintEqualToAnchor:startCard.topAnchor constant:18],
        [stTitle.leadingAnchor constraintEqualToAnchor:startCard.leadingAnchor constant:20],

        [self.startValueLabel.centerYAnchor constraintEqualToAnchor:stTitle.centerYAnchor],
        [self.startValueLabel.trailingAnchor constraintEqualToAnchor:startCard.trailingAnchor constant:-20],

        [self.startSlider.topAnchor constraintEqualToAnchor:stTitle.bottomAnchor constant:14],
        [self.startSlider.leadingAnchor constraintEqualToAnchor:startCard.leadingAnchor constant:20],
        [self.startSlider.trailingAnchor constraintEqualToAnchor:startCard.trailingAnchor constant:-20],

        [self.startDetailLabel.topAnchor constraintEqualToAnchor:self.startSlider.bottomAnchor constant:10],
        [self.startDetailLabel.leadingAnchor constraintEqualToAnchor:stTitle.leadingAnchor],
        [self.startDetailLabel.trailingAnchor constraintEqualToAnchor:startCard.trailingAnchor constant:-20],
        [self.startDetailLabel.bottomAnchor constraintEqualToAnchor:startCard.bottomAnchor constant:-18],
    ]];

    // ---- 运行日志（默认折叠；排障时展开）----
    UIView *logCard = [self card];
    [stack addArrangedSubview:logCard];

    UIButton *logToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    logToggle.translatesAutoresizingMaskIntoConstraints = NO;
    [logToggle setTitle:@"运行日志" forState:UIControlStateNormal];
    [logToggle setTitleColor:CLColorText() forState:UIControlStateNormal];
    logToggle.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    logToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [logToggle addTarget:self action:@selector(toggleLog) forControlEvents:UIControlEventTouchUpInside];

    UIButton *logClear = [UIButton buttonWithType:UIButtonTypeSystem];
    logClear.translatesAutoresizingMaskIntoConstraints = NO;
    [logClear setTitle:@"清空" forState:UIControlStateNormal];
    [logClear setTitleColor:CLColorSub() forState:UIControlStateNormal];
    logClear.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    [logClear addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];

    // 记录开关：默认开，排障后可以彻底关掉（关闭后 daemon 不再写任何日志行）。
    self.logSwitch = [[UISwitch alloc] init];
    self.logSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.logSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.logSwitch.onTintColor = CLColorTeal();
    [self.logSwitch addTarget:self action:@selector(logToggled:)
             forControlEvents:UIControlEventValueChanged];

    self.logInfoLabel = [self label:@"" size:10 weight:UIFontWeightRegular color:CLColorSub()];
    self.logInfoLabel.numberOfLines = 1;
    self.logInfoLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    self.logTextView = [[UITextView alloc] init];
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logTextView.editable = NO;
    self.logTextView.scrollEnabled = YES;
    self.logTextView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    self.logTextView.layer.cornerRadius = 10;
    self.logTextView.textColor = CLColorSub();
    self.logTextView.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    self.logTextView.text = @"";
    self.logTextView.hidden = YES;

    [logCard addSubview:logToggle];
    [logCard addSubview:logClear];
    [logCard addSubview:self.logSwitch];
    [logCard addSubview:self.logInfoLabel];
    [logCard addSubview:self.logTextView];
    self.logHeight = [self.logTextView.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [logToggle.topAnchor constraintEqualToAnchor:logCard.topAnchor constant:16],
        [logToggle.leadingAnchor constraintEqualToAnchor:logCard.leadingAnchor constant:20],
        [logToggle.heightAnchor constraintEqualToConstant:22],

        [self.logSwitch.centerYAnchor constraintEqualToAnchor:logToggle.centerYAnchor],
        [self.logSwitch.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-16],

        [logClear.centerYAnchor constraintEqualToAnchor:logToggle.centerYAnchor],
        [logClear.trailingAnchor constraintEqualToAnchor:self.logSwitch.leadingAnchor constant:-8],

        [self.logInfoLabel.topAnchor constraintEqualToAnchor:logToggle.bottomAnchor constant:4],
        [self.logInfoLabel.leadingAnchor constraintEqualToAnchor:logToggle.leadingAnchor],
        [self.logInfoLabel.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-20],

        [self.logTextView.topAnchor constraintEqualToAnchor:self.logInfoLabel.bottomAnchor constant:8],
        [self.logTextView.leadingAnchor constraintEqualToAnchor:logCard.leadingAnchor constant:16],
        [self.logTextView.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-16],
        [self.logTextView.bottomAnchor constraintEqualToAnchor:logCard.bottomAnchor constant:-14],
        self.logHeight,
    ]];

    // ---- 保存状态（写入被拒时可见；成功时短暂显示"已保存"）----
    self.statusLabel = [self label:@"" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:20],
    ]];
}

#pragma mark - 数据刷新

- (void)refresh {
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] getBatteryInfoWithCompletion:^(NSDictionary *response, NSError *error) {
        NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
        if (data) {
            weakSelf.batInfo = data;
            [weakSelf renderBattery];
        }
    }];
    [[CLAPIClient shared] getConfigWithKey:nil completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
        if (data) {
            weakSelf.conf = data;
            [weakSelf ensureMasterEnabled];
            [weakSelf syncCapacityKeys];
            [weakSelf renderSettings];
            [weakSelf renderLevel];
        }
    }];
}

- (NSInteger)intFromConf:(NSString *)key fallback:(NSInteger)fallback {
    id v = self.conf[key];
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : fallback;
}

- (BOOL)boolFromConf:(NSString *)key fallback:(BOOL)fallback {
    id v = self.conf[key];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

- (void)renderBattery {
    id tempObj = self.batInfo[@"Temperature"];
    double centi = [tempObj respondsToSelector:@selector(doubleValue)] ? [tempObj doubleValue] : 0.0;
    double temp = centi / 100.0;
    BOOL hasTemp = (centi > 0.0);

    self.tempLabel.text = hasTemp ? [NSString stringWithFormat:@"%.1f", temp] : @"--.-";
    UIColor *tempColor = CLColorTeal();
    if (temp >= 44.0)      tempColor = CLColorRed();
    else if (temp >= 39.0) tempColor = CLColorOrange();
    else if (temp >= 35.0) tempColor = CLColorAmber();
    self.tempLabel.textColor = tempColor;

    // 色带量程 25℃-50℃：日常区间铺满，极值留边。
    self.gauge.progress = hasTemp ? (CGFloat)((temp - 25.0) / 25.0) : 0.0;

    NSInteger capacity = [self.batInfo[@"CurrentCapacity"] integerValue];
    BOOL charging = [self.batInfo[@"IsCharging"] boolValue];
    BOOL external = [self.batInfo[@"ExternalConnected"] boolValue];
    NSString *power = external ? (charging ? @"充电中" : @"已接通电源") : @"未接电源";
    // 实测电流（iOS 充电时为负值）：档位升降后这个数字是否变化，是柔性调控
    // 是否真的生效的直接证据，所以放在主界面而不是埋进诊断页。
    long long amp = [self.batInfo[@"InstantAmperage"] longLongValue];
    long long ampAbs = (amp < 0) ? -amp : amp;
    NSString *ampText = (external && ampAbs > 0)
        ? [NSString stringWithFormat:@" · %lldmA", ampAbs] : @"";
    self.socLabel.text = [NSString stringWithFormat:@"%ld%% · %@%@",
                          (long)capacity, power, ampText];
}

- (void)renderLevel {
    NSInteger level = [self intFromConf:@"jy_gov_level" fallback:0];
    BOOL stopped = [self boolFromConf:@"jy_gov_stopped" fallback:NO];

    NSString *text = @"待机";
    UIColor *color = CLColorSub();
    if (stopped) {
        text = @"紧急停充";
        color = CLColorRed();
    } else if (level >= 4) {
        text = @"重度限速";
        color = CLColorRed();
    } else if (level == 3) {
        text = @"中度限速";
        color = CLColorOrange();
    } else if (level == 2) {
        text = @"轻度限速";
        color = CLColorAmber();
    } else if (level == 1) {
        text = @"标称档位";
        color = CLColorTeal();
    }
    self.levelLabel.text = text;
    self.levelLabel.textColor = color;
    self.levelDot.backgroundColor = color;
}

// 主开关自愈：温控开着但 daemon 处于 master-off 时，所有上游键（charge_above /
// charge_below）都会被 -403 拒绝，而且 governor 在 !g_enable 时直接不执行——
// 表现就是"设置存不住 + 温度再高也不降功率"。这里主动把主开关拉起来。
- (void)ensureMasterEnabled {
    if (self.masterFixAttempted) return;
    BOOL masterOn = [self boolFromConf:@"enable" fallback:YES];
    BOOL thermalOn = [self boolFromConf:@"jy_thermal_enabled" fallback:YES];
    if (masterOn || !thermalOn) return;
    self.masterFixAttempted = YES;
    [self writeKey:@"enable" value:@YES];
    [self showStatus:@"后台服务未开启，已自动启用" ok:YES];
    NSLog(@"[Jy] daemon master switch was off -> re-enabled");
}

// 容量键同步（一次性）：界面认 jy_max_percent，上游状态机认 charge_above/below。
// 老版本因 -403 可能只写进了前者，导致"显示 84% 却按 80% 停充"。
- (void)syncCapacityKeys {
    if (self.capacitySynced) return;
    if (![self boolFromConf:@"enable" fallback:YES]) return;   // 主开关没开时写也没用
    NSInteger wanted = [self intFromConf:@"jy_max_percent" fallback:-1];
    if (wanted < 0) return;
    NSInteger current = [self intFromConf:@"charge_above" fallback:80];
    if (wanted == current) { self.capacitySynced = YES; return; }
    self.capacitySynced = YES;
    [self writeKey:@"charge_above" value:@(wanted)];
    [self writeKey:@"charge_below" value:@(MAX(20, wanted - 5))];
    NSLog(@"[Jy] capacity keys re-synced: charge_above %ld -> %ld", (long)current, (long)wanted);
}

- (void)renderSettings {
    if (self.applyingRemoteValues) return;
    // 用户正在拖动、或刚提交不到 2 秒：不回填远端值。轮询 2 秒一次，
    // 若不放行，松手瞬间就会被上一轮 get_conf 的旧值拉回去（表现为"弹回默认"）。
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.userEditing || (now - self.lastUserWriteTs) < 2.0) return;
    self.applyingRemoteValues = YES;

    [self.thermalSwitch setOn:[self boolFromConf:@"jy_thermal_enabled" fallback:YES] animated:NO];
    [self.logSwitch setOn:[self boolFromConf:@"jy_log_enabled" fallback:YES] animated:NO];

    NSInteger maxPercent = [self intFromConf:@"jy_max_percent" fallback:[self intFromConf:@"charge_above" fallback:80]];
    self.maxSlider.value = (float)MAX(50, MIN(100, maxPercent));
    [self updateMaxLabel];

    NSInteger riseLight = [self intFromConf:@"jy_rise_light" fallback:35];
    self.startSlider.value = (float)MAX(30, MIN(40, riseLight));
    [self updateStartLabel];

    self.applyingRemoteValues = NO;
}

- (void)updateMaxLabel {
    self.maxValueLabel.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(self.maxSlider.value)];
}

- (void)updateStartLabel {
    int riseLight = (int)lroundf(self.startSlider.value);
    self.startValueLabel.text = [NSString stringWithFormat:@"%d℃", riseLight];
    self.startDetailLabel.text = [NSString stringWithFormat:@"轻度 %d℃ · 中度 %d℃ · 紧急 %d℃",
                                  riseLight, riseLight + 4, riseLight + 9];
}

#pragma mark - 设置写入

// 统一写入：把 daemon 的拒绝显式暴露出来。以前静默失败，界面表现为"值自己弹回去"，
// 排查只能靠猜；现在能看到具体状态码。
- (void)writeKey:(NSString *)key value:(id)value {
    [[CLAPIClient shared] setConfigWithKey:key value:value completion:^(NSDictionary *response, NSError *error) {
        if (error != nil) {
            [self showStatus:[NSString stringWithFormat:@"%@ 保存失败：连接错误", key] ok:NO];
            return;
        }
        NSInteger status = [response[@"status"] integerValue];
        if (status != 0) {
            [self showStatus:[NSString stringWithFormat:@"%@ 被拒绝（%ld）", key, (long)status] ok:NO];
        }
    }];
}

- (void)showStatus:(NSString *)text ok:(BOOL)ok {
    self.statusLabel.text = text;
    self.statusLabel.textColor = ok ? CLColorTeal() : CLColorRed();
    if (ok) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearStatus) object:nil];
        [self performSelector:@selector(clearStatus) withObject:nil afterDelay:1.6];
    }
}

- (void)clearStatus {
    self.statusLabel.text = @"";
}

- (void)thermalToggled:(UISwitch *)sender {
    BOOL on = sender.isOn;
    self.lastUserWriteTs = [NSDate timeIntervalSinceReferenceDate];
    // 先开主开关：daemon 在 g_enable=NO 时会对 set_conf 做白名单拦截。
    if (on) {
        [self writeKey:@"enable" value:@YES];
    }
    [self writeKey:@"jy_thermal_enabled" value:@(on)];
    [self showStatus:on ? @"温控已开启" : @"温控已关闭" ok:YES];
}

- (void)maxChanged:(UISlider *)sender {
    [self updateMaxLabel];
    self.userEditing = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitMax) object:nil];
    [self performSelector:@selector(commitMax) withObject:nil afterDelay:0.35];
}

- (void)commitMax {
    int maxPercent = (int)lroundf(self.maxSlider.value);
    int resume = MAX(20, maxPercent - 5);
    self.userEditing = NO;
    self.lastUserWriteTs = [NSDate timeIntervalSinceReferenceDate];
    [self writeKey:@"jy_max_percent" value:@(maxPercent)];
    // 真正执行停充的是上游状态机：charge_above 到顶停、charge_below 回落恢复。
    [self writeKey:@"charge_above" value:@(maxPercent)];
    [self writeKey:@"charge_below" value:@(resume)];
    [self showStatus:[NSString stringWithFormat:@"最大充电 %d%% · 低于 %d%% 恢复", maxPercent, resume] ok:YES];
    NSLog(@"[Jy] max charge -> %d%% (resume %d%%)", maxPercent, resume);
}

- (void)startChanged:(UISlider *)sender {
    [self updateStartLabel];
    self.userEditing = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitStart) object:nil];
    [self performSelector:@selector(commitStart) withObject:nil afterDelay:0.35];
}

- (void)commitStart {
    int riseLight = (int)lroundf(self.startSlider.value);
    int riseModerate = riseLight + 4;
    int fallLight = MAX(20, riseLight - 2);
    int fallModerate = riseLight + 1;
    int emergency = riseLight + 9;
    self.userEditing = NO;
    self.lastUserWriteTs = [NSDate timeIntervalSinceReferenceDate];
    [self writeKey:@"jy_rise_light" value:@(riseLight)];
    [self writeKey:@"jy_rise_moderate" value:@(riseModerate)];
    [self writeKey:@"jy_fall_light" value:@(fallLight)];
    [self writeKey:@"jy_fall_moderate" value:@(fallModerate)];
    [self writeKey:@"jy_emergency" value:@(emergency)];
    [self showStatus:[NSString stringWithFormat:@"轻度 %d℃ · 中度 %d℃ · 紧急 %d℃",
                      riseLight, riseModerate, emergency] ok:YES];
    NSLog(@"[Jy] thermal thresholds -> light %d / moderate %d / emergency %d",
          riseLight, riseModerate, emergency);
}

#pragma mark - 运行日志

- (void)toggleLog {
    if (self.logTextView.hidden) {
        [self loadLog];
    } else {
        self.logTextView.hidden = YES;
        self.logHeight.constant = 0;
        [self.logTimer invalidate];
        self.logTimer = nil;
    }
}

- (void)loadLog {
    __weak typeof(self) weakSelf = self;
    // 面板展开期间每 3 秒自动刷新——日志本来就是用来看"现在发生了什么"的，
    // 每次都要手动收起再展开才能看到新行，等于没有。
    if (self.logTimer == nil) {
        self.logTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
            [weakSelf loadLog];
        }];
    }
    [[CLAPIClient shared] sendRequest:@{@"api": @"jy_log"}
                          completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
        NSString *text = [data[@"text"] isKindOfClass:[NSString class]] ? data[@"text"] : @"";
        BOOL wasHidden = weakSelf.logTextView.hidden;
        weakSelf.logTextView.text = text.length
            ? text
            : @"（暂无记录：daemon 还没有产生温控评估日志。若已插电仍为空，说明 governor 没有执行。）";
        NSNumber *size = [data[@"size"] isKindOfClass:[NSNumber class]] ? data[@"size"] : @0;
        NSString *path = [data[@"path"] isKindOfClass:[NSString class]] ? data[@"path"] : @"";
        NSString *name = path.length ? path.lastPathComponent : @"jys-governor.log";
        weakSelf.logInfoLabel.text = [NSString stringWithFormat:@"%@ · %.1f KB",
                                      name, size.doubleValue / 1024.0];
        weakSelf.logTextView.hidden = NO;
        weakSelf.logHeight.constant = 220;
        // 只有首次展开才回到顶部；自动刷新时不打断用户正在看的位置。
        if (wasHidden) [weakSelf.logTextView setContentOffset:CGPointZero animated:NO];
    }];
}

- (void)clearLog {
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] sendRequest:@{@"api": @"jy_log_clear"}
                          completion:^(NSDictionary *response, NSError *error) {
        weakSelf.logTextView.text = @"（日志已清空）";
        weakSelf.logInfoLabel.text = @"jys-governor.log · 0.0 KB";
    }];
}

- (void)logToggled:(UISwitch *)sender {
    BOOL on = sender.isOn;
    self.lastUserWriteTs = [NSDate timeIntervalSinceReferenceDate];
    [self writeKey:@"jy_log_enabled" value:@(on)];
    [self showStatus:on ? @"运行日志已开启" : @"运行日志已关闭" ok:YES];
    if (!on) self.logTextView.text = @"（日志记录已关闭，可随时重新打开）";
}

@end
