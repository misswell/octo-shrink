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

## 📦 下载与安装

前往 [GitHub Releases](https://github.com/misswell/octo-shrink/releases) 下载对应平台安装包。

### macOS 提示"已损坏，无法打开"

> 自 v2.2 起已使用 **Apple Developer ID 签名 + 公证（Notarization）+ 装订（Stapling）**，正常双击安装即可运行，**不再需要**下面的 xattr 处理。
>
> 下面这段仅用于调试旧版本（未签名）时参考。

如果使用旧版（未签名）下载安装后打开提示：

> "OctoShrink.app"已损坏，无法打开。你应该推出磁盘映像。

这通常不是文件真的损坏，而是 macOS 对未签名/未公证开源应用添加了隔离标记。可以这样处理：

1. 打开 `.dmg`
2. 将 `OctoShrink.app` 拖到「应用程序」文件夹
3. 推出/弹出磁盘映像
4. 打开「终端」，运行：

```bash
sudo xattr -dr com.apple.quarantine /Applications/OctoShrink.app
```


5. 再从「应用程序」里打开 OctoShrink（仅旧版需要）

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

### 分发打包（Apple 签名 + 公证）

`scripts/notarize.sh` 一键完成「构建 → 复制内置工具 → 逐个签名（hardened runtime + entitlements）→ 校验 → 制作 DMG → Apple 公证 → 装订票据」。流程参考已签名公证的分发版做法。

前置条件（只需做一次）：

1. 加入付费 [Apple Developer Program](https://developer.apple.com/programs/)，并创建 **Developer ID Application** 证书（在 Xcode 账户或 developer.apple.com 创建，安装到登录钥匙串）。
   - 验证：`security find-identity -v -p codesigning` 能看到 `Developer ID Application: ... (U8U443D7ZL)`。
2. 存储公证凭据（推荐 keychain profile，免明文密码）：
   ```bash
   xcrun notarytool store-credentials "octoshrink-notary" \
     --apple-id "you@example.com" --team-id "U8U443D7ZL" \
     --password "应用专用密码"   # 在 appleid.apple.com 生成
   ```

打包发布：

```bash
# 自动检测 Developer ID 身份；使用 keychain profile 公证
NOTARY_PROFILE="octoshrink-notary" bash scripts/notarize.sh

# 或用 Apple ID + 应用专用密码公证
APPLE_ID="you@example.com" APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  APPLE_TEAM_ID="U8U443D7ZL" bash scripts/notarize.sh

# 仅签名不公证（本地测试）
SIGN_ONLY=1 bash scripts/notarize.sh
```

产物：
- `src-tauri/target/release/bundle/macos/OctoShrink.app`（已签名 + 装订）
- `src-tauri/target/release/bundle/macos/OctoShrink-<version>-macos.dmg`（已签名 + 装订）

> 说明：内置的 7 个 CLI 压缩工具与 17 个动态库均已用 Developer ID 逐一签名，并启用 hardened runtime 与 `disable-library-validation` / `allow-dyld-environment-variables` entitlements，以确保 `DYLD_FALLBACK_LIBRARY_PATH` 在加固运行时下仍可加载内置库。这是通过 Apple 公证的必要条件。

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
