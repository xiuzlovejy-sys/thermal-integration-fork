# RootHide 独立加载诊断包

该包只为核验“实际安装路径下，独立宿主能否动态加载观察组件”。安装后不会自动运行，不向 thermalmonitord 或其它系统服务注入，不读取或写入充电控制。

包名为 `com.jy.charge.powercuff-loader-test`，与主包独立，不覆盖、冲突或替换 Jy's Charge。所有文件只放在 RootHide 前缀下的：

```text
/usr/lib/jycharge-powercuff-loader-test/
```

包无 maintainer scripts、launchd 项、自动加载目录、过滤 plist、主包配置或恢复数据。卸载只删除本包文件。测试运行后生成的输出目录需保留用于分析。

## 当前证据

直接链接测试四场景已经通过。动态观察组件从 Documents 加载被报告为 sandbox mmap 拒绝；在运行时执行镜像中，原宿主与库的签名身份不匹配。移除宿主平台身份后，当前 App 启动环境又拒绝运行该 arm64e 宿主。不能把这些失败计作动态加载成功。

本包使用 Apple 工作流 39884329988 的同源 host、observer、controller。包内宿主及控制器只带 platform-application、no-sandbox、no-container，未沿用主包的电源写入等权限；dylib 不带 entitlements，采用现有 RootHide 包的 ldid 签名方式。签名配置不保证安装环境一定接受，安装后的测试结果才是验收证据。

## 安装与执行

这是待验证的开发诊断包，不是柔性降流功能更新。是否安装由用户决定；构建阶段没有安装或执行包内文件。

正常通过 RootHide 的包管理器安装后，由代理确认实际安装前缀，再显式运行：

```sh
sh /实际RootHide前缀/usr/lib/jycharge-powercuff-loader-test/run-tests.sh /工作区内的绝对输出目录
```

脚本检查预期目录后缀和所需文件，自动使用同一前缀下的 libellekit；该检查不能独立证明包已安装，代理运行前还需核对包管理器清单。随后依次启动独立测试宿主及控制器，包含约 30 秒的找类超时场景。任何场景失败就保留日志并停止后续场景。测试只使用假 CommonProduct 与 `.hosttest.*` 通知域，不连接主包 governor；不启动或停止任何服务。

即使全部通过，也不能证明真实服务的自动注入、旧 watchdog 根因或实际降流有效。
