# OctoShrink → Mac App Store 改造方案

## 一、为什么要改 / 当前架构冲突清单

当前 v2.2（Developer ID + 公证）能跑通，靠的是 **3 个被 App Store 拒绝的机制**：

| 当前机制 | App Store 规则 | 冲突点 |
---|---|---|
| `DYLD_FALLBACK_LIBRARY_PATH` 让 7 个 CLI 工具找到 17 个内置 dylib | `com.apple.security.cs.allow-dyld-environment-variables` 禁止 | 必须去掉 |
| 加载 Homebrew 编译、非同团队签名的 17 个 dylib | library validation 在沙盒强制启用 | `disable-library-validation` 在沙盒被拒 |
| 启动 7 个外部子进程做压缩 | 沙盒只允许启动同样沙盒化、由你签名的 Helper | 每个工具要么沙盒化改造，要么改进程内调用 |
| 任意路径 `fs::read/write`（recursive `walk_dir`） | 沙盒只允许用户主动选过的路径 + 安全书签 | 文件访问要重做 |
| `Command::new("open").arg("-R")` 打开 Finder | 沙盒禁止启动 Finder | 改用 `NSWorkspace` / opener 插件 |

## 二、核心思路：CLI 子进程 → 进程内 Rust 库

把"启动外部 CLI"改成"直接在 Rust 进程内调用压缩库"。`image` crate 已经在用，**大多数 CLI 工具都有 1:1 的 Rust crate 对应**，且用 `*-sys` 模式静态链接 C 代码，最终编进同一个 Mach-O，用你的 TeamID 签一次即可，**不再有 dylib 库验证问题**。

### 引擎替换映射表

| 格式 | 当前（CLI） | 替换为（进程内） | 静态/动态 | 质量/能力损失 |
---|---|---|---|---|
| PNG 有损（量化） | pngquant | `imagequant` crate（libimagequant 绑定，pngquant 同源算法） | C 库静态链接 | 无（同算法） |
| PNG 无损 | oxipng | `oxipng` crate（库版，纯 Rust + 一点 C/Zopfli） | 基本纯 Rust | 无 |
| JPEG | cjpeg (mozjpeg) | `mozjpeg` crate（mozjpeg C 库绑定；build.rs 用 `cc` 编译入静态库） | C 静态链接 | 无（同一套 trellis quant） |
| WebP | cwebp | `webp` + `libwebp-sys`（libwebp 静态链接） | C 静态链接 | 无 |
| AVIF | avifenc | `libavif` + `libavif-sys`（或纯 Rust 的 `ravif` 用 `rav1e`，慢但无 C 依赖） | C 静态 / 纯 Rust 二选一 | 用 libavif 无损；用 ravif 慢但更易过审 |
| JPEG XL | cjxl | `jpegxl-sys`（libjxl 绑定，C++ 静态链接）—— 若审计难推进则**先在 App Store 版本移除 JXL 输出** | C++ 静态 / 临时移除 | 可能临时降级（移除 JXL 输出） |
| GIF | gifsicle | `gif` crate（解码/转码，动图优化弱于 gifsicle） | 纯 Rust | **动图体积优化能力下降**，需评估是否仍值得上 |
| 进程后备 | — | 已有 `image` crate（保留） | 纯 Rust | 现状备用 |

**关键结论**：除 **GIF 动图优化** 和 **JPEG XL** 可能需要短期降级外，其余格式可做到无损迁移（同算法同质量）。

## 三、改造路线（分阶段，每阶段独立可发布）

### 阶段 0 · 保留两条产物线（先做）

用 Cargo feature 分叉，**不破坏现有 Developer ID 分发**：

```toml
# Cargo.toml
[features]
default = ["cli-backends"]        # 现有 Developer ID / DMG 路径
cli-backends = []                  # 调 7 个外部工具 + 17 dylib（保留）
appstore = ["inproc-backends"]     # App Store 路径
inproc-backends = []               # 进程内库
```

