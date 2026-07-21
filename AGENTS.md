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

### 7. 修改前防改坏流程（务必遵守，避免"修A坏B"反复）

历史上反复出现"修改之前正常，修改之后坏了"——根因是修一个问题时不验证是否破坏另一个已修复项，或凭推理盲改不查 git 历史。强制流程：

1. **先查 git 历史，别凭推理直接改**：用户说"之前正常"→ `git log -- <file>` + `git show <commit>:<file>` 找正常基线，diff 出"正常→坏"改动点，证据闭环后再动。绝不只读几行靠推理就 apply_patch。
2. **已盲改的先撤回**：没查根因就改了→ `git checkout -- <file>` 撤回已知状态，查清再精准改，不留叠加瞎改。
3. **耦合项必须同改**：本项目耦合对 = **白屏（HTTP 服务器 + network entitlements）↔ IPC（remote.urls 带端口 origin + allow-* ACL）**，改任一项须确认另一项仍满足。`f064299` 修白屏漏改 remote.urls 端口→IPC 坏；`2760364` 移除 network entitlements→白屏回归。两害同治。
4. **最小改动**：只改确诊根因行，不碰 engine/commands/前端/另一产物线。<30 行优先 apply_patch；>50% 文件用 `_write` 整覆盖。
5. **不破坏 Direct 产物线**：HTTP 服务器在 `#[cfg(feature="inproc-backends")]` 内；`capabilities/default.json` 两线共用但 Direct 用 tauri:// 不走 remote ACL。改完确认 `cargo tauri build`（无 --features）仍可用。
6. **验证用签名+沙盒 .app**：`open` 产物实测（非 `cargo tauri dev`，非沙盒不复现）。改完跑 `bash scripts/build_appstore.sh`，`open` 产物测白屏+拖图+选文件夹+窗口拖动四项。
7. **诊断优先于动手**：写码前读完相关文件+git 历史，证据闭环再改。没把握不改，宁可问基线，不赌。

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
# 两版同时构建（日常开发首选）
bash scripts/build_all.sh                      # 编译两版 + 复制资源（不签名）
SIGN=1 bash scripts/build_all.sh               # 编译 + 签名两版
# 产物：OctoShrink_direct.app（Direct）+ OctoShrink.app（App Store）

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
- ✅ App Store 产物线已构建并上传：v2.2.9 PKG 已上传 App Store Connect（Apple ID: 6792604654，Delivery UUID 6d414d74-5d30-449f-a666-ac11f6ea4814）
- ✅ 白屏与 IPC 问题已最终修复（v2.2.9）：固定端口段 41845-41847 + HTTP 服务器 + 完整 ACL（allow-* + remote.urls 精确带端口 origin），详见第 3 节「白屏与 IPC 反复 bug 终极解法」
- ✅ 沙盒文件访问已修复：security-scoped bookmarks + 弹窗授权 + 清理旧授权功能
- ✅ PNG 进程内化已完成（阶段 1.1）：imagequant + oxipng crate 接入
- ✅ JPG/WebP/AVIF 进程内化已完成：mozjpeg / webp / ravif crate 接入
- ✅ 两条产物线功能对齐：JXL 已从前端输出格式下拉移除（两版一致）；GIF 两版均有压缩功能（Direct gifsicle 减色更优，App Store image crate 重编码，属质量差异非功能差异）
- 🟡 App Store 审核待提交：2.2.9 已上传 ASC，需补全元数据 + 回复 network.server 解释（路径B）后提交审核
- ⬜ 引擎迁移后续：JXL（未来接入 jpegxl-sys 后可恢复 UI 选项）；GIF 减色优化（未来可用 imagequant 逐帧量化，当前有帧间闪烁风险暂不做）

### 8. 每次编译必须同时构建两条产物线（强制）

日常开发首选 `bash scripts/build_all.sh`，一次编译两版：
- **Direct 版**（default=cli-backends）→ 产物 `OctoShrink_direct.app`（加 `_direct` 后缀，与 App Store 版区分）
- **App Store 版**（appstore=inproc-backends）→ 产物 `OctoShrink.app`（原名）

