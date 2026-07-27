#!/bin/bash
# Collect the current Mac architecture's Homebrew CLI tools and rewrite their
# non-system dylib dependencies so the app bundle is self-contained.

set -euo pipefail

DEST_ROOT="${1:-$(cd "$(dirname "$0")/../src-tauri/resources" && pwd)}"
BIN_DIR="${DEST_ROOT}/bin"
LIB_DIR="${DEST_ROOT}/lib"

command -v dylibbundler >/dev/null || {
  echo "dylibbundler is required (brew install dylibbundler)" >&2
  exit 1
}

mkdir -p "${BIN_DIR}" "${LIB_DIR}"
find "${BIN_DIR}" -mindepth 1 -maxdepth 1 -type f -delete
find "${LIB_DIR}" -mindepth 1 -maxdepth 1 -type f -delete

for tool in pngquant oxipng cjpeg gifsicle cwebp cjxl avifenc; do
  source_path="$(command -v "${tool}" || true)"
  if [ -z "${source_path}" ]; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
  cp -L "${source_path}" "${BIN_DIR}/${tool}"
  chmod 755 "${BIN_DIR}/${tool}"
  dylibbundler -od -b -x "${BIN_DIR}/${tool}" -d "${LIB_DIR}" \
    -p @executable_path/../lib >/dev/null
done

expected_arch="$(uname -m)"
for binary in "${BIN_DIR}"/* "${LIB_DIR}"/*.dylib; do
  [ -f "${binary}" ] || continue
  file "${binary}" | grep -q "${expected_arch}" || {
    echo "Architecture mismatch: ${binary}" >&2
    exit 1
  }
done

echo "Collected macOS tools for ${expected_arch}: ${DEST_ROOT}"
