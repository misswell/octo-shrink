# 大队列与内存回收验证

日期：2026-10-12。基线：`eb05bd5e3ceab1905788c1d80629b61a6429c1ca`。
本文记录本地工作区改动与测量，未发布、未替换已安装应用。

## 结论范围

原实现存在随队列数量增长的 DOM、等待工作块与任务记录驻留，以及整批结果/历史 JSON 的元数据副本压力。源码没有证据表明 `CompressResult` 或 `HistoryEntry` 会长期持有已经完成的图片像素。

本次修复有界视口、有界任务、每图临时对象作用域与估算内存预算；不把估算预算称为硬 RSS 上限。历史仍为最多 10,000 条的 JSON，追加时仍有全量复制/序列化开销。Rust 整批结果返回仍用于实时事件丢失时补偿，未改为只返回统计。

## 审查逐项对账

对照《OctoShrink 内存回收专项审查》（基线 `eb05bd5e`）的 6 条问题、6 条修复建议与 7 项验收清单，逐项状态如下。

### 问题清单

| 审查问题 | 状态 | 本工作区的落点 / 边界 |
|---|---|---|
| P0 Swift：一次性提交 1 万个等待工作块 | ✅ 已修 | `CompressionWorklist` 固定 worker 逐项领取（`AppState.runBatch`），不再为每个文件创建阻塞闭包；`[33]` 组用十万项验证恰好消费一次 |
| P0 Tauri：1 万个 DOM 行长期驻留、进度事件全量排序、`files.includes()` 近似平方比较 | ✅ 已修 | 有界视口（可见 ±8 行、`QUEUE_ROW_PITCH=42`）+ 状态存 `queueItems` 不在 DOM；筛选用 `Set`；进度刷新 100 ms 合并；迟到的元数据结果核对 `queueRevision` 与队列项身份 |
| Swift `displayItems` 排序比较器里反复 `firstIndex` | ✅ 已修 | `itemIndexByID` / `itemIndexByPath` 索引 + 默认导入序排序快路径；`[33]` 组 grep 守住导入路径不含 `firstIndex` |
| P1 历史记录每张图片全量重写 JSON（建议迁 SQLite） | ❌ 未做（已知边界） | 仍是 ≤10,000 条的 JSON + 整文件重写；迁移必须连同原图备份与崩溃恢复语义一起做，不在本次范围 |
| P1 Rust 整批结果最终 `.clone()` 造成重复持有 | ✅ 已修 | 基线 L851 的 `results_arc` 与 L1018 的 `final_results … .clone()` 均已移除；`JoinSet` 及时收割，`results` 移动进 `CompressionSessionResult`。整批返回本身保留（事件丢失补偿），`CompressResult` 不含图片字节 |
| P1 并发仅按 CPU 限制，不按内存限制 | ✅ 已修 | 三线同一估算公式 + 同一个闸门同预留 CPU 名额与估算字节；permit 释放两者都归还；超预算单图独占运行 |
| P2 峰值回落缺少验证 | ◐ 部分验证 | Chromium 队列 heap 三批稳定、Swift 短测 malloc 平坦；本次补充多格式样本缩小版压测（见下节），Instruments 未跑 |

### 修复建议

| 建议 | 状态 |
|---|---|
| 1. Swift 调度器改固定工作者 + 每图 `autoreleasepool` | ✅（含逐图作用域） |
| 2. Tauri 队列虚拟化、`Set` 查找、不在每个进度事件全量排序 | ✅ |
| 3. 历史记录增量持久化（SQLite） | ❌ 未做，保留为边界 |
| 4. 结果数据精简，Rust 不再整批重复返回 | ✅ clone 已删；整批返回保留（补偿用途），未改按需查询 |
| 5. 新增内存预算，大图动态降低并发 | ✅（估算式准入，非实时系统内存压力） |
| 6. Swift 查找/排序建索引，消除 `firstIndex` 全量扫描 | ✅ |

### 验收清单（审查第五节）

| # | 验收项 | 状态 |
|---|---|---|
| 1 | 连续压 10,000 张 JPEG，每 100 张记录内存 | ❌ 未按原样执行（缩小版用多格式样本） |
| 2 | 混合 PNG/JPEG/WebP/AVIF + 智能压缩 | ◐ 缩小版覆盖 PNG/JPEG/WebP/GIF 智能压缩；AVIF 作为输入在三线均为既有边界（见压测节） |
| 3 | 过程中暂停、继续、停止再完成 | ✅ 行为回归（`pause-resume` / `compression-session` / Swift [27][28][29]）；压测中未重复执行 |
| 4 | 压完保持队列 5 分钟观察空闲 | ◐ 缩小版于每线结束做短时空闲观察 |
| 5 | 清空队列、关对比窗口后观察存活内存 | ✅ 队列：Chromium 三批清空；对比窗口：Swift `CompareWindowLifetime` 真实 `close()` 弱引用断言 |
| 6 | 连续三批检查内存基线逐批上升 | ✅ 缩小版三批（Chromium heap / Rust 进程内 / Swift 进程内） |
| 7 | Direct 子进程与 App Store 进程内编码器峰值 | ✅ 缩小版分别采样（见压测节） |

