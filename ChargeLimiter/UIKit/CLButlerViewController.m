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

#pragma mark - 近 30 分钟曲线

// 三条归一化曲线叠加：温度（橙，20–45℃）、充电电流（青，0–3000mA）、占空比（琥珀，0–1）。
// 只读展示，不参与任何控制。
@interface CLCurveView : UIView
@property (nonatomic, strong) NSArray<NSDictionary *> *samples;   // @{t,temp,amp,duty}
@end

@implementation CLCurveView

- (void)setSamples:(NSArray<NSDictionary *> *)samples {
    _samples = [samples copy];
    [self setNeedsDisplay];
}

- (void)drawLineInContext:(CGContextRef)ctx key:(NSString *)key
                      min:(double)mn max:(double)mx color:(UIColor *)color
                        w:(CGFloat)w h:(CGFloat)h {
    NSArray *arr = self.samples;
    NSUInteger n = arr.count;
    if (n < 2 || mx <= mn) return;
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 1.6);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    BOOL started = NO;
    for (NSUInteger i = 0; i < n; i++) {
        id vObj = arr[i][key];
        if (vObj == nil) continue;
        double v = [vObj doubleValue];
        double r = (v - mn) / (mx - mn);
        if (r < 0) r = 0; if (r > 1) r = 1;
        CGFloat x = (n <= 1) ? 0 : (w * (CGFloat)i / (CGFloat)(n - 1));
        CGFloat y = h * (1.0 - (CGFloat)r);
        if (!started) { CGContextMoveToPoint(ctx, x, y); started = YES; }
        else { CGContextAddLineToPoint(ctx, x, y); }
    }
    if (started) CGContextStrokePath(ctx);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat w = CGRectGetWidth(rect), h = CGRectGetHeight(rect);
    if (w <= 0 || h <= 0) return;

    // 网格（4 条横线）
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.07].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    for (int i = 0; i <= 3; i++) {
        CGFloat y = h * (CGFloat)i / 3.0;
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, w, y);
    }
    CGContextStrokePath(ctx);

    if (self.samples.count < 2) {
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:11],
                                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.45 alpha:1.0]};
        [@"等待采样…（约 1 分钟出现曲线）" drawAtPoint:CGPointMake(8, h / 2 - 7) withAttributes:attrs];
        return;
    }

    [self drawLineInContext:ctx key:@"temp" min:20 max:45 color:CLColorOrange() w:w h:h];
    [self drawLineInContext:ctx key:@"duty" min:0 max:1 color:CLColorAmber() w:w h:h];
    [self drawLineInContext:ctx key:@"amp" min:0 max:3000 color:CLColorTeal() w:w h:h];
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
// 浮动提示（覆盖层，不随滚动）
@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, strong) UILabel *toastLabel;
// 动效
@property (nonatomic, strong) UIStackView *cardStack;
@property (nonatomic, assign) BOOL didPlayEntrance;
// 运行日志面板（默认折叠）
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logInfoLabel;
@property (nonatomic, strong) NSLayoutConstraint *logHeight;
@property (nonatomic, strong) NSTimer *logTimer;
@property (nonatomic, strong) UISwitch *logSwitch;
// 自 2009-04-18 起的天数计数（纪念日）
@property (nonatomic, strong) UILabel *dayCountLabel;
// 底部版本号
@property (nonatomic, strong) UILabel *versionLabel;
// 近 30 分钟曲线（App 侧采样，不碰 daemon）
@property (nonatomic, strong) CLCurveView *curveView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *curveSamples;
@property (nonatomic, assign) NSTimeInterval curveLastSampleTs;
// 紧急补电（定时暂停温控，到点自动恢复）
@property (nonatomic, strong) UIButton *urgentButton;
// 充电模式预设（护电/均衡/快充）
@property (nonatomic, strong) UISegmentedControl *presetControl;
// PWM 周期：顺滑优先(20s) / 少启停优先(60s)
@property (nonatomic, strong) UISegmentedControl *periodControl;
// 本次充电统计
@property (nonatomic, strong) UILabel *sessStateLabel;
@property (nonatomic, strong) UILabel *sessPeakLabel;
@property (nonatomic, strong) UILabel *sessAvgLabel;
@property (nonatomic, strong) UILabel *sessMahLabel;
@property (nonatomic, strong) UILabel *sessCyclesLabel;
// 最大充电说明（拖动时显示 ETA 预览）
@property (nonatomic, strong) UILabel *maxDescLabel;
// 充电记录
@property (nonatomic, strong) UIStackView *historyStack;
@property (nonatomic, assign) NSTimeInterval historyLastTs;
// 周期满充校准（上游 full_charge_sched_*，仅暴露 UI）
@property (nonatomic, strong) UISwitch *fullChargeSwitch;
@property (nonatomic, strong) UISegmentedControl *fullChargeInterval;
@property (nonatomic, strong) UIDatePicker *fullChargeTimePicker;
@property (nonatomic, strong) UISlider *fullChargeDurationSlider;
@property (nonatomic, strong) UILabel *fullChargeDurationLabel;

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
- (void)restartThermald;
- (void)probeHW;
- (void)updateDayCount;
- (void)sampleCurveIfNeeded;
- (void)urgentTopUp:(UIButton *)sender;
- (void)updateUrgentButton;
- (void)presetChanged:(UISegmentedControl *)sender;
- (void)periodChanged:(UISegmentedControl *)sender;
- (void)renderSession;
- (void)loadHistory;
- (void)renderHistory:(NSArray *)rows;
- (void)fullChargeToggled:(UISwitch *)sender;
- (void)fullChargeIntervalChanged:(UISegmentedControl *)sender;
- (void)fullChargeTimeChanged:(UIDatePicker *)sender;
- (void)fullChargeDurationChanged:(UISlider *)sender;
- (void)commitFullChargeDuration;
- (void)renderFullChargeSchedule;
- (double)doubleFromConf:(NSString *)key fallback:(double)fallback;

@end

