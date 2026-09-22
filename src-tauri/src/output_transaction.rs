// OctoShrink - replace 模式的覆盖事务日志（crash journal）。
//
// 为什么需要它：backup 写完、压缩结果覆盖到用户文件上、`history.add` 还没跑 ——
// 就在这个窗口里崩溃或强杀，App 下次启动将完全不知道发生过这次压缩：
// 历史里没有记录，备份目录里躺着一份没人认领的原图，用户看到的却是压缩后的文件。
// transaction 文件就是那段时间的记账凭证：
//
//   ① ensure_backup  ② 写 transaction  ③ 临时文件写压缩结果
//   ④ flush + fsync  ⑤ rename 覆盖目标  ⑥ history.add
//   ⑦ 删 transaction
//
// 启动时凡是**不能被历史证明已完整提交**的事务，一律回滚成真正原图。
// 宁可丢掉一次压缩结果，也不能丢掉原图。

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::history::{now_millis, write_atomic, HistoryStore};

/// 一次 replace 覆盖的事务记录，落 `<appdata>/history/transactions/<id>.json`。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplaceTransaction {
    pub id: String,
    /// 与最终 `HistoryEntry.id` 同一个值：事务是否提交，就靠历史里有没有这个 id 判定。
    pub history_id: String,
    pub source_path: String,
    pub output_path: String,
    pub backup_path: String,
    #[serde(default)]
    pub temp_output_path: Option<String>,
    pub original_size: u64,
    pub expected_output_size: u64,
    pub created_at: i64,
    /// PNG → JPG 这类跨格式 replace：压缩结果是个新文件，回滚时要一并删掉。
    pub cross_format: bool,
}

pub const TRANSACTIONS_DIR: &str = "transactions";

#[derive(Debug, Default)]
pub struct RecoveryReport {
    /// 历史已记录，只是删日志前崩溃：补删日志。
    pub committed: usize,
    /// 回滚成真正原图的事务数。
    pub rolled_back: usize,
    pub warnings: Vec<String>,
}

pub struct TransactionStore {
    root: PathBuf,
}

impl TransactionStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    fn path_of(&self, id: &str) -> PathBuf {
        self.root.join(format!("{id}.json"))
    }

    /// 覆盖发生**之前**登记。写不进日志就不许覆盖 —— 没有记账凭证的覆盖等于不可恢复。
    pub fn prepare(&self, txn: &ReplaceTransaction) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|e| e.to_string())?;
        let json = serde_json::to_string(txn).map_err(|e| e.to_string())?;
        write_atomic(&self.path_of(&txn.id), json.as_bytes())
    }

    /// 事务已完整提交（历史也写成了）：销账。
    pub fn finish(&self, id: &str) {
        let _ = fs::remove_file(self.path_of(id));
    }

    pub fn list(&self) -> Vec<ReplaceTransaction> {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return Vec::new();
        };
        let mut found = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            match fs::read_to_string(&path)
                .ok()
                .and_then(|raw| serde_json::from_str::<ReplaceTransaction>(&raw).ok())
            {
                Some(txn) => found.push(txn),
                // 半个日志文件：无法判定它代表哪次覆盖，改名留下现场，绝不据此删任何东西。
                None => {
                    let _ = fs::rename(&path, path.with_extension("unparsed"));
                }
            }
        }
        found.sort_by_key(|txn| txn.created_at);
        found
    }

    pub fn has_pending(&self) -> bool {
        !self.list().is_empty()
    }

    /// 启动时第一件事：把上次没走完的事务结清。
    ///
    /// 判定只依赖一条事实 —— 历史里有没有这条 `history_id`。有则整条链路都走完了，
    /// 只欠删日志；没有则证明不了提交完成，一律回滚成真正原图。
    pub fn recover(&self, history: &HistoryStore) -> RecoveryReport {
        let mut report = RecoveryReport::default();
        for txn in self.list() {
            if history.contains_committed(&txn.history_id) {
                self.finish(&txn.id);
                report.committed += 1;
                continue;
            }
            match rollback(&txn) {
                Ok(()) => {
                    self.finish(&txn.id);
                    report.rolled_back += 1;
                }
                Err(error) => report
                    .warnings
                    .push(format!("{} 回滚失败，原图仍在备份里: {error}", txn.source_path)),
            }
        }
        report
    }
}

/// 用备份把真正原图写回源位置，再清掉这次生成的压缩结果。
///
/// 备份本身**不删**：回滚半途失败时它是唯一的原图副本，留给历史页/下次启动处理。
pub fn rollback(txn: &ReplaceTransaction) -> Result<(), String> {
    let backup = PathBuf::from(&txn.backup_path);
    let source = PathBuf::from(&txn.source_path);
    if !backup.exists() {
        return Err("备份已不存在，无法自动恢复原图".into());
    }
    HistoryStore::write_backup_back_to_source(&backup, &source)?;
    remove_generated_output(txn);
    Ok(())
}

/// 删掉这次压缩产生的新文件与临时文件。同格式 replace 的输出就是源文件本身，绝不删。
fn remove_generated_output(txn: &ReplaceTransaction) {
    let source = PathBuf::from(&txn.source_path);
    if txn.cross_format || !crate::history::same_file(&PathBuf::from(&txn.output_path), &source) {
        let _ = fs::remove_file(&txn.output_path);
    }
    if let Some(temp) = txn.temp_output_path.as_deref() {
        let _ = fs::remove_file(temp);
    }
}

/// 压缩结果的落盘：同目录临时文件 → flush + fsync → rename 覆盖目标。
///
/// 临时文件必须和目标同目录，否则 rename 跨挂载点就不是原子操作了。
pub struct StagedOutput {
    pub temp: PathBuf,
}

