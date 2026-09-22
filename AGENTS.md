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
cli-backends = ["dep:tauri-plugin-updater"] # 7 个 CLI + macOS GitHub 在线更新
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
cargo tauri build --features appstore --bundles app -- --no-default-features
bash scripts/build_appstore.sh                 # 一键：构建→签名→productbuild→PKG（待落地）

# 单元测试
cargo test                                     # 默认 feature（cli-backends）
cargo test --features inproc-backends          # 进程内版
npm run test:frontend                          # 前端纯逻辑（队列/暂停/历史页/恢复）
bash scripts/test_swift_history.sh             # Swift 线历史·备份·暂停自检（真跑文件系统）
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
- ✅ App Store 线已做到**真正全进程内**：`engine_inproc.rs` 不再有优先 spawn 打包 CLI 的分支（沙盒子进程拿不到 security-scoped 授权，那条路径必然失败），`build_all.sh` 也不再往 App Store .app 里复制 CLI/dylib；两个构建脚本 + 一个源码自检测试共同守住"包里无第三方可执行文件、引擎无 spawn"（见「App Store bundle 自检」）
- ✅ JPG/WebP/AVIF 进程内化已完成：mozjpeg / webp / ravif crate 接入
- ✅ macOS 系统转换模式已接入：两条产物线共用 ImageIO/CoreGraphics，支持 JPEG/PNG/HEIF、Finder 尺寸档位和元数据保留，不调用外部进程
- ✅ 输出文件名后缀支持自定义：默认 `_compressed`，两条产物线共用 `outputSuffix`，并对路径分隔符做安全清理
- ✅ 两条产物线功能对齐：JXL 已从前端输出格式下拉移除（两版一致）；GIF 两版均有压缩功能（Direct gifsicle 减色更优，App Store image crate 重编码，属质量差异非功能差异）
- ✅ 对比视图已改为独立原生窗口（未发版）：`compare.html` + `compare_window.js`，label="compare"，由 `open_compare_window` 命令创建（Direct 用 tauri:// 内嵌页，App Store 用本地 HTTP 页），自由缩放可大于主窗口、自带红绿灯；载荷经 `pending_compare` 状态 + `take_compare_window_payload` 首屏取回，`compare-open` / `compare-results-changed` 事件双向同步；`on_window_event` 仅在 label=="main" 关闭时 exit(0)；首屏与 resize 均按"适合窗口"fit 适配（先 showPanel 再测量视口，隐藏态测量会得到 0 而回退 100%，大图只显示局部），缩放下限 0.02，重置按钮=重新适配，用户手动缩放后 resize 不再打断
- ✅ 安全暂停已接入（三线一致）：压缩中可暂停/继续，只拦「还没开始」的文件，绝不 kill 正在跑的 CLI 子进程；进度按钮文案变「暂停中…」，旁边一个小号 [暂停]/[继续]。**取消一个文件只 `wake_waiters()`、绝不 `resume()`**（详见「安全暂停」），整批取消走一次 `cancel_batch`
- ✅ 压缩历史 + 原图保留/恢复已接入（三线一致）：`history.rs::HistoryStore` / Swift `Services/HistoryStore.swift` 落 App Support（**不再是临时目录**），历史页/设置页为主窗口内部视图，恢复统一走一个服务（`restore_original` / `restore_history_entry` / `restore_all` 共用 `HistoryStore::restore`），保留档位为「不保留」（默认，退出时清理）或 1/3/7/14/30 天（启动时按天清理，详见下一节）
- ✅ 历史页每一行都有与「压缩完成」那一行对等的按钮（三线一致）：另存为 / 对比查看 / 恢复原图 / 删除这次压缩结果 / 访达 / 复制日志，全部由 `sourceExists`·`backupExists`·`outputExists` 三个读取时现算的派生字段决定，按钮不成立就不画；后缀模式给「删除这次压缩结果」而不是「恢复原图」，清空历史的确认框数得清带走几份原图备份（详见「历史页每一行的按钮」）
- ✅ 覆盖事务与崩溃安全已接入（**三条线一致**）：`output_transaction.rs::TransactionStore` ↔ Swift `OutputTransactionStore.swift` 在覆盖前记账、`history.add` 落盘后才销账，启动时 `recover()` 补记或自动回滚上次中断的覆盖；`history.json` 严格读取（损坏→隔离 + 按 `backup-meta.json` 重建 `recoveryAvailable` + 本次启动锁死备份 sweep）；`write_output_file` 全链路 `Result`（任一步失败必须把 `CompressResult.success` 翻成 false）；备份 key 从 `DefaultHasher` 迁到 FNV-1a 64（老 key 只读复用/续认，含书签）；`MAX_HISTORY_ENTRIES = 10_000`
- ✅ CPU 使用上限已接入（三条线一致）：设置页「性能」小节 + `CompressionScheduler`（暂停与并行预算同一套闸门）+两层预算（并发文件数 × 单编码器内部线程），检测见 `system_info.rs` / `SystemInfo.swift`，详见「CPU 使用上限（三条线共用不变量）」
- ✅ Swift 原生线（`swift/`）与两条 Tauri 线功能对齐，历史/备份/覆盖事务/暂停语义一致，但存储根目录独立且少一层 `history/`（`~/Library/Application Support/com.misswell.octoshrink.swift`），三条线互不读写对方的 history.json
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
| walk_dir 递归 | fs::read_dir 任意路径；稳定排序并按规范路径去重，前端批次使用已展开文件快照 | 同上 + 仅在已书签根内递归 | 沙盒只认授权范围；队列不能因重复目录或处理期间新增文件而改变 |
| 队列批次文件清单 | 导入完成后展开并去重，开始处理时只提交该批次快照；目录根通过 `sourceRoots` 保留相对输出路径 | 同上，书签授权范围内执行 | 避免处理中追加、异步扫描乱序和清空后旧事件回流 |
| write_output_file | ①`ensure_backup`（写不成就不碰用户文件）②写 `history/transactions/<id>.json` 记账 ③同目录 `.octoshrink-write-<millis>.tmp` ④flush + fsync ⑤rename 覆盖目标 ⑥`history.add`（失败=回滚：备份写回源文件、删生成结果、销账）⑦ 删账。系统跨格式覆盖时改扩展名并避让同名目标；后缀模式使用自定义 `outputSuffix`（默认 `_compressed`） | 系统转换开始前强制经文件夹选择器授权，随后写入已授权目录；后缀模式使用同一自定义 `outputSuffix` | 沙盒不能依赖单文件授权写入旁路新文件；两版需保持输出命名一致。**落盘任一步失败都必须把 `CompressResult.success` 翻成 false**，UI 绝不许显示「压缩完成」 |
| restore_original / restore_history_entry / restore_all | 三条命令共用同一个恢复服务 `HistoryStore::restore`：备份 → `.octoshrink-restore-<nanos>.tmp` → fsync → rename 覆盖源文件 → **历史状态落盘成功之后**才删本次生成的压缩输出与备份目录；命中冲突（大小或 mtime 变化 >2 s，仅 replace 模式）时返回 `conflict=true`，前端确认后带 `force=true` 重试。`RestoreOutcome` 额外回报 `output_mode`，前端据此决定说「已恢复原图」还是「已删除这次压缩结果」 | 同上，源图/输出/备份路径均经 bookmark 授权；路径一律由 historyId 从存储读取，前端不拼路径 | 沙盒；两版恢复语义一致，**不允许复制三套恢复逻辑**。顺序反了会出现"历史说已恢复、备份已删、原图没写回" |
| 历史页每一行的按钮 | `historyRowActionDefs(entry)`（前端）↔ `historyRowActions(_:)`（Swift 服务层）按 `sourceExists` / `backupExists` / `outputExists` 三个**读取时现算**的派生字段决定：另存为 → 对比 → 反悔（恢复原图 或 删除这次压缩结果，二选一）→ 访达 → 复制日志 | 同上，同一份前端代码、同一套判据 | 见「历史页每一行的按钮 = 这条记录此刻真能做到的事」。后缀模式永不给「恢复原图」，replace 永不给「删除这次压缩结果」；按钮不成立就不画 |
| 历史记录与原图备份 | `HistoryStore` 落 `<appdata>/history/history.json` + `<appdata>/history/backups/<key>/`（App Support，跨启动长期保留）；备份 key = **FNV-1a 64 位**（`stable_hash`，跨 rustc 版本稳定），老 `DefaultHasher` key 仍被识别用于续用已有备份与书签 | 同上（沙盒容器内的 App Support）| 备份绝不放 temp_dir/Caches，否则系统清理会丢掉原图；Swift 线用独立根 `~/Library/Application Support/com.misswell.octoshrink.swift`。**标准库从不承诺 `DefaultHasher` 的跨版本稳定性**，一次升级就能让所有备份看起来"无人引用" |
| 启动清理 | `setup` 里先 `transactions.recover(history)`（补记或自动回滚上次中断的覆盖），再跑一次 `cleanup_expired(retention_days)`：只删过期 `HistoryEntry` 和只被该条目引用的备份目录；`retention_days == 0`（「不保留」，默认档）时**只扫无人引用的孤儿备份** | 同上 | 不留常驻计时器；「不保留」档的备份**只在正常退出时清**（`RunEvent::Exit` / `applicationWillTerminate`），因为崩溃现场那份可能是唯一的原图；**绝不删用户的 sourcePath / outputPath / 输出目录里的文件**（历史过期 ≠ 用户文件过期） |
| history.json 读不出来 | **严格读**：文件不存在=空历史（正常）；存在但解析失败=损坏 → 隔离为 `history.corrupt-<millis>.json`（现场绝不许被 `[]` 覆盖）→ 按 `backups/<key>/backup-meta.json` 重建 `status: "recoveryAvailable"` 条目 → 本次启动**禁止一切备份 sweep**（`cleanup_is_locked()`） | 同上 | 老实现 `unwrap_or_default()` 把半个文件当空历史，下一次启动清理就"合法地"删光所有原图备份。重建出的条目没有压缩明细，但保证**原图仍可一键恢复** |
| 安全暂停 / 取消 | `CompressionScheduler`（`pause_compression` / `resume_compression` / `compression_state` / `cancel_file` / `cancel_batch` / `clear_cancel_queue`）：闸门只拦「还没开始」的文件，正在跑的 CLI 子进程绝不 kill；`Notify` + 250 ms 超时轮询，等待者用 `acquire_or_cancelled` 自带取消退出条件 | 同上（进程内引擎同样只在新任务起点等待）| 两版行为一致；Swift 线为 `CompressionScheduler.acquire(cancelled:)`。**取消只 `wake_waiters()`，绝不 `resume()`** |
| 对比窗口（compare 独立窗口）| WebviewUrl::App 加载内嵌 compare.html，经 convertFileSrc / read_image_dataurl 读图 | WebviewUrl::External 指向本地 HTTP 服务器 `http://localhost:<port>/compare.html`（`frontend_http_port()`），经 read_image_dataurl（bookmark 授权范围内）读图，窗口创建时 `visible(false)` + on_page_load show 防白屏 | 沙盒阻止 tauri://；两版窗口行为一致，URL 按 feature 分叉 |
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
| Finder「转换图像」 | macOS ImageIO/CoreGraphics（两版共用） | ✅ 系统转换模式：JPEG/PNG/HEIF + 实际/1280/640/320 px + 元数据开关 |

