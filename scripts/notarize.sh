#!/bin/bash
# OctoShrink 分发管线（构建 + 签名 + 公证 + 装订）
# 镜像已签名公证的 OctoPilot 方案：Team U8U443D7ZL / hardened runtime /
# disable-library-validation / notarized + stapled / arm64-only。
#
# 用法：
#   bash scripts/notarize.sh                  # 构建 + 签名 + 公证 + 装订
#   SIGN_ONLY=1 bash scripts/notarize.sh      # 构建 + 签名，跳过公证
# 环境变量（可选覆盖）：
#   SIGNING_IDENTITY          指定 codesign 签名身份；默认自动检测 Developer ID Application
#   NOTARY_PROFILE            notarytool keychain 凭据 profile（推荐：先 notarytool store-credentials）
#   APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID   不用 profile 时的公证凭据
#   SKIP_BUILD=1              跳过 cargo tauri build，复用已有 .app
#   VERBOSE=1                 输出签名详情

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$PROJECT_DIR/src-tauri"
APP_NAME="OctoShrink"
APP="$TAURI_DIR/target/release/bundle/macos/$APP_NAME.app"
BUNDLE_ID="com.misswell.octoshrink"
ENTITLEMENTS="$TAURI_DIR/entitlements.plist"
DEFAULT_TEAM_ID="U8U443D7ZL"

