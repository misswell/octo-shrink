#!/bin/bash
# scripts/package_swift_dmg.sh — Swift 原生版 DMG 打包管线
#
# 用法：
#   bash scripts/package_swift_dmg.sh                    # 构建 + 签名 + DMG
#   SKIP_BUILD=1 bash scripts/package_swift_dmg.sh       # 复用已有 .app，直接签名 + DMG
#   NOTARIZE=1 bash scripts/package_swift_dmg.sh         # 构建 + 签名 + DMG + 公证 + 装订
#   SIGN_ONLY=1 bash scripts/package_swift_dmg.sh        # 仅签名，不打包 DMG
#
# 环境变量：
#   SIGNING_IDENTITY   签名身份（默认自动检测 Developer ID Application）
#   NOTARY_PROFILE     公证凭据 profile（默认 octoshrink-notary）

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OctoShrink"
APP="$PROJECT_DIR/swift/.build/${APP_NAME}_swift.app"
BUNDLE_ID="com.misswell.octoshrink.swift"
ENTITLEMENTS="$PROJECT_DIR/swift/entitlements.plist"
DEFAULT_TEAM_ID="U8U443D7ZL"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_NAME="${APP_NAME}_swift-${VERSION}-macos.dmg"
DMG_DIR="$PROJECT_DIR/swift/.build"
DMG="$DMG_DIR/$DMG_NAME"

log()  { echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ---------- 0. 构建 ----------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "构建 Swift 版 .app"
  bash "$PROJECT_DIR/scripts/build_swift.sh" || fail "Swift 构建失败"
fi
[ -d "$APP" ] || fail "产物不存在：$APP（先跑一次构建或去掉 SKIP_BUILD=1）"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DMG_NAME="${APP_NAME}_swift-${VERSION}-macos.dmg"
DMG="$DMG_DIR/$DMG_NAME"
ok "版本 $VERSION · $(du -sh "$APP" | awk '{print $1}')"

# ---------- 1. 签名 ----------
if [ -z "${SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)"
fi

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  log "签名：$SIGNING_IDENTITY"
  CS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY")

  # 叶子优先：dylib → CLI → 主程序
  for lib in "$APP/Contents/Resources/lib/"*.dylib; do
    [ -f "$lib" ] && codesign "${CS[@]}" "$lib" >/dev/null 2>&1 || true
  done
  for bin in "$APP/Contents/Resources/bin/"*; do
    [ -f "$bin" ] && codesign "${CS[@]}" "$bin" >/dev/null 2>&1 || true
  done
  codesign "${CS[@]}" "$APP" || fail "主程序签名失败"
  ok "已签名"

  # 校验
  codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
else
  echo "    ⚠ 未检测到 Developer ID 证书，跳过签名（产物可本地运行，但分发需签名）"
  CS=()
fi

# ---------- 2. 仅签名模式 ----------
if [ "${SIGN_ONLY:-0}" = "1" ]; then
  echo ""
  log "SIGN_ONLY=1：跳过 DMG"
  exit 0
fi

# ---------- 3. 制作 DMG ----------
log "制作 DMG"
STAGING="$(mktemp -d -t octoshrink_swift_dmg)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "${APP_NAME} (Swift)" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
if [ ${#CS[@]} -gt 0 ]; then
  codesign "${CS[@]}" --no-strict "$DMG" >/dev/null 2>&1 || true
fi
ok "$DMG_NAME ($(du -h "$DMG" | awk '{print $1}'))"

# ---------- 4. 公证（可选）----------
if [ "${NOTARIZE:-0}" = "1" ]; then
  NOTARY_PROFILE="${NOTARY_PROFILE:-octoshrink-notary}"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "    ⚠ 钥匙串未找到公证凭据 profile: $NOTARY_PROFILE，跳过公证" >&2
    echo "      本地 DMG 已生成：$DMG"
    exit 0
  fi
  log "提交 Apple 公证（notarytool --wait）"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  log "装订公证票据"
  xcrun stapler staple "$APP"
  xcrun stapler staple "$DMG"
  ok "stapled"
fi

# ---------- 5. 报告 ----------
echo ""
log "🎉 Swift 版打包完成！"
echo "    .app : $APP"
echo "    .dmg : $DMG"
echo "    大小 : $(du -h "$DMG" | awk '{print $1}')"
