//! 缩小版真实图内存压测：仅 App Store 进程内引擎（feature = inproc-backends），手动运行。
//!
//! 由 `scripts/memory_stress.sh` 生成多格式样本并驱动；也可以单独跑：
//!
//! ```text
//! OCTOSHRINK_STRESS_DIR=<样本目录> cargo test --manifest-path src-tauri/Cargo.toml \
//!   --release --features appstore --no-default-features --lib memory_stress \
//!   -- --ignored --nocapture
//! ```
//!
//! 按与 `compress_batch` 相同的闸门语义逐批推进（估算工作集 → `acquire_with_memory`
//! → 有界 JoinSet 收割 → 丢弃本轮结果，只留计数），观察三批 phys_footprint 是否收敛，
//! 并断言闸门没有放行超预算的并发与估算内存。

use crate::app_settings::effective_cpu_limit;
use crate::commands::{AcquireOutcome, CompressionScheduler};
use crate::system_info::CpuInfo;
use crate::{engine, memory_budget};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const BATCHES: usize = 3;
const SAMPLE_INTERVAL: Duration = Duration::from_millis(50);
/// 队列清空后的短时空闲观察（验收清单第 4 项「5 分钟」的缩小版）。
const IDLE_OBSERVATION: Duration = Duration::from_secs(30);
const MIB: f64 = 1_048_576.0;

// ── phys_footprint：与 Swift 自检同一口径（task_vm_info.phys_footprint） ──

extern "C" {
    fn task_info(task: u32, flavor: u32, info: *mut i32, count: *mut u32) -> i32;
    static mach_task_self_: u32;
}

/// TASK_VM_INFO 的**别名值**随 SDK 演进：旧头文件是 20，当前 macOS 27 SDK 是 22。
/// 实测 20 在这台机器上落到另一个 12 字长的口味（TASK_BASIC_INFO_64 形状，
/// status=0 但 resident/footprint 全错位）—— 所以必须用 count_out 校验：
/// struct 只追加字段、已有偏移稳定，只要内核真填了覆盖目标字段的字节数，读数才可信。
const TASK_VM_INFO_FLAVORS: [u32; 2] = [22, 20];
/// task_vm_info_data_t 只在**尾部**追加字段，已有字段偏移是稳定 ABI（C probe 实证）。
/// 读数是否可信不靠注释背书：`footprint_reading_is_trustworthy` 会真分配内存验证。
const RESIDENT_SIZE_OFFSET: usize = 16;
const PHYS_FOOTPRINT_OFFSET: usize = 144;

fn read_task_vm_info(offset: usize) -> Option<u64> {
    let mut buffer = [0i32; 256];
    let bytes_needed = offset + 8;
    for flavor in TASK_VM_INFO_FLAVORS {
        let mut count = buffer.len() as u32;
        let status =
            unsafe { task_info(mach_task_self_, flavor, buffer.as_mut_ptr(), &mut count) };
        // 内核回填的字数必须覆盖目标字段；短口味（错的 flavor）在这里被排除。
        if status != 0 || (count as usize) * 4 < bytes_needed {
            continue;
        }
        let bytes =
            unsafe { std::slice::from_raw_parts(buffer.as_ptr().cast::<u8>(), buffer.len() * 4) };
        return Some(u64::from_ne_bytes(bytes[offset..offset + 8].try_into().ok()?));
    }
    None
}

fn phys_footprint_bytes() -> Option<u64> {
    read_task_vm_info(PHYS_FOOTPRINT_OFFSET)
}

/// 手写偏移必须自证：触碰 96 MiB 后 phys_footprint 应至少上涨 48 MiB。
/// 读到垃圾就返回 false，压测直接失败，绝不报假数。
fn footprint_reading_is_trustworthy() -> bool {
    let resident = read_task_vm_info(RESIDENT_SIZE_OFFSET).unwrap_or(0);
    let Some(before) = phys_footprint_bytes() else {
        eprintln!("[stress] 自检失败：TASK_VM_INFO 读不出来（flavors {TASK_VM_INFO_FLAVORS:?} 都不可用）");
        return false;
    };
    if resident < 1024 * 1024 {
        eprintln!("[stress] 自检失败：resident={resident} 小于 1 MiB，读数可疑");
        return false;
    }
    let mut probe = vec![0u8; 96 * 1024 * 1024];
    // volatile 写入：普通循环曾在优化构建里整段被消除（实测 growth=0），
    // 触碰循环被消掉 = 页面没真提交，自检就变成假阴性。
    unsafe {
        let ptr = probe.as_mut_ptr();
        for offset in (0..probe.len()).step_by(4096) {
            std::ptr::write_volatile(ptr.add(offset), 1u8);
        }
    }
    let after = phys_footprint_bytes().unwrap_or(before);
    let growth = after.saturating_sub(before);
    drop(probe);
    if growth < 48 * 1024 * 1024 {
        eprintln!(
            "[stress] 自检失败：触碰 96 MiB 后 footprint 只涨了 {:.1} MiB（before={before} after={after}）",
            growth as f64 / MIB
        );
        return false;
    }
    true
}