⚠️ **`engine_inproc.rs` 里绝不允许出现 `find_tool` / `make_command` / `cli_to_file` / `Command::new`**（曾经为了"压缩效果对齐 Direct"优先 spawn 打包 CLI，但那在沙盒下是必然失败的死路径）。为什么：security-scoped 文件授权挂在**父进程**的 sandbox extension 上，不随 spawn 继承，子进程读不到用户选中的图片；`scripts/build_appstore.sh` 也从不再往包里放 CLI。两处机器可查的守卫：`engine_inproc.rs` 的 `the_inproc_engine_never_spawns_an_external_tool`（扫自己源码）+ 两个构建脚本里的 bundle 自检（包里不许有第三方 Mach-O / dylib）。

## 变更本文件的规定

- 任何 PR / 提交若改变两条产物线的并行结构、文件访问差异、entitlements 配置、CLI↔crate 映射 → 必须在本文件同步更新对应小节
- 本文件由 AI 失效风险最小化优先：每条规则都写成"行动项 + 为什么"，便于将来任何 Agent 读到时都能立即照做

## 历史记录、原图备份与安全暂停（三条线共用不变量）

> 这一节是"原图不能被弄丢"的硬约束。三条线（Direct / App Store / Swift 原生）各自的实现可以不同，但下列不变量**必须逐条成立**，改动任何一条都要同时在三条线里核对。

### 存储位置：永远在 App Support，绝不在临时目录

| 线 | 根目录 | history 文件 | 备份目录 | 覆盖事务凭证 |
|---|---|---|---|---|
| Direct | `app.path().app_data_dir()`（identifier `com.misswell.octoshrink`） | `<root>/history/history.json` | `<root>/history/backups/<key>/original.<ext>` | `<root>/history/transactions/<id>.json` |
| App Store | 同上，identifier `com.misswell.octoshrink.appstore` → 自动落沙盒容器 | 同上 | 同上 | 同上 |
| Swift | `~/Library/Application Support/com.misswell.octoshrink.swift` | `<root>/history.json` | `<root>/backups/<key>/original.<ext>` | `<root>/transactions/<id>.json` |

