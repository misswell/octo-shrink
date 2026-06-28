#!/bin/bash
# Octor Compressor 打包脚本
# 在 cargo tauri build 之后执行，将 CLI 工具和动态库复制到 .app bundle
# 工具保持原始状态（不修改路径、不重新签名），通过 DYLD_FALLBACK_LIBRARY_PATH 加载库

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

echo "📦 将 CLI 工具打包到 .app bundle（保持原始状态，不修改签名）..."

# 创建目录
mkdir -p "$BIN_DIR" "$LIB_DIR"

# 复制二进制文件（原始文件，不修改）
echo "  复制 CLI 工具..."
for tool in pngquant oxipng cjpeg gifsicle cwebp cjxl avifenc; do
  src="$PROJECT_DIR/src-tauri/resources/bin/$tool"
  if [ -f "$src" ]; then
    cp "$src" "$BIN_DIR/$tool"
    chmod 755 "$BIN_DIR/$tool"
    echo "    ✓ $tool"
  fi
done

# 复制动态库（原始文件，不修改）
echo "  复制动态库..."
lib_count=0
for lib in "$PROJECT_DIR/src-tauri/resources/lib/"*.dylib; do
  if [ -f "$lib" ]; then
    lib_name=$(basename "$lib")
    cp "$lib" "$LIB_DIR/$lib_name"
    chmod 644 "$LIB_DIR/$lib_name"
    lib_count=$((lib_count + 1))
  fi
done
echo "    ✓ $lib_count 个库文件"

# 显示最终大小
echo ""
echo "✅ 打包完成！"
echo "   .app 大小: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
echo "   内置工具: $(ls "$BIN_DIR" | wc -l | tr -d ' ') 个"
echo "   内置库: $lib_count 个"
echo ""
echo "   工具通过 DYLD_FALLBACK_LIBRARY_PATH 加载内置库，无需用户安装任何依赖"
