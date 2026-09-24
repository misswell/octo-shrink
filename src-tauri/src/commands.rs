// OctoShrink - Tauri command handlers (replaces Electron IPC)

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;

use crate::app_settings::{effective_cpu_limit, AppSettings, SettingsStore};
use crate::engine::{self, CompressOptions, CompressResult, EngineResult};
use crate::history::{HistoryEntry, HistoryStore, RestoreError};
use crate::output_transaction::{self, ReplaceTransaction, StagedOutput, TransactionStore};
use crate::sandbox_access::FileAccess;
use crate::system_info::{CpuInfo, CpuStatus};

/// Shared app state.
pub struct AppState {
    pub cancel_queue: Mutex<HashSet<String>>,
    /// 主窗口打开对比时暂存的待渲染载荷，compare 窗口加载完成后取走。
    pub pending_compare: Mutex<Option<serde_json::Value>>,
    pub compression: std::sync::Arc<CompressionScheduler>,
    pub history_store: std::sync::Arc<HistoryStore>,
    /// replace 覆盖的事务日志：崩溃后据此把原图恢复回来。
    pub transactions: std::sync::Arc<TransactionStore>,
    pub settings_store: std::sync::Arc<SettingsStore>,
    /// 跨启动的文件访问授权：Direct 版直通，沙盒版用 security-scoped bookmark。
    pub access: std::sync::Arc<dyn FileAccess>,
    /// 启动时检测一次的本机 CPU 能力：设置页展示 + 上限天花板。
    pub cpu_info: CpuInfo,
    /// 本次运行的起点：「不保留」档靠它区分"这次造的记录"和"上次崩溃留下的记录"。
    pub run_started_at: i64,
    /// 上次运行是否走完了退出清理。为假时说明磁盘上那批备份是崩溃现场留下的、
    /// 可能是原图唯一的副本，本次退出得再留它一次。
    pub previous_run_ended_cleanly: bool,
}

/// 批次阶段。这是前端渲染按钮与状态文案的**唯一**依据（经 `compression-state-change`
/// 事件下发），前端不再自己从"批次还没结束"猜当前是什么状态。
///
/// - `idle`：没有批次在跑。
/// - `running`：批次在跑，闸门开着。
/// - `paused`：闸门对"还没开始"的文件关着，已经在跑的继续跑完。
/// - `stopping`：用户点了停止。闸门对"还没开始"的文件**永久**关闭（暂停中也能停），
///   已经在跑的跑完，批次收尾后回到 `idle`。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CompressionState {
    Idle,
    Running,
    Paused,
    Stopping,
}

/// 压缩调度器：暂停 / 停止与 CPU 使用上限共用一个闸门。
///
/// 三者语义相同 —— 只决定"要不要再启动新任务"，绝不干预已经在跑的子进程或线程：
/// 暂停或停止时正在压的那张继续跑完；上限从 8 调到 2 时已有的 8 个也允许跑完，
/// 只是不再启动新的。反过来 2 → 8 立刻唤醒等待者。
///
/// 用 Notify + 轮询超时兜底：notify_waiters 与 notified.await 之间存在丢唤醒的
/// 窗口，超时让最坏情况只是延迟几百毫秒，而不是永久卡住。
pub struct CompressionScheduler {
    paused: AtomicBool,
    /// 批次级的「停止」。与文件级的 `cancel_queue` 是两件事：停止不需要逐条记账，
    /// 闸门本身对后来者永久关闭。
    stopping: AtomicBool,
    /// 是否有批次在跑，只影响前端显示的 state 文案。
    active_batch: AtomicBool,
    max_parallelism: AtomicUsize,
    active: AtomicUsize,
    notify: tokio::sync::Notify,
}

/// 一份 CPU 并行预算。Drop 即归还，因此提前 return、panic 都不会把闸门卡死。
pub struct ParallelPermit {
    scheduler: std::sync::Arc<CompressionScheduler>,
}

/// 等闸门等的三种结局。**必须分开**，不能再像老实现那样用 `Option` 一个 `None`
/// 同时表示"这个文件被用户取消"和"整批被停止"：
///
/// - `Cancelled`：用户明确把**这个文件**移出队列（点 ×、清空队列）。它真的不该再被压。
/// - `Stopped`：用户停的是**这一轮**。这个文件仍然该压，只是本轮没轮到它 ——
///   队列里保持 `pending`，下一次「继续压缩」自然带上。
///
/// 两者混在一起，就是"停止后 70 张图全部变成已跳过、再也没法继续"的根源。
pub enum AcquireOutcome {
    Acquired(ParallelPermit),
    Cancelled,
    Stopped,
}

/// 上限的最小值 —— 0 会让一个任务都启动不了。
pub const MIN_PARALLELISM: usize = 1;

impl CompressionScheduler {
    pub fn new(max_parallelism: usize) -> Self {
        Self {
            paused: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
            active_batch: AtomicBool::new(false),
            max_parallelism: AtomicUsize::new(max_parallelism.max(MIN_PARALLELISM)),
            active: AtomicUsize::new(0),
            notify: tokio::sync::Notify::new(),
        }
    }

    pub fn pause(&self) {
        self.paused.store(true, Ordering::Release);
    }

    /// 解除暂停并唤醒等待中的 worker。**只有用户点「继续」和批次起止才许调用**。
    pub fn resume(&self) {
        self.paused.store(false, Ordering::Release);
        self.notify.notify_waiters();
    }

    /// 停止整批：闸门对"还没开始"的文件永久关闭，已经在跑的跑完各自收尾。
    ///
    /// 与"取消某个文件"是两件事：`cancel_file` 要逐条记账（`cancel_queue`），
    /// 停止只是把闸门焊死 —— 后来者不需要谁替它记账，自己就会在
    /// `acquire` 里看见 `stopping` 并拿到 `AcquireOutcome::Stopped`。
    ///
    /// 绝不 kill 正在跑的进程：那会留下写了一半的临时文件、悬空的覆盖事务和
    /// 对不上账的历史，正是「宁可慢一点也不能弄丢原图」要避免的。
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    /// 只唤醒等待者，不改动暂停态。
    ///
    /// 与 `resume()` 的区别必须分清：取消一个文件需要正在等的 worker 醒来看到这个取消，
    /// 但**绝不**需要顺便把整批解除暂停 —— 老实现调的是 `resume()`，于是"暂停中移除一张图"
    /// 会让其余所有等待中的文件偷偷继续压缩，而 UI 上仍写着「暂停中…」。
    pub fn wake_waiters(&self) {
        self.notify.notify_waiters();
    }

    /// 是否有批次在跑。清空历史这类破坏性操作的硬保护看这个，不看前端状态。
    /// 用户点了停止但批次还在收尾时它仍然为真 —— 备份还在被认领，历史就不许被清。
    pub fn is_batch_active(&self) -> bool {
        self.active_batch.load(Ordering::Acquire)
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Acquire)
    }

    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
    }

    /// 运行中改上限：不回收已在跑的 permit，只影响之后的启动。
    pub fn set_max_parallelism(&self, limit: usize) {
        self.max_parallelism
            .store(limit.max(MIN_PARALLELISM), Ordering::Release);
        self.notify.notify_waiters();
    }

    pub fn max_parallelism(&self) -> usize {
        self.max_parallelism.load(Ordering::Acquire).max(MIN_PARALLELISM)
    }

    /// 当前正在占用的 CPU 并行份数。UI 展示的是"上限/核数"而不是这个瞬时值，
    /// 所以只有调度器测试会读它 —— 事件里也不带它：快照在下一次事件之前不会更新，
    /// 显示出去就是一句很快就会变假的话。
    #[cfg(test)]
    pub fn active(&self) -> usize {
        self.active.load(Ordering::Acquire)
    }

    pub fn begin_batch(&self) {
        // 新一批永远从"未暂停、未停止"开始，不继承上一批的状态。
        self.paused.store(false, Ordering::Release);
        self.stopping.store(false, Ordering::Release);
        self.active_batch.store(true, Ordering::Release);
    }

    pub fn end_batch(&self) {
        self.paused.store(false, Ordering::Release);
        self.stopping.store(false, Ordering::Release);
        self.active_batch.store(false, Ordering::Release);
        self.active.store(0, Ordering::Release);
        self.notify.notify_waiters();
    }

    /// idle / running / paused / stopping —— 前端按钮与 summary 的唯一真相来源。
    pub fn state(&self) -> CompressionState {
        if !self.active_batch.load(Ordering::Acquire) {
            return CompressionState::Idle;
        }
        // 停止盖过暂停：暂停中点停止，状态就该是"正在停止"，而不是一直显示暂停。
        if self.is_stopping() {
            return CompressionState::Stopping;
        }
        if self.is_paused() {
            CompressionState::Paused
        } else {
            CompressionState::Running
        }
    }

    /// 拿一份 CPU 预算：暂停中或名额已满就等，拿到时闸门是开着的。
    ///
    /// 老实现是"等信号量 → 再查一次暂停"两步，因为信号量不知道暂停。
    /// 现在两者在同一次 CAS 里判断，拿到 permit 的那一刻必然既没暂停也没超载。
    /// 测试专用：先拿一份预算，不关心演出条件（闸门一定是开的）。
    #[cfg(test)]
    pub async fn acquire_permit(self: &std::sync::Arc<Self>) -> ParallelPermit {
        // 这里传一个永远为假的取消判据：调用方不关心取消，只是要闸门开。
        match self.acquire(|| false).await {
            AcquireOutcome::Acquired(permit) => permit,
            // 测试里的调用点都保证闸门开着；真出现说明用例自己写错了。
            AcquireOutcome::Cancelled | AcquireOutcome::Stopped => {
                unreachable!("这个调用永远不会返回 Cancelled / Stopped")
            }
        }
    }

    /// 拿一份 CPU 预算；等待期间 `cancelled()` 变真、或批次被「停止」，就退出等待。
    ///
    /// 判定顺序是刻意的，**不能改**：取消 → 停止 → 暂停/名额。
    /// - 取消排最前：`paused == true` 且这个文件已被取消时，worker 能马上退出，
    ///   而暂停状态原样保留给其余还在排队的文件。
    /// - 停止排在暂停之前：暂停中按下停止，等待者必须能看见"整批已停"并退出，
    ///   否则它们会一直堵在关着的闸门上，直到用户点「继续」——那正是「停止」的反面。
    ///
    /// 三种结局必须分开回给调用方（`AcquireOutcome`）：取消是"这个文件不再参与队列"，
    /// 停止是"这一轮没轮到它，队列里它还是 pending"，两者的收尾动作完全相反。
    pub async fn acquire<F>(self: &std::sync::Arc<Self>, mut cancelled: F) -> AcquireOutcome
    where
        F: FnMut() -> bool,
    {
        loop {
            if cancelled() {
                return AcquireOutcome::Cancelled;
            }
            if self.is_stopping() {
                return AcquireOutcome::Stopped;
            }
            if let Some(permit) = self.try_acquire() {
                // 拿到的这一刻才被取消 / 才点了停止：还回预算，这个文件不压。
                if cancelled() {
                    drop(permit);
                    return AcquireOutcome::Cancelled;
                }
                if self.is_stopping() {
                    drop(permit);
                    return AcquireOutcome::Stopped;
                }
                return AcquireOutcome::Acquired(permit);
            }
            let notified = self.notify.notified();
            let _ = tokio::time::timeout(Duration::from_millis(250), notified).await;
        }
    }

    pub fn try_acquire(self: &std::sync::Arc<Self>) -> Option<ParallelPermit> {
        if self.is_paused() {
            return None;
        }
        let current = self.active.load(Ordering::Acquire);
        if current >= self.max_parallelism() {
            return None;
        }
        self.active
            .compare_exchange(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .ok()
            .map(|_| ParallelPermit { scheduler: self.clone() })
    }
}

