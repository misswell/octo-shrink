// OctoShrink - Rust compression engine
// Replaces the Node.js engine (sharp/squoosh) with CLI tools + the `image` crate.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tokio::process::Command;
use serde::{Deserialize, Serialize};

#[cfg(feature = "inproc-backends")]
#[path = "engine_inproc.rs"]
mod engine_inproc;

/// 全局存储应用资源目录路径（在 setup 时初始化）
static RESOURCE_DIR: OnceLock<PathBuf> = OnceLock::new();

/// 初始化资源目录路径（由 lib.rs setup 调用）
pub fn set_resource_dir(path: PathBuf) {
    let _ = RESOURCE_DIR.set(path);
}

/// 获取库目录路径（resources/lib）
fn get_lib_dir() -> Option<PathBuf> {
    if let Some(res_dir) = RESOURCE_DIR.get() {
        let lib_dir = res_dir.join("resources").join("lib");
        if lib_dir.exists() {
            return Some(lib_dir);
        }
        let lib_dir = res_dir.join("lib");
        if lib_dir.exists() {
            return Some(lib_dir);
        }
    }
    let dev_lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("resources").join("lib");
    if dev_lib.exists() {
        return Some(dev_lib);
    }
    None
}

/// 创建带有正确环境变量的 Command（自动设置 DYLD_FALLBACK_LIBRARY_PATH）
fn make_command(tool: &Path) -> Command {
    let mut cmd = Command::new(tool);
    cmd.kill_on_drop(true);
    #[cfg(target_os = "windows")]
    {
        // CREATE_NO_WINDOW: 避免每个 CLI 工具弹出控制台黑框
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    if cfg!(target_os = "macos") {
        if let Some(lib_dir) = get_lib_dir() {
        // macOS: 设置 DYLD_FALLBACK_LIBRARY_PATH 让工具找到内置动态库
        // 这样无需修改二进制文件的依赖路径，保持原始签名有效
        let current = std::env::var("DYLD_FALLBACK_LIBRARY_PATH").unwrap_or_default();
        let combined = if current.is_empty() {
            lib_dir.to_string_lossy().into_owned()
        } else {
            format!("{}:{}", lib_dir.to_string_lossy(), current)
        };
        cmd.env("DYLD_FALLBACK_LIBRARY_PATH", combined);
        }
    }
    cmd
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
pub struct CompressOptions {
    #[serde(default = "default_quality")]
    pub quality: u32,
    #[serde(default)]
    pub smart_mode: bool,
    #[serde(default = "default_format")]
    pub output_format: String,
    #[serde(default = "default_backend")]
    pub backend: String,
    #[serde(default = "default_effort")]
    pub effort: u32,
    #[serde(default)]
    pub convert_to_webp: bool,
    #[serde(default = "default_mode")]
    pub output_mode: String,
    #[serde(default)]
    pub output_dir: Option<String>,
    #[serde(default)]
    pub lossless: Option<bool>,
}

fn default_quality() -> u32 { 75 }
fn default_format() -> String { "original".into() }
fn default_backend() -> String { "auto".into() }
fn default_effort() -> u32 { 6 }
fn default_mode() -> String { "suffix".into() }

impl Default for CompressOptions {
    fn default() -> Self {
        Self {
            quality: 75, smart_mode: false, output_format: "original".into(),
            backend: "auto".into(), effort: 6, convert_to_webp: false,
            output_mode: "suffix".into(), output_dir: None, lossless: None,
        }
    }
}

/// Internal result carrying the compressed bytes.
#[derive(Debug, Clone)]
pub struct EngineResult {
    pub success: bool,
    pub compressed: Vec<u8>,
    pub out_type: String,
    pub algorithm: String,
    pub error: Option<String>,
}

/// Result returned to the frontend (no raw bytes).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressResult {
    pub success: bool,
    pub file: String,
    pub original_size: u64,
    pub compressed_size: u64,
    pub savings: f64,
    pub original_size_formatted: String,
    pub compressed_size_formatted: String,
    #[serde(rename = "type")]
    pub out_type: String,
    pub algorithm: String,
    pub error: Option<String>,
    pub output_path: Option<String>,
    pub backup_path: Option<String>,
    pub output_mode: Option<String>,
}

// ─── Utilities ──────────────────────────────────────────────────

pub fn format_bytes(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{:.1}B", bytes as f64)
    } else if bytes < 1024 * 1024 {
        format!("{:.1}KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1}MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

pub fn get_file_size(path: &Path) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

pub fn detect_image_type(path: &Path) -> String {
    let buf = match fs::read(path) {
        Ok(b) => b,
        Err(_) => return "unknown".into(),
    };
    let b = if buf.len() >= 12 { &buf[..12] } else { &buf };
    if b.len() >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 {
        "png".into()
    } else if b.len() >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
        "jpg".into()
    } else if b.len() >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 {
        "gif".into()
    } else if b.len() >= 4 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 {
        "webp".into()
    } else if b.len() >= 2 && b[0] == 0x42 && b[1] == 0x4D {
        "bmp".into()
    } else {
        "unknown".into()
    }
}

fn analyze_quality(path: &Path) -> u32 {
    let size = get_file_size(path);
    if size > 5 * 1024 * 1024 { 60 }
    else if size > 2 * 1024 * 1024 { 65 }
    else if size > 1024 * 1024 { 70 }
    else if size > 500 * 1024 { 75 }
    else { 80 }
}

/// Locate a CLI tool: first from bundled resources, then system PATH.
fn find_tool(name: &str) -> Option<PathBuf> {
    let exe_name = if cfg!(target_os = "windows") {
        format!("{}.exe", name)
    } else {
        name.to_string()
    };

    // 1. Tauri bundled: <res>/resources/bin/<tool>
    if let Some(res_dir) = RESOURCE_DIR.get() {
        let bundled = res_dir.join("resources").join("bin").join(&exe_name);
        if bundled.exists() {
            return Some(bundled);
        }
        // package.sh style: <res>/bin/<tool>
        let bundled = res_dir.join("bin").join(&exe_name);
        if bundled.exists() {
            return Some(bundled);
        }
    }
    // 2. Dev mode: src-tauri/resources/bin/<tool>
    let dev_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("resources").join("bin").join(&exe_name);
    if dev_path.exists() {
        return Some(dev_path);
    }
    // 3. System PATH
    if cfg!(target_os = "windows") {
        if let Ok(path_var) = std::env::var("PATH") {
            for dir in path_var.split(';') {
                let p = Path::new(dir).join(&exe_name);
                if p.exists() {
                    return Some(p);
                }
            }
        }
        let mut where_cmd = std::process::Command::new("where");
        where_cmd.arg(&exe_name);
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::process::CommandExt;
            where_cmd.creation_flags(0x08000000);
        }
        if let Ok(out) = where_cmd.output() {
            if out.status.success() {
                if let Some(line) = String::from_utf8_lossy(&out.stdout).lines().next() {
                    let s = line.trim();
                    if !s.is_empty() {
                        return Some(PathBuf::from(s));
                    }
                }
            }
        }
    } else {
        let extra = [
            "/opt/homebrew/opt/mozjpeg/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/opt/local/bin",
        ];
        for dir in extra {
            let p = Path::new(dir).join(name);
            if p.exists() {
                return Some(p);
            }
        }
        if let Ok(out) = std::process::Command::new("which").arg(name).output() {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !s.is_empty() {
                    return Some(PathBuf::from(s));
                }
            }
        }
    }
    None
}

