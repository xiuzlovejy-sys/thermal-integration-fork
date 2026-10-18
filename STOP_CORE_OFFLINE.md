# 离线温度停充组件的分叉归档

`ChargeLimiter/OfflineAdvisory/temperature_stop.{h,c}` 为独立 C99 纯计算温度停充建议核心，来自 `../thermal-native-stop`；**未加入 Xcode target，也未接线到 daemon、充电命令、设置写入或原有控制器**。用户可在离线模型指定 `stop_c` 与 `resume_c`；两者分别是停充及考虑恢复的温度阈值（摄氏度）。默认关闭。失效/过期温度不会建议恢复。

Linux 离线构建与 40,000 事件 Python 差分测试见 [原生核心测试](minis://workspace/thermal-native-stop/README.md)。此前同机 Darwin 使用 Procursus clang14 编译双核心示意程序虽成功链接，但 arm64e 对象头 caps 0x00 与 ld64 要求的 0x80 不符；**该新增温停核心尚未经过同机 Darwin 编译**，更没有真机运行或温控效果验证。

完整项目实现仍需：与原生 UIKit/daemon 的配置路径接线、序列化策略状态、所有权与采样新鲜度真实性、ABI 兼容工具链、执行与恢复安全门槛；不得把当前文件当成已经可安装版本。