impl Drop for ParallelPermit {
    fn drop(&mut self) {
        // saturating：end_batch 会把计数归零，迟到的 Drop 不能减成天文数字。
        self.scheduler.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
            Some(current.saturating_sub(1))
        }).ok();
        self.scheduler.notify.notify_waiters();
    }
}

/// 独立对比窗口的固定 label（capabilities/default.json 按 label 授权）。
pub const COMPARE_WINDOW_LABEL: &str = "compare";

// ─── Progress event payload ─────────────────────────────────────
/// 单个文件的进度状态。**用枚举而不是字符串**：老实现里"完成了但失败"和"被跳过"
/// 都靠一个空字符串 + 有没有 result 去猜，前端只能反过来推。
///
/// - `Queued`：这一轮开始了，它排在队列里。
/// - `Starting`：真的开工了（已经拿到闸门名额）。
/// - `Completed` / `Failed`：跑完了，`result` 里带着明细。
/// - `Cancelled`：用户明确把这个文件移出了队列 —— 它不再参与本轮，也不该再回队列。
/// - `Deferred`：整批被「停止」，这一轮没轮到它 —— **队列里它仍然是 pending**，
///   下一次「继续压缩」会带上它。它没有 `result`，因为它压根没执行。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgressStatus {
    Queued,
    Starting,
    Completed,
    Failed,
    Cancelled,
    Deferred,
}

/// 一条进度事件。`session_id` 是这一轮执行会话的标识：**逐条事件都带着它**，
/// 前端据此彻底阻断跨会话污染（上一轮迟到的 deferred 事件不许影响下一轮）。
///
/// `session_total` / `session_processed` 只描述**这一轮**（诊断用）：
/// 界面上的总进度由前端的队列状态派生（见 frontend/app.js 的 getQueueProgress），
/// 不是这个计数 —— 停止后重新开始一轮时，sessionTotal 会变小，而队列进度不该变小。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ProgressPayload {
    session_id: String,
    /// Frontend queue generation; an event from before Clear All must be ignored.
    queue_revision: u64,
    file: String,
    status: ProgressStatus,
    /// Unix milliseconds, for diagnostics and consistent event envelopes.
    timestamp: u64,
    /// 本轮的目标文件数（停止后重新开始的那一轮只数 pending）。
    session_total: usize,
    /// 本轮真正处理完的数量 + 明确取消的数量；`Deferred` **不增加**它。
    session_processed: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<CompressResult>,
}

fn event_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// 一轮执行的收尾报告。只用于诊断：界面总进度看队列，不看这里。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CompressionSessionResult {
    session_id: String,
    /// 真正跑过的文件数（= results.len()）。
    attempted: usize,
    completed: usize,
    failed: usize,
    /// 因为「停止」这一轮没轮到的文件数 —— 它们在队列里仍然是 pending。
    deferred: usize,
    /// 被用户明确取消（移出队列）的文件数。
    cancelled: usize,
    results: Vec<CompressResult>,
}

/// 批次阶段变化的载荷。
///
/// 只有状态，**不含"还有几个在跑"这类计数**：事件只在阶段真的变化时发一次，快照里的
/// 数字在下一个事件之前不会再更新，放进 UI 就是一句很快就变假的话。谁还在跑，队列里
/// 那几个仍在转圈的行就是活的答案。
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct CompressionStatePayload {
    state: CompressionState,
}

/// 阶段变化的唯一播报口：每次状态真的变了都走这里，前端不再猜。
fn emit_compression_state(app: &AppHandle, scheduler: &CompressionScheduler) {
    let _ = app.emit(
        "compression-state-change",
        CompressionStatePayload {
            state: scheduler.state(),
        },
    );
}

// ─── File collection ────────────────────────────────────────────
fn collect_image_files(file_paths: &[String]) -> Vec<String> {
    let exts = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "jxl", "heic", "heif", "tif",
        "tiff",
    ];
    let mut all = Vec::new();
    let mut seen_files = HashSet::new();
    let mut visited_dirs = HashSet::new();
    for fp in file_paths {
        let path = PathBuf::from(fp);
        if path.is_dir() {
            walk_dir(&path, &exts, &mut all, &mut seen_files, &mut visited_dirs);
        } else if path.is_file() {
            add_image_file(path, &exts, &mut all, &mut seen_files);
        }
    }
    all
}

fn path_identity(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

fn add_image_file(
    path: PathBuf,
    exts: &[&str],
    out: &mut Vec<String>,
    seen_files: &mut HashSet<String>,
) {
    let is_image = path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| exts.contains(&ext.to_lowercase().as_str()))
        .unwrap_or(false);
    if is_image {
        let canonical = path.canonicalize().unwrap_or_else(|_| path.clone());
        if seen_files.insert(canonical.to_string_lossy().into_owned()) {
            // Return the canonical path so separate imports using relative,
            // symlinked, or `..` aliases also deduplicate in the frontend.
            out.push(canonical.to_string_lossy().into_owned());
        }
    }
}

