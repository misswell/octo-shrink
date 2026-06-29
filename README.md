# 🐙 OctoShrink

> **免费开源的图片压缩神器** — 图片压缩神器，帮你的图片减减肥

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS·Windows·Linux-blue)](https://github.com/misswell/octo-shrink/releases)
[![Tauri](https://img.shields.io/badge/Tauri-2.x-orange)](https://tauri.app)

![章小压 · OctoShrink](assets/banner.png)

## 📸 截图

| 亮色模式 | 暗黑模式 |
|---------|---------|
| ![亮色模式](assets/screenshot-light.png) | ![暗黑模式](assets/screenshot-dark.png) |

![压缩对比](assets/compare.png)

## ✨ 特性

- 🎯 **智能算法选择** — 自动分析图片特征，从多个后端中选择最优算法
- 🚀 **多引擎支持** — 集成 pngquant、oxipng、mozjpeg (cjpeg)、gifsicle、cwebp、cjxl、avifenc 等 CLI 工具，以及 Rust `image` 引擎作为后备
- 📦 **批量处理** — 支持批量选择图片或拖入整个文件夹，自动递归处理子目录
- 🔄 **多种格式** — 支持 PNG、JPG、GIF、WebP、BMP 格式压缩
- 🆕 **现代格式输出** — 支持输出为 **AVIF** 和 **JPEG XL**（下一代 JPEG 标准）
- 📊 **实时对比** — 压缩前后体积、压缩率一目了然，支持滑动对比
- 🔓 **完全免费** — MIT 开源协议，无需购买激活码
- 🖥️ **原生体验** — 基于 **Tauri 2** 构建，体积仅 ~18MB，开箱即用
- 🔧 **内置工具链** — 所有 CLI 压缩工具已打包到应用内，无需用户额外安装
- ↩️ **恢复原图** — 压缩后不满意可一键恢复原始文件
- 🔄 **实时切换压缩率** — 对比时随时调整质量参数重新压缩，实时对比效果

## 🏗️ 技术架构

基于 **Tauri 2** 构建，后端使用 Rust，前端使用原生 HTML/CSS/JS（无构建步骤）。

### 压缩引擎

| 格式 | 主要工具 | 后备方案 |
|------|---------|---------|
| PNG | pngquant (有损) / oxipng (无损) | Rust image 引擎 |
| JPEG | cjpeg (mozjpeg) | Rust image 引擎 |
| GIF | gifsicle | — |
| WebP | cwebp | — |
| AVIF | avifenc | — |
| JPEG XL | cjxl | — |

### 内置工具

所有 CLI 工具及其依赖库均已打包到应用内（`Contents/Resources/bin/` 和 `Contents/Resources/lib/`），通过 `DYLD_FALLBACK_LIBRARY_PATH` 环境变量加载，**无需用户安装任何依赖**。

## 🛠️ 开发

### 环境要求

- [Rust](https://rustup.rs/) 1.77+
- [Tauri CLI](https://tauri.app/) (`cargo install tauri-cli --version "^2.0"`)
- CLI 压缩工具（开发时需要，macOS 可通过 Homebrew 安装）：

```bash
brew install pngquant oxipng mozjpeg gifsicle webp jpeg-xl libavif
```

### 开发运行

```bash
# 开发模式
cargo tauri dev

# 或直接运行（无需 Tauri CLI）
cd src-tauri && cargo run

# 构建发布版本
cargo tauri build

# 将 CLI 工具打包到 .app（开箱即用）
bash scripts/package.sh
```

### 项目结构

```
octoshrink/
├── frontend/           # 前端（纯 HTML/CSS/JS，无构建步骤）
│   ├── index.html
│   ├── style.css
│   ├── app.js          # 使用 window.__TAURI__ 全局 API
│   └── octo-icon.png
├── src-tauri/          # Rust 后端
│   ├── src/
│   │   ├── main.rs     # 入口
│   │   ├── lib.rs      # Tauri 应用配置
│   │   ├── engine.rs   # 压缩引擎
│   │   └── commands.rs # Tauri 命令
│   ├── resources/      # 内置 CLI 工具和动态库
│   │   ├── bin/        # 7 个压缩工具
│   │   └── lib/        # 17 个依赖库
│   ├── icons/          # 应用图标
│   ├── tauri.conf.json # Tauri 配置
│   └── Cargo.toml      # Rust 依赖
├── scripts/
│   └── package.sh      # 打包脚本（将工具集成到 .app）
└── package.json
```

## 📄 License

MIT