两条线的 `productName` 都是 "OctoShrink"，Tauri 输出到同一路径。build_all.sh 先建 Direct 再重命名，避免覆盖。**不要只编译一版**——改完代码必须两版都过 `cargo check`，发布时用 `build_all.sh` 同时出两版。单独发布某一条线时用 `notarize.sh`（Direct）或 `build_appstore.sh`（App Store）。

---

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
| files.downloads.read-write | 不需要 | 不需要（代码无写下载目录逻辑，曾误开 → Apple "minimum entitlements" 自动分析风险；2.2.9 已移除） |
| network.server | 不需要 | 需要（本地 HTTP 服务器绕过沙盒阻止的 tauri://，见第 3 节终极解法） |
| network.client | 不需要 | 需要（WebContent 进程连本地 HTTP 服务器） |
| cs.disable-library-validation | 需要（加载内置 dylib） | 不允许（沙盒禁用） |
| cs.allow-dyld-environment-variables | 需要（DYLD_FALLBACK_LIBRARY_PATH） | 不允许（沙盒禁用） |

## 内置 CLI 工具与 Rust crate 对照

| CLI（Direct 版用）| Rust crate 替代（App Store 版用）| 状态 |
---|---|---|
| pngquant | imagequant crate（同源算法）| ✅ 已完成 |
| oxipng | oxipng crate（库版）| ✅ 已完成 |
| cjpeg (mozjpeg) | mozjpeg crate | ✅ 已完成 |
| cwebp | webp crate | ✅ 已完成 |
| avifenc | ravif crate | ✅ 已完成 |
| cjxl | jpegxl-sys | ⬜ 已从前端移除（两版一致）；engine 代码保留，未来接入后可恢复 UI |
| gifsicle | image crate（无减色优化）| ✅ 已完成（质量降级：无 gifsicle --colors=N 减色，两版均有 GIF 压缩功能）|

## 变更本文件的规定

- 任何 PR / 提交若改变两条产物线的并行结构、文件访问差异、entitlements 配置、CLI↔crate 映射 → 必须在本文件同步更新对应小节
- 本文件由 AI 失效风险最小化优先：每条规则都写成"行动项 + 为什么"，便于将来任何 Agent 读到时都能立即照做

## 参考

