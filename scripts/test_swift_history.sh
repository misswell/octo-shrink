#!/bin/bash
# scripts/test_swift_history.sh —— Swift 线历史 / 原图备份 / 暂停 / CPU 上限自检
#
# Swift 产物线用 swiftc 直接编译，没有 Package.swift 测试 target，
# 所以这里把待测源码和 swift/Tests/HistoryStoreCheck/main.swift 编成一个
# 临时可执行文件跑断言（覆盖持久化、文件操作和真实并发，这些必须真跑）。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_DIR="$PROJECT_DIR/swift"
SRC_DIR="$SWIFT_DIR/Sources/OctoShrinkSwift"
OUT_BIN="$(mktemp -d)/octoshrink-history-check"

log() { echo "==> $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ─── 措辞红线：报的是并行预算，不是承诺绑定哪几个核心（方案 §63） ────────────
# 只看用户可见的字符串，注释里正是在解释这条禁令。
log "检查 CPU 文案没有承诺绑定核心"
copy_offenders=$(grep -rInE '使用 [0-9]+ 个性能核|绑定.{0,4}(性能核|核心)' "$SRC_DIR" \
  | grep -vE ':[0-9]+: *(//|\*|/\*)' || true)
if [ -n "$copy_offenders" ]; then
  echo "$copy_offenders" >&2
  fail "Swift 源码出现「使用 N 个性能核」这类承诺绑定核心的措辞"
fi

log "编译 Swift 历史自检"
xcrun swiftc \
  -O \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$OUT_BIN" \
  "$SRC_DIR/Models/CompressOptions.swift" \
  "$SRC_DIR/Models/CompressResult.swift" \
  "$SRC_DIR/Services/HistoryStore.swift" \
  "$SRC_DIR/Services/OutputTransactionStore.swift" \
  "$SRC_DIR/Services/SystemInfo.swift" \
  "$SRC_DIR/Services/CompressionScheduler.swift" \
  "$SRC_DIR/Engine/CLIRunner.swift" \
  "$SWIFT_DIR/Tests/HistoryStoreCheck/main.swift"

log "运行 Swift 历史自检"
"$OUT_BIN"
