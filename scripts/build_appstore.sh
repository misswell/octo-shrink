#!/bin/bash
# OctoShrink App Store 构建脚本（产物线：appstore = inproc-backends）
#
# 与 scripts/notarize.sh 完全独立。走进程内 Rust 库、沙盒 entitlements、
# Apple Distribution 证书，产物是 .pkg（productbuild archive），待 Transporter 上传。
#
# 规则（见 AGENTS.md）：本脚本不依赖 scripts/notarize.sh，不复制内置 CLI / dylib，
# 且送审前必须通过下面的 bundle 自检（包里除主程序外不许有第三方 Mach-O）。

set -euo pipefail

# Cargo 1.90.0 regression：panic=abort 会让 proc-macro（equator-macro）的 dylib
# metadata 损坏，rustc 报 E0463 "can't find crate for equator_macro"。
# 用 panic=unwind 绕过，仅 appstore 线，不影响默认线（notarize.sh 仍用 abort）。
export CARGO_PROFILE_RELEASE_PANIC=unwind

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$PROJECT_DIR/src-tauri"
APP_NAME="OctoShrink"
APP="$TAURI_DIR/target/release/bundle/macos/$APP_NAME.app"
BUNDLE_ID="com.misswell.octoshrink.appstore"
ENTITLEMENTS="$TAURI_DIR/entitlements-appstore.plist"
CONF="$TAURI_DIR/tauri.conf.appstore.json"
APP_VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONF" | head -1)"

log()  { echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

[ -f "$ENTITLEMENTS" ] || fail "找不到 App Store entitlements：$ENTITLEMENTS"
[ -f "$CONF" ] || fail "找不到 App Store 配置：$CONF"
[ -n "${APP_VERSION}" ] || fail "无法从 App Store 配置读取版本号：$CONF"

# ---------- 1. 构建（appstore feature，不复用 default） ----------
log "cargo tauri build --bundles app --features appstore（进程内 Rust 库，无外部 CLI/dylib）"
# 用 tauri.conf.appstore.json 作为配置基准（identifier=appstore Bundle ID）
cd "$TAURI_DIR"
cargo tauri build --bundles app --features appstore --config "$CONF" -- --no-default-features \
  || fail "构建失败"
[ -d "$APP" ] || fail "构建产物不存在：$APP"
ok "$APP"

# 复制前端文件到 .app/Contents/Resources/（Tauri --config 模式下 frontendDist 不自动复制）
cp -R "$PROJECT_DIR/frontend/." "$APP/Contents/Resources/" \
  || fail "复制前端文件失败"
ok "前端文件已复制到 .app"

# ---------- 1.5 bundle 自检（送审前必须干净）----------
# 沙盒线一切编码都在本进程内：包里不许有第三方可执行文件 / dylib，
# 引擎源码里不许有 spawn CLI 的写法（注释里提到这些词不算）。
foreign=$(find "$APP/Contents" \( -name '*.dylib' -o -path '*/Resources/bin/*' \) -type f 2>/dev/null || true)
if [ -n "$foreign" ]; then
  echo "$foreign" >&2
  fail "App Store 包里混进了外部可执行文件/dylib（沙盒线必须全进程内）"
fi
# 守的不变量是"MacOS 下只有唯一一个主程序"，与它叫什么名字无关：Tauri 只把 .app
# 目录建成 productName（OctoShrink），可执行文件仍是 Cargo 包名（octoshrink），
# 按 $APP_NAME 比对会把主程序自己判成"额外可执行文件"，自检就永久失败了。
binaries=$(find "$APP/Contents/MacOS" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$binaries" != "1" ]; then
  find "$APP/Contents/MacOS" -mindepth 1 >&2
  fail "Contents/MacOS 必须只有唯一一个主程序（当前 $binaries 项）"
fi
spawns=$(sed -n '1,/#\[cfg(test)\]/p' "$TAURI_DIR/src/engine_inproc.rs" \
  | sed 's://.*::' \
  | grep -nE 'find_tool|make_command|cli_to_file|Command::new' || true)
if [ -n "$spawns" ]; then
  echo "$spawns" >&2
  fail "engine_inproc.rs 出现了 spawn CLI 的写法，沙盒线必须全部进程内"
fi
ok "bundle 自检通过（无外部可执行文件、引擎无 spawn）"

# ---------- 2. Apple Distribution 签名（hardened runtime + sandbox entitlements）----------
# 前置：在钥匙串安装 "Apple Distribution: <name>" 证书（Apple Developer > Certificates > +）。
SIGN_IDENTITY="${APPSTORE_SIGN_IDENTITY:-Apple Distribution: Guofeng Liu (U8U443D7ZL)}"
log "codesign: $SIGN_IDENTITY + hardened runtime + entitlements"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP" \
  || fail "签名失败：确认钥匙串已安装 Apple Distribution 证书"
ok "$APP 已签名"

# ---------- 3. productbuild 打包 .pkg ----------
PKG="$PROJECT_DIR/OctoShrink-${APP_VERSION}.pkg"
INSTALLER_IDENTITY="${APPSTORE_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Guofeng Liu (U8U443D7ZL)}"
log "productbuild: ${PKG}（installer: ${INSTALLER_IDENTITY}）"
xcrun productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG" \
  || fail "productbuild 失败：确认有 3rd Party Mac Developer Installer 证书"
ok "${PKG}"

# ---------- 4. 上传 App Store Connect ----------
echo ""
log "✅ 产物就绪：$PKG"
log "上传方式（二选一）："
log "  a. 打开 Transporter.app，拖入 $PKG 上传（推荐）"
log "  b. xcrun altool --upload-app -f \"$PKG\" -t macOS -u \"<apple_id>\" -p \"<app_specific_password>\""
log "上传后在 App Store Connect 选 build 提交审核（1-3 周）。"
