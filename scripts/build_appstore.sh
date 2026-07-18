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

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$PROJECT_DIR/src-tauri"
APP_NAME="OctoShrink"
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
TAURI_CONF="$CONF" cargo tauri build --bundles app --features appstore || fail "构建失败"
[ -d "$APP" ] || fail "构建产物不存在：$APP"
ok "$APP"

# ---------- 2. 当前状态：骨架占位 ----------
# 以下步骤待 Apple Distribution 证书签发后补齐，骨架阶段到此为止。
#   a. 用 Apple Distribution + hardened runtime 重新签名（entitlements-appstore.plist）
#      codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
#        --sign "Apple Distribution: misswell@foxmail.com" "$APP"
#   b. 生成 .pkg: xcrun productbuild --component "$APP" /Applications ...
#   c. 用 Transporter / xcrun altool 上传到 App Store Connect（不走 notarytool）

echo ""
log "骨架阶段产物：$APP"
log "App Store 签名/打包/上传待 Apple Distribution 证书就绪后补齐。"
log "下一步见 docs/APPSTORE_MIGRATION_PLAN.md（阶段 1-5）与 AGENTS.md。"