@implementation CLButlerViewController

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didPlayEntrance) return;
    self.didPlayEntrance = YES;
    // 入场：卡片自下而上浮现，按顺序轻微错峰（40ms），克制不拖沓。
    NSArray<UIView *> *cards = self.cardStack.arrangedSubviews;
    for (NSUInteger i = 0; i < cards.count; i++) {
        UIView *card = cards[i];
        card.alpha = 0.0;
        card.transform = CGAffineTransformMakeTranslation(0, 14);
        [UIView animateWithDuration:0.42
                              delay:0.04 * (NSTimeInterval)i
             usingSpringWithDamping:0.92
              initialSpringVelocity:0.2
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            card.alpha = 1.0;
            card.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

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
    self.cardStack = stack;
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
    self.dayCountLabel = [self label:@"" size:12 weight:UIFontWeightMedium color:CLColorTeal()];
    self.dayCountLabel.textAlignment = NSTextAlignmentRight;
    [self updateDayCount];
    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle, self.dayCountLabel]];
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
    self.socLabel.adjustsFontSizeToFitWidth = YES;
    self.socLabel.minimumScaleFactor = 0.65;
    self.socLabel.lineBreakMode = NSLineBreakByClipping;

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
        // 防重叠：电量/电流/功率/ETA 变长时不得压到左侧「电池温度」上。
        [self.socLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.gaugeHint.trailingAnchor constant:8],

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

    // 紧急补电：临时暂停温控（满速充），到点自动恢复，避免忘记打开。
    self.urgentButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.urgentButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.urgentButton setTitle:@"紧急补电 30 分钟" forState:UIControlStateNormal];
    self.urgentButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [self.urgentButton setTitleColor:CLColorAmber() forState:UIControlStateNormal];
    self.urgentButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    self.urgentButton.layer.cornerRadius = 12;
    self.urgentButton.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [self.urgentButton addTarget:self action:@selector(urgentTopUp:) forControlEvents:UIControlEventTouchUpInside];
    [self attachPressAnimation:self.urgentButton];
    [switchCard addSubview:self.urgentButton];

    // 顺滑优先 / 少启停优先：只改 PWM 周期（20s / 60s），平均功率不变。
    self.periodControl = [[UISegmentedControl alloc] initWithItems:@[@"顺滑优先", @"少启停优先"]];
    self.periodControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.periodControl.selectedSegmentIndex = 0;
    self.periodControl.selectedSegmentTintColor = CLColorTeal();
    [self.periodControl addTarget:self action:@selector(periodChanged:)
                 forControlEvents:UIControlEventValueChanged];
    [switchCard addSubview:self.periodControl];

    [NSLayoutConstraint activateConstraints:@[
        [swTitle.topAnchor constraintEqualToAnchor:switchCard.topAnchor constant:18],
        [swTitle.leadingAnchor constraintEqualToAnchor:switchCard.leadingAnchor constant:20],
        [swTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.thermalSwitch.leadingAnchor constant:-12],

        [self.thermalSwitch.centerYAnchor constraintEqualToAnchor:swTitle.centerYAnchor],
        [self.thermalSwitch.trailingAnchor constraintEqualToAnchor:switchCard.trailingAnchor constant:-18],

        [swDesc.topAnchor constraintEqualToAnchor:swTitle.bottomAnchor constant:6],
        [swDesc.leadingAnchor constraintEqualToAnchor:swTitle.leadingAnchor],
        [swDesc.trailingAnchor constraintEqualToAnchor:switchCard.trailingAnchor constant:-20],

        [self.urgentButton.topAnchor constraintEqualToAnchor:swDesc.bottomAnchor constant:10],
        [self.urgentButton.leadingAnchor constraintEqualToAnchor:swDesc.leadingAnchor],
        [self.urgentButton.heightAnchor constraintEqualToConstant:30],

        [self.periodControl.topAnchor constraintEqualToAnchor:self.urgentButton.bottomAnchor constant:10],
        [self.periodControl.leadingAnchor constraintEqualToAnchor:swDesc.leadingAnchor],
        [self.periodControl.trailingAnchor constraintEqualToAnchor:switchCard.trailingAnchor constant:-20],
        [self.periodControl.heightAnchor constraintEqualToConstant:30],
        [self.periodControl.bottomAnchor constraintEqualToAnchor:switchCard.bottomAnchor constant:-16],
    ]];

    // ---- 最大充电卡 ----
    UIView *maxCard = [self card];
    [stack addArrangedSubview:maxCard];
    UILabel *maxTitle = [self label:@"最大充电" size:16 weight:UIFontWeightMedium color:CLColorText()];
    self.maxValueLabel = [self label:@"80%" size:26 weight:UIFontWeightLight color:CLColorTeal()];
    self.maxValueLabel.textAlignment = NSTextAlignmentRight;
    self.maxDescLabel = [self label:@"达到该电量后停止充电，回落 5% 后恢复" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    self.maxDescLabel.numberOfLines = 0;
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
    [maxCard addSubview:self.maxDescLabel];

    [NSLayoutConstraint activateConstraints:@[
        [maxTitle.topAnchor constraintEqualToAnchor:maxCard.topAnchor constant:18],
        [maxTitle.leadingAnchor constraintEqualToAnchor:maxCard.leadingAnchor constant:20],

        [self.maxValueLabel.centerYAnchor constraintEqualToAnchor:maxTitle.centerYAnchor],
        [self.maxValueLabel.trailingAnchor constraintEqualToAnchor:maxCard.trailingAnchor constant:-20],

        [self.maxSlider.topAnchor constraintEqualToAnchor:maxTitle.bottomAnchor constant:14],
        [self.maxSlider.leadingAnchor constraintEqualToAnchor:maxCard.leadingAnchor constant:20],
        [self.maxSlider.trailingAnchor constraintEqualToAnchor:maxCard.trailingAnchor constant:-20],

        [self.maxDescLabel.topAnchor constraintEqualToAnchor:self.maxSlider.bottomAnchor constant:10],
        [self.maxDescLabel.leadingAnchor constraintEqualToAnchor:maxTitle.leadingAnchor],
        [self.maxDescLabel.trailingAnchor constraintEqualToAnchor:maxCard.trailingAnchor constant:-20],

        [self.maxDescLabel.bottomAnchor constraintEqualToAnchor:maxCard.bottomAnchor constant:-18],
    ]];

    // ---- 充电模式（预设）----
    UIView *presetCard = [self card];
    [stack addArrangedSubview:presetCard];
    UILabel *prTitle = [self label:@"充电模式" size:16 weight:UIFontWeightMedium color:CLColorText()];
    UILabel *prDesc = [self label:@"一键切换推荐参数，切换后仍可手动微调" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    prDesc.numberOfLines = 0;
    self.presetControl = [[UISegmentedControl alloc] initWithItems:@[@"护电", @"均衡", @"快充"]];
    self.presetControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.presetControl.selectedSegmentIndex = UISegmentedControlNoSegment;
    self.presetControl.selectedSegmentTintColor = CLColorTeal();
    [self.presetControl addTarget:self action:@selector(presetChanged:)
                 forControlEvents:UIControlEventValueChanged];
    [presetCard addSubview:prTitle];
    [presetCard addSubview:prDesc];
    [presetCard addSubview:self.presetControl];
    [NSLayoutConstraint activateConstraints:@[
        [prTitle.topAnchor constraintEqualToAnchor:presetCard.topAnchor constant:18],
        [prTitle.leadingAnchor constraintEqualToAnchor:presetCard.leadingAnchor constant:20],
        [prDesc.topAnchor constraintEqualToAnchor:prTitle.bottomAnchor constant:6],
        [prDesc.leadingAnchor constraintEqualToAnchor:prTitle.leadingAnchor],
        [prDesc.trailingAnchor constraintEqualToAnchor:presetCard.trailingAnchor constant:-20],
        [self.presetControl.topAnchor constraintEqualToAnchor:prDesc.bottomAnchor constant:12],
        [self.presetControl.leadingAnchor constraintEqualToAnchor:presetCard.leadingAnchor constant:20],
        [self.presetControl.trailingAnchor constraintEqualToAnchor:presetCard.trailingAnchor constant:-20],
        [self.presetControl.heightAnchor constraintEqualToConstant:32],
        [self.presetControl.bottomAnchor constraintEqualToAnchor:presetCard.bottomAnchor constant:-18],
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

    // ---- 充电曲线（近 30 分钟，App 侧采样；只读展示）----
    UIView *curveCard = [self card];
    [stack addArrangedSubview:curveCard];

    UILabel *cvTitle = [self label:@"充电曲线" size:13 weight:UIFontWeightSemibold color:CLColorText()];
    UILabel *cvRange = [self label:@"近 30 分钟" size:11 weight:UIFontWeightRegular color:CLColorSub()];
    self.curveView = [[CLCurveView alloc] init];
    self.curveView.translatesAutoresizingMaskIntoConstraints = NO;
    self.curveView.backgroundColor = [UIColor clearColor];
    self.curveView.samples = @[];

    UILabel *lgTemp = [self label:@"● 温度" size:10 weight:UIFontWeightRegular color:CLColorOrange()];
    UILabel *lgAmp  = [self label:@"● 电流" size:10 weight:UIFontWeightRegular color:CLColorTeal()];
    UILabel *lgDuty = [self label:@"● 占空比" size:10 weight:UIFontWeightRegular color:CLColorAmber()];
    UIStackView *legend = [[UIStackView alloc] initWithArrangedSubviews:@[lgTemp, lgAmp, lgDuty]];
    legend.axis = UILayoutConstraintAxisHorizontal;
    legend.spacing = 12;
    legend.translatesAutoresizingMaskIntoConstraints = NO;

    [curveCard addSubview:cvTitle];
    [curveCard addSubview:cvRange];
    [curveCard addSubview:self.curveView];
    [curveCard addSubview:legend];
    [NSLayoutConstraint activateConstraints:@[
        [cvTitle.topAnchor constraintEqualToAnchor:curveCard.topAnchor constant:18],
        [cvTitle.leadingAnchor constraintEqualToAnchor:curveCard.leadingAnchor constant:20],
        [cvRange.centerYAnchor constraintEqualToAnchor:cvTitle.centerYAnchor],
        [cvRange.trailingAnchor constraintEqualToAnchor:curveCard.trailingAnchor constant:-20],
        [self.curveView.topAnchor constraintEqualToAnchor:cvTitle.bottomAnchor constant:12],
        [self.curveView.leadingAnchor constraintEqualToAnchor:curveCard.leadingAnchor constant:20],
        [self.curveView.trailingAnchor constraintEqualToAnchor:curveCard.trailingAnchor constant:-20],
        [self.curveView.heightAnchor constraintEqualToConstant:110],
        [legend.topAnchor constraintEqualToAnchor:self.curveView.bottomAnchor constant:10],
        [legend.leadingAnchor constraintEqualToAnchor:curveCard.leadingAnchor constant:20],
        [legend.bottomAnchor constraintEqualToAnchor:curveCard.bottomAnchor constant:-16],
    ]];

    // ---- 本次充电统计 ----
    UIView *sessCard = [self card];
    [stack addArrangedSubview:sessCard];
    UILabel *seTitle = [self label:@"本次充电" size:13 weight:UIFontWeightSemibold color:CLColorText()];
    self.sessStateLabel = [self label:@"" size:11 weight:UIFontWeightRegular color:CLColorSub()];
    self.sessStateLabel.textAlignment = NSTextAlignmentRight;
    self.sessPeakLabel = [self label:@"峰值 --" size:11 weight:UIFontWeightRegular color:CLColorOrange()];
    self.sessAvgLabel  = [self label:@"平均 --" size:11 weight:UIFontWeightRegular color:CLColorSub()];
    self.sessAvgLabel.textAlignment = NSTextAlignmentRight;
    self.sessMahLabel  = [self label:@"充入 --" size:11 weight:UIFontWeightRegular color:CLColorTeal()];
    self.sessCyclesLabel = [self label:@"启停 --" size:11 weight:UIFontWeightRegular color:CLColorAmber()];
    self.sessCyclesLabel.textAlignment = NSTextAlignmentRight;

    for (UILabel *l in @[seTitle, self.sessStateLabel, self.sessPeakLabel, self.sessAvgLabel,
                         self.sessMahLabel, self.sessCyclesLabel]) {
        [sessCard addSubview:l];
    }
    [NSLayoutConstraint activateConstraints:@[
        [seTitle.topAnchor constraintEqualToAnchor:sessCard.topAnchor constant:18],
        [seTitle.leadingAnchor constraintEqualToAnchor:sessCard.leadingAnchor constant:20],
        [self.sessStateLabel.centerYAnchor constraintEqualToAnchor:seTitle.centerYAnchor],
        [self.sessStateLabel.trailingAnchor constraintEqualToAnchor:sessCard.trailingAnchor constant:-20],

        [self.sessPeakLabel.topAnchor constraintEqualToAnchor:seTitle.bottomAnchor constant:10],
        [self.sessPeakLabel.leadingAnchor constraintEqualToAnchor:seTitle.leadingAnchor],
        [self.sessAvgLabel.centerYAnchor constraintEqualToAnchor:self.sessPeakLabel.centerYAnchor],
        [self.sessAvgLabel.trailingAnchor constraintEqualToAnchor:sessCard.trailingAnchor constant:-20],

        [self.sessMahLabel.topAnchor constraintEqualToAnchor:self.sessPeakLabel.bottomAnchor constant:8],
        [self.sessMahLabel.leadingAnchor constraintEqualToAnchor:seTitle.leadingAnchor],
        [self.sessCyclesLabel.centerYAnchor constraintEqualToAnchor:self.sessMahLabel.centerYAnchor],
        [self.sessCyclesLabel.trailingAnchor constraintEqualToAnchor:sessCard.trailingAnchor constant:-20],
        [self.sessMahLabel.bottomAnchor constraintEqualToAnchor:sessCard.bottomAnchor constant:-18],
    ]];

    // ---- 周期满充校准 ----
    UIView *fcCard = [self card];
    [stack addArrangedSubview:fcCard];
    UILabel *fcTitle = [self label:@"周期满充校准" size:16 weight:UIFontWeightMedium color:CLColorText()];
    self.fullChargeSwitch = [[UISwitch alloc] init];
    self.fullChargeSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.fullChargeSwitch.onTintColor = CLColorTeal();
    [self.fullChargeSwitch addTarget:self action:@selector(fullChargeToggled:)
                    forControlEvents:UIControlEventValueChanged];
    UILabel *fcDesc = [self label:@"每 N 天在指定窗口内放行到 100%，让电量计重新学习满充点（不改变实际容量）"
                                size:12 weight:UIFontWeightRegular color:CLColorSub()];
    fcDesc.numberOfLines = 0;
    self.fullChargeInterval = [[UISegmentedControl alloc] initWithItems:@[@"7 天", @"15 天", @"30 天"]];
    self.fullChargeInterval.translatesAutoresizingMaskIntoConstraints = NO;
    self.fullChargeInterval.selectedSegmentTintColor = CLColorTeal();
    [self.fullChargeInterval addTarget:self action:@selector(fullChargeIntervalChanged:)
                      forControlEvents:UIControlEventValueChanged];
    UILabel *fcTimeLabel = [self label:@"开始时间" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    self.fullChargeTimePicker = [[UIDatePicker alloc] init];
    self.fullChargeTimePicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.fullChargeTimePicker.datePickerMode = UIDatePickerModeTime;
    self.fullChargeTimePicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    [self.fullChargeTimePicker addTarget:self action:@selector(fullChargeTimeChanged:)
                        forControlEvents:UIControlEventValueChanged];
    self.fullChargeDurationLabel = [self label:@"持续 3 小时" size:12 weight:UIFontWeightRegular color:CLColorSub()];
    self.fullChargeDurationSlider = [[UISlider alloc] init];
    self.fullChargeDurationSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.fullChargeDurationSlider.minimumValue = 1;
    self.fullChargeDurationSlider.maximumValue = 6;
    self.fullChargeDurationSlider.minimumTrackTintColor = CLColorTeal();
    self.fullChargeDurationSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [self.fullChargeDurationSlider addTarget:self action:@selector(fullChargeDurationChanged:)
                            forControlEvents:UIControlEventValueChanged];

    for (UIView *v in @[fcTitle, self.fullChargeSwitch, fcDesc, self.fullChargeInterval,
                        fcTimeLabel, self.fullChargeTimePicker,
                        self.fullChargeDurationLabel, self.fullChargeDurationSlider]) {
        [fcCard addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [fcTitle.topAnchor constraintEqualToAnchor:fcCard.topAnchor constant:18],
        [fcTitle.leadingAnchor constraintEqualToAnchor:fcCard.leadingAnchor constant:20],
        [fcTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.fullChargeSwitch.leadingAnchor constant:-12],
        [self.fullChargeSwitch.centerYAnchor constraintEqualToAnchor:fcTitle.centerYAnchor],
        [self.fullChargeSwitch.trailingAnchor constraintEqualToAnchor:fcCard.trailingAnchor constant:-18],

        [fcDesc.topAnchor constraintEqualToAnchor:fcTitle.bottomAnchor constant:6],
        [fcDesc.leadingAnchor constraintEqualToAnchor:fcTitle.leadingAnchor],
        [fcDesc.trailingAnchor constraintEqualToAnchor:fcCard.trailingAnchor constant:-20],

        [self.fullChargeInterval.topAnchor constraintEqualToAnchor:fcDesc.bottomAnchor constant:12],
        [self.fullChargeInterval.leadingAnchor constraintEqualToAnchor:fcTitle.leadingAnchor],
        [self.fullChargeInterval.trailingAnchor constraintEqualToAnchor:fcCard.trailingAnchor constant:-20],
        [self.fullChargeInterval.heightAnchor constraintEqualToConstant:30],

        [fcTimeLabel.topAnchor constraintEqualToAnchor:self.fullChargeInterval.bottomAnchor constant:12],
        [fcTimeLabel.leadingAnchor constraintEqualToAnchor:fcTitle.leadingAnchor],
        [self.fullChargeTimePicker.centerYAnchor constraintEqualToAnchor:fcTimeLabel.centerYAnchor],
        [self.fullChargeTimePicker.trailingAnchor constraintEqualToAnchor:fcCard.trailingAnchor constant:-20],

        [self.fullChargeDurationLabel.topAnchor constraintEqualToAnchor:fcTimeLabel.bottomAnchor constant:10],
        [self.fullChargeDurationLabel.leadingAnchor constraintEqualToAnchor:fcTitle.leadingAnchor],

        [self.fullChargeDurationSlider.topAnchor constraintEqualToAnchor:self.fullChargeDurationLabel.bottomAnchor constant:4],
        [self.fullChargeDurationSlider.leadingAnchor constraintEqualToAnchor:fcTitle.leadingAnchor],
        [self.fullChargeDurationSlider.trailingAnchor constraintEqualToAnchor:fcCard.trailingAnchor constant:-20],
        [self.fullChargeDurationSlider.bottomAnchor constraintEqualToAnchor:fcCard.bottomAnchor constant:-18],
    ]];

    // ---- 充电记录（最近 6 次会话，仅本地）----
    UIView *histCard = [self card];
    [stack addArrangedSubview:histCard];
    UILabel *hTitle = [self label:@"充电记录" size:13 weight:UIFontWeightSemibold color:CLColorText()];
    UILabel *hNote = [self label:@"仅本地保存" size:10 weight:UIFontWeightRegular color:CLColorSub()];
    self.historyStack = [[UIStackView alloc] init];
    self.historyStack.axis = UILayoutConstraintAxisVertical;
    self.historyStack.spacing = 6;
    self.historyStack.translatesAutoresizingMaskIntoConstraints = NO;
    [histCard addSubview:hTitle];
    [histCard addSubview:hNote];
    [histCard addSubview:self.historyStack];
    [NSLayoutConstraint activateConstraints:@[
        [hTitle.topAnchor constraintEqualToAnchor:histCard.topAnchor constant:18],
        [hTitle.leadingAnchor constraintEqualToAnchor:histCard.leadingAnchor constant:20],
        [hNote.centerYAnchor constraintEqualToAnchor:hTitle.centerYAnchor],
        [hNote.trailingAnchor constraintEqualToAnchor:histCard.trailingAnchor constant:-20],
        [self.historyStack.topAnchor constraintEqualToAnchor:hTitle.bottomAnchor constant:10],
        [self.historyStack.leadingAnchor constraintEqualToAnchor:histCard.leadingAnchor constant:20],
        [self.historyStack.trailingAnchor constraintEqualToAnchor:histCard.trailingAnchor constant:-20],
        [self.historyStack.bottomAnchor constraintEqualToAnchor:histCard.bottomAnchor constant:-18],
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

    UIButton *logRestart = [UIButton buttonWithType:UIButtonTypeSystem];
    logRestart.translatesAutoresizingMaskIntoConstraints = NO;
    [logRestart setTitle:@"重启服务" forState:UIControlStateNormal];
    [logRestart setTitleColor:CLColorAmber() forState:UIControlStateNormal];
    logRestart.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    [logRestart addTarget:self action:@selector(restartThermald) forControlEvents:UIControlEventTouchUpInside];

    UIButton *logHW = [UIButton buttonWithType:UIButtonTypeSystem];
    logHW.translatesAutoresizingMaskIntoConstraints = NO;
    [logHW setTitle:@"硬件探测" forState:UIControlStateNormal];
    [logHW setTitleColor:CLColorTeal() forState:UIControlStateNormal];
    logHW.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    [logHW addTarget:self action:@selector(probeHW) forControlEvents:UIControlEventTouchUpInside];

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
    [logCard addSubview:logRestart];
    [logCard addSubview:logHW];
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

        [logRestart.centerYAnchor constraintEqualToAnchor:logToggle.centerYAnchor],
        [logRestart.trailingAnchor constraintEqualToAnchor:logClear.leadingAnchor constant:-8],

        [logHW.centerYAnchor constraintEqualToAnchor:logToggle.centerYAnchor],
        [logHW.trailingAnchor constraintEqualToAnchor:logRestart.leadingAnchor constant:-10],

        [self.logInfoLabel.topAnchor constraintEqualToAnchor:logToggle.bottomAnchor constant:4],
        [self.logInfoLabel.leadingAnchor constraintEqualToAnchor:logToggle.leadingAnchor],
        [self.logInfoLabel.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-20],

        [self.logTextView.topAnchor constraintEqualToAnchor:self.logInfoLabel.bottomAnchor constant:8],
        [self.logTextView.leadingAnchor constraintEqualToAnchor:logCard.leadingAnchor constant:16],
        [self.logTextView.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-16],
        [self.logTextView.bottomAnchor constraintEqualToAnchor:logCard.bottomAnchor constant:-14],
        self.logHeight,
    ]];

    // 保存状态改为浮动 Toast（见 buildLayout 末尾），不再占列表底部空间。

    // ---- 版本号（整个软件最下方）----
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    self.versionLabel = [self label:[NSString stringWithFormat:@"Jy's charge v%@", ver ?: @"?"]
                               size:11 weight:UIFontWeightRegular color:CLColorSub()];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:self.versionLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.versionLabel.heightAnchor constraintGreaterThanOrEqualToConstant:16],
    ]];

    // ---- 浮动 Toast：覆盖在窗口底部，不随滚动，任何位置都能看到 ----
    self.toastView = [[UIView alloc] init];
    self.toastView.translatesAutoresizingMaskIntoConstraints = NO;
    self.toastView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    self.toastView.layer.cornerRadius = 14;
    self.toastView.layer.borderWidth = 0.5;
    self.toastView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.toastView.alpha = 0.0;
    self.toastView.userInteractionEnabled = NO;   // 不阻挡下方操作
    self.toastLabel = [self label:@"" size:12 weight:UIFontWeightMedium color:CLColorText()];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.numberOfLines = 0;
    [self.toastView addSubview:self.toastLabel];
    [self.view addSubview:self.toastView];
    [NSLayoutConstraint activateConstraints:@[
        [self.toastView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.toastView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.toastView.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.toastView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [self.toastLabel.topAnchor constraintEqualToAnchor:self.toastView.topAnchor constant:10],
        [self.toastLabel.bottomAnchor constraintEqualToAnchor:self.toastView.bottomAnchor constant:-10],
        [self.toastLabel.leadingAnchor constraintEqualToAnchor:self.toastView.leadingAnchor constant:16],
        [self.toastLabel.trailingAnchor constraintEqualToAnchor:self.toastView.trailingAnchor constant:-16],
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
            [weakSelf sampleCurveIfNeeded];
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
            [weakSelf loadHistory];   // 20 秒节流，内部判断
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

- (NSString *)stringFromConf:(NSString *)key fallback:(NSString *)fallback {
    id v = self.conf[key];
    return [v isKindOfClass:[NSString class]] ? v : fallback;
}

- (double)doubleFromConf:(NSString *)key fallback:(double)fallback {
    id v = self.conf[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}

// 曲线采样：每 5 秒一点，保留 30 分钟（360 点）。只在 App 内存里存，不写盘、不碰 daemon。
- (void)sampleCurveIfNeeded {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.curveLastSampleTs > 0 && (now - self.curveLastSampleTs) < 5.0) return;
    self.curveLastSampleTs = now;
    if (self.curveSamples == nil) self.curveSamples = [NSMutableArray array];

    double temp = [self.batInfo[@"Temperature"] doubleValue] / 100.0;
    long long amp = [self.batInfo[@"Amperage"] longLongValue];
    if (amp < 0) amp = -amp;
    id dutyObj = self.conf[@"jy_gov_duty"];
    float duty = [dutyObj respondsToSelector:@selector(floatValue)] ? [dutyObj floatValue] : 1.0f;

    [self.curveSamples addObject:@{@"t": @(now), @"temp": @(temp), @"amp": @(amp), @"duty": @(duty)}];
    while (self.curveSamples.count > 360) [self.curveSamples removeObjectAtIndex:0];
    self.curveView.samples = self.curveSamples;
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
    BOOL sysPause = [self boolFromConf:@"jy_sys_pause" fallback:NO];
    NSString *stateText = external ? (charging ? @"充电中" : (sysPause ? @"系统暂停" : @"已接通电源")) : @"未接电源";
    // 电流优先用 Amperage（平滑值更稳、更准），缺失回退 InstantAmperage。
    NSNumber *ampObj = self.batInfo[@"Amperage"] ?: self.batInfo[@"InstantAmperage"];
    long long amp = [ampObj longLongValue];
    long long ampAbs = (amp < 0) ? -amp : amp;
    NSMutableString *tail = [NSMutableString string];
    if (charging && ampAbs > 0) {
        [tail appendFormat:@" · %lldmA", ampAbs];
        // 充电功率 = 电池电压(V) × 充电电流(A)（如 4.1V × 2.15A ≈ 8.8W）
        double volt = [self.batInfo[@"Voltage"] doubleValue] / 1000.0;
        double watt = volt * (ampAbs / 1000.0);
        if (watt >= 0.01) [tail appendFormat:@" · %.1fW", watt];
    }
    // P2 剩余充电时间：紧凑格式（避免与左侧「电池温度」重叠）
    NSString *etaState = [self stringFromConf:@"jy_eta_state" fallback:@""];
    NSInteger etaMin = [self intFromConf:@"jy_eta_min" fallback:-1];
    if ([etaState isEqualToString:@"charging"] && etaMin >= 0) {
        if (etaMin < 60) [tail appendFormat:@" · %ld分", (long)etaMin];
        else [tail appendFormat:@" · %ld时%ld分", (long)(etaMin / 60), (long)(etaMin % 60)];
    } else if ([etaState isEqualToString:@"paused"]) {
        [tail appendString:@" · 暂停"];
    } else if ([etaState isEqualToString:@"estimating"]) {
        [tail appendString:@" · 估算中"];
    } else if ([etaState isEqualToString:@"at_target"]) {
        [tail appendString:@" · 已满"];
    }
    self.socLabel.text = [NSString stringWithFormat:@"%ld%% · %@%@",
                          (long)capacity, stateText, tail];
}

// 自 2009-04-18 起的天数（动态，每天 +1）
- (void)updateDayCount {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    fmt.timeZone = [NSTimeZone localTimeZone];
    NSDate *ref = [fmt dateFromString:@"2009-04-18"];
    NSDate *now = [NSDate date];
    // 以自然日为准（按日历天数，不计时/分/秒）
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *refDay = [cal startOfDayForDate:ref];
    NSDate *nowDay = [cal startOfDayForDate:now];
    NSInteger days = [cal components:NSCalendarUnitDay fromDate:refDay toDate:nowDay options:0].day;
    self.dayCountLabel.text = [NSString stringWithFormat:@"%ld", (long)days];
}

// 紧急补电：临时暂停温控 N 分钟，到点由 daemon 自动恢复（jy_urgent_until）。
- (void)urgentTopUp:(UIButton *)sender {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger until = [self intFromConf:@"jy_urgent_until" fallback:0];
    BOOL active = (until > 0 && (NSTimeInterval)until > now);
    self.lastUserWriteTs = [NSDate timeIntervalSinceReferenceDate];
    if (active) {
        [self writeKey:@"jy_thermal_enabled" value:@YES];
        [self writeKey:@"jy_urgent_until" value:@0];
        [self.thermalSwitch setOn:YES animated:YES];
        [self showStatus:@"已取消紧急补电，温控已恢复" ok:YES];
    } else {
        NSInteger target = (NSInteger)(now + 30 * 60);
        [self writeKey:@"jy_thermal_enabled" value:@NO];
        [self writeKey:@"jy_urgent_until" value:@(target)];
        [self.thermalSwitch setOn:NO animated:YES];
        [self showStatus:@"紧急补电 30 分钟：温控暂停，到点自动恢复" ok:YES];
    }
    [self updateUrgentButton];
}

- (void)updateUrgentButton {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger until = [self intFromConf:@"jy_urgent_until" fallback:0];
    if (until > 0 && (NSTimeInterval)until > now) {
        NSInteger remain = (NSInteger)((NSTimeInterval)until - now);
        [self.urgentButton setTitle:[NSString stringWithFormat:@"紧急补电中 · 剩 %ld:%02ld（点按取消）",
                                     (long)(remain / 60), (long)(remain % 60)]
                           forState:UIControlStateNormal];
        [self.urgentButton setTitleColor:CLColorRed() forState:UIControlStateNormal];
    } else {
        [self.urgentButton setTitle:@"紧急补电 30 分钟" forState:UIControlStateNormal];
        [self.urgentButton setTitleColor:CLColorAmber() forState:UIControlStateNormal];
    }
}

// 充电模式预设：护电 80%/起点30/duty40；均衡 85%/32/55；快充 100%/36/80。
// 只写"推荐参数"，用户之后仍可手动拖动滑块覆盖。
- (void)presetChanged:(UISegmentedControl *)sender {
    int maxPct, riseLight, duty;
    switch (sender.selectedSegmentIndex) {
        case 0:  maxPct = 80;  riseLight = 30; duty = 40; break;   // 护电
        case 2:  maxPct = 100; riseLight = 36; duty = 80; break;   // 快充
        default: maxPct = 85;  riseLight = 32; duty = 55; break;   // 均衡
    }
    int riseMod   = riseLight + 4;
    int fallLight = riseLight - 2;
    int fallMod   = riseLight + 1;
    int emerg     = riseLight + 9;
    int resume    = MAX(20, maxPct - 5);

    self.lastUserWriteTs = [NSDate timeIntervalSinceReferenceDate];
    [self writeKey:@"jy_max_percent" value:@(maxPct)];
    [self writeKey:@"jy_resume_percent" value:@(resume)];
    [self writeKey:@"charge_above" value:@(maxPct)];
    [self writeKey:@"charge_below" value:@(resume)];
    [self writeKey:@"jy_rise_light" value:@(riseLight)];
    [self writeKey:@"jy_rise_moderate" value:@(riseMod)];
    [self writeKey:@"jy_fall_light" value:@(fallLight)];
    [self writeKey:@"jy_fall_moderate" value:@(fallMod)];
    [self writeKey:@"jy_emergency" value:@(emerg)];
    [self writeKey:@"jy_pwm_moderate_duty" value:@(duty)];

    self.maxSlider.value = (float)maxPct;
    self.startSlider.value = (float)riseLight;
    [self updateMaxLabel];
    [self updateStartLabel];
    [self showStatus:[NSString stringWithFormat:@"%@：上限 %d%% · 起点 %d℃",
                      [sender titleForSegmentAtIndex:sender.selectedSegmentIndex], maxPct, riseLight]
                  ok:YES];
}

- (void)loadHistory {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.historyLastTs < 20.0) return;   // 20 秒节流
    self.historyLastTs = now;
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] sendRequest:@{ @"api": @"get_jy_sessions", @"n": @6 }
                          completion:^(NSDictionary *response, NSError *error) {
        if (error != nil) return;
        NSArray *rows = [response[@"data"] isKindOfClass:[NSArray class]] ? response[@"data"] : @[];
        [weakSelf renderHistory:rows];
    }];
}

- (void)renderHistory:(NSArray *)rows {
    if (self.historyStack == nil) return;
    for (UIView *v in self.historyStack.arrangedSubviews) {
        [self.historyStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (rows.count == 0) {
        [self.historyStack addArrangedSubview:[self label:@"暂无记录（拔电后自动生成）"
                                                    size:11 weight:UIFontWeightRegular color:CLColorSub()]];
        return;
    }
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm";
    for (NSDictionary *r in rows) {
        NSTimeInterval s = [r[@"start_ts"] doubleValue];
        NSTimeInterval e = [r[@"end_ts"] doubleValue];
        NSString *line = [NSString stringWithFormat:
                          @"%@ → %@   %@%%→%@%%\n峰值 %.1f℃ · 平均 %.1f℃ · %.0fmAh · 启停 %@ 次",
                          [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:s]],
                          [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:e]],
                          r[@"start_soc"] ?: @0, r[@"end_soc"] ?: @0,
                          [r[@"peak_temp"] doubleValue], [r[@"avg_temp"] doubleValue],
                          [r[@"mah_added"] doubleValue], r[@"cycles"] ?: @0];
        UILabel *row = [self label:line size:11 weight:UIFontWeightRegular color:CLColorSub()];
        row.numberOfLines = 0;
        [self.historyStack addArrangedSubview:row];
    }
}

- (void)fullChargeToggled:(UISwitch *)sender {
    [self writeKey:@"full_charge_sched_enabled" value:@(sender.isOn)];
    [self showStatus:(sender.isOn ? @"已开启周期满充校准" : @"已关闭周期满充校准") ok:YES];
}

- (void)fullChargeIntervalChanged:(UISegmentedControl *)sender {
    NSArray<NSNumber *> *days = @[@7, @15, @30];
    NSInteger idx = MAX(0, MIN((NSInteger)days.count - 1, sender.selectedSegmentIndex));
    [self writeKey:@"full_charge_sched_interval_days" value:days[idx]];
}

- (void)fullChargeTimeChanged:(UIDatePicker *)sender {
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:sender.date];
    NSInteger minute = c.hour * 60 + c.minute;
    [self writeKey:@"full_charge_sched_start_minute" value:@(minute)];
}

- (void)fullChargeDurationChanged:(UISlider *)sender {
    NSInteger hours = (NSInteger)lroundf(sender.value);
    self.fullChargeDurationLabel.text = [NSString stringWithFormat:@"持续 %ld 小时", (long)hours];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitFullChargeDuration) object:nil];
    [self performSelector:@selector(commitFullChargeDuration) withObject:nil afterDelay:0.35];
}

