// OctoShrink - Tauri command handlers (replaces Electron IPC)

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_dialog::DialogExt;

use crate::engine::{self, CompressOptions, CompressResult, EngineResult};

/// Shared app state.
pub struct AppState {
    pub cancel_queue: Mutex<HashSet<String>>,
}

// ─── Progress event payload ─────────────────────────────────────
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ProgressPayload {
    total: usize,
    current: usize,
    file: String,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<CompressResult>,
}

// ─── File collection ────────────────────────────────────────────
fn collect_image_files(file_paths: &[String]) -> Vec<String> {
    let exts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "jxl"];
    let mut all = Vec::new();
    for fp in file_paths {
        let path = PathBuf::from(fp);
        if path.is_dir() {
            walk_dir(&path, &exts, &mut all);
        } else if path.is_file() {
            if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                if exts.contains(&ext.to_lowercase().as_str()) {
                    all.push(fp.clone());
                }
            }
        }
    }
    all
}

fn walk_dir(dir: &Path, exts: &[&str], out: &mut Vec<String>) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk_dir(&path, exts, out);
            } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                if exts.contains(&ext.to_lowercase().as_str()) {
                    out.push(path.to_string_lossy().into_owned());
                }
            }
        }
    }
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

fn base64_url_name(path: &Path) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(path.to_string_lossy().as_bytes())
}