- Developer ID 构建沿用 `notarize.sh`（feature = default）→ 仍发 DMG
- App Store 构建用新 feature `appstore`：另起构建脚本、另一套 entitlements、产物是 `.pkg`
- `engine.rs` 用 `#[cfg(feature = "inproc-backends")]` 在两条实现间切换，UI 行为不变

### 阶段 1 · 引擎改造（最大工作量，内部可测）

1. 新建 `src-tauri/src/engine_inproc.rs`，提供与 `engine.rs` 同样接口：`compress_image(file, options) -> EngineResult`、`compress_smart`、`compress_to_format`、`EngineResult/CompressOptions` 结构沿用。
2. 实现 7 个新函数（过程内），**接口签名与现有 CLI 版一致**——便于 `#[cfg]` 切换：
   - `compress_png_inproc`: 先 `imagequant` 量化 → 失败则 `oxipng` 无损 → 兜底 `image` crate
   - `compress_jpg_inproc`: `mozjpeg` 编码（输入 RGB/RGBA → mozjpeg encoder），兜底 `image` crate
   - `compress_gif_inproc`: `gif` crate 解码 + 重编码帧，无动图优化能力就标记"无优化空间"
   - `compress_to_webp_inproc`: `webp::Encoder::from_image`，`set_quality`
   - `compress_to_avif_inproc`: `libavif` API（`AvifEncoder::new + encode_rgba`），兜底 `ravif`
   - `compress_to_jxl_inproc`: `jpegxl-sys`，或先 cfg 掉返回"App Store 版暂不支持"
3. 分批接入 `Cargo.toml`：
   ```toml
   [target.'cfg(all(target_os="macos", feature="inproc-backends"))'.dependencies]
   imagequant = "4"
   oxipng = "9"
   mozjpeg = "0.10"
   webp = "0.3"
   libavif = "0.14"   # 备选 ravif = "0.9"
   jpegxl-sys = "0.10"  # 可选
   gif = "0.13"
   ```
   所有 `*-sys` crate 都用 `cc` 在 build 时把 C 库编进静态 `.a`，编进最终单个 Mach-O。无 dylib、无 `DYLD_*`、无 library validation 问题。
4. 写单元测试：固定样本图 → 对比输出字节与 CLI 版编码结果的不严格相等（用长度和 SSIM/PSNR 容忍度判定），保证迁移不退化。
5. 切 `#[cfg(feature = "inproc-backends")]` 让 `compress_png/jpg/gif/webp/avif/jxl` 走新实现；保留 `#[cfg(feature = "cli-backends")]` 老路径。

### 阶段 2 · 沙盒与文件访问改造

#### 2.1 新 entitlements

新增 `entitlements-appstore.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key> <true/>
    <key>com.apple.security.files.user-selected.read-write</key> <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key> <true/>
    <key>com.apple.security.files.downloads.read-write</key> <true/>
</dict>
</plist>
```

- `app-sandbox` = 强制
- `files.user-selected.read-write` = 用户用文件/文件夹选择器选过的能读写
- `files.bookmarks.app-scope` = 把选过的文件夹记成安全书签，下次启动还能直接访问（避免每次重新选）
- `files.downloads.read-write` = 输出到"下载"目录免再选
❌ 不要这两个（删掉）：
- ~~`com.apple.security.cs.disable-library-validation`~~
- ~~`com.apple.security.cs.allow-dyld-environment-variables`~~

#### 2.2 文件访问改造点