- ⚠️ Swift 线的布局**少一层 `history/`**（`<root>/history.json` 而不是 `<root>/history/history.json`），表里的"同上"对这三列并不成立。三条线的根目录与 key 哈希都不同，本来就不共用文件，但改任何一条线时别照着另一条线拼路径。

- 三条线的存储根**互不相同**，备份 key 的哈希算法也不同（Rust 与 Swift 各自实现 FNV-1a 64 位）。这是刻意设计：任何两条线都不能读写同一份 `history.json`。
- ❌ 不要把备份放进 `temp_dir` / `NSTemporaryDirectory` / `Caches` —— 系统会随手清理，用户原图就没了。历史功能上线前的老版本确实在 temp 里放过，那份残骸（`<tmp>/octoshrink-backups`）只在启动时清目录本身。
- ⚠️ 备份 key **必须**是 `fnv1a_64(canonical(sourcePath))` 的 16 位十六进制，❌ 不得改回 `std::collections::hash_map::DefaultHasher`：标准库从不把它的算法承诺为持久格式，一次 rustc 升级就会让所有已有备份"查无此人"，于是它们变成孤儿并被清理，而对应的用户原图早已被覆盖 —— 等于批量丢原图。老 key 只读不写：`legacy_backup_key` 仍参与 `ensure_backup` 的查找（命中就**复用那一份**，❌ 不许另起炉灶把压缩结果当原图存进新目录），安全作用域书签同理（`BookmarkAccess::try_slot`），并在那里对新 key **补写一份**（write-through），老目录留着不动、由自然过期收尾。
- `history.json` 有条数上限 `MAX_HISTORY_ENTRIES = 10_000`，超出时淘汰**最老**的记录；连带删备份的前提是"没有幸存记录再引用它"（`drop_backups_of(evicted, survivors)`）。这是内存缓存常驻 + 整文件重写的成本上限，不是给用户的功能裁剪。

### 覆盖事务：每一笔"盖掉用户原文件"的操作都要能自证

`src-tauri/src/output_transaction.rs::TransactionStore` ↔ Swift `Services/OutputTransactionStore.swift`。解决的问题：rename 覆盖成功、但进程在 `history.add` 之前死掉 —— 磁盘上是压缩结果，账上什么都没有，下次启动谁也不知道该回滚还是该记账。

- **凭证在覆盖之前落盘**：`prepare()` 写 `transactions/<id>.json`（含 `history_id` / source / output / backup 路径 / `cross_format`），`history_id` 与稍后写入的 `HistoryEntry.id` **同一个**，这是唯一的关联键。
- **提交凭据 = 只有一条事实**：`history.contains_committed(history_id)`。真 → `finish()` 销账；假 → `rollback()`（备份写回源文件、删本次生成结果）。❌ 不许凭"文件存在 / mtime 对了"之类的猜测来判断提交。
- `rollback()` **永不删备份**：回滚失败时它是唯一的原图副本，必须留给下一次。
- 启动时 `transactions.recover(history)` 先跑，再跑 `cleanup_expired`；`setup` 的 `CleanupReport` 会把中断事务的处置结果带出去（补记 or 已自动回滚）。
- 只要还有 pending 凭证，`clear_history` 必须拒绝（「仍有文件事务正在处理，暂时无法清空历史记录」）。
- **Swift 线必须全进程只用 `HistoryStore.shared`**：损坏锁死（`cleanupLocked`）与启动报告是**这一次运行**的状态，`AppState` 与 `AppDelegate.applicationWillTerminate` 各 `new` 一个实例，就会出现"启动时刚把损坏现场留档、退出清理看不见那把锁，转身把备份 sweep 掉"。`OutputTransactionStore` 同理只有一份（`AppState.transactions`）。
- **清空历史同样受批次闸门约束**：`clear_history` 在压缩进行中直接返回错误（「压缩进行中，无法清空历史记录」），因为历史是"备份还有人认领"的账本 —— 一边在写备份一边销账，正在处理的那几张图就会变成无人引用的孤儿并被扫掉。前端配套：`renderHistory` 在 `isCompressing` 时禁用 `historyClearBtn` 并给 title，`clearHistory()` 自己也要早退 + toast（只靠按钮 disabled 挡不住键盘触发）。Swift 侧判据是 `CompressionScheduler.isBatchActive` + `transactions.hasPending()`，后端 `AppState.clearHistory()` 自己早退 + toast，`HistoryPageView` 的按钮同样 disable。这条在 `tests/history-view.cjs` 有回归断言。

### 备份：一次写成，永不覆盖

- `ensure_backup(source)` 在**覆盖原文件之前**调用；返回 `None`（备份没写成）时**必须放弃这次覆盖**，把该文件标记为失败并提示「无法保存原图备份，已跳过覆盖」。宁可压缩失败，也不能出现"覆盖了但没原图"。
- **已有有效备份时绝不覆盖**：同一张图连压三次，备份里必须还是第一次压缩前的真正原图。哈希撞到其他源路径时往后挪槽位（`<key>-1` … `<key>-31`），不串别人的原图。
- `history.json` 与 `backup-meta.json` 一律"写 tmp → fsync → rename"，崩溃不会留下半个文件。

### 历史文件读不出来：宁可少删，不可错删

`history.json` 是"哪些备份还有人认领"的唯一依据。读不出来时如果把损坏当成空历史，下一次启动清理就会"合法地"删光所有备份目录 —— 而那些目录里是已被覆盖的**用户原图唯一的副本**。

- **严格读**：文件不存在 = 空历史（正常状态）；文件存在但解析失败 = 损坏。❌ 不许 `serde_json::from_str(...).unwrap_or_default()` 这类"读不出就当没有"。
- 损坏时**先隔离现场**：整份挪成为 `history.corrupt-<epoch millis>.json`（毫秒足够唯一，本项目不引 chrono）。❌ 绝不许用重建出的 `[]` 或少量记录去覆盖它 —— 那是销毁证据，也是销毁用户的东西。
- 隔离之后按 `backups/<key>/backup-meta.json` 重建 `status: "recoveryAvailable"` 条目：没有压缩明细（省了多少字节、用的什么算法），但带**真实原图副本的位置**，用户仍然能一键恢复。备份目录里连 meta 都没有的那些，保持孤儿身份，等解锁后再扫。
- 本次启动**锁死一切备份 sweep**：`cleanup_is_locked()` 为真时，`cleanup_expired` / `purge_backups_on_exit` / `sweep_unreferenced_backups` 一律直接返回并给出警告文案「历史记录文件已损坏，本次启动跳过清理，原图备份全部保留」。锁是**整次启动**的，不因某一次成功写入而解除。
- 前端文案（三条线一致）：`recoveryAvailable` 显示「检测到可恢复的原图备份」，明细行显示「明细已丢失」，算法行显示「按备份重建」，用警告图标而不是对勾。❌ 不许伪造「节省 0.0%」—— 那是把"我不知道"包装成"压得不好"。备份也没了的时候同样显示「原图备份已清理」并收起恢复按钮。
- `restore` 对 `recoveryAvailable` 条目照常工作（它只需要 `backup_path`）。冲突判定比的是文件大小 + mtime，而这两个值对重建条目来说无从得知 —— 必须填**当下实测到的源文件状态**（`compressed_size: file_size(source)`、`output_modified_at: file_mtime_millis(source)`），否则每一次恢复都会误报「压缩后又被修改过」，逼用户确认一次根本没有的冲突。

