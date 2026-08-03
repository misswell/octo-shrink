#!/bin/bash
# Merge two complete, architecture-matched app bundles into Universal 2.

set -euo pipefail

ARM_APP="${1:?arm64 app path required}"
INTEL_APP="${2:?x86_64 app path required}"
OUTPUT_APP="${3:?output app path required}"

[ -d "${ARM_APP}" ] || { echo "Missing arm64 app: ${ARM_APP}" >&2; exit 1; }
[ -d "${INTEL_APP}" ] || { echo "Missing x86_64 app: ${INTEL_APP}" >&2; exit 1; }

rm -rf "${OUTPUT_APP}"
ditto "${ARM_APP}" "${OUTPUT_APP}"

while IFS= read -r -d '' arm_file; do
  relative_path="${arm_file#${ARM_APP}/}"
  intel_file="${INTEL_APP}/${relative_path}"
  output_file="${OUTPUT_APP}/${relative_path}"
  if file "${arm_file}" | grep -q 'Mach-O'; then
    if [ ! -f "${intel_file}" ]; then
      case "${relative_path}" in
        */lib/*.dylib) echo "Keeping arm64-only resource: ${relative_path}" ;;
        *)
          echo "Missing Intel counterpart: ${relative_path}" >&2
          exit 1
          ;;
      esac
    elif file "${intel_file}" | grep -q 'Mach-O'; then
      merged_file="$(mktemp /tmp/octoshrink-universal.XXXXXX)"
      lipo -create "${arm_file}" "${intel_file}" -output "${merged_file}"
      chmod "$(stat -f '%Lp' "${output_file}")" "${merged_file}"
      mv "${merged_file}" "${output_file}"
    else
      echo "Intel counterpart is not Mach-O: ${relative_path}" >&2
      exit 1
    fi
  fi
done < <(find "${ARM_APP}" -type f -print0)

# Some dependencies are only used by one architecture (for example, cjxl may
# link libopenjph on arm64 but not on x86_64). Preserve those resources instead
# of requiring every Mach-O file to have a counterpart in both bundles.
while IFS= read -r -d '' intel_file; do
  relative_path="${intel_file#${INTEL_APP}/}"
  output_file="${OUTPUT_APP}/${relative_path}"
  if [ ! -e "${output_file}" ]; then
    case "${relative_path}" in
      */lib/*.dylib)
        mkdir -p "$(dirname "${output_file}")"
        ditto "${intel_file}" "${output_file}"
        echo "Keeping x86_64-only resource: ${relative_path}"
        ;;
      *)
        echo "Missing arm64 counterpart: ${relative_path}" >&2
        exit 1
        ;;
    esac
  fi
done < <(find "${INTEL_APP}" -type f -print0)

verify_macho_architectures() {
  local binary="$1"
  local archs
  archs="$(lipo -archs "${binary}")"
  case " ${archs} " in
    *" arm64 "*|*" x86_64 "*) ;;
    *)
      echo "Unexpected architecture(s) in ${binary}: ${archs}" >&2
      exit 1
      ;;
  esac
}

while IFS= read -r -d '' binary; do
  if file "${binary}" | grep -q 'Mach-O'; then
    verify_macho_architectures "${binary}"
    codesign --force --sign - "${binary}"
  fi
done < <(find "${OUTPUT_APP}/Contents" -type f -print0)
codesign --force --deep --sign - "${OUTPUT_APP}"
codesign --verify --deep --strict "${OUTPUT_APP}"

echo "Universal app created: ${OUTPUT_APP}"
