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
#import "Controllers/CLSettingsViewController.h"

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

// 显式声明（避免"方法定义在使用之后"的实例方法解析差异，编译更稳）
- (void)refresh;
- (void)renderBattery;
- (void)renderLevel;
- (void)renderSettings;
- (void)updateMaxLabel;
- (void)updateStartLabel;
- (void)thermalToggled:(UISwitch *)sender;
- (void)maxChanged:(UISlider *)sender;
- (void)maxCommitted:(UISlider *)sender;
- (void)startChanged:(UISlider *)sender;
- (void)startCommitted:(UISlider *)sender;
- (void)openMoreSettings;

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
    [self.maxSlider addTarget:self action:@selector(maxCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

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
    [self.startSlider addTarget:self action:@selector(startCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
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

    // ---- 更多设置 ----
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    more.translatesAutoresizingMaskIntoConstraints = NO;
    [more setTitle:@"更多设置" forState:UIControlStateNormal];
    [more setTitleColor:CLColorSub() forState:UIControlStateNormal];
    more.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [more addTarget:self action:@selector(openMoreSettings) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:more];
    [NSLayoutConstraint activateConstraints:@[
        [more.heightAnchor constraintEqualToConstant:44],
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

- (void)renderSettings {
    if (self.applyingRemoteValues) return;
    self.applyingRemoteValues = YES;

    [self.thermalSwitch setOn:[self boolFromConf:@"jy_thermal_enabled" fallback:YES] animated:NO];

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

- (void)thermalToggled:(UISwitch *)sender {
    BOOL on = sender.isOn;
    [[CLAPIClient shared] setConfigWithKey:@"jy_thermal_enabled" value:@(on) completion:nil];
    if (on) {
        // daemon 主开关关闭时所有 set_conf 都会被拒绝（master_off 白名单），先打开。
        [[CLAPIClient shared] setConfigWithKey:@"enable" value:@YES completion:nil];
    }
}

- (void)maxChanged:(UISlider *)sender {
    [self updateMaxLabel];
}

- (void)maxCommitted:(UISlider *)sender {
    int maxPercent = (int)lroundf(sender.value);
    int resume = MAX(20, maxPercent - 5);
    [[CLAPIClient shared] setConfigWithKey:@"jy_max_percent" value:@(maxPercent) completion:nil];
    // 真正执行停充的是上游状态机：charge_above 到顶停、charge_below 回落恢复。
    [[CLAPIClient shared] setConfigWithKey:@"charge_above" value:@(maxPercent) completion:nil];
    [[CLAPIClient shared] setConfigWithKey:@"charge_below" value:@(resume) completion:nil];
    NSLog(@"[Jy] max charge -> %d%% (resume %d%%)", maxPercent, resume);
}

- (void)startChanged:(UISlider *)sender {
    [self updateStartLabel];
}

- (void)startCommitted:(UISlider *)sender {
    int riseLight = (int)lroundf(sender.value);
    int riseModerate = riseLight + 4;
    int fallLight = MAX(20, riseLight - 2);
    int fallModerate = riseLight + 1;
    int emergency = riseLight + 9;
    [[CLAPIClient shared] setConfigWithKey:@"jy_rise_light" value:@(riseLight) completion:nil];
    [[CLAPIClient shared] setConfigWithKey:@"jy_rise_moderate" value:@(riseModerate) completion:nil];
    [[CLAPIClient shared] setConfigWithKey:@"jy_fall_light" value:@(fallLight) completion:nil];
    [[CLAPIClient shared] setConfigWithKey:@"jy_fall_moderate" value:@(fallModerate) completion:nil];
    [[CLAPIClient shared] setConfigWithKey:@"jy_emergency" value:@(emergency) completion:nil];
    NSLog(@"[Jy] thermal thresholds -> light %d / moderate %d / emergency %d",
          riseLight, riseModerate, emergency);
}

#pragma mark - 导航

- (void)openMoreSettings {
    CLSettingsViewController *vc = [[CLSettingsViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