- (void)commitFullChargeDuration {
    NSInteger hours = (NSInteger)lroundf(self.fullChargeDurationSlider.value);
    [self writeKey:@"full_charge_sched_duration_hours" value:@(hours)];
}

- (void)renderFullChargeSchedule {
    [self.fullChargeSwitch setOn:[self boolFromConf:@"full_charge_sched_enabled" fallback:NO] animated:NO];

    NSInteger days = [self intFromConf:@"full_charge_sched_interval_days" fallback:30];
    NSInteger idx = 2;
    if (days <= 7) idx = 0;
    else if (days <= 15) idx = 1;
    self.fullChargeInterval.selectedSegmentIndex = idx;

    NSInteger minute = [self intFromConf:@"full_charge_sched_start_minute" fallback:180];
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.hour = (minute / 60) % 24;
    c.minute = minute % 60;
    NSDate *d = [[NSCalendar currentCalendar] dateFromComponents:c];
    if (d != nil) [self.fullChargeTimePicker setDate:d animated:NO];

    NSInteger hours = [self intFromConf:@"full_charge_sched_duration_hours" fallback:3];
    self.fullChargeDurationSlider.value = (float)hours;
    self.fullChargeDurationLabel.text = [NSString stringWithFormat:@"持续 %ld 小时", (long)hours];
}

