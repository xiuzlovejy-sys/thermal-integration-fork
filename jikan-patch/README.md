# Jikan 补丁：锁屏显示 Jy's charge 的充电估算

## 为什么需要

Jikan 用**瞬时电流**（`InstantAmperage`）估算剩余时间。Jy's charge 的软 PWM 让电池电流变成
`0 ↔ 3A` 的方波，Jikan 看到的是 `0W ↔ 12W`，估算会明显跳变、偏乐观。

Jy's charge 的 daemon 用 `amp × duty`（逐样本积分）计算速率，结果通过
`POST http://127.0.0.1:1230 {"api":"status"}` 暴露：

```json
{"status":0,"data":{"eta_min":18,"eta_state":"charging","duty":0.43}}
```

本补丁让 Jikan **优先使用这个外部估算**，取不到时回退到它自己的算法。

## 改动范围

| 文件 | 改动 |
|---|---|
| `Tweak/TT100/TT100ExternalEstimate.h/.m` | 新增：异步查询 + 90s 缓存 |
| `Tweak/TT100/TT100.m` | `_refreshBatteryInfo` 里优先采用外部 `eta_min`；`estimateStatus` 标记为 `external` |

`Tweak/Makefile` 用 `$(wildcard TT100/*.m)`，新增文件自动参与编译，**无需改 Makefile**。

## 应用

```bash
git clone --depth 1 --branch 1.0.2 https://github.com/waruhachi/Jikan
bash jikan-patch/apply.sh ./Jikan
```

脚本幂等：已打过会提示并退出。

## 构建

CI：`.github/workflows/build-jikan-patched.yml`，手动触发或改 `jikan-patch/**` 时运行，
产出 `jikan-jys-roothide-deb` 与 `jikan-jys-rootless-deb`。

本地（需要 theos + iOS SDK）：

```bash
cd Jikan
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1 TARGET=iphone:clang:latest:14.0
```

## 安装注意

1. **先卸载已安装的 Jikan**，避免两份 tweak 同时注入 SpringBoard。
2. 选与你当前越狱匹配的包：RootHide → `roothide`；一般无根越狱 → `rootless`。
3. 安装后重启 SpringBoard（respring）。
4. Jikan 设置里目标百分比仍可用「同步到 Jikan」（Jy's charge 主界面按钮）更新；
   锁屏倒计时则来自 Jy's charge 的 ETA。

## 回退

取不到外部估算（App 未运行 / daemon 未启动 / 版本低于 1.0.52）时，自动回退到 Jikan 自己的算法，
不会显示空白或负数。

## 许可

Jikan 为 GPLv3。本补丁是其衍生作品，同样遵循 GPLv3；分发时请保留原始版权与许可声明。