fn walk_dir(
    dir: &Path,
    exts: &[&str],
    out: &mut Vec<String>,
    seen_files: &mut HashSet<String>,
    visited_dirs: &mut HashSet<String>,
) {
    if !visited_dirs.insert(path_identity(dir)) {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
    paths.sort_by(|a, b| a.to_string_lossy().cmp(&b.to_string_lossy()));
    for path in paths {
        if path.is_dir() {
            walk_dir(&path, exts, out, seen_files, visited_dirs);
        } else if path.is_file() {
            add_image_file(path, exts, out, seen_files);
        }
    }
}

fn relative_path_from_source_roots(file_path: &Path, source_roots: &[String]) -> Option<PathBuf> {
    let canonical_file = file_path.canonicalize().ok()?;
    source_roots
        .iter()
        .filter_map(|root| {
            let root_path = PathBuf::from(root);
            if !root_path.is_dir() {
                return None;
            }
            let canonical_root = root_path.canonicalize().ok()?;
            let relative = canonical_file.strip_prefix(&canonical_root).ok()?;
            Some((canonical_root.components().count(), relative.to_path_buf()))
        })
        .max_by_key(|(depth, _)| *depth)
        .map(|(_, relative)| relative)
}

// ─── Result building ────────────────────────────────────────────
fn build_result(file_path: &str, engine_result: &EngineResult) -> CompressResult {
    let path = PathBuf::from(file_path);
    let original_size = engine::get_file_size(&path);
    let compressed_size = engine_result.compressed.len() as u64;
    let savings = if original_size > 0 {
        ((original_size - compressed_size.min(original_size)) as f64 / original_size as f64) * 100.0
    } else {
        0.0
    };
    CompressResult {
        success: engine_result.success,
        file: file_path.into(),
        original_size,
        compressed_size,
        savings: (savings * 10.0).round() / 10.0,
        original_size_formatted: engine::format_bytes(original_size),
        compressed_size_formatted: engine::format_bytes(compressed_size),
        out_type: engine_result.out_type.clone(),
        algorithm: engine_result.algorithm.clone(),
        error: engine_result.error.clone(),
        output_path: None,
        backup_path: None,
        output_mode: None,
    }
}

fn normalized_output_suffix(value: Option<&str>) -> String {
    let mut suffix = value
        .unwrap_or("_compressed")
        .trim()
        .chars()
        .map(|ch| {
            if ch == '/' || ch == '\\' || ch == '\0' || ch.is_control() {
                '_'
            } else {
                ch
            }
        })
        .collect::<String>();

    if suffix.is_empty() {
        suffix = "_compressed".into();
    }
    suffix.chars().take(64).collect()
}

fn available_system_conversion_path(file_path: &Path, out_type: &str) -> PathBuf {
    let preferred = file_path.with_extension(out_type);
    if !preferred.exists() {
        return preferred;
    }

    let stem = file_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("image");
    let parent = file_path.parent().unwrap_or(Path::new("."));
    for index in 1.. {
        let suffix = if index == 1 {
            "_converted".to_string()
        } else {
            format!("_converted_{}", index)
        };
        let candidate = parent.join(format!("{}{}.{}", stem, suffix, out_type));
        if !candidate.exists() {
            return candidate;
        }
    }
    unreachable!()
}

/// 落盘失败的分类。每一种都必须把 `CompressResult.success` 翻成 false ——
/// 引擎算成功但文件没写成时，UI 绝不许显示「压缩完成」。
#[derive(Debug)]
pub enum OutputWriteError {
    BackupFailed(String),
    TransactionFailed(String),
    OutputWriteFailed(String),
    HistoryWriteFailed,
    RollbackFailed(String),
}

impl OutputWriteError {
    pub fn user_message(&self) -> String {
        match self {
            OutputWriteError::BackupFailed(detail) => {
                format!("无法保存原图备份，已跳过覆盖（{detail}）")
            }
            OutputWriteError::TransactionFailed(detail) => {
                format!("无法登记这次覆盖，已跳过覆盖（{detail}）")
            }
            OutputWriteError::OutputWriteFailed(detail) => {
                format!("压缩结果写入失败，原图未被覆盖（{detail}）")
            }
            OutputWriteError::HistoryWriteFailed => {
                "压缩结果已生成，但历史记录保存失败，已自动恢复原图".into()
            }
            OutputWriteError::RollbackFailed(detail) => format!(
                "历史记录保存失败，且自动恢复原图也没成功：原图还在那份备份里，请不要清理备份，重试恢复即可（{detail}）"
            ),
        }
    }
}

/// Write the compressed bytes to disk according to the output mode.
///
/// replace 模式必须走完整的事务顺序，任何一步失败都不得留下"覆盖了但没人知道"的状态：
///
/// ```text
/// ① ensure_backup  ② 写 transaction  ③ 同目录临时文件写压缩结果
/// ④ flush + fsync  ⑤ rename 覆盖目标  ⑥ history.add  ⑦ 删 transaction
/// ```
///
/// ⑥ 失败就回滚：用备份把真正原图写回去、删掉这次生成的文件，并把错误报给用户。
fn write_output_file(
    result: &mut CompressResult,
    file_path: &Path,
    compressed: &[u8],
    file_paths: &[String],
    options: &CompressOptions,
    history: &HistoryStore,
    transactions: &TransactionStore,
    retention_days: u32,
) -> Result<(), OutputWriteError> {
    if !result.success || compressed.is_empty() {
        return Ok(());
    }
    // 格式转换时跳过大小检查（用户明确要求转换为目标格式）
    let is_format_conversion = options.output_format != "original";
    if !is_format_conversion && (compressed.len() as u64) >= result.original_size {
        result.error = Some("原图已是最优，无需替换".into());
        return Ok(());
    }
    let mut backup_file: Option<PathBuf> = None;
    let out_ext = format!(".{}", result.out_type);
    let out_path: Option<PathBuf> = match options.output_mode.as_str() {
        "replace" => {
            // 先备份再覆盖：备份没写成就不碰用户文件，否则原图永久丢失。
            let backup = match history.ensure_backup(file_path) {
                Ok(backup) => backup,
                Err(detail) => {
                    return Err(OutputWriteError::BackupFailed(detail));
                }
            };
            result.backup_path = Some(backup.to_string_lossy().into_owned());
            backup_file = Some(backup);
            let current_ext = file_path
                .extension()
                .and_then(|ext| ext.to_str())
                .unwrap_or("")
                .to_lowercase();
            let same_format = current_ext == result.out_type
                || (current_ext == "jpeg" && result.out_type == "jpg")
                || (current_ext == "jpg" && result.out_type == "jpeg")
                || (current_ext == "heif" && result.out_type == "heic")
                || (current_ext == "heic" && result.out_type == "heic");
            if options.processing_mode == "system" && is_format_conversion && !same_format {
                Some(available_system_conversion_path(file_path, &result.out_type))
            } else {
                Some(file_path.to_path_buf())
            }
        }
        "suffix" => {
            let stem = file_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("file");
            let dir = file_path.parent().unwrap_or(Path::new("."));
            let suffix = normalized_output_suffix(Some(&options.output_suffix));
            Some(dir.join(format!("{}{}{}", stem, suffix, out_ext)))
        }
        "folder" => {
            if let Some(ref out_dir) = options.output_dir {
                let fallback_root = if file_paths.len() == 1 && PathBuf::from(&file_paths[0]).is_dir() {
                    PathBuf::from(&file_paths[0])
                } else {
                    file_path
                        .parent()
                        .unwrap_or(Path::new("."))
                        .to_path_buf()
                };
                let rel = relative_path_from_source_roots(file_path, &options.source_roots)
                    .or_else(|| file_path.strip_prefix(&fallback_root).ok().map(Path::to_path_buf))
                    .unwrap_or_else(|| {
                        file_path
                            .file_name()
                            .map(PathBuf::from)
                            .unwrap_or_else(|| PathBuf::from("image"))
                    });
                let rel_out = rel.with_extension(&result.out_type);
                let out = PathBuf::from(out_dir).join(&rel_out);
                if let Some(p) = out.parent() {
                    let _ = fs::create_dir_all(p);
                }
                Some(out)
            } else {
                None
            }
        }
        _ => None,
    };

    let Some(out_path) = out_path else {
        return Ok(());
    };
    let is_replace = options.output_mode == "replace";
    let cross_format = is_replace && out_path != file_path;

    // ①事务id 必须在覆盖之前定下来：历史落盘成功与否就靠它和 transaction 对账。
    let history_id = is_replace.then(|| HistoryEntry::new_id(file_path));
    let mut txn = history_id.as_ref().map(|id| ReplaceTransaction {
        id: id.clone(),
        history_id: id.clone(),
        source_path: path_identity(file_path),
        output_path: out_path.to_string_lossy().into_owned(),
        backup_path: backup_file
            .as_ref()
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default(),
        temp_output_path: None,
        original_size: result.original_size,
        expected_output_size: compressed.len() as u64,
        created_at: crate::history::now_millis(),
        cross_format,
    });
    // ②记账先于动手：写不进日志就还不许碰用户文件。
    if let Some(record) = txn.as_ref() {
        if let Err(detail) = transactions.prepare(record) {
            return Err(OutputWriteError::TransactionFailed(detail));
        }
    }

    // ③④⑤同目录临时文件 → flush + fsync → rename。失败时目标文件保持原样。
    let staged = match StagedOutput::write(&out_path, compressed) {
        Ok(staged) => staged,
        Err(detail) => {
            if let Some(record) = txn.take() {
                transactions.finish(&record.id);
            }
            return Err(OutputWriteError::OutputWriteFailed(detail));
        }
    };
    if let Some(record) = txn.as_mut() {
        record.temp_output_path = Some(staged.temp.to_string_lossy().into_owned());
    }

    if cross_format {
        let _ = fs::remove_file(file_path);
    }
    result.output_path = Some(out_path.to_string_lossy().into());
    result.output_mode = Some(options.output_mode.clone());

    // 输出确认落盘之后才记历史：历史里绝不出现没写成的文件。
    let entry = match history_id {
        Some(id) => HistoryEntry::record_with_id(
            id,
            file_path,
            result,
            &out_path,
            backup_file.as_deref(),
            retention_days,
        ),
        None => HistoryEntry::record(
            file_path,
            result,
            &out_path,
            backup_file.as_deref(),
            retention_days,
        ),
    };
    if let Err(error) = history.add(entry.clone()) {
        // ⑥失败 = 这次覆盖不能算数：把真正原图写回去，删掉这次生成的文件。
        staged.discard();
        log::warn!("写入压缩历史失败: {error}");
        if let Some(record) = txn.as_ref() {
            match output_transaction::rollback(record) {
                Ok(()) => {
                    transactions.finish(&record.id);
                    result.output_path = None;
                    result.backup_path = None;
                    return Err(OutputWriteError::HistoryWriteFailed);
                }
                // 回滚也没成：事务日志必须留着，下次启动的 recovery 再试一次。
                Err(rollback) => {
                    return Err(OutputWriteError::RollbackFailed(format!(
                        "{error}；{rollback}"
                    )));
                }
            }
        }
    }
    // ⑦历史已经落盘 = 这次覆盖有据可查，销账。留着的话下次启动会误判成中断事务。
    if let Some(record) = txn.as_ref() {
        transactions.finish(&record.id);
    }
    Ok(())
}

// ─── Batch compression core ─────────────────────────────────────
fn take_cancelled(cancel_queue: &Mutex<HashSet<String>>, file_path: &str) -> bool {
    cancel_queue.lock().unwrap().remove(file_path)
}

// 启动下一个文件前的闸门就是 `CompressionScheduler::acquire`：暂停与 CPU 上限在同一次
// CAS 里判断，拿到 permit 的那一刻闸门必然是开的。老实现要"等信号量 → 再查一次暂停"，
// 因为信号量不知道暂停这回事。

/// 跑一轮执行会话：只处理传进来的这些文件（前端的「继续压缩」只提交 pending）。
///
/// 一轮的流程（与前端 Session 一一对应）：
/// `begin_batch` → 逐个文件过闸门 → 拿到名额的开工 → 等所有真正在跑的收尾 →
/// `end_batch` → 回报本轮结果。
/// 被「停止」挡在闸门外的文件发 `deferred` 事件后就地结束，**不进 results**：
/// 它们没执行过，队列里仍然是 pending，下一轮自然带上。
async fn compress_batch(
    app: &AppHandle,
    state: &AppState,
    session_id: String,
    queue_revision: u64,
    file_paths: Vec<String>,
    options: CompressOptions,
    use_smart: bool,
) -> CompressionSessionResult {
    // Keep cancellations that arrive between the frontend's start request and
    // this command's first poll. The queue is cleared after all workers exit,
    // so a completed batch cannot leak cancellation state into the next one.
    let all_files = collect_image_files(&file_paths);
    let session_total = all_files.len();

    // 沙盒版只对用户刚选中的路径持有授权：趁现在还能访问，把这批输入存成书签，
    // 否则重启后历史记录指向的位置再也读不到。
    state.access.remember_all(&all_files);
    let settings = state.settings_store.load();
    state.compression.begin_batch();
    // 每批开始按当前设置重算并发度：设置命令走的是同一个调度器，这里只是兜底，
    // 保证换过机器 / 手改过 settings.json 也不会拿到一个能卡死的上限。
    state
        .compression
        .set_max_parallelism(effective_cpu_limit(
            settings.cpu_thread_limit,
            state.cpu_info.budget_ceiling(),
        ));
    let retention_days = settings.original_retention_days;
    // 批次真的开跑了才播报 running：前端在拿到这条事件之前不许显示「压缩中…」。
    emit_compression_state(app, &state.compression);

    // Emit "queued" for all files
    for fp in &all_files {
        let _ = app.emit(
            "compress-progress",
            ProgressPayload {
                session_id: session_id.clone(),
                queue_revision,
                file: fp.clone(),
                status: ProgressStatus::Queued,
                timestamp: event_timestamp(),
                session_total,
                session_processed: 0,
                result: None,
            },
        );
    }

    // 并发度由 CPU 上限决定（不再是写死的 3）
    use std::sync::Arc;
    use tokio::sync::Mutex;

    let options = Arc::new(options);
    let file_paths_arc = Arc::new(file_paths);
    let app_arc = Arc::new(app.clone());
    let cancel_queue = &state.cancel_queue;
    let control = state.compression.clone();
    let history = state.history_store.clone();
    let transactions = state.transactions.clone();
    let results_arc = Arc::new(Mutex::new(Vec::<CompressResult>::new()));
    // 本轮真正处理完的数量 + 明确取消的数量。`deferred` 绝不加它：
    // 没执行过的文件不算处理过，否则"停止后继续"的进度会凭空多出一截。
    let processed_arc = Arc::new(AtomicUsize::new(0));
    let deferred = Arc::new(AtomicUsize::new(0));
    let cancelled_count = Arc::new(AtomicUsize::new(0));
    let session_id_arc = Arc::new(session_id.clone());

    let mut handles: Vec<(tokio::task::JoinHandle<()>, String)> = Vec::new();
    for file_path in all_files {
        // 闸门：暂停或名额满了就在这里等，拿到的瞬间两者都已满足。
        // 等待期间这个文件被取消就直接退出，**绝不因此解除暂停**。
        let outcome = control
            .acquire(|| take_cancelled(cancel_queue, &file_path))
            .await;
        let permit = match outcome {
            AcquireOutcome::Acquired(permit) => permit,
            // 用户明确把这个文件移出队列：报一条 cancelled，它本轮到此为止。
            AcquireOutcome::Cancelled => {
                let done = processed_arc.fetch_add(1, Ordering::SeqCst) + 1;
                cancelled_count.fetch_add(1, Ordering::SeqCst);
                let _ = app_arc.emit(
                    "compress-progress",
                    ProgressPayload {
                        session_id: session_id_arc.to_string(),
                        queue_revision,
                        file: file_path.clone(),
                        status: ProgressStatus::Cancelled,
                        timestamp: event_timestamp(),
                        session_total,
                        session_processed: done,
                        result: None,
                    },
                );
                continue;
            }
            // 整批被停止：这一轮没轮到它。**不生成任何 result、也不计入 session_processed**，
            // 只告诉前端"这一个是 deferred"——它在前端的队列里仍然是 pending。
            AcquireOutcome::Stopped => {
                deferred.fetch_add(1, Ordering::SeqCst);
                let done = processed_arc.load(Ordering::SeqCst);
                let _ = app_arc.emit(
                    "compress-progress",
                    ProgressPayload {
                        session_id: session_id_arc.to_string(),
                        queue_revision,
                        file: file_path.clone(),
                        status: ProgressStatus::Deferred,
                        timestamp: event_timestamp(),
                        session_total,
                        session_processed: done,
                        result: None,
                    },
                );
                continue;
            }
        };

        // Emit "starting" only after the worker is available.
        {
            let pr = processed_arc.load(Ordering::SeqCst);
            let _ = app_arc.emit(
                "compress-progress",
                ProgressPayload {
                    session_id: session_id_arc.to_string(),
                    queue_revision,
                    file: file_path.clone(),
                    status: ProgressStatus::Starting,
                    timestamp: event_timestamp(),
                    session_total,
                    session_processed: pr,
                    result: None,
                },
            );
        }

        let opts = options.clone();
        let fps = file_paths_arc.clone();
        let app_c = app_arc.clone();
        let history_c = history.clone();
        let transactions_c = transactions.clone();
        let results_c = results_arc.clone();
        let processed_c = processed_arc.clone();
        let session_id_c = session_id_arc.clone();
        let fp = file_path.clone();

        let fp_for_track = fp.clone();
        handles.push((tokio::spawn(async move {
            let _permit = permit; // 持有信号量直到压缩完成

            let path = PathBuf::from(&fp);
            let engine_result = if use_smart {
                engine::compress_smart(&path, &opts).await
            } else {
                engine::compress_image(&path, &opts).await
            };

            let mut result = build_result(&fp, &engine_result);
            if let Err(error) = write_output_file(
                &mut result,
                &path,
                &engine_result.compressed,
                &fps,
                &opts,
                &history_c,
                &transactions_c,
                retention_days,
            ) {
                // 落盘没成就是没成：UI 绝不许显示「压缩完成」。
                eprintln!("[ERROR] {fp} 落盘失败: {error:?}");
                result.success = false;
                result.output_path = None;
                result.error = Some(error.user_message());
            }

            {
                let done = processed_c.fetch_add(1, Ordering::SeqCst) + 1;
                let status = if result.success {
                    ProgressStatus::Completed
                } else {
                    ProgressStatus::Failed
                };
                let _ = app_c.emit(
                    "compress-progress",
                    ProgressPayload {
                        session_id: session_id_c.to_string(),
                        queue_revision,
                        file: fp.clone(),
                        status,
                        timestamp: event_timestamp(),
                        session_total,
                        session_processed: done,
                        result: Some(result.clone()),
                    },
                );
            }

            let mut res = results_c.lock().await;
            res.push(result);
        }), fp_for_track));
    }

    // 等待所有任务完成
    for (handle, fp) in handles {
        if let Err(e) = handle.await {
            eprintln!("[ERROR] compression task panicked for {}: {:?}", fp, e);
            let done = processed_arc.fetch_add(1, Ordering::SeqCst) + 1;
            let _ = app_arc.emit(
                "compress-progress",
                ProgressPayload {
                    session_id: session_id_arc.to_string(),
                    queue_revision,
                    file: fp.clone(),
                    status: ProgressStatus::Failed,
                    timestamp: event_timestamp(),
                    session_total,
                    session_processed: done,
                    result: Some(failed_result(fp)),
                },
            );
        }
    }

    state.cancel_queue.lock().unwrap().clear();
    // 批次结束必须清暂停与停止，否则下一批继承上一批的状态。
    state.compression.end_batch();
    emit_compression_state(app, &state.compression);
    let final_results = results_arc.lock().await.clone();
    let completed = final_results.iter().filter(|r| r.success).count();
    let failed = final_results.len() - completed;
    CompressionSessionResult {
        session_id,
        attempted: final_results.len(),
        completed,
        failed,
        deferred: deferred.load(Ordering::SeqCst),
        cancelled: cancelled_count.load(Ordering::SeqCst),
        results: final_results,
    }
}

fn failed_result(file: String) -> CompressResult {
    CompressResult {
        success: false,
        file,
        original_size: 0,
        compressed_size: 0,
        savings: 0.0,
        original_size_formatted: "0 B".into(),
        compressed_size_formatted: "0 B".into(),
        out_type: "unknown".into(),
        algorithm: "none".into(),
        error: Some("压缩过程发生内部错误".into()),
        output_path: None,
        backup_path: None,
        output_mode: None,
    }
}

// ─── Tauri commands ─────────────────────────────────────────────

#[tauri::command]
pub async fn select_files(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Vec<String>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .add_filter(
            "Images",
            &[
                "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "jxl", "heic", "heif",
                "tif", "tiff",
            ],
        )
        .pick_files(move |files| {
            let _ = tx.send(files);
        });
    let files = rx.await.map_err(|e| e.to_string())?.unwrap_or_default();
    let paths: Vec<String> = files
        .into_iter()
        .filter_map(|fp| fp.into_path().ok().map(|p| p.to_string_lossy().into_owned()))
        .collect();
    // 刚选中的路径带着系统授权，此时存书签才有效。
    state.access.remember_all(&paths);
    Ok(paths)
}

#[tauri::command]
pub async fn select_folder(app: AppHandle, state: State<'_, AppState>) -> Result<Vec<String>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_folder(move |folder| {
        let _ = tx.send(folder);
    });
    let folder = rx.await.map_err(|e| e.to_string())?;
    let paths: Vec<String> = folder
        .into_iter()
        .filter_map(|fp| fp.into_path().ok().map(|p| p.to_string_lossy().into_owned()))
        .collect();
    state.access.remember_all(&paths);
    Ok(paths)
}