/// Write the compressed bytes to disk according to the output mode.
fn write_output_file(
    result: &mut CompressResult,
    file_path: &Path,
    compressed: &[u8],
    file_paths: &[String],
    options: &CompressOptions,
) {
    if !result.success || compressed.is_empty() {
        return;
    }
    // 如果压缩后体积没有变小，不写入文件（原图已是最优）
    if (compressed.len() as u64) >= result.original_size {
        result.error = Some("原图已是最优，无需替换".into());
        return;
    }
    let out_ext = format!(".{}", result.out_type);
    let out_path: Option<PathBuf> = match options.output_mode.as_str() {
        "replace" => {
            let backup_dir = std::env::temp_dir().join("octoshrink-backups");
            let _ = fs::create_dir_all(&backup_dir);
            let backup_path = backup_dir.join(base64_url_name(file_path));
            if !backup_path.exists() {
                let _ = fs::copy(file_path, &backup_path);
            }
            result.backup_path = Some(backup_path.to_string_lossy().into());
            Some(file_path.to_path_buf())
        }
        "suffix" => {
            let stem = file_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("file");
            let dir = file_path.parent().unwrap_or(Path::new("."));
            Some(dir.join(format!("{}_compressed{}", stem, out_ext)))
        }
        "folder" => {
            if let Some(ref out_dir) = options.output_dir {
                let root = if file_paths.len() == 1 && PathBuf::from(&file_paths[0]).is_dir() {
                    PathBuf::from(&file_paths[0])
                } else {
                    file_path
                        .parent()
                        .unwrap_or(Path::new("."))
                        .to_path_buf()
                };
                let rel = file_path.strip_prefix(&root).unwrap_or(file_path);
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

    if let Some(out_path) = out_path {
        if fs::write(&out_path, compressed).is_ok() {
            result.output_path = Some(out_path.to_string_lossy().into());
            result.output_mode = Some(options.output_mode.clone());
        }
    }
}

// ─── Batch compression core ─────────────────────────────────────
async fn compress_batch(
    app: &AppHandle,
    state: &AppState,
    file_paths: Vec<String>,
    options: CompressOptions,
    use_smart: bool,
) -> Vec<CompressResult> {
    state.cancel_queue.lock().unwrap().clear();
    let all_files = collect_image_files(&file_paths);
    let total = all_files.len();
    let _results: Vec<CompressResult> = Vec::new();

    // Emit "queued" for all files
    for fp in &all_files {
        let _ = app.emit(
            "compress-progress",
            ProgressPayload {
                total,
                current: 0,
                file: fp.clone(),
                status: "queued".into(),
                result: None,
            },
        );
    }

    // 3 线程并发压缩
    use std::sync::Arc;
    use tokio::sync::Mutex;

    let options = Arc::new(options);
    let file_paths_arc = Arc::new(file_paths);
    let app_arc = Arc::new(app.clone());
    let cancel_queue = &state.cancel_queue;
    let results_arc = Arc::new(Mutex::new(Vec::<CompressResult>::new()));
    let processed_arc = Arc::new(Mutex::new(0usize));
    let skipped_arc = Arc::new(Mutex::new(0usize));

    // 信号量限制并发数为 3
    let semaphore = Arc::new(tokio::sync::Semaphore::new(3));

    let mut handles = Vec::new();
    for file_path in all_files {
        // Check cancellation
        let cancelled = {
            let mut cq = cancel_queue.lock().unwrap();
            if cq.contains(&file_path) {
                cq.remove(&file_path);
                true
            } else {
                false
            }
        };
        if cancelled {
            let mut sk = skipped_arc.lock().await;
            *sk += 1;
            let mut pr = processed_arc.lock().await;
            *pr += 1;
            let _ = app_arc.emit(
                "compress-progress",
                ProgressPayload {
                    total: total - *sk,
                    current: *pr,
                    file: file_path.clone(),
                    status: "cancelled".into(),
                    result: None,
                },
            );
            continue;
        }

        // Emit "starting"
        {
            let pr = processed_arc.lock().await;
            let sk = skipped_arc.lock().await;
            let _ = app_arc.emit(
                "compress-progress",
                ProgressPayload {
                    total: total - *sk,
                    current: *pr,
                    file: file_path.clone(),
                    status: "starting".into(),
                    result: None,
                },
            );
        }

        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let opts = options.clone();
        let fps = file_paths_arc.clone();
        let app_c = app_arc.clone();
        let results_c = results_arc.clone();
        let processed_c = processed_arc.clone();
        let skipped_c = skipped_arc.clone();
        let fp = file_path.clone();

        handles.push(tokio::spawn(async move {
            let _permit = permit; // 持有信号量直到压缩完成

            let path = PathBuf::from(&fp);
            let engine_result = if use_smart {
                engine::compress_smart(&path, &opts).await
            } else {
                engine::compress_image(&path, &opts).await
            };

            let mut result = build_result(&fp, &engine_result);
            write_output_file(&mut result, &path, &engine_result.compressed, &fps, &opts);

            {
                let mut pr = processed_c.lock().await;
                *pr += 1;
                let sk = *skipped_c.lock().await;
                let _ = app_c.emit(
                    "compress-progress",
                    ProgressPayload {
                        total: total - sk,
                        current: *pr,
                        file: fp.clone(),
                        status: "".into(),
                        result: Some(result.clone()),
                    },
                );
            }

            let mut res = results_c.lock().await;
            res.push(result);
        }));
    }

    // 等待所有任务完成
    for handle in handles {
        let _ = handle.await;
    }

    state.cancel_queue.lock().unwrap().clear();
    let final_results = results_arc.lock().await.clone();
    final_results
}

// ─── Tauri commands ─────────────────────────────────────────────

#[tauri::command]
pub async fn select_files(app: AppHandle) -> Result<Vec<String>, String> {
    let files = app
        .dialog()
        .file()
        .add_filter("Images", &["png", "jpg", "jpeg", "gif", "webp", "bmp"])
        .blocking_pick_files();
    Ok(files
        .unwrap_or_default()
        .into_iter()
        .filter_map(|fp| fp.into_path().ok().map(|p| p.to_string_lossy().into_owned()))
        .collect())
}

#[tauri::command]
pub async fn select_folder(app: AppHandle) -> Result<Vec<String>, String> {
    let folder = app.dialog().file().blocking_pick_folder();
    Ok(folder
        .into_iter()
        .filter_map(|fp| fp.into_path().ok().map(|p| p.to_string_lossy().into_owned()))
        .collect())
}

#[tauri::command]
pub async fn select_output_dir(app: AppHandle) -> Result<Vec<String>, String> {
    let folder = app.dialog().file().blocking_pick_folder();
    Ok(folder
        .into_iter()
        .filter_map(|fp| fp.into_path().ok().map(|p| p.to_string_lossy().into_owned()))
        .collect())
}

#[tauri::command]
pub fn expand_image_files(file_paths: Vec<String>) -> Vec<String> {
    collect_image_files(&file_paths)
}

#[tauri::command]
pub async fn compress_files(
    app: AppHandle,
    state: State<'_, AppState>,
    file_paths: Vec<String>,
    options: CompressOptions,
) -> Result<Vec<CompressResult>, String> {
    Ok(compress_batch(&app, state.inner(), file_paths, options, false).await)
}

#[tauri::command]
pub async fn compress_smart(
    app: AppHandle,
    state: State<'_, AppState>,
    file_paths: Vec<String>,
    options: CompressOptions,
) -> Result<Vec<CompressResult>, String> {
    Ok(compress_batch(&app, state.inner(), file_paths, options, true).await)
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

#[tauri::command]
pub fn cancel_file(file_path: String, state: State<'_, AppState>) -> bool {
    state.cancel_queue.lock().unwrap().insert(file_path);
    true
}

#[tauri::command]
pub fn clear_cancel_queue(state: State<'_, AppState>) -> bool {
    state.cancel_queue.lock().unwrap().clear();
    true
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
pub struct RestoreResult {
    success: bool,
    #[serde(rename = "filePath")]
    file_path: String,
    error: Option<String>,
}

#[tauri::command]
pub fn restore_original(
    file_path: String,
    backup_path: Option<String>,
    output_mode: String,
) -> RestoreResult {
    match output_mode.as_str() {
        "replace" => {
            if let Some(bp) = &backup_path {
                if Path::new(bp).exists() {
                    let _ = fs::copy(bp, &file_path);
                    let _ = fs::remove_file(bp);
                    return RestoreResult {
                        success: true,
                        file_path,
                        error: None,
                    };
                }
            }
        }
        "suffix" => {
            let path = PathBuf::from(&file_path);
            let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
            let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
            let dir = path.parent().unwrap_or(Path::new("."));
            let compressed = dir.join(format!("{}_compressed.{}", stem, ext));
            if compressed.exists() {
                let _ = fs::remove_file(&compressed);
            }
            return RestoreResult {
                success: true,
                file_path,
                error: None,
            };
        }
        "folder" => {
            if let Some(bp) = &backup_path {
                if Path::new(bp).exists() {
                    let _ = fs::remove_file(bp);
                }
            }
            return RestoreResult {
                success: true,
                file_path,
                error: None,
            };
        }
        _ => {}
    }
    RestoreResult {
        success: false,
        file_path,
        error: Some("无法恢复".into()),
    }
}


/// 一键恢复全部原图
#[derive(Serialize)]
pub struct RestoreAllResult {
    success: bool,
    restored: usize,
    failed: usize,
    message: String,
}

#[tauri::command]
pub fn restore_all(results: Vec<CompressResult>) -> RestoreAllResult {
    let mut restored = 0usize;
    let mut failed = 0usize;

    for r in &results {
        if !r.success {
            continue;
        }
        let single = restore_original(
            r.file.clone(),
            r.backup_path.clone(),
            r.output_mode.clone().unwrap_or_else(|| "suffix".into()),
        );
        if single.success {
            restored += 1;
        } else {
            failed += 1;
        }
    }

    RestoreAllResult {
        success: true,
        restored,
        failed,
        message: format!("已恢复 {} 个文件", restored),
    }
}

#[tauri::command]
pub fn get_file_sizes(file_paths: Vec<String>) -> Vec<u64> {
    file_paths
        .iter()
        .map(|fp| engine::get_file_size(&PathBuf::from(fp)))
        .collect()
}

/// Export all compressed results to their original directories with _compressed suffix.
#[tauri::command]
pub fn export_all(results: Vec<CompressResult>) -> usize {
    let mut count = 0usize;
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
                let dest = dir.join(format!("{}_compressed.{}", stem, ext));
                if fs::copy(&src, &dest).is_ok() {
                    count += 1;
                }
            }
        }
    }
    count
}
