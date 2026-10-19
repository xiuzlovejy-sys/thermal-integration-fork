# Jy's charge 核心原理、实现机制与温控方案对比

> 文档版本：2026-10-19 · 对应构建 1.0.24  
> 设备：iPhone 13 Pro (A15) · iOS 16.6 · Relaxin (RootHide) 越狱



---

## 0. 先定义：什么是「占空比」

占空比（duty cycle）＝ **在一个固定周期 T 内，"导通（充电）时间"所占的比例**。

```
        |<--------------- T = 20s --------------->|
充电    ███████████                             ███████████
停止              ░░░░░░░░░
        Ton≈11s          Toff≈9s
        duty = Ton / T = 11 / 20 ≈ 55%
```

- 平均功率 = 满功率 × duty
- 平均充电电流 ≈ 充电相电流 × duty
- duty 越低，平均功率越低、发热越少、充得越慢

> 注意：它不是"降低瞬时电流"，而是**用时间平均得到更低的等效功率**。iOS 不暴露"设定电流=mA"的接口（下文有证据），这是数字开关系统实现"等效降流"的标准做法——和开关电源、电机 PWM 调速同一原理。

---

## 1. 系统架构

```
┌───────────────────────────────────────────────┐
│ App（Jy's charge 界面，沙盒）                   │
│  CLButlerViewController  ←→ CLAPIClient        │
└───────────────────┬───────────────────────────┘
                    │ localhost HTTP (127.0.0.1:10973)
┌───────────────────▼───────────────────────────┐
│ Daemon（root，launchd 常驻）                    │
│  daemon.mm                                     │
│   ├─ 电池事件（IOKit 通知）+ 15s 心跳           │
│   ├─ getBatInfo() 快照（Temperature/Amps/SOC）  │
│   ├─ applyChargePolicy()  上游策略机（执行）     │
│   ├─ CLThermalPwmTick()   软 PWM 相位驱动       │
│   └─ jy_* API（日志/探测/配置）                 │
│                                                │
│  CLOfflineAdvisory（C 策略内核，纯决策）         │
│   ├─ native_thermal.c  温度分级 + 滞回 + min_hold│
│   └─ native_capacity.c 容量滞回（80/75）         │
│                                                │
│  CLThermalGovernor（温控决策引擎）               │
│   ├─ 策略档位 → CLThermalLevel                  │
│   ├─ emergency latch（39℃ 停充）               │
│   └─ pwmDuty（软 PWM 占空比）                   │
└───────────────────┬───────────────────────────┘
                    │ IOKit
┌───────────────────▼───────────────────────────┐
│ AppleSmartBattery                               │
│  PredictiveChargingInhibit（软停）              │
│  ExternalConnected（输入通断，备选）            │
└───────────────────────────────────────────────┘

（备选、RootHide 下不可用）CLThermalSimTweak → thermalmonitord 热模拟
```

---

## 2. 数据流与决策链

1. **采样**
   - IOKit 电池属性变化 → `onBatteryEvent`
   - 每 15s 心跳 → `refreshBatteryStateAndApplyPolicy`（防"稳态无事件导致档位冻住"）
   - `getBatInfo` 取精简快照（温度、电流、SOC、插电状态）
2. **策略内核**
   - `native_thermal`：按 `rise_light/rise_moderate/emergency` 分级，带**滞回**与 `min_hold`（默认 60s），输出 `level / action / reason`
   - `native_capacity`：容量滞回（≥80% 停、≤75% 恢复），只做建议、不作动
3. **决策引擎（Governor）**
   - 策略档位 → `CLThermalLevel`（Off/Light/Moderate/Heavy）
   - `action == TP_MANUAL_STOP_REVIEW` → emergency latch（39℃ 停充）
   - `pwmDuty` 计算当前占空比
4. **执行**
   - `applyChargePolicy`：上游策略机，负责容量停充/恢复（最高优先级先看 `g_jyThermalEmergencyStop`）
   - `CLThermalPwmTick`（每 2s）：按时间切片驱动软停/恢复
   - 全部经 `setChargeStatus()`（写 `PredictiveChargingInhibit`）

---

## 3. 分级阈值与滞回

