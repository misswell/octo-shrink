#!/bin/bash
# Sign, notarize, staple, and package the three Direct macOS distributions.
# Intended for the ephemeral keychain created by .github/workflows/release.yml.

set -euo pipefail

ARM_APP="${1:?arm64 app path required}"
INTEL_APP="${2:?x86_64 app path required}"
UNIVERSAL_APP="${3:?universal app path required}"
OUTPUT_DIR="${4:?output directory required}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="${ENTITLEMENTS:-${PROJECT_DIR}/src-tauri/entitlements.plist}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Guofeng Liu (U8U443D7ZL)}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:?SIGNING_KEYCHAIN is required}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
APPLE_ID="${APPLE_ID:?APPLE_ID is required}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"

for app in "${ARM_APP}" "${INTEL_APP}" "${UNIVERSAL_APP}"; do
  [ -d "${app}" ] || { echo "Missing app: ${app}" >&2; exit 1; }
done
[ -f "${ENTITLEMENTS}" ] || { echo "Missing entitlements: ${ENTITLEMENTS}" >&2; exit 1; }
security find-identity -v -p codesigning "${SIGNING_KEYCHAIN}" | grep -F "${SIGNING_IDENTITY}"
mkdir -p "${OUTPUT_DIR}"

log() { echo "==> $*"; }

verify_architectures() {
  local app="$1"
  shift
  local file_path
  local count=0

  while IFS= read -r -d '' file_path; do
    if file "${file_path}" | grep -q 'Mach-O'; then
      lipo "${file_path}" -verify_arch "$@"
      count=$((count + 1))
    fi
  done < <(find "${app}/Contents" -type f -print0)

  [ "${count}" -gt 0 ] || { echo "No Mach-O files found in ${app}" >&2; exit 1; }
  echo "    verified ${count} Mach-O files in $(dirname "${app}")"
}

verify_universal_architectures() {
  local app="$1"
  local file_path
  local archs
  local count=0

  while IFS= read -r -d '' file_path; do
    if file "${file_path}" | grep -q 'Mach-O'; then
      archs="$(lipo -archs "${file_path}")"
      case " ${archs} " in
        *" arm64 "*|*" x86_64 "*) ;;
        *)
          echo "Unexpected architecture(s) in ${file_path}: ${archs}" >&2
          exit 1
          ;;
      esac
      count=$((count + 1))
    fi
  done < <(find "${app}/Contents" -type f -print0)

  [ "${count}" -gt 0 ] || { echo "No Mach-O files found in ${app}" >&2; exit 1; }
  echo "    verified ${count} Mach-O files in $(dirname "${app}")"
}

sign_app() {
  local app="$1"
  local file_path
  local count=0
  local sign_options=(
    --force
    --options runtime
    --timestamp
    --entitlements "${ENTITLEMENTS}"
    --sign "${SIGNING_IDENTITY}"
  )

  while IFS= read -r -d '' file_path; do
    if file "${file_path}" | grep -q 'Mach-O'; then
      codesign "${sign_options[@]}" "${file_path}"
      count=$((count + 1))
    fi
  done < <(find "${app}/Contents" -type f -print0)

  codesign "${sign_options[@]}" "${app}"
  codesign --verify --deep --strict --verbose=2 "${app}"
  codesign -dv --verbose=2 "${app}" 2>&1 | grep -E 'Authority=|Timestamp='
  echo "    signed ${count} Mach-O files in $(dirname "${app}")"
}

create_dmg() {
  local app="$1"
  local arch="$2"
  local dmg="${OUTPUT_DIR}/OctoShrink_${RELEASE_TAG}_macos_${arch}.dmg"
  local staging
  staging="$(mktemp -d -t "octoshrink-${arch}")"

  ditto "${app}" "${staging}/OctoShrink.app"
  ln -s /Applications "${staging}/Applications"
  hdiutil create -volname OctoShrink -srcfolder "${staging}" -ov -format UDZO "${dmg}" >/dev/null
  codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${dmg}"
  rm -r "${staging}"
  echo "${dmg}"
}

notarize_dmg() {
  local dmg="$1"
  xcrun notarytool submit "${dmg}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait
}

log "Verify app architectures"
verify_architectures "${ARM_APP}" arm64
verify_architectures "${INTEL_APP}" x86_64
verify_universal_architectures "${UNIVERSAL_APP}"

log "Developer ID sign apps"
sign_app "${ARM_APP}"
sign_app "${INTEL_APP}"
sign_app "${UNIVERSAL_APP}"

log "Create signed DMGs"
ARM_DMG="$(create_dmg "${ARM_APP}" arm64)"
INTEL_DMG="$(create_dmg "${INTEL_APP}" x86_64)"
UNIVERSAL_DMG="$(create_dmg "${UNIVERSAL_APP}" universal)"

log "Submit three DMGs to Apple notarization"
notarize_dmg "${ARM_DMG}" &
arm_pid=$!
notarize_dmg "${INTEL_DMG}" &
intel_pid=$!
notarize_dmg "${UNIVERSAL_DMG}" &
universal_pid=$!

set +e
wait "${arm_pid}"
arm_status=$?
wait "${intel_pid}"
intel_status=$?
wait "${universal_pid}"
universal_status=$?
set -e

if [ "${arm_status}" -ne 0 ] || [ "${intel_status}" -ne 0 ] || [ "${universal_status}" -ne 0 ]; then
  echo "Notarization failed: arm64=${arm_status}, x86_64=${intel_status}, universal=${universal_status}" >&2
  exit 1
fi

log "Staple and validate notarization tickets"
for app in "${ARM_APP}" "${INTEL_APP}" "${UNIVERSAL_APP}"; do
  xcrun stapler staple "${app}"
  xcrun stapler validate "${app}"
  spctl -a -vvv -t exec "${app}"
done
for dmg in "${ARM_DMG}" "${INTEL_DMG}" "${UNIVERSAL_DMG}"; do
  xcrun stapler staple "${dmg}"
  xcrun stapler validate "${dmg}"
done

log "Create the stapled Universal updater archive"
tar -czf "${OUTPUT_DIR}/OctoShrink_${RELEASE_TAG}_macos_universal.app.tar.gz" \
  -C "$(dirname "${UNIVERSAL_APP}")" "$(basename "${UNIVERSAL_APP}")"

log "macOS release assets are signed, notarized, and stapled"
ls -lh "${OUTPUT_DIR}"
