// CLThermalGovernor — 充电管家温控决策引擎实现。
// 差异化：上游 ChargeLimiter 的 thermal sim 是手动固定档位；本引擎是实时温度
// 闭环自动档位（策略状态经 CLOfflineAdvisory 实例跨轮保持，滞回/min_hold 生效）。
#import "CLThermalGovernor.h"
#import "CLOfflineAdvisory.h"
#import "thermal_policy.h"
#import <notify.h>
#import <mach/mach_time.h>

// 与 CLThermalSimTweak.m 同名通道（daemon 写、tweak 读后下发热模拟档位）。
static NSString *const CLGovernorApplyNotification = @"com.chargelimiter.thermalapply";

@interface CLThermalGovernor ()
@property (nonatomic, readwrite) CLThermalLevel currentLevel;
@property (nonatomic) int applyToken;
@property (nonatomic) BOOL emergencyLatched;
@property (nonatomic) CLOfflineAdvisory *advisory;   // 跨轮复用：tp_policy 状态在实例内
@end

@implementation CLThermalGovernor

+ (instancetype)sharedGovernor {
    static CLThermalGovernor *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _applyToken = -1;
        _currentLevel = CLThermalLevelOff;
        _emergencyLatched = NO;
        notify_register([CLGovernorApplyNotification UTF8String], &_applyToken);
    }
    return self;
}

- (void)dealloc {
    if (_applyToken >= 0) notify_cancel(_applyToken);
}

static double CLContinuousSeconds(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * (double)timebase.numer / (double)timebase.denom / 1e9;
}

- (NSDictionary *)governorSettings {
    // 温控默认开（充电管家核心功能）；容量策略后置（UI 设置入口接入前默认关）。
    // 阈值即 thermal_policy 核心默认：rise 35/39、fall 33/36、emergency 44、
    // min_hold 60s、max_age 15s——滞回与最短保持由 C 内核保证。
    return @{
        @"thermal": @{@"enabled": @1,
                      @"rise_light": @35, @"rise_moderate": @39,
                      @"fall_light": @33, @"fall_moderate": @36,
                      @"emergency": @44, @"min_hold_s": @60, @"max_age_s": @15},
        @"capacity": @{@"enabled": @0, @"max_percent": @80, @"resume_percent": @75,
                       @"max_age_s": @15},
    };
}

- (void)evaluateBattery:(NSDictionary *)bat_info {
    NSNumber *tempCenti = [bat_info[@"Temperature"] isKindOfClass:[NSNumber class]]
                              ? bat_info[@"Temperature"] : nil;
    if (tempCenti == nil) return;   // 无温度输入不决策

    if (self.advisory == nil) self.advisory = [CLOfflineAdvisory new];
    NSDictionary *envelope = [self.advisory observeBattery:bat_info
                                                  settings:[self governorSettings]
                                              monotonicNow:CLContinuousSeconds()
                                         monotonicSampleAt:nil
                                                 ownership:@"ours"];
    NSDictionary *thermal = [envelope[@"thermal"] isKindOfClass:[NSDictionary class]]
                                ? envelope[@"thermal"] : nil;
    if (thermal == nil) return;

    NSInteger level = [thermal[@"level"] respondsToSelector:@selector(integerValue)]
                          ? [thermal[@"level"] integerValue] : TP_OFF;
    NSInteger action = [thermal[@"action"] respondsToSelector:@selector(integerValue)]
                           ? [thermal[@"action"] integerValue] : TP_NONE;
    NSString *reason = [thermal[@"reason"] isKindOfClass:[NSString class]]
                           ? thermal[@"reason"] : @"?";

    // emergency：策略内核判 TP_MANUAL_STOP_REVIEW（temp >= emergency）→
    // heavy 档 + 布尔停充兜底（经 daemon 注入的 emergencyHandler）。
    BOOL emergency = (action == TP_MANUAL_STOP_REVIEW);
    [self handleEmergency:emergency];

    CLThermalLevel target = CLThermalLevelOff;
    switch (level) {
        case TP_LIGHT:    target = CLThermalLevelLight;    break;
        case TP_MODERATE: target = CLThermalLevelModerate; break;
        default:          target = CLThermalLevelOff;      break;
    }
    if (emergency) target = CLThermalLevelHeavy;

    [self applyLevel:target reason:reason];
}

- (void)handleEmergency:(BOOL)emergency {
    if (emergency == self.emergencyLatched) return;
    self.emergencyLatched = emergency;
    if (self.emergencyHandler) self.emergencyHandler(emergency);
    NSLog(@"[CLGovernor] emergency %@",
          emergency ? @"ENGAGED (charge inhibited)" : @"CLEARED (charge resumed)");
}

- (void)applyLevel:(CLThermalLevel)level reason:(NSString *)reason {
    if (level == self.currentLevel) return;
    self.currentLevel = level;
    if (self.applyToken >= 0) {
        notify_set_state(self.applyToken, (uint64_t)level);
    }
    NSLog(@"[CLGovernor] thermal level -> %lu (%@)",
          (unsigned long)level, reason);
}

@end
