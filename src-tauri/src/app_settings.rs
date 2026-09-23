// OctoShrink - backend-persisted app settings.
//
// 保留天数必须在后端可读，因为清理挂在正常退出上（`RunEvent::Exit`），
// 那一刻前端可能已经不存在，localStorage 不可用。

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// `0` = **不保留**（默认档位）：覆盖原文件前照样先写备份，跑完正常退出时清干净。
///
/// 这一档不按时间过期 —— 崩溃 / 强杀留下的那份备份可能就是唯一还活着的原图，
/// 启动时只能清掉没人引用的，等下一次正常退出再一并清。
pub const KEEP_UNTIL_QUIT: u32 = 0;
pub const DEFAULT_RETENTION_DAYS: u32 = KEEP_UNTIL_QUIT;
pub const MIN_RETENTION_DAYS: u32 = 1;
pub const MAX_RETENTION_DAYS: u32 = 30;

/// 「自动」在第一阶段的取值：`min(3, 本机可用并行度)`。
///
/// 故意不默认"全部核心"：这个功能存在的意义就是压图的同时电脑还能正常干活。
pub const AUTO_CPU_PARALLELISM: usize = 3;

fn default_retention_days() -> u32 {
    DEFAULT_RETENTION_DAYS
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    /// OctoShrink 自己保存的原图备份保留多久；与用户真实文件无关。
    /// `0`（[`KEEP_UNTIL_QUIT`]）= 不保留，正常退出时清理。
    #[serde(default = "default_retention_days")]
    pub original_retention_days: u32,
    /// `None` = 自动。设置存的是用户的选择本身，不预先裁剪，
    /// 换到核心更少的机器时仍旧照常工作（见 `effective_cpu_limit`）。
    #[serde(default)]
    pub cpu_thread_limit: Option<usize>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            original_retention_days: DEFAULT_RETENTION_DAYS,
            cpu_thread_limit: None,
        }
    }
}

/// 自动模式下本机应该给压缩多少份并行能力。
pub fn auto_cpu_limit(detected: usize) -> usize {
    detected.min(AUTO_CPU_PARALLELISM).max(1)
}

/// 真正生效的上限：配置值缺失按自动，再夹进 `[1, 本机可用并行度]`。
///
/// 老电脑 16 核设成 12、换到 8 核新电脑 → 生效 8，不是报错也不是 12。
pub fn effective_cpu_limit(configured: Option<usize>, detected: usize) -> usize {
    let ceiling = detected.max(1);
    configured
        .unwrap_or_else(|| auto_cpu_limit(ceiling))
        .clamp(1, ceiling)
}

pub struct SettingsStore {
    path: PathBuf,
}

impl SettingsStore {
    pub fn new(root: &Path) -> Self {
        Self {
            path: root.join("settings.json"),
        }
    }

    /// 读取失败或文件不存在都按默认值处理：老版本升级上来不能崩。
    pub fn load(&self) -> AppSettings {
        let raw = match fs::read_to_string(&self.path) {
            Ok(raw) => raw,
            Err(_) => return AppSettings::default(),
        };
        let parsed = serde_json::from_str::<AppSettings>(&raw)
            .ok()
            .unwrap_or_default();
        AppSettings {
            original_retention_days: clamp_retention(parsed.original_retention_days),
            cpu_thread_limit: parsed.cpu_thread_limit.filter(|n| *n >= 1),
        }
    }

    pub fn save(&self, settings: &AppSettings) -> Result<(), String> {
        let json = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
        crate::history::write_atomic(&self.path, json.as_bytes())
    }

    pub fn set_retention_days(&self, days: u32) -> Result<AppSettings, String> {
        // 0 是合法档位（不保留），只有超出上界才拒绝。
        if days > MAX_RETENTION_DAYS {
            return Err(format!("保留天数最多 {MAX_RETENTION_DAYS} 天"));
        }
        // 读-改-写：设置项会越来越多，绝不能因为改一项把别的项抹平。
        let mut settings = self.load();
        settings.original_retention_days = days;
        self.save(&settings)?;
        Ok(settings)
    }