### 恢复：一个服务，三条入口

- `restore_original` / `restore_history_entry` / `restore_all` **共用**同一个恢复实现（Rust `HistoryStore::restore`，Swift `HistoryStore.restore(entry:force:)`）。禁止复制三套恢复逻辑。
- 前端**不拼路径**：只传 `historyId`，源图路径、输出路径、备份路径全部从存储读取。
- 原子顺序（replace 模式）：① 取目录授权 ② 备份 → 同目录 `.octoshrink-restore-<nanos>.tmp` → flush + fsync → rename 覆盖源文件 ③ `mark_restored` 把状态落盘 ④ 才删本次生成的压缩输出 ⑤ 才删备份目录。中途失败不留半个文件，也不许提前删备份。
- ③ 落盘失败时**必须保留备份并直接报错**（「文件已恢复，但历史记录状态保存失败（…），原图备份已保留」）：文件已经回到用户手上，此时删备份就是把唯一的原图副本押在一条没写成的记录上。用户重试即可收敛（第二次 `force` 或不 force 都能正常走完）。
- ④ 删压缩输出前必须判**同一性**：`same_file(output_path, source_path)`（Rust）/ `sameFile(output, entry.sourcePath)`（Swift）。记录里的 `source_path` 是规范路径、`output_path` 是当时那个原始字符串，macOS 上 `/var/…` 与 `/private/var/…`、任何软链目录都会让两者**字面不等**（Swift 的 `canonicalPath` 走 `resolvingSymlinksInPath()`，它还会把 `/private/var` 折回 `/var`，所以两种写法都可能出现）；判成"另一个文件"就会把刚写回的原图当成压缩产物删掉（这是真实修过的丢文件 bug，不是洁癖）。
- 冲突保护：仅 replace 模式比对记录时的文件大小 / mtime（容差 2000 ms），任一不符即返回 `conflict=true`；前端弹「这个文件在压缩后又被修改过。恢复原图会覆盖当前版本。」→ 用户确认后带 `force=true` 重试。
- 恢复后**历史记录不删**，只标 `restored` 并删备份；共享同一备份的兄弟条目一起标记。非 replace 模式没有备份，其"撤销"只删本次压缩输出并移除条目。
- **完成文案跟着 `outputMode` 走，不许一律「已恢复原图」**：非 replace 模式后端做的是"删掉这次的压缩产物"，报「已恢复原图」等于把一件没发生过的事说给用户听。三线同一句：replace → 「已恢复原图: <name>」，否则 → 「已删除这次压缩结果: <name>」。前端拿不到模式时以**后端回报**为准（Rust `RestoreOutcome.output_mode` → `outputMode`），不要只信本地缓存的 result 快照。

### 历史页每一行的按钮 = 这条记录此刻真能做到的事

> 用户的原话：**「有原图的，你就给他找到对应的恢复按钮。没有原图的，你就不展示。」**
> 历史行与队列「压缩完成」那一行是同一套动作，按输出方式给对等的反悔按钮。三线判据逐字一致：
> Rust `history.rs` 的派生字段 + `frontend/app.js::historyRowActionDefs` ↔ Swift `Services/HistoryStore.swift::historyRowActions`。

- 判据只用 `decorate` / 读取时**现算**的三个 exists 标志（`sourceExists` / `backupExists` / **`outputExists`**），❌ 不许落库当真值用：用户随时能在访达里删掉产物或备份。`outputExists` 是这一节新加的派生字段，三线同名。
- 按钮集合与顺序（**固定顺序**，两边自检各自钉住）：
  1. `另存为` —— `outputExists`。压缩产物已经不存在了，就不许挂一个点开只会报错的按钮。
  2. `对比查看` —— `outputExists && 原图还摸得着`。**"原图还在"按模式判**：replace 只看 `backupExists`（源位置此刻躺着的是压缩结果，拿它当"原图"比的是同一张文件，比了个寂寞）；后缀 / 目录模式源文件从没被盖过，看 `sourceExists`。
  3. 反悔按钮，**二选一**：`historyCanRestore(entry)` 为真 → `恢复原图`；否则若 `status == compressed && outputMode != replace && outputExists` → `删除这次压缩结果`（图标 trash）。❌ 后缀模式永远不许出现「恢复原图」——那是把"这份产物可以撤销"说成"你的原图能换回来"。❌ replace 模式也永远不许退化成「删除这次压缩结果」——那等于让按钮去删用户的源文件。
  4. `在访达中显示`、`复制日志` —— 永远在。
- **什么按钮都不成立的行仍然留在历史里**（用户 2026-09-22 明确选了"全类型都留，按模式给对等的按钮"，而不是"只显示能恢复的"）：`history.json` 是用户的压缩记录本，产物被删 / 备份过期都不改变"这张图在什么时候被压过"这个事实。❌ 不要为了让页面"看着干净"去过滤行 —— 那是在删用户的记录。
- 一个都不给的情况是真的存在：后缀模式 + 产物已被用户删掉 = 只剩访达和复制日志两个不承诺任何反悔的按钮。
- `recoveryAvailable`（历史损坏后按备份重建）那一行照常给 `恢复原图`：它存在的唯一意义就是让用户换回原图。
- 「删除这次压缩结果」删的是**用户目录里的真实文件**，所以前端/ Swift 都必须先二次确认（`frontend/app.js::deleteHistoryOutput` / `AppState.deleteHistoryOutput`）；确认之后照旧走同一个恢复服务、只交 `historyId`，❌ 不许前端自己 `removeFile`。
- 「清空历史」就是**手动到期**：不用等保留期，确认框要数清楚这一次带走几份原图备份（`historyEntries.filter(e => e.backupExists).length`）。文案固定：「同时立即删除 OctoShrink 保存的 N 份原图备份，不必等保留期到期。不会删除你的任何图片文件。」一份都没有时说「这次只清记录」，❌ 不许在没有备份的时候还写"会清理备份"。
- 回归：`tests/history-view.cjs`（前端逐模式的按钮数组）+ `swift/Tests/HistoryStoreCheck/main.swift` 第 [26] 组（同一批用例）。改判据必须两边同改、两边都要过。

