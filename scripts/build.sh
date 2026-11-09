#!/usr/bin/env bash
# HarmonyScale 构建脚本
# 鸿蒙工程路径不允许包含中文字符，故在纯 ASCII 路径下构建，再把产物同步回工作区。
set -e

DEVECO="/c/Program Files/Huawei/DevEco Studio"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${HARMONYSCALE_BUILD_ROOT:-/c/temp/harmonyscale-build}"
PROJECT_NAME="HarmonyScale"

export PATH="$DEVECO/tools/node:$PATH"
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
# 打包签名阶段需要 java，使用 DevEco 自带的 JBR
if [ -x "$DEVECO/jbr/bin/java.exe" ]; then
  export JAVA_HOME="C:/Program Files/Huawei/DevEco Studio/jbr"
  export PATH="$DEVECO/jbr/bin:$PATH"
fi

echo "==> 同步工程到 ASCII 构建路径: $BUILD_ROOT"
DEST="$BUILD_ROOT/$PROJECT_NAME"
rm -rf "$DEST"
mkdir -p "$DEST"
# 排除产物与依赖目录，保留源码
cp -r "$SRC/." "$DEST/"
rm -rf "$DEST/node_modules" "$DEST/oh_modules" "$DEST/entry/build" \
       "$DEST/entry/oh_modules" "$DEST/.hvigor" "$DEST/.git" "$DEST/scripts"

cd "$DEST"

echo "==> 执行 hvigor assembleHap"
node "$DEVECO/tools/hvigor/bin/hvigorw.js" \
  --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  assembleHap --no-daemon

echo "==> 同步 HAP 产物回工作区"
OUT_DIR="$SRC/entry/build/outputs/default"
mkdir -p "$OUT_DIR"
find "$DEST/entry/build" -name "*.hap" -exec cp -f {} "$OUT_DIR/" \; 2>/dev/null || true
ls -la "$OUT_DIR" 2>/dev/null || true
echo "==> 构建完成"
