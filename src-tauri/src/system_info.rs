// 硬件 CPU 信息检测：只为「CPU 使用上限」提供展示数据与天花板。
//
// 语义边界：这里报的是"有多少份并行能力"，不是"绑哪几个核心"。
// 不做 CPU affinity —— Apple Silicon 的 P/E 调度归系统管，绑核反而干扰能耗决策。

use serde::Serialize;
use std::thread;

/// 检测到的 CPU 能力。`None` 表示该平台拿不到这项信息，UI 必须能容忍。
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuInfo {
    /// `std::env::consts::ARCH`：aarch64 / x86_64 / …
    ///
    /// 注意 aarch64 ≠ Apple Silicon（Windows、Linux 同样跑 ARM64），
    /// 判断是不是苹果芯片只能靠 `model_name`。
    pub architecture: String,
    pub logical_cpus: usize,
    pub physical_cpus: Option<usize>,
    pub performance_cpus: Option<usize>,
    pub efficiency_cpus: Option<usize>,
    pub model_name: Option<String>,
    /// `available_parallelism()`：进程实际该采用的并行度上限。
    ///
    /// 比硬件核数更可信 —— 虚拟机、容器、cgroup 都可能把进程可用 CPU 限得更小。
    pub available_parallelism: usize,
    /// 前端按这个字段决定要不要显示"性能核/能效核"和 Apple 专属文案，
    /// 不要让它自己从 `architecture` 猜（Windows/Linux 同样有 ARM64）。
    pub apple_silicon: bool,
}

impl CpuInfo {
    pub fn detect() -> Self {
        let available = available_parallelism();
        let architecture = std::env::consts::ARCH.to_string();
        let model_name = sysctl_string("machdep.cpu.brand_string");
        let apple_silicon = is_apple_silicon(&architecture, model_name.as_deref());
        Self {
            logical_cpus: sysctl_usize("hw.logicalcpu").unwrap_or(available),
            physical_cpus: sysctl_usize("hw.physicalcpu"),
            performance_cpus: performance_cpus(),
            efficiency_cpus: efficiency_cpus(),
            available_parallelism: available,
            architecture,
            model_name,
            apple_silicon,
        }
    }

    /// 用户可选上限的天花板：至少 1，否则设置里连"1 个 worker"都给不出。
    pub fn budget_ceiling(&self) -> usize {
        self.available_parallelism.max(1)
    }
}

/// 是不是苹果自研芯片只能看型号名 + 架构，不能只看 `aarch64`。
fn is_apple_silicon(architecture: &str, model: Option<&str>) -> bool {
    architecture == "aarch64" && model.is_some_and(|name| name.starts_with("Apple "))
}

/// `get_cpu_info` 的返回体：硬件事实 + 用户配置 + 本机真正生效值。
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CpuStatus {
    #[serde(flatten)]
    pub info: CpuInfo,
    /// `None` = 自动。
    pub configured_limit: Option<usize>,
    pub effective_limit: usize,
}

fn available_parallelism() -> usize {
    // 官方定义就是"当前程序应当采用的并行度估计值"，比自己数核更靠谱。
    thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}

/// 性能核数量。只有大小核架构（`hw.nperflevels > 1`）才有意义。
fn performance_cpus() -> Option<usize> {
    if perf_levels()? <= 1 {
        return None;
    }
    sysctl_usize("hw.perflevel0.physicalcpu")
}

/// 能效核数量：perflevel1 往后全部算进去（Apple 目前只有两级）。
fn efficiency_cpus() -> Option<usize> {
    let levels = perf_levels()?;
    if levels <= 1 {
        return None;
    }
    let counts: Vec<usize> = (1..levels)
        .filter_map(|level| sysctl_usize(&format!("hw.perflevel{level}.physicalcpu")))
        .collect();
    (!counts.is_empty()).then(|| counts.iter().sum())
}