#[tauri::command]
pub async fn select_output_dir(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Vec<String>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_folder(move |folder| {
        let _ = tx.send(folder);
    });
    let folder = rx.await.map_err(|e| e.to_string())?;
    let paths: Vec<String> = folder
        .into_iter()
        .filter_map(|fp| fp.into_path().ok().map(|p| p.to_string_lossy().into_owned()))
        .collect();
    state.access.remember_all(&paths);
    Ok(paths)
}

#[tauri::command]
pub fn expand_image_files(file_paths: Vec<String>) -> Vec<String> {
    collect_image_files(&file_paths)
}

/// 一轮执行会话的入口。`session_id` 由前端生成并原样回传，所有进度事件都带着它 ——
/// 前端据此把"上一轮迟到的收尾事件"和"这一轮正在进行的事件"彻底分开。
#[tauri::command]
pub async fn compress_files(
    app: AppHandle,
    state: State<'_, AppState>,
    session_id: String,
    queue_revision: u64,
    file_paths: Vec<String>,
    options: CompressOptions,
) -> Result<CompressionSessionResult, String> {
    Ok(compress_batch(&app, state.inner(), session_id, queue_revision, file_paths, options, false).await)
}

#[tauri::command]
pub async fn compress_smart(
    app: AppHandle,
    state: State<'_, AppState>,
    session_id: String,
    queue_revision: u64,
    file_paths: Vec<String>,
    options: CompressOptions,
) -> Result<CompressionSessionResult, String> {
    Ok(compress_batch(&app, state.inner(), session_id, queue_revision, file_paths, options, true).await)
}

#[tauri::command]
pub async fn compress_single(
    file_path: String,
    options: CompressOptions,
) -> Result<CompressResult, String> {
    let path = PathBuf::from(&file_path);
    let engine_result = engine::compress_image(&path, &options).await;
    let mut result = build_result(&file_path, &engine_result);

    // Write compressed output to a persistent temp file for display
    if engine_result.success {
        let dir = std::env::temp_dir().join("octoshrink-display");
        let _ = fs::create_dir_all(&dir);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let out_file = dir.join(format!("recompress-{}.{}", ts, engine_result.out_type));
        if fs::write(&out_file, &engine_result.compressed).is_ok() {
            result.output_path = Some(out_file.to_string_lossy().into());
        }
    }
    Ok(result)
}

/// 清理临时目录：`octoshrink-display`（单图重压缩对比文件）、`octoshrink-work`
/// （压缩中间产物）。原图备份在 AppData 下的 history/backups，按保留档位决定去留，
/// 这里绝不能再删；旧版本遗留在 TMP 的备份目录没有任何历史引用它，继续回收。
pub fn cleanup_temp_dirs() {
    for name in ["octoshrink-display", "octoshrink-work", "octoshrink-backups"] {
        let _ = fs::remove_dir_all(std::env::temp_dir().join(name));
    }
}

/// 退出时按当前保留档位清一次历史记录与原图备份 —— 这是保留档位唯一的执行点。
///
/// 只在正常退出跑，启动时不清：崩溃或强杀现场的那份备份可能是唯一还活着的原图，
/// 删掉它就把"覆盖不可逆"变成"原图彻底没了"。中途改档位也在这一刻生效。
pub fn apply_retention_on_exit(app: &AppHandle) {
    let state = app.state::<AppState>();
    let report = state.history_store.apply_retention_on_exit(
        state.settings_store.load().original_retention_days,
        state.run_started_at,
        state.previous_run_ended_cleanly,
    );
    if report.removed_entries > 0 || report.removed_backups > 0 {
        log::info!(
            "退出清理: 历史记录 -{} 条，原图备份 -{} 份，保留 {} 份",
            report.removed_entries,
            report.removed_backups,
            report.kept_backups
        );
    }
    for warning in &report.warnings {
        log::warn!("退出清理未完成: {warning}");
    }
    // 只有账真结了才留记号。历史不可信或写盘失败时跳过清理，那批备份就得继续留着，
    // 于是下一次退出仍然按"上次异常退出"处理，多给它一个会话的机会。
    if report.warnings.is_empty() {
        state.history_store.mark_clean_exit();
    }
}

#[tauri::command]
pub fn cancel_file(file_path: String, state: State<'_, AppState>) -> bool {
    state.cancel_queue.lock().unwrap().insert(file_path);
    // 只把正在等的 worker 叫醒，暂停态原样保留 —— 取消一张图不等于继续整批。
    state.compression.wake_waiters();
    true
}

/// 一次 IPC 取消整批：前端 Clear All 不再循环 N 次 `cancel_file`。
///
/// 逐个 invoke 会让"部分已取消、部分还在排队"的中间态暴露给调度器，
/// 几十个异步 IPC 之间只要有一次暂停/名额变化就会出现竞态。
#[tauri::command]
pub fn cancel_batch(file_paths: Vec<String>, state: State<'_, AppState>) -> usize {
    let unique: HashSet<String> = file_paths.into_iter().collect();
    let queued = unique.len();
    state.cancel_queue.lock().unwrap().extend(unique);
    // 一批取消只唤醒一次：与逐个 invoke 相比，中间态少得多。
    state.compression.wake_waiters();
    queued
}

#[tauri::command]
pub fn clear_cancel_queue(state: State<'_, AppState>) -> bool {
    state.cancel_queue.lock().unwrap().clear();
    state.compression.wake_waiters();
    true
}

