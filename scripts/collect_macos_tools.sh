#!/bin/bash
# Collect the current Mac architecture's Homebrew CLI tools and rewrite their
# non-system dylib dependencies so the app bundle is self-contained.

set -euo pipefail

DEST_ROOT="${1:-$(cd "$(dirname "$0")/../src-tauri/resources" && pwd)}"
BIN_DIR="${DEST_ROOT}/bin"
LIB_DIR="${DEST_ROOT}/lib"

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
done

resolve_dependency() {
  local binary="$1"
  local dependency="$2"
  local loader_dir
  local candidate
  loader_dir="$(dirname "${binary}")"

  case "${dependency}" in
    /System/*|/usr/lib/*)
      return 1
      ;;
    /*)
      [ -f "${dependency}" ] && { printf '%s\n' "${dependency}"; return 0; }
      ;;
    @loader_path/*)
      candidate="${loader_dir}/${dependency#@loader_path/}"
      [ -f "${candidate}" ] && { printf '%s\n' "${candidate}"; return 0; }
      ;;
    @executable_path/*)
      candidate="${BIN_DIR}/${dependency#@executable_path/}"
      [ -f "${candidate}" ] && { printf '%s\n' "${candidate}"; return 0; }
      ;;
    @rpath/*)
      while IFS= read -r rpath; do
        rpath="${rpath//@loader_path/${loader_dir}}"
        rpath="${rpath//@executable_path/${BIN_DIR}}"
        candidate="${rpath}/${dependency#@rpath/}"
        [ -f "${candidate}" ] && { printf '%s\n' "${candidate}"; return 0; }
      done < <(otool -l "${binary}" | awk '/path .*\(offset/{print $2}')
      ;;
  esac

  if command -v brew >/dev/null; then
    candidate="$(find "$(brew --cellar)" -name "$(basename "${dependency}")" -print -quit)"
    [ -n "${candidate}" ] && { printf '%s\n' "${candidate}"; return 0; }
  fi

  echo "Unable to resolve dependency ${dependency} for ${binary}" >&2
  return 2
}

# Process newly copied libraries in subsequent passes. This avoids
# dylibbundler's unbounded retry loop when Homebrew uses @rpath install names
# (notably mozjpeg's @rpath/libjpeg.8.dylib on macOS 26 runners).
while :; do
  copied=0
  for binary in "${BIN_DIR}"/* "${LIB_DIR}"/*.dylib; do
    [ -f "${binary}" ] || continue
    while IFS= read -r dependency; do
      [ -n "${dependency}" ] || continue
      status=0
      resolved="$(resolve_dependency "${binary}" "${dependency}")" || status=$?
      if [ "${status}" -eq 1 ]; then
        status=0
        continue
      fi
      [ "${status}" -eq 0 ] || exit "${status}"
      destination="${LIB_DIR}/$(basename "${resolved}")"
      if [ ! -f "${destination}" ]; then
        cp -L "${resolved}" "${destination}"
        chmod 755 "${destination}"
        install_name_tool -id "@executable_path/../lib/$(basename "${destination}")" \
          "${destination}" 2>/dev/null
        copied=1
      fi
      install_name_tool -change "${dependency}" \
        "@executable_path/../lib/$(basename "${destination}")" "${binary}" 2>/dev/null
      status=0
    done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')
  done
  [ "${copied}" -eq 1 ] || break
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