- (void)renderSession {
    BOOL active = [self boolFromConf:@"jy_sess_active" fallback:NO];
    NSInteger mins = [self intFromConf:@"jy_sess_min" fallback:0];
    double peak = [self doubleFromConf:@"jy_sess_peak" fallback:0];
    double avg = [self doubleFromConf:@"jy_sess_avg" fallback:0];
    double mah = [self doubleFromConf:@"jy_sess_mah" fallback:0];
    NSInteger cycles = [self intFromConf:@"jy_sess_cycles" fallback:0];

    self.sessStateLabel.text = active
        ? [NSString stringWithFormat:@"进行中 · %ld 分钟", (long)mins]
        : @"上次会话";
    self.sessPeakLabel.text  = [NSString stringWithFormat:@"峰值 %.1f℃", peak];
    self.sessAvgLabel.text   = [NSString stringWithFormat:@"平均 %.1f℃", avg];
    self.sessMahLabel.text   = [NSString stringWithFormat:@"充入 %.0fmAh", mah < 0 ? 0 : mah];
    self.sessCyclesLabel.text = [NSString stringWithFormat:@"启停 %ld 次", (long)cycles];
}

// PWM 周期切换：只影响启停频率，平均占空比不变。
- (void)periodChanged:(UISegmentedControl *)sender {
    NSInteger period = (sender.selectedSegmentIndex == 1) ? 60 : 20;
    [self writeKey:@"jy_pwm_period_s" value:@(period)];
    [self showStatus:(period == 60 ? @"少启停优先：60 秒周期" : @"顺滑优先：20 秒周期") ok:YES];
}