fn perf_levels() -> Option<usize> {
    sysctl_usize("hw.nperflevels")
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{c_void, CString};
    use std::mem::MaybeUninit;

    extern "C" {
        fn sysctlbyname(
            name: *const i8,
            oldp: *mut c_void,
            oldlenp: *mut usize,
            newp: *mut c_void,
            newlen: usize,
        ) -> i32;
    }

    /// 先问长度，再按长度读；int32 / int64 都能容纳，负值（未知 -1）当作 None。
    pub fn sysctl_usize(name: &str) -> Option<usize> {
        let name = CString::new(name).ok()?;
        let mut len = 0usize;
        let query =
            unsafe { sysctlbyname(name.as_ptr(), std::ptr::null_mut(), &mut len, std::ptr::null_mut(), 0) };
        if query != 0 || len == 0 || len > 8 {
            return None;
        }
        let mut buf = MaybeUninit::<[u8; 8]>::uninit();
        let read = unsafe {
            sysctlbyname(name.as_ptr(), buf.as_mut_ptr() as *mut c_void, &mut len, std::ptr::null_mut(), 0)
        };
        if read != 0 {
            return None;
        }
        let bytes = unsafe { buf.assume_init() };
        let value = match len {
            4 => i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as i64,
            8 => i64::from_le_bytes(bytes),
            _ => return None,
        };
        if value < 0 {
            None
        } else {
            Some(value as usize)
        }
    }

    pub fn sysctl_string(name: &str) -> Option<String> {
        let name = CString::new(name).ok()?;
        let mut len = 0usize;
        let query =
            unsafe { sysctlbyname(name.as_ptr(), std::ptr::null_mut(), &mut len, std::ptr::null_mut(), 0) };
        if query != 0 || len <= 1 {
            return None;
        }
        let mut buf = vec![0u8; len];
        let read = unsafe {
            sysctlbyname(
                name.as_ptr(),
                buf.as_mut_ptr() as *mut c_void,
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if read != 0 {
            return None;
        }
        buf.truncate(len);
        // sysctl 字符串带结尾 NUL，截掉再判空。
        while buf.last() == Some(&0) {
            buf.pop();
        }
        let text = String::from_utf8_lossy(&buf).trim().to_string();
        (!text.is_empty()).then_some(text)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    /// Windows / Linux 只依赖 `available_parallelism()`：
    /// 各家的物理核、P/E 核口径不一致，宁可不显示也不显示错。
    pub fn sysctl_usize(_name: &str) -> Option<usize> {
        None
    }

    pub fn sysctl_string(_name: &str) -> Option<String> {
        None
    }
}

use imp::{sysctl_string, sysctl_usize};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detection_never_returns_zero_parallelism() {
        let cpu = CpuInfo::detect();
        assert!(cpu.available_parallelism >= 1);
        assert!(cpu.logical_cpus >= 1);
        assert!(!cpu.architecture.is_empty());
        assert!(cpu.budget_ceiling() >= 1);
    }

    #[test]
    fn core_breakdown_never_exceeds_physical_cores() {
        let cpu = CpuInfo::detect();
        if let (Some(physical), Some(p), Some(e)) =
            (cpu.physical_cpus, cpu.performance_cpus, cpu.efficiency_cpus)
        {
            assert!(p + e <= physical.max(p.max(e)));
        }
    }

    #[test]
    fn arm64_is_not_guessed_to_be_apple_silicon() {
        assert!(is_apple_silicon("aarch64", Some("Apple M5")));
        // Windows on ARM / Linux on ARM：同为 aarch64，绝不能显示成 Apple Silicon。
        assert!(!is_apple_silicon("aarch64", Some("Snapdragon X Elite")));
        assert!(!is_apple_silicon("aarch64", None));
        assert!(!is_apple_silicon("x86_64", Some("Intel Core i7")));
    }

    #[test]
    fn detection_reports_whether_this_machine_is_apple_silicon() {
        let cpu = CpuInfo::detect();
        assert_eq!(
            cpu.apple_silicon,
            is_apple_silicon(&cpu.architecture, cpu.model_name.as_deref())
        );
    }

    #[test]
    fn status_serializes_with_camel_case_and_flattened_fields() {
        let status = CpuStatus {
            info: CpuInfo {
                architecture: "x86_64".into(),
                logical_cpus: 12,
                physical_cpus: Some(6),
                performance_cpus: None,
                efficiency_cpus: None,
                model_name: Some("Intel Core i7".into()),
                available_parallelism: 12,
                apple_silicon: false,
            },
            configured_limit: Some(4),
            effective_limit: 4,
        };
        let json: serde_json::Value = serde_json::to_value(&status).unwrap();
        assert_eq!(json["architecture"], "x86_64");
        assert_eq!(json["physicalCpus"], 6);
        assert_eq!(json["availableParallelism"], 12);
        assert_eq!(json["configuredLimit"], 4);
        assert_eq!(json["effectiveLimit"], 4);
        // Intel 没有大小核，字段必须是 null 而不是被省掉。
        assert!(json["performanceCpus"].is_null());
    }
}