fn make_engine_result(
    _original_size: u64,
    data: Vec<u8>,
    out_type: &str,
    algorithm: &str,
) -> EngineResult {
    let _compressed_size = data.len() as u64;
    EngineResult {
        success: true,
        compressed: data,
        out_type: out_type.into(),
        algorithm: algorithm.into(),
        error: None,
    }
}

fn fallback_engine(original: Vec<u8>, out_type: &str, algorithm: &str, error: &str) -> EngineResult {
    EngineResult {
        success: false,
        compressed: original,
        out_type: out_type.into(),
        algorithm: algorithm.into(),
        error: Some(error.into()),
    }
}

/// 压缩后体积未减小：返回原始数据，标记为"无优化空间"（不算失败）
fn no_improvement(original: Vec<u8>, out_type: &str, algorithm: &str, orig_size: u64, comp_size: u64) -> EngineResult {
    let msg = if comp_size >= orig_size {
        format!("压缩后 {} > 原始 {}，原图已是最优压缩", format_bytes(comp_size), format_bytes(orig_size))
    } else {
        "压缩后体积未减小".into()
    };
    EngineResult {
        success: true,  // 不算失败，只是没有优化空间
        compressed: original,
        out_type: out_type.into(),
        algorithm: algorithm.into(),
        error: Some(msg),
    }
}

