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
cargo tauri build --bundles app --features appstore --config tauri.conf.appstore.json -- --no-default-features \
  || fail "App Store 构建失败"
APPSTORE_APP="$BUNDLE_DIR/${APP_NAME}.app"
[ -d "$APPSTORE_APP" ] || fail "App Store 产物不存在：$APPSTORE_APP"

# 复制前端文件（--config 模式下 Tauri 不自动复制前端）
cp -R "$PROJECT_DIR/frontend/." "$APPSTORE_APP/Contents/Resources/" || true
ok "前端文件已复制"

# App Store 版**不打包任何内置 CLI / dylib**：进程内引擎（engine_inproc.rs）只调
# 链接进主程序的 Rust crate；而且沙盒子进程拿不到父进程的 security-scoped 文件授权，
# 打包 CLI 在这条线上必然失败。历史上这里复制过 pngquant/oxipng/gifsicle 以求
# "与 Direct 对齐"，结果是死代码 + bundle 里多出第三方可执行文件（审核风险）。
# 见 AGENTS.md「App Store bundle 自检」。
rm -rf "$APPSTORE_APP/Contents/Resources/bin" "$APPSTORE_APP/Contents/Resources/lib"

# bundle 自检：App Store 包里除主程序外不许有第三方 Mach-O / dylib，
# 引擎源码里不许有 spawn CLI 的写法（注释里提到这些词不算）。
check_appstore_bundle() {
  local app="$1" foreign macho spawns
  foreign=$(find "$app/Contents" \( -name '*.dylib' -o -path '*/Resources/bin/*' \) -type f 2>/dev/null || true)
  if [ -n "$foreign" ]; then
    echo "$foreign" >&2
    fail "App Store 包里混进了外部可执行文件/dylib（沙盒线必须全进程内）"
  fi
  macho=$(find "$app/Contents/MacOS" -type f ! -name "$APP_NAME" 2>/dev/null || true)
  if [ -n "$macho" ]; then
    echo "$macho" >&2
    fail "Contents/MacOS 下有额外可执行文件"
  fi
  # 只扫生产代码：自检测试里就写着这些词（截到第一个 #[cfg(test)] 之前）。
  spawns=$(sed -n '1,/#\[cfg(test)\]/p' "$TAURI_DIR/src/engine_inproc.rs" \
    | sed 's://.*::' \
    | grep -nE 'find_tool|make_command|cli_to_file|Command::new' || true)
  if [ -n "$spawns" ]; then
    echo "$spawns" >&2
    fail "engine_inproc.rs 出现了 spawn CLI 的写法，沙盒线必须全部进程内"
  fi
  ok "bundle 自检通过（无外部可执行文件、引擎无 spawn）"
}
check_appstore_bundle "$APPSTORE_APP"

# 签名 App Store 版（可选）
if [ "${SIGN:-0}" = "1" ]; then
  SIGN_IDENTITY_AS="${APPSTORE_SIGN_IDENTITY:-Apple Distribution: Guofeng Liu (U8U443D7ZL)}"
  log "签名 App Store 版：${SIGN_IDENTITY_AS}"
  ENT_AS="$TAURI_DIR/entitlements-appstore.plist"
  codesign --force --options runtime --entitlements "$ENT_AS" --sign "${SIGN_IDENTITY_AS}" "$APPSTORE_APP" \
    || echo "    ⚠ App Store 签名失败：确认钥匙串已安装 Apple Distribution 证书"
  ok "App Store 版已签名"
fi

# ========== 3. 原生 Swift 版 ==========
log "构建原生 Swift 版"
bash "$PROJECT_DIR/scripts/build_swift.sh" || echo "    ⚠ Swift 版构建失败（不影响其他两版）"
SWIFT_APP="$PROJECT_DIR/swift/.build/OctoShrink_swift.app"

# ========== 4. 报告 ==========
echo ""
log "🎉 三版构建完成！"
echo "    Direct       : $DIRECT_RENAMED"
echo "    App Store    : $APPSTORE_APP"
if [ -d "$SWIFT_APP" ]; then
  echo "    Swift Native : $SWIFT_APP"
else
  echo "    Swift Native : (构建失败)"
fi
echo "    Direct 大小      : $(du -sh "$DIRECT_RENAMED" | awk '{print $1}')"
echo "    App Store 大小   : $(du -sh "$APPSTORE_APP" | awk '{print $1}')"
if [ -d "$SWIFT_APP" ]; then
  echo "    Swift 大小       : $(du -sh "$SWIFT_APP" | awk '{print $1}')"
fi
