# 软 PWM 柔性充电 vs ChargeLimiter 温控开关 —— 对比分析

> 文档日期：2026-10-19 · 项目阶段：柔性充电真机验证通过（1.0.22）
> 设备环境：iPhone 13 Pro (A15) · iOS 16.6 · Relaxin (RootHide) 越狱

## 一、结论摘要

| 维度 | ChargeLimiter 滞回开关 | 本项目软 PWM | 胜者 |
|---|---|---|---|
| 温度峰值控制 | 反复触顶 T_max | 稳定在更低均衡点，不触顶 | **软 PWM** |
| 温度稳定性 | 在 T_max⇄T_low 间大摆幅震荡 | 小幅波动 | **软 PWM** |
| 电池损伤 | 高温暴露多、满电流阶段发热大 | 峰值温度低、平均电流低 | **软 PWM** |
| 温控生效时的充电速度 | 有大量全停「死时间」 | 持续以降低功率充，吞吐更高 | **软 PWM** |
| 低温段充电速度 | 满速 | 满速 | 平手 |
| 实现复杂度 | 极简、无时序 | 需定时器 + 相位逻辑 | 滞回式 |

**结论**：软 PWM 在「立项初衷」所关注的维度（温度控制、电池健康、同温限下吞吐）全面占优；滞回式仅在实现简单性上占优。本项目采用「**分级软 PWM 为主 + 39℃ 紧急全停兜底**」，兼顾两者优点。

---

## 二、两种机制的原理

### 1. ChargeLimiter 式：滞回开关（bang-bang 恒温器）

```
温度 ≥ T_max  → 立即停充（setBatteryStatus(NO)）
温度 ≤ T_low  → 恢复满速充电
T_low < T < T_max 区间 → 不干预（保持满速）
```

- 只有一个开关：停 / 充，中间没有档位。
- 依赖滞回带（T_max − T_low）防止在阈值点高频抖动。
- 充电发热 → 升温 → 触 T_max → 停充 → 降温 → 触 T_low → 恢复 → 再发热……**天然振荡**。

### 2. 本项目：分级软 PWM（比例式功率调节）

```
待机/标称   → 100% 占空（满速）
轻度(≥30℃) → 85% 占空（jy_pwm_light_duty）
中度(≥34℃) → 55% 占空（jy_pwm_moderate_duty）
紧急(≥39℃) → 0% 占空（完全停充，emergencyHandler）
```

- 温度越高，平均充电功率越低，靠「软停 + 恢复」的占空比实现。
- 软停用 `PredictiveChargingInhibit`（iOS 原生「优化电池充电」同款），**不拔电、不重握手、电流平滑 ramp**。
- 达到降温目的的温度点是一个**更低、更稳的均衡点**，而非反复触碰上限。

---

## 三、为什么软 PWM 在关键维度更优

### 温度控制

- 滞回式：温度在 T_max 与 T_low 之间**反复震荡，每次都冲到 T_max**。
- 软 PWM：靠降低平均功率，让电池稳定在比 T_max 更低的均衡温度（如目标 39℃，实际稳定在 35~36℃）。

> 同样的「不超过 39℃」约束下，软 PWM 的**峰值温度更低、曲线更平**。

### 对电池的损害

电池老化主要驱动因素（排序）：

1. **高温** —— 近似 Arrhenius 定律，每升高 10℃ 老化速度约翻倍；
2. 高充电电流（大倍率）；
3. 长时间停留在满电。

- 滞回式：反复触顶 + 满电流阶段发热最大 → 高温暴露更多。
- 软 PWM：峰值更低 + 平均电流更低 → 发热更少 → 老化更慢。

> 两者都用软停（无机械/握手冲击），区别仅在「启停频率 vs 热摆幅」。就电池而言，**降低峰值温度**的软 PWM 更有利。

### 充电效率 / 速度

- 同温限下：滞回式「满速一会 → 全停冷却」有大量死时间；软 PWM 持续以降低功率充电 → **软 PWM 吞吐更高**。
- 相比不设温控的满速：软 PWM 的中度档就是主动只给 ~55%，充电时间约 1.8× —— 这是「柔性充电用速度换低温」的本意，而非缺陷。

### 复杂度

- 滞回式：无需定时器，恢复/停充各一条分支，最稳健。
- 软 PWM：需一个 2s 定时器 + 按时间切相位（精确到秒），已实现并真机验证。

---

## 四、关键事实依据（本次真机调研）

以下均由真机 IOKit dump / 日志 / 实测得出，写入本文档作为决策依据：

1. **iOS 16.6 无连续控流的注入无关入口**：`AppleSmartBattery` / `AppleSMCCharger*` 全量属性 dump 证实，充电电流由 USB-PD + 充电器 IC（tristar/CCG2）固件协商，无任何 `setProperties` 可写的电流/功率键（`ChargingOverride`/`InflowOverride`/`ChargerConfiguration`/`BestAdapterIndex` 均只读，写回返回 `kIOReturnBadArgument`/`NotPermitted`）。

2. **连续控流唯一路径是热模拟**（`CommonProduct.putDeviceInThermalSimulationMode:` / `simulateLightThermalPressure`），需要注入 `thermalmonitord`，而 RootHide 对系统守护进程不注入 —— 故该路在本设备不可行。

3. **软停通道已验证**：`PredictiveChargingInhibit` 软停真机平滑（电流 1820 → -2 → 1689 mA，无 USB-PD 重协商，`ExternalConnected` 全程保持 1）。

4. **软 PWM 真机验证**：中度（35℃）下 `duty=55%` 周期性 STOP/CHARGE，电流 1779mA ⇄ -1mA，电池温度稳定在 34~35℃，不冲击 39℃ 紧急阈值。

5. **iOS 自身也用同款机制**：`ChargerData.TimeChargingThermallyLimited` 字段，说明系统在发热时**本来就对充电做 PWM 限流**；「优化电池充电」在 80% 处暂停/恢复也走 `PredictiveChargingInhibit`。本项目复用系统原生通路，非异常应力。

---

## 五、本项目最终方案

```
分级软 PWM（注入无关，温度越高占空比越低）
        ⊕
39℃ 紧急全停（emergencyHandler，最后一道硬保护）
        ⊕
容量上限停充（charge_above，与 PWM 互斥、不打架）
```

- 阈值可调：`jy_rise_light` / `jy_rise_moderate` / `jy_emergency`；
- 占空比可调：`jy_pwm_light_duty`（默认 85）/ `jy_pwm_moderate_duty`（默认 55）；
- 周期可调：`jy_pwm_period_s`（默认 20s，每 2s 重估相位）。

---

## 六、后续可选方向

- 换 Dopamine（rootless，可注入守护进程）时，可切换回**真·连续热模拟**（`putDeviceInThermalSimulationMode:`）路线，代码已就绪。
- SMC 直写（`AppleSMCClient`）为最后未探面，但 Mac 上 SMC 亦仅 `CH0I/CH0J` 布尔抑制键、无充电电流键，预期概率极低。