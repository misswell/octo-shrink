<div align="center">

# 章小压 · OctoShrink

**免费开源、本地运行的图片压缩工具 —— 拖进去，压缩好，还给你。**

[![Release](https://img.shields.io/github/v/release/misswell/octo-shrink)](https://github.com/misswell/octo-shrink/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%20%C2%B7%20Windows%20%C2%B7%20Linux-blue)](https://github.com/misswell/octo-shrink/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tauri](https://img.shields.io/badge/Tauri-2.x-orange)](https://tauri.app)
[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-%E5%85%8D%E8%B4%B9-0A84FF)](https://apps.apple.com/cn/app/octoshrink-%E5%9B%BE%E7%89%87%E5%8E%8B%E7%BC%A9/id6792604654?mt=12)

![章小压 · OctoShrink](assets/banner.png)

**[官网](https://octoshrink.liuguofeng.com/)** · **[下载最新版](https://github.com/misswell/octo-shrink/releases/latest)** · **[Mac App Store](https://apps.apple.com/cn/app/octoshrink-%E5%9B%BE%E7%89%87%E5%8E%8B%E7%BC%A9/id6792604654?mt=12)** · **[问题反馈](https://github.com/misswell/octo-shrink/issues)**

</div>

---

## 为什么是章小压

在线压缩工具要把图片传到别人的服务器，命令行工具要装依赖、记参数。章小压把常用的图片压缩能力装进一个桌面应用：**所有压缩都在你的电脑上完成，素材永不上传**，断网也能用。适合日常整理截图、设计稿、公众号配图、网站图片和产品素材。

- **图片不上云** —— 本机处理，不注册、不登录、没有上传这一步
- **开箱即用** —— 压缩引擎随应用内置，无需安装任何命令行工具
- **批量拖拽** —— 图片或文件夹整批拖入，自动递归子目录
- **原图保护** —— 覆盖前先备份真原图，任何时候都能一键恢复
- **免费开源** —— MIT 许可证，无需购买或激活

## 界面一览

| 亮色模式 | 暗色模式 |
|---------|---------|
| ![亮色模式](assets/screenshot-light.png) | ![暗色模式](assets/screenshot-dark.png) |

压缩完成后，在独立对比窗口中拖动分割线逐像素对比原图与压缩结果，画面几乎看不出差别：

![对比窗口](assets/compare.png)

## 核心能力

### 压缩

- **两种模式**：「高级压缩」可调质量、压缩力度和输出格式（保持原格式或转 JPEG / PNG / WebP / AVIF）；macOS 另有「系统转换」，与 Finder 转换图像对齐，支持 JPEG / PNG / HEIF 与尺寸档位、元数据保留。
- **智能压缩**：自动为每张图选择合适的算法与参数；想完全掌控时，也可以手动指定引擎与力度。
- **批量队列**：拖入文件或文件夹自动递归展开、去重，支持追加导入、按名称 / 大小 / 压缩比 / 状态排序、只看失败。
- **灵活保存**：覆盖原文件、加自定义后缀（默认 `_compressed`）或输出到指定文件夹，三种方式随选。
- **压缩统计**：整个队列的原始大小、压缩后、已节省、压缩率一目了然，每行结果单独给出节省比例。

### 原图保护

- **覆盖前先备份**：选择覆盖原文件时，应用先把真正的原图备份到本机，备份失败就放弃覆盖 —— 宁可压缩失败，也不弄丢原图。
- **一键恢复**：从压缩结果或历史记录随时恢复原图；如果文件在压缩后又被其他应用改过，会先提示确认再覆盖。
- **压缩历史**：跨启动保留每次记录，每一行都提供此刻真正可用的操作 —— 另存为、对比查看、恢复原图（或删除本次压缩结果）、在访达中显示、复制日志。
- **备份保留期**：默认「不保留」（关闭应用时清理记录和备份，期间随时可恢复），也可选保留 1 / 3 / 7 / 14 / 30 天。清理只动应用自己的记录与备份，绝不删除你的图片文件。
- **崩溃安全**：覆盖操作有事务记录，意外退出后下次启动自动补记或回滚；历史文件损坏时会隔离现场、从备份重建恢复入口，并跳过当次清理 —— 原图副本永远优先。

### 队列与任务

- **暂停 / 继续 / 停止**：暂停只等还没开始的文件，正在压缩的照常跑完；「停止」结束这一轮，没轮到的文件仍留在队列，点「继续压缩」从原进度接着处理，进度绝不倒扣。失败项单独「重试」。
- **CPU 使用上限**：设置中可选自动或限制并行能力（同时处理的文件数 × 单个编码器线程数），为其他应用留出性能。
- **自动处理**：开启后导入即压缩；调整参数后也可以对单个文件调质量重压一次。

### 体验细节

- 🌗 亮色 / 暗色 / 自动跟随系统；压缩设置默认收起，不需要时完全不打扰
- 🔄 macOS GitHub 直发版支持应用内检查更新；Mac App Store 版由商店负责更新
- 🔒 直发版已签名并公证（Developer ID + Notarization），双击即用

## 下载与安装

| 渠道 | 适合谁 | 获取方式 |
|------|--------|---------|
| [GitHub Releases](https://github.com/misswell/octo-shrink/releases/latest) | 想要最新功能，以及 Windows / Linux 用户 | 下载安装包，双击安装 |
| [Mac App Store](https://apps.apple.com/cn/app/octoshrink-%E5%9B%BE%E7%89%87%E5%8E%8B%E7%BC%A9/id6792604654?mt=12) | 希望通过商店安装和更新的 Mac 用户 | 搜索「OctoShrink 图片压缩」，免费 |

GitHub Releases 提供 macOS Apple Silicon / Intel / Universal 三种 DMG，Windows 安装包（exe / msi）和 Linux 包（AppImage / deb）。两个渠道独立审核与发布，版本号和更新节奏可能略有差异。

### 快速上手

1. 打开章小压，把图片或文件夹拖进窗口（也可以点「选择文件」/「选择文件夹」）。
2. 需要调参数时展开「压缩设置」：质量、力度、输出格式、保存方式；不调就直接开始。
3. 点「开始压缩」。队列支持随时暂停、停止、追加文件；失败项可单独重试。
4. 完成后点结果行的「对比」按钮，在独立窗口滑动查看前后效果，不满意可调质量重压。
5. 覆盖模式下随时可「恢复原图」；打开「历史」页还能找回更早的记录。
6. 「设置」里可调整原图备份保留期、CPU 使用上限和外观主题。

### macOS 提示“已损坏，无法打开”？

自 v2.2 起直发版已签名 + 公证 + 装订，正常双击安装即可。若你在使用更早的未签名版本，可在终端执行：

```bash
sudo xattr -dr com.apple.quarantine /Applications/OctoShrink.app
```

## 和在线工具相比

| 能力 | 章小压 | 在线压缩工具 | 命令行工具 |
|------|:---:|:---:|:---:|
| 图片不上云 | ✅ | ❌ | ✅ |
| 批量文件夹递归 | ✅ | 通常受限 | 需要脚本 |
| 开箱即用 | ✅ | ✅ | 通常需要安装 |
| 可视化前后对比 | ✅ | 部分支持 | ❌ |
| 原图备份与一键恢复 | ✅ | ❌ | ❌ |
| 断网可用 | ✅ | ❌ | ✅ |
| 开源免费 | ✅ | 部分免费 | 多数免费 |

## 技术架构

基于 **Tauri 2**（Rust 后端 + 原生 HTML/CSS/JS 前端，无构建步骤），另有第三条 **Swift 原生**产物线。macOS 要求 11.0+（App Store 版 12.0+）。

### 三条产物线

同一套源码、同一个 master 分支，靠 Cargo feature 分叉：

| 产物线 | 分发渠道 | 压缩后端 | 构建脚本 | 产物 |
|--------|---------|---------|---------|------|
| Direct（直发） | GitHub Releases | 内置 CLI 工具（`cli-backends`，默认） | `scripts/notarize.sh` | `.app` + `.dmg` |
| App Store | Mac App Store | 全进程内 Rust 库（`appstore` = `inproc-backends`），沙盒 | `scripts/build_appstore.sh` | `.app` + `.pkg` |
| Swift 原生 | 源码 / 自行打包 | 同为进程内实现 | `scripts/build_swift.sh` | `.app` + `.dmg` |

- App Store 版**不打包、也不 spawn 任何第三方可执行文件**：所有格式走进程内 Rust 库，前端由进程内本地 HTTP 服务器提供（沙盒阻止 `tauri://`），文件访问经 security-scoped bookmark 授权
- 三条线的历史记录与备份存储根互相独立，原图备份永不落临时目录
- 工程规则详见 [AGENTS.md](AGENTS.md)（两条产物线并行、文件访问差异表、entitlements 对照）

### 压缩引擎对照

| 格式 | Direct（CLI） | App Store（进程内 crate） |
|------|--------------|--------------------------|
| PNG | pngquant / oxipng | imagequant / oxipng |
| JPEG | cjpeg (mozjpeg) | mozjpeg |
| WebP | cwebp | webp |
| AVIF | avifenc | ravif |
| GIF | gifsicle（可减色） | image crate 重编码 |
| 系统转换 | macOS ImageIO + CoreGraphics（三线共用，对齐 Finder） | 同左 |

所有 CLI 工具及其依赖库均已打包进 Direct 版应用内（`Contents/Resources/bin|lib`），通过 `DYLD_FALLBACK_LIBRARY_PATH` 加载，用户无需安装任何依赖。

## 本地开发

### 环境要求

- [Rust](https://rustup.rs/) 1.77+、[Tauri CLI](https://tauri.app/) 2.x（`cargo install tauri-cli --version "^2.0"`）
- 开发时需要 CLI 压缩工具（发布产物已内置，无需用户安装）：

```bash
brew install pngquant oxipng mozjpeg gifsicle webp jpeg-xl libavif
```

### 常用命令

```bash
cargo tauri dev                 # 开发模式（默认 Direct feature）

bash scripts/build_all.sh       # 一次构建 Direct + App Store 两版（日常首选，不签名）
SIGN=1 bash scripts/build_all.sh

cargo tauri build               # 构建 Direct 发布版
bash scripts/notarize.sh        # Direct：构建 → 签名 → 公证 → 装订 → DMG
bash scripts/build_appstore.sh  # App Store：构建 → 签名 → PKG

# 测试（推 tag 前 CI 不跑测试，这几套就是唯一门禁）
cargo test                                              # Rust 默认 feature
cargo test --no-default-features --features inproc-backends   # App Store feature
npm run test:frontend                                   # 前端队列 / 状态机 / 历史页 / CPU 上限
bash scripts/test_swift_history.sh                      # Swift 线历史·备份·暂停（真跑文件系统）
```

发布流程（推 `vX.Y.Z` 标签 → GitHub Actions 并行构建五大平台、签名公证、自动发布）与签名公证的凭据配置见 [AGENTS.md](AGENTS.md) 第 14 节。

### 项目结构

```
octo-shrink/
├── frontend/               # 前端（纯 HTML/CSS/JS，无构建步骤）
│   ├── index.html / app.js # 主窗口
│   └── compare.html / compare_window.js  # 独立对比窗口
├── src-tauri/              # Rust 后端（两条 Tauri 产物线共用）
│   ├── src/
│   │   ├── engine.rs            # 压缩引擎（CLI 后端）
│   │   ├── engine_inproc.rs     # 压缩引擎（进程内后端，不 spawn 外部进程）
│   │   ├── commands.rs          # Tauri 命令 + CompressionScheduler（暂停/停止/CPU 闸门）
│   │   ├── history.rs           # 压缩历史 + 原图备份 + 统一恢复服务
│   │   ├── output_transaction.rs# 覆盖事务凭证，启动时补记或回滚
│   │   └── app_settings.rs      # 保留天数 + CPU 上限（同一份 settings.json）
│   ├── resources/bin|lib/       # 内置 CLI 工具与动态库（仅 Direct 版打包）
│   ├── entitlements*.plist      # Direct / App Store
│   └── tauri.conf*.json         # Direct / App Store 两份配置
├── swift/                  # Swift 原生线（功能对齐，独立存储根）
├── website/                # 官网（octoshrink.liuguofeng.com）
├── tests/                  # 前端纯逻辑自检（node 直接跑）
├── scripts/                # 构建 / 签名 / 公证 / 自检脚本
└── AGENTS.md               # 工程准则：产物线并行规则、文件访问差异表
```

## License

[MIT](LICENSE)

---

## 👨‍💻 作者的其他开源项目

**[MacPilot](https://github.com/misswell/MacPilot)** —— 开源 macOS 菜单栏效率工具箱（Swift 原生 · 零第三方依赖）：应用自动退出规则、BLE 靠近解锁、窗口切换器、剪贴板历史、平滑滚动、画中画、录屏、截图贴图等 11 合 1，Apple 公证签名，[免费下载](https://github.com/misswell/MacPilot/releases/latest)。觉得有用欢迎点个 Star ⭐
