# Apple arm64e 隔离验证结果

日期：2026-10-23。Apple 交叉构建，local-ios 独立进程执行。未安装观察插件，未向 thermalmonitord 注入、重启服务或下发真实热模拟。

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

下一阶段仍需核验：

1. 独立宿主中的真实注入框架及 arm64e IMP 认证、原方法跳转。
2. 生产构造入口的即刻绑定、延迟找类、初始化早于 hook 的情况。
3. 真实 CommonProduct 签名与对象生命周期；长期强引用的影响。
4. 生产通知名下跨进程请求/状态闭环与时效，不能仅凭旧状态值判断进程存活。

本轮未证明旧 watchdog 根因已解决，也未证明充电降流效果。现有构建 21 主包不受本次实验提交影响。
