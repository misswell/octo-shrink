#!/bin/bash
# scripts/memory_stress.sh —— 多格式真实图缩小版内存压测（手动运行，不进常规门禁）
#
# 三步：
#   A. Direct 产物线的 CLI 子进程 RSS 峰值（ps 采样，捆绑工具 + 系统 dylib）
#   B. Rust 进程内引擎（App Store 线）三批压测：phys_footprint / 闸门观测
#   C. Swift 原生线进程内 ImageIO 三批压测（复用 scripts/test_swift_history.sh 的 [37] 组）
#
# 样本：PNG 噪声图 + sips 转 JPEG/GIF + 捆绑 cwebp/avifenc 转 WebP/AVIF。
# 用法：bash scripts/memory_stress.sh [--regen]
#   --regen 重建样本目录；否则复用已有的（默认 $TMPDIR/octoshrink-memory-stress）。
#   STRESS_PART=a|b|c 只跑其中一步（默认 all，三步都跑）。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLES_DIR="${OCTOSHRINK_STRESS_DIR:-${TMPDIR:-/tmp}/octoshrink-memory-stress}"
TOOLS="$PROJECT_DIR/src-tauri/resources/bin"

log() { echo "==> $*"; }

STRESS_PART="${STRESS_PART:-all}"
run_part() { [ "$STRESS_PART" = "all" ] || [ "$STRESS_PART" = "$1" ]; }

if [ "${1:-}" = "--regen" ] || [ ! -f "$SAMPLES_DIR/manifest.txt" ]; then
  log "生成多格式样本到 $SAMPLES_DIR"
  rm -rf "$SAMPLES_DIR"
  mkdir -p "$SAMPLES_DIR"
  python3 "$PROJECT_DIR/scripts/gen_stress_samples.py" "$SAMPLES_DIR" | tee "$SAMPLES_DIR/manifest.txt"
else
  log "复用已有样本目录 $SAMPLES_DIR（--regen 可重建）"
fi

# ── A. Direct 线：CLI 子进程 RSS 峰值 ─────────────────────────────────────
if run_part a; then
log "A. Direct 版子进程 RSS 峰值（ps 采样间隔 ~20ms）"
export DYLD_FALLBACK_LIBRARY_PATH="$PROJECT_DIR/src-tauri/resources/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
# 产物放进子目录：样本目录顶层会被 B/C 两线当作轮转输入，产物留在顶层就是多余样本。
CHILD_DIR="$SAMPLES_DIR/direct-children"
mkdir -p "$CHILD_DIR"

# 采样到进程退出，取居住内存峰值（KB → MiB）。20ms 粒度是下界：更短的尖峰可能漏采。
sample_peak() {
  local label="$1"
  shift
  local peak=0 pid rss status=0
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$rss" ] && [ "$rss" -gt "$peak" ]; then peak=$rss; fi
    sleep 0.02
  done
  wait "$pid" || status=$?
  printf '   %-30s peak RSS %6d MiB (exit %d)\n' "$label" $((peak / 1024)) "$status"
}

sample_peak "pngquant 4000×3000 PNG" \
  "$TOOLS/pngquant" --quality=65-80 --speed=3 --strip \
  --output "$CHILD_DIR/out-pngquant.png" -- "$SAMPLES_DIR/large-png-01.png"
sample_peak "oxipng -o3 4000×3000 PNG" \
  bash -c "cp '$SAMPLES_DIR/large-png-02.png' '$CHILD_DIR/oxipng-work.png' && exec '$TOOLS/oxipng' -o3 --strip safe '$CHILD_DIR/oxipng-work.png'"
sample_peak "cjpeg q75 4000×3000 PPM" \
  "$TOOLS/cjpeg" -quality 75 -optimize -progressive -outfile "$CHILD_DIR/out-cjpeg.jpg" "$SAMPLES_DIR/large-cjpeg-input.ppm"
sample_peak "cwebp q80 4000×3000 PNG" \
  "$TOOLS/cwebp" -q 80 -quiet "$SAMPLES_DIR/large-png-01.png" -o "$CHILD_DIR/out-cwebp.webp"
sample_peak "avifenc s8 2400×1800 PNG" \
  "$TOOLS/avifenc" -s 8 -q 60 "$SAMPLES_DIR/medium-png-01.png" "$CHILD_DIR/out-avifenc.avif"
sample_peak "gifsicle -O3 1200×900 GIF" \
  "$TOOLS/gifsicle" -O3 "$SAMPLES_DIR/small-gif-01.gif" -o "$CHILD_DIR/out-gifsicle.gif"
fi

# ── B. Rust 进程内（App Store 线）三批 ─────────────────────────────────────
if run_part b; then
log "B. Rust 进程内引擎三批压测（release，--features appstore）"
RUST_LOG="$SAMPLES_DIR/rust-stress.log"
(
  cd "$PROJECT_DIR/src-tauri"
  OCTOSHRINK_STRESS_DIR="$SAMPLES_DIR" \
    cargo test --release --features appstore --no-default-features --lib \
    memory_stress -- --ignored --nocapture
) 2>&1 | tee "$RUST_LOG"
grep -E '^\[stress\]|^test result' "$RUST_LOG" || true
fi

# ── C. Swift 原生线三批 ────────────────────────────────────────────────────
if run_part c; then
log "C. Swift 进程内 ImageIO 三批压测（复用历史自检 harness 的 [37] 组）"
SWIFT_LOG="$SAMPLES_DIR/swift-stress.log"
OCTOSHRINK_STRESS_DIR="$SAMPLES_DIR" \
  bash "$PROJECT_DIR/scripts/test_swift_history.sh" 2>&1 | tee "$SWIFT_LOG" | tail -30
grep -A8 '\[37\]' "$SWIFT_LOG" || true
fi

log "完成。样本与日志在 $SAMPLES_DIR（--regen 重建，测完可直接 rm -rf）"
