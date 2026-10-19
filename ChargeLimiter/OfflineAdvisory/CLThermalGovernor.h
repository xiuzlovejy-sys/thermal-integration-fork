#ifndef CL_THERMAL_GOVERNOR_H
#define CL_THERMAL_GOVERNOR_H
/* 充电管家温控决策引擎（2026-10-18 用户授权接线）。
 * 温度闭环 -> Powercuff 式热模拟档位（柔性调控）：实时温度经 thermal_policy
 * 内核（分级阈值 + 滞回 + min_hold）产出策略档位，映射为热模拟档位后经
 * 内核 notify 通道 com.jy.charge.thermalapply 下发——由注入
 * thermalmonitord 的 CLThermalSimTweak 执行 putDeviceInThermalSimulationMode:，
 * PMIC 按模拟温度平滑降功率（非通断、无握手冲击）。
 * 布尔停充仅在 emergency 兜底，且只经由 emergencyHandler 受控通道。 */
#import <Foundation/Foundation.h>

// 档位编码与 CLThermalSimTweak.m 的 Powercuff 编码严格一致:
// 0=off 1=nominal 2=light 3=moderate 4=heavy
typedef NS_ENUM(uint64_t, CLThermalLevel) {
    CLThermalLevelOff = 0,
    CLThermalLevelNominal = 1,
    CLThermalLevelLight = 2,
    CLThermalLevelModerate = 3,
    CLThermalLevelHeavy = 4,
};

@interface CLThermalGovernor : NSObject

+ (instancetype)sharedGovernor;

// emergency 兜底回调（daemon 注入）：stop=YES 停充 / NO 恢复充电。
// 决策引擎自身绝不作动布尔停充——只经由此受控通道。
@property (nonatomic, copy) void (^emergencyHandler)(BOOL stop);

// 当前生效档位（供 UI/诊断查询）。
@property (nonatomic, readonly) CLThermalLevel currentLevel;

// 每轮电池事件调用（串行事件流）。bat_info: getBatInfo/getBatInfoWithServ 快照
// （Temperature 厘摄氏度、InstantAmperage、IsCharging、ExternalConnected）。
- (void)evaluateBattery:(NSDictionary *)bat_info;

// 软 PWM 占空比（RootHide 下注入无关的"柔性"实现）：0.0=全停(紧急/heavy)，
// 0~1=温度分级平均充电占比（light/moderate 读 jy_pwm_*_duty 设置）。
// 仅在"已接电源 + 未到容量停充"时参与 PWM；否则返回 1.0（不干预）。
- (float)pwmDuty;

// 只读状态快照（get_conf 上报给 App）：level / stopped / emergency / capacity。
// temp_c / amp_ma 为最近一次电池事件实测值——App 与日志据此判断"档位是否真的
// 带来了电流变化"（柔性调控的唯一可观测证据，控制器本身不臆造效果）。
- (NSDictionary *)stateSnapshot;

// 运行日志（真机排障）：落在 daemon 日志同目录的 jys-governor.log。
// 上限 32KB，超出保留最近 16KB（自覆盖）；App 可读末尾若干行并清空。
+ (NSString *)logPath;
+ (NSString *)logTailWithMaxLines:(NSUInteger)lines;
+ (void)clearLog;
+ (void)appendLogLine:(NSString *)line;   // daemon 侧（如软 PWM tick）也写同一份日志

@end

#endif