### 保留期与退出/启动清理

- 设置项 `原图备份保留时间`：**默认 `0` = 不保留**，可选 `不保留 / 1 / 3 / 7 / 14 / 30`（单位：天）。存在 `<app_data_dir>/settings.json`（Swift 线在自己的根目录下同名文件），字段 `original_retention_days` / `originalRetentionDays`，文件损坏则回落默认值。
- **`0` 是一个真实档位，不是"没设置"**：常量 `KEEP_UNTIL_QUIT`（Rust）/ `Retention.noRetain`（Swift），默认值直接取它。三处必须守住：
  - ❌ 不许 `if (days)` / `parseInt(v,10) || 3` 这类真值判断 —— 会把「不保留」静默吞成 3 天（前端已修过两处，`tests/history-view.cjs` 有回归断言）。
  - ❌ 不许把 clamp 写成 `days.clamp(1, 30)` —— 会把 0 变成"保留 1 天"。clamp 只夹越界值，0 原样通过（`clamp_retention` / `Retention.clamp`）。
  - ❌ 不许显示成「保留 0 天」（`Retention.label(0) == "不保留"`）。
- **`0` 不按时间过期**：它的清理挂在**正常退出**上（Tauri `RunEvent::Exit` → `commands::purge_backups_if_not_retained`；Swift `AppDelegate.applicationWillTerminate` → `HistoryStore.shared.purgeBackupsOnExit()`）。启动时这一档**只扫无人引用的孤儿备份**，不动还有人引用的（`cleanup_expired(0)` / `cleanupExpired(retentionDays: 0)` 里 `expires_by_time = days > 0` 为假）。
  **为什么**：崩溃 / 强杀之后，那次留下的备份可能就是用户原图**唯一还活着的副本**（压缩结果已覆盖了源文件）。这笔欠账留给下一次正常退出收，绝不能在下一次启动时先删。
- ⚠️ 「不保留」**不改变备份的写入**：`ensure_backup` 照旧在覆盖原文件前写备份，本次会话内随时可恢复。这一档只决定备份的**寿命**（到本次退出为止），不决定"要不要备份"。备份写不成仍然必须放弃覆盖。
- 退出清理只抹 `backup_path` 并删备份目录，**历史条目本身保留** —— 那是用户的压缩记录，不是原图。前端/历史页读到 `backupExists == false` 就显示「原图备份已清理」并收起恢复按钮；此时 `restore` 必须返回 `BackupGone` / 抛 `RestoreError.backupGone`（「原图备份已清理，无法恢复」），❌ 不许伪装成 `NotRestorable`（"原图未被覆盖，无需恢复"）骗用户。
- 按天保留的档位（1/3/7/14/30）：清理**只在启动时跑一次**，不留常驻计时器。
- ⚠️ 清理对象的白名单是闭集，只允许删：① 本 store 里过期/无主的 `HistoryEntry` ② 只被这些过期条目引用的 `backups/<key>/` ③「不保留」档退出时所有已无引用的备份目录。**绝对不能删**：用户的 `sourcePath` 原图、`outputPath` 压缩结果、用户指定输出目录里的任何文件、`*_compressed.<ext>`、历史条目本身。历史过期 ≠ 用户文件过期。
- 文案硬规定：按天档说「过期的历史记录和原图备份将在下次启动应用时自动清理」；「不保留」档说「原图备份只在这次运行期间保留，关闭应用时清理；期间可以随时恢复原图」。**永远不许**写「原图将在 3 天后删除」这类吓人的话，也**永远不许**把备份说成从不存在的功能（后半句「期间可以随时恢复原图」在「不保留」档是事实，可以写）。

### 安全暂停

- 暂停只拦"还没开始"的文件：闸门在取下一个任务前等待，**绝不 kill / SIGSTOP 正在运行的 CLI 子进程**，也不打断正在跑的进程内引擎。
- 等待要有超时（Rust `tokio::sync::Notify` + 250 ms 兜底，防丢唤醒；Swift `CompressionScheduler` 的 `NSCondition.wait(until:)` 0.25 s），否则取消/退出会挂死。
- 一批开始/结束时必然清除暂停态（Rust `begin_batch()` / `end_batch()`，Swift `beginBatch()` / `endBatch()`）。
- **取消绝不解除暂停**：`cancel_file` / `cancel_batch` / `clear_cancel_queue` 只 `wake_waiters()`（Rust）/ `wakeWaiters()`（Swift）—— 只把等待者叫醒让它们看见"这个文件已被取消"，闸门仍然是关的。老实现调 `resume()`，结果是"暂停中移除一个文件 → 整批悄悄继续跑"，前端还显示「暂停中…」。
  防"闸门关着却没人开"的正确做法不是取消时开门，而是**等待者自己带退出条件**：`acquire_or_cancelled(cancelled)`（Rust）在暂停判定之前先查取消，被取消的文件直接结束并上报 `status: "cancelled"`，永不启动；Swift 侧 `acquire(cancelled:)` 同语义。批次结束时 `end_batch()` 必然 `resume()`，所以关着的闸门总有一个人会来开。
- UI 保持现有密度：进度按钮仍是 `startCompressBtn`，旁边一个小号 `[暂停]/[继续]`，标题文案「暂停中…」，队列摘要追加「 · 已暂停」。不要做成大按钮。

## CPU 使用上限（三条线共用不变量）

> 设置页「性能」小节里的「CPU 使用上限」控制的是 **CPU 并行预算的份数**，不是 affinity。
> ❌ 不做绑核（`taskpolicy` / `SetThreadAffinityMask` / `sched_setaffinity`）
> ❌ 不做 P/E 核指定，❌ 不硬编码 M1…M5 的核数表。
> 因此文案**永远不许**出现「使用 N 个性能核」这类承诺绑定核心的话（`tests/cpu-limit.cjs` 与 `scripts/test_swift_history.sh` 各自 grep 守这条）。

### 1. 两层预算必须同时限，只限一层等于没限

| 层级 | Direct（CLI 后端） | App Store（进程内后端） | Swift 原生 |
|---|---|---|---|
| L1 同时处理几个文件 | `commands.rs::CompressionScheduler`（两条 Tauri 线共用） | 同左 | `Services/CompressionScheduler.swift` → `acquire() -> Permit` |
| L2 单个编码器内部几个 worker | `engine.rs::per_task_threads()` = 1，经 `configure_cpu_limits()` 注入 | `Cargo.toml` 编译期裁掉并行后端 + `ravif.with_num_threads(1)` | `Engine/CLIRunner.swift::CPUResourcePolicy` = 1 |

