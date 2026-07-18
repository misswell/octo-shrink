# OctoShrink 工程准则（Codex / Agent 必读）

本文件是项目的权威工程约定。每次在此仓库工作时，**必须先读本文件**，并严格遵守其中"强制规则"。它们的目的是保证两条分发产物线长期并行、互不破坏。

---

## 🚨 强制规则（不可违反）

### 1. OctoShrink 有且仅有两条分发产物线，必须始终并行

| 产物线 | 用途 | 默认 feature | 构建脚本 | 证书 | 产物 |
---|---|---|---|---|---|
| Direct（直发） | GitHub Releases DMG，开发者/高级用户 | default = cli-backends | scripts/notarize.sh | Developer ID Application | .app + .dmg |
| App Store | Mac App Store 审核/上架 | appstore = inproc-backends | scripts/build_appstore.sh | Apple Distribution | .app + .pkg |

两条线共存于同一个 master 分支、同一套源码，靠 Cargo feature + #[cfg] 分叉实现。

### 2. 任意改动都不得破坏默认构建（Direct 产物线）

- cargo tauri build（不传 --features）必须始终产出可用 DMG，与 v2.2.0 等价或更好
- 任何新增能力不得依赖 --features appstore
- 修改 engine.rs / commands.rs / lib.rs / frontend/* 时，默认分支行为必须保留，用 #[cfg(feature = "inproc-backends")] 加新实现，不要改写 #[cfg(feature = "cli-backends")] 下的现有实现

### 3. 不允许出现只有一条线的代码

- 新增压缩引擎函数 → 必须同时提供 cli-backends 版本（现状）和 inproc-backends 版本（进程内），同一接口签名
- 新增 tauri command / 前端 invoke → 两个 feature 下行为必须一致；若 App Store 版不同，用 #[cfg] 分叉，并在本文件记录差异
- 接口（CompressOptions / EngineResult / CompressResult 等）跨 feature 必须保持一致，不得为某一条线改类型签名

### 4. 不在主分支上做"切换主路径"的改动

- 不要把 default 改成 inproc-backends
- 不要删 cli-backends 实现（即使 App Store 版跑通）
- 不要把 resources/bin/* 和 resources/lib/* 删掉
- 增量并轨：新能力以 #[cfg(feature = "inproc-backends")] 写在新文件或新分支里

### 5. App Store 版与 Direct 版必须可独立构建/签名/发布

- scripts/notarize.sh 只认 default feature，签 Developer ID，输出 DMG
- scripts/build_appstore.sh 只认 --features appstore，签 Apple Distribution，输出 PKG
- 两脚本不得互相 import / 调用
- 共享代码只在 src-tauri/src/，不在脚本层共享

### 6. 文件访问层差异要显式记录

- 沙盒（App Store 版）使用 security-scoped bookmarks，Direct 版不受限
- 任何与文件路径、目录访问、fs::read/write、walk_dir、drag-drop 相关的改动 → 必须在本文件第 3 节"文件访问差异表"更新，并确保两个 feature 下都符合各自约束

---

## 两条产物线的 feature 分叉结构

```toml
# src-tauri/Cargo.toml
[features]
default = ["cli-backends"]        # Direct（DMG 直发，现状）
cli-backends = []                  # 调 7 个外部 CLI + 内置 17 dylib
appstore = ["inproc-backends"]     # App Store
inproc-backends = []               # 进程内 Rust 库（沙盒友好）
```

```rust
// src-tauri/src/engine.rs 范式
#[cfg(feature = "cli-backends")]
pub async fn compress_png(file: &Path, opts: &CompressOptions) -> EngineResult { /* 调 pngquant/oxipng CLI */ }

#[cfg(feature = "inproc-backends")]
pub async fn compress_png(file: &Path, opts: &CompressOptions) -> EngineResult { /* 调 imagequant/oxipng crate */ }
```

- 两个 compress_png 接口完全一致 → commands.rs 调用层无需 #[cfg]
- EngineResult / CompressOptions 定义在 engine.rs 顶部，跨 feature 一致

## 构建命令速查

```bash
# Direct（默认，发布到 GitHub Releases）
cargo tauri build                              # 或 cargo tauri build --features default
bash scripts/notarize.sh                       # 一键：构建→签名→公证→装订→DMG

# App Store（开发循环）
cargo tauri build --features appstore --bundles app
bash scripts/build_appstore.sh                 # 一键：构建→签名→productbuild→PKG（待落地）

