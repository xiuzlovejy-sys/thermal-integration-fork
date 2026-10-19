// CLThermalGovernor — 充电管家温控决策引擎实现。
// 差异化：上游 ChargeLimiter 的 thermal sim 是手动固定档位；本引擎是实时温度
// 闭环自动档位（策略状态经 CLOfflineAdvisory 实例跨轮保持，滞回/min_hold 生效）。
#import "CLThermalGovernor.h"
#import "CLOfflineAdvisory.h"
#import "thermal_policy.h"
#import <notify.h>
#import <mach/mach_time.h>
#include <math.h>

// 设置读取（utils.mm 定义，daemon target 内）。此处只前置声明，避免把 utils.h /
// common.h 整包拉进决策引擎——头文件污染越小，接线越不容易撬动既有编译单元。
extern BOOL getLocalBool(NSString *key, BOOL defaultValue);
extern int getLocalInt(NSString *key, int defaultValue);
extern NSString *getLogPath(void);

// 日志体积上限：32KB，超出后只保留最近 16KB（自覆盖，不会无限增长）。
// 按每行约 100 字节算，16KB ≈ 160 行 ≈ 近 2 小时的 40 秒心跳，排障够用。
static const unsigned long long kJYLogMaxBytes = 32 * 1024;
static const unsigned long long kJYLogKeepBytes = 16 * 1024;

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
@property (nonatomic) BOOL adapterConnected;        // 最近一次事件是否已接电源（不受停充影响）
@property (nonatomic) float smoothDuty;             // 平滑后占空比（P1 时间低通）
@property (nonatomic) double lastDutyTs;            // 上次平滑时间
@property (nonatomic) BOOL hasDutyTs;
@property (nonatomic) double prevTempC;             // 上一轮温度（dT/dt 前馈）
@property (nonatomic) double lastTempTs;            // 上一轮温度时间
@property (nonatomic) BOOL hasTempTs;
@property (nonatomic) double tempTrendCPerS;        // dT/dt（℃/s）
@property (nonatomic) NSInteger lastSoc;            // 最近一次 SOC（高 SOC 收紧）
@property (nonatomic) CLOfflineAdvisory *advisory;   // 跨轮复用：tp_policy 状态在实例内
// 日志节流：档位/动作变化必记，其余每 30 秒一条心跳。
@property (nonatomic) NSInteger loggedLevel;
@property (nonatomic) NSInteger loggedAction;
@property (nonatomic) NSTimeInterval lastLogTs;
@property (nonatomic) BOOL hasLoggedOnce;
- (void)logEvaluation:(NSInteger)level action:(NSInteger)action reason:(NSString *)reason;
@end

@implementation CLThermalGovernor

+ (NSString *)logPath {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = [getLogPath() stringByDeletingLastPathComponent];
        if (dir.length == 0) dir = @"/var/mobile/Library/Logs";
        path = [dir stringByAppendingPathComponent:@"jys-governor.log"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });
    return path;
}

+ (void)appendLogLine:(NSString *)line {
    NSString *path = [self logPath];
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [data writeToFile:path atomically:YES];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } @catch (NSException *e) {
        [fh closeFile];
    }
    // 体积上限：超过 32KB 保留最近 16KB（自覆盖，永不无限增长）。
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if ([attrs fileSize] > kJYLogMaxBytes) {
        NSData *all = [NSData dataWithContentsOfFile:path];
        if (all.length > kJYLogKeepBytes) {
            NSData *tail = [all subdataWithRange:NSMakeRange(all.length - kJYLogKeepBytes,
                                                             kJYLogKeepBytes)];
            [tail writeToFile:path atomically:YES];
        }
    }
}