审查未要求、但本次一并修复的：Swift 静态对比窗口 `isReleasedWhenClosed=false` 造成的关闭后残留（`CompareWindowLifetime` 现于真正关闭时解绑内容控制器并释放窗口）。

## 实际 Chromium 队列测量

运行 `tests/large-queue-browser.cjs`，使用本机 Google Chrome headless、920×800 视口，加载完整前端和样式，mock Tauri 文件元数据 IPC。完成态使用真实队列行绘制与结果按钮，但不执行图片编码。每次测量等待 DOM MutationObserver 交付，再执行 DevTools GC。

| 队列 | 状态 | 实际队列行 | JS live heap（MiB） | DOM 节点 |
|---|---|---:|---:|---:|
| 当前改动，100,000 项 | 空 | 0 | 0.91 | 1,507 |
| 当前改动，100,000 项 | 导入 | 15 | 14.27 | 1,867 |
| 当前改动，100,000 项 | 完成结果元数据 | 15 | 20.82 | 2,393 |
| 当前改动，100,000 项 | 清空第 1 批 | 0 | 2.17 | 1,507 |
| 当前改动，100,000 项 | 清空第 2 批 | 0 | 2.19 | 1,507 |
| 当前改动，100,000 项 | 清空第 3 批 | 0 | 2.20 | 1,507 |

基线 10,000 项会同时保留 10,000 行，完成态约 59 万个 DOM 节点；当前视口下 100,000 项仍只有约 15 行。初次冷启动与清空后的 heap 不必相等：代码运行后的编译/运行时缓存也计入 heap。连续三批清空后 heap 稳定，DOM 节点恢复到空队列数量。

这里的 JS live heap **不含完整浏览器进程 RSS、WebKit 原生资源、编码器和 Direct 子进程**，不得作为 App 总内存宣传数字。基线与当前 DOM 都要等待 MutationObserver 清理记录后再测，否则被删除的节点仍可能暂时被观察记录持有，得到错误的泄漏判断。

## 已修复的回收路径

- 离屏行从 `fileRows` 移除并从文档解绑；重新滚入时从最新队列数据重建。
- `pendingImports` 的全局串行信号只解析为 `undefined`，不再永久持有上一批返回的路径数组。清空同时释放 `currentCompressOptions` 和视图路径引用。
- 迟到的目录扫描/尺寸结果核对队列版本与队列项身份，不能在清空后复活数据。
- Rust `JoinSet` 及时收割任务，任务返回不含像素的结果；删掉整批结果的最终 `clone`。
- Swift 有界 worker 逐项领取，结果按 ID 索引回写，每图 `autoreleasepool` 清理 Cocoa 临时对象。批量导入与默认排序消除嵌套全表查找。
- Swift 原实现的静态对比窗口配合 `isReleasedWhenClosed=false`，红色按钮关闭后仍持有 hosting controller、当前两张图和结果数组。`CompareWindowLifetime` 现在在真正关闭时解绑内容控制器并释放窗口；视图消失清图像、结果和监听，使迟到的重压请求失效。真实 `NSWindow.close()` 测试确认窗口与内容控制器的弱引用均在作用域结束后释放。
- CPU 与图片工作集估算共用闸门，permit 同时归还 CPU/估算字节。超预算单图仅独占运行，不永久等待。
- 无对比窗口时不序列化整个结果集，有窗口时合并更新。

## 回归与剩余实测

`tests/large-queue.cjs` 使用真实前端视口/绘制函数验证 100,000 项滚动、筛选排序、256 路径元数据分批、清空与同路径重导入隔离、刷新合并以及关闭对比后不构造快照。

Rust 调度器测试覆盖估算预留/归还、超预算独占、暂停/停止/取消和动态 CPU 上限；Swift 自检包含 100,000 项恰好消费一次与对应内存闸门测试。

## Swift 实际编码短测

Swift 自检生成一张独立的 1536×1536 JPEG，连续 5 批，每批调用当前 ImageIO JPEG 编码函数 20 次，共 100 次。每次以 `autoreleasepool` 收尾，不保留输出 `Data`。测量读取 `TASK_VM_INFO.phys_footprint`，以及 `malloc_zone_statistics(nil, …)` 汇总所有 malloc zones 的 `size_in_use`。

