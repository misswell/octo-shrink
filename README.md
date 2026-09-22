# 🐙 章小压 · OctoShrink

> **免费开源、本地运行的图片压缩工具。** 拖进去，压缩好，还给你。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS·Windows·Linux-blue)](https://github.com/misswell/octo-shrink/releases)
[![Tauri](https://img.shields.io/badge/Tauri-2.x-orange)](https://tauri.app)

![章小压 · OctoShrink](assets/banner.png)

## 为什么用它

在线压缩工具很方便，但图片需要上传到第三方服务器；命令行工具很强，但需要安装和记参数；不少桌面压缩软件又比较重。章小压把常用压缩工具打包进一个轻量桌面应用里，适合每天处理截图、设计稿、公众号配图、网站图片和产品素材。

- **图片不上云**：所有压缩都在本机完成，断网也能用
- **拖拽批量压缩**：支持图片和文件夹，自动递归处理子目录
- **开箱即用**：内置 pngquant、oxipng、mozjpeg、gifsicle、cwebp、cjxl、avifenc
- **体积轻**：Tauri 2 + Rust 后端，macOS 应用约 18MB
- **可视化对比**：滑动查看压缩前后效果，按需要重新调整质量
- **原图保护**：覆盖原文件前先保存一份真正原图，压缩历史跨启动保留，任何时候都能一键恢复

## 适合谁

- 写博客、公众号、知识库时，经常需要压缩配图的人
- 前端、独立开发者、站长，需要减少网页图片体积的人
- 设计师、运营、产品经理，需要批量处理截图和素材的人
- 不想把证件照、合同扫描件、客户图片上传到在线工具的人

## 📸 截图

| 亮色模式 | 暗黑模式 |
|---------|---------|
| ![亮色模式](assets/screenshot-light.png) | ![暗黑模式](assets/screenshot-dark.png) |

![压缩对比](assets/compare.png)

## ✨ 特性

- 🎯 **智能算法选择**：自动分析图片格式，从多个后端中选择合适算法
- 🚀 **多引擎支持**：集成 pngquant、oxipng、mozjpeg (cjpeg)、gifsicle、cwebp、cjxl、avifenc，并使用 Rust `image` 引擎作为后备
- 📦 **批量处理**：支持批量选择图片或拖入整个文件夹，自动递归处理子目录
- 🔄 **多种格式**：支持 PNG、JPG、GIF、WebP、BMP 压缩
- 🆕 **现代格式输出**：支持输出为 AVIF、JPEG XL、WebP、JPEG、PNG
- 📊 **实时对比**：压缩前后体积、压缩率一目了然，支持滑动对比
- 🔓 **完全免费**：MIT 开源协议，无需购买激活码
- 🖥️ **原生体验**：基于 Tauri 2 构建，macOS 应用约 18MB
- 🔧 **内置工具链**：所有 CLI 压缩工具已打包到应用内，无需用户额外安装
- ↩️ **恢复原图**：覆盖模式下先备份再写盘，压缩后不满意可恢复原始文件；若文件在压缩后又被外部改动过，会先确认再覆盖
- 🕘 **压缩历史**：独立的「历史」页按时间倒序列出文件名、原始 → 压缩后体积、节省比例、时间、算法与状态，可直接从历史恢复原图（队列和压缩进度不受影响）
- ⏸️ **安全暂停**：压缩途中可暂停 / 继续，只拦下还没开始的文件，正在处理的那张不会被打断
- 🗓️ **备份保留期**：默认「不保留」——覆盖原文件前照样先备份，本次会话内随时可恢复原图，关闭应用时清干净；也可改为 1 / 3 / 7 / 14 / 30 天，过期的历史记录与备份在下次启动时自动清理，**任何时候都不会删除你的图片或压缩结果**
- 🔄 **实时切换压缩率**：对比时可调整质量参数并重新压缩
- ⚙️ **CPU 使用上限**：设置页「性能」可限制 OctoShrink 同时使用的 CPU 并行能力（自动 / 1…本机并行度），队列摘要显示 `· CPU 4/10`。数值越低速度越慢，但给其他应用留出更多性能；运行中改数值不打断正在压缩的文件，暂停与它共用同一套调度闸门

## 📦 下载与安装

前往 [GitHub Releases](https://github.com/misswell/octo-shrink/releases) 下载对应平台安装包。

### 当前版本

v2.5.33：Swift 原生线补齐到与 Tauri 版功能对齐（智能模式、系统转换、输出三模式、重试/导出/恢复、对比窗口），布局按 Tauri 样式重排。

已合入主干、随下一版发布：压缩历史与原图长期备份、按保留天数自动清理、安全暂停，以及三条产物线共用的 CPU 使用上限（同时限制并发文件数与单个编码器内部线程数）。

### 基本使用

1. 打开章小压
2. 拖入图片或文件夹
3. 选择输出模式：覆盖原文件、添加自定义文件名后缀（默认 `_compressed`），或输出到指定文件夹
4. 点击「开始压缩」；中途想停下来点「暂停」，处理完当前这张就会停住，随时「继续」
5. 如需检查画质，点击「对比」查看压缩前后差异
6. 想找回某张的原图：标题栏「历史」→ 定位该文件 → 「恢复原图」
7. 想给其他应用留性能：「设置」→「性能」→ 调 CPU 使用上限，或直接点「自动」

macOS 用户还可以切换到「系统转换」：它对齐 Finder 右键「快速操作 → 转换图像」的默认系统转换方式。

### macOS 提示“已损坏，无法打开”

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

## 和在线工具相比

| 能力 | 章小压 | 在线压缩工具 | 命令行工具 |
|------|--------|--------------|------------|
| 本地运行 | ✅ | ❌ | ✅ |
| 图片不上云 | ✅ | ❌ | ✅ |
| 批量文件夹处理 | ✅ | 通常受限 | 需要脚本 |
| 开箱即用 | ✅ | ✅ | 通常需要安装 |
| 可视化对比 | ✅ | 部分支持 | ❌ |
| 开源免费 | ✅ | 部分免费 | 多数免费 |

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

macOS Direct 版会在启动后静默检查 GitHub Release 更新；发现新版本后由用户确认下载并安装。发布的更新包使用 Tauri updater 签名校验，App Store 版仍由 Mac App Store 更新。

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
│   │   ├── history.rs  # 压缩历史 + 原图备份 + 统一恢复服务
│   │   ├── app_settings.rs # 备份保留天数 + CPU 并行上限（同一份 settings.json）
│   │   ├── system_info.rs # CPU 能力检测（并行度基准 + 核心构成展示）
│   │   └── commands.rs # Tauri 命令
│   ├── resources/      # 内置 CLI 工具和动态库
│   │   ├── bin/        # 7 个压缩工具
│   │   └── lib/        # 17 个依赖库
│   ├── icons/          # 应用图标
│   ├── tauri.conf.json # Tauri 配置
│   └── Cargo.toml      # Rust 依赖
├── swift/              # Swift 原生线（与 Tauri 线功能对齐，独立存储根）
├── tests/              # 前端纯逻辑自检（*.cjs，node 直接跑）
├── scripts/
│   ├── package.sh      # 打包脚本（将工具集成到 .app）
│   └── test_swift_history.sh # Swift 历史·备份·暂停·CPU 上限自检
└── package.json
```

### 跑测试

```bash
cargo test                                     # Rust 默认 feature（Direct / cli-backends）
cargo test --no-default-features --features inproc-backends   # App Store 版
npm run test:frontend                          # 前端队列 / 暂停 / 历史页 / 恢复 / CPU 上限
bash scripts/test_swift_history.sh             # Swift 线历史·备份·暂停·CPU 上限（真跑文件系统与并发）
```

## 📄 License

MIT

---

## 👨‍💻 作者的其他开源项目

**[MacPilot](https://github.com/misswell/MacPilot)** —— 开源 macOS 菜单栏效率工具箱（Swift 原生 · 零第三方依赖）：应用自动退出规则、BLE 靠近解锁、窗口切换器、剪贴板历史、平滑滚动、画中画、录屏、截图贴图等 11 合 1，Apple 公证签名，[免费下载](https://github.com/misswell/MacPilot/releases/latest)。觉得有用欢迎点个 Star ⭐