# 单元测试
cargo test                                     # 默认 feature（cli-backends）
cargo test --features inproc-backends          # 进程内版
```

## 分发表

| 渠道 | 产物 | 位置 | 用户获取方式 | 审核方式 |
---|---|---|---|---|
| Direct | OctoShrink-<ver>-macos.dmg | GitHub Releases | 下载 + 拖到「应用程序」 | Apple 公证（自动 ~2 分钟）|
| App Store | OctoShrink-<ver>.pkg | App Store Connect | App Store 搜索安装 | 人工 + 自动审核（1-3 周）|

- 两渠道独立发布，各自节奏
- 版本号保持一致，避免用户混淆
- Bundle ID 分开（推荐）：
  - Direct：com.misswell.octoshrink（现状）
  - App Store：com.misswell.octoshrink.appstore（独立配置文件 src-tauri/tauri.conf.appstore.json）

## 完整改造蓝图

详见 docs/APPSTORE_MIGRATION_PLAN.md —— 5 阶段路线图、引擎替换映射表、风险与取舍、估时。

本文件是"规则"，蓝图文档是"施工方案"。

## 当前状态（编辑此节以保持最新）

- ✅ Direct 产物线已就绪：v2.2.0 已签名公证发布，notarize.sh 工作
- 🟡 App Store 产物线骨架已完成：features 双线、engine_inproc.rs 占位、build_appstore.sh 占位
- ⬜ App Store 引擎迁移：PNG 进程内化（阶段 1.1 起步）→ JPEG → WebP → AVIF → GIF → JXL
- ⬜ 沙盒改造：entitlements-appstore.plist、bookmarks、open_in_finder 替换
- ⬜ Apple Distribution 证书签发
- ⬜ 首次 App Store 提交

## 文件访问差异表（随改动更新）

| 功能 | Direct 版（feature=default） | App Store 版（feature=appstore） | 差异原因 |
---|---|---|---|
| 选文件/文件夹 | tauri_plugin_dialog::pick_* 无限制 | 同上 + 写入 BookmarkStore | 沙盒需书签才能续访 |
| 拖放（drag-drop） | Tauri drop payload 直给路径 | 同上 + bookmark 化 | 沙盒需 security-scoped URL |
| walk_dir 递归 | fs::read_dir 任意路径 | 仅在已书签根内递归 | 沙盒只认授权范围 |
| write_output_file | fs::write 原路径 | 同上，前提路径已授权 | 沙盒 fs 检查 |
| restore_original | fs::copy(backup, original) | 同上，原路径需 bookmark | 沙盒 |
| open_in_finder | Command::new("open").arg("-R") | tauri-plugin-opener（NSWorkspace）| 沙盒禁 spawn Finder |
| ~/Library/... 访问 | 任意 | 仅 App Support / Caches / Tmp（sandbox 允许子集）| 沙盒 |

## Entitlements 对照

| entitlement | Direct（entitlements.plist） | App Store（entitlements-appstore.plist） |
---|---|---|
| app-sandbox | 关 | 强制开 |
| files.user-selected.read-write | 不需要 | 需要 |
| files.bookmarks.app-scope | 不需要 | 需要 |
| files.downloads.read-write | 不需要 | 需要 |
| cs.disable-library-validation | 需要（加载内置 dylib） | 不允许（沙盒禁用） |
| cs.allow-dyld-environment-variables | 需要（DYLD_FALLBACK_LIBRARY_PATH） | 不允许（沙盒禁用） |

## 内置 CLI 工具与 Rust crate 对照

| CLI（Direct 版用）| Rust crate 替代（App Store 版用）| 状态 |
---|---|---|
| pngquant | imagequant crate（同源算法）| 待接入 |
| oxipng | oxipng crate（库版）| 待接入 |
| cjpeg (mozjpeg) | mozjpeg crate | 待接入 |
| cwebp | webp + libwebp-sys | 待接入 |
| avifenc | libavif / ravif | 待接入 |
| cjxl | jpegxl-sys（或临时移除 JXL 输出）| 待接入 |
| gifsicle | gif crate | 待接入（动图优化能力下降）|

## 变更本文件的规定

- 任何 PR / 提交若改变两条产物线的并行结构、文件访问差异、entitlements 配置、CLI↔crate 映射 → 必须在本文件同步更新对应小节
- 本文件由 AI 失效风险最小化优先：每条规则都写成"行动项 + 为什么"，便于将来任何 Agent 读到时都能立即照做

## 参考

- docs/APPSTORE_MIGRATION_PLAN.md — 5 阶段路线图
- scripts/notarize.sh — Direct 产物线
- scripts/build_appstore.sh — App Store 产物线（占位）
- src-tauri/entitlements.plist — Direct entitlements
- src-tauri/entitlements-appstore.plist — App Store entitlements（占位）
- src-tauri/tauri.conf.json — Direct 配置（identifier = com.misswell.octoshrink）
- src-tauri/tauri.conf.appstore.json — App Store 配置（identifier = com.misswell.octoshrink.appstore，占位）