- 一次测量 phys_footprint：基线 42.4 MiB，峰值 238.3 MiB；每批结束依次为 125.2、190.5、226.6、149.3、238.3 MiB。加入窗口生命周期回归后的再次测量为基线 42.3 MiB、峰值 232.0 MiB，批后 125.2、111.8、174.5、214.6、183.8 MiB；两次都显示明显波动。
- 所有 malloc zones 的活跃字节：5 批均约 21.7 MiB。

malloc 活跃分配在该短测中没有随处理张数持续增长，footprint 则明显波动且没有回到启动基线。malloc 统计不包含全部 VM/CoreGraphics 分配，不能据此断言所有图片框架没有泄漏；footprint 高位也不能单独证明对象仍被队列引用。首次仅测默认 malloc zone 得到约 2.1 MiB，已改为聚合全部 zones，不能混用两种口径。

尚未进行 10,000 张真实照片、混合 Smart Mode、五分钟空闲或 Instruments Allocations/Leaks/VM Tracker 的完整验收。

## 多格式样本缩小版压测（脚本驱动）

作为问题 P2 与验收 1 / 2 / 4 / 6 / 7 的缩小版实测。`scripts/memory_stress.sh` 驱动三段测量（`STRESS_PART=a|b|c` 可单跑一段，默认全跑），样本由 `scripts/gen_stress_samples.py` 生成并落临时目录复用（`--regen` 重建）：PNG 用噪声合成，JPEG/GIF 走 sips，WebP/AVIF 用捆绑的 cwebp/avifenc。样本库共 49 个文件约 296 MiB —— 1200×900（PNG/JPEG/WebP 各 8）、2400×1800（各 5）、4000×3000（各 2），GIF 1、AVIF 2，另有一张 4000×3000 PPM 专供 cjpeg；B / C 两段轮转其中 46 个（png 15 / jpg 15 / webp 15 / gif 1）。样本全是噪声图（`pngquant --quality 65-80` 对它们必然不出产物，见下），不代表真实照片的行为。

### A. Direct 编码 CLI 子进程 RSS 峰值

| CLI 实测 | 输入 | 峰值 RSS |
|---|---|---:|
| pngquant `--quality=65-80 --speed=3 --strip` | 4000×3000 PNG | 877 MiB（exit 99） |
| oxipng `-o3 --strip safe` | 4000×3000 PNG | 321 MiB |
| cjpeg `-quality 75 -optimize -progressive` | 4000×3000 PPM | 36 MiB |
| cwebp `-q 80` | 4000×3000 PNG | 284 MiB |
| avifenc `-s 8 -q 60` | 2400×1800 PNG | 146 MiB |
| gifsicle `-O3` | 1200×900 GIF | 11 MiB |

- ~20 ms 间隔 `ps` 采样，是真实峰值的下界；更短的尖峰可能漏采。
- pngquant 以 exit 99 结束：噪声图达不到质量下限，pngquant 默认不写出产物（已确认输出目录没有它的产物）；退出码与内存采样无关。
- 单张 4000×3000 PNG 的 pngquant 峰值 877 MiB，远高于该图的调度估算（本库最大估算 316 MiB）：估算公式是**准入调度值，不是 RSS 上限**，这条就是直接反例。

### B. Rust 进程内引擎（App Store 线）三批

`cargo test --release --features appstore --no-default-features --lib memory_stress -- --ignored --nocapture`。46 个样本/批，自动档并发上限 3，预算 4096 MiB。

| 批 | 用时 | 成功/失败 | 输入合计 | 输出合计 | 批后 footprint | 批内峰值 |
|---|---:|---|---:|---:|---:|---:|
| 1 | 38.5 s | 46 / 0 | 253.9 MiB | 85.3 MiB | 444.0 MiB | 1504.5 MiB |
| 2 | 41.0 s | 46 / 0 | 253.9 MiB | 85.3 MiB | 95.8 MiB | 1582.0 MiB |
| 3 | 40.3 s | 46 / 0 | 253.9 MiB | 85.3 MiB | 579.9 MiB | 1945.9 MiB |

- 闸门观测：最大并发 3（= 上限 3），最大预留估算 906 MiB ≤ 4096 MiB 预算；三批全部处理完、0 失败。
- 30 s 空闲观察：579.9 → 599.9 MiB（+20 MiB）。
- 批后 footprint 不单调（444 → 96 → 580 MiB），批内峰值逐批抬高（1504.5 → 1582.0 → 1945.9 MiB）。与 [35] 短测一致：malloc live bytes 平坦（Swift 侧对照，见下），footprint 高水位包含 CoreGraphics/ImageIO 类缓存分配，单凭它不能区分"泄漏"与"缓存未归还"；要定性需 Instruments，未跑。
- AVIF 作为输入探测：`success=false algorithm=none out_type=unknown error=Some("未识别的图片类型")`，产物=原图。这是三线一致的既有边界（见下），与本次内存改动无关；AVIF 输出不受影响。