#[tauri::command]
pub fn pause_compression(app: AppHandle, state: State<'_, AppState>) -> CompressionState {
    state.compression.pause();
    emit_compression_state(&app, &state.compression);
    state.compression.state()
}

#[tauri::command]
pub fn resume_compression(app: AppHandle, state: State<'_, AppState>) -> CompressionState {
    state.compression.resume();
    emit_compression_state(&app, &state.compression);
    state.compression.state()
}

/// 停止**这一轮**：还没轮到的文件不再启动，正在压的几个跑完，本轮收尾后回到 idle。
///
/// 停止**不是取消**：没轮到的文件各自收到一条 `deferred` 事件，队伍里仍然是 pending，
/// 用户点「继续压缩」时新一轮会把它们带上（见 `AcquireOutcome`）。
///
/// 不需要前端把路径传进来 —— 闸门自己认得 `stopping`，排在后面的文件
/// 一个个在 `acquire` 里自行退出。这也是"停止"比"逐个取消"更可靠的地方：
/// 不存在"部分已停、部分还在排队"的中间态。
#[tauri::command]
pub fn stop_compression(app: AppHandle, state: State<'_, AppState>) -> CompressionState {
    state.compression.stop();
    emit_compression_state(&app, &state.compression);
    state.compression.state()
}

#[tauri::command]
pub fn get_compression_state(state: State<'_, AppState>) -> CompressionState {
    state.compression.state()
}

#[tauri::command]
pub fn list_history(state: State<'_, AppState>) -> Vec<HistoryEntry> {
    state.history_store.list()
}

/// 清空历史 = 连原图备份一起删。这是全 App 里破坏性最大的操作，
/// 所以判据必须在**后端**，不能指望前端把按钮禁用住。
#[tauri::command]
pub fn clear_history(state: State<'_, AppState>) -> Result<usize, String> {
    if state.compression.is_batch_active() {
        return Err("压缩进行中，无法清空历史记录".into());
    }
    // 批次可能刚好结束、事务还挂着（比如 worker 被取消后迟到的写入）：
    // 这时清历史会连正在跑那批的备份一起删掉，比 batch active 更严格的判据。
    if state.transactions.has_pending() {
        return Err("仍有文件事务正在处理，暂时无法清空历史记录".into());
    }
    let report = state.history_store.clear()?;
    for warning in report.warnings {
        log::warn!("清理历史失败: {warning}");
    }
    Ok(report.removed_entries)
}

#[tauri::command]
pub fn get_app_settings(state: State<'_, AppState>) -> AppSettings {
    state.settings_store.load()
}

/// 只改持久值：清理只在正常退出时跑，所以这里绝不顺手删东西，生效时点就是下一次关闭应用。
#[tauri::command]
pub fn set_original_retention_days(
    state: State<'_, AppState>,
    days: u32,
) -> Result<AppSettings, String> {
    state.settings_store.set_retention_days(days)
}

/// 本机 CPU 能力 + 用户配置 + 当前真正生效值。
#[tauri::command]
pub fn get_cpu_info(state: State<'_, AppState>) -> CpuStatus {
    cpu_status(state.inner())
}

#[tauri::command]
pub fn get_cpu_resource_settings(state: State<'_, AppState>) -> AppSettings {
    state.settings_store.load()
}

/// 运行中改上限：已在跑的任务继续跑完，之后的新任务按新值启动 —— 与暂停同一套语义。
#[tauri::command]
pub fn set_cpu_thread_limit(
    state: State<'_, AppState>,
    limit: Option<usize>,
) -> Result<CpuStatus, String> {
    let settings = state.settings_store.set_cpu_thread_limit(limit)?;
    let effective =
        effective_cpu_limit(settings.cpu_thread_limit, state.cpu_info.budget_ceiling());
    state.compression.set_max_parallelism(effective);
    Ok(cpu_status(state.inner()))
}

fn cpu_status(state: &AppState) -> CpuStatus {
    let settings = state.settings_store.load();
    CpuStatus {
        info: state.cpu_info.clone(),
        configured_limit: settings.cpu_thread_limit,
        effective_limit: effective_cpu_limit(
            settings.cpu_thread_limit,
            state.cpu_info.budget_ceiling(),
        ),
    }
}

#[tauri::command]
pub async fn save_file(source_path: String, app: AppHandle) -> Result<Option<String>, String> {
    let p = PathBuf::from(&source_path);
    let file_name = p
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("compressed")
        .to_string();
    let ext = p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("png")
        .to_string();

    let save_path = app
        .dialog()
        .file()
        .set_file_name(&file_name)
        .add_filter("Image", &[&ext])
        .blocking_save_file();

    if let Some(fp) = save_path {
        if let Ok(dest) = fp.into_path() {
            let _ = fs::copy(&source_path, &dest);
            return Ok(Some(dest.to_string_lossy().into_owned()));
        }
    }
    Ok(None)
}

#[tauri::command]
pub fn open_in_finder(file_path: String) -> bool {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open")
            .args(["-R", &file_path])
            .spawn();
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        let path = PathBuf::from(&file_path);
        let canonical = path.canonicalize().unwrap_or(path);
        if canonical.is_file() {
            let _ = std::process::Command::new("explorer.exe")
                .arg("/select,")
                .arg(&canonical)
                .creation_flags(CREATE_NO_WINDOW)
                .spawn();
        } else {
            let dir = if canonical.is_dir() {
                canonical
            } else {
                canonical
                    .parent()
                    .map(Path::to_path_buf)
                    .unwrap_or_else(|| PathBuf::from(&file_path))
            };
            let _ = std::process::Command::new("explorer.exe")
                .arg(dir)
                .creation_flags(CREATE_NO_WINDOW)
                .spawn();
        }
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("xdg-open")
            .arg(file_path)
            .spawn();
    }
    true
}

#[tauri::command]
pub fn read_image_dataurl(file_path: String, preview: Option<bool>) -> Option<String> {
    let path = PathBuf::from(&file_path);
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("png")
        .to_lowercase();
    let preview_data = if preview.unwrap_or(false) {
        preview_image_bytes(&path, &ext)
    } else {
        None
    };
    let has_preview = preview_data.is_some();
    let data = preview_data.or_else(|| fs::read(&path).ok())?;
    let mime = if has_preview {
        if matches!(ext.as_str(), "jpg" | "jpeg") {
            "image/jpeg"
        } else {
            "image/png"
        }
    } else {
        match ext.as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "bmp" => "image/bmp",
            "avif" => "image/avif",
            "jxl" => "image/jxl",
            _ => "image/png",
        }
    };
    let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
    Some(format!("data:{};base64,{}", mime, b64))
}

fn preview_image_bytes(path: &Path, ext: &str) -> Option<Vec<u8>> {
    if matches!(ext, "gif" | "avif" | "jxl") {
        return None;
    }

    const MAX_PREVIEW_DIMENSION: u32 = 2048;
    const MAX_RAW_PREVIEW_BYTES: u64 = 8 * 1024 * 1024;

    let original_size = fs::metadata(path).ok()?.len();
    let img = image::open(path).ok()?;
    let needs_preview = original_size > MAX_RAW_PREVIEW_BYTES
        || img.width() > MAX_PREVIEW_DIMENSION
        || img.height() > MAX_PREVIEW_DIMENSION;

    if !needs_preview {
        return None;
    }

    let preview = img.thumbnail(MAX_PREVIEW_DIMENSION, MAX_PREVIEW_DIMENSION);
    let mut buf = Vec::new();

    if matches!(ext, "jpg" | "jpeg") {
        let rgb = preview.to_rgb8();
        let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 84);
        use image::ImageEncoder;
        encoder
            .write_image(
                &rgb,
                preview.width(),
                preview.height(),
                image::ExtendedColorType::Rgb8,
            )
            .ok()?;
    } else {
        let rgba = preview.to_rgba8();
        let encoder = image::codecs::png::PngEncoder::new_with_quality(
            &mut buf,
            image::codecs::png::CompressionType::Fast,
            image::codecs::png::FilterType::Adaptive,
        );
        use image::ImageEncoder;
        encoder
            .write_image(
                &rgba,
                preview.width(),
                preview.height(),
                image::ExtendedColorType::Rgba8,
            )
            .ok()?;
    }

    Some(buf)
}

#[tauri::command]
pub fn get_app_version(app: AppHandle) -> String {
    app.package_info().version.to_string()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreOutcome {
    success: bool,
    /// true = 压缩之后目标文件又被改过，需要用户确认后用 force = true 再来一次。
    conflict: bool,
    file_path: String,
    error: Option<String>,
    /// 一起被标记为「已恢复」的历史记录：同一张图重压多次会共享那份真正原图。
    history_ids: Vec<String>,
    /// 这条记录当时是哪种输出方式。后缀 / 目录模式下后端做的是"删掉这次的压缩产物"，
    /// 前端要据此措辞 —— 统一服务被三个入口共用，只有后端知道刚刚真正发生了什么。
    output_mode: String,
}

impl RestoreOutcome {
    fn failure(entry: Option<&HistoryEntry>, error: RestoreError) -> Self {
        let detail = match &error {
            RestoreError::Io(inner) => format!("恢复失败: {inner}"),
            other => other.message().to_string(),
        };
        Self {
            success: false,
            conflict: matches!(error, RestoreError::Conflict),
            file_path: entry.map(|e| e.source_path.clone()).unwrap_or_default(),
            error: Some(detail),
            history_ids: Vec::new(),
            output_mode: entry.map(|e| e.output_mode.clone()).unwrap_or_default(),
        }
    }
}

/// 沙盒下书签失效时，请用户重新授权目标文件夹；Direct 版这条路径不会走到。
fn request_folder_access(app: &AppHandle, state: &AppState, target: &Path) -> bool {
    let Some(picked) = app
        .dialog()
        .file()
        .blocking_pick_folder()
        .and_then(|fp| fp.into_path().ok())
    else {
        return false;
    };
    let parent_ok = target == picked.as_path() || target.starts_with(&picked);
    state.access.remember(&picked);
    parent_ok
}

/// 统一恢复服务：主队列、历史页、恢复全部三个入口都只能走这里。
fn restore_entry(app: &AppHandle, state: &AppState, entry: &HistoryEntry, force: bool) -> RestoreOutcome {
    let mut reauth = || {
        request_folder_access(
            app,
            state,
            Path::new(&entry.source_path),
        )
    };
    match state
        .history_store
        .restore(entry, force, state.access.as_ref(), &mut reauth)
    {
        Ok(ids) => RestoreOutcome {
            success: true,
            conflict: false,
            file_path: entry.source_path.clone(),
            error: None,
            history_ids: ids,
            output_mode: entry.output_mode.clone(),
        },
        Err(error) => RestoreOutcome::failure(Some(entry), error),
    }
}

/// 按源路径取最近一条还没恢复的记录（主队列的行只知道自己压的是哪个文件）。
fn entry_for_source(state: &AppState, file_path: &str) -> Option<HistoryEntry> {
    let canonical = PathBuf::from(file_path)
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(file_path));
    state
        .history_store
        .find_latest_for_source(&canonical.to_string_lossy())
}

