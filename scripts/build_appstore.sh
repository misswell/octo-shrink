#!/bin/bash
# OctoShrink App Store 构建脚本（产物线：appstore = inproc-backends）
#
# 与 scripts/notarize.sh 完全独立。走进程内 Rust 库、沙盒 entitlements、
# Apple Distribution 证书，产物是 .pkg（productbuild archive），待 Transporter 上传。
#
# 规则（见 AGENTS.md）：本脚本不依赖 scripts/notarize.sh，不复制内置 CLI / dylib。
# 当前进度为骨架占位：仅做 cargo build 检验，签名/打包/上传部分待 Apple Distribution
# 证书就绪后补齐。先保证 --features appstore 能跑通编译。

set -euo pipefail

# Cargo 1.90.0 regression：panic=abort 会让 proc-macro（equator-macro）的 dylib
# metadata 损坏，rustc 报 E0463 "can't find crate for equator_macro"。
# 用 panic=unwind 绕过，仅 appstore 线，不影响默认线（notarize.sh 仍用 abort）。
export CARGO_PROFILE_RELEASE_PANIC=unwind

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$PROJECT_DIR/src-tauri"
APP_NAME="OctoShrink"
APP_VERSION="2.2.1"
APP="$TAURI_DIR/target/release/bundle/macos/$APP_NAME.app"
BUNDLE_ID="com.misswell.octoshrink.appstore"
ENTITLEMENTS="$TAURI_DIR/entitlements-appstore.plist"
CONF="$TAURI_DIR/tauri.conf.appstore.json"

log()  { echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

[ -f "$ENTITLEMENTS" ] || fail "找不到 App Store entitlements：$ENTITLEMENTS"
[ -f "$CONF" ] || fail "找不到 App Store 配置：$CONF"

# ---------- 1. 构建（appstore feature，不复用 default） ----------
log "cargo tauri build --bundles app --features appstore（进程内 Rust 库，无外部 CLI/dylib）"
# 用 tauri.conf.appstore.json 作为配置基准（identifier=appstore Bundle ID）
cd "$TAURI_DIR"
cargo tauri build --bundles app --features appstore --config "$CONF" || fail "构建失败"
[ -d "$APP" ] || fail "构建产物不存在：$APP"
ok "$APP"

# 复制前端文件到 .app/Contents/Resources/（Tauri --config 模式下 frontendDist 不自动复制）
cp -R "$PROJECT_DIR/frontend/." "$APP/Contents/Resources/" \
  || fail "复制前端文件失败"
ok "前端文件已复制到 .app"

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
log "productbuild: ${PKG}（installer: $INSTALLER_IDENTITY）"
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