/// Run a CLI tool that writes to an output file, then read the output.
async fn cli_to_file(
    tool: &Path,
    args: &[String],
    output_path: &Path,
) -> Option<Vec<u8>> {
    let result = make_command(tool)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .await
        .ok()?;
    if !result.status.success() {
        return None;
    }
    fs::read(output_path).ok().filter(|d| !d.is_empty())
}

// ─── PNG ────────────────────────────────────────────────────────

async fn compress_png(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    // 1. pngquant (lossy)
    if let Some(tool) = find_tool("pngquant") {
        let tmp = tempfile::tempdir().ok();
        if let Some(ref td) = tmp {
            let out = td.path().join("c.png");
            let q_low = quality.saturating_sub(10).max(10);
            let q_high = quality.min(100);
            let args = vec![
                format!("--quality={}-{}", q_low, q_high),
                "--speed=3".into(),
                "--strip".into(),
                "--output".into(),
                out.to_string_lossy().into(),
                "--".into(),
                file.to_string_lossy().into(),
            ];
            if let Some(data) = cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "png", "pngquant");
                }
            }
        }
    }

    // 2. oxipng (lossless)
    if let Some(tool) = find_tool("oxipng") {
        let tmp = tempfile::tempdir().ok();
        if let Some(ref td) = tmp {
            let out = td.path().join("c.png");
            let _ = fs::copy(file, &out);
            let level = (quality / 20).min(6).max(1);
            let args = vec![
                format!("-o{}", level),
                "--strip".into(),
                "safe".into(),
                out.to_string_lossy().into(),
            ];
            let _ = make_command(&tool).args(&args).stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null()).status().await;
            if let Ok(data) = fs::read(&out) {
                if !data.is_empty() && (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "png", "oxipng");
                }
            }
        }
    }

    // 3. image crate fallback (lossless re-encode, best compression)
    if let Some(data) = compress_png_with_image(file) {
        if (data.len() as u64) < original_size {
            return make_engine_result(original_size, data, "png", "image-png");
        }
    }

    no_improvement(original, "png", "pngquant", original_size, original_size)
}

fn compress_png_with_image(file: &Path) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let mut buf = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new_with_quality(
        &mut buf,
        image::codecs::png::CompressionType::Best,
        image::codecs::png::FilterType::Adaptive,
    );
    use image::ImageEncoder;
    let rgba = img.to_rgba8();
    encoder
        .write_image(&rgba, img.width(), img.height(), image::ExtendedColorType::Rgba8)
        .ok()?;
    Some(buf)
}

// ─── JPEG ───────────────────────────────────────────────────────

