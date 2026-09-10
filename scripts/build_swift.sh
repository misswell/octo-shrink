#!/bin/bash
# scripts/build_swift.sh — 构建原生 Swift 版 OctoShrink
#
# 产物：OctoShrink_swift.app（第三条产物线，不替换 Direct / App Store）
#
# 用法：
#   bash scripts/build_swift.sh            # 编译 + 打包（不签名）
#   SIGN=1 bash scripts/build_swift.sh     # 编译 + 签名

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_DIR="$PROJECT_DIR/swift"
SRC_DIR="$SWIFT_DIR/Sources/OctoShrinkSwift"
BUILD_DIR="$SWIFT_DIR/.build"
APP_NAME="OctoShrink"
OUT_APP="$BUILD_DIR/${APP_NAME}_swift.app"

log()  { echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ─── 清理旧产物 ───
log "清理旧构建产物"
rm -rf "$OUT_APP" "$BUILD_DIR/obj"
mkdir -p "$BUILD_DIR/obj"

# ─── 编译 Swift 源码 ───
log "编译 Swift 源码"
find "$SRC_DIR" -name '*.swift' | sort > "$BUILD_DIR/sources.txt"
cat "$BUILD_DIR/sources.txt"

xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -module-name OctoShrinkSwift \
  -o "$BUILD_DIR/${APP_NAME}" \
  @"$BUILD_DIR/sources.txt" \
  || fail "Swift 编译失败"
ok "编译成功: $BUILD_DIR/${APP_NAME}"

# ─── 创建 .app 包结构 ───
log "创建 .app 包"
mkdir -p \
  "$OUT_APP/Contents/MacOS" \
  "$OUT_APP/Contents/Resources/bin" \
  "$OUT_APP/Contents/Resources/lib"

cp "$BUILD_DIR/${APP_NAME}" "$OUT_APP/Contents/MacOS/${APP_NAME}"
cp "$SWIFT_DIR/Info.plist" "$OUT_APP/Contents/Info.plist"

# ─── 复制图标 ───
if [ -f "$PROJECT_DIR/src-tauri/icons/icon.icns" ]; then
  cp "$PROJECT_DIR/src-tauri/icons/icon.icns" "$OUT_APP/Contents/Resources/AppIcon.icns"
  ok "图标已复制"
fi

# ─── 复制 CLI 工具和动态库（同 Direct 线） ───
log "复制 CLI 工具和动态库"
TAURI_RES="$PROJECT_DIR/src-tauri/resources"
COPY_COUNT=0
for tool in pngquant oxipng cjpeg cwebp avifenc gifsicle; do
  if [ -f "$TAURI_RES/bin/$tool" ]; then
    cp "$TAURI_RES/bin/$tool" "$OUT_APP/Contents/Resources/bin/"
    COPY_COUNT=$((COPY_COUNT + 1))
  fi
done
ok "$COPY_COUNT 个 CLI 工具"

DYLIB_COUNT=0
if [ -d "$TAURI_RES/lib" ]; then
  for lib in "$TAURI_RES/lib/"*.dylib; do
    [ -f "$lib" ] || continue
    cp "$lib" "$OUT_APP/Contents/Resources/lib/"
    DYLIB_COUNT=$((DYLIB_COUNT + 1))
  done
fi
ok "$DYLIB_COUNT 个动态库"

# ─── 签名（可选） ───
if [ "${SIGN:-0}" = "1" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)"
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    log "签名 Swift 版：$SIGN_IDENTITY"
    for lib in "$OUT_APP/Contents/Resources/lib/"*.dylib; do
      [ -f "$lib" ] && codesign --force --options runtime --sign "$SIGN_IDENTITY" "$lib" 2>/dev/null || true
    done
    for bin in "$OUT_APP/Contents/Resources/bin/"*; do
      [ -f "$bin" ] && codesign --force --options runtime --sign "$SIGN_IDENTITY" "$bin" 2>/dev/null || true
    done
    codesign --force --options runtime \
      --entitlements "$PROJECT_DIR/src-tauri/entitlements.plist" \
      --sign "$SIGN_IDENTITY" \
      "$OUT_APP" || echo "    ⚠ 签名失败（可能缺少证书）"
    ok "Swift 版已签名"
  else
    echo "    ⚠ 未检测到 Developer ID 证书，跳过签名"
  fi
fi

# ─── 报告 ───
echo ""
log "🎉 Swift 版构建完成！"
echo "    产物: $OUT_APP"
echo "    大小: $(du -sh "$OUT_APP" | awk '{print $1}')"
