// OctoShrink - 持久化的压缩历史与原图备份。
//
// 与旧的 `$TMPDIR/octoshrink-backups` 模型的根本区别：清理只针对 OctoShrink 自己
// 写的副本 —— 用户的原图和压缩结果永远不在删除范围内。
//
// 清理只有一个时机：**正常退出**。启动时一律不动备份。
//
// `retentionDays == 0`（「不保留」，默认档）：本次运行的记录连同原图备份在退出时一起
// 走；覆盖原文件前照写不误（没有备份就不许覆盖）。上次异常退出遗留的那批多给一次机会。
// `retentionDays > 0`：退出时清掉超出天数窗口的记录和只被它们引用的备份。
//
// 为什么是退出而不是"下次启动"：崩溃现场那份备份可能是被覆盖原图唯一还活着的副本，
// 而"下次启动就删"恰好会在用户最可能需要它的时候把它抹掉。
//
// 读取是**严格**的：`history.json` 存在但解析不出来时，绝不退化成"空历史"。
// 空历史会让所有备份看起来无人引用，进而被清理掉 —— 那是拿用户原图换一个不报错。
// 损坏时改名留档、按 `backup-meta.json` 重建恢复入口，并且本次启动禁止任何备份清理。

use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::engine::CompressResult;
use crate::sandbox_access::FileAccess;

pub const HISTORY_DIR: &str = "history";
pub const BACKUPS_DIR: &str = "backups";
const HISTORY_FILE: &str = "history.json";
const META_FILE: &str = "backup-meta.json";
/// 上次运行是否走完了退出清理。清理只有一个时机，所以得留个记号区分"上次崩了"。
const CLEAN_EXIT_FILE: &str = "clean-exit";
pub const DAY_MILLIS: i64 = 86_400_000;
/// mtime 比文件大小更容易被无关操作扰动；容忍 2 秒以内的写入抖动。
const MTIME_TOLERANCE_MILLIS: i64 = 2_000;
/// 历史条数的硬上限：清理逻辑再怎么出错，也不能让 history.json 无限膨胀。
/// 淘汰的是最老的记录，且只连带删它自己那份备份。
pub const MAX_HISTORY_ENTRIES: usize = 10_000;
/// `history.json` 损坏时从备份重建出来的条目用的算法标记：它不是一次真实压缩。
pub const RECOVERY_ALGORITHM: &str = "recovery";

pub fn file_size(path: &Path) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

pub fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn now_nanos() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0)
}

pub fn file_mtime_millis(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .ok()
}

/// 截断重写会让崩溃留下半个 history.json；先写 tmp、fsync、再 rename。
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension(format!("tmp-{}", now_nanos()));
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        file.sync_all().ok();
    }
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        e.to_string()
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HistoryStatus {
    /// 压缩结果仍在，原图备份可恢复
    Compressed,
    /// 已恢复到真正原图
    Restored,
    /// 压缩结果或原图位置已不存在（外部改名/删除）
    Missing,
    /// `history.json` 损坏后从备份目录的 `backup-meta.json` 重建出来的条目：
    /// 备份确实还在，但这次压缩的明细（算法、节省率）已经无从得知。
    RecoveryAvailable,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub created_at: i64,
    pub expires_at: i64,
    pub source_path: String,
    pub output_path: Option<String>,
    pub file_name: String,
    pub output_mode: String,
    pub original_size: u64,
    pub compressed_size: u64,
    pub savings: f64,
    pub out_type: String,
    pub algorithm: String,
    /// 只有 replace 模式才有：覆盖原文件前保存的那份真正原图。
    pub backup_path: Option<String>,
    pub status: HistoryStatus,
    pub restored_at: Option<i64>,
    /// 压缩结果写入完成时的 mtime，用于检测压缩后被外部编辑器改过的文件。
    pub output_modified_at: Option<i64>,
    /// 派生字段：读取时刷新，不落库使用。
    #[serde(default)]
    pub source_exists: bool,
    #[serde(default)]
    pub backup_exists: bool,
    /// 压缩结果此刻还在不在：历史页的「另存为 / 对比 / 删除这次压缩结果」都靠它决定，
    /// 用户手动删过产物后这些按钮就不该出现。
    #[serde(default)]
    pub output_exists: bool,
}

static ENTRY_SEQUENCE: AtomicU32 = AtomicU32::new(0);

impl HistoryEntry {
    /// 事务id 必须在覆盖开始之前就定下来：`ReplaceTransaction` 和历史记录靠它对齐，
    /// 启动时"历史里有没有这个 id"就是这次覆盖是否完整提交的唯一判据。
    pub fn new_id(source: &Path) -> String {
        let sequence = ENTRY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        format!(
            "{}-{}-{}",
            now_nanos(),
            sequence,
            HistoryStore::backup_key(source)
        )
    }

    /// 一次成功产出对应一条历史。`expires_at` 只用于展示：退出清理按 `created_at`
    /// 判定，所以同一张图重压多次时，备份的存活期顺延到最后一次相关压缩之后。
    pub fn record(
        source: &Path,
        result: &CompressResult,
        output: &Path,
        backup: Option<&Path>,
        retention_days: u32,
    ) -> Self {
        Self::record_with_id(
            Self::new_id(source),
            source,
            result,
            output,
            backup,
            retention_days,
        )
    }

    pub fn record_with_id(
        id: String,
        source: &Path,
        result: &CompressResult,
        output: &Path,
        backup: Option<&Path>,
        retention_days: u32,
    ) -> Self {
        let created_at = now_millis();
        Self {
            id,
            created_at,
            // 「不保留」没有"几天后到期"这回事：这份备份的寿命就是这次运行。
            expires_at: if retention_days == crate::app_settings::KEEP_UNTIL_QUIT {
                created_at
            } else {
                created_at + retention_days.max(1) as i64 * DAY_MILLIS
            },
            source_path: canonical_path(source),
            output_path: Some(output.to_string_lossy().into_owned()),
            file_name: source
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "image".into()),
            output_mode: result
                .output_mode
                .clone()
                .unwrap_or_else(|| "replace".into()),
            original_size: result.original_size,
            compressed_size: result.compressed_size,
            savings: result.savings,
            out_type: result.out_type.clone(),
            algorithm: result.algorithm.clone(),
            backup_path: backup.map(|path| path.to_string_lossy().into_owned()),
            status: HistoryStatus::Compressed,
            restored_at: None,
            output_modified_at: file_mtime_millis(output),
            source_exists: true,
            backup_exists: backup.is_some(),
            output_exists: output.exists(),
        }
    }
}

/// 每份原图备份的来历。`history.json` 一旦损坏，这份元数据就是重建恢复入口的
/// 唯一依据 —— 所以 version、大小、扩展名都必须写全，不能只留路径。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackupMeta {
    /// 1 = 只有 sourcePath/createdAt（老版本）；2 = 带大小、mtime、扩展名。
    #[serde(default = "meta_version_v1")]
    version: u32,
    source_path: String,
    created_at: i64,
    #[serde(default)]
    original_size: u64,
    #[serde(default)]
    original_modified_at: Option<i64>,
    #[serde(default)]
    original_extension: String,
}