| 参数                     | 默认  | 说明                   |
| ---------------------- | --- | -------------------- |
| `jy_rise_light`        | 30℃ | 轻度档起点 → duty 85%     |
| `jy_rise_moderate`     | 34℃ | 中度档起点 → duty 55%     |
| `jy_emergency`         | 39℃ | 紧急停充                 |
| `jy_emergency_fall`    | 3℃  | 紧急解除回落（39−3=36℃ 才恢复） |
| `jy_min_hold`          | 60s | 档位最短保持，防抖动           |
| `jy_pwm_light_duty`    | 85% | 轻度档占空比               |
| `jy_pwm_moderate_duty` | 55% | 中度档占空比               |
| `jy_pwm_period_s`      | 20s | PWM 周期               |

**两条独立的滞回**：

- 温度分级：C 内核的 fall 阈值（升 30/34，降 33/36 一类），防在阈值点抖动
- 紧急停充：governor 层 latch，必须降到 39−3=36℃ 才解除，避免 39↔38 的窄带震荡

---

## 4. 三个作动通道

| 通道        | 触发条件       | 实现                                                 | 依赖注入？                  |
| --------- | ---------- | -------------------------------------------------- | ---------------------- |
| **容量停充**  | SOC ≥ 最大充电 | `PredictiveChargingInhibit=YES`（上游 `charge_above`） | ❌ 不依赖                  |
| **紧急停充**  | 温度 ≥ 39℃   | `setChargeStatus(NO)` + 高优先级标志                     | ❌ 不依赖                  |
| **软 PWM** | 轻度/中度档     | 每 2s 切相位，软停 / 恢复                                   | ❌ 不依赖                  |
| 热模拟（备选）   | —          | `putDeviceInThermalSimulationMode:`                | ✅ 需要注入 thermalmonitord |

**为什么只剩前三个**：见第 7 节证据链。

---

## 5. 关键实现细节（真实踩坑记录）

1. **主开关 `g_enable`**  
   上游所有策略入口都以主开关为前提；主开关关闭时 governor 与 PWM 都不运行。
2. **`applyChargePolicy` 的优先级**  
   `g_jyThermalEmergencyStop` 是最优先分支，压住后续所有"恢复充电"分支，防止状态机每轮互相覆盖。
3. **紧急停充 latch + 回落滞回**  
   39℃ 停充后，必须降到 36℃ 才解除；否则真机出现 39↔37.9 每 45 秒一次的强电流震荡。
4. **容量 latch 的隐蔽 bug（1.0.23 修复）**  
   `native_capacity` 只在 `thermal_safe` 为真时才发 `resume-review`，而适配层恒置 `thermal_safe=0`（上游"绝不推断可恢复"原则）→ `resume-review` 永不可达 → governor 的 `_capacityLatched` 只能置位、不能清除 → `pwmDuty` 永久返回 1.0 → **软 PWM 静默失效**。  
   修复：改用实时 SOC 直接推导 latch。
5. **`pwmDuty` 的三个让位条件**
   - 紧急/重度 → 0（交给 emergencyHandler，PWM 不插手）
   - 未接电源 / 容量到顶 → 1.0（不干预，避免与容量停充打架）
   - 其余 → 按档位返回 0.85 / 0.55 / 1.0
6. **PWM 时间切片**  
   早期按 5 秒 tick 量化，占空比粒度粗、电流波动大；现改为**按秒切相位**（周期 20s、每 2s 重估），电流在窄区间小幅波动，更接近连续调流。
7. **自诊断**  
   `[pwm] duty=..% -> STOP/CHARGE` 记录每次切换；`[pwm] idle 100% lvl/ad/cap/em` 每 60s 记录"为何没限流"，避免再次静默失效。

---

## 6. ChargeLimiter 式温控机制

**本质：带滞回的 bang-bang 恒温器（开关控制）**

```
温度 ≥ T_max → 立即停充
温度 ≤ T_low → 恢复满速充电
T_low ~ T_max 之间 → 不干预（满速）
```

- 只有"停 / 满速"两个状态，没有中间档
- 靠滞回带（T_max − T_low）避免在阈值点高频抖动
- 充电发热 → 升温 → 触顶 → 停充 → 降温 → 触底 → 恢复 → 再升温……**天然振荡**

它可用的作动方式：

1. `PredictiveChargingInhibit`（软停，推荐）
2. `ExternalConnected=NO`（禁流，更"硬"，会断输入）
3. 热模拟（需注入 thermalmonitord，部分版本可用）
4. 部分版本还有 "Limit Inflow" —— 本质仍是热模拟档位

---

## 7. 全面对比