log()  { echo "==> $*"; }
ok()   { echo "    ✓ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
[ -f "$ENTITLEMENTS" ] || fail "找不到 entitlements：$ENTITLEMENTS"

# 检测 Developer ID 签名身份
if [ -z "${SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)"
fi
[ -n "${SIGNING_IDENTITY:-}" ] || {
  echo "✗ 未检测到 Developer ID Application 签名身份，可能存在以下原因之一。" >&2
  echo "" >&2
  echo "  [1] 本机尚未创建/安装 Developer ID Application 证书（最常见）。" >&2
  echo "      → 付费 Apple Developer Program 成员可在 Xcode：" >&2
  echo "        Settings → Accounts → 选你的 Apple ID → Manage Certificates…" >&2
  echo "        → 左下 『+』 → Developer ID Application" >&2
  echo "        或 developer.apple.com → Certificates, Identifiers & Profiles 新建并双击安装。" >&2
  echo "      → 验证：security find-identity -v -p codesigning 应看到 'Developer ID Application: ... (U8U443D7ZL)'" >&2
  echo "" >&2
  echo "  [2] 钥匙串搜索列表已损坏（本机的表现：security list-keychains 报 'errSecParam'）。" >&2
  echo "      → 一次性修复（重置为默认并重启）：" >&2
  echo "        defaults delete com.apple.security DLDBSearchList" >&2
  echo "        然后注销/重启，再用 Keychain Access 确认 login 钥匙串可见。" >&2
  echo "" >&2
  echo "  [3] 仍无法定位，可显式传入签名身份名后运行：" >&2
  echo "      SIGNING_IDENTITY='Developer ID Application: Your Name (U8U443D7ZL)' NOTARY_PROFILE=octoshrink-notary $0" >&2
  echo "" >&2
  exit 2
}
log "签名身份：$SIGNING_IDENTITY"

# ---------- 1. 构建 ----------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "cargo tauri build --bundles app（release, arm64, 不由 Tauri 自动签名；DMG 由本脚本后续用 hdiutil 生成）"
  # 只构建 .app，避开 Tauri 自带的 create-dmg 步骤（该步骤在新版 create-dmg 上会因参数不匹配而失败）
  ( cd "$TAURI_DIR" && cargo tauri build --bundles app ) || fail "cargo tauri build 失败"
fi
[ -d "$APP" ] || fail "构建产物不存在：$APP（请先 SKIP_BUILD=0 跑一次构建）"

# ---------- 2. 打包内置工具到 .app ----------
log "复制内置 CLI 工具和动态库到 .app/Contents/Resources"
RES_DIR="$APP/Contents/Resources"
BIN_DIR="$RES_DIR/bin"
LIB_DIR="$RES_DIR/lib"
mkdir -p "$BIN_DIR" "$LIB_DIR"
SRC_BIN="$TAURI_DIR/resources/bin"
SRC_LIB="$TAURI_DIR/resources/lib"
[ -d "$SRC_BIN" ] || fail "缺少内置工具源：$SRC_BIN"
[ -d "$SRC_LIB" ] || fail "缺少内置库源：$SRC_LIB"
tool_count=0
for tool in "$SRC_BIN"/*; do
  [ -f "$tool" ] || continue
  cp "$tool" "$BIN_DIR/$(basename "$tool")"
  chmod 755 "$BIN_DIR/$(basename "$tool")"
  tool_count=$((tool_count+1))
done
ok "$tool_count 个 CLI 工具"
lib_count=0
for lib in "$SRC_LIB"/*.dylib; do
  [ -f "$lib" ] || continue
  cp "$lib" "$LIB_DIR/$(basename "$lib")"
  chmod 755 "$LIB_DIR/$(basename "$lib")"
  lib_count=$((lib_count+1))
done
ok "$lib_count 个动态库"

# ---------- 3. 签名（先叶子后根：dylib → bin → 主程序） ----------
CS_OPTS=( --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" )
[ "${VERBOSE:-0}" = "1" ] && CS_OPTS=( --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" --verbose=4 )

log "签名内置动态库"
for lib in "$LIB_DIR"/*.dylib; do
  [ -f "$lib" ] || continue
  codesign "${CS_OPTS[@]}" "$lib" >/dev/null 2>&1 || codesign "${CS_OPTS[@]}" "$lib"
  ok "$(basename "$lib")"
done

log "签名内置 CLI 工具"
for bin in "$BIN_DIR"/*; do
  [ -f "$bin" ] || continue
  codesign "${CS_OPTS[@]}" "$bin" >/dev/null 2>&1 || codesign "${CS_OPTS[@]}" "$bin"
  ok "$(basename "$bin")"
done

log "签名主程序 $APP_NAME.app"
# 如有辅助程序/框架，先逐个签名（本应用无 Contents/Frameworks、无 Helper）
find "$APP/Contents" -type d \( -name "*.app" -o -name "*.framework" \) -prune -exec sh -c '
  for d; do codesign --force --options runtime --entitlements "$0" --sign "$1" "$d" >/dev/null 2>&1; done
' "$ENTITLEMENTS" "$SIGNING_IDENTITY" {} + 2>/dev/null || true

codesign "${CS_OPTS[@]}" "$APP" >/dev/null 2>&1 || codesign "${CS_OPTS[@]}" "$APP"
ok "$APP_NAME.app 已签名（hardened runtime + entitlements）"

# ---------- 4. 校验签名 ----------
log "校验签名与 Gatekeeper"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
if spctl -a -vvv -t exec "$APP" 2>&1 | tee /tmp/octoshrink_spctl.log | grep -q "accepted"; then
  ok "Gatekeeper 接受"
else
  echo "    ⚠ spctl 评估（未公证前可能显示 rejected，公证装订后会通过）：" >&2
  sed 's/^/      /' /tmp/octoshrink_spctl.log
fi

echo ""
log "应用大小：$(du -sh "$APP" | awk '{print $1}')"

# ---------- 5. 仅签名模式 ----------
if [ "${SIGN_ONLY:-0}" = "1" ]; then
  echo ""
  log "SIGN_ONLY=1：跳过公证，签名产物已生成：$APP"
  exit 0
fi

# ---------- 6. 公证凭据前置检查 ----------
TEAM_ID="${APPLE_TEAM_ID:-$DEFAULT_TEAM_ID}"
if [ -z "${NOTARY_PROFILE:-}" ] && [ -z "${APPLE_ID:-}" ]; then
  echo "✗ 未提供公证凭据。" >&2
  echo "  方式 A（推荐）：先执行一次 'xcrun notarytool store-credentials <profile>'，然后 NOTARY_PROFILE=<profile> $0" >&2
  echo "  方式 B：设置 APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID（=U8U443D7ZL）后运行" >&2
  echo "  本地已签名产物保留在：$APP" >&2
  exit 3
fi

# ---------- 7. 制作 DMG ----------
STAGING="$(mktemp -d -t octoshrink_dmg)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$TAURI_DIR/target/release/bundle/macos/$APP_NAME-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")-macos.dmg"
log "制作 DMG：$(basename "$DMG")"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign "${CS_OPTS[@]}" --no-strict "$DMG" >/dev/null 2>&1 || true
ok "$(basename "$DMG")"

# ---------- 8. 提交公证 ----------
log "提交 Apple 公证（notarytool --wait）"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
fi

# ---------- 9. 装订公证票据 ----------
log "装订公证票据"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
ok "stapled"

log "校验装订"
xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    /'

echo ""
log "🎉 分发完成！"
echo "    .app : $APP"
echo "    .dmg : $DMG"
echo "    大小 : $(du -h "$DMG" | awk '{print $1}')"
