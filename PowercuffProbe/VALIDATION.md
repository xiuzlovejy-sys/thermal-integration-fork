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

## 下一阶段仍需核验

1. 生产构造入口的即刻绑定、延迟找类、初始化早于 hook 的情况，先在独立宿主验证。
2. 自动注入加载器、过滤规则、安全模式和其它插件共存，须与手动 dlopen 结果分开验收。
3. 真实 CommonProduct 签名与对象生命周期；长期强引用的影响。
4. 生产通知名下跨进程请求/状态闭环与时效，不能仅凭旧状态值判断进程存活。

本轮未证明旧 watchdog 根因已解决，也未证明充电降流效果。现有构建 21 主包不受本次实验提交影响。