| 维度          | ChargeLimiter 滞回开关 | Jy's charge 分级软 PWM   | 孰优        |
| ----------- | ------------------ | --------------------- | --------- |
| 温度峰值        | 反复冲击 T_max         | 稳定在更低均衡点，不触顶          | **软 PWM** |
| 温度稳定性       | 大摆幅震荡（36↔39.6℃）    | 小幅波动（34.3↔35.8℃）      | **软 PWM** |
| 电池损伤        | 高温暴露多、满流阶段发热大      | 峰值低、平均电流低             | **软 PWM** |
| 同温限下充电速度    | 有大量全停死时间           | 持续以降低功率充，吞吐更高         | **软 PWM** |
| 低温段充电速度     | 满速                 | 满速                    | 平手        |
| 电气效率        | 满流 I²R 损耗略高        | 平均电流低，损耗略低            | 软 PWM（微弱） |
| 温度控制精度      | 只有上限，无中间调节         | 分级可调（30/34/39 + 占空比）  | **软 PWM** |
| 实现复杂度       | 极简，无时序             | 需定时器 + 相位逻辑           | 滞回式       |
| 失效模式        | 简单，难失效             | 依赖 latch/使能状态，曾出现静默失效 | 滞回式       |
| RootHide 兼容 | 软停部分可用；热模拟不可用      | 全部基于 IOKit 软停，可用      | **软 PWM** |

### 各自优点

**ChargeLimiter 式**

- 实现简单、逻辑透明、几乎不会因状态 bug 失效
- 停充期间完全不发热，降温最直接
- 对硬件零额外要求

**Jy's charge 软 PWM**

- 温度稳定在目标带，不反复冲击上限
- 温度越高、占空比越低，是"连续可调"的柔性
- 同温限下充电更快（无死时间）
- 电池平均发热更低（峰值温度是老化主因）
- 阈值、占空比、周期均可配置

### 各自缺点

**ChargeLimiter 式**

- 温度在上下限间反复大摆幅震荡，峰值温度高
- 无中间档：要么满速、要么全停
- 无法按温度"渐进"降功率

**Jy's charge 软 PWM**

- 实现复杂，依赖正确的 latch/使能状态（已踩过一次坑）
- 启停比滞回式频繁（但为软停，无握手/机械冲击）
- 总充电时间会比满速长（这是"柔性"的代价，不是缺陷）

### 结论

- 追求**电池寿命与温度平稳** → 软 PWM 更优
- 追求**实现简单、绝对可靠** → 滞回式更优
- 本项目的选择：**分级软 PWM 为主 + 39℃ 紧急停充兜底 + 容量停充互斥**，把两者优点都留下

---

## 8. 为什么软 PWM 是这台设备的唯一可行路线（证据链）

1. **IOKit 没有可写的充电电流/功率键**  
   全量 dump `AppleSmartBattery`、`AppleSMC`、`All AppleSMCCharger*` 服务：
   - 可写：`ExternalConnected`、`IsCharging`（布尔）
   - 只读：`ChargingOverride` / `InflowOverride` / `ChargerConfiguration` / `BestAdapterIndex`（写回返回 `kIOReturnBadArgument` / `NotPermitted`）
   - 充电电流由 USB-PD 与充电器 IC（tristar / CCG2）固件协商（3000mA），非软件可设
2. **连续控流的唯一入口是热模拟**（`putDeviceInThermalSimulationMode:` / `simulateLightThermalPressure`），它必须运行在 `thermalmonitord` 进程内
3. **RootHide 不向系统守护进程注入**  
   实测：`thermalmonitord`、`backboardd` 在多轮 respring / 重启 / userspace reboot 后均无注入；而 SpringBoard 可注入。→ 热模拟路线在本设备不可用
4. **软停通道已验证**  
   `PredictiveChargingInhibit` 软停平滑（1820 → -2 → 1689mA），不触发 USB-PD 重协商，适配器全程保持连接
5. **iOS 自身也用同一机制**  
   `ChargerData.TimeChargingThermallyLimited` 字段说明系统发热时本就会对充电做 PWM 限流；「优化电池充电」在 80% 处暂停/恢复也走 `PredictiveChargingInhibit`

> 因此：软 PWM 不是"退而求其次的 hack"，而是这台设备上**物理可行的、与系统同源的**柔性实现。

---

## 9. 后续方向：剩余充电时间估算

### 目标

在界面上显示「预计还需 X 分钟充到 Y%」（Y = 设定的最大充电）。

### 输入

- `soc`：当前电量（`CurrentCapacity`）
- `targetSoc`：`jy_max_percent`
- `capacity_mAh`：`NominalChargeCapacity`（健康修正后的实际容量）
- `ampNow_mA`：当前充电电流（充电相）
- `duty`：当前 PWM 占空比（未启用 PWM 时为 1.0）