真实 CPU 用量 ≈ L1 × L2。L2 曾被漏掉两次：`cwebp -mt`、`avifenc --jobs 4` 当时写在各压缩函数里，oxipng / imagequant 的 rayon 后端默认吃满全核 —— "上限 3"实际是"3 个文件 × 每个用满全部核心"，用户看到的占用率和设置完全对不上。

### 2. L2 的三个强制写法

- **命令行开关集中在一张表**：`engine.rs::cpu_flags(tool, threads)` ↔ Swift `CPUResourcePolicy.flags(for:)`，逐工具对应：`avifenc → --jobs N`、`oxipng → --threads N`、`cjxl → --num_threads=N`（⚠️ 它的默认 `0` = 按硬件线程数全开，不钉住就是"上限 3 个文件 × 每个用满全部核心"；且 cjxl 的参数是 `--num_threads=` **等号**形式，不是空格分隔）、`cwebp → 只在 N > 1 时给 -mt`（`-mt` 只能开关、不能指定线程数，单 worker 预算下传它就是超发），其余工具（pngquant / gifsicle / cjpeg）不加参数。
  ⚠️ **cjxl 那行只属于 Direct 线**：Swift 线既不打包 cjxl、`OutputFormat` 里也没有 JXL 档位，所以 `flags(for:)` 只认 avifenc / oxipng / cwebp。这不是漏配 —— 给一条线没有的工具补分支就是死代码；但**新增该线真正会调用的工具时必须两边都补**，别只改一张表。
  **新增压缩函数不许自己写 `-mt` / `--jobs` / `--num_threads`**，一律走 `make_command()` / `CLIRunner.run(…) / runToFile(…)`，否则 `tests/cpu-limit.cjs` 与 `engine.rs` 的 `cpu_flags` 单表就会和真实调用分叉。
- **线程类环境变量无条件注入**：`OMP_NUM_THREADS` / `RAYON_NUM_THREADS`（Rust `cpu_env()`，Swift `CLIRunner.environment()`）。Swift 侧这两个变量必须在 `DYLD_FALLBACK_LIBRARY_PATH` 那个 `if let lib` 分支**之外**设置，否则资源目录缺失时预算静默失效。
- **进程内 crate 走编译期裁剪，不走运行时调线程数**：`oxipng` 的并行度由 `parallel` feature（rayon）决定、其 `Options` 没有 threads 字段；`imagequant` 的 `threads` feature 同理；rayon 全局池一旦初始化就调不动。所以这三个 crate 在 `Cargo.toml` 里一律 `default-features = false`，`ravif` 单独 `with_num_threads(Some(per_task_threads()))`。❌ 不要为"动态调线程"给它们重开 feature，❌ 不要 `rayon::ThreadPoolBuilder::build_global()`。

### 3. 检测与取值

- `system_info.rs` ↔ `Services/SystemInfo.swift`：预算基准取 `available_parallelism()`（Swift 取 `activeProcessorCount`）；sysctl（`hw.physicalcpu` / `hw.logicalcpu` / `hw.nperflevels` / `hw.perflevel0.*` / `hw.perflevel1.*`）**只用于展示**，不参与算预算。
- `aarch64 ≠ Apple Silicon`：只有 `machdep.cpu.brand_string` 以 `Apple ` 开头才算。检测把结论作为 `appleSilicon` 字段序列化出去，❌ 前端不许自己从 `architecture` 猜（ARM Windows / Linux 同样报 aarch64）。
- 设置存的是**用户选的原始值**，生效值按本机能力 clamp：`effective_cpu_limit(configured, detected)`；自动档 = `min(3, detected)`。16 核上设 12、换到 8 核 → 生效 8，静默收敛而不是报错。上限 0/负数夹到 1（0 会让闸门永远关着）。
- 持久化：与保留天数**同一份** `settings.json` 的 `cpu_thread_limit` / `cpuThreadLimit`，`null` = 自动。❌ 不要再开一个 cpu-settings.json。写设置一律读-改-写（`set_retention_days` 顺手覆盖掉 `cpuThreadLimit` 是已修过的回归 bug）。

### 4. 运行中改上限 = 与暂停同一套语义

- 8 → 2 **不抢占**已在跑的 8 个（各自跑完），只是不再启动新任务；2 → 8 立刻唤醒等待者（不靠 250 ms 超时兜底）。
- 因此暂停与 CPU 上限合并为**一个** `CompressionScheduler`（`paused` + `max_parallelism` + `active` + 一次通知/条件变量）。❌ 不要拆成 `PauseGate` + `ConcurrencyGate` + `CpuGate` 三层锁 —— Swift 侧 `PauseGate` 已删除，不许在 `HistoryStore.swift` 里复活。

### 5. 命令与文案

- Tauri 命令：`get_cpu_info`、`get_cpu_resource_settings`、`set_cpu_thread_limit(limit | null)`，三者返回同一份 `CpuStatus`（camelCase）。新增命令按"三处同改"注册：`commands.rs` handler + `lib.rs` `invoke_handler!` + `commands.toml` / `capabilities/default.json`。
- 队列摘要（不另起面板）：`47 / 200 已完成 · CPU 4/10`；暂停时 `… · 已暂停 · CPU 4/10`；自动档 `… · CPU 自动`。
- 文案固定：「限制 OctoShrink 同时使用的 CPU 并行能力。较低的数值会降低压缩速度，但可为其他应用保留更多性能。」，Apple Silicon 才追加「系统会自动在性能核与能效核之间调度任务。」；设备行报 `Apple M5 · ARM64` + `10 核 CPU（4 性能核 + 6 能效核）`，Intel 报 `6 个物理核心 · 12 个逻辑处理器`。
- 承诺边界：这个开关调的是并行度，**不许**承诺"< 40% CPU"或"固定占用 N 个核"。

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
- src-tauri/src/history.rs + src-tauri/src/app_settings.rs — 历史记录、原图备份、保留期（两条 Tauri 线共用）
- src-tauri/src/output_transaction.rs — 覆盖事务凭证（`TransactionStore` / `ReplaceTransaction` / `rollback`），启动时 `recover()`
- swift/Sources/OctoShrinkSwift/Services/HistoryStore.swift — 同上的 Swift 原生线实现（`HistoryStore.shared` 全进程唯一）
- swift/Sources/OctoShrinkSwift/Services/OutputTransactionStore.swift — Swift 线的覆盖事务凭证 + `OutputWriteError` / `StagedWrite`
- tests/history-view.cjs（`npm run test:frontend`）— 前端历史页（每行按钮集合 / 重建条目 / 恢复只交 historyId / 冲突 force 重试 / 不保留档位 / 压缩中拒绝清空）、暂停与 CPU 上限纯逻辑自检
- scripts/test_swift_history.sh — Swift 线历史·备份·覆盖事务·恢复·取消与暂停·CPU 上限·历史行按钮自检（真跑文件系统，26 组）

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
cargo tauri build --bundles app --features appstore --config tauri.conf.appstore.json -- --no-default-features

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

