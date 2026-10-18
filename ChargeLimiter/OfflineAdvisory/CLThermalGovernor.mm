// CLThermalGovernor — 充电管家温控决策引擎实现。
// 差异化：上游 ChargeLimiter 的 thermal sim 是手动固定档位；本引擎是实时温度
// 闭环自动档位（策略状态经 CLOfflineAdvisory 实例跨轮保持，滞回/min_hold 生效）。
#import "CLThermalGovernor.h"
#import "CLOfflineAdvisory.h"
#import "thermal_policy.h"
#import <notify.h>
#import <mach/mach_time.h>

// 设置读取（utils.mm 定义，daemon target 内）。此处只前置声明，避免把 utils.h /
// common.h 整包拉进决策引擎——头文件污染越小，接线越不容易撬动既有编译单元。
extern BOOL getLocalBool(NSString *key, BOOL defaultValue);
extern int getLocalInt(NSString *key, int defaultValue);

// 与 CLThermalSimTweak.m 同名通道（daemon 写、tweak 读后下发热模拟档位）。
static NSString *const CLGovernorApplyNotification = @"com.jy.charge.thermalapply";

@interface CLThermalGovernor ()
@property (nonatomic, readwrite) CLThermalLevel currentLevel;
@property (nonatomic) int applyToken;
@property (nonatomic) BOOL emergencyLatched;
@property (nonatomic) BOOL capacityLatched;    // 容量停充 latch（到 max_percent 停、resume 恢复）
@property (nonatomic) BOOL actuationStopped;   // 合并作动态（emergency）
@property (nonatomic) double lastTempC;            // 最近一次电池事件实测温度
@property (nonatomic) long long lastAmpMa;         // 最近一次实测电流（原始符号）
@property (nonatomic) BOOL lastCharging;
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
        _capacityLatched = NO;
        _actuationStopped = NO;
        // notify_register（mach 端口版）在 iOS SDK 头不可用；与 CLThermalSimTweak
        // 同款用 notify_register_dispatch。governor 只写档位不消费通知，block 为空。
        uint32_t status = notify_register_dispatch(
            [CLGovernorApplyNotification UTF8String], &_applyToken,
            dispatch_get_main_queue(), ^(int token) {});
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"[CLGovernor] notify_register_dispatch failed status=%u", status);
        }
    }
    return self;
}

static double CLContinuousSeconds(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * (double)timebase.numer / (double)timebase.denom / 1e9;
}

- (NSDictionary *)governorSettings {
    // 全部参数来自设置存储（App 经 set_conf 写入，daemon 每轮读取——改设置即刻生效，
    // 无需重启 daemon）。默认值即充电管家的产品默认：温控开、轻度 35/中度 39/
    // 回落 33/36/紧急 44/min_hold 60s；容量保护开、到 80% 停、75% 恢复。
    // 滞回与最短保持由 C 内核保证。
    return @{
        @"thermal": @{
            @"enabled": @(getLocalBool(@"jy_thermal_enabled", YES)),
            @"rise_light": @(getLocalInt(@"jy_rise_light", 35)),
            @"rise_moderate": @(getLocalInt(@"jy_rise_moderate", 39)),
            @"fall_light": @(getLocalInt(@"jy_fall_light", 33)),
            @"fall_moderate": @(getLocalInt(@"jy_fall_moderate", 36)),
            @"emergency": @(getLocalInt(@"jy_emergency", 44)),
            @"min_hold_s": @(getLocalInt(@"jy_min_hold", 60)),
            @"max_age_s": @15,
        },
        @"capacity": @{
            @"enabled": @(getLocalBool(@"jy_capacity_enabled", YES)),
            @"max_percent": @(getLocalInt(@"jy_max_percent", 80)),
            @"resume_percent": @(getLocalInt(@"jy_resume_percent", 75)),
            @"max_age_s": @15,
        },
    };
}