### 模型 A：瞬时估算（简单，先做）

```
剩余容量 = (targetSoc - soc) / 100 × capacity_mAh
平均电流 = ampNow_mA × duty
剩余时间(h) = 剩余容量 / 平均电流
```

### 模型 B：观测外推（更准，后做）

用统计库（`min5` 表）里最近 10–15 分钟的 ΔSOC/Δt，反推实际平均充电速率：

```
实际速率(%/min) = ΔSOC / Δt
剩余时间 = (targetSoc - soc) / 实际速率
```

优点：自动把「电池 taper、温度、PWM、iOS 自身曲线」全部吃进去，不需要建模。

### 必须处理的三个难点

1. **充电曲线不是线性的**：锂电池 CC-CV，后段（>80%）电流大幅 taper，任何线性外推都会低估时间
2. **PWM 与温度联动**：温度升高 → 占空比下降 → 平均电流下降，估算要跟随
3. **iOS 自身的优化充电/温控** 也会改变速率

### 建议的落地方式

- **起步用模型 A**，并乘一个经验校准系数（例如 1.15~1.3，补偿 CV 段的 taper）
- 若误差大，切到模型 B（直接用实测速率，最稳）
- 界面上显示为：`预计 42 分钟充到 80%`，放在"最大充电"卡片下方；未充电时隐藏

---

## 10. 关于「占空比/周期是否上界面」

| 选项                | 优点                     | 缺点           |
| ----------------- | ---------------------- | ------------ |
| 保持内部设置（当前）        | 界面简洁，不易误调              | 想微调只能改配置     |
| 暴露"中度占空比"滑块       | 用户可按体感调"快/静"           | 需要解释概念，增加复杂度 |
| 暴露"充电强度"档位（慢/中/快） | 语义直观，映射到 duty 55/70/85 | 损失精细控制       |

建议：**先做"充电强度"三档（语义化），高级设置里再放开精确占空比与周期**。这样普通用户不需要理解 PWM，也能得到"更凉但更慢"或"更快但更热"的选择。

---

## 附：文件地图

| 文件                                                   | 职责                                     |
| ---------------------------------------------------- | -------------------------------------- |
| `ChargeLimiter/daemon.mm`                            | 主守护进程：采样、策略执行、PWM tick、HTTP API        |
| `ChargeLimiter/OfflineAdvisory/CLThermalGovernor.mm` | 温控决策引擎：档位、紧急 latch、pwmDuty             |
| `ChargeLimiter/OfflineAdvisory/CLOfflineAdvisory.mm` | C 策略信封适配                               |
| `ChargeLimiter/OfflineAdvisory/native_thermal.c`     | 温度分级 + 滞回 + min_hold                   |
| `ChargeLimiter/OfflineAdvisory/native_capacity.c`    | 容量滞回                                   |
| `ChargeLimiter/UIKit/CLButlerViewController.m`       | 主界面（温度/档位/滑块/日志/天数/版本/电流功率）            |
| `ChargeLimiter/Tweak/CLThermalSimTweak.m`            | 热模拟执行端（RootHide 下不被注入，保留作 Dopamine 备选） |
| `软PWM与温控开关对比.md`                                     | 早期对比草稿（本文档为其完整扩展）                      |

---

## 11. 版本演进与故障复盘（1.0.20 → 1.0.36）

> 这一节是实战记录。每一条都对应一次真机现象、根因和修复，避免后人重踩。

### 11.1 功能演进

| 版本 | 变更 |
|---|---|
| 1.0.20 | 软 PWM 柔性充电落地：按占空比软停/恢复 |
| 1.0.21 | 删除无效的 tweak 日志段；天数计数改纯数字右对齐 |
| 1.0.22 | PWM 按秒切片（周期 60s→20s），更接近连续调流 |
| 1.0.23 | 修复容量 latch 只能置位不能清除（`resume-review` 永不可达） |
| 1.0.24 | 修复 `[NSDate timeIntervalSince1970]` 类方法误用 |
| 1.0.25 | P0：启动释放残留 `PredictiveChargingInhibit` |
| 1.0.26 | P0：紧急停充闭环校验（8s 后回读电流） |
| 1.0.27 | P1：温度连续插值占空比 + 时间低通（90s） |
| 1.0.28 | P1：dT/dt 前馈 + 高 SOC 收紧 + 低温限流 |
| 1.0.29 | P2：剩余充电时间估算（ETA） |
| 1.0.30 | 修复 `updateChargeETA` 前向声明缺失 |
| 1.0.31 | 修复 `getIOPMPSServ` 缓存句柄失效导致 bat_info 冻结 |
| 1.0.32 | 修复共享句柄被误释放 → daemon 崩溃循环 |
| 1.0.33 | UI：防重叠 + 写入失败回滚开关状态 |
| 1.0.34 | 修复温控关闭时 PWM 仍在限流 |
| 1.0.35 | ETA 改电流×占空比速率；短暂停相位不再闪「暂停」 |
| 1.0.36 | 修复抬高最大充电后卡在容量保持带、不恢复充电 |