+ (NSString *)logTailWithMaxLines:(NSUInteger)lines {
    NSString *text = [NSString stringWithContentsOfFile:[self logPath]
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (text.length == 0) return @"";
    NSArray<NSString *> *all = [text componentsSeparatedByString:@"\n"];
    NSUInteger n = MIN(lines, all.count);
    return [[all subarrayWithRange:NSMakeRange(all.count - n, n)] componentsJoinedByString:@"\n"];
}

+ (void)clearLog {
    [[NSFileManager defaultManager] removeItemAtPath:[self logPath] error:NULL];
}

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
    // 接电源判定：PWM 阶段里 IsCharging 会被软停置 0，只能用 External* 判"插着电源"，
    // 否则 PWM 停充后会误判成"拔电"而立刻恢复，占空比失效。
    self.adapterConnected = [bat_info[@"ExternalConnected"] boolValue] ||
                            [bat_info[@"ExternalChargeCapable"] boolValue];
    // 温度趋势（dT/dt，℃/s）—— P1 前馈控制：快速升温时提前降占空比，消除超调。
    double trendNowTs = CLContinuousSeconds();
    if (self.hasTempTs) {
        double dt = trendNowTs - self.lastTempTs;
        if (dt > 0.5) self.tempTrendCPerS = (_lastTempC - self.prevTempC) / dt;
    }
    self.prevTempC = _lastTempC;
    self.lastTempTs = trendNowTs;
    self.hasTempTs = YES;
    // SOC 快照 —— 高 SOC 收紧策略。
    self.lastSoc = [bat_info[@"CurrentCapacity"] integerValue];

    if (self.advisory == nil) self.advisory = [CLOfflineAdvisory new];
    // 采样戳必须给：tp_step 的硬校验要求 has_age && age_s <= max_age_s，
    // 传 nil 会让每一轮都被判成"样本过期"，直接 release_level() → 档位永远是 0。
    // 本轮 bat_info 就是刚刚从 IOKit 读到的，采样时刻 = 当前单调时钟。
    double now = CLContinuousSeconds();
    NSDictionary *envelope = [self.advisory observeBattery:bat_info
                                                  settings:[self governorSettings]
                                              monotonicNow:now
                                         monotonicSampleAt:@(now)
                                                 ownership:@"ours"];
    NSDictionary *thermal = [envelope[@"thermal"] isKindOfClass:[NSDictionary class]]
                                ? envelope[@"thermal"] : nil;
    if (thermal == nil) return;

    // 容量到顶 latch：只做状态记账（UI/诊断展示"为什么停"），不作动。
    // 真正的停/恢复由上游 applyChargePolicy 的 charge_above/charge_below 执行。
    //
    // 注意：不能用 native_capacity 的 suggestion 驱动这个 latch。它只在
    // thermal_safe 为真时才发 "resume-review"，而适配层恒置 thermal_safe=0
    // （上游"绝不推断可恢复"原则），于是 resume-review 永不可达 → latch 只能置位
    // 不能清除 → pwmDuty 永久返回 1.0，软 PWM 静默失效（真机 2026-10-19 现场）。
    // 改用实时 SOC 直接判定，阈值与上游 charge_above/charge_below 同源。
    NSInteger soc = [bat_info[@"CurrentCapacity"] integerValue];
    if (bat_info[@"CurrentCapacity"] != nil) {
        NSInteger maxPct = getLocalInt(@"jy_max_percent", 80);
        if (soc >= maxPct) {
            [self setCapacityLatched:YES];
        } else {
            // 低于上限（含"用户抬高上限"的情况）→ 立即解除，PWM 恢复工作。
            // 不再用 resume 阈值滞回：那会让 latch 在 76~max 的保持带里卡住。
            [self setCapacityLatched:NO];
        }
    }

    NSInteger level = [thermal[@"level"] respondsToSelector:@selector(integerValue)]
                          ? [thermal[@"level"] integerValue] : TP_OFF;
    NSInteger action = [thermal[@"action"] respondsToSelector:@selector(integerValue)]
                           ? [thermal[@"action"] integerValue] : TP_NONE;
    NSString *reason = [thermal[@"reason"] isKindOfClass:[NSString class]]
                           ? thermal[@"reason"] : @"?";

    [self logEvaluation:level action:action reason:reason];

    // emergency：策略内核判 TP_MANUAL_STOP_REVIEW（temp >= emergency）→
    // heavy 档 + 布尔停充兜底（经 daemon 注入的 emergencyHandler）。
    BOOL emergency = (action == TP_MANUAL_STOP_REVIEW);
    // 回落滞回：一旦锁存，只有温度降到 emergency - jy_emergency_fall（默认 3℃）
    // 以下才解除。否则 39↔37.9 的窄带会让充电每 45 秒停/充震荡一次
    // （真机 01:08 实测），强电流反复冲击电池。
    if (self.emergencyLatched && !emergency) {
        double emergencyC = getLocalInt(@"jy_emergency", 44);
        double fallC = getLocalInt(@"jy_emergency_fall", 3);
        if (self.lastTempC >= (emergencyC - fallC)) {
            emergency = YES;   // 仍维持停充锁存
        }
    }
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

static NSString *CLTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

- (void)logEvaluation:(NSInteger)level action:(NSInteger)action reason:(NSString *)reason {
    // 手动开关（App 设置项）。排障时才需要，平时可以彻底关掉。
    if (!getLocalBool(@"jy_log_enabled", YES)) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL changed = !self.hasLoggedOnce
                   || level != self.loggedLevel
                   || action != self.loggedAction;
    // 只有"真的在做事"才写心跳：充电中，或处于非零档位（且未因容量到顶停充）。
    // 拔线且档位归零后就不再产生新行；容量到顶停充后也停写——充电没进行、
    // 温度不会因充电上升，每 30 秒重复同一行没有排障价值，只会白占空间。
    BOOL meaningful = self.lastCharging || (level != 0 && !_capacityLatched);
    BOOL heartbeat = meaningful && (now - self.lastLogTs) >= 30.0;
    if (!changed && !heartbeat) return;
    self.hasLoggedOnce = YES;
    self.loggedLevel = level;
    self.loggedAction = action;
    self.lastLogTs = now;

    NSString *line = [NSString stringWithFormat:
        @"%@ temp=%.1fC lvl=%ld act=%ld reason=%@ amp=%lldmA chg=%d en=%d rise=%d/%d/%d",
        CLTimestamp(), self.lastTempC, (long)level, (long)action, reason,
        self.lastAmpMa, (int)self.lastCharging,
        (int)getLocalBool(@"jy_thermal_enabled", YES),
        getLocalInt(@"jy_rise_light", 35),
        getLocalInt(@"jy_rise_moderate", 39),
        getLocalInt(@"jy_emergency", 44)];
    [CLThermalGovernor appendLogLine:line];
}

- (void)applyLevel:(CLThermalLevel)level reason:(NSString *)reason {
    if (level == self.currentLevel) return;
    self.currentLevel = level;
    if (self.applyToken >= 0) {
        // 写通道并回读：如果 write_status 非 0 或 readback 与目标不一致，
        // 说明通道本身没通（例如 daemon 没有该 notify 域权限），
        // 与"写成功但系统不响应"是两种完全不同的故障。
        uint32_t st = notify_set_state(self.applyToken, (uint64_t)level);
        uint64_t rb = 0;
        notify_get_state(self.applyToken, &rb);
        [CLThermalGovernor appendLogLine:[NSString stringWithFormat:
            @"%@ [channel] target=%lu write=%u readback=%llu",
            CLTimestamp(), (unsigned long)level, st, (unsigned long long)rb]];
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
        @"adapter": @(_adapterConnected),
        @"pwm_duty": @([self pwmDuty]),
    };
}

// 连续占空比目标：等效温度 → 占空比，档位内线性插值、边界连续（无跳变）。
// 等效温度 = 实际温度 + dT/dt 前馈 + 高 SOC 收紧（见调用处）。
//   ≤ rise_light:                    1.0（满速）
//   rise_light → rise_moderate:      1.0 → moderate_duty（轻度过渡带）
//   rise_moderate → emergency:       moderate_duty → duty_floor（中度带）
//   ≥ emergency:                     0（由紧急 latch 处理，PWM 不参与）
static float CLDutyTarget(double effT) {
    double riseLight = getLocalInt(@"jy_rise_light", 30);
    double riseMod   = getLocalInt(@"jy_rise_moderate", 34);
    double emerg     = getLocalInt(@"jy_emergency", 39);
    double dutyMod   = getLocalInt(@"jy_pwm_moderate_duty", 55) / 100.0;
    double dutyFloor = getLocalInt(@"jy_pwm_duty_floor", 20) / 100.0;
    if (effT >= emerg) return 0.0f;
    if (effT <= riseLight) return 1.0f;
    if (effT <= riseMod) {
        double span = (riseMod - riseLight) > 0.1 ? (riseMod - riseLight) : 0.1;
        double r = (effT - riseLight) / span;
        return (float)(1.0 - r * (1.0 - dutyMod));
    }
    double span = (emerg - riseMod) > 0.1 ? (emerg - riseMod) : 0.1;
    double r = (effT - riseMod) / span;
    return (float)(dutyMod - r * (dutyMod - dutyFloor));
}

- (BOOL)pwmShouldYield {
    @synchronized(self) {
        if (!getLocalBool(@"jy_thermal_enabled", YES)) return YES;   // 温控总开关关闭
        if (!_adapterConnected) return YES;                          // 未接电源
        if (_capacityLatched) return YES;                            // 容量到顶（交给执行层）
        if (_emergencyLatched || _actuationStopped) return YES;      // 紧急停充（交给紧急通道）
        return NO;
    }
}

- (float)pwmDuty {
    @synchronized(self) {
        // 温控总开关关闭：完全不参与 PWM，立即回满（否则"关了温控还在限流"）。
        if (!getLocalBool(@"jy_thermal_enabled", YES)) {
            _smoothDuty = 1.0f; _hasDutyTs = NO;
            return 1.0f;
        }
        // 紧急/重度：完全停充（emergencyHandler 全权接管，PWM 不干预）——立即归零，不渐变。
        if (_emergencyLatched || _actuationStopped) {
            _smoothDuty = 0.0f; _hasDutyTs = NO;
            return 0.0f;
        }
        // 没插电源 / 容量到顶停充：不 PWM（交给策略机）——立即回满，不渐变。
        if (!_adapterConnected || _capacityLatched) {
            _smoothDuty = 1.0f; _hasDutyTs = NO;
            return 1.0f;
        }
    // 目标占空比随"等效温度"连续变化（无档位跳变）。
    // 等效温度 = 实际温度 + 前馈 + 高 SOC 收紧，见下。
    double effT = _lastTempC;
    // 前馈：快速升温时提前介入（dT/dt × 前瞻时间，上限 jy_dt_max_advance_c）。
    if (self.tempTrendCPerS > 0) {
        double adv = self.tempTrendCPerS * getLocalInt(@"jy_dt_lookahead_s", 30);
        double maxAdv = getLocalInt(@"jy_dt_max_advance_c", 2);
        if (adv > maxAdv) adv = maxAdv;
        effT += adv;
    }
    // 高 SOC 收紧：> jy_high_soc 时等效温度 +2℃（阈值等效下调 2℃）。
    if (self.lastSoc > getLocalInt(@"jy_high_soc", 88)) effT += 2.0;
    // 前馈不越界到紧急区（紧急归 emergencyHandler，PWM 只负责到 duty_floor）。
    double emergBound = getLocalInt(@"jy_emergency", 39);
    if (effT > emergBound - 0.5) effT = emergBound - 0.5;

    float target = CLDutyTarget(effT);
    // 低温限流：< jy_cold_throttle_c 时占空比上限 50%（低温大倍率充电有锂镀层风险）。
    if (_lastTempC < getLocalInt(@"jy_cold_throttle_c", 5) && target > 0.5f) target = 0.5f;
    // 时间低通：占空比向目标平滑滑移（时间常数 jy_pwm_smooth_tau，默认 90s），
    // 既"随温度连续"又"随时间柔和"，杜绝单样本温度抖动导致占空比骤变。
        double now = CLContinuousSeconds();
        if (!_hasDutyTs) {
            _smoothDuty = target;
            _lastDutyTs = now;
            _hasDutyTs = YES;
            return _smoothDuty;
        }
        double dt = now - _lastDutyTs;
        _lastDutyTs = now;
        if (dt <= 0) return _smoothDuty;
        double tau = getLocalInt(@"jy_pwm_smooth_tau", 90);
        float alpha = 1.0f - (float)exp(-dt / tau);
        _smoothDuty += (target - _smoothDuty) * alpha;
        if (_smoothDuty < 0.0f) _smoothDuty = 0.0f;
        if (_smoothDuty > 1.0f) _smoothDuty = 1.0f;
        return _smoothDuty;
    }
}

@end