/// 后台采样：批内 footprint 峰值 + 闸门实际放行的最大并发 / 最大预留估算。
struct GateSampler {
    stop: Arc<AtomicBool>,
    peak_footprint: Arc<AtomicU64>,
    max_active: Arc<AtomicUsize>,
    max_reserved: Arc<AtomicU64>,
}

impl GateSampler {
    fn start(scheduler: Arc<CompressionScheduler>) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let peak_footprint = Arc::new(AtomicU64::new(0));
        let max_active = Arc::new(AtomicUsize::new(0));
        let max_reserved = Arc::new(AtomicU64::new(0));
        let thread_state = (
            stop.clone(),
            peak_footprint.clone(),
            max_active.clone(),
            max_reserved.clone(),
        );
        std::thread::spawn(move || {
            let (stop, peak, active, reserved) = thread_state;
            while !stop.load(Ordering::Acquire) {
                if let Some(value) = phys_footprint_bytes() {
                    peak.fetch_max(value, Ordering::AcqRel);
                }
                active.fetch_max(scheduler.active(), Ordering::AcqRel);
                reserved.fetch_max(scheduler.active_memory_bytes(), Ordering::AcqRel);
                std::thread::sleep(SAMPLE_INTERVAL);
            }
        });
        Self { stop, peak_footprint, max_active, max_reserved }
    }

    /// 批次开始时把峰值地板重置到当下读数，批内峰值才是"这一批造成的"。
    fn reset_peak(&self) {
        if let Some(value) = phys_footprint_bytes() {
            self.peak_footprint.store(value, Ordering::Release);
        }
    }

    fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    fn peak_mib(&self) -> f64 {
        self.peak_footprint.load(Ordering::Acquire) as f64 / MIB
    }
}

#[derive(Default)]
struct BatchStats {
    succeeded: usize,
    failed: usize,
    input_bytes: u64,
    output_bytes: u64,
}