### 11.2 四个必须记住的坑

**① 缓存 IOKit 句柄必须能失效重枚举**
`getIOPMPSServ()` 曾用函数内 static 缓存 `io_service_t`。安装/注销后服务重枚举，句柄失效，`getBatInfo` 每次返回 nil → `bat_info` 永久冻结 → 温控与 UI 全部失联。
修复：文件级 static + `invalidateIOPMPSServCache()` + 失败重枚举重试 + `g_lastBatInfoOkTs` 新鲜度看门狗。

**② 共享句柄的所有权契约（borrowed vs owned）**
`getIOPMPSServ()` 返回的是**借用引用**。任何调用方 `IOObjectRelease` 都会把引用计数打到 0；再叠加"失效重试"的 release 就变成 **over-release → daemon 崩溃循环 → HTTP 连接错误 / 日志闪白 / UI 卡死**。
铁律：**借用引用绝不 release**；只有 `IOServiceGetMatchingService` / `*Copy*` 这类 +1 引用才 release。

**③ 容量控制是滞回，存在"保持带"**
停充线 `charge_above`、恢复线 `charge_below`。`charge_below < SOC < charge_above` 时既不满足停充也不满足恢复 → 保持上一条状态。
所以"把上限从 80 调到 81"会卡住不充。修复：`charge_above` 被设到当前 SOC 之上时立即 `resetBatteryStatus()`。

**④ 连续占空比必须显式尊重总开关**
改成 `duty(T)` 直接吃温度后，绕过了档位，导致 `jy_thermal_enabled=0` 时仍在限流。`pwmDuty` 开头必须先判总开关。

### 11.3 当前控制链（1.0.36 最终形态）

```
采样（电池事件 + 15s 心跳）
  → getBatInfo（共享服务句柄，失败自动重枚举）
  → CLOfflineAdvisory（温度分级 + 滞回 + min_hold / 容量滞回）
  → CLThermalGovernor
       level        → 档位展示
       emergency    → 39℃ 停充 latch（回落 3℃ 解除）
       pwmDuty      = 连续 duty(T) [+dT/dt 前馈 +高SOC收紧]
                       + 时间低通(90s)
                       + 硬门控：温控关闭 / 未接电源 / 容量到顶 / 紧急
  → applyChargePolicy（容量/紧急优先，PWM 让位）
  → CLThermalPwmTick（2s，时间切片相位，软停/恢复）
  → IOKit PredictiveChargingInhibit
```

---

## 12. 验收清单（安装 1.0.36 后逐项确认）

| # | 操作 | 预期 |
|---|---|---|
| 1 | 打开 App | 温度/电量/电流实时跳动，不再卡在某个旧值 |
| 2 | 插拔充电器 | 「未接电源」↔「充电中」立即切换 |
| 3 | 保存任意设置 | 不再出现「保存失败：连接错误」 |
| 4 | 打开「温控充电」 | 开关保持常绿；关掉后 `[pwm]` 日志停止出现 |
| 5 | 充电到 32–36℃ | `[pwm] duty=` 连续渐变（如 96→88→75%），温度小幅波动 |
| 6 | 温度 ≥39℃ | `[act=3]` 紧急停充，电流归零；降到 36℃ 恢复 |
| 7 | 电量到 80% | 停充，界面显示「已满」 |
| 8 | 把最大充电从 80% 调到 81% | **立即恢复充电**（`cap=0`，amp 变正） |
| 9 | 再调回 80% | 立即停充 |
| 10 | 充电中观察 ETA | 79% 附近应为 5–10 分钟；PWM 停充相位不闪「暂停」 |
| 11 | 界面文字 | 电量/电流/功率/ETA 不压到「电池温度」 |
| 12 | 底部 | 显示 `Jy's charge v1.0.36` |

> 任一项不通过：展开日志，找 `[pwm]` / `[warn]` / `[channel]` 行，附带当时温度、电量、电流一起反馈。