async fn compress_jpg(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    // 1. cjpeg (mozjpeg) via PPM pipe: decode with image crate, encode with mozjpeg
    if let Some(tool) = find_tool("cjpeg") {
        // Decode image and convert to PPM for cjpeg input
        if let Ok(img) = image::open(file) {
            let rgb = img.to_rgb8();
            let (w, h) = (rgb.width(), rgb.height());
            // Build PPM (P6) header + raw RGB data
            let mut ppm = Vec::with_capacity(15 + (w * h * 3) as usize);
            ppm.extend_from_slice(format!("P6\n{} {}\n255\n", w, h).as_bytes());
            ppm.extend_from_slice(&rgb);
            // Pipe PPM to cjpeg stdin
            if let Ok(mut child) = make_command(&tool)
                .args([
                    "-quality", &quality.to_string(),
                    "-optimize", "-progressive",
                ])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()
            {
                use tokio::io::AsyncWriteExt;
                if let Some(mut stdin) = child.stdin.take() {
                    let _ = stdin.write_all(&ppm).await;
                }
                if let Ok(output) = child.wait_with_output().await {
                    if !output.stdout.is_empty() && (output.stdout.len() as u64) < original_size {
                        return make_engine_result(original_size, output.stdout, "jpg", "mozjpeg");
                    }
                }
            }
        }
    }

    // 2. image crate fallback (decode + re-encode)
    if let Some(data) = compress_jpg_with_image(file, quality as u8) {
        if (data.len() as u64) < original_size {
            return make_engine_result(original_size, data, "jpg", "image-jpeg");
        }
    }

    no_improvement(original, "jpg", "mozjpeg", original_size, original_size)
}

fn compress_jpg_with_image(file: &Path, quality: u8) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let rgb = img.to_rgb8();
    let mut buf = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, quality);
    use image::ImageEncoder;
    encoder
        .write_image(&rgb, img.width(), img.height(), image::ExtendedColorType::Rgb8)
        .ok()?;
    Some(buf)
}

// ─── GIF ────────────────────────────────────────────────────────

async fn compress_gif(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    if let Some(tool) = find_tool("gifsicle") {
        let tmp = tempfile::tempdir().ok();
        if let Some(ref td) = tmp {
            let out = td.path().join("c.gif");
            let colors = ((quality as f64 / 100.0) * 256.0).floor().max(32.0) as u32;
            let args = vec![
                format!("--optimize=3"),
                format!("--colors={}", colors),
                "--no-comments".into(),
                "--output".into(),
                out.to_string_lossy().into(),
                file.to_string_lossy().into(),
            ];
            if let Some(data) = cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "gif", "gifsicle");
                }
            }
        }
    }

    // No good image-crate fallback for GIF animation; return original
    no_improvement(original, "gif", "gifsicle", original_size, original_size)
}

// ─── WebP ───────────────────────────────────────────────────────

async fn compress_to_webp(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    if let Some(tool) = find_tool("cwebp") {
        let tmp = tempfile::tempdir().ok();
        if let Some(ref td) = tmp {
            let out = td.path().join("c.webp");
            let args = vec![
                format!("-q"), quality.to_string(),
                "-m".into(), "6".into(),
                "-pass".into(), "10".into(),
                "-mt".into(),
                "-o".into(),
                out.to_string_lossy().into(),
                file.to_string_lossy().into(),
            ];
            if let Some(data) = cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "webp", "cwebp");
                }
            }
        }
    }

    no_improvement(original, "webp", "cwebp", original_size, original_size)
}

// ─── AVIF ───────────────────────────────────────────────────────

async fn compress_to_avif(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    if let Some(tool) = find_tool("avifenc") {
        let tmp = tempfile::tempdir().ok();
        if let Some(ref td) = tmp {
            let out = td.path().join("c.avif");
            let args = vec![
                "--speed".into(), "6".into(),
                "--jobs".into(), "4".into(),
                "--min".into(), "0".into(),
                "--max".into(), quality.to_string(),
                "-o".into(),
                out.to_string_lossy().into(),
                file.to_string_lossy().into(),
            ];
            if let Some(data) = cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "avif", "avifenc");
                }
            }
        }
    }

    no_improvement(original, "avif", "avifenc", original_size, original_size)
}

// ─── JPEG XL ────────────────────────────────────────────────────

async fn compress_to_jxl(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    if let Some(tool) = find_tool("cjxl") {
        let tmp = tempfile::tempdir().ok();
        if let Some(ref td) = tmp {
            let out = td.path().join("c.jxl");
            let distance = ((100 - quality) as f64 / 7.0).max(0.1).min(15.0);
            let args = vec![
                "--lossless_jpeg=0".into(),
                "--distance".into(),
                format!("{:.2}", distance),
                "--effort".into(), "7".into(),
                file.to_string_lossy().into(),
                out.to_string_lossy().into(),
            ];
            if let Some(data) = cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return make_engine_result(original_size, data, "jxl", "cjxl");
                }
            }
        }
    }

    no_improvement(original, "jxl", "cjxl", original_size, original_size)
}