fn meta_version_v1() -> u32 {
    1
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupReport {
    pub removed_entries: usize,
    pub removed_backups: usize,
    pub kept_backups: usize,
    /// 本次启动从备份目录重建出的恢复入口数。
    pub recovered_entries: usize,
    /// 损坏的 `history.json` 被改名留下的现场（绝对路径）。
    pub quarantined_to: Option<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug)]
pub enum RestoreError {
    NotFound,
    /// 没有可恢复的备份（后缀/目录模式，原图本来就没被覆盖）
    NotRestorable,
    /// 原图确实被覆盖过，但那份备份已经不在了（「不保留」档退出时清理过）
    BackupGone,
    /// 压缩之后目标文件被外部修改过，需要用户确认
    Conflict,
    Io(String),
    /// 沙盒下拿不到（也续不上）目标位置的访问授权
    AccessDenied,
}

impl RestoreError {
    pub fn message(&self) -> &'static str {
        match self {
            RestoreError::NotFound => "找不到这条历史记录",
            RestoreError::NotRestorable => "原图未被覆盖，无需恢复",
            // 「不保留」档退出后就会走到这里：原图确实被覆盖过，只是备份没了。
            RestoreError::BackupGone => "原图备份已清理，无法恢复",
            RestoreError::Conflict => "这个文件在压缩后又被修改过",
            RestoreError::Io(_) => "恢复失败",
            RestoreError::AccessDenied => "没有该文件夹的访问权限，请重新授权",
        }
    }
}

/// 内存里的历史快照 + 可信度。落盘永远是整份覆盖（写 tmp → fsync → rename），
/// 所以"缓存与磁盘不一致"只可能发生在写失败之后 —— 那时缓存不更新，
/// 内存反映的仍是磁盘上那份可信内容。
#[derive(Debug, Default)]
struct Cache {
    entries: Vec<HistoryEntry>,
    loaded: bool,
    /// `history.json` 存在但读不出可信内容（半个文件 / 无法读）：
    /// 引用关系已经不可信，本次启动**禁止 sweep 备份**。
    untrusted: bool,
}

/// 进程内共享的历史存储。所有读-改-写都在同一把锁里完成，
/// 3 个并发 worker 同时追加不会互相覆盖。
///
/// 启动时读一次 `history.json` 进内存，之后每次追加只覆盖落盘，
/// 不再"读整份 → 解析整份 → 追加 → 序列化整份"。
pub struct HistoryStore {
    root: PathBuf,
    cache: Mutex<Cache>,
    /// 备份目录的读-改-写单独一把锁：与 `cache` 无嵌套，不会互锁。
    backup_lock: Mutex<()>,
    /// 历史是"读全量 → 改 → 写全量"，所以读改写的整个过程必须独占：
    /// 否则两个并发的压缩各自拿到同一份快照，后写的那份把前一份整条抹掉。
    commit_lock: Mutex<()>,
    /// 首次加载时对损坏现场做的处理，留给启动流程报告（只报一次）。
    pending_report: Mutex<Option<CleanupReport>>,
}

impl HistoryStore {
    pub fn new(root: PathBuf) -> Result<Self, String> {
        fs::create_dir_all(root.join(BACKUPS_DIR)).map_err(|e| e.to_string())?;
        Ok(Self {
            root,
            cache: Mutex::new(Cache::default()),
            backup_lock: Mutex::new(()),
            commit_lock: Mutex::new(()),
            pending_report: Mutex::new(None),
        })
    }

    fn history_path(&self) -> PathBuf {
        self.root.join(HISTORY_FILE)
    }

    fn backups_dir(&self) -> PathBuf {
        self.root.join(BACKUPS_DIR)
    }

    // ─── 读写 ────────────────────────────────────────────────────

    /// 严格读取：**"没有历史"和"历史读不出来"是两回事**。
    ///
    /// 老实现 `serde_json::from_str(&raw).unwrap_or_default()` 把半个 JSON 当成空历史，
    /// 于是下一次清理看到"没有任何记录引用这些备份"，把用户所有原图备份全删了。
    /// Err 只会来自"文件存在但内容不可信"，调用方据此关掉清理。
    fn load_from_disk(&self) -> Result<Vec<HistoryEntry>, String> {
        let raw = match fs::read_to_string(self.history_path()) {
            Ok(raw) => raw,
            // 文件不存在 = 真的没有历史，这是正常状态。
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(format!("无法读取历史记录: {error}")),
        };
        if raw.trim().is_empty() {
            return Ok(Vec::new());
        }
        serde_json::from_str(&raw).map_err(|error| format!("历史记录已损坏: {error}"))
    }

    /// 取内存快照（首次调用时落盘加载）。调用方必须已持有 `cache` 锁。
    fn ensure_loaded(&self, cache: &mut Cache) {
        if cache.loaded {
            return;
        }
        cache.loaded = true;
        match self.load_from_disk() {
            Ok(entries) => cache.entries = entries,
            Err(error) => {
                cache.untrusted = true;
                let mut report = CleanupReport::default();
                report.warnings.push(error);
                // 先保住现场：改名留档，绝不能让后续清理把这份文件覆盖成 []。
                match self.quarantine_history_file() {
                    Ok(path) => report.quarantined_to = Some(path.to_string_lossy().into_owned()),
                    Err(eject) => report.warnings.push(eject),
                }
                // 备份还在，就还能恢复：按 backup-meta 重建恢复入口。
                let rebuilt = self.rebuild_from_backups();
                report.recovered_entries = rebuilt.len();
                cache.entries = rebuilt;
                // 重建出来的这份必须落盘，否则重启又看到空历史。
                if let Err(write_error) = self.write_raw(&cache.entries) {
                    report.warnings.push(write_error);
                }
                *self.pending_report.lock().unwrap() = Some(report);
            }
        }
    }

    fn quarantine_history_file(&self) -> Result<PathBuf, String> {
        let path = self.history_path();
        let stamped = self
            .root
            .join(format!("history.corrupt-{}.json", now_millis()));
        fs::rename(&path, &stamped).map_err(|e| e.to_string())?;
        Ok(stamped)
    }

    fn write_raw(&self, entries: &[HistoryEntry]) -> Result<(), String> {
        let json = serde_json::to_string_pretty(entries).map_err(|e| e.to_string())?;
        write_atomic(&self.history_path(), json.as_bytes())
    }

    /// 覆盖磁盘写入 + 内存快照：写失败时内存保持磁盘上那份可信内容。
    fn store(&self, entries: Vec<HistoryEntry>) -> Result<(), String> {
        self.write_raw(&entries)?;
        let mut cache = self.cache.lock().unwrap();
        self.ensure_loaded(&mut cache);
        cache.entries = entries;
        Ok(())
    }

    /// 本次启动是否禁止清理无人引用的备份。
    pub fn cleanup_is_locked(&self) -> bool {
        let mut cache = self.cache.lock().unwrap();
        self.ensure_loaded(&mut cache);
        cache.untrusted
    }

    /// 取出损坏现场的处理结果（只有一份，报告完就没了）。
    /// 这里主动触发一次加载：启动流程可能在任何历史读取之前就调它。
    pub fn take_startup_report(&self) -> Option<CleanupReport> {
        {
            let mut cache = self.cache.lock().unwrap();
            self.ensure_loaded(&mut cache);
        }
        self.pending_report.lock().unwrap().take()
    }

