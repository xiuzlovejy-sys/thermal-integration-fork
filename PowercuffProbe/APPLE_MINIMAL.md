# Apple 工具链最小交叉验证

此验证只需要 macOS 上已安装的 Xcode（含 iPhoneOS SDK）与 Python 3。不需要 Theos、设备连接、开发者证书或越狱插件安装。当前文件未在 Apple 工具链环境运行过。

在项目根目录或独立验证压缩包解压后的根目录执行：

```sh
sh tests/build_powercuff_apple_minimal.sh
```

结果保存在 `PowercuffProbe/apple-minimal/`。请将整个结果目录压缩带回，失败时也保留：

- `toolchain.txt`：编译器、SDK 与目标信息。
- `fixture.o`、`compile.log`：真实编译产物与编译诊断。
- `metadata.json`、`metadata.log`、`gate-exit.txt`：两个 PAC schema 的静态核对及退出状态。
- 仅门禁通过时生成 `minimal-arm64e`、`link.log`，供后续检查链接后 fixup。

门禁返回 2 代表不满足当前两个实测 schema，不意味着 Apple 工具链整体不可用；需要对照原始 object 与本机运行时证据继续分析。编译器本身失败时可能只有编译日志，不会伪造 metadata。

脚本只交叉编译，不签名、不运行 iOS 程序、不连接设备。后续需由主线程核对产物、签名并在独立进程运行，之后才考虑系统服务中的零调用观察。检查通过不是热模拟有效的证据。