### 2.5 App Store bundle 自检（送审前必过）

`scripts/build_appstore.sh` 与 `scripts/build_all.sh` 在签名前都会检查 App Store 版 `.app`：

1. `Contents/**` 里不许有 `*.dylib`，也不许有 `Contents/Resources/bin/*`（第三方可执行文件）。
2. `Contents/MacOS/` 里**必须只有唯一一个主程序**。⚠️ 判据不许按名字比：Tauri 只把 `.app` 目录建成 `productName`（`OctoShrink`），里面的可执行文件仍是 Cargo 包名 `octoshrink`，写成 `! -name "$APP_NAME"` 会把主程序自己判成"额外可执行文件"，于是两条 App Store 构建脚本**永久自检失败**（这个坑已在 v2.5.35 修掉，改回按名字比就是再次踩）。
3. `src-tauri/src/engine_inproc.rs` 的生产代码里不许出现 `find_tool` / `make_command` / `cli_to_file` / `Command::new`。

任一条不过就 `exit 1`。为什么值得写成脚本 + 测试各一份：App Store 的自动分析会看"包里有可执行文件 / 有 entitlements 却声明不做网络或子进程"，一次驳回就是 1-3 周；而 `cs.disable-library-validation` 在沙盒线根本不允许，带进来的 dylib 连加载都过不去。历史上 `build_all.sh` 曾把 pngquant/oxipng/gifsicle 连同两个 homebrew dylib 复制进 App Store 包以求"与 Direct 画质对齐"，现在已删除 —— Direct 版的 `resources/bin` + `resources/lib` 照旧打包，不受影响（规则 4）。

### 3. 白屏与 IPC 反复 bug 终极解法（v2.2.8，务必遵守）

**根因**：macOS 27 App Sandbox 阻止 `tauri://localhost`（WKURLSchemeHandler 完全不工作）→ webview 拿不到内容 → 白屏。必须用本地 HTTP 服务器（监听 127.0.0.1 随机端口）服务前端资源。

**「来回修」真相**：历史上两个 commit 各解决一半，从未合并，故反复：
- `2672532`/`10e56fc`：有 HTTP 服务器（白屏解决）但 capabilities 只有 4 项 → app 命令不在 ACL → IPC 全失效（选图/拖图/移窗口失效）
- `b21cc53`：补全基础 `allow-*` + `remote.urls`（IPC 解决）但删了 HTTP 服务器 → 沙盒白屏

**正确方案（v2.2.9，缺一不可）**：
- `lib.rs` `#[cfg(feature = "inproc-backends")]` 块：`TcpListener::bind` **固定端口段** `[41845u16, 41846, 41847]`（带 fallback 防冲突），serve resource_dir 前端，`window.navigate("http://localhost:PORT/")`
- `entitlements-appstore.plist`：`network.server` + `network.client` 必需
- `capabilities/default.json`：`allow-*` app 命令权限（当前 **35** 个，与 `permissions/commands.toml` 的 35 个 `[[permission]]` 一一对应；permissions 数组共 **40** 项，其余 5 项是 `core:default` / `dialog:default` / `opener:default` / `core:window:allow-start-dragging` / `core:window:allow-close`。数字会随命令增长，别信它 —— 用 `python3 -c "import json;p=json.load(open('src-tauri/capabilities/default.json'))['permissions'];print(len([x for x in p if x.startswith('allow-')]),len(p))"` 与 `grep -c '^\[\[permission\]\]' src-tauri/permissions/commands.toml` 现算）+ `remote.urls: ["http://localhost:41845","http://localhost:41846","http://localhost:41847"]`（**精确匹配带端口 origin**）+ `core:window:allow-start-dragging` + `core:window:allow-close`；`windows` 必须同时含 `"main"` 和 `"compare"`（独立对比窗口按 label 授权，漏掉 compare 会让对比窗口 IPC 静默失效）
- 启动白闪：前端把最终解析出的 `light/dark` 通过 `set_startup_theme` 写入 `NSHomeDirectory()/Library/Application Support/OctoShrink/startup-theme`（App Store 自动落入沙盒容器）；Rust 在 `Builder::run` 创建窗口前读取主题（首次使用 macOS 系统外观）并改写运行时 `WindowConfig.background_color`。本地 HTTP 资源必须返回 `Cache-Control: no-store`，否则 WKWebView 可能复用旧版主题脚本。不要等到 `setup()` 后才设置背景，窗口创建瞬间会漏出静态浅色帧。

**勿再犯**：
- ❌ 「tauri://localhost 在沙盒下正常工作，不需要 HTTP fallback」—— 错！macOS 27 沙盒阻止它。此断言曾写入本文件，导致 b21cc53 删 HTTP 服务器 → 白屏回归。
- ❌ **随机端口 `:0` + 无端口 `remote.urls: ["http://localhost"]`** —— 错！Tauri ACL 对 remote origin 精确匹配，`http://localhost` ≠ `http://localhost:41845` → IPC 静默失效（加不了图/拖不进图/窗口拖不动）。v2.2.8（`f064299`）即此 bug：修白屏却漏改端口匹配。**必须固定端口段 + remote.urls 精确列带端口 origin**。
- ❌ 单独用 HTTP 服务器不配 ACL → app 命令（remote origin）全被 Tauri ACL 拒，IPC 静默失效。
- ❌ `visible: false` + 延迟 `show()` → 窗口可能永不显示（曾误判为白屏根因，实际是独立问题）。

**验证方法**：`open` 签名+沙盒 .app（**非** `cargo tauri dev`，后者非沙盒不复现白屏），`screencapture` 截图确认 UI 渲染。b21cc53 的"截图确认无白屏"疑在非沙盒环境测，不可信。

### 4. IPC 权限（App Store 版必须配置）