| 命令 | 现状 | 改造动作 |
---|---|---|
| `select_files` / `select_folder` / `select_output_dir` | `tauri_plugin_dialog` 选过即用 | 保留；选到的路径**立即建 bookmark 并存**，下次启动恢复 |
| 拖放（webview drag-drop 在 app.js 第 200 行） | Tauri 给 `drop` payload 中的文件路径 | Tauri 沙盒下 drop 会给 security-scoped URL，需把它存为 bookmark；递归扫描子目录需要在书签作用域内做 |
| `walk_dir` 递归（engine.rs L52） | `fs::read_dir` 任意路径 | 沙盒下只对**用户选过/拖过的根**递归；子目录访问需要该目录的 security-scoped bookmark；建议限制：
oot 已选则可递归下到该树内） |
| `write_output_file`（commands.rs L100） | `replace`（覆盖原文件）/`suffix`（同目录新文件）/`folder`（指定输出目录） | 三种模式都在沙盒可行，**前提**：原文件路径或输出目录有 bookmark；建议 `replace` 在覆盖前用 `FileProviderProxy`，或直接用书签覆盖 |
| `backup`（L118 `temp_dir().join("octoshrink-backups")`） | `std::env::temp_dir()` | 沙盒下 `NSTemporaryDirectory()` 是每个 app 唯一的，OK ✓ |
| `restore_original` | `fs::copy(backup, original)` | 同上：原文件路径需有 bookmark。这部分最敏感，**用户重开应用后还能恢复**靠 app-scope bookmark |
| `open_in_finder` | `Command::new("open").arg("-R")` | 改用 `NSWorkspace.activateFileViewerSelectingFile`（objc2-app-kit 已有依赖）或 tauri-plugin-opener |
| `read_image_dataurl` / `get_file_sizes` / `read_image_dataurl` | `fs::read/path` | 在已授权路径下 OK；为批量缩小图，建议仍走 image crate，缓存数据避免重复 IO |
| `export_all` | `fs::copy` 到原目录 | 需要对目标目录有 bookmark；若没有，再问一次用户 |

#### 2.3 封装一个 `BookmarkStore`

新建 `src-tauri/src/sandbox.rs`：

```rust
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

pub struct BookmarkStore {
    map: Mutex<HashMap<PathBuf, /* NSData bookmark, objc2 */}},
    persistence_path: PathBuf,
}

impl BookmarkStore {
    pub fn add(&self, path: PathBuf) -> Result<(), String> { /* resolve URL, create bookmark, persist */ }
    pub fn access(&self, path: &Path) -> Option<SecurityScopedResource> { /* resolve bookmark, start accessing */ }
    pub fn persist(&self) -> Result<(), String> { /* 写入 app support json */ }
    pub fn restore(&self) -> Self { /* 启动时读 */ }
}
```

- 在 `setup()` 中调用 `BookmarkStore::restore()`，把上次选过的文件夹恢复成可访问
- 在 `select_folder` / `select_files` / drag-drop handler / `select_output_dir` 提交时调用 `store.add(path)` 并 `persist()`
- 所有 `fs::*` 调用前用 `store.access(p)` 拿到 start-accessing })}
- Tauri 的 `tauri-plugin-fs` 已经替我们管这个，可以考虑依赖它而非自己实现（看版本支持情况）

### 阶段 3 · 构建产物与签名改造

#### 3.1 证书切换

App Store 用 **Apple Distribution** 证书（不是 Developer ID Application）：

```bash
# 在 Xcode：Settings → Accounts → 你的 Apple ID → Manage Certificates → + → Apple Distribution
security find-identity -v -p codesigning   # 应看到 "Apple Distribution: misswell@foxmail.com (XXXXXXXXXX)"
```

| 路径 | 证书 | 公证/审核 |
---|---|---|
| Developer ID（DMG 直发，保留） | Developer ID Application | notarytool 公证 |
| App Store | Apple Distribution | App Store Connect 审核 |

#### 3.2 构建脚本

新增 `scripts/build_appstore.sh`：