impl StagedOutput {
    pub fn write(target: &Path, bytes: &[u8]) -> Result<Self, String> {
        let parent = target.parent().unwrap_or(Path::new("."));
        let temp = parent.join(format!(".octoshrink-write-{}.tmp", now_millis()));
        let staged = Self { temp: temp.clone() };
        let outcome = (|| -> Result<(), String> {
            {
                use std::io::Write;
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&temp)
                    .map_err(|e| e.to_string())?;
                file.write_all(bytes).map_err(|e| e.to_string())?;
                file.flush().map_err(|e| e.to_string())?;
                // 落盘确认：崩溃后 rename 过去的不能是个只在内核缓存里的文件。
                file.sync_all().map_err(|e| e.to_string())?;
            }
            fs::rename(&temp, target).map_err(|e| e.to_string())
        })();
        if outcome.is_err() {
            staged.discard();
        }
        outcome.map(|_| staged)
    }

    /// 事后清理临时文件（正常情况下 rename 已经把它变成目标了）。
    pub fn discard(&self) {
        let _ = fs::remove_file(&self.temp);
    }

    #[cfg(test)]
    pub fn temp_exists(&self) -> bool {
        self.temp.exists()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::{HistoryStore, MAX_HISTORY_ENTRIES};

    fn stores(dir: &Path) -> (HistoryStore, TransactionStore) {
        let root = dir.join("history");
        fs::create_dir_all(root.join(crate::history::BACKUPS_DIR)).unwrap();
        (
            HistoryStore::new(root.clone()).unwrap(),
            TransactionStore::new(root.join(TRANSACTIONS_DIR)),
        )
    }

    fn txn(source: &Path, backup: &Path, history_id: &str) -> ReplaceTransaction {
        ReplaceTransaction {
            id: format!("t-{history_id}"),
            history_id: history_id.into(),
            source_path: source.to_string_lossy().into_owned(),
            output_path: source.to_string_lossy().into_owned(),
            backup_path: backup.to_string_lossy().into_owned(),
            temp_output_path: None,
            original_size: 100,
            expected_output_size: 10,
            created_at: now_millis(),
            cross_format: false,
        }
    }

    #[test]
    fn staged_write_replaces_the_target_and_leaves_no_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("a.png");
        fs::write(&target, b"old-bytes").unwrap();

        let staged = StagedOutput::write(&target, b"new").unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert!(!staged.temp_exists());
    }

    #[test]
    fn a_transaction_the_history_never_recorded_rolls_back_to_the_original() {
        let dir = tempfile::tempdir().unwrap();
        let (history, store) = stores(dir.path());
        let source = dir.path().join("a.png");
        fs::write(&source, b"true-original").unwrap();
        let backup = dir.path().join("original.png");
        fs::write(&backup, b"true-original").unwrap();

        // 崩溃现场：源文件已经是压缩结果，历史里却没有这条记录。
        fs::write(&source, b"compressed").unwrap();
        store.prepare(&txn(&source, &backup, "missing-from-history")).unwrap();

        let report = store.recover(&history);
        assert_eq!(report.rolled_back, 1);
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
        assert!(!store.has_pending());
        // 回滚靠的是备份，所以备份不能顺手删掉（回滚到一半失败时它是唯一副本）。
        assert!(backup.exists());
    }

    #[test]
    fn a_committed_transaction_only_needs_its_journal_removed() {
        let dir = tempfile::tempdir().unwrap();
        let (history, store) = stores(dir.path());
        let source = dir.path().join("a.png");
        fs::write(&source, b"compressed").unwrap();
        let backup = history.ensure_backup(&source).expect("backup");
        let entry = crate::history::sample_entry(&source, &backup, "committed-1");
        history.add(entry).unwrap();

        store.prepare(&txn(&source, &backup, "committed-1")).unwrap();
        let report = store.recover(&history);
        assert_eq!(report.committed, 1);
        assert_eq!(fs::read(&source).unwrap(), b"compressed");
        assert!(backup.exists(), "已提交的事务不许动用户文件");
        assert!(!store.has_pending());
    }

    #[test]
    fn cross_format_rollback_removes_the_converted_file_but_not_the_original() {
        let dir = tempfile::tempdir().unwrap();
        let (history, store) = stores(dir.path());
        let source = dir.path().join("photo.png");
        fs::write(&source, b"true-original").unwrap();
        let backup = dir.path().join("original.png");
        fs::write(&backup, b"true-original").unwrap();
        let output = dir.path().join("photo.jpg");
        fs::write(&output, b"converted").unwrap();

        let mut record = txn(&source, &backup, "gone");
        record.output_path = output.to_string_lossy().into_owned();
        record.cross_format = true;
        store.prepare(&record).unwrap();

        assert_eq!(store.recover(&history).rolled_back, 1);
        assert_eq!(fs::read(&source).unwrap(), b"true-original");
        assert!(!output.exists());
    }

    #[test]
    fn an_unparsable_journal_is_kept_and_rolls_back_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let (history, store) = stores(dir.path());
        fs::create_dir_all(&store.root).unwrap();
        fs::write(store.root.join("broken.json"), b"{ half").unwrap();
        let source = dir.path().join("a.png");
        fs::write(&source, b"compressed").unwrap();

        let report = store.recover(&history);
        assert_eq!(report.rolled_back, 0);
        assert_eq!(fs::read(&source).unwrap(), b"compressed");
        assert!(store.root.join("broken.unparsed").exists());
    }

    #[test]
    fn the_cap_only_ever_evicts_the_oldest_entries() {
        assert_eq!(MAX_HISTORY_ENTRIES, 10_000);
    }
}