### C. Swift 原生线（[37] 组）

复用 `scripts/test_swift_history.sh` 的 [37] 组（`OCTOSHRINK_STRESS_DIR` 触发）。45 个样本/批 × 3 批：gif 不在 Swift 白名单；本机 ImageIO 无 WebP 编码器（`CGImageDestinationCreateWithData(…, UTType.webP, …)` 恒为 nil），15 张 WebP 每批显式跳过并打印注明，断言只针对余下 30 张。

| 批 | 成功（跳过） | 批后 footprint | malloc live |
|---|---:|---:|---:|
| 1 | 30（15 跳过） | 543.1 MiB | 24.2 MiB |
| 2 | 30（15 跳过） | 697.2 MiB | 24.2 MiB |
| 3 | 30（15 跳过） | 850.9 MiB | 24.2 MiB |

- 45 张样本 · 输入合计 252.5 MiB · 输出合计 765.8 MiB（三批累计）· 用时 18.2 s；基线 / 峰值 footprint = 302.6 / 860.1 MiB。
- 30 s 空闲观察 850.9 → 850.9 MiB（纹丝不动）。
- malloc size_in_use 三批恒 24.2 MiB，平台化断言通过 —— 这是"未随图片数近似线性增长"的正证据；但 malloc 统计不含全部 VM/CoreGraphics 分配，高位 footprint 也不能解读为对象仍被队列强引用，两个方向都要 Instruments 才能进一步定论。
- 输出合计 765.8 MiB 远大于 Rust 批的 85.3 MiB：Swift 这里调 ImageIO 编码函数，与 Rust 的 mozjpeg/oxipng/webp crate 是不同编码器，输出体积不可跨线比较。

### AVIF 作为输入的既有边界（三线一致，非本问题）

三线的输入格式识别都按魔数：JPEG/PNG/GIF/WebP/HEIC（`ftyp` brand 只认 heic/heix/mif1/hevc），不含 `avif` brand，整条链没有 AVIF 解码路径。导入白名单却含 `.avif`（`commands.rs` 两处、Swift `supportedExtensions`），于是 AVIF 能进队列、到引擎才报「未识别的图片类型」并跳过压缩。Rust 进程内探测与 Swift 短测均复现；AVIF 作为**输出**格式三线正常。这是既有边界，不属于本次内存回收改动，未在本工作区修复。

### 口径与未覆盖

- harness 与 `phys_footprint` 读取的两个坑已修：`TASK_VM_INFO` 的 flavor 别名在当前 macOS 27 SDK 是 **22**（旧头文件 20），编号 20 会以 `status=0` 落进另一个 12 字段口味导致读数错位 —— 读取改为 [22, 20] 依次尝试并用 `count_out` 校验覆盖字节数。96 MiB 页触碰自检改用 `write_volatile`（普通循环在优化构建里曾被整段消除，growth=0 造成假阴性）。
- 仍未覆盖：10,000 张原样规模、混合 Smart Mode 全量、5 分钟空闲观察、Instruments Allocations/Leaks/VM Tracker。暂停/继续/停止在压测中未重复执行（由 `pause-resume` / `compression-session` / Swift [27][28][29] 行为回归覆盖）。

## 构建检查

两条 Tauri feature 的 `cargo check` 与 `cargo test --lib` 已通过，分别 82 / 83 个测试；前端全套与 Swift 自检通过。Swift 独立构建已通过。

默认构建环境的 App Store release 阶段遇到 proc-macro E0463，精确隔离宏缓存、统一 `panic=unwind`、全新 target 都仍复现。干净 target 加 `strip=none` 的 release check 通过；因此在 `Cargo.toml` 增加仅针对 build dependencies 的 `strip=false` override，主产物仍保持 `strip=true`、Direct 的默认 panic 设置也不变。该最小修法已由一轮完整 `build_all.sh` 验证通过：Direct / App Store / Swift 三版全部产出（22 MB / 14 MB / 16 MB），App Store bundle 自检（无外部可执行文件、`engine_inproc.rs` 无 spawn）通过。

最终源码状态复核：`cargo test --lib` 默认 feature 82 通过、appstore feature 83 通过；`npm run test:frontend`（含 100,000 项的 `large-queue.cjs`）与 `scripts/test_swift_history.sh`（36 组，含内存预算与对比窗口生命周期）全过。生产路径不再调用零内存成本的 `acquire` / `try_acquire`，二者已标记 `#[cfg(test)]`，release 构建不再有对应 dead_code 警告（剩余两项 sandbox_access 警告是 inproc 专用函数在 Direct 构建下的既有提示）。