```bash
#!/bin/bash
set -euo pipefail
cd src-tauri

# 用 appstore feature 构建进程内库版本，无外部 CLI / dylib
cargo tauri build --bundles app --features appstore

# 用 Apple Distribution 重新签名（hardened runtime 可关，sandbox 自带）
APP=target/release/bundle/macos/OctoShrink.app
codesign --force --timestamp --options runtime \
  --entitlements entitlements-appstore.plist \
  --sign "Apple Distribution: misswell@foxmail.com" "$APP"

# 生成 product archive (.pkg)
xcrun productbuild --component "$APP" /Applications \
  --product "$APP/Contents/Info.plist" target/release/OctoShrink-2.2.0.pkg

# 上传到 App Store Connect（需要 App Store Connect API key 或 App Store Connect 账户）
xcrun altool --upload-app -f target/release/OctoShrink-2.2.0.pkg \
  --type macos-app --username "misswell@foxmail.com" \
  --password "@keychain:AC_PASSWORD" \
  --asc-provider "your_team_provider_id"
# 或更现代：
xcrun notarytool submit ... # 不适用，App Store 不走 notarytool
# App Store Connect 用 StoreKit + Transporter:
xcrun transporter -m assemble -i ... # 或 Transporter.app 拖进去
```

> 实际生产更推荐用 **Xcode** 的 "Validate" + "Deliver to App Store" 按钮，避免一把梭：
> 1. `cargo tauri build` 生成 .app
> 2. Xcode 新建 "Mac App" wrapper target 引用 .app，Archive → Distribute App → Mac App Store
> 3. Xcode 自动跑签名 + productbuild + 上传

### 阶段 4 · App Store Connect 元数据准备

在 App Store Connect 网页：

- **新建 App**：Platforms = macOS；Bundle ID = `com.misswell.octoshrink`（已在用）
- **基本信息**：
  - 名称：`OctoShrink - 章小压`（需做名称搜索冲突检查）
  - 副标题：`免费开源图片压缩工具`（zh）
  - 主类别：Photography（图片处理）或 Graphics & Design
  - 次类别：Utilities
- **截图**：
  - macOS 6.5" / 13" 各一套（亮 + 暗 ×6 张）
  - README 已有截图：`assets/screenshot-light.png` / `screenshot-dark.png` / `compare.png`，需补 Mac App Store 规格尺寸
- **应用描述**：zh-Hans 必填，en 加一份
- **关键词**：图片压缩、批量压缩、PNG 优化、WebP、AVIF、JPEG XL、图片瘦身（最多 100 字符）
- **隐私问卷（App Privacy）**：
  - 数据采集：**不采集**（声明 0）
  - 数据使用：仅本地处理（声明）
  - 这是 App Store 弱审核点：如果你的进程内库（如 imagequant/libavif）做了任何分析遥测，要关掉
- **定价**：免费（建议，开源应用收费审核更严）
- **审核备注**：
  - 说明应用是开源工具
  - GIF 动图若做了降级，需说明（避免审核员按旧功能点拒）

### 阶段 5 · 审核前自检（App Sandbox Validator）

```bash
# 沙盒合规检查
xcrun sandbox-check --validate "$APP"

# 检没用的 private API、滥用 entitlement
codesign --display --entitlements - "$APP"

# 用 Transporter 校验 archive
xcrun transporter -m verify-asset ...
```

- 手动跑一遍完整流程：启动 → 选文件夹 → 批量压缩 → 恢复原图 → 切暗色 → 输出 AVIF/WebP
- **重点测** sandbox 下 push：拖入文件夹 / 退出重开能否恢复访问 / 输出到 Downloads

## 四、风险与取舍

