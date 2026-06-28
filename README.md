# 🐙 Octor Compressor

> **免费开源的图片压缩神器** — 图片压缩神器，帮你的图片减减肥

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue)](https://github.com/guofeng/octor-compressor/releases)
[![Tauri](https://img.shields.io/badge/Tauri-2.x-orange)](https://tauri.app)

## ✨ 特性

- 🎯 **智能算法选择** — 自动分析图片特征，从多个后端中选择最优算法
- 🚀 **多引擎支持** — 集成 pngquant、oxipng、mozjpeg (cjpeg)、gifsicle、cwebp、cjxl、avifenc 等 CLI 工具，以及 Rust `image` 引擎作为后备
- 📦 **批量处理** — 支持批量选择图片或拖入整个文件夹，自动递归处理子目录
- 🔄 **多种格式** — 支持 PNG、JPG、GIF、WebP、BMP 格式压缩
- 🆕 **现代格式输出** — 支持输出为 **AVIF** 和 **JPEG XL**（下一代 JPEG 标准）
- 📊 **实时对比** — 压缩前后体积、压缩率一目了然，支持滑动对比
- 🔓 **完全免费** — MIT 开源协议，无需购买激活码
- 🖥️ **桌面应用** — 基于 **Tauri 2** 构建，原生体验，体积仅 ~6MB（Electron 版本 ~200MB）
- ↩️ **恢复原图** — 压缩后不满意可一键恢复原始文件
- 🔄 **实时切换压缩率** — 对比时随时调整质量参数重新压缩，实时对比效果

## 🏗️ 技术架构

### Electron → Tauri 迁移

本项目已从 Electron 迁移至 **Tauri 2**，带来以下优势：

| 对比项 | Electron 版本 | Tauri 版本 |
|--------|-------------|-----------|
| 打包体积 | ~200MB | **~6MB** |
| 内存占用 | ~300MB | **~80MB** |
| 后端 | Node.js (sharp/squoosh) | **Rust** |
| 前端 | Chromium 渲染 | **系统 WebView** (WebKit) |
| 压缩引擎 | sharp + squoosh + CLI | **Rust image + CLI 工具** |

### 压缩引擎

| 格式 | 主要工具 | 后备方案 |
|------|---------|---------|
| PNG | pngquant (有损) / oxipng (无损) | Rust image 引擎 |
| JPEG | cjpeg (mozjpeg) | Rust image 引擎 |
| GIF | gifsicle | — |
| WebP | cwebp | — |
| AVIF | avifenc | — |
| JPEG XL | cjxl | — |

### CLI 工具安装

压缩依赖以下 CLI 工具（macOS 可通过 Homebrew 安装）：

```bash
brew install pngquant oxipng mozjpeg gifsicle webp jpeg-xl libavif
```

## 🛠️ 开发

### 环境要求

- [Rust](https://rustup.rs/) 1.77+
- [Tauri CLI](https://tauri.app/) (`cargo install tauri-cli --version "^2.0"`)
- CLI 压缩工具（见上方）

### 开发运行

```bash
# 安装 Tauri CLI
cargo install tauri-cli --version "^2.0"

# 开发模式
cargo tauri dev

# 或直接运行（无需 Tauri CLI）
cd src-tauri && cargo run

# 构建发布版本
cargo tauri build
```

### 项目结构

```
octor-compressor-tauri/
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
│   │   └── commands.rs # Tauri 命令（替代 Electron IPC）
│   ├── icons/          # 应用图标
│   ├── tauri.conf.json # Tauri 配置
│   └── Cargo.toml      # Rust 依赖
├── electron/           # 原 Electron 版本（参考）
└── package.json
```

## 📄 License

MIT
