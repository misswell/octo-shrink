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
    [ -f "${intel_file}" ] || {
      echo "Missing Intel counterpart: ${relative_path}" >&2
      exit 1
    }
    file "${intel_file}" | grep -q 'Mach-O' || {
      echo "Intel counterpart is not Mach-O: ${relative_path}" >&2
      exit 1
    }
    merged_file="$(mktemp /tmp/octoshrink-universal.XXXXXX)"
    lipo -create "${arm_file}" "${intel_file}" -output "${merged_file}"
    chmod "$(stat -f '%Lp' "${output_file}")" "${merged_file}"
    mv "${merged_file}" "${output_file}"
  fi
done < <(find "${ARM_APP}" -type f -print0)

while IFS= read -r -d '' binary; do
  if file "${binary}" | grep -q 'Mach-O'; then
    lipo "${binary}" -verify_arch arm64 x86_64
    codesign --force --sign - "${binary}"
  fi
done < <(find "${OUTPUT_APP}/Contents" -type f -print0)
codesign --force --deep --sign - "${OUTPUT_APP}"
codesign --verify --deep --strict "${OUTPUT_APP}"

echo "Universal app created: ${OUTPUT_APP}"