- (void)evaluateBattery:(NSDictionary *)bat_info {
    NSNumber *tempCenti = [bat_info[@"Temperature"] isKindOfClass:[NSNumber class]]
                              ? bat_info[@"Temperature"] : nil;
    if (tempCenti == nil) return;   // 无温度输入不决策

    // 实测快照：只记录，不参与决策。档位切换日志带这两个值，真机 log show 即可
    // 判断"降档是否真的伴随电流变化"——这是柔性调控唯一诚实的验收依据。
    _lastTempC = tempCenti.doubleValue / 100.0;
    id ampObj = bat_info[@"InstantAmperage"];
    _lastAmpMa = [ampObj respondsToSelector:@selector(longLongValue)] ? [ampObj longLongValue] : 0;
    _lastCharging = [bat_info[@"IsCharging"] boolValue];

    if (self.advisory == nil) self.advisory = [CLOfflineAdvisory new];
    NSDictionary *envelope = [self.advisory observeBattery:bat_info
                                                  settings:[self governorSettings]
                                              monotonicNow:CLContinuousSeconds()
                                         monotonicSampleAt:nil
                                                 ownership:@"ours"];
    NSDictionary *thermal = [envelope[@"thermal"] isKindOfClass:[NSDictionary class]]
                                ? envelope[@"thermal"] : nil;
    NSDictionary *capacity = [envelope[@"capacity"] isKindOfClass:[NSDictionary class]]
                                 ? envelope[@"capacity"] : nil;
    if (thermal == nil) return;

    // 容量到顶 latch：只做状态记账（UI/诊断展示"为什么停"），不作动。
    // 真正的停/恢复由上游 applyChargePolicy 的 charge_above/charge_below 执行。
    if (capacity != nil) {
        NSString *suggestion = [capacity[@"suggestion"] isKindOfClass:[NSString class]]
                                   ? capacity[@"suggestion"] : @"none";
        if ([suggestion isEqualToString:@"stop-review"]) {
            [self setCapacityLatched:YES];
        } else if ([suggestion isEqualToString:@"resume-review"]) {
            [self setCapacityLatched:NO];
        }
    }

    NSInteger level = [thermal[@"level"] respondsToSelector:@selector(integerValue)]
                          ? [thermal[@"level"] integerValue] : TP_OFF;
    NSInteger action = [thermal[@"action"] respondsToSelector:@selector(integerValue)]
                           ? [thermal[@"action"] integerValue] : TP_NONE;
    NSString *reason = [thermal[@"reason"] isKindOfClass:[NSString class]]
                           ? thermal[@"reason"] : @"?";

    // emergency：策略内核判 TP_MANUAL_STOP_REVIEW（temp >= emergency）→
    // heavy 档 + 布尔停充兜底（经 daemon 注入的 emergencyHandler）。
    BOOL emergency = (action == TP_MANUAL_STOP_REVIEW);
    [self setEmergencyLatched:emergency];

    CLThermalLevel target = CLThermalLevelOff;
    switch (level) {
        case TP_LIGHT:    target = CLThermalLevelLight;    break;
        case TP_MODERATE: target = CLThermalLevelModerate; break;
        default:          target = CLThermalLevelOff;      break;
    }
    if (emergency) target = CLThermalLevelHeavy;

    [self applyLevel:target reason:reason];
}

- (void)setEmergencyLatched:(BOOL)latched {
    if (latched == _emergencyLatched) return;
    _emergencyLatched = latched;
    [self updateActuation];
}

- (void)setCapacityLatched:(BOOL)latched {
    if (latched == _capacityLatched) return;
    _capacityLatched = latched;
    [self updateActuation];
}

// 合并作动决策：温度紧急（44℃+）成立即停充，清除即恢复。
// 容量停充不走这里——它由上游 applyChargePolicy 的 charge_above/charge_below
// 状态机执行（App 滑块直接写这两个键）。两套控制器写同一条停充命令会互相覆盖，
// 因此 governor 只保留一个作动出口：温控紧急兜底。
- (void)updateActuation {
    BOOL stop = _emergencyLatched;
    if (stop == _actuationStopped) return;
    _actuationStopped = stop;
    if (self.emergencyHandler) self.emergencyHandler(stop);
    NSLog(@"[CLGovernor] actuation %@ (emergency=%d capacity_latch=%d)",
          stop ? @"STOP" : @"RESUME", _emergencyLatched, _capacityLatched);
}

- (void)applyLevel:(CLThermalLevel)level reason:(NSString *)reason {
    if (level == self.currentLevel) return;
    self.currentLevel = level;
    if (self.applyToken >= 0) {
        notify_set_state(self.applyToken, (uint64_t)level);
    }
    NSLog(@"[CLGovernor] thermal level -> %lu (%@) temp=%.1fC amp=%lldmA charging=%d",
          (unsigned long)level, reason, _lastTempC, _lastAmpMa, (int)_lastCharging);
}

- (NSDictionary *)stateSnapshot {
    return @{
        @"level": @((unsigned long long)self.currentLevel),
        @"stopped": @(_actuationStopped),
        @"emergency": @(_emergencyLatched),
        @"capacity": @(_capacityLatched),
        @"temp_c": @(_lastTempC),
        @"amp_ma": @(_lastAmpMa),
        @"charging": @(_lastCharging),
    };
}

@end