#[tauri::command]
pub fn restore_original(
    app: AppHandle,
    state: State<'_, AppState>,
    file_path: String,
    force: Option<bool>,
) -> RestoreOutcome {
    match entry_for_source(state.inner(), &file_path) {
        Some(entry) => restore_entry(&app, state.inner(), &entry, force.unwrap_or(false)),
        None => RestoreOutcome::failure(None, RestoreError::NotFound),
    }
}

#[tauri::command]
pub fn restore_history_entry(
    app: AppHandle,
    state: State<'_, AppState>,
    history_id: String,
    force: Option<bool>,
) -> RestoreOutcome {
    match state.history_store.find(&history_id) {
        Some(entry) => restore_entry(&app, state.inner(), &entry, force.unwrap_or(false)),
        None => RestoreOutcome::failure(None, RestoreError::NotFound),
    }
}

/// 一键恢复全部原图
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreAllResult {
    success: bool,
    restored: usize,
    failed: usize,
    message: String,
    /// 真正被恢复的源路径：前端据此逐行标记「已恢复」，不靠猜。
    restored_files: Vec<String>,
}

#[tauri::command]
pub fn restore_all(
    app: AppHandle,
    state: State<'_, AppState>,
    results: Vec<CompressResult>,
) -> RestoreAllResult {
    let mut restored = 0usize;
    let mut failed = 0usize;
    let mut conflicts = 0usize;
    let mut restored_files: Vec<String> = Vec::new();

    for r in &results {
        if !r.success {
            continue;
        }
        let outcome = match entry_for_source(state.inner(), &r.file) {
            Some(entry) => restore_entry(&app, state.inner(), &entry, false),
            None => RestoreOutcome::failure(None, RestoreError::NotFound),
        };
        if outcome.success {
            restored += 1;
            restored_files.push(outcome.file_path.clone());
        } else {
            failed += 1;
            if outcome.conflict {
                conflicts += 1;
            }
        }
    }

    let mut message = format!("已恢复 {restored} 个文件");
    if conflicts > 0 {
        message.push_str(&format!(
            "，{conflicts} 个文件压缩后又被修改过，请在历史记录里逐个确认"
        ));
    } else if failed > 0 {
        message.push_str(&format!("，{failed} 个未能恢复"));
    }
    RestoreAllResult {
        success: true,
        restored,
        failed,
        message,
        restored_files,
    }
}

#[tauri::command]
pub fn get_file_sizes(file_paths: Vec<String>) -> Vec<u64> {
    file_paths
        .iter()
        .map(|fp| engine::get_file_size(&PathBuf::from(fp)))
        .collect()
}

/// 打开（或聚焦）独立对比窗口，并把待渲染载荷暂存到 AppState。
///
/// 载荷形如 `{ results: [...成功结果对象...], index: <当前文件下标> }`，由前端组装；
/// compare 窗口页面加载完成后调用 take_compare_window_payload 取走，避免创建竞态。
/// 同步命令默认在主线程执行，可安全创建窗口。
///
/// 两条产物线行为一致，仅前端页面 URL 按 feature 分叉：
/// - Direct（cli-backends）：tauri:// 协议内嵌资源 compare.html
/// - App Store（inproc-backends）：沙盒阻止 tauri://，走本地 HTTP 服务器
///   （http://localhost:<port>/compare.html，端口见 lib.rs 固定端口段）
#[tauri::command]
pub fn open_compare_window(
    app: AppHandle,
    state: State<'_, AppState>,
    payload: serde_json::Value,
) -> Result<(), String> {
    *state.pending_compare.lock().unwrap() = Some(payload.clone());

    if let Some(window) = app.get_webview_window(COMPARE_WINDOW_LABEL) {
        let _ = window.unminimize();
        let _ = window.set_focus();
        let _ = app.emit_to(COMPARE_WINDOW_LABEL, "compare-open", payload);
        return Ok(());
    }

    let theme = crate::read_startup_theme().unwrap_or("light");
    let background = crate::startup_background(theme);

    #[cfg(feature = "inproc-backends")]
    let url = {
        let port = crate::frontend_http_port()
            .ok_or_else(|| "本地前端服务未启动，无法打开对比窗口".to_string())?;
        let parsed: tauri::Url = format!("http://localhost:{port}/compare.html")
            .parse()
            .map_err(|error| format!("对比窗口地址无效: {error}"))?;
        tauri::WebviewUrl::External(parsed)
    };
    #[cfg(not(feature = "inproc-backends"))]
    let url = tauri::WebviewUrl::App("compare.html".into());

    let builder = tauri::webview::WebviewWindowBuilder::new(&app, COMPARE_WINDOW_LABEL, url)
        .title("原图对比")
        .inner_size(1080.0, 780.0)
        .min_inner_size(560.0, 440.0)
        .resizable(true)
        .background_color(background);
    // 与主窗口同一模式：窗口始终可见，创建即带主题背景色（compare.html 首帧自设
    // 同步主题背景，不会露白）。❌ 不许用 visible(false) + on_page_load 延迟 show：
    // 那里的 webview.show() 经 wry 只作用于 WKWebView 视图，NSWindow 仍隐藏，
    // 沙盒版对比窗口将永远弹不出来（v2.5.44 实测 bug）。
    builder
        .build()
        .map_err(|error| format!("创建对比窗口失败: {error}"))?;
    Ok(())
}

/// compare 窗口页面就绪后取走暂存的对比载荷（取后即清）。
#[tauri::command]
pub fn take_compare_window_payload(state: State<'_, AppState>) -> Option<serde_json::Value> {
    state.pending_compare.lock().unwrap().take()
}

