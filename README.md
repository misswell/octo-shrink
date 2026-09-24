# 🐙 章小压 · OctoShrink

> **免费开源、本地运行的图片压缩工具。** 拖进去，压缩好，还给你。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS·Windows·Linux-blue)](https://github.com/misswell/octo-shrink/releases)
[![Tauri](https://img.shields.io/badge/Tauri-2.x-orange)](https://tauri.app)
[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-免费-0A84FF)](https://apps.apple.com/cn/app/octoshrink-%E5%9B%BE%E7%89%87%E5%8E%8B%E7%BC%A9/id6792604654?mt=12)

![章小压 · OctoShrink](assets/banner.png)

官网：**[octoshrink.liuguofeng.com](https://octoshrink.liuguofeng.com/)**

## 为什么用它

在线压缩工具需要上传图片，命令行工具则要安装和记参数。章小压把常见图片压缩能力整合进桌面应用，在本机处理图片，适合日常整理截图、设计稿、公众号配图、网站图片和产品素材。

- **图片不上云**：所有压缩都在本机完成，断网也能用
- **拖拽批量压缩**：支持图片和文件夹，自动递归处理子目录
- **开箱即用**：压缩引擎随应用提供，无需另行安装命令行工具
- **可视化对比**：独立对比窗口，滑动查看压缩前后效果，按需重调质量再压一次
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

### 图片压缩

- 🎯 **两种处理方式**：「高级压缩」可调整质量、压缩力度和输出格式；macOS 另有「系统转换」，可选 JPEG、PNG 或 HEIF，并设置图像尺寸与元数据保留。
- 🧠 **智能压缩**：自动选择合适的算法和参数；需要更多控制时，也可手动选择压缩引擎与压缩力度。
- 📦 **批量处理**：拖入图片或文件夹，自动递归扫描子目录。队列支持追加文件、去重、排序和失败后单独重试。
- 🔄 **格式转换**：高级压缩可保持原格式，或输出为 JPEG、PNG、WebP、AVIF；macOS 系统转换还支持 HEIF。
- 📁 **灵活保存**：可覆盖原文件、添加自定义后缀（默认 `_compressed`），或输出到指定文件夹。
- 📊 **压缩对比**：查看原图与结果的文件大小、节省比例；在独立窗口中滑动对比画面，也可调整参数后重新压缩。

### 原图与任务管理

- ↩️ **恢复原图**：覆盖文件前先备份原图。可从压缩结果或历史记录恢复；如果原文件之后被其他应用修改，会先提示确认。
- 🕘 **压缩历史**：按时间查看压缩记录和结果。可另存、对比、恢复原图、删除本次压缩结果、在访达中显示或复制日志。
- 🗓️ **备份保留期**：默认「不保留」，覆盖前仍会备份，运行期间可恢复；关闭应用时清理记录和备份。也可选择保留 1、3、7、14 或 30 天。清理不会删除你自己的图片或压缩结果。
- 🧾 **异常恢复**：覆盖操作有事务记录。意外退出后，应用会在下次启动时检查并恢复中断现场；历史文件损坏时会尽量重建原图恢复入口，并跳过备份清理。
- ⏸️ **暂停、继续与停止**：暂停会等正在处理的文件完成，再暂停尚未开始的任务。停止会让已开始的文件完成，并将其余文件留在队列；之后点「继续压缩」可从原进度接着处理。失败项需单独重试。

### 其他

- 🔒 **本机处理**：图片在本机压缩，不会上传到服务器；断网也能使用。GitHub 直发版的应用内更新会连接 GitHub Releases。
- ⚙️ **CPU 使用上限**：在设置中选择自动或限制并行处理能力。较低的上限会降低压缩速度，但能为其他应用留出更多性能。
- 🖤 **外观**：支持自动、亮色和暗色模式；压缩设置默认收起，需要时再展开。
- 🖥️ **应用更新**：macOS GitHub 直发版可在设置中检查更新；Mac App Store 版通过 App Store 更新。
- 🔓 **免费开源**：采用 MIT 许可证，无需购买或激活。

## 📦 下载与安装

| 渠道 | 最新版本 | 适合谁 | 获取方式 |
|------|---------|--------|---------|
| [GitHub Releases](https://github.com/misswell/octo-shrink/releases/latest) | 最新版 | 想获取最新功能，以及 Windows / Linux 用户 | 下载 macOS DMG、Windows 安装包或 Linux 安装包 |
| [Mac App Store](https://apps.apple.com/cn/app/octoshrink-%E5%9B%BE%E7%89%87%E5%8E%8B%E7%BC%A9/id6792604654?mt=12) | 以商店页为准 | 希望通过 App Store 安装和更新的 Mac 用户 | 搜索「OctoShrink 图片压缩」，免费 |

GitHub Releases 提供 macOS Apple Silicon、Intel 和 Universal 版本，以及 Windows、Linux 安装包。macOS 直发版已签名并公证；应用内更新仅适用于直发版。App Store 版本独立审核和更新，版本号与功能更新节奏可能不同。

### 基本使用

1. 打开 OctoShrink，拖入图片或文件夹，也可以点「选择文件」或「选择文件夹」。
2. 导入后展开「压缩设置」，选择「高级压缩」或 macOS 上的「系统转换」。设置默认收起，不需要调整时可直接开始。
3. 按需选择质量、压缩力度、输出格式和保存方式。覆盖原文件前会先保存原图备份。
4. 点击「开始压缩」。也可开启「自动处理」，让导入的图片立即开始压缩。
5. 需要暂停时点击「暂停」，已开始的文件完成后会等待；点击「继续」可接着当前任务处理。点击「停止」后，已开始的文件完成，未开始的文件仍留在队列；之后点击「继续压缩」从剩余文件开始。失败项需点「重试」。
6. 点击结果中的「对比」，在独立窗口中滑动查看原图与压缩结果；可调整质量后再次压缩。
7. 打开「历史」查看记录。覆盖模式且备份仍在时可恢复原图；使用后缀或输出文件夹模式时，可删除本次压缩结果，原图保持不变。
8. 在「设置」中调整原图备份保留时间和 CPU 使用上限。GitHub 直发版也可在这里检查应用更新。

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
| 原图备份与恢复 | ✅ | ❌ | ❌ |
| 开源免费 | ✅ | 部分免费 | 多数免费 |

## 🏗️ 技术架构

基于 **Tauri 2** 构建，后端 Rust，前端原生 HTML/CSS/JS（无构建步骤）。另有第三条 **Swift 原生** 产品线。macOS 要求 11.0+（App Store 版 12.0+）。

### 三条产物线

同一套源码、同一个 master 分支，靠 Cargo feature 分叉：

| 产物线 | 对应分发 | 压缩后端 | 构建脚本 | 产物 |
|--------|---------|---------|---------|------|
| Direct（直发） | GitHub Releases | 内置 CLI 工具（`cli-backends`，默认） | `scripts/notarize.sh` | `.app` + `.dmg` |
| App Store | Mac App Store | 全进程内 Rust 库（`appstore` = `inproc-backends`），沙盒 | `scripts/build_appstore.sh` | `.app` + `.pkg` |
| Swift 原生 | 源码 / 自行打包 | 同为进程内实现 | `scripts/build_swift.sh`、`scripts/package_swift_dmg.sh` | `.app` + `.dmg` |

日常开发用 `bash scripts/build_all.sh` 一次构建前两条线（Direct 产物重命名为 `OctoShrink_direct.app` 以免覆盖）。

- 沙盒版不打包任何第三方 CLI 或 dylib，也不 spawn 外部进程 —— 沙盒下子进程拿不到 security-scoped 文件授权，那条路径必然失败；构建脚本与源码自检测试共同守住这一点
- 沙盒版用 security-scoped bookmark 记住用户授权过的路径，所以「关闭 App → 重新打开 → 从历史页恢复原图」仍然可用；前端由进程内本地 HTTP 服务器提供（macOS 沙盒阻止 `tauri://`）
- 三条线的历史记录与备份**存储根互相独立**，不读写对方的 `history.json`；原图备份永不落临时目录

### 压缩引擎对照

| 格式 | Direct（CLI） | App Store（进程内 crate） | 后备 |
|------|--------------|--------------------------|------|
| PNG | pngquant（有损）/ oxipng（无损） | imagequant / oxipng | Rust `image` |
| JPEG | cjpeg (mozjpeg) | mozjpeg | Rust `image` |
| WebP | cwebp | webp | Rust `image` |
| AVIF | avifenc | ravif | — |
| GIF | gifsicle（可减色） | image crate 重编码（不减色） | — |
| HEIF / 系统转换 | macOS ImageIO + CoreGraphics（三线共用，对齐 Finder） | 同左 | — |
| JPEG XL | cjxl（引擎代码保留，界面输出选项已移除，两版一致） | 暂无 | — |

### 内置工具（仅 Direct 版）

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

# 一次构建两条 Tauri 产物线（日常首选，不签名）
bash scripts/build_all.sh
SIGN=1 bash scripts/build_all.sh   # 同时签名

# 将 CLI 工具打包到 .app（开箱即用）
bash scripts/package.sh
```

### 分发打包（Apple 签名 + 公证）

`scripts/notarize.sh` 一键完成「构建 → 复制内置工具 → 逐个签名（hardened runtime + entitlements）→ 校验 → 制作 DMG → Apple 公证 → 装订票据」。

前置条件（只需做一次）：

1. 加入付费 [Apple Developer Program](https://developer.apple.com/programs/)，并创建 **Developer ID Application** 证书（在 Xcode 账户或 developer.apple.com 创建，安装到登录钥匙串）。
   - 验证：`security find-identity -v -p codesigning` 能看到 `Developer ID Application: ... (你的 Team ID)`。
2. 存储公证凭据（推荐 keychain profile，免明文密码）：
   ```bash
   xcrun notarytool store-credentials "octoshrink-notary" \
     --apple-id "you@example.com" --team-id "你的TeamID" \
     --password "应用专用密码"   # 在 appleid.apple.com 生成
   ```

打包发布：

```bash
# 自动检测 Developer ID 身份；使用 keychain profile 公证
NOTARY_PROFILE="octoshrink-notary" bash scripts/notarize.sh

# 或用 Apple ID + 应用专用密码公证
APPLE_ID="you@example.com" APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
  APPLE_TEAM_ID="你的TeamID" bash scripts/notarize.sh

# 仅签名不公证（本地测试）
SIGN_ONLY=1 bash scripts/notarize.sh

# App Store 线：构建 → 签名 → productbuild 打 PKG
bash scripts/build_appstore.sh
```

产物：
- `src-tauri/target/release/bundle/macos/OctoShrink.app`（已签名 + 装订）
- `src-tauri/target/release/bundle/macos/OctoShrink-<version>-macos.dmg`（已签名 + 装订）

> 说明：内置的 7 个 CLI 压缩工具与 17 个动态库均已用 Developer ID 逐一签名，并启用 hardened runtime 与 `disable-library-validation` / `allow-dyld-environment-variables` entitlements，以确保 `DYLD_FALLBACK_LIBRARY_PATH` 在加固运行时下仍可加载内置库。这是通过 Apple 公证的必要条件。

也可以推 `vX.Y.Z` 标签、或在 GitHub 手动运行 **Release** workflow（`.github/workflows/release.yml`）：CI 会并行构建 ARM / Intel / Universal 2 / Windows / Linux，逐一签名、公证三个 macOS DMG，签好 Universal 在线更新包并生成 `latest.json`。手动运行时 `publish=false`（默认）只完整验证构建、签名与公证，`publish=true` 才正式发布。

### 项目结构

```
octoshrink/
├── frontend/               # 前端（纯 HTML/CSS/JS，无构建步骤）
│   ├── index.html          # 主窗口
│   ├── compare.html        # 独立对比窗口
│   ├── compare_window.js   # 对比窗口逻辑（载荷经后端状态中转）
│   ├── app.js              # 使用 window.__TAURI__ 全局 API
│   └── style.css
├── src-tauri/              # Rust 后端（两条 Tauri 产物线共用）
│   ├── src/
│   │   ├── main.rs              # 入口
│   │   ├── lib.rs               # Tauri 应用配置（沙盒线含本地 HTTP 服务器）
│   │   ├── engine.rs            # 压缩引擎（CLI 后端）
│   │   ├── engine_inproc.rs     # 压缩引擎（进程内后端，不 spawn 外部进程）
│   │   ├── commands.rs          # Tauri 命令 + CompressionScheduler（暂停/停止与并发预算同一套闸门）
│   │   ├── history.rs           # 压缩历史 + 原图备份 + 统一恢复服务
│   │   ├── output_transaction.rs# 覆盖事务凭证，启动时补记或回滚
│   │   ├── sandbox_access.rs    # 跨启动文件访问授权（书签 / 直通）
│   │   ├── app_settings.rs      # 备份保留天数 + CPU 并行上限（同一份 settings.json）
│   │   └── system_info.rs       # CPU 能力检测（并行度基准 + 核心构成展示）
│   ├── resources/bin|lib/       # 内置 CLI 工具与动态库（仅 Direct 版打包）
│   ├── capabilities/default.json# IPC 权限（沙盒版必须显式声明）
│   ├── permissions/commands.toml
│   ├── entitlements*.plist      # Direct / App Store
│   └── tauri.conf*.json         # Direct / App Store 两份配置
├── swift/                  # Swift 原生线（功能对齐，独立存储根）
│   └── Sources/OctoShrinkSwift/{Engine,Models,Services,ViewModels,Views}
├── tests/                  # 前端纯逻辑自检（*.cjs，node 直接跑）
├── scripts/                # build_all / notarize / build_appstore / build_swift / 自检
├── website/                # 官网（octoshrink.liuguofeng.com）
├── docs/                   # App Store 迁移蓝图、界面设计稿
├── AGENTS.md               # 工程准则：两条产物线的并行规则、文件访问差异表
└── package.json
```

### 跑测试

```bash
cargo test                                              # Rust 默认 feature（Direct / cli-backends）
cargo test --no-default-features --features inproc-backends   # App Store 版
npm run test:frontend                                   # 前端队列 / 暂停·停止状态机 / 历史页 / 恢复 / CPU 上限
bash scripts/test_swift_history.sh                      # Swift 线历史·备份·暂停·停止·CPU 上限（真跑文件系统与并发）
```

改动若涉及产物线结构、文件访问差异、entitlements 或 CLI↔crate 映射，请同步更新 `AGENTS.md` 对应小节。

## 📄 License

MIT

---

## 👨‍💻 作者的其他开源项目

**[MacPilot](https://github.com/misswell/MacPilot)** —— 开源 macOS 菜单栏效率工具箱（Swift 原生 · 零第三方依赖）：应用自动退出规则、BLE 靠近解锁、窗口切换器、剪贴板历史、平滑滚动、画中画、录屏、截图贴图等 11 合 1，Apple 公证签名，[免费下载](https://github.com/misswell/MacPilot/releases/latest)。觉得有用欢迎点个 Star ⭐