    fn decorate(&self, mut entries: Vec<HistoryEntry>) -> Vec<HistoryEntry> {
        for entry in &mut entries {
            entry.source_exists = Path::new(&entry.source_path).exists();
            entry.backup_exists = entry
                .backup_path
                .as_ref()
                .map(|p| Path::new(p).exists())
                .unwrap_or(false);
            entry.output_exists = entry
                .output_path
                .as_ref()
                .map(|p| Path::new(p).exists())
                .unwrap_or(false);
            if !entry.source_exists && entry.status == HistoryStatus::Compressed {
                entry.status = HistoryStatus::Missing;
            }
        }
        entries
    }

    fn snapshot(&self) -> Vec<HistoryEntry> {
        let mut cache = self.cache.lock().unwrap();
        self.ensure_loaded(&mut cache);
        cache.entries.clone()
    }

    /// 最新在前，历史页直接渲染。
    pub fn list(&self) -> Vec<HistoryEntry> {
        let mut entries = self.snapshot();
        entries.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| b.id.cmp(&a.id)));
        self.decorate(entries)
    }

    pub fn find(&self, history_id: &str) -> Option<HistoryEntry> {
        self.decorate(self.snapshot())
            .into_iter()
            .find(|entry| entry.id == history_id)
    }

    /// 事务是否已完整提交：历史里有没有这条 id。crash recovery 的唯一判据。
    pub fn contains_committed(&self, history_id: &str) -> bool {
        self.snapshot()
            .iter()
            .any(|entry| entry.id == history_id && entry.status != HistoryStatus::Restored)
    }

    /// 主队列的「恢复原图」不带 id 时，按源路径找最近一条还没恢复的记录。
    pub fn find_latest_for_source(&self, source_path: &str) -> Option<HistoryEntry> {
        self.decorate(self.snapshot())
            .into_iter()
            .filter(|entry| entry.source_path == source_path && entry.status != HistoryStatus::Restored)
            .max_by_key(|entry| entry.created_at)
    }

    pub fn add(&self, entry: HistoryEntry) -> Result<(), String> {
        let _commit = self.commit_lock.lock().unwrap();
        let mut entries = self.snapshot();
        entries.retain(|existing| existing.id != entry.id);
        entries.push(entry);
        // 硬上限：异常设置或时间问题都不许让历史无限膨胀。淘汰的是最老的记录，
        // 备份只在"没有任何幸存记录引用它"时才连带删。
        let evicted = self.trim_to_cap(&mut entries, MAX_HISTORY_ENTRIES);
        if !evicted.is_empty() {
            let survivors = entries.clone();
            self.store(entries)?;
            self.drop_backups_of(&evicted, &survivors);
            return Ok(());
        }
        self.store(entries)
    }

    /// 只保留最近 `cap` 条，返回被淘汰的那些。
    fn trim_to_cap(&self, entries: &mut Vec<HistoryEntry>, cap: usize) -> Vec<HistoryEntry> {
        if entries.len() <= cap {
            return Vec::new();
        }
        let mut order: Vec<usize> = (0..entries.len()).collect();
        order.sort_by(|a, b| {
            entries[*a]
                .created_at
                .cmp(&entries[*b].created_at)
                .then_with(|| entries[*a].id.cmp(&entries[*b].id))
        });
        let doomed: HashSet<usize> = order.into_iter().take(entries.len() - cap).collect();
        let mut evicted = Vec::with_capacity(doomed.len());
        let mut kept = Vec::new();
        for (index, entry) in entries.drain(..).enumerate() {
            if doomed.contains(&index) {
                evicted.push(entry);
            } else {
                kept.push(entry);
            }
        }
        *entries = kept;
        evicted
    }

    /// 删掉被淘汰记录独占的备份目录。`survivors` 是还留在历史里的那些 ——
    /// 同一张图重压多次时备份是共享的，只要还有一个引用就绝不能动。
    fn drop_backups_of(&self, evicted: &[HistoryEntry], survivors: &[HistoryEntry]) {
        for stale in evicted {
            let Some(dir) = stale
                .backup_path
                .as_deref()
                .and_then(|path| Self::backup_dir_of_path(path))
            else {
                continue;
            };
            let Some(key) = backup_key_of(stale.backup_path.as_deref()) else {
                continue;
            };
            let still_used = survivors.iter().any(|other| {
                other.status != HistoryStatus::Restored
                    && backup_key_of(other.backup_path.as_deref()).as_deref() == Some(key.as_str())
            });
            if !still_used {
                let _ = fs::remove_dir_all(dir);
            }
        }
    }

    pub fn clear(&self) -> Result<CleanupReport, String> {
        let _commit = self.commit_lock.lock().unwrap();
        let entries = self.snapshot();
        let referenced: HashSet<String> = entries
            .iter()
            .filter_map(|entry| backup_key_of(entry.backup_path.as_deref()))
            .collect();
        // 先让历史不再引用任何备份，再动手删：中间崩溃只是留下孤儿，下次退出扫掉。
        self.store(Vec::new())?;
        let mut report = CleanupReport {
            removed_entries: entries.len(),
            ..Default::default()
        };
        for key in referenced {
            match fs::remove_dir_all(self.backup_dir(&key)) {
                Ok(()) => report.removed_backups += 1,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => report.warnings.push(format!("{key}: {error}")),
            }
        }
        Ok(report)
    }

    // ─── 原图备份 ────────────────────────────────────────────────

    /// 稳定哈希：FNV-1a 64 位。同一 sourcePath 在任意次启动、任意 rustc 版本下
    /// 都落进同一个备份目录，也和 Swift 线 `backupKey(forPath:)` 完全一致。
    ///
    /// 刻意不用 `DefaultHasher` —— 标准库从不把它的算法当作持久存储格式的保证，
    /// 一次升级就能让所有已有备份变成"无人引用"，进而被退出清理删掉。
    fn stable_hash(text: &str) -> String {
        let mut hash: u64 = 0xcbf29ce484222325;
        for byte in text.as_bytes() {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("{hash:016x}")
    }

    pub fn backup_key(path: &Path) -> String {
        Self::stable_hash(&canonical_path(path))
    }

    /// 老版本 `DefaultHasher` 的 key：只用来认已有备份，不再产生新目录。
    fn legacy_backup_key(path: &Path) -> String {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        canonical_path(path).hash(&mut hasher);
        format!("{:016x}", hasher.finish())
    }

    /// security-scoped 书签文件名候选：新 key 优先，老 key 只用于续认已有授权。
    /// 只有沙盒线（`inproc-backends`）会读它，默认构建下不参与压缩。
    #[cfg_attr(not(feature = "inproc-backends"), allow(dead_code))]
    pub fn bookmark_keys_for(path: &Path) -> [String; 2] {
        [Self::backup_key(path), Self::legacy_backup_key(path)]
    }

    fn backup_dir(&self, key: &str) -> PathBuf {
        self.backups_dir().join(key)
    }

    fn read_meta(&self, key: &str) -> Option<BackupMeta> {
        let raw = fs::read_to_string(self.backup_dir(key).join(META_FILE)).ok()?;
        serde_json::from_str(&raw).ok()
    }

    fn existing_backup_file(&self, key: &str) -> Option<PathBuf> {
        let dir = self.backup_dir(key);
        let mut names: Vec<PathBuf> = fs::read_dir(&dir)
            .ok()?
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.starts_with("original."))
                    .unwrap_or(false)
            })
            .collect();
        names.sort();
        names.pop()
    }

    /// 为一次 replace 压缩准备原图备份。
    ///
    /// Err = 这份备份不可信（备份文件在、来历记录不在的半份备份等同于没有：
    /// `history.json` 一旦损坏就再也认不出它属于谁）。调用方**必须放弃这次覆盖**。
    ///
    /// 关键不变量：**已有有效备份时绝不覆盖**。同一张图连压三次，备份里永远是
    /// 第一次压缩前的真正原图，否则「恢复原图」只会回到上一版压缩结果。
    pub fn ensure_backup(&self, source: &Path) -> Result<PathBuf, String> {
        let _guard = self.backup_lock.lock().unwrap();
        let canonical = PathBuf::from(canonical_path(source));
        let base_key = Self::backup_key(source);
        let extension = canonical
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.to_lowercase())
            .filter(|ext| !ext.is_empty() && ext.len() <= 8)
            .unwrap_or_else(|| "bin".into());

        for index in 0..32u32 {
            let key = if index == 0 {
                base_key.clone()
            } else {
                format!("{base_key}-{index}")
            };
            let dir = self.backup_dir(&key);
            match self.read_meta(&key) {
                // 命中同一源路径：复用，不重新拷贝。
                Some(meta) if meta.source_path == canonical.to_string_lossy() => {
                    if let Some(existing) = self.existing_backup_file(&key) {
                        return Ok(existing);
                    }
                    // 备份文件被外部删掉了，重新写一份真正原图。
                }
                // 哈希撞上了别的文件，往后挪一个槽位。
                Some(_) => continue,
                None => {
                    if dir.exists() {
                        continue;
                    }
                    // 升级前用老 key 备份过的图：认那一份，不另起炉灶，
                    // 否则第二次压缩会把压缩结果当成原图存进新目录。
                    if index == 0 {
                        if let Some(legacy) = self
                            .existing_backup_file(&Self::legacy_backup_key(source))
                        {
                            return Ok(legacy);
                        }
                    }
                }
            }

            if fs::create_dir_all(&dir).is_err() {
                return Err("无法创建原图备份目录".into());
            }
            let backup_path = dir.join(format!("original.{extension}"));
            // 先写临时名再 rename：崩溃不许留下半个 original.xxx 冒充有效备份。
            let staged = dir.join(format!(".original.{extension}.tmp"));
            if fs::copy(&canonical, &staged).is_err() {
                let _ = fs::remove_dir_all(&dir);
                return Err("无法保存原图备份".into());
            }
            if let Ok(handle) = fs::File::open(&staged) {
                let _ = handle.sync_all();
            }
            if let Err(error) = fs::rename(&staged, &backup_path) {
                let _ = fs::remove_dir_all(&dir);
                return Err(format!("无法保存原图备份: {error}"));
            }
            let meta = BackupMeta {
                version: 2,
                source_path: canonical.to_string_lossy().into_owned(),
                created_at: now_millis(),
                original_size: file_size(&backup_path),
                original_modified_at: file_mtime_millis(source),
                original_extension: extension.clone(),
            };
            let json = serde_json::to_string(&meta)
                .map_err(|error| format!("原图备份的来历记录写不成功: {error}"))?;
            if let Err(error) = write_atomic(&dir.join(META_FILE), json.as_bytes()) {
                let _ = fs::remove_dir_all(&dir);
                return Err(format!("原图备份的来历记录写不成功: {error}"));
            }
            // 备份文件 + 来历记录**都在**才算备份成功，缺一处这次覆盖就不可恢复。
            if self.existing_backup_file(&key).is_none() || self.read_meta(&key).is_none() {
                let _ = fs::remove_dir_all(&dir);
                return Err("原图备份不完整，已跳过覆盖".into());
            }
            return Ok(backup_path);
        }
        Err("原图备份槽位已满，无法为这张图准备备份".into())
    }

    /// `history.json` 损坏后按备份目录重建恢复入口。
    ///
    /// 只"把文件留着但历史页看不到"不叫数据恢复 —— 用户必须看到
    /// 「检测到可恢复的原图备份」并且能一键恢复。
    fn rebuild_from_backups(&self) -> Vec<HistoryEntry> {
        let Ok(dirs) = fs::read_dir(self.backups_dir()) else {
            return Vec::new();
        };
        let now = now_millis();
        let mut rebuilt = Vec::new();
        for entry in dirs.flatten() {
            let dir = entry.path();
            if !dir.is_dir() {
                continue;
            }
            let Some(key) = dir.file_name().and_then(|name| name.to_str()).map(str::to_owned)
            else {
                continue;
            };
            let Some(backup) = self.existing_backup_file(&key) else {
                continue;
            };
            let meta = self.read_meta(&key);
            // 没有来历记录就不知道这份备份是谁的图，宁可不认也不许瞎猜。
            let Some(meta) = meta else { continue };
            let source = Path::new(&meta.source_path);
            rebuilt.push(HistoryEntry {
                id: format!("recovery-{key}"),
                created_at: meta.created_at,
                expires_at: now,
                source_path: meta.source_path.clone(),
                // replace 模式覆盖的就是源文件本身。
                output_path: Some(meta.source_path.clone()),
                file_name: source
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "image".into()),
                output_mode: "replace".into(),
                original_size: if meta.original_size > 0 {
                    meta.original_size
                } else {
                    file_size(&backup)
                },
                compressed_size: file_size(source),
                savings: 0.0,
                out_type: source
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .map(|ext| ext.to_lowercase())
                    .unwrap_or_else(|| "bin".into()),
                algorithm: RECOVERY_ALGORITHM.into(),
                backup_path: Some(backup.to_string_lossy().into_owned()),
                status: HistoryStatus::RecoveryAvailable,
                restored_at: None,
                // 明细已经无从得知，但"此刻源文件是什么样"是量得出来的：拿它的实时
                // mtime，冲突判定才不会在每次恢复前都误报一次「压缩后又被修改过」。
                output_modified_at: file_mtime_millis(source).or(meta.original_modified_at),
                source_exists: true,
                backup_exists: true,
                // 重建条目的"输出"就是源文件本身，它刚被 stat 过。
                output_exists: true,
            });
        }
        rebuilt
    }

    pub fn backup_dir_of_path(backup_path: &str) -> Option<PathBuf> {
        Path::new(backup_path).parent().map(Path::to_path_buf)
    }

    // ─── 退出清理（唯一的清理时机）────────────────────────────────

    /// 正常退出时按保留档位清一次：删掉的记录写回 `history.json`，再删已经没人引用的备份。
    /// 单个删除失败只 warn，剩下的孤儿下次退出继续扫。
    ///
    /// - 按天档位（1/3/7/14/30）：`created_at` 超出窗口的记录过期。
    /// - 「不保留」（0）：**本次运行**造出的记录过期。`run_started_at` 之前那条如果是
    ///   上次异常退出留下的、备份文件还在，就再留它一次（`previous_run_ended_cleanly`
    ///   为假时）—— 那份备份可能是被覆盖原图唯一的副本，而这一次会话是用户唯一看得见
    ///   也能一键恢复它的窗口。下一次干净退出收账，不留"说不保留却永久占着磁盘"的死角。
    pub fn apply_retention_on_exit(
        &self,
        retention_days: u32,
        run_started_at: i64,
        previous_run_ended_cleanly: bool,
    ) -> CleanupReport {
        let mut report = CleanupReport::default();
        let _commit = self.commit_lock.lock().unwrap();
        if self.cleanup_is_locked() {
            // 引用关系不可信的时候一个备份都不许删：这是"history.json 损坏 →
            // 所有备份变成无人引用 → 全被清掉"那条链路唯一的断点。
            report.warnings.push(
                "历史记录文件已损坏，本次退出跳过清理，原图备份全部保留".into(),
            );
            return report;
        }
        let not_retained = retention_days == crate::app_settings::KEEP_UNTIL_QUIT;
        let cutoff = now_millis() - retention_days.max(1) as i64 * DAY_MILLIS;
        let all = self.snapshot();
        let kept: Vec<HistoryEntry> = all
            .iter()
            .filter(|entry| {
                let survives = if not_retained {
                    entry.created_at < run_started_at
                        && !previous_run_ended_cleanly
                        && backup_file_is_live(entry)
                } else {
                    entry.created_at >= cutoff
                };
                if !survives {
                    report.removed_entries += 1;
                }
                survives
            })
            .cloned()
            .collect();

        // 先落账再删文件：备份没了而 `history.json` 还说备份在，就是一个点开只会报错的
        // 恢复入口；写失败时一个文件都不许动。
        if kept.len() != all.len() {
            if let Err(error) = self.store(kept.clone()) {
                report.warnings.push(format!("history.json 写入失败: {error}"));
                return report;
            }
        }

        self.sweep_unreferenced_backups(&kept, &mut report);
        report
    }

    /// 读取并抹掉「上次运行走完了退出清理」的记号，只在启动时取一次。
    /// 崩溃 / 强杀写不下这个文件，所以"没有记号"就是上次没清账的证据。
    pub fn take_clean_exit_marker(&self) -> bool {
        let path = self.root.join(CLEAN_EXIT_FILE);
        match fs::remove_file(&path) {
            Ok(()) => true,
            Err(error) if error.kind() == ErrorKind::NotFound => false,
            Err(error) => {
                log::warn!("退出记号 {path:?} 读不了，按上次没清账处理: {error}");
                false
            }
        }
    }

    /// 只有退出清理真的跑完才留记号：跳过清理时不许留下"账已结清"的假证据。
    pub fn mark_clean_exit(&self) {
        let _ = fs::write(self.root.join(CLEAN_EXIT_FILE), now_millis().to_string());
    }

    /// 删掉没有任何存活条目引用的备份目录。
    fn sweep_unreferenced_backups(&self, kept: &[HistoryEntry], report: &mut CleanupReport) {
        if self.cleanup_is_locked() {
            report.warnings.push("历史记录不可信，跳过备份清理".into());
            return;
        }
        let referenced: HashSet<String> = kept
            .iter()
            .filter(|entry| entry.status != HistoryStatus::Restored)
            .filter_map(|entry| backup_key_of(entry.backup_path.as_deref()))
            .collect();

        let Ok(entries) = fs::read_dir(self.backups_dir()) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                let _ = fs::remove_file(&path);
                continue;
            }
            let Some(key) = path.file_name().and_then(|name| name.to_str()).map(str::to_owned)
            else {
                continue;
            };
            if referenced.contains(&key) {
                report.kept_backups += 1;
                continue;
            }
            match fs::remove_dir_all(&path) {
                Ok(()) => report.removed_backups += 1,
                Err(error) => report
                    .warnings
                    .push(format!("备份 {key} 删除失败，留待下次清理: {error}")),
            }
        }
    }

    // ─── 恢复 ────────────────────────────────────────────────────

    fn mark_restored(&self, ids: &[String]) -> Result<(), String> {
        let _commit = self.commit_lock.lock().unwrap();
        let stamp = now_millis();
        let mut entries = self.snapshot();
        let mut touched = false;
        for entry in &mut entries {
            if ids.contains(&entry.id) && entry.status != HistoryStatus::Restored {
                entry.status = HistoryStatus::Restored;
                entry.restored_at = Some(stamp);
                entry.backup_path = None;
                entry.backup_exists = false;
                touched = true;
            }
        }
        if touched {
            self.store(entries)?;
        }
        Ok(())
    }

    fn remove_ids(&self, ids: &[String]) -> Result<(), String> {
        let _commit = self.commit_lock.lock().unwrap();
        let before = self.snapshot();
        let after: Vec<HistoryEntry> = before
            .iter()
            .filter(|entry| !ids.contains(&entry.id))
            .cloned()
            .collect();
        if after.len() != before.len() {
            self.store(after)?;
        }
        Ok(())
    }

    /// 同一条备份可能被多条记录引用（同一张图重压 N 次）。恢复的是那份真正原图，
    /// 所有这些记录的「已压缩」状态同时失效，必须一起标 Restored。
    fn siblings_sharing_backup(&self, entry: &HistoryEntry) -> Vec<String> {
        let Some(key) = backup_key_of(entry.backup_path.as_deref()) else {
            return vec![entry.id.clone()];
        };
        self.snapshot()
            .into_iter()
            .filter(|other| {
                other.status != HistoryStatus::Restored
                    && backup_key_of(other.backup_path.as_deref()).as_deref() == Some(key.as_str())
            })
            .map(|other| other.id)
            .collect()
    }

    /// 恢复前的安全检查：压缩结果被外部改过就不要静默覆盖。
    pub fn has_conflict(entry: &HistoryEntry) -> bool {
        if entry.output_mode != "replace" {
            return false;
        }
        let Some(target) = entry.output_path.as_deref().or(Some(entry.source_path.as_str())) else {
            return false;
        };
        let target = Path::new(target);
        if !target.exists() {
            return false;
        }
        if fs::metadata(target).map(|m| m.len()).unwrap_or(0) != entry.compressed_size {
            return true;
        }
        match (entry.output_modified_at, file_mtime_millis(target)) {
            (Some(recorded), Some(current)) => (current - recorded).abs() > MTIME_TOLERANCE_MILLIS,
            _ => false,
        }
    }

    /// 把一份备份原子地写回目标位置：同目录临时文件 → fsync → rename。
    ///
    /// `restore` 和事务回滚共用这一个实现 —— 恢复原图这件事绝不允许有两套写法。
    pub fn write_backup_back_to_source(backup: &Path, target: &Path) -> Result<(), String> {
        let parent = target
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let tmp = parent.join(format!(".octoshrink-restore-{}.tmp", now_nanos()));
        fs::copy(backup, &tmp).map_err(|e| e.to_string())?;
        if let Ok(handle) = fs::File::open(&tmp) {
            // 写回原图这一步不能只留在内核缓存里：崩溃后用户看到的必须真是原图。
            let _ = handle.sync_all();
        }
        if fs::rename(&tmp, target).is_err() {
            // 覆盖到一半失败时保留原目标文件，只清掉临时文件。
            let _ = fs::remove_file(&tmp);
            return Err("无法把原图写回目标位置".into());
        }
        Ok(())
    }

    /// 跨格式 replace（PNG → JPG）时压缩结果是个新文件，恢复后不该留下孤儿。
    /// 同格式 replace 的输出就是源文件本身，绝不许删。
    fn remove_generated_output(entry: &HistoryEntry) {
        let target = PathBuf::from(&entry.source_path);
        if let Some(output) = entry.output_path.as_deref() {
            let output = Path::new(output);
            if !same_file(output, &target) {
                let _ = fs::remove_file(output);
            }
        }
    }

    /// 统一恢复入口：`restore_original` / `restore_history_entry` / `restore_all`
    /// 都走这里，避免三套逻辑对历史状态的处理不一致。
    ///
    /// `access` 负责在沙盒下临时取得目标位置的访问权（Direct 版直通），
    /// 守卫必须覆盖整个文件操作，返回即释放授权。
    ///
    /// 提交顺序是**刻意**的：写回原图 → 历史落盘 → 才删压缩输出和备份目录。
    /// 反过来（先删备份再写历史）一旦历史写失败，历史会显示「已压缩」而备份已经没了 ——
    /// 用户看到一条永远恢复不了的记录。现在最坏只留下一个没人引用的孤儿目录。
    pub fn restore(
        &self,
        entry: &HistoryEntry,
        force: bool,
        access: &dyn FileAccess,
        reauth: &mut dyn FnMut() -> bool,
    ) -> Result<Vec<String>, RestoreError> {
        if entry.status == HistoryStatus::Restored {
            return Err(RestoreError::NotRestorable);
        }
        if entry.output_mode == "replace" {
            if !force && Self::has_conflict(entry) {
                return Err(RestoreError::Conflict);
            }
            let backup = entry
                .backup_path
                .as_ref()
                .map(PathBuf::from)
                .filter(|path| path.exists())
                .ok_or(RestoreError::BackupGone)?;
            let target = PathBuf::from(&entry.source_path);
            let parent = target
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("/"));
            let ids = self.siblings_sharing_backup(entry);
            let backup_dir = entry
                .backup_path
                .as_deref()
                .and_then(|path| Self::backup_dir_of_path(path));
            let _guard = access
                .acquire(&parent, reauth)
                .ok_or(RestoreError::AccessDenied)?;
            Self::write_backup_back_to_source(&backup, &target)
                .map_err(RestoreError::Io)?;
            drop(_guard);
            if let Err(error) = self.mark_restored(&ids) {
                // 文件已经回到原图，但状态没落盘：备份必须留着，用户重试即可收敛。
                return Err(RestoreError::Io(format!(
                    "文件已恢复，但历史记录状态保存失败（{error}），原图备份已保留"
                )));
            }
            Self::remove_generated_output(entry);
            if let Some(dir) = backup_dir {
                // 备份在 AppData 内，不需要沙盒授权。删不掉只是孤儿，下次退出扫。
                let _ = fs::remove_dir_all(dir);
            }
            Ok(ids)
        } else {
            // 后缀/目录模式原图从未被改动：撤销 = 删掉这次生成的压缩结果。
            if let Some(output) = entry.output_path.as_deref() {
                let path = Path::new(output);
                if path.exists() {
                    let dir = path
                        .parent()
                        .map(Path::to_path_buf)
                        .unwrap_or_else(|| PathBuf::from("/"));
                    let _guard = access
                        .acquire(&dir, reauth)
                        .ok_or(RestoreError::AccessDenied)?;
                    fs::remove_file(path).map_err(|e| RestoreError::Io(e.to_string()))?;
                }
            }
            self.remove_ids(&[entry.id.clone()])
                .map_err(RestoreError::Io)?;
            Ok(vec![entry.id.clone()])
        }
    }
}