- [App Store 提交完整流程与注意事项](#app-store-提交完整流程与注意事项)
- docs/APPSTORE_MIGRATION_PLAN.md — 5 阶段路线图
- scripts/build_all.sh — 两版同时构建（日常首选，Direct 产物加 _direct 后缀）
- scripts/notarize.sh — Direct 产物线（构建→签名→公证→装订→DMG）
- scripts/build_appstore.sh — App Store 产物线（构建→签名→PKG）
- src-tauri/entitlements.plist — Direct entitlements
- src-tauri/entitlements-appstore.plist — App Store entitlements（沙盒权限）
- src-tauri/tauri.conf.json — Direct 配置（identifier = com.misswell.octoshrink）
- src-tauri/tauri.conf.appstore.json — App Store 配置（identifier = com.misswell.octoshrink.appstore，v2.2.6）
- src-tauri/capabilities/default.json — IPC 权限（App Store 版需显式声明所有 app 命令权限）
- src-tauri/permissions/commands.toml — app 命令 ACL 权限定义

## App Store 提交完整流程与注意事项

> 记录于 2026-07-21。基于 v2.2.0 → v2.2.6 的实际上架经验。每次上架前必读。

### 1. 前置准备（一次性）

- Apple Developer 账号（已就绪：Guofeng Liu - U8U443D7ZL）
- 两张证书（在 Keychain Access 中）：
  - `Apple Distribution: Guofeng Liu (U8U443D7ZL)` — 用于 codesign app
  - `3rd Party Mac Developer Installer: Guofeng Liu (U8U443D7ZL)` — 用于 productbuild 打 PKG
- Bundle ID 注册：`com.misswell.octoshrink.appstore`（已在 Apple Developer Portal 注册）
- App Store Connect 已创建 App：OctoShrink（Apple ID: 6792604654）
- App-Specific Password（用于 xcrun altool 上传）：在 appleid.apple.com 生成

### 2. 构建与签名

```bash
cd src-tauri
export CARGO_PROFILE_RELEASE_PANIC=unwind

# 构建 app bundle（App Store feature）
cargo tauri build --bundles app --features appstore --config tauri.conf.appstore.json

# 手动复制前端资源到 Resources（Tauri 默认不打前端进 app bundle）
cp -R ../frontend/. target/release/bundle/macos/OctoShrink.app/Contents/Resources/

# 用 Apple Distribution 证书签名
codesign --force --options runtime \
  --entitlements entitlements-appstore.plist \
  --sign "Apple Distribution: Guofeng Liu (U8U443D7ZL)" \
  target/release/bundle/macos/OctoShrink.app

# 打 PKG（用 3rd Party Mac Developer Installer 证书）
xcrun productbuild --component \
  target/release/bundle/macos/OctoShrink.app /Applications \
  --sign "3rd Party Mac Developer Installer: Guofeng Liu (U8U443D7ZL)" \
  OctoShrink-<version>.pkg
```

或直接用 `bash scripts/build_appstore.sh`（封装了上述步骤）。

### 3. 白屏与 IPC 反复 bug 终极解法（v2.2.8，务必遵守）

**根因**：macOS 27 App Sandbox 阻止 `tauri://localhost`（WKURLSchemeHandler 完全不工作）→ webview 拿不到内容 → 白屏。必须用本地 HTTP 服务器（监听 127.0.0.1 随机端口）服务前端资源。

**「来回修」真相**：历史上两个 commit 各解决一半，从未合并，故反复：
- `2672532`/`10e56fc`：有 HTTP 服务器（白屏解决）但 capabilities 只有 4 项 → app 命令不在 ACL → IPC 全失效（选图/拖图/移窗口失效）
- `b21cc53`：补全 17 个 `allow-*` + `remote.urls`（IPC 解决）但删了 HTTP 服务器 → 沙盒白屏

**正确方案（v2.2.9，缺一不可）**：
- `lib.rs` `#[cfg(feature = "inproc-backends")]` 块：`TcpListener::bind` **固定端口段** `[41845u16, 41846, 41847]`（带 fallback 防冲突），serve resource_dir 前端，`window.navigate("http://localhost:PORT/")`
- `entitlements-appstore.plist`：`network.server` + `network.client` 必需
- `capabilities/default.json`：17 个 `allow-*` app 命令权限 + `remote.urls: ["http://localhost:41845","http://localhost:41846","http://localhost:41847"]`（**精确匹配带端口 origin**）+ `core:window:allow-start-dragging`

**勿再犯**：
- ❌ 「tauri://localhost 在沙盒下正常工作，不需要 HTTP fallback」—— 错！macOS 27 沙盒阻止它。此断言曾写入本文件，导致 b21cc53 删 HTTP 服务器 → 白屏回归。
- ❌ **随机端口 `:0` + 无端口 `remote.urls: ["http://localhost"]`** —— 错！Tauri ACL 对 remote origin 精确匹配，`http://localhost` ≠ `http://localhost:41845` → IPC 静默失效（加不了图/拖不进图/窗口拖不动）。v2.2.8（`f064299`）即此 bug：修白屏却漏改端口匹配。**必须固定端口段 + remote.urls 精确列带端口 origin**。
- ❌ 单独用 HTTP 服务器不配 ACL → app 命令（remote origin）全被 Tauri ACL 拒，IPC 静默失效。
- ❌ `visible: false` + 延迟 `show()` → 窗口可能永不显示（曾误判为白屏根因，实际是独立问题）。

**验证方法**：`open` 签名+沙盒 .app（**非** `cargo tauri dev`，后者非沙盒不复现白屏），`screencapture` 截图确认 UI 渲染。b21cc53 的"截图确认无白屏"疑在非沙盒环境测，不可信。

### 4. IPC 权限（App Store 版必须配置）

- 在 `capabilities/default.json` 中显式声明所有 app 命令的 permission（约 17 个）
- 创建 `permissions/commands.toml` 定义权限 schema
- 不配置 → 前端 invoke 全部失败（静默，不报错）
- Direct 版不需要此配置（非沙盒，不检查 ACL）

### 5. 沙盒文件访问

- 用户选文件/拖入文件时，系统弹窗授权（security-scoped bookmarks）
- 授权后路径写入 BookmarkStore，后续可续访
- 提供「清理旧授权」功能，避免书签过期导致访问失败
- `files.user-selected.read-write` + `files.bookmarks.app-scope` entitlements 必须开启

### 6. 上传到 App Store Connect

```bash
xcrun altool --upload-app \
  -f OctoShrink-<version>.pkg \
  -t macOS \
  -u misswell@foxmail.com \
  -p <app-specific-password>
```

- 版本号（CFBundleVersion）必须比上次上传的**高**，否则报 `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE`
- 上传成功后约 15-30 分钟才出现在 App Store Connect 构建版本列表
- macOS beta 可能无法安装 Transporter app → 用 `xcrun altool` 命令行替代

### 7. App Store Connect 元数据（提交审核前必须补全）

| 项目 | 要求 | 备注 |
|---|---|---|
| 截图 | 至少 1 张 | 1280×800 / 1440×900 / 2560×1600 / 2880×1800 |
| 描述 | 必填 | 简体中文 |
| 关键词 | 必填 | 100 字符以内 |
| 技术支持网址 | 必填 | URL |
| 版权 | 必填 | 如 "© 2026 Guofeng Liu" |
| 主要类别 | 必填 | 如「工具」/「图形和设计」|
| 出口合规证明 | 必填 | 选「不属于上述的任意一种算法」或在 Info.plist 加 `ITSAppUsesNonExemptEncryption=false` |
| 隐私政策网址 | 必填 | 在「App 隐私」页面填写 |
| 联系信息 | 必填 | 姓名、电话、邮箱 |
| 年龄分级 | 必填 | 设置年龄分级问卷 |

### 8. 常见错误与解决

| 错误 | 原因 | 解决 |
|---|---|---|
| `bundle version must be higher` | 版本号重复 | 递增 tauri.conf.appstore.json 的 version |
| `缺少出口合规证明` | 未声明加密 | 选「不属于上述」或加 Info.plist key |
| 白屏 | 沙盒阻止 tauri://（缺 HTTP 服务器）或缺 ACL（有 HTTP 服务器但 app 命令被拒） | HTTP 服务器 + 完整 allow-* + remote.urls（见第 3 节终极解法） |
| 无法选文件/拖入 | 沙盒缺权限 | 检查 entitlements + bookmarks 配置 |
| 窗口无法拖动 | 缺 start-dragging 权限 | capabilities 加 `core:window:allow-start-dragging` |
| 中间有方形洞 | CSS/布局问题 | 检查前端透明区域 |
| Transporter 无法安装 | macOS beta | 用 `xcrun altool` 命令行 |

### 9. 版本号管理

- App Store 版与 Direct 版版本号保持一致（如都是 2.2.6）
- 每次上传构建版本号必须递增
- `tauri.conf.appstore.json` 的 `version` 字段 = CFBundleShortVersionString（显示版本）
- `tauri.conf.appstore.json` 的 `version` 也用作 CFBundleVersion（构建版本）
  - 如需分离，在 `tauri.conf.appstore.json` 加 `"macOS": { "buildNumber": "..." }`

### 10. network.server entitlement 的 App Store 审核（路径 B，勿走路径 A）

`network.server` 是 HTTP 服务器方案必需。Apple 自动分析可能标记"有 entitlement 但无匹配功能"（v2.2.7 曾因此被拒）。

- ❌ **不要走路径 A（移除 network.server）**——移除后沙盒白屏回归（tauri:// 不工作）。

- ✅ **走路径 B（保留 + 解释用途）**，需完成 Apple 要求的**两步**（缺一不可，否则视为未回应驳回）：
  1. **回复驳回消息**：在 App Store Connect 该提交的消息线程直接 reply，描述 app 如何使用 `network.server`。
  2. **写入 App Review Information**：App Store Connect > App Review Information 附上同样说明。

回复 / App Review Information 文本（直接复制，已对齐 Apple 原话措辞）：

> `com.apple.security.network.server` — 本 app 运行时 **listen for and respond to incoming network connections**：在 app 进程内启动本地 HTTP 服务器（`TcpListener::bind("localhost:41845")`，带 41846/41847 fallback），仅监听 127.0.0.1，向 app 自身 WKWebView 提供打包在 Resources 目录内的前端资源（index.html / app.js / style.css）。必须保留：macOS 27 App Sandbox 阻止 `tauri://localhost` 自定义协议（WKURLSchemeHandler）导致白屏，本地 HTTP 服务器是 app 加载自身前端界面的唯一方式。该服务器仅监听 localhost、只服务 app 自带资源（带路径穿越防护）、不发起任何出站连接、不接受外部请求。`com.apple.security.network.client` 允许 app 的 WebContent 进程连此本地服务器获取前端资源。

> ⚠️ **与全局 AGENTS.md 冲突**：全局 `~/.codex/AGENTS.md` 有一条（2026-07-21）称"tauri:// 沙盒下正常、白屏是 visible:false 导致、应删 HTTP 服务器"。经实测（v2.2.8 HTTP 服务器版正常，b21cc53 删 HTTP 后白屏），**以本节为准：HTTP 服务器 + network.server 必需，勿删、勿走路径 A**。全局那条疑在非沙盒环境验证，不可信。

### 11. provisioning profile：仅 TestFlight 需要，提交审核不需要

**关键结论（2.2.6 + 2.2.9 实证）**：macOS App Store 提交审核**不强制** `embedded.provisionprofile`（与 iOS 不同）。2.2.6/2.2.9 无 profile 照样上传成功 + 进入审核（2.2.6 被审核驳回是 network.server 问题，非 profile）。`xcrun altool --upload-app` 上传 .pkg 不查 profile。

上传时 ASC 返回 1 个 warning 90889："Cannot be used with **TestFlight** because the bundle is missing a provisioning profile"——**只阻止 TestFlight，不阻止提交审核**。`altool` 输出 `UPLOAD SUCCEEDED with no errors, 1 warning` 即可提交审核。

| 目标 | 需要 embedded.provisionprofile 吗 |
|---|---|
| 上传到 App Store Connect | ❌ 不需要 |
| 提交审核（过审上架） | ❌ 不需要（2.2.6 / 2.2.9 实证） |
| TestFlight 内测分发 | ✅ 需要 |

**何时需要 profile**：仅当要 TestFlight 内测分发给测试者时才嵌入。过审上架直接上传 + 提交审核即可，不必等 profile。

嵌入步骤（TestFlight 时才用）：codesign 前 `cp <profile>.provisionprofile "$APP/Contents/embedded.provisionprofile"`，再 codesign + productbuild。profile 从 Apple Developer > Profiles 下载（macOS → App Store 类型，App ID = com.misswell.octoshrink.appstore，证书 Apple Distribution: Guofeng Liu）。

### 12. build_appstore.sh 变量引用必须用花括号

`set -u` 模式下，`$VAR` 后紧跟非 ASCII 字符（如全角括号 `）`）会被 bash 误解析为变量名延续 → unbound variable。**变量引用一律 `${VAR}` 花括号界定**。曾因 `log "...$INSTALLER_IDENTITY）"`（全角右括号）报 `INSTALLER_IDENTITY unbound` 卡住 productbuild。