- (void)renderLevel {
    NSInteger level = [self intFromConf:@"jy_gov_level" fallback:0];
    BOOL stopped = [self boolFromConf:@"jy_gov_stopped" fallback:NO];
    BOOL capLatched = [self boolFromConf:@"jy_gov_capacity" fallback:NO];

    NSString *text = @"待机";
    UIColor *color = CLColorSub();
    if (stopped) {
        text = @"紧急停充";
        color = CLColorRed();
    } else if (capLatched) {
        // 已达设定上限：充电任务完成，不再显示"限速档位"（温度关联对已停充无意义）。
        text = @"已充满";
        color = CLColorTeal();
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
    self.capacitySynced = YES;

    NSInteger current = [self intFromConf:@"charge_above" fallback:80];
    if (wanted != current) {
        [self writeKey:@"charge_above" value:@(wanted)];
        [self writeKey:@"charge_below" value:@(MAX(20, wanted - 5))];
        NSLog(@"[Jy] capacity keys re-synced: charge_above %ld -> %ld", (long)current, (long)wanted);
    }
    // 恢复线必须严格小于上限，否则策略内核整体返回 -422 → 档位冻结。
    NSInteger wantResume = MIN(MAX(5, wanted - 5), MAX(5, wanted - 1));
    NSInteger curResume = [self intFromConf:@"jy_resume_percent" fallback:-1];
    if (curResume != wantResume) {
        [self writeKey:@"jy_resume_percent" value:@(wantResume)];
    }
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
    [self updateUrgentButton];

    // 预设高亮：只在参数完全匹配某个预设时选中，否则不高亮（避免误导）。
    NSInteger presetIdx = UISegmentedControlNoSegment;
    if (maxPercent == 80 && riseLight == 30) presetIdx = 0;
    else if (maxPercent == 85 && riseLight == 32) presetIdx = 1;
    else if (maxPercent == 100 && riseLight == 36) presetIdx = 2;
    self.presetControl.selectedSegmentIndex = presetIdx;

    // 周期档位回显：>=40s 视为"少启停优先"。
    NSInteger pwmPeriod = [self intFromConf:@"jy_pwm_period_s" fallback:20];
    self.periodControl.selectedSegmentIndex = (pwmPeriod >= 40) ? 1 : 0;
    [self renderSession];
    [self renderFullChargeSchedule];

    self.applyingRemoteValues = NO;
}

- (void)updateMaxLabel {
    int pct = (int)lroundf(self.maxSlider.value);
    self.maxValueLabel.text = [NSString stringWithFormat:@"%d%%", pct];

    // 拖动时实时预览：用 daemon 暴露的当前速率在本地估算，不额外发请求。
    double rate = [self doubleFromConf:@"jy_eta_rate" fallback:0];
    double rawCur = [self.batInfo[@"AppleRawCurrentCapacity"] doubleValue];
    double rawMax = [self.batInfo[@"AppleRawMaxCapacity"] doubleValue];
    if (rate > 0.3 && rawMax > 0 && rawCur > 0) {
        double remain = rawMax * (double)pct / 100.0 - rawCur;
        if (remain > 0) {
            NSInteger mins = (NSInteger)lround(remain / rate);
            NSString *t = (mins < 60)
                ? [NSString stringWithFormat:@"%ld 分钟", (long)mins]
                : [NSString stringWithFormat:@"%ld 小时 %ld 分", (long)(mins / 60), (long)(mins % 60)];
            self.maxDescLabel.text = [NSString stringWithFormat:@"预计还需约 %@（按当前速率）", t];
            return;
        }
        self.maxDescLabel.text = @"当前电量已达到该目标";
        return;
    }
    self.maxDescLabel.text = @"达到该电量后停止充电，回落 5% 后恢复";
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
            // 回滚 UI 到已知 conf：否则开关"看起来开了"但实际没写进去，
            // 下次刷新又会自己弹回去（用户会以为开关"自己关了"）。
            [self renderSettings];
            return;
        }
        NSInteger status = [response[@"status"] integerValue];
        if (status != 0) {
            [self showStatus:[NSString stringWithFormat:@"%@ 被拒绝（%ld）", key, (long)status] ok:NO];
            [self renderSettings];
        }
    }];
}

