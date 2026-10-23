# Apple arm64e 隔离验证结果

日期：2026-10-23。Apple 交叉构建，local-ios 独立进程执行。未安装观察插件，未向 thermalmonitord 注入、重启服务或下发真实热模拟。

## 第一阶段：测试桩

| 项目 | 结果 |
| --- | --- |
| 最小构建工作流 | [39881077104](https://github.com/xiuzlovejy-sys/thermal-integration-fork/actions/runs/39881077104)，成功 |
| 完整测试构建工作流 | [39881592855](https://github.com/xiuzlovejy-sys/thermal-integration-fork/actions/runs/39881592855)，成功 |
| 完整测试源提交 | `6b0ec17`，专用分支 `powercuff-apple-minimal-validation` |
| 工具链 | Apple clang 21.0.0，Xcode 26.6，iPhoneOS SDK 26.5，部署目标 iOS 15 |
| 真实 fixture 元数据 | superclass DA/address-diverse/B5AB，global block isa DA/address-diverse/6AE1，均 type 11 |
| 最小程序手机运行 | `PASS minimal Objective-C class load`，退出 0 |
| 完整观察测试手机运行 | `PASS 34 native Powercuff probe assertions (test_apply=0)`，退出 0 |
| 完整假执行测试手机运行 | `PASS 38 native Powercuff probe assertions (test_apply=1)`，退出 0 |

完整测试产物只依赖 Foundation、libobjc、libc++、libSystem、CoreFoundation，没有 CydiaSubstrate 动态加载依赖。MSHookMessageEx 由测试桩提供，不能当作真实 ElleKit/Substrate 验收。方法调用只面向同进程动态创建的假 CommonProduct；测试通知使用 `.test.*` 命名空间，不连接主包 governor。

覆盖：原初始化参数、继承方法与重复安装、self/nil/替换对象返回、异步捕获、对象释放、签名拒绝、Darwin notify 请求投递、观察零调用、五档映射和非法档位。没有放宽检查、关闭 PAC 或将 arm64 结果冒充 arm64e。

## 第二阶段：本机真实 ElleKit

提交 `7778d19`，Apple 工作流 [39882530782](https://github.com/xiuzlovejy-sys/thermal-integration-fork/actions/runs/39882530782) 成功。新后端接受显式框架路径，经 dlopen/dlsym 加载本机框架，检查函数存在、来源可追溯且不等于测试桥接函数；没有失败后回退测试桩。框架句柄保持到进程退出。

本机 libsubstrate 与 CydiaSubstrate 实际指向 libellekit；静态核对其含 arm64e 切片及 MSHookMessageEx 导出。以下为手机独立进程结果：

| 后端 | 观察模式 | 假执行模式 |
| --- | --- | --- |
| 测试桩回归 | 34 项，退出 0 | 38 项，退出 0 |
| 本机真实 ElleKit | 39 项，退出 0 | 43 项，退出 0 |

额外断言检查框架加载、符号来源、无桩回退和只安装一次。继承的原方法调用、重复安装、返回替换对象、nil、释放计数与通知等原有断言全部保留。测试对象仍是独立进程创建的假 CommonProduct；假执行只调用假接收器。

本结果验证了手动加载本机 ElleKit 后的消息 Hook 与原方法调用，不验证自动注入加载器、过滤规则、安全模式或与其它插件共存。也未执行生产构造入口。

## 第三阶段：构造入口与跨进程通知

Apple 工作流 [39883798763](https://github.com/xiuzlovejy-sys/thermal-integration-fork/actions/runs/39883798763) 已成功构建动态观察 dylib 与宿主。手机对工作区 dylib 的 dlopen 被报告为 `file system sandbox blocked mmap()`，失败发生在组件构造函数运行前，退出 1。本次没有更改设备权限或把文件安装到越狱目录来消除该限制；此加载路径未通过。

补充工作流 [39884329988](https://github.com/xiuzlovejy-sys/thermal-integration-fork/actions/runs/39884329988)，源提交 `fea867f`，将同一 Logos 生产构造入口与 Core 直接链接进独立宿主。编译固定 `CLPC_TESTING=0`、`CLPC_ENABLE_APPLY=0`；`CLPC_HOST_TESTING=1` 仅选择 `.hosttest.*` 隔离通知名。编译保护已实测拒绝非测试构建开启 apply。

手机执行结果如下；数字是本次执行的断言计数，均退出 0：

| 场景 | 断言数 | 核验内容 |
| --- | --- | --- |
| immediate | 113 | 类在构造期已存在，真实 ElleKit hook 捕获后续初始化 |
| delayed | 115 | 类延迟出现，生产定时查找随后绑定 |
| early | 116 | 对象早于 hook 初始化时不追溯捕获，后续初始化才被捕获 |
| absent | 114 | 实际等待约 30 秒后重试停止，之后出现的类保持未 hook |

每个场景都由独立控制器子进程依次发送 2/3/0，再由新子进程读取状态。检查子进程退出、JSON 字段存在及数值类型、请求计数增量、模式值、捕获数与观察状态。捕获的假对象热方法调用数及返回调用计数都为 0；无对象场景返回 NoProduct。测试没有手动调用安装或启动函数，实际构造入口在 main 前执行。静态宿主将 fake CommonProduct 预先编译进程序；early 场景的测试初始化入口排在观察构造入口之前。

该结果覆盖直接链接时的构造逻辑与隔离通知域的跨进程路径，不覆盖 dylib 动态装载或真实服务中的生产通知域。

## 下一阶段仍需核验

1. 单独解决和验收已记录的观察 dylib 加载路径；直接链接成功不能代替此项。
2. 自动注入加载器、过滤规则、安全模式和其它插件共存。
3. 真实 CommonProduct 签名、初始化时序与对象生命周期；长期强引用的影响。
4. 真实服务的生产通知域、进程重启和状态有效期；最后才进行短时单档与 off 恢复、功率对照。

本轮未证明旧 watchdog 根因已解决，也未证明充电降流效果。现有构建 21 主包不受本次实验提交影响。