// ─── Dispatcher ─────────────────────────────────────────────────

// 函数级 allow：inproc-backends 模式下提前 return 会让后续 cli 代码被判为 unreachable；
// 放在 fn 签名上方而非语句级，避免 cfg 消除该 return 时属性也跟着消失。
#[allow(unreachable_code)]
pub async fn compress_image(file: &Path, options: &CompressOptions) -> EngineResult {
    // 双线骨架：inproc 模式提前 return；cli 模式走下面默认实现（见 AGENTS.md 强制规则 1-3）
    // App Store 产物线：路由到进程内实现
    #[cfg(feature = "inproc-backends")]
    return engine_inproc::compress_image(file, options).await;

    let img_type = detect_image_type(file);

    // Format conversion
    if options.output_format != "original" {
        return compress_to_format(file, &options.output_format, options).await;
    }

    match img_type.as_str() {
        "png" => compress_png(file, options).await,
        "jpg" => compress_jpg(file, options).await,
        "gif" => compress_gif(file, options).await,
        "webp" => compress_to_webp(file, options).await,
        _ => {
            let original = fs::read(file).unwrap_or_default();
            fallback_engine(original, &img_type, "none", &format!("Unsupported image type: {}", img_type))
        }
    }
}

#[allow(unreachable_code)]
pub async fn compress_to_format(file: &Path, target: &str, options: &CompressOptions) -> EngineResult {
    // App Store 产物线：路由到进程内实现
    #[cfg(feature = "inproc-backends")]
    return engine_inproc::compress_to_format(file, target, options).await;

    match target {
        "webp" => compress_to_webp(file, options).await,
        "avif" => compress_to_avif(file, options).await,
        "jxl" => compress_to_jxl(file, options).await,
        "jpg" | "jpeg" => compress_jpg(file, options).await,
        "png" => compress_png(file, options).await,
        _ => {
            let original = fs::read(file).unwrap_or_default();
            fallback_engine(original, target, "none", &format!("Unsupported target format: {}", target))
        }
    }
}

/// Smart mode: try the natural compressor; if smart, also try alternatives and pick best.
#[allow(unreachable_code)]
pub async fn compress_smart(file: &Path, options: &CompressOptions) -> EngineResult {
    // App Store 产物线：路由到进程内实现
    #[cfg(feature = "inproc-backends")]
    return engine_inproc::compress_smart(file, options).await;

    let img_type = detect_image_type(file);
    let _original_size = get_file_size(file);
    let quality = if options.quality > 0 { options.quality } else { analyze_quality(file) };

    let mut opts = options.clone();
    opts.quality = quality;

    // If a specific output format is requested, use format conversion path
    if opts.output_format != "original" {
        return compress_to_format(file, &opts.output_format, &opts).await;
    }

    let mut candidates: Vec<EngineResult> = Vec::new();

    match img_type.as_str() {
        "png" => {
            let r = compress_png(file, &opts).await;
            if r.success { candidates.push(r); }
            // Also try webp as an alternative for potentially smaller size
            let w = compress_to_webp(file, &opts).await;
            if w.success { candidates.push(w); }
        }
        "jpg" => {
            let r = compress_jpg(file, &opts).await;
            if r.success { candidates.push(r); }
        }
        "gif" => {
            let r = compress_gif(file, &opts).await;
            if r.success { candidates.push(r); }
        }
        "webp" => {
            let r = compress_to_webp(file, &opts).await;
            if r.success { candidates.push(r); }
        }
        _ => {}
    }

    // Pick the smallest result
    if let Some(best) = candidates.into_iter().min_by_key(|r| r.compressed.len()) {
        return best;
    }

    // Fallback
    compress_image(file, &opts).await
}