/// Export all compressed results to their original directories with the selected suffix.
#[tauri::command]
pub fn export_all(results: Vec<CompressResult>, output_suffix: Option<String>) -> usize {
    let mut count = 0usize;
    let suffix = normalized_output_suffix(output_suffix.as_deref());
    for r in &results {
        if r.success {
            if let Some(ref out_path) = r.output_path {
                let src = PathBuf::from(out_path);
                let dir = PathBuf::from(&r.file)
                    .parent()
                    .unwrap_or(Path::new("."))
                    .to_path_buf();
                let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("png");
                let file_path = PathBuf::from(&r.file);
                let stem = file_path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("file");
                let dest = dir.join(format!("{}{}.{}", stem, suffix, ext));
                if src == dest || fs::copy(&src, &dest).is_ok() {
                    count += 1;
                }
            }
        }
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    async fn wait_until(mut condition: impl FnMut() -> bool) -> bool {
        for _ in 0..250 {
            if condition() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        false
    }

    /// `AcquireOutcome` 不是 PartialEq（permit 没法比），断言只看它落在哪一支。
    fn outcome_name(outcome: AcquireOutcome) -> &'static str {
        match outcome {
            AcquireOutcome::Acquired(_) => "acquired",
            AcquireOutcome::Cancelled => "cancelled",
            AcquireOutcome::Stopped => "stopped",
        }
    }

    /// 上限就是上限：limit=3 时任何时刻最多 3 份在跑；暂停只拦新任务，不 interrupt 已开跑的。
    ///
    /// 用 work_gate（0 号牌的信号量）当"任务什么时候算跑完"的手动开关，避免靠 sleep 猜时序。
    #[tokio::test]
    async fn cpu_limit_caps_running_jobs_and_pause_blocks_only_new_ones() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(3));
        let work_gate = std::sync::Arc::new(tokio::sync::Semaphore::new(0));
        let started = std::sync::Arc::new(AtomicUsize::new(0));
        let finished = std::sync::Arc::new(AtomicUsize::new(0));
        let peak = std::sync::Arc::new(AtomicUsize::new(0));
        scheduler.begin_batch();

        let driver = {
            let scheduler = scheduler.clone();
            let work_gate = work_gate.clone();
            let started = started.clone();
            let finished = finished.clone();
            let peak = peak.clone();
            tokio::spawn(async move {
                let mut running = Vec::new();
                for _ in 0..10 {
                    // 闸门：暂停或名额满了就等在这里。
                    let permit = scheduler.acquire_permit().await;
                    let running_now = started.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(running_now, Ordering::SeqCst);
                    let work_gate = work_gate.clone();
                    let started = started.clone();
                    let finished = finished.clone();
                    running.push(tokio::spawn(async move {
                        // 模拟已经在跑的子进程：只能等它自己结束，不能被暂停打断。
                        let running_permit = work_gate.acquire_owned().await.unwrap();
                        finished.fetch_add(1, Ordering::SeqCst);
                        started.fetch_sub(1, Ordering::SeqCst);
                        // forget 让一张放行牌只放行一个任务，否则信号量会被反复回收。
                        running_permit.forget();
                        drop(permit);
                    }));
                }
                for task in running {
                    task.await.unwrap();
                }
            })
        };

        // 并发数就是上限：正好 3 个开始，不多不少。
        assert!(wait_until(|| started.load(Ordering::SeqCst) == 3).await);
        scheduler.pause();
        assert!(scheduler.is_paused());
        assert_eq!(scheduler.state(), CompressionState::Paused);

        // 放掉一个在跑的任务，腾出名额 —— 暂停时不能拿它补位。
        work_gate.add_permits(1);
        assert!(wait_until(|| finished.load(Ordering::SeqCst) == 1).await);
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert_eq!(started.load(Ordering::SeqCst), 2, "暂停后仍在启动新任务");

        scheduler.resume();
        assert_eq!(scheduler.state(), CompressionState::Running);
        work_gate.add_permits(20);
        driver.await.unwrap();
        assert_eq!(finished.load(Ordering::SeqCst), 10, "继续后必须把整批跑完");
        assert_eq!(peak.load(Ordering::SeqCst), 3, "任何时刻都不该超过 3 份并行");
        scheduler.end_batch();
        assert_eq!(scheduler.state(), CompressionState::Idle);
        assert_eq!(scheduler.active(), 0);
    }

    #[tokio::test]
    async fn a_new_batch_never_inherits_the_previous_pause() {
        let scheduler = CompressionScheduler::new(3);
        scheduler.begin_batch();
        scheduler.pause();
        assert_eq!(scheduler.state(), CompressionState::Paused);
        scheduler.begin_batch();
        assert_eq!(scheduler.state(), CompressionState::Running);
        scheduler.end_batch();
        assert_eq!(scheduler.state(), CompressionState::Idle);
    }

    /// 「停止」= 闸门对还没开始的文件永久关闭，已经在跑的继续跑完（绝不 kill）。
    ///
    /// 逐条钉住四件事：状态是 stopping、等待者立刻退出、已在跑的照常完成、
    /// 停止后即使有人调 `resume()` 也不会把排队的文件放回来。
    #[tokio::test]
    async fn stopping_the_batch_lets_running_jobs_finish_and_closes_the_gate_for_good() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(2));
        scheduler.begin_batch();
        // 先占满两个名额 —— 这两个就是"正在压缩的图片"。
        let first = scheduler.acquire_permit().await;
        let second = scheduler.acquire_permit().await;
        assert_eq!(scheduler.active(), 2);

        let waiter = {
            let scheduler = scheduler.clone();
            tokio::spawn(async move { outcome_name(scheduler.acquire(|| false).await) })
        };
        tokio::task::yield_now().await;
        assert!(!waiter.is_finished(), "名额满了，第三个文件就该在闸门上等");

        scheduler.stop();
        assert_eq!(scheduler.state(), CompressionState::Stopping);
        assert_eq!(
            waiter.await.unwrap(),
            "stopped",
            "停止后等待中的文件必须自己退出，不能等到名额空出来再开工"
        );
        assert_eq!(scheduler.active(), 2, "已经在跑的两个不许被抢走名额");
        // 必须报 Stopped 而不是 Cancelled：这个文件该留在队列里等下一轮。
        assert_eq!(
            outcome_name(scheduler.acquire(|| false).await),
            "stopped",
            "停止后闸门对后来者是关的"
        );

        // 关键：停止不是暂停。即使有人误调 resume()，批次的闸门也不该重新打开。
        scheduler.resume();
        assert_eq!(
            outcome_name(scheduler.acquire(|| false).await),
            "stopped",
            "停止不可逆：resume() 不许把停止的批次放回来"
        );
        assert_eq!(scheduler.state(), CompressionState::Stopping);

        // 在跑的两个收尾（permit 归还）之后，批次照样收尾回 idle。
        drop(first);
        drop(second);
        scheduler.end_batch();
        assert_eq!(scheduler.state(), CompressionState::Idle);
    }

    /// 暂停中按停止：等待者必须能看见"整批已停"并退出，而不是继续堵在关着的闸门上。
    #[tokio::test]
    async fn stopping_while_paused_finishes_the_batch_instead_of_waiting_for_resume() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(1));
        scheduler.begin_batch();
        let running = scheduler.acquire_permit().await;
        scheduler.pause();
        assert_eq!(scheduler.state(), CompressionState::Paused);

        let waiter = {
            let scheduler = scheduler.clone();
            tokio::spawn(async move { outcome_name(scheduler.acquire(|| false).await) })
        };
        tokio::task::yield_now().await;
        assert!(!waiter.is_finished(), "暂停时等待者必须被拦住");

        scheduler.stop();
        assert_eq!(scheduler.state(), CompressionState::Stopping);
        assert_eq!(
            waiter.await.unwrap(),
            "stopped",
            "暂停中停止：等待者必须退出（判断顺序是 取消 → 停止 → 暂停，不能反过来）"
        );
        assert_eq!(scheduler.active(), 1, "在跑的那个照旧跑完");
        drop(running);
        scheduler.end_batch();
        assert_eq!(scheduler.state(), CompressionState::Idle);
    }

    /// 停止的标志不许泄漏到下一批：批次起止都要把它清干净。
    #[test]
    fn stopping_does_not_leak_into_the_next_batch() {
        let scheduler = CompressionScheduler::new(2);
        scheduler.begin_batch();
        scheduler.stop();
        assert_eq!(scheduler.state(), CompressionState::Stopping);
        scheduler.end_batch();
        assert_eq!(scheduler.state(), CompressionState::Idle);
        scheduler.begin_batch();
        assert_eq!(scheduler.state(), CompressionState::Running);
        assert!(!scheduler.is_stopping(), "新一批必须从「未停止」开始");
    }

    /// 「停止」与「取消」必须给出两种结局：前者是"这一轮没轮到"，后者是"这个文件出局"。
    ///
    /// 混成一个 `None` 时，`compress_batch` 只能统一报 cancelled，于是"停止后 70 张图
    /// 全变成已跳过、再也没法继续"——那是把批次级的动作记成了文件级的终态。
    #[tokio::test]
    async fn stopping_defers_a_waiting_file_while_removing_it_cancels_it() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(1));
        let queue = std::sync::Arc::new(Mutex::new(HashSet::new()));
        scheduler.begin_batch();
        let held = scheduler.acquire_permit().await;

        // ① 停止：等待者拿到的必须是 Stopped（它该留在队列里等下一轮）。
        let deferred = {
            let scheduler = scheduler.clone();
            tokio::spawn(async move { outcome_name(scheduler.acquire(|| false).await) })
        };
        tokio::task::yield_now().await;
        assert!(!deferred.is_finished(), "名额占满时它就该在闸门上等");
        scheduler.stop();
        assert_eq!(
            deferred.await.unwrap(),
            "stopped",
            "停止只结束这一轮，文件不算被取消"
        );

        // ② 取消：新一批里把文件移出队列，拿到的必须是 Cancelled。
        scheduler.end_batch();
        scheduler.begin_batch();
        queue.lock().unwrap().insert("/gone.png".to_string());
        assert_eq!(
            outcome_name(
                scheduler
                    .acquire(|| take_cancelled(&queue, "/gone.png"))
                    .await
            ),
            "cancelled",
            "用户移出队列的文件必须报 Cancelled，而不是 Stopped"
        );

        // ③ 两者同时成立时「取消」优先：用户点过 × 的文件本来就不该再压。
        queue.lock().unwrap().insert("/both.png".to_string());
        scheduler.stop();
        assert_eq!(
            outcome_name(
                scheduler
                    .acquire(|| take_cancelled(&queue, "/both.png"))
                    .await
            ),
            "cancelled",
            "判断顺序是 取消 → 停止"
        );
        drop(held);
        scheduler.end_batch();
    }

    /// 进度状态的字面量就是前端的判据（app.js 的 progressHandler）：改一个字母
    /// 前端就会把「跑完了」当成未知状态，界面停在转圈上。
    #[test]
    fn the_progress_status_wire_format_is_what_the_frontend_matches() {
        for (status, wire) in [
            (ProgressStatus::Queued, "\"queued\""),
            (ProgressStatus::Starting, "\"starting\""),
            (ProgressStatus::Completed, "\"completed\""),
            (ProgressStatus::Failed, "\"failed\""),
            (ProgressStatus::Cancelled, "\"cancelled\""),
            (ProgressStatus::Deferred, "\"deferred\""),
        ] {
            assert_eq!(serde_json::to_string(&status).unwrap(), wire);
        }
    }

    #[test]
    fn progress_events_echo_the_queue_generation() {
        let payload = ProgressPayload {
            session_id: "session-7".into(),
            queue_revision: 42,
            file: "/image.png".into(),
            status: ProgressStatus::Deferred,
            timestamp: event_timestamp(),
            session_total: 1,
            session_processed: 0,
            result: None,
        };
        let wire = serde_json::to_value(payload).unwrap();
        assert_eq!(wire["sessionId"], "session-7");
        assert_eq!(wire["queueRevision"], 42);
        assert_eq!(wire["status"], "deferred");
        assert!(wire["timestamp"].as_u64().unwrap() > 0);
    }

    /// 前端认的是四个字面量（app.js 的 COMPRESSION_STATES 与事件载荷）：序列化结果必须
    /// 逐字一致 —— 改变体名就得同时改前端，否则 UI 会静默不认后端播报的状态。
    #[test]
    fn the_wire_format_is_the_four_state_strings_the_frontend_knows() {
        for (state, wire) in [
            (CompressionState::Idle, "\"idle\""),
            (CompressionState::Running, "\"running\""),
            (CompressionState::Paused, "\"paused\""),
            (CompressionState::Stopping, "\"stopping\""),
        ] {
            assert_eq!(serde_json::to_string(&state).unwrap(), wire);
        }
    }

    /// 暂停中取消一个还没开始的文件：它自己退出等待，但闸门**保持关闭**。
    ///
    /// 老实现在取消路径上调的是 `resume()`，于是"暂停中从队列里移走一张图"
    /// 会让其余排队的文件全部悄悄开跑，而 UI 上仍写着「暂停中…」。
    #[tokio::test]
    async fn cancelling_a_paused_file_leaves_the_rest_still_paused() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(2));
        let queue = std::sync::Arc::new(Mutex::new(HashSet::new()));
        queue.lock().unwrap().insert("/gone.png".to_string());
        scheduler.begin_batch();
        scheduler.pause();

        let leaving = {
            let scheduler = scheduler.clone();
            let queue = queue.clone();
            tokio::spawn(async move {
                outcome_name(
                    scheduler
                        .acquire(|| take_cancelled(&queue, "/gone.png"))
                        .await,
                )
            })
        };
        let staying = {
            let scheduler = scheduler.clone();
            tokio::spawn(async move { scheduler.acquire_permit().await })
        };

        // 必须是 Cancelled 而不是 Stopped：用户移出队列的文件本轮到此为止。
        let exited = matches!(
            tokio::time::timeout(Duration::from_millis(500), leaving).await,
            Ok(Ok(name)) if name == "cancelled"
        );
        assert!(
            exited,
            "被取消的文件必须立刻退出等待，而不是拿着名额去压缩"
        );
        assert!(scheduler.is_paused(), "取消绝不能顺手解除暂停");
        assert_eq!(scheduler.active(), 0, "退出等待必须归还预算");
        assert!(!staying.is_finished(), "还在排队的文件必须继续被闸门拦住");

        // 唤醒只叫醒不开门；真正开门的仍然只有用户点「继续」和批次收尾。
        scheduler.wake_waiters();
        tokio::task::yield_now().await;
        assert!(!staying.is_finished(), "wake_waiters 只叫醒等待者，不放行");
        assert!(scheduler.is_paused());

        scheduler.resume();
        let permit = staying.await.unwrap();
        assert_eq!(scheduler.active(), 1);
        drop(permit);
    }

    /// 暂停中清空队列 / 取消全部 / 退出：批次收尾必须唤醒还堵在闸门上的 worker。
    #[tokio::test]
    async fn ending_a_batch_wakes_workers_still_waiting_on_the_gate() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(1));
        scheduler.begin_batch();
        // 先占满唯一的名额，下一个任务就会堵在闸门上。
        let held = scheduler.acquire_permit().await;
        scheduler.pause();

        let waiter = {
            let scheduler = scheduler.clone();
            tokio::spawn(async move {
                let permit = scheduler.acquire_permit().await;
                drop(permit);
                true
            })
        };
        tokio::task::yield_now().await;
        assert!(!waiter.is_finished(), "暂停时闸门必须拦住新任务");

        scheduler.end_batch();
        drop(held);
        assert!(waiter.await.unwrap(), "收尾后闸门必须放行");
    }

    /// 8 → 2：已在跑的 8 份必须被放过，只是不再启动新的（绝不"强杀 6 个"）。
    #[tokio::test]
    async fn lowering_the_limit_never_recovers_permits_from_running_jobs() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(8));
        scheduler.begin_batch();
        let mut permits = Vec::new();
        for _ in 0..8 {
            permits.push(scheduler.acquire_permit().await);
        }
        assert_eq!(scheduler.active(), 8);

        scheduler.set_max_parallelism(2);
        assert_eq!(scheduler.max_parallelism(), 2);
        assert_eq!(scheduler.active(), 8, "降上限不能把已在跑的名额抢回来");
        assert!(scheduler.try_acquire().is_none(), "超额期间不能再启动新任务");

        // 交还到只剩 2 份之前，闸门一直是关的；到了 2 份之后仍然不能再多。
        for permit in permits.drain(..6) {
            drop(permit);
            assert!(scheduler.try_acquire().is_none(), "active 仍 >= 新上限时不能放行");
        }
        assert_eq!(scheduler.active(), 2);
        drop(permits.pop().unwrap());
        assert!(scheduler.try_acquire().is_some(), "回落到上限以下后必须能继续开工");
    }

    /// 2 → 6：提高上限要立刻唤醒等待者，而不是等下一次超时轮询。
    #[tokio::test]
    async fn raising_the_limit_wakes_waiting_workers_immediately() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(2));
        scheduler.begin_batch();
        let held = vec![scheduler.acquire_permit().await, scheduler.acquire_permit().await];

        let waiters: Vec<_> = (0..4)
            .map(|_| {
                let scheduler = scheduler.clone();
                tokio::spawn(async move {
                    let permit = scheduler.acquire_permit().await;
                    drop(permit);
                })
            })
            .collect();
        tokio::task::yield_now().await;
        assert_eq!(scheduler.active(), 2, "2 个名额时不该有第 3 个开工");

        scheduler.set_max_parallelism(6);
        for waiter in waiters {
            waiter.await.unwrap();
        }
        assert_eq!(scheduler.active(), 2, "等待者放行后又要归位");
        drop(held);
        assert_eq!(scheduler.active(), 0);
    }

    #[tokio::test]
    async fn one_permit_serialises_the_whole_batch() {
        let scheduler = std::sync::Arc::new(CompressionScheduler::new(1));
        scheduler.begin_batch();
        let held = scheduler.acquire_permit().await;
        assert!(scheduler.try_acquire().is_none(), "limit=1 时任何时刻只能有一个任务");
        drop(held);
        assert!(scheduler.try_acquire().is_some());
    }

    #[test]
    fn a_zero_limit_still_runs_one_job() {
        // 上限 0 会让闸门永远关闭，比"慢"更糟，所以夹到 1。
        let scheduler = CompressionScheduler::new(0);
        assert_eq!(scheduler.max_parallelism(), MIN_PARALLELISM);
        scheduler.set_max_parallelism(0);
        assert_eq!(scheduler.max_parallelism(), MIN_PARALLELISM);
    }

    #[test]
    fn collect_image_files_deduplicates_overlapping_inputs_in_stable_order() {
        let temp = tempfile::tempdir().unwrap();
        let nested = temp.path().join("nested");
        fs::create_dir_all(&nested).unwrap();
        let first = temp.path().join("first.png");
        let second = nested.join("second.JPG");
        fs::write(&first, b"first").unwrap();
        fs::write(&second, b"second").unwrap();

        let files = collect_image_files(&[
            first.to_string_lossy().into_owned(),
            temp.path().to_string_lossy().into_owned(),
            nested.to_string_lossy().into_owned(),
        ]);

        assert_eq!(files.len(), 2);
        assert_eq!(files[0], first.canonicalize().unwrap().to_string_lossy());
        assert_eq!(files[1], second.canonicalize().unwrap().to_string_lossy());
    }

    #[test]
    fn folder_output_keeps_the_selected_root_when_queue_is_expanded() {
        let temp = tempfile::tempdir().unwrap();
        let source_root = temp.path().join("source");
        let nested = source_root.join("nested");
        let output_root = temp.path().join("output");
        fs::create_dir_all(&nested).unwrap();
        let input = nested.join("photo.png");
        fs::write(&input, b"original").unwrap();

        let engine_result = EngineResult {
            success: true,
            compressed: b"small".to_vec(),
            out_type: "png".into(),
            algorithm: "test".into(),
            error: None,
        };
        let mut result = build_result(&input.to_string_lossy(), &engine_result);
        let options = CompressOptions {
            output_mode: "folder".into(),
            output_dir: Some(output_root.to_string_lossy().into_owned()),
            source_roots: vec![source_root.to_string_lossy().into_owned()],
            ..Default::default()
        };

        write_output_file(
            &mut result,
            &input,
            &engine_result.compressed,
            &[input.to_string_lossy().into_owned()],
            &options,
            &history_in(temp.path()),
            &transactions_in(temp.path()),
            3,
        )
        .expect("目录模式的输出必须落进已选根目录");

        assert_eq!(
            result.output_path.as_deref(),
            Some(output_root.join("nested/photo.png").to_string_lossy().as_ref())
        );
    }

    /// 目录/后缀模式只记录历史，不留原图备份；备份只在 replace 模式产生。
    #[test]
    fn only_replace_mode_keeps_an_original_backup() {
        let temp = tempfile::tempdir().unwrap();
        let history = history_in(temp.path());
        let transactions = transactions_in(temp.path());
        let engine_result = EngineResult {
            success: true,
            compressed: b"small".to_vec(),
            out_type: "png".into(),
            algorithm: "test".into(),
            error: None,
        };

        for (mode, suffix) in [("suffix", "_c"), ("folder", "_f")] {
            let input = temp.path().join(format!("{}-in.png", mode));
            fs::write(&input, b"original-bytes-longer").unwrap();
            let mut result = build_result(&input.to_string_lossy(), &engine_result);
            let options = CompressOptions {
                output_mode: mode.into(),
                output_suffix: suffix.into(),
                output_dir: Some(temp.path().join("out").to_string_lossy().into_owned()),
                ..Default::default()
            };
            write_output_file(
                &mut result,
                &input,
                &engine_result.compressed,
                &[input.to_string_lossy().into_owned()],
                &options,
                &history,
                &transactions,
                3,
            )
            .expect("输出写入成功必须产生历史");
            assert_eq!(result.backup_path, None);
            let entry = history
                .list()
                .into_iter()
                .next()
                .expect("这次压缩必须留下一条历史");
            assert_eq!(entry.output_mode, mode);
            assert_eq!(entry.backup_path, None);
            // 非覆盖模式不动用户原图，也就不需要事务凭证。
            assert!(!transactions.has_pending());
        }

        let input = temp.path().join("replace-in.png");
        fs::write(&input, b"original-bytes-longer").unwrap();
        let mut result = build_result(&input.to_string_lossy(), &engine_result);
        let options = CompressOptions {
            output_mode: "replace".into(),
            ..Default::default()
        };
        write_output_file(
            &mut result,
            &input,
            &engine_result.compressed,
            &[input.to_string_lossy().into_owned()],
            &options,
            &history,
            &transactions,
            3,
        )
        .expect("覆盖模式必须产出历史");
        let entry = history.list().into_iter().next().unwrap();
        assert!(PathBuf::from(entry.backup_path.unwrap()).exists());
        assert_eq!(fs::read(&input).unwrap(), b"small");
        // 提交完成 = 事务凭证必须收走，否则下次启动会白回滚一次。
        assert!(!transactions.has_pending());
    }

    fn history_in(dir: &Path) -> HistoryStore {
        HistoryStore::new(dir.join("history")).unwrap()
    }

    fn transactions_in(dir: &Path) -> TransactionStore {
        TransactionStore::new(
            dir.join("history")
                .join(output_transaction::TRANSACTIONS_DIR),
        )
    }

    /// 历史写不成 = 这次覆盖不能算数：原图必须回到用户手上，事务凭证必须收走。
    #[test]
    fn a_history_write_failure_rolls_the_overwrite_back_to_the_original() {
        let temp = tempfile::tempdir().unwrap();
        let history = history_in(temp.path());
        let transactions = transactions_in(temp.path());
        let input = temp.path().join("photo.png");
        fs::write(&input, b"true-original-bytes").unwrap();

        // 先把内存快照建立起来：否则下面的堵塞点会被"损坏现场隔离"整目录挪走，
        // 测的就不是写入失败而是损坏恢复了（那条另有测试覆盖）。
        assert!(history.list().is_empty());
        // 注入失败：history.json 的位置放一个**非空**目录，rename 必撞 EISDIR
        // （空目录会被 macOS 直接替换掉，所以必须留一个占位子目录）。
        let blocked = temp.path().join("history").join("history.json");
        fs::create_dir_all(blocked.join("stale")).unwrap();

        let engine_result = EngineResult {
            success: true,
            compressed: b"small".to_vec(),
            out_type: "png".into(),
            algorithm: "test".into(),
            error: None,
        };
        let mut result = build_result(&input.to_string_lossy(), &engine_result);
        let options = CompressOptions {
            output_mode: "replace".into(),
            ..Default::default()
        };
        let error = write_output_file(
            &mut result,
            &input,
            &engine_result.compressed,
            &[input.to_string_lossy().into_owned()],
            &options,
            &history,
            &transactions,
            3,
        )
        .expect_err("历史落盘失败必须报给调用方");
        assert!(matches!(error, OutputWriteError::HistoryWriteFailed));
        // 覆盖撤销：源文件回到真正原图，UI 侧不能再报"输出在 X"。
        assert_eq!(fs::read(&input).unwrap(), b"true-original-bytes");
        assert_eq!(result.output_path, None);
        assert_eq!(result.backup_path, None);
        // 凭证已销账，下次启动不会再把这次当成中断事务。
        assert!(!transactions.has_pending());
        // 备份**不删**：它成了无人引用的孤儿，留给退出清理，绝不在这条路径上丢掉原图副本。
        let backups = temp.path().join("history").join("backups");
        assert!(
            fs::read_dir(&backups)
                .map(|mut iter| iter.next().is_some())
                .unwrap_or(false),
            "回滚之后原图副本必须还在磁盘上"
        );
    }

    #[test]
    fn system_conversion_never_overwrites_an_existing_target() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("photo.png");
        fs::write(&input, b"png").unwrap();
        assert_eq!(
            available_system_conversion_path(&input, "jpg"),
            temp.path().join("photo.jpg")
        );

        fs::write(temp.path().join("photo.jpg"), b"existing").unwrap();
        assert_eq!(
            available_system_conversion_path(&input, "jpg"),
            temp.path().join("photo_converted.jpg")
        );

        fs::write(temp.path().join("photo_converted.jpg"), b"existing").unwrap();
        assert_eq!(
            available_system_conversion_path(&input, "jpg"),
            temp.path().join("photo_converted_2.jpg")
        );
    }

    #[test]
    fn custom_suffix_is_used_for_suffix_output() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("photo.png");
        fs::write(&input, b"original").unwrap();

        let engine_result = EngineResult {
            success: true,
            compressed: b"small".to_vec(),
            out_type: "png".into(),
            algorithm: "test".into(),
            error: None,
        };
        let mut result = build_result(&input.to_string_lossy(), &engine_result);
        let options = CompressOptions {
            output_mode: "suffix".into(),
            output_suffix: "_small".into(),
            ..Default::default()
        };

        write_output_file(
            &mut result,
            &input,
            &engine_result.compressed,
            &[input.to_string_lossy().into_owned()],
            &options,
            &history_in(temp.path()),
            &transactions_in(temp.path()),
            3,
        )
        .expect("后缀模式的输出必须落盘");

        assert_eq!(
            result.output_path.as_deref(),
            Some(temp.path().join("photo_small.png").to_string_lossy().as_ref())
        );
    }
}