- (void)attachPressAnimation:(UIButton *)button {
    [button addTarget:self action:@selector(pressDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(pressUp:)
     forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
}

- (void)pressDown:(UIButton *)button {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        button.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)pressUp:(UIButton *)button {
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        button.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)showStatus:(NSString *)text ok:(BOOL)ok {
    if (self.toastView == nil) return;
    self.toastLabel.text = text;
    UIColor *tint = ok ? CLColorTeal() : CLColorRed();
    self.toastLabel.textColor = tint;
    self.toastView.layer.borderColor = tint.CGColor;
    [self.view bringSubviewToFront:self.toastView];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearStatus) object:nil];
    self.toastView.transform = CGAffineTransformMakeTranslation(0, 8);
    [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.toastView.alpha = 1.0;
        self.toastView.transform = CGAffineTransformIdentity;
    } completion:nil];
    // 成功 2 秒、失败 3.5 秒：错误需要更久的阅读时间。
    [self performSelector:@selector(clearStatus) withObject:nil afterDelay:(ok ? 2.0 : 3.5)];
}

- (void)clearStatus {
    if (self.toastView == nil) return;
    [UIView animateWithDuration:0.25 animations:^{
        self.toastView.alpha = 0.0;
    }];
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
    // jy_resume_percent 必须同步：策略内核要求 resume < max_percent，
    // 不同步会让整个配置返回 -422、档位冻结（真机 2026-10-20）。
    [self writeKey:@"jy_resume_percent" value:@(resume)];
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

- (void)restartThermald {
    [self showStatus:@"正在重启 thermalmonitord…" ok:YES];
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] sendRequest:@{@"api": @"jy_restart_thermald"}
                          completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
        int killed = [data[@"killed_pid"] intValue];
        if (killed > 0) {
            [weakSelf showStatus:[NSString stringWithFormat:@"已重启 thermalmonitord (pid %d)", killed] ok:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ [weakSelf loadLog]; });
        } else {
            NSString *err = [data[@"error"] isKindOfClass:[NSString class]] ? data[@"error"] : @"未找到";
            [weakSelf showStatus:[NSString stringWithFormat:@"重启失败：%@", err] ok:NO];
        }
    }];
}

- (void)probeHW {
    [self showStatus:@"正在探测硬件寄存器…" ok:YES];
    __weak typeof(self) weakSelf = self;
    [[CLAPIClient shared] sendRequest:@{@"api": @"jy_hw"}
                          completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
        NSString *text = [data[@"text"] isKindOfClass:[NSString class]] ? data[@"text"] : @"（探测失败）";
        weakSelf.logTextView.text = text;
        weakSelf.logTextView.hidden = NO;
        weakSelf.logHeight.constant = 400;
        [weakSelf.logTimer invalidate];
        weakSelf.logTimer = nil;
        [weakSelf showStatus:@"硬件属性已 dump（滚动日志面板查看/复制）" ok:YES];
    }];
}

@end
