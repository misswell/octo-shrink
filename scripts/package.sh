#!/bin/bash
# Octor Compressor 打包脚本
# 在 cargo tauri build 之后执行，将 CLI 工具复制到 .app bundle

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="$PROJECT_DIR/src-tauri/target/release/bundle/macos/Octor Compressor.app"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "❌ .app bundle 不存在，请先运行 cargo tauri build"
  exit 1
fi

RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
LIB_DIR="$RESOURCES_DIR/lib"

echo "📦 将 CLI 工具打包到 .app bundle..."

# 创建目录
mkdir -p "$BIN_DIR" "$LIB_DIR"

# 复制二进制文件
echo "  复制 CLI 工具..."
for tool in pngquant oxipng cjpeg gifsicle cwebp cjxl avifenc; do
  src="$PROJECT_DIR/src-tauri/resources/bin/$tool"
  if [ -f "$src" ]; then
    cp "$src" "$BIN_DIR/$tool"
    chmod 755 "$BIN_DIR/$tool"
    echo "    ✓ $tool"
  fi
done

# 复制动态库
echo "  复制动态库..."
for lib in "$PROJECT_DIR/src-tauri/resources/lib/"*.dylib; do
  if [ -f "$lib" ]; then
    lib_name=$(basename "$lib")
    cp "$lib" "$LIB_DIR/$lib_name"
    chmod 644 "$LIB_DIR/$lib_name"
  fi
done
echo "    ✓ $(ls "$LIB_DIR" | wc -l | tr -d ' ') 个库文件"

# 修正动态库路径
echo "  修正动态库路径..."
python3 << 'PYEOF'
import subprocess, os, re

BIN_DIR = os.path.expandvars("$BIN_DIR").replace("$BIN_DIR", "")
# Use actual paths
import sys
bin_dir = sys.argv[1] if len(sys.argv) > 1 else ""
PYEOF

# 使用 Python 修正路径
python3 - "$BIN_DIR" "$LIB_DIR" << 'PYEOF'
import subprocess, os, sys, re

bin_dir = sys.argv[1]
lib_dir = sys.argv[2]

PREFIX = "/opt/homebrew/opt"
lib_files = set(os.listdir(lib_dir))

# 修正二进制文件
for bin_name in os.listdir(bin_dir):
    bin_path = os.path.join(bin_dir, bin_name)
    if not os.path.isfile(bin_path):
        continue
    result = subprocess.run(["otool", "-L", bin_path], capture_output=True, text=True)
    for line in result.stdout.split("\n")[1:]:
        if PREFIX in line or "@rpath/" in line:
            match = re.match(r'\s*(\S+)', line)
            if match:
                old_path = match.group(1)
                lib_name = os.path.basename(old_path)
                if lib_name in lib_files:
                    new_path = f"@executable_path/../lib/{lib_name}"
                    subprocess.run(["install_name_tool", "-change", old_path, new_path, bin_path], check=False)

# 修正库文件
for lib_name in lib_files:
    lib_path = os.path.join(lib_dir, lib_name)
    subprocess.run(["install_name_tool", "-id", f"@executable_path/../lib/{lib_name}", lib_path], check=False)
    result = subprocess.run(["otool", "-L", lib_path], capture_output=True, text=True)
    for line in result.stdout.split("\n")[1:]:
        if PREFIX in line or "@rpath/" in line:
            match = re.match(r'\s*(\S+)', line)
            if match:
                old_path = match.group(1)
                dep_name = os.path.basename(old_path)
                if dep_name in lib_files:
                    new_path = f"@executable_path/../lib/{dep_name}"
                    subprocess.run(["install_name_tool", "-change", old_path, new_path, lib_path], check=False)

print("    ✓ 路径已修正")
PYEOF

# 重新签名
echo "  重新签名..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null
echo "    ✓ 签名完成"

# 显示最终大小
echo ""
echo "✅ 打包完成！"
echo "   .app 大小: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
echo "   内置工具: $(ls "$BIN_DIR" | wc -l | tr -d ' ') 个"
echo "   内置库: $(ls "$LIB_DIR" | wc -l | tr -d ' ') 个"
