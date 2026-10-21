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

python3 "$SRC_DIR/patch_tt100.py" "$TT100_DIR/TT100.m"

echo "[patch] applied to $JIKAN_DIR"