async fn reap(
    tasks: &mut tokio::task::JoinSet<(PathBuf, engine::EngineResult)>,
    stats: &mut BatchStats,
) {
    let Some(joined) = tasks.join_next().await else {
        return;
    };
    match joined {
        Ok((path, result)) => {
            if result.success {
                stats.succeeded += 1;
            } else {
                stats.failed += 1;
                eprintln!("[stress] 压缩失败 {}: {:?}", path.display(), result.error);
            }
            stats.input_bytes += std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);
            stats.output_bytes += result.compressed.len() as u64;
            // result.compressed 在这里离开作用域：与生产一致，不让编码字节驻留到下一批。
        }
        Err(error) => {
            stats.failed += 1;
            eprintln!("[stress] 压缩任务 panic: {error}");
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "手动压测：需要 OCTOSHRINK_STRESS_DIR 指向样本目录（scripts/memory_stress.sh 会准备好）"]
async fn memory_stress_inproc_three_batches() {
    let Ok(dir) = std::env::var("OCTOSHRINK_STRESS_DIR") else {
        eprintln!("[stress] 跳过：未设置 OCTOSHRINK_STRESS_DIR");
        return;
    };
    let dir = PathBuf::from(dir);
    assert!(dir.is_dir(), "[stress] 样本目录不存在: {}", dir.display());
    assert!(
        footprint_reading_is_trustworthy(),
        "[stress] phys_footprint 自检失败：task_vm_info 偏移不可信，拒绝报数"
    );

    let mut samples: Vec<PathBuf> = std::fs::read_dir(&dir)
        .expect("[stress] 读样本目录")
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.is_file()
                && matches!(
                    path.extension()
                        .and_then(|ext| ext.to_str())
                        .map(str::to_ascii_lowercase)
                        .as_deref(),
                    Some("png" | "jpg" | "jpeg" | "webp" | "gif")
                )
        })
        .collect();
    samples.sort();
    assert!(!samples.is_empty(), "[stress] 样本目录里没有可压缩的样本");

    let largest_estimate = samples
        .iter()
        .map(|path| memory_budget::estimate_working_set(path))
        .max()
        .unwrap_or(0);
    let budget = memory_budget::budget_bytes();
    let parallelism = effective_cpu_limit(None, CpuInfo::detect().budget_ceiling());
    let scheduler = Arc::new(CompressionScheduler::new(parallelism));
    let options = Arc::new(engine::CompressOptions::default());
    let sampler = GateSampler::start(scheduler.clone());

    println!(
        "[stress] 样本 {} 个（最大估算 {:.0} MiB），自动档并发上限 {}，内存预算 {:.0} MiB",
        samples.len(),
        largest_estimate as f64 / MIB,
        parallelism,
        budget as f64 / MIB
    );

    for batch in 1..=BATCHES {
        scheduler.begin_batch();
        sampler.reset_peak();
        let started = Instant::now();
        let mut tasks = tokio::task::JoinSet::new();
        let mut stats = BatchStats::default();
        let max_in_flight = scheduler.max_parallelism();
        for path in &samples {
            let estimate = memory_budget::estimate_working_set(path);
            let permit = match scheduler.acquire_with_memory(estimate, || false).await {
                AcquireOutcome::Acquired(permit) => permit,
                AcquireOutcome::Cancelled | AcquireOutcome::Stopped => {
                    panic!("[stress] 无人取消 / 停止，闸门不应返回 Cancelled / Stopped")
                }
            };
            while tasks.len() >= max_in_flight {
                reap(&mut tasks, &mut stats).await;
            }
            let path = path.clone();
            let options = options.clone();
            tasks.spawn(async move {
                let _permit = permit;
                let result = engine::compress_smart(&path, &options).await;
                (path, result)
            });
        }
        while !tasks.is_empty() {
            reap(&mut tasks, &mut stats).await;
        }
        scheduler.end_batch();
        let after = phys_footprint_bytes().unwrap_or(0);
        println!(
            "[stress] 批 {batch}: 用时 {:.1}s 成功 {} 失败 {} 输入合计 {:.1} MiB 输出合计 {:.1} MiB | 批后 {:.1} MiB · 批内峰值 {:.1} MiB",
            started.elapsed().as_secs_f64(),
            stats.succeeded,
            stats.failed,
            stats.input_bytes as f64 / MIB,
            stats.output_bytes as f64 / MIB,
            after as f64 / MIB,
            sampler.peak_mib(),
        );
        assert_eq!(
            stats.succeeded + stats.failed,
            samples.len(),
            "[stress] 每批必须逐一处理全部样本"
        );
    }

    // 队列清空后的短时空闲观察（缩小版：30 s，对应验收清单第 4 项）。
    let idle_baseline = phys_footprint_bytes().unwrap_or(0);
    tokio::time::sleep(IDLE_OBSERVATION).await;
    let idle_after = phys_footprint_bytes().unwrap_or(0);
    sampler.stop();
    println!(
        "[stress] 空闲观察 {}s：开始 {:.1} MiB → 结束 {:.1} MiB",
        IDLE_OBSERVATION.as_secs(),
        idle_baseline as f64 / MIB,
        idle_after as f64 / MIB
    );

    let max_active = sampler.max_active.load(Ordering::Acquire);
    let max_reserved = sampler.max_reserved.load(Ordering::Acquire);
    println!(
        "[stress] 闸门观测：最大并发 {}（上限 {}）· 最大预留估算 {:.0} MiB（预算 {:.0} MiB）",
        max_active,
        parallelism,
        max_reserved as f64 / MIB,
        budget as f64 / MIB
    );
    assert!(max_active <= parallelism, "[stress] CPU 闸门放行超过上限的并发");
    assert!(
        max_reserved <= budget.max(largest_estimate),
        "[stress] 内存闸门放行超过预算的估算字节"
    );

    // AVIF 输入探测：不进轮转，单独记录这条线的既有行为。
    if let Some(avif) = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .find(|path| {
            path.extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("avif"))
        })
    {
        let result = engine::compress_smart(&avif, &options).await;
        println!(
            "[stress] AVIF 输入探测: success={} algorithm={} out_type={} 产物 {:.1} KiB / 原图 {:.1} KiB error={:?}",
            result.success,
            result.algorithm,
            result.out_type,
            result.compressed.len() as f64 / 1024.0,
            std::fs::metadata(&avif).map(|meta| meta.len()).unwrap_or(0) as f64 / 1024.0,
            result.error,
        );
    }
}