| 风险 | 取舍 |
---|---|
| GIF 动图优化弱化（gifsicle 是动图专精）| App Store 版 GIF 走 `gif` crate 做基础压缩，体积改善有限；UI 上对 GIF 的"无优化空间"结果增多。可后续接入 `gifsicle` 进程内化（有人尝试过纯 Rust 移植，功能不全） |
| JPEG XL 是否保留 | libjxl 是 C++，静态链 + App Store 审计进展慢；**建议 App Store v1 移除 JXL 输出**，保留 Developer ID 版全部格式。后期再补 |
| `imagequant` / `mozjpeg` 等是否算"私有 API" | 不算私 API；属于开源第三方库静态链。审核关心的是 sandbox/隐私/功能匹配，不排斥静态 C 库 |
| 安全书签的 UX | 用户首次选过的文件夹，重启后不再询问；如果用户从外部挪动该文件夹，书签会失效，需友好提示重选 |
| 改造工作量 | 阶段 1 ≈ 2-3 天（7 个函数接入 + 单测）；阶段 2 ≈ 2 天（书签 + 沙盒实测）；阶段 3-5 ≈ 1 天 + 审核等待 |
| 双产物维护 | `default` = CLI 分发不破坏；`appstore` = 条件编译；CI 可两个都发 |

## 五、推荐执行顺序

1. **阶段 0**：Cargo feature 双线（先做，让后续改动不破坏 Developer ID 用户）
2. **阶段 1.1**: 先接 `imagequant` + `oxipng`（PNG，最常用，最易验证），跑通 `inproc-backends` 框架，feature gated 测试
3. **阶段 1.2**: `mozjpeg` + `webp`（JPEG/WebP，覆盖率次大）
4. **阶段 1.3**: `libavif` / `ravif`（AVIF），GIF，JXL 暂 cfg 掉
5. **阶段 2**: sandbox entitlements + bookmark store + open_in_finder 改 NSWorkspace
6. **阶段 3**: `build_appstore.sh` + Apple Distribution 证书 + productbuild
7. **阶段 4**: App Store Connect 元数据 + 截图 + 隐私问卷
8. **阶段 5**: 上传 Transporter → 等审核 → 反馈迭代

## 六、预判的审核拒绝点（值得提前避免）

1. **沙盒不合规**：用 sandbox-check 在提交前跑一次，把访问越界路径全部封掉
2. **功能与截图不符**：如果 JXL 在 App Store 版降级移除，截图里就不能出现 JXL 选项
3. **崩溃/未处理错误**：sandbox 文件访问失败要 graceful 降级，不要 panic
4. **隐私问卷不一致**：声明"不采集数据"，就确保绑定的 C 库（libavif/imagequant/mozjpeg 等）没内置遥测 — 已确认这些库都是无遥测的纯算法实现 ✓
5. **macOS 最低版本**：(minimumSystemVersion = 14.0) 当前 Engineer 已设，App Store 要求 ≤ OS 最新版减 2，14.0 在 2025-2026 合规 ✓

## 七、决策建议

- **如果目标是"曝光到 App Store 用户"**：值得做，但工作量是真的一块新功能开发（~1 周）。
- **如果目标是少维护成本**：保持 Developer ID + DMG 现状更划算——DMG 已经"双击即用"，体验差距不大。
- **建议方案**：先执行**阶段 0 + 阶段 1.1**（PNG 进程内化）作为 PoC，验证工作量预期；若 1 天内跑通，再继续，否则暂停评估 ROI。

---

## 附：现状架构速览（改造参考点）

```
src-tauri/src/
├── engine.rs            # 669 行：所有 CLI 调用都在这里（compress_png/jpg/gif/webp/avif/jxl + cli_to_file/make_command）
├── commands.rs          # 711 行：tauri commands（select_files/select_folder/save_file/restore_*/open_in_finder/export_all 等）
├── lib.rs               # 55 行：tauri Builder + invoke_handler + setup（resource_dir 初始化）
└── main.rs              # 6 行：调用 lib::run

frontend/app.js          # 1097 行：drag-drop @ L200、invoke select_files/select_folder @ L228/235、restore @ L691

src-tauri/entitlements.plist        # 现有（Developer ID 版）：disable-library-validation + allow-dyld
src-tauri/entitlements-appstore.plist # 新增：app-sandbox + user-selected + bookmarks.app-scope
src-tauri/resources/   # 17 dylib + 7 CLI → App Store 版整体丢弃
```

