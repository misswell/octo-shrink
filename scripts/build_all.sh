#!/bin/bash
# scripts/build_all.sh — 同时构建两条产物线
#
# 1. Direct 版 (default=cli-backends) → OctoShrink_direct.app
# 2. App Store 版 (appstore=inproc-backends) → OctoShrink.app
#
# 用法：
#   bash scripts/build_all.sh            # 编译两版 + 复制资源（不签名）
#   SIGN=1 bash scripts/build_all.sh     # 编译 + 签名两版
#
# 产物路径：
#   Direct    : target/release/bundle/macos/OctoShrink_direct.app
#   App Store : target/release/bundle/macos/OctoShrink.app

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$PROJECT_DIR/src-tauri"
BUNDLE_DIR="$TAURI_DIR/target/release/bundle/macos"
APP_NAME="OctoShrink"

log()  { echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ========== 1. Direct 版（先建，避免被 App Store 版覆盖）==========
log "构建 Direct 版（default=cli-backends）"
cd "$TAURI_DIR"
cargo tauri build --bundles app || fail "Direct 构建失败"
DIRECT_APP="$BUNDLE_DIR/${APP_NAME}.app"
[ -d "$DIRECT_APP" ] || fail "Direct 产物不存在：$DIRECT_APP"

# 复制内置 CLI 工具和动态库到 .app
log "复制 CLI 工具和动态库到 Direct .app"
RES_DIR="$DIRECT_APP/Contents/Resources"
mkdir -p "$RES_DIR/bin" "$RES_DIR/lib"
if [ -d "$TAURI_DIR/resources/bin" ]; then
  cp "$TAURI_DIR/resources/bin/"* "$RES_DIR/bin/" 2>/dev/null || true
  ok "$(ls "$RES_DIR/bin" 2>/dev/null | wc -l | tr -d ' ') 个 CLI 工具"
fi
if [ -d "$TAURI_DIR/resources/lib" ]; then
  cp "$TAURI_DIR/resources/lib/"*.dylib "$RES_DIR/lib/" 2>/dev/null || true
  ok "$(ls "$RES_DIR/lib" 2>/dev/null | wc -l | tr -d ' ') 个动态库"
fi

# 签名 Direct 版（可选）
if [ "${SIGN:-0}" = "1" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)"
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    log "签名 Direct 版：$SIGN_IDENTITY"
    ENT="$TAURI_DIR/entitlements.plist"
    CS=(--force --options runtime --entitlements "$ENT" --sign "$SIGN_IDENTITY")
    for lib in "$RES_DIR/lib/"*.dylib; do [ -f "$lib" ] && codesign "${CS[@]}" "$lib" 2>/dev/null || true; done
    for bin in "$RES_DIR/bin/"*; do [ -f "$bin" ] && codesign "${CS[@]}" "$bin" 2>/dev/null || true; done
    codesign "${CS[@]}" "$DIRECT_APP" 2>/dev/null || codesign "${CS[@]}" "$DIRECT_APP"
    ok "Direct 版已签名"
  else
    echo "    ⚠ 未检测到 Developer ID 证书，跳过 Direct 签名"
  fi
fi

# 重命名为 _direct
DIRECT_RENAMED="$BUNDLE_DIR/${APP_NAME}_direct.app"
rm -rf "$DIRECT_RENAMED"
mv "$DIRECT_APP" "$DIRECT_RENAMED"
ok "Direct: $DIRECT_RENAMED"

# ========== 2. App Store 版 ==========
log "构建 App Store 版（appstore=inproc-backends）"
# Cargo 1.90.0 regression：panic=abort 损坏 proc-macro dylib，用 unwind 绕过（仅 appstore 线）
export CARGO_PROFILE_RELEASE_PANIC=unwind
cargo tauri build --bundles app --features appstore --config tauri.conf.appstore.json || fail "App Store 构建失败"
APPSTORE_APP="$BUNDLE_DIR/${APP_NAME}.app"
[ -d "$APPSTORE_APP" ] || fail "App Store 产物不存在：$APPSTORE_APP"

# 复制前端文件（--config 模式下 Tauri 不自动复制前端）
cp -R "$PROJECT_DIR/frontend/." "$APPSTORE_APP/Contents/Resources/" || true
ok "前端文件已复制"

# 复制 CLI 工具到 App Store .app（自包含的 + 带 dylib 依赖的）
log "复制 CLI 工具到 App Store .app"
mkdir -p "$APPSTORE_APP/Contents/Resources/bin"
AS_BIN="$APPSTORE_APP/Contents/Resources/bin"
AS_LIB="$APPSTORE_APP/Contents/Resources/lib"
mkdir -p "$AS_LIB"
SRC_BIN="$TAURI_DIR/resources/bin"

# gifsicle（自包含，仅依赖 libSystem）
if [ -f "$TAURI_DIR/resources/bin/gifsicle" ]; then
  cp "$SRC_BIN/gifsicle" "$AS_BIN/"
  ok "gifsicle 已复制"
else
  echo "    ⚠ gifsicle 未找到，GIF 将降级为 gif crate"
fi

# oxipng（自包含，仅依赖 libiconv + libSystem）
if [ -f "$SRC_BIN/oxipng" ]; then
  cp "$SRC_BIN/oxipng" "$AS_BIN/"
  ok "oxipng 已复制"
else
  echo "    ⚠ oxipng 未找到，PNG 无损优化将降级为 inproc oxipng crate"
fi

# pngquant + 依赖 dylib（libpng16 + liblcms2，均仅递归依赖系统库）
if [ -f "$SRC_BIN/pngquant" ]; then
  cp "$SRC_BIN/pngquant" "$AS_BIN/"
  # 复制 pngquant 的非系统 dylib 依赖
  for lib in libpng16.16.dylib liblcms2.2.dylib; do
    SRC_LIB=""
    # 尝试从 otool 输出提取实际路径
    SRC_LIB=$(otool -L "$SRC_BIN/pngquant" 2>/dev/null | grep "$lib" | awk '{print $1}' | head -1)
    if [ -n "$SRC_LIB" ] && [ -f "$SRC_LIB" ]; then
      cp "$SRC_LIB" "$AS_LIB/"
      ok "$lib 已复制"
    else
      echo "    ⚠ $lib 未找到，pngquant 可能无法运行"
    fi
  done
  # 用 install_name_tool 将 dylib 路径改为 @executable_path（沙盒不依赖 DYLD）
  install_name_tool -change /opt/homebrew/opt/little-cms2/lib/liblcms2.2.dylib \
    @executable_path/../lib/liblcms2.2.dylib "$AS_BIN/pngquant" 2>/dev/null || true
  install_name_tool -change /opt/homebrew/opt/libpng/lib/libpng16.16.dylib \
    @executable_path/../lib/libpng16.16.dylib "$AS_BIN/pngquant" 2>/dev/null || true
  # 修正 dylib 自身 ID
  if [ -f "$AS_LIB/liblcms2.2.dylib" ]; then
    install_name_tool -id @executable_path/../lib/liblcms2.2.dylib "$AS_LIB/liblcms2.2.dylib" 2>/dev/null || true
  fi
  if [ -f "$AS_LIB/libpng16.16.dylib" ]; then
    install_name_tool -id @executable_path/../lib/libpng16.16.dylib "$AS_LIB/libpng16.16.dylib" 2>/dev/null || true
  fi
  ok "pngquant + dylib 路径已修正"
else
  echo "    ⚠ pngquant 未找到，PNG 压缩将降级为 inproc imagequant"
fi

# 签名 App Store 版（可选）
if [ "${SIGN:-0}" = "1" ]; then
  SIGN_IDENTITY_AS="${APPSTORE_SIGN_IDENTITY:-Apple Distribution: Guofeng Liu (U8U443D7ZL)}"
  log "签名 App Store 版：${SIGN_IDENTITY_AS}"
  ENT_AS="$TAURI_DIR/entitlements-appstore.plist"
  # 先签名所有子进程可执行文件和 dylib（子进程需要独立签名）
  for bin in "$AS_BIN"/*; do
    [ -f "$bin" ] && codesign --force --options runtime --sign "${SIGN_IDENTITY_AS}" "$bin" 2>/dev/null || true
  done
  for lib in "$AS_LIB"/*.dylib; do
    [ -f "$lib" ] && codesign --force --options runtime --sign "${SIGN_IDENTITY_AS}" "$lib" 2>/dev/null || true
  done
  codesign --force --options runtime --entitlements "$ENT_AS" --sign "${SIGN_IDENTITY_AS}" "$APPSTORE_APP" \
    || echo "    ⚠ App Store 签名失败：确认钥匙串已安装 Apple Distribution 证书"
  ok "App Store 版已签名"
fi

# ========== 3. 报告 ==========
echo ""
log "🎉 两版构建完成！"
echo "    Direct    : $DIRECT_RENAMED"
echo "    App Store : $APPSTORE_APP"
echo "    Direct 大小    : $(du -sh "$DIRECT_RENAMED" | awk '{print $1}')"
echo "    App Store 大小 : $(du -sh "$APPSTORE_APP" | awk '{print $1}')"