    /// `None` 表示"自动"，与 settings.json 里的 `"cpuThreadLimit": null` 同义。
    pub fn set_cpu_thread_limit(&self, limit: Option<usize>) -> Result<AppSettings, String> {
        if limit == Some(0) {
            return Err("CPU 上限至少为 1".into());
        }
        let mut settings = self.load();
        settings.cpu_thread_limit = limit;
        self.save(&settings)?;
        Ok(settings)
    }
}

fn clamp_retention(days: u32) -> u32 {
    // 「不保留」是一个真实档位，不是"没设置"：clamp 到 1 天会把它悄悄变成保留 1 天。
    if days == KEEP_UNTIL_QUIT {
        return KEEP_UNTIL_QUIT;
    }
    days.clamp(MIN_RETENTION_DAYS, MAX_RETENTION_DAYS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_corrupt_settings_fall_back_to_the_default() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(dir.path());
        assert_eq!(store.load().original_retention_days, DEFAULT_RETENTION_DAYS);

        fs::write(store.path.as_path(), "not json").unwrap();
        assert_eq!(store.load().original_retention_days, DEFAULT_RETENTION_DAYS);
    }

    #[test]
    fn retention_is_persisted_and_clamped_out_of_range_values() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(dir.path());
        assert_eq!(store.set_retention_days(14).unwrap().original_retention_days, 14);
        assert_eq!(store.load().original_retention_days, 14);
        // 0 = 不保留，是真实档位而不是"没设"，必须能存住。
        assert_eq!(store.set_retention_days(0).unwrap().original_retention_days, 0);
        assert_eq!(store.load().original_retention_days, 0);
        assert!(store.set_retention_days(31).is_err());

        fs::write(store.path.as_path(), r#"{"originalRetentionDays":9000}"#).unwrap();
        assert_eq!(store.load().original_retention_days, MAX_RETENTION_DAYS);
        fs::write(store.path.as_path(), r#"{"originalRetentionDays":0}"#).unwrap();
        assert_eq!(store.load().original_retention_days, KEEP_UNTIL_QUIT);
    }

    #[test]
    fn auto_limit_leaves_headroom_instead_of_grabbing_every_core() {
        assert_eq!(auto_cpu_limit(2), 2);
        assert_eq!(auto_cpu_limit(8), AUTO_CPU_PARALLELISM);
        assert_eq!(auto_cpu_limit(64), AUTO_CPU_PARALLELISM);
        assert_eq!(auto_cpu_limit(0), 1);
    }

    #[test]
    fn moving_to_a_smaller_machine_shrinks_the_limit_instead_of_failing() {
        assert_eq!(effective_cpu_limit(Some(12), 16), 12);
        assert_eq!(effective_cpu_limit(Some(12), 8), 8);
        assert_eq!(effective_cpu_limit(None, 10), AUTO_CPU_PARALLELISM);
        assert_eq!(effective_cpu_limit(Some(0), 4), 1);
        assert_eq!(effective_cpu_limit(Some(4), 0), 1);
    }

    #[test]
    fn cpu_limit_persists_and_changing_one_setting_keeps_the_other() {
        let dir = tempfile::tempdir().unwrap();
        let store = SettingsStore::new(dir.path());

        assert_eq!(store.load().cpu_thread_limit, None);
        assert_eq!(store.set_cpu_thread_limit(Some(4)).unwrap().cpu_thread_limit, Some(4));
        assert_eq!(store.load().cpu_thread_limit, Some(4));

        // 改保留天数不能把 CPU 设置抹掉（settings.json 只有一份）。
        store.set_retention_days(7).unwrap();
        let after = store.load();
        assert_eq!(after.original_retention_days, 7);
        assert_eq!(after.cpu_thread_limit, Some(4));

        store.set_cpu_thread_limit(None).unwrap();
        assert_eq!(store.load().cpu_thread_limit, None);
        let raw = fs::read_to_string(store.path.as_path()).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert!(parsed["cpuThreadLimit"].is_null(), "{raw}");
        assert!(store.set_cpu_thread_limit(Some(0)).is_err());
    }
}
