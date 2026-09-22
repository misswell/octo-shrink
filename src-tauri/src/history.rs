// OctoShrink - 持久化的压缩历史与原图备份。
//
// 与旧的 `$TMPDIR/octoshrink-backups` 模型的根本区别：清理只针对 OctoShrink 自己
// 写的副本 —— 用户的原图和压缩结果永远不在删除范围内。
//
// `retentionDays > 0`：备份随 App 退出保留，只在**下一次启动**按天数清理。
// `retentionDays == 0`（「不保留」，默认档）：备份随这次运行存活，覆盖原文件前照写
// 不误（没有备份就不许覆盖），在**正常退出**时清干净；异常退出留下的等到下次正常退出，
// 启动时只扫没人引用的孤儿。

use std::collections::hash_map::DefaultHasher;
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::Write;
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
pub const DAY_MILLIS: i64 = 86_400_000;
/// mtime 比文件大小更容易被无关操作扰动；容忍 2 秒以内的写入抖动。
const MTIME_TOLERANCE_MILLIS: i64 = 2_000;

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
}

static ENTRY_SEQUENCE: AtomicU32 = AtomicU32::new(0);

impl HistoryEntry {
    /// 一次成功产出对应一条历史。`expires_at` 只用于展示：启动清理按 `created_at`
    /// 判定，所以同一张图重压多次时，备份的存活期顺延到最后一次相关压缩之后。
    pub fn record(
        source: &Path,
        result: &CompressResult,
        output: &Path,
        backup: Option<&Path>,
        retention_days: u32,
    ) -> Self {
        let created_at = now_millis();
        let sequence = ENTRY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        Self {
            id: format!(
                "{}-{}-{}",
                now_nanos(),
                sequence,
                HistoryStore::backup_key(source)
            ),
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
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackupMeta {
    source_path: String,
    created_at: i64,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanupReport {
    pub removed_entries: usize,
    pub removed_backups: usize,
    pub kept_backups: usize,
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

/// 进程内共享的历史存储。所有读-改-写都在同一把锁里完成，
/// 3 个并发 worker 同时追加不会互相覆盖。
pub struct HistoryStore {
    root: PathBuf,
    lock: Mutex<()>,
}

impl HistoryStore {
    pub fn new(root: PathBuf) -> Result<Self, String> {
        fs::create_dir_all(root.join(BACKUPS_DIR)).map_err(|e| e.to_string())?;
        Ok(Self {
            root,
            lock: Mutex::new(()),
        })
    }

    fn history_path(&self) -> PathBuf {
        self.root.join(HISTORY_FILE)
    }

    fn backups_dir(&self) -> PathBuf {
        self.root.join(BACKUPS_DIR)
    }

    // ─── 读写 ────────────────────────────────────────────────────

    fn read_raw(&self) -> Vec<HistoryEntry> {
        match fs::read_to_string(self.history_path()) {
            Ok(raw) => serde_json::from_str(&raw).unwrap_or_default(),
            Err(_) => Vec::new(),
        }
    }

    fn write_raw(&self, entries: &[HistoryEntry]) -> Result<(), String> {
        let json = serde_json::to_string_pretty(entries).map_err(|e| e.to_string())?;
        write_atomic(&self.history_path(), json.as_bytes())
    }

    fn decorate(&self, mut entries: Vec<HistoryEntry>) -> Vec<HistoryEntry> {
        for entry in &mut entries {
            entry.source_exists = Path::new(&entry.source_path).exists();
            entry.backup_exists = entry
                .backup_path
                .as_ref()
                .map(|p| Path::new(p).exists())
                .unwrap_or(false);
            if !entry.source_exists && entry.status == HistoryStatus::Compressed {
                entry.status = HistoryStatus::Missing;
            }
        }
        entries
    }

    /// 最新在前，历史页直接渲染。
    pub fn list(&self) -> Vec<HistoryEntry> {
        let _guard = self.lock.lock().unwrap();
        let mut entries = self.read_raw();
        entries.sort_by(|a, b| b.created_at.cmp(&a.created_at).then_with(|| b.id.cmp(&a.id)));
        self.decorate(entries)
    }

    pub fn find(&self, history_id: &str) -> Option<HistoryEntry> {
        let _guard = self.lock.lock().unwrap();
        self.decorate(self.read_raw())
            .into_iter()
            .find(|entry| entry.id == history_id)
    }

    /// 主队列的「恢复原图」不带 id 时，按源路径找最近一条还没恢复的记录。
    pub fn find_latest_for_source(&self, source_path: &str) -> Option<HistoryEntry> {
        let _guard = self.lock.lock().unwrap();
        self.decorate(self.read_raw())
            .into_iter()
            .filter(|entry| entry.source_path == source_path && entry.status != HistoryStatus::Restored)
            .max_by_key(|entry| entry.created_at)
    }

    pub fn add(&self, entry: HistoryEntry) -> Result<(), String> {
        let _guard = self.lock.lock().unwrap();
        let mut entries = self.read_raw();
        entries.retain(|existing| existing.id != entry.id);
        entries.push(entry);
        self.write_raw(&entries)
    }

    pub fn clear(&self) -> Result<CleanupReport, String> {
        let _guard = self.lock.lock().unwrap();
        let entries = self.read_raw();
        let referenced: HashSet<String> = entries
            .iter()
            .filter_map(|entry| backup_key_of(entry.backup_path.as_deref()))
            .collect();
        self.write_raw(&[])?;
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

    /// 稳定哈希：同一 sourcePath 在任意次启动后都落进同一个备份目录。
    pub fn backup_key(path: &Path) -> String {
        let canonical = canonical_path(path);
        let mut hasher = DefaultHasher::new();
        canonical.hash(&mut hasher);
        format!("{:016x}", hasher.finish())
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

    /// 为一次 replace 压缩准备原图备份，返回 None 表示备份没写成。
    ///
    /// 关键不变量：**已有有效备份时绝不覆盖**。同一张图连压三次，备份里永远是
    /// 第一次压缩前的真正原图，否则「恢复原图」只会回到上一版压缩结果。
    pub fn ensure_backup(&self, source: &Path) -> Option<PathBuf> {
        let _guard = self.lock.lock().unwrap();
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
                        return Some(existing);
                    }
                    // 备份文件被外部删掉了，重新写一份真正原图。
                }
                // 哈希撞上了别的文件，往后挪一个槽位。
                Some(_) => continue,
                None => {
                    if dir.exists() {
                        continue;
                    }
                }
            }

            if fs::create_dir_all(&dir).is_err() {
                return None;
            }
            let backup_path = dir.join(format!("original.{extension}"));
            if fs::copy(&canonical, &backup_path).is_err() {
                return None;
            }
            let meta = BackupMeta {
                source_path: canonical.to_string_lossy().into_owned(),
                created_at: now_millis(),
            };
            if let Ok(json) = serde_json::to_string(&meta) {
                let _ = write_atomic(&dir.join(META_FILE), json.as_bytes());
            }
            return Some(backup_path);
        }
        None
    }

    pub fn backup_dir_of_path(backup_path: &str) -> Option<PathBuf> {
        Path::new(backup_path).parent().map(Path::to_path_buf)
    }

    // ─── 启动清理 ────────────────────────────────────────────────

    /// 只在启动时调用一次：删掉过期记录，再删掉已经没有任何记录引用的备份。
    /// 单个删除失败只 warn，剩下的孤儿下次启动继续扫。
    ///
    /// `retention_days == 0`（不保留）**不按时间过期**：这一档的清理挂在正常退出上。
    /// 崩溃 / 强杀现场留下的那份备份可能是唯一还活着的原图，启动时只扫没人引用的孤儿。
    pub fn cleanup_expired(&self, retention_days: u32) -> CleanupReport {
        let _guard = self.lock.lock().unwrap();
        let mut report = CleanupReport::default();
        let expires_by_time = retention_days > crate::app_settings::KEEP_UNTIL_QUIT;
        let cutoff = now_millis() - retention_days.max(1) as i64 * DAY_MILLIS;
        let all = self.read_raw();
        let kept: Vec<HistoryEntry> = all
            .iter()
            .filter(|entry| {
                let expired = expires_by_time && entry.created_at < cutoff;
                if expired {
                    report.removed_entries += 1;
                }
                !expired
            })
            .cloned()
            .collect();

        if let Err(error) = self.write_raw(&kept) {
            report.warnings.push(format!("history.json 写入失败: {error}"));
            return report;
        }

        self.sweep_unreferenced_backups(&kept, &mut report);
        report
    }

    /// 「不保留」档：正常退出时清掉所有原图备份。
    ///
    /// 历史条目本身留着 —— 那是用户的压缩记录，不是原图。只把 `backup_path` 抹掉，
    /// 前端读到 `backupExists == false` 就自然显示「原图备份已清理」并收起恢复按钮。
    pub fn purge_backups_on_exit(&self) -> CleanupReport {
        let _guard = self.lock.lock().unwrap();
        let mut report = CleanupReport::default();
        let cleared: Vec<HistoryEntry> = self
            .read_raw()
            .into_iter()
            .map(|mut entry| {
                entry.backup_path = None;
                entry
            })
            .collect();

        if let Err(error) = self.write_raw(&cleared) {
            report.warnings.push(format!("history.json 写入失败: {error}"));
            return report;
        }
        // 传空列表：备份目录里剩下的每一份都不再被引用，一并清掉。
        self.sweep_unreferenced_backups(&[], &mut report);
        report
    }

    /// 删掉没有任何存活条目引用的备份目录。调用方必须已持有 `lock`。
    fn sweep_unreferenced_backups(&self, kept: &[HistoryEntry], report: &mut CleanupReport) {
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
        let _guard = self.lock.lock().unwrap();
        let stamp = now_millis();
        let mut entries = self.read_raw();
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
            self.write_raw(&entries)?;
        }
        Ok(())
    }

    fn remove_ids(&self, ids: &[String]) -> Result<(), String> {
        let _guard = self.lock.lock().unwrap();
        let before = self.read_raw();
        let after: Vec<HistoryEntry> = before
            .iter()
            .filter(|entry| !ids.contains(&entry.id))
            .cloned()
            .collect();
        if after.len() != before.len() {
            self.write_raw(&after)?;
        }
        Ok(())
    }

    /// 同一条备份可能被多条记录引用（同一张图重压 N 次）。恢复的是那份真正原图，
    /// 所有这些记录的「已压缩」状态同时失效，必须一起标 Restored。
    fn siblings_sharing_backup(&self, entry: &HistoryEntry) -> Vec<String> {
        let _guard = self.lock.lock().unwrap();
        let Some(key) = backup_key_of(entry.backup_path.as_deref()) else {
            return vec![entry.id.clone()];
        };
        self.read_raw()
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

    /// 把备份原子地写回源路径，并处理跨格式输出的清理。
    /// 调用方负责沙盒访问；这里只做纯文件操作 + 历史记录状态更新。
    fn restore_backup_files(&self, entry: &HistoryEntry) -> Result<(), RestoreError> {
        let backup = entry
            .backup_path
            .as_ref()
            .map(PathBuf::from)
            .filter(|path| path.exists())
            .ok_or(RestoreError::BackupGone)?;
        let target = PathBuf::from(&entry.source_path);
        let parent = target.parent().ok_or_else(|| {
            RestoreError::Io("源文件路径无效".into())
        })?;
        let tmp = parent.join(format!(".octoshrink-restore-{}.tmp", now_nanos()));

        fs::copy(&backup, &tmp).map_err(|e| RestoreError::Io(e.to_string()))?;
        if fs::rename(&tmp, &target).is_err() {
            // 覆盖到一半失败时保留原目标文件，只清掉临时文件。
            let _ = fs::remove_file(&tmp);
            return Err(RestoreError::Io(
                "无法把原图写回目标位置".into(),
            ));
        }
        // 跨格式 replace（PNG → JPG）时压缩结果是个新文件，恢复后不该留下孤儿。
        if let Some(output) = entry.output_path.as_deref() {
            let output = Path::new(output);
            if output != target {
                let _ = fs::remove_file(output);
            }
        }
        Ok(())
    }

    /// 统一恢复入口：`restore_original` / `restore_history_entry` / `restore_all`
    /// 都走这里，避免三套逻辑对历史状态的处理不一致。
    ///
    /// `access` 负责在沙盒下临时取得目标位置的访问权（Direct 版直通），
    /// 守卫必须覆盖整个文件操作，返回即释放授权。
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
            self.restore_backup_files(entry)?;
            drop(_guard);
            if let Some(dir) = backup_dir {
                // 备份在 AppData 内，不需要沙盒授权。
                let _ = fs::remove_dir_all(dir);
            }
            self.mark_restored(&ids)
                .map_err(RestoreError::Io)?;
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

/// 备份 key = 备份目录名；目录名 = backups/<key>/original.<ext>。
fn backup_key_of(backup_path: Option<&str>) -> Option<String> {
    let dir = Path::new(backup_path?).parent()?;
    dir.file_name()?.to_str().map(str::to_owned)
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
    fn expired_entries_and_unreferenced_backups_are_dropped_at_startup() {
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

        let report = store.cleanup_expired(3);
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

        store.cleanup_expired(3);
        assert!(dir_of_backup(&backup).exists());
        assert_eq!(store.list().len(), 1);

        store.cleanup_expired(1);
        assert!(!dir_of_backup(&backup).exists());
        assert!(store.list().is_empty());
        assert!(source.exists());
    }

    #[test]
    fn not_retained_backups_survive_startup_because_they_may_be_the_only_original() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        // 三天前异常退出欠下的：0 档不按时间过期，这份备份可能还是唯一活着的原图。
        store
            .add(entry_for(&source, &backup, now_millis() - 3 * DAY_MILLIS))
            .unwrap();

        let report = store.cleanup_expired(0);
        assert_eq!(report.removed_entries, 0);
        assert!(
            dir_of_backup(&backup).exists(),
            "启动清理不许动还有人引用的原图备份"
        );
        assert_eq!(fs::read(&backup).unwrap(), b"true-original");
    }

    #[test]
    fn quitting_with_not_retained_clears_backups_but_keeps_the_history_rows() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        let source = sample_source(dir.path(), "a.png", b"true-original");
        let backup = store.ensure_backup(&source).unwrap();
        fs::write(&source, b"compressed").unwrap();
        store
            .add(entry_for(&source, &backup, now_millis()))
            .unwrap();

        let report = store.purge_backups_on_exit();
        assert_eq!(report.removed_backups, 1);
        assert!(!dir_of_backup(&backup).exists());

        // 历史条目是用户的压缩记录，不是原图：留着，只是不再可恢复。
        let rows = store.list();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].backup_path.is_none());
        assert!(!rows[0].backup_exists);
        assert!(source.exists(), "清理备份不能顺手删掉用户的压缩结果");

        let error = store
            .restore(&rows[0], true, open_access().as_ref(), &mut || false)
            .unwrap_err();
        assert!(matches!(error, RestoreError::BackupGone));
        assert_eq!(error.message(), "原图备份已清理，无法恢复");

        // 再退一次不许炸：已经没有备份可清了。
        assert_eq!(store.purge_backups_on_exit().removed_backups, 0);
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
    fn corrupt_history_file_reopens_as_empty_history() {
        let dir = tempfile::tempdir().unwrap();
        let store = store_in(dir.path());
        fs::write(store.history_path(), b"{ half-written").unwrap();
        assert!(store.list().is_empty());
        let source = sample_source(dir.path(), "a.png", b"x");
        let backup = store.ensure_backup(&source).unwrap();
        store.add(entry_for(&source, &backup, now_millis())).unwrap();
        assert_eq!(store.list().len(), 1);
    }
}