fn canonical_path(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

/// 两个路径指的是不是同一个文件。
///
/// 记录里的 `source_path` 是规范路径，`output_path` 是当时那个字符串 —— macOS 上
/// `/var/…` 与 `/private/var/…`、任何软链目录都会让两者字面不等。同格式 replace 的
/// 压缩输出**就是**源文件本身，判成"另一个文件"会在恢复之后把刚写回的原图删掉。
pub(crate) fn same_file(a: &Path, b: &Path) -> bool {
    a == b || canonical_path(a) == canonical_path(b)
}

/// 备份 key = 备份目录名；目录名 = backups/<key>/original.<ext>。
fn backup_key_of(backup_path: Option<&str>) -> Option<String> {
    let dir = Path::new(backup_path?).parent()?;
    dir.file_name()?.to_str().map(str::to_owned)
}

/// 备份文件此刻是否还在磁盘上。清理时用它判断"这条记录还替用户守着一份原图吗"。
fn backup_file_is_live(entry: &HistoryEntry) -> bool {
    entry
        .backup_path
        .as_ref()
        .map(|path| Path::new(path).exists())
        .unwrap_or(false)
}

/// 只有测试用：一条指向 `source`、覆盖模式为 replace 的历史记录。
#[cfg(test)]
pub(crate) fn sample_entry(source: &Path, backup: &Path, id: &str) -> HistoryEntry {
    let created_at = now_millis();
    HistoryEntry {
        id: id.into(),
        created_at,
        expires_at: created_at + DAY_MILLIS * 3,
        source_path: source.to_string_lossy().into_owned(),
        output_path: Some(source.to_string_lossy().into_owned()),
        file_name: source
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "image".into()),
        output_mode: "replace".into(),
        original_size: 100,
        compressed_size: file_size(source),
        savings: 60.0,
        out_type: "png".into(),
        algorithm: "test".into(),
        backup_path: Some(backup.to_string_lossy().into_owned()),
        status: HistoryStatus::Compressed,
        restored_at: None,
        output_modified_at: file_mtime_millis(source),
        source_exists: true,
        backup_exists: true,
        output_exists: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store_in(dir: &Path) -> HistoryStore {
        HistoryStore::new(dir.join("history")).unwrap()
    }

    fn sample_source(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, bytes).unwrap();
        path.canonicalize().unwrap()
    }

    /// 备份文件所在目录 = backups/<key>；用它断言备份是否还在。
    fn dir_of_backup(backup: &Path) -> PathBuf {
        backup.parent().unwrap().to_path_buf()
    }

    fn entry_for(source: &Path, backup: &Path, created_at: i64) -> HistoryEntry {
        HistoryEntry {
            id: format!(
                "{}-{}",
                created_at,
                dir_of_backup(backup).file_name().unwrap().to_string_lossy()
            ),
            created_at,
            expires_at: created_at + DAY_MILLIS * 3,
            source_path: source.to_string_lossy().into_owned(),
            output_path: Some(source.to_string_lossy().into_owned()),
            file_name: source.file_name().unwrap().to_string_lossy().into_owned(),
            output_mode: "replace".into(),
            original_size: 100,
            compressed_size: fs::metadata(source).map(|m| m.len()).unwrap_or(0),
            savings: 60.0,
            out_type: "png".into(),
            algorithm: "test".into(),
            backup_path: Some(backup.to_string_lossy().into_owned()),
            status: HistoryStatus::Compressed,
            restored_at: None,
            output_modified_at: file_mtime_millis(source),
            source_exists: true,
            backup_exists: true,
            output_exists: true,
        }
    }

    fn open_access() -> std::sync::Arc<dyn crate::sandbox_access::FileAccess> {
        crate::sandbox_access::unrestricted()
    }

    #[test]
    fn replace_reuses_the_first_backup_so_the_true_original_survives_recompression() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"bytes1");

        let first = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed-once").unwrap();
        let second = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed-twice").unwrap();

        assert_eq!(first, second);
        assert_eq!(fs::read(&second).unwrap(), b"bytes1");
    }

    #[test]
    fn expired_entries_and_their_backups_are_dropped_when_quitting() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let old = sample_source(dir.path(), "old.png", b"old-original");
        let fresh = sample_source(dir.path(), "fresh.png", b"fresh-original");
        let now = now_millis();

        let old_backup = store.ensure_backup(&old).unwrap();
        let fresh_backup = store.ensure_backup(&fresh).unwrap();
        store
            .add(entry_for(&old, &old_backup, now - 4 * DAY_MILLIS))
            .unwrap();
        store
            .add(entry_for(&fresh, &fresh_backup, now - 2 * DAY_MILLIS))
            .unwrap();

        let report = store.apply_retention_on_exit(3, now, true);
        assert_eq!(report.removed_entries, 1);
        assert!(!dir_of_backup(&old_backup).exists());
        assert!(dir_of_backup(&fresh_backup).exists());
        assert_eq!(store.list().len(), 1);
        // 用户自己的文件永远不在清理范围内
        assert!(old.exists());
        assert!(fresh.exists());
    }

    #[test]
    fn shared_backup_is_kept_until_the_last_reference_expires() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        let now = now_millis();

        store
            .add(entry_for(&source, &backup, now - 4 * DAY_MILLIS))
            .unwrap();
        fs::write(&source, b"recompressed").unwrap();
        let second = store.ensure_backup(&source).unwrap();
        store
            .add(entry_for(&source, &second, now - 2 * DAY_MILLIS))
            .unwrap();

        store.apply_retention_on_exit(3, now, true);
        assert!(dir_of_backup(&backup).exists());
        assert_eq!(store.list().len(), 1);

        store.apply_retention_on_exit(1, now, true);
        assert!(!dir_of_backup(&backup).exists());
        assert!(store.list().is_empty());
        assert!(source.exists());
    }

    #[test]
    fn quitting_with_not_retained_clears_this_runs_rows_and_backups() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        let run_started_at = now_millis();
        store
            .add(entry_for(&source, &backup, run_started_at + 1_000))
            .unwrap();

        let report = store.apply_retention_on_exit(0, run_started_at, true);
        assert_eq!(report.removed_entries, 1);
        assert_eq!(report.removed_backups, 1);
        assert!(store.list().is_empty(), "「不保留」= 关掉应用后记录也没了");
        assert!(!dir_of_backup(&backup).exists());
        // 清的是 OctoShrink 自己的账本和副本，用户的压缩结果一个字节都不动。
        assert!(source.exists());
        assert_eq!(fs::read(&source).unwrap(), b"compressed");

        // 再退一次不许炸：已经没有东西可清了。
        let again = store.apply_retention_on_exit(0, run_started_at, true);
        assert_eq!(again.removed_entries, 0);
        assert_eq!(again.removed_backups, 0);
    }

    #[test]
    fn a_row_whose_backup_vanished_says_so_instead_of_pretending_to_be_restorable() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        store
            .add(entry_for(&source, &backup, now_millis()))
            .unwrap();
        // 记录还活着、备份目录却已经没了（手动清过 / 磁盘出错）：这时只能说实话。
        fs::remove_dir_all(dir_of_backup(&backup)).unwrap();

        let rows = store.list();
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].backup_exists);
        let error = store
            .restore(&rows[0], true, open_access().as_ref(), &mut || false)
            .unwrap_err();
        assert!(matches!(error, RestoreError::BackupGone));
        assert_eq!(error.message(), "原图备份已清理，无法恢复");
    }

    #[test]
    fn crash_leftovers_get_one_more_session_under_not_retained() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        // 上次被强杀/崩溃欠下的：那份备份可能是这个原图唯一还活着的副本。
        let run_started_at = now_millis();
        store
            .add(entry_for(&source, &backup, run_started_at - 60_000))
            .unwrap();

        // 本次退出：上一次没结清账 → 留着，用户在这一次会话里看得见、也恢复得了。
        let report = store.apply_retention_on_exit(0, run_started_at, false);
        assert_eq!(report.removed_entries, 0);
        assert_eq!(report.removed_backups, 0);
        assert!(dir_of_backup(&backup).exists());
        let rows = store.list();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].backup_exists);
        store
            .restore(&rows[0], true, open_access().as_ref(), &mut || false)
            .unwrap();
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
    }

    #[test]
    fn not_retained_leftovers_are_collected_by_the_next_clean_quit() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        // 同一份遗留：这次的上一次运行是**正常退出**的，账已经结过，不该再享有豁免。
        store
            .add(entry_for(&source, &backup, now_millis() - 60_000))
            .unwrap();

        let report = store.apply_retention_on_exit(0, now_millis(), true);
        assert_eq!(report.removed_entries, 1);
        assert_eq!(report.removed_backups, 1);
        assert!(store.list().is_empty());
        assert!(!dir_of_backup(&backup).exists());
        assert!(source.exists());
    }

    #[test]
    fn the_clean_exit_marker_is_what_tells_a_crash_apart_from_a_quit() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        // 全新安装：没有记号 = 上次没结清（宁可多留一批备份，也不误删）。
        assert!(!store.take_clean_exit_marker());
        store.mark_clean_exit();
        // 取一次就抹掉：下次启动读到的必须是"本次运行"的结论，不是上上次的。
        assert!(store.take_clean_exit_marker());
        assert!(!store.take_clean_exit_marker());
    }

    #[test]
    fn restore_marks_every_entry_sharing_the_backup_and_deletes_the_copy() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        let now = now_millis();

        fs::write(&source, b"compressed-once").unwrap();
        let first = entry_for(&source, &backup, now - 60_000);
        store.add(first.clone()).unwrap();
        let second = entry_for(&source, &backup, now);
        store.add(second.clone()).unwrap();

        let restored = store.restore(&second, false, open_access().as_ref(), &mut || false).unwrap();
        assert_eq!(restored.len(), 2);
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
        assert!(!dir_of_backup(&backup).exists());
        for entry in store.list() {
            assert_eq!(entry.status, HistoryStatus::Restored);
            assert!(entry.restored_at.is_some());
        }
    }

    #[test]
    fn cross_format_replace_removes_the_converted_output_when_restoring() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "photo.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        let output = dir.path().canonicalize().unwrap().join("photo.jpg");
        fs::write(&output, b"converted").unwrap();

        let mut entry = entry_for(&source, &backup, now_millis());
        entry.compressed_size = fs::metadata(&output).unwrap().len();
        entry.output_modified_at = file_mtime_millis(&output);
        entry.output_path = Some(output.to_string_lossy().into_owned());
        fs::write(&source, b"converted").unwrap();
        store.add(entry.clone()).unwrap();

        store.restore(&entry, false, open_access().as_ref(), &mut || false).unwrap();
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
        assert!(!output.exists());
    }

    #[test]
    fn externally_modified_output_requires_force() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        let mut entry = entry_for(&source, &backup, now_millis());
        entry.output_modified_at = Some(1_000);
        store.add(entry.clone()).unwrap();

        fs::write(&source, b"photoshop-saved-this").unwrap();
        assert!(HistoryStore::has_conflict(&entry));
        assert!(matches!(
            store.restore(&entry, false, open_access().as_ref(), &mut || false),
            Err(RestoreError::Conflict)
        ));
        // 备份没被动过，强制恢复仍可成功
        assert!(store.restore(&entry, true, open_access().as_ref(), &mut || false).is_ok());
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
    }

    #[test]
    fn suffix_entries_keep_no_backup_and_are_dropped_when_undone() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"untouched-original");
        let generated = dir.path().join("a_compressed.png");
        fs::write(&generated, b"compressed").unwrap();

        let mut entry = entry_for(&source, &generated, now_millis());
        entry.output_mode = "suffix".into();
        entry.backup_path = None;
        entry.output_path = Some(generated.to_string_lossy().into_owned());
        store.add(entry.clone()).unwrap();

        // 后缀模式没有备份，恢复语义只能是"删掉生成文件"。
        store.restore(&entry, false, open_access().as_ref(), &mut || false).unwrap();
        assert!(!generated.exists());
        assert!(store.list().is_empty());
        assert_eq!(fs::read(&source).unwrap(), b"untouched-original");
    }

    #[test]
    fn concurrent_appends_do_not_overwrite_each_other() {
        let dir = tempfile::tempdir().unwrap();
        let store = std::sync::Arc::new(store_in(dir.path()));
        let source = sample_source(dir.path(), "a.png", b"x");
        let backup = store.ensure_backup(&source).unwrap();

        let mut handles = Vec::new();
        for index in 0..12 {
            let store = store.clone();
            let source = source.clone();
            let backup = backup.clone();
            handles.push(std::thread::spawn(move || {
                store
                    .add(entry_for(&source, &backup, 1_000 + index))
                    .unwrap();
            }));
        }
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(store.list().len(), 12);
    }

    #[test]
    fn corrupt_history_never_deletes_backups() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        fs::write(store.history_path(), b"{ half-written").unwrap();

        // 退出清理第一刀就砍在损坏的历史上：它绝不能被当成"空历史"，否则所有备份
        // 看起来无人引用，一次不报错的退出就把原图全删了。
        let report = store.apply_retention_on_exit(3, now_millis(), true);
        assert_eq!(report.removed_entries, 0);
        assert_eq!(report.removed_backups, 0);
        assert!(!report.warnings.is_empty(), "跳过清理必须说给用户听");
        assert!(dir_of_backup(&backup).exists());
        assert_eq!(fs::read(&backup).unwrap(), b"true-original");
        assert!(store.list().iter().any(|entry| entry.status == HistoryStatus::RecoveryAvailable));
        // 损坏现场要留档，不能悄悄被 [] 覆盖掉。
        let quarantined = PathBuf::from(store.take_startup_report().unwrap().quarantined_to.unwrap());
        assert_eq!(fs::read(&quarantined).unwrap(), b"{ half-written");
    }

    #[test]
    fn corrupt_history_rebuilds_a_restore_entry_from_the_backup() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        fs::write(store.history_path(), b"not json at all").unwrap();
        drop(store);

        // 换一个新实例 = 重启一次：读不到老历史，就从备份重建能一键恢复的入口。
        let store = store_in(dir.path());
        let rows = store.list();
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].status, HistoryStatus::RecoveryAvailable);
        assert_eq!(rows[0].original_size, 13, "备份里那份才是真正原图");
        assert_eq!(rows[0].compressed_size, 10);
        assert!(rows[0].backup_exists);
        // 重建条目不该一上来就误报「压缩后又被改过」：不 force 也必须能恢复。
        assert!(!HistoryStore::has_conflict(&rows[0]));

        store
            .restore(&rows[0], false, open_access().as_ref(), &mut || false)
            .unwrap();
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
        assert!(!dir_of_backup(&backup).exists());
        assert_eq!(store.list()[0].status, HistoryStatus::Restored);
    }

    #[test]
    fn a_missing_history_file_is_not_corruption() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"x");
        let backup = store.ensure_backup(&source).unwrap();
        assert!(!store.cleanup_is_locked());
        // 全新安装（没有任何历史）时，无人引用的孤儿备份照常被回收。
        let report = store.apply_retention_on_exit(3, now_millis(), true);
        assert_eq!(report.removed_backups, 1);
        assert!(!dir_of_backup(&backup).exists());
    }

    #[test]
    fn backup_keys_are_stable_across_store_instances() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.png");
        fs::write(&path, b"x").unwrap();
        let first = HistoryStore::backup_key(&path);
        let second = HistoryStore::backup_key(&path.canonicalize().unwrap());
        assert_eq!(first, second);
        assert_eq!(first.len(), 16);
        // FNV-1a 64 的已知测试向量：换算法会在这里炸，而不是在用户升级之后。
        assert_eq!(HistoryStore::stable_hash(""), "cbf29ce484222325");
        assert_eq!(HistoryStore::stable_hash("a"), "af63dc4c8601ec8c");
        assert_ne!(first, HistoryStore::legacy_backup_key(&path));
    }

    #[test]
    fn a_backup_made_under_the_legacy_hash_key_is_still_reused() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        // 模拟升级前老 key 写的备份目录（只有 original，没有来历记录）。
        let legacy = HistoryStore::legacy_backup_key(&source);
        let legacy_dir = dir.path().join("history").join(BACKUPS_DIR).join(&legacy);
        fs::create_dir_all(&legacy_dir).unwrap();
        let legacy_backup = legacy_dir.join("original.png");
        fs::write(&legacy_backup, b"true-original").unwrap();

        // 第二次压缩必须复用那份老备份，而不是把压缩结果当成原图存进新目录。
        fs::write(&source, b"compressed").unwrap();
        assert_eq!(store.ensure_backup(&source).unwrap(), legacy_backup);
        assert_eq!(fs::read(&legacy_backup).unwrap(), b"true-original");
    }

    #[test]
    fn the_history_cap_evicts_the_oldest_rows_only() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"x");
        let backup = store.ensure_backup(&source).unwrap();
        let mut entries = Vec::new();
        for index in 0..5 {
            let mut entry = entry_for(&source, &backup, 1_000 + index);
            entry.id = format!("row-{index}");
            entries.push(entry);
        }

        let evicted = store.trim_to_cap(&mut entries, 3);
        assert_eq!(entries.len(), 3);
        assert_eq!(evicted.len(), 2);
        assert!(entries.iter().all(|entry| entry.id.starts_with("row-")));
        assert!(evicted.iter().any(|entry| entry.id == "row-0"));
        assert!(evicted.iter().any(|entry| entry.id == "row-1"));
        // 还没超上限时一条都不动。
        assert!(store.trim_to_cap(&mut entries, 9).is_empty());
    }

    #[test]
    fn a_backup_shared_with_a_surviving_row_survives_eviction() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"x");
        let backup = store.ensure_backup(&source).unwrap();
        let mut entries = Vec::new();
        for index in 0..2 {
            let mut entry = entry_for(&source, &backup, 1_000 + index);
            entry.id = format!("row-{index}");
            entries.push(entry);
        }
        // 两条记录共用同一份备份：淘汰最老的那条也不能把备份删了。
        let evicted = store.trim_to_cap(&mut entries, 1);
        store.drop_backups_of(&evicted, &entries);
        assert!(dir_of_backup(&backup).exists());
    }
}