## 八、关键代码改造样例

### PNG lossy 无需改 `compress_png` 对外接口，只换内部实现：

```rust
// engine_inproc.rs
pub async fn compress_png(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = std::fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    // 1. imagequant 量化（替代 pngquant CLI）
    let img = image::open(file).ok();
    if let Some(img) = img {
        let rgba = img.to_rgba8();
        let (w, h) = (rgba.width(), rgba.height());
        let attrs = imagequant::Attributes {
            max_colors: 256,
            min_quality: quality.saturating_sub(10).max(10) as i32,
            max_quality: quality.min(100) as i32,
            speed: 3,
            ..Default::default()
        };
        if let Ok(palette) = imagequant::quantize(&rgba, w, h, attrs) {
            // 用 palette 写回 PNG（借助 image crate 的 Palette encoder）
            if let Ok(data) = encode_indexed_png(&palette, w, h) {
                if (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "png", "imagequant");
                }
            }
        }
    }

    // 2. oxipng 无损（库版）
    let mut opts = oxipng::Options::from_preset((quality / 20).min(6).max(1));
    opts.strip = oxipng::StripChunks::Safe;
    if let Ok(data) = oxipng::optimize(file, &opts) {  // 或 oxipng::optimize_mem
        if (data.len() as u64) < original_size { return make_engine_result(original_size, data, "png", "oxipng"); }
    }

    // 3. image crate 兜底
    if let Some(data) = compress_png_with_image(file) {
        if (data.len() as u64) < original_size {
            return make_engine_result(original_size, data, "png", "image-png");
        }
    }
    no_improvement(original, "png", "imagequant", original_size, original_size)
}
```

— 同法替换 JPEG（mozjpeg encoder）、WebP、AVIF。`CompressOptions` / `EngineResult` 不变 → `commands.rs` / `lib.rs` **零改动**。

## 九、估时（粗）

| 阶段 | 估时 | 风险 |
---|---|---|
| 0 双线骨架 | 0.5 天 | 低 |
| 1 引擎进程内 | 2.5 天 | 中（JXL/GIF 有不确定性） |
| 2 沙盒 + 书签 | 2 天 | 高（文件访问 UX 调试） |
| 3 构建脚本 | 0.5 天 | 低 |
| 4 ASC 元数据 | 2 小时 | 低 |
| 5 提交 + 等审核 + 迭代 | 1-3 周（等审核） | 中 |
| **总计工作量（不含等待）** | **~1 周（5 工作日）** | **含 1-3 周审核等待** |

## 十、给出下一步

本文件是改造蓝图。**真正落地的第一步建议**：

```bash
# 1. Cargo.toml 加 features default = ["cli-backends"] / appstore = ["inproc-backends"]
# 2. 加 imagequant crate + oxipng crate 的依赖（PNG 先动）
# 3. 写 engine_inproc.rs 的 compress_png_inproc 函数 + 3 张样本图单测
# 4. 用 `cargo test --features inproc-backends` 跑通 → 证明进程内可行
# 5. 再决定是否继续阶段 1.2/1.3
```

我可以帮你把阶段 0 + 阶段 1.1（PNG 进程内化）落到代码里，作为可运行 PoC（不到 1 天的工作量），跑完再决定是否推进。要继续吗？

## 附：Tauri 2 + 沙盒已知的坑

1. Tauri 的 `tauri-plugin-fs` 已支持 `security-scope` 配合 sandbox；不要自己造 bookmark 轮子，先用它
2. Tauri 的 drag-drop 事件在 sandbox 下需要 `webview/dragDropEnabled = true` 和允许 file URLs，要确认 webview 配置
3. `tauri-plugin-opener` 用于 `open_in_finder` 替代 `open -R`（沙盒安全）
4. webview 本身的脚本引擎不是 sandbox 函数——sandbox 只限制 FS/进程/网络，webview 行为不受影响
