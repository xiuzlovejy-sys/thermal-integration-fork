#!/bin/bash
# 把「外部 ETA 优先」补丁应用到 Jikan 1.0.2 源码。
# 用法: bash jikan-patch/apply.sh /path/to/Jikan
set -euo pipefail

JIKAN_DIR="${1:-}"
if [ -z "$JIKAN_DIR" ] || [ ! -f "$JIKAN_DIR/Tweak/TT100/TT100.m" ]; then
    echo "usage: apply.sh <Jikan checkout>" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TT100_DIR="$JIKAN_DIR/Tweak/TT100"

cp "$SRC_DIR/TT100ExternalEstimate.h" "$TT100_DIR/"
cp "$SRC_DIR/TT100ExternalEstimate.m" "$TT100_DIR/"

# 中文界面：Jikan 把语言资源直接放在 layout 里打包（不是编译产物）。
L10N_DIR="$JIKAN_DIR/layout/Library/Tweak Support/Jikan/Localization/zh-Hans.lproj"
mkdir -p "$L10N_DIR"
cp "$SRC_DIR/zh-Hans.lproj/Localizable.strings" "$L10N_DIR/"

python3 "$SRC_DIR/patch_tt100.py" "$TT100_DIR/TT100.m"

# 版本后缀：定制版与官方 1.0.2 区分开，Sileo 才能正确比较/显示，
# 也方便确认"装的到底是哪一个构建"。
CONTROL="$JIKAN_DIR/layout/DEBIAN/control"
if [ -f "$CONTROL" ] && grep -q '^Version: 1\.0\.2$' "$CONTROL"; then
    TMP_CONTROL="$(mktemp)"
    sed 's/^Version: 1\.0\.2$/Version: 1.0.2-jys1/' "$CONTROL" > "$TMP_CONTROL"
    mv "$TMP_CONTROL" "$CONTROL"
    echo "[patch] package version -> 1.0.2-jys1"
fi

echo "[patch] applied to $JIKAN_DIR"