- 在 `capabilities/default.json` 中显式声明所有 app 命令的 permission（数量必须与 `permissions/commands.toml` 的 `[[permission]]` 保持一致，现算而不是信文档；新增 command 时三处同改：`commands.rs` 的 handler、`lib.rs` 的 `invoke_handler`、`commands.toml` + `capabilities/default.json` 的 kebab-case 权限名，如 `set_original_retention_days` → `allow-set-original-retention-days`，`cancel_batch` → `allow-cancel-batch`。前端漏注册权限的表现是 **invoke 静默失败、不报错**，最难查）
- 创建 `permissions/commands.toml` 定义权限 schema
- 不配置 → 前端 invoke 全部失败（静默，不报错）
- Direct 版不需要此配置（非沙盒，不检查 ACL）
- 新增窗口时必须把窗口 label 加入 capabilities 的 `windows` 数组（如独立对比窗口 "compare"），否则新窗口内所有 invoke 被拒

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
| release 构建报 `E0463: can't find crate for \`xxx_macro\``，但 `target/release/deps/libxxx_macro-*.dylib` 明明存在 | 上一次构建中途失败留下了半写坏的 proc-macro dylib，cargo 却认为它是新鲜的并复用（`panic` 设置不进 proc-macro 单元的 fingerprint，两条线共用同一个 `target/release` 时更容易踩） | 删掉那一个 crate 的产物和指纹后重编：`rm -rf target/release/deps/*<crate>* target/release/.fingerprint/<crate>*`。⚠️ `cargo clean -p <registry-crate>` 在这里**无效**（该包不在 workspace 里，只会 `Removed 0 files`） |

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

### 13. Direct 在线更新与 macOS 架构发布

- macOS Direct 版通过 `tauri-plugin-updater` 检查 GitHub Release 的 `latest.json`，更新包必须使用项目 updater 私钥签名；仓库只保存 `tauri.conf.json` 中的公钥，私钥不得提交。
- App Store 版不加载 updater 插件，继续由 Mac App Store 负责更新。
- GitHub Release 必须同时提供 macOS arm64、x86_64 与 Universal 2；Universal 内的主程序、CLI 工具和非系统 dylib 都必须包含双架构，不能只合并主程序。
- Windows 与 Linux 产物继续由 `.github/workflows/release.yml` 并行构建。

### 14. 发布流程全凭据速查（本机与 GitHub Actions 均已配置，无需向用户索要）

> ⚠️ 本节记录所有发布相关凭据的存储位置和使用方式。用户经常不在电脑旁，**禁止向用户索要任何密码**，所有凭据均已在以下位置：

| 凭据 | 存储位置 | 使用方式 | 是否需要用户输入 |
|------|---------|---------|:---:|
| Apple 公证凭据 | 钥匙串 profile `octoshrink-notary` —— ⚠️ **2026-09-23 实测本机已不存在**（`notarytool history --keychain-profile octoshrink-notary` 报 No Keychain password item found） | `xcrun notarytool ... --keychain-profile octoshrink-notary`（本机需先重建） | ✅ 本机需要；CI 不需要 |
| Developer ID 签名身份 | 钥匙串（自动检测） | `security find-identity -v -p codesigning` 自动取 `Developer ID Application: Guofeng Liu (U8U443D7ZL)` | ❌ 自动检测 |
| Apple Distribution 证书 | 钥匙串 | App Store 版签名，`scripts/build_appstore.sh` 自动引用 | ❌ 自动检测 |
| 3rd Party Mac Developer Installer | 钥匙串 | `productbuild` 打 PKG，`scripts/build_appstore.sh` 自动引用 | ❌ 自动检测 |
| Tauri updater 私钥 | `src-tauri/.tauri/octoshrink-updater.key` | `cargo tauri signer sign`（设置 `TAURI_SIGNING_PRIVATE_KEY` 环境变量） | ❌ 本地文件 |
| Tauri updater 密码 | `src-tauri/.tauri/octoshrink-updater.password` | `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` 环境变量 | ❌ 本地文件 |
| GitHub Secrets（Developer ID） | `APPLE_DEVELOPER_ID_P12_BASE64` / `APPLE_DEVELOPER_ID_P12_PASSWORD` | CI 导入临时钥匙串，仅包含 Developer ID Application 身份 | ❌ 已配置 |
| GitHub Secrets（Apple 公证） | `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_SPECIFIC_PASSWORD` | CI 用 `notarytool` 公证三个 macOS DMG | ❌ 已配置 |
| GitHub Secrets（更新签名） | `TAURI_SIGNING_PRIVATE_KEY` / `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | CI 签 Universal 在线更新包 | ❌ 已配置 |
| GitHub 推送 | SSH key（`git@github.com:misswell/octo-shrink.git`） | `git push origin master` | ❌ SSH 自动认证 |

#### 发布新版本完整流程（无密码）

```bash
# 1. 更新版本号
#    src-tauri/tauri.conf.json -> "version"

# 2. 提交 + 打 tag + 推送
git add -A && git commit -m "feat(vX.Y.Z): ..."
git tag vX.Y.Z
git push origin master
git push origin vX.Y.Z

# 3. GitHub Actions 自动完成全部发布工作：
#    - ARM / Intel / Universal 2 / Windows / Linux 编译
#    - macOS 全部 Mach-O Developer ID 重签
#    - 三个 macOS DMG 并行 Apple 公证 + app/DMG 装订
#    - Universal 在线更新包签名 + latest.json
#    - 所有步骤成功后直接发布正式 GitHub Release
gh run watch --exit-status
```

也可在 GitHub Actions 手动运行 `Release` workflow：输入 `vX.Y.Z` 作为产物版本标签；`publish=false`（默认）只完整验证构建、签名与公证，`publish=true` 才正式发布。CI 签名公证实现位于 `scripts/sign_notarize_macos_ci.sh`；本地不再需要下载、重签或覆盖 Release 资产。

**钥匙串 profile 已丢失（2026-09-23 实测）**：本机 `octoshrink-notary` 已不在钥匙串里，`bash scripts/notarize.sh` 会在公证前的自检处停下并打印下面这条命令（脚本第 146 行的探测是好的，不会让它变成莫名其妙的失败）。发布走 GitHub Actions 不受影响 —— CI 用的是 `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_SPECIFIC_PASSWORD` 三个 Secrets，与本机钥匙串无关。
用户需要在终端执行一次 `xcrun notarytool store-credentials octoshrink-notary --apple-id misswell@foxmail.com --team-id U8U443D7ZL`，输入 App 专用密码。这是唯一可能需要用户输入的情况。

**Direct 版一键签名公证**（仅 ARM，日常开发用；需先重建上面的 profile）：
```bash
bash scripts/notarize.sh    # 自动构建->签名->公证->装订->DMG

## Migrated local state and reusable release rules

- The project-specific reusable release scripts are `scripts/notarize.sh` and `scripts/sign_notarize_macos_ci.sh` in this checkout (`/Users/guofeng/Code/solo/octor-shrink`, note the directory is `octor-shrink`); inspect and reuse them before designing another macOS notarization flow.
- Do not treat the historical `octoshrink-notary` Keychain profile as currently usable solely because it appears in older notes. Verify it with `xcrun notarytool history` in the current session; if it fails, report the exact missing credential rather than guessing.
- The historical cleanup removed about 19G from `/Users/guofeng/Code/solo/octo-shrink/src-tauri/target`; this generated cache can be moved to the Trash and rebuilt, but release artifacts and worktrees with uncommitted changes must be preserved.
```
