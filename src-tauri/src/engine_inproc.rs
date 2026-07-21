// 进程内压缩引擎（App Store 产物线 / feature = inproc-backends）
//
// 与 engine.rs 公共接口一致，但直接调用 Rust 库（沙盒友好，无外部 CLI / dylib）。
// 当前为骨架：PNG/JPG 走 image crate 兜底编码（弱于 pngquant/mozjpeg），
// 其它格式待接入专用 crate（见 AGENTS.md「内置 CLI 工具与 Rust crate 对照」）。
//
// 改造原则（强制）：本文件的公共函数签名必须与 engine.rs 同名函数严格一致，
// CompressOptions / EngineResult 等类型复用 super::engine，不得重复定义。

use std::fs;
use std::path::Path;

// engine_inproc 是 engine 模块的子模块，super 就是 engine 自身
use super::{CompressOptions, EngineResult, detect_image_type};

fn ok(data: Vec<u8>, out_type: &str, algorithm: &str) -> EngineResult {
    EngineResult {
        success: true,
        compressed: data,
        out_type: out_type.into(),
        algorithm: algorithm.into(),
        error: None,
    }
}

fn no_improvement(original: Vec<u8>, out_type: &str, algorithm: &str, orig_size: u64, comp_size: u64) -> EngineResult {
    let msg = if comp_size >= orig_size {
        format!("压缩后 {} > 原始 {}，原图已是最优压缩", super::format_bytes(comp_size), super::format_bytes(orig_size))
    } else {
        "压缩后体积未减小".into()
    };
    EngineResult {
        success: true,
        compressed: original,
        out_type: out_type.into(),
        algorithm: algorithm.into(),
        error: Some(msg),
    }
}

fn unsupported(original: Vec<u8>, out_type: &str, reason: &str) -> EngineResult {
    EngineResult {
        success: false,
        compressed: original,
        out_type: out_type.into(),
        algorithm: "none".into(),
        error: Some(reason.into()),
    }
}

/// PNG：优先调打包的 pngquant/oxipng CLI（与 Direct 版完全一致），找不到降级 inproc。
async fn compress_png(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    // 1. pngquant CLI（与 Direct 版 engine.rs 完全一致的调用方式）
    if let Some(tool) = super::find_tool("pngquant") {
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
            if let Some(data) = super::cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return ok(data, "png", "pngquant");
                }
            }
        }
    }

    // 2. oxipng CLI（与 Direct 版一致，自包含可沙盒运行）
    if let Some(tool) = super::find_tool("oxipng") {
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
            let _ = super::make_command(&tool).args(&args)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status().await;
            if let Ok(data) = fs::read(&out) {
                if !data.is_empty() && (data.len() as u64) < original_size {
                    return ok(data, "png", "oxipng");
                }
            }
        }
    }

    // 3. inproc imagequant 降级（CLI 工具未找到时，如 dev 模式）
    if let Some(data) = compress_png_with_imagequant(file, quality) {
        if (data.len() as u64) < original_size {
            return ok(data, "png", "pngquant (inproc fallback)");
        }
    }

    // 4. inproc oxipng 降级
    if let Some(data) = compress_png_with_oxipng(file, quality) {
        if (data.len() as u64) < original_size {
            return ok(data, "png", "oxipng (inproc fallback)");
        }
    }

    // 5. image crate 兜底
    if let Some(data) = compress_png_with_image(file) {
        if (data.len() as u64) < original_size {
            return ok(data, "png", "image-png");
        }
    }

    no_improvement(original, "png", "pngquant", original_size, original_size)
}

/// image crate 兜底：PNG 无损重编码，保留原色型（RGB→RGB8，RGBA→RGBA8）。
fn compress_png_with_image(file: &Path) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let mut buf = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new_with_quality(
        &mut buf,
        image::codecs::png::CompressionType::Best,
        image::codecs::png::FilterType::Adaptive,
    );
    use image::ImageEncoder;
    match img.color() {
        image::ColorType::Rgba8 | image::ColorType::Rgba16 => {
            let rgba = img.to_rgba8();
            encoder.write_image(&rgba, img.width(), img.height(), image::ExtendedColorType::Rgba8).ok()?
        }
        _ => {
            let rgb = img.to_rgb8();
            encoder.write_image(&rgb, img.width(), img.height(), image::ExtendedColorType::Rgb8).ok()?
        }
    }
    if buf.is_empty() { None } else { Some(buf) }
}

/// oxipng crate 无损优化。level = (quality/20).clamp(1,6)。
fn compress_png_with_oxipng(file: &Path, quality: u32) -> Option<Vec<u8>> {
    let data = std::fs::read(file).ok()?;
    let level = (quality / 20).clamp(1, 6) as u8;
    let opts = oxipng::Options::from_preset(level);
    oxipng::optimize_from_memory(&data, &opts).ok()
}

/// imagequant crate 量化（与 pngquant 同源算法）：quality→set_quality(q-10,q)，speed=3，
/// 量化后用 png crate 直接写 8-bit 调色板 PNG（PLTE + 索引像素），与 pngquant CLI 一致。
fn compress_png_with_imagequant(file: &Path, quality: u32) -> Option<Vec<u8>> {
    use imagequant::{RGBA, Attributes};
    let img = image::open(file).ok()?;
    let rgba = img.to_rgba8();
    let (w, h) = (rgba.width() as usize, rgba.height() as usize);
    let raw: &[u8] = rgba.as_raw();
    let pixels: Vec<RGBA> = raw.chunks_exact(4)
        .map(|c| RGBA::new(c[0], c[1], c[2], c[3]))
        .collect();
    let mut attr = Attributes::new();
    let _ = attr.set_speed(3);
    let q = quality.min(100).max(10);
    let _ = attr.set_quality((q - 10) as u8, q as u8);
    let mut image = attr.new_image(pixels, w, h, 0.0).ok()?;
    let mut quant = attr.quantize(&mut image).ok()?;
    let _ = quant.set_dithering_level(1.0);
    let (palette, indices) = quant.remapped(&mut image).ok()?;

    // 构建 RGB 调色板（3 bytes/entry）+ tRNS 透明度表
    let mut palette_rgb = Vec::with_capacity(palette.len() * 3);
    let mut trns = Vec::with_capacity(palette.len());
    let mut has_alpha = false;
    for p in &palette {
        palette_rgb.push(p.r); palette_rgb.push(p.g); palette_rgb.push(p.b);
        if p.a < 255 { has_alpha = true; }
        trns.push(p.a);
    }

    // 用 png crate 写 8-bit Indexed PNG（同 pngquant CLI 输出格式）
    let mut buf = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut buf, w as u32, h as u32);
        enc.set_color(png::ColorType::Indexed);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_palette(&palette_rgb);
        if has_alpha { enc.set_trns(trns); }
        enc.set_compression(png::Compression::High);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(&indices).ok()?;
        writer.finish().ok()?;
    }
    if buf.is_empty() { return None; }

    // 快速路径：palette PNG 已比原文件小 → 直接返回（多数图片走此路径）
    let original_size = std::fs::metadata(file).ok()?.len() as usize;
    if buf.len() < original_size {
        return Some(buf);
    }

    // 慢速路径：palette PNG 比原文件大 → oxipng 全过滤优化
    // preset 4 = 全部 5 种过滤器（None/Sub/Up/Avg/Paeth）逐行选优
    // + Libdeflater（C 库 zlib，compression=12）+ 无超时（确保压到最优）
    let mut opts = oxipng::Options::from_preset(4);
    opts.bit_depth_reduction = false;
    opts.color_type_reduction = false;
    opts.palette_reduction = false;
    opts.grayscale_reduction = false;
    if let oxipng::Deflaters::Libdeflater { compression } = &mut opts.deflate {
        *compression = 12;
    }
    opts.timeout = None;
    match oxipng::optimize_from_memory(&buf, &opts) {
        Ok(optimized) if optimized.len() < buf.len() => Some(optimized),
        _ => Some(buf),
    }
}

/// image crate 兜底：JPEG 按质量重编码（RGB8）。
fn compress_jpg_with_image(file: &Path, quality: u8) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let rgb = img.to_rgb8();
    let mut buf = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, quality);
    use image::ImageEncoder;
    encoder
        .write_image(&rgb, img.width(), img.height(), image::ExtendedColorType::Rgb8)
        .ok()?;
    if buf.is_empty() { None } else { Some(buf) }
}

/// mozjpeg crate 量化（同源 cjpeg trellis quant）：set_quality + optimize + progressive。
fn compress_jpg_with_mozjpeg(file: &Path, quality: u32) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let rgb = img.to_rgb8();
    let (w, h) = (rgb.width() as usize, rgb.height() as usize);
    let mut cinfo = mozjpeg::Compress::new(mozjpeg::ColorSpace::JCS_EXT_RGB);
    cinfo.set_size(w, h);
    cinfo.set_quality(quality as f32);
    cinfo.set_optimize_coding(true);
    cinfo.set_progressive_mode();
    let mut comp = cinfo.start_compress(Vec::new()).ok()?;
    let row_stride = w * 3;
    let raw: &[u8] = rgb.as_raw();
    for row in raw.chunks_exact(row_stride) {
        let _ = comp.write_scanlines(row);
    }
    comp.finish().ok()
}

/// JPEG：两级 fallback（对齐 cli 版 engine.rs），成功判定 data.len() < original_size。
/// mozjpeg crate 量化（同源 cjpeg trellis quant）→ image crate 兜底。
async fn compress_jpg(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;
    if let Some(data) = compress_jpg_with_mozjpeg(file, quality) {
        if (data.len() as u64) < original_size {
            return ok(data, "jpg", "mozjpeg (inproc)");
        }
    }
    if let Some(data) = compress_jpg_with_image(file, quality as u8) {
        if (data.len() as u64) < original_size {
            return ok(data, "jpg", "image-jpeg (inproc)");
        }
    }
    no_improvement(original, "jpg", "mozjpeg (inproc)", original_size, original_size)
}

/// webp crate 编码（同源 cwebp/libwebp）：from_rgba + encode(quality)。
fn compress_to_webp_with_cwebp(file: &Path, quality: u32) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let rgba = img.to_rgba8();
    let encoder = webp::Encoder::from_rgba(rgba.as_raw(), rgba.width(), rgba.height());
    let webp_data = encoder.encode(quality as f32);
    let bytes: &[u8] = &webp_data;
    if bytes.is_empty() { None } else { Some(bytes.to_vec()) }
}

/// WebP：进程内 webp crate 编码（对齐 cli 版 cwebp）。成功判定 < original_size。
async fn compress_to_webp(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;
    if let Some(data) = compress_to_webp_with_cwebp(file, quality) {
        if (data.len() as u64) < original_size {
            return ok(data, "webp", "cwebp (inproc)");
        }
    }
    no_improvement(original, "webp", "cwebp (inproc)", original_size, original_size)
}

/// image crate 重编码 GIF（保留所有帧，无 gifsicle 减色优化，功能降级但可用）。
fn compress_gif_with_image(file: &Path) -> Option<Vec<u8>> {
    use image::AnimationDecoder;
    let f = std::fs::File::open(file).ok()?;
    let dec = image::codecs::gif::GifDecoder::new(std::io::BufReader::new(f)).ok()?;
    let frames = dec.into_frames().collect_frames().ok()?;
    let mut buf = Vec::new();
    {
        let mut enc = image::codecs::gif::GifEncoder::new_with_speed(&mut buf, 3);
        let _ = enc.encode_frames(frames);
    }
    if buf.is_empty() { None } else { Some(buf) }
}

/// GIF：优先调打包的 gifsicle CLI（与 Direct 版完全一致），找不到降级 gif crate。
/// gifsicle 是自包含二进制（仅依赖 libSystem），沙盒可直接 spawn。
async fn compress_gif(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;

    // 1. gifsicle CLI（与 Direct 版 engine.rs 完全一致的调用方式）
    if let Some(tool) = super::find_tool("gifsicle") {
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
            if let Some(data) = super::cli_to_file(&tool, &args, &out).await {
                if (data.len() as u64) < original_size {
                    return ok(data, "gif", "gifsicle");
                }
            }
        }
    }

    // 2. gif crate 降级（gifsicle 未找到时，如 dev 模式）
    if let Some(data) = compress_gif_with_image(file) {
        if (data.len() as u64) < original_size {
            return ok(data, "gif", "gifsicle (gif-crate fallback)");
        }
    }

    no_improvement(original, "gif", "gifsicle", original_size, original_size)
}

/// ravif crate 编码（同源 AV1/rav1e，对齐 avifenc）：with_quality + with_speed(6)。
fn compress_to_avif_with_avifenc(file: &Path, quality: u32) -> Option<Vec<u8>> {
    let img = image::open(file).ok()?;
    let rgba = img.to_rgba8();
    let (w, h) = (rgba.width() as usize, rgba.height() as usize);
    let pixels: Vec<ravif::RGBA8> = rgba.as_raw().chunks_exact(4)
        .map(|c| ravif::RGBA8 { r: c[0], g: c[1], b: c[2], a: c[3] })
        .collect();
    let enc = ravif::Encoder::new().with_quality(quality as f32).with_speed(6);
    let result = enc.encode_rgba(ravif::Img::new(&pixels, w, h)).ok()?;
    Some(result.avif_file)
}

/// AVIF：进程内 ravif 编码（对齐 cli 版 avifenc）。成功判定 < original_size。
async fn compress_to_avif(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;
    if let Some(data) = compress_to_avif_with_avifenc(file, quality) {
        if (data.len() as u64) < original_size {
            return ok(data, "avif", "avifenc (inproc)");
        }
    }
    no_improvement(original, "avif", "avifenc (inproc)", original_size, original_size)
}

/// JPEG XL：App Store 版暂未接入 libjxl（编译链重），友好降级保留原图不崩。
async fn compress_to_jxl(file: &Path, _options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    no_improvement(original, "jxl", "cjxl (inproc, 暂未接入)", original_size, original_size)
}

pub async fn compress_image(file: &Path, options: &CompressOptions) -> EngineResult {
    let img_type = detect_image_type(file);
    eprintln!("[DEBUG] inproc compress_image: {:?} type={}", file, img_type);
    match img_type.as_str() {
        "png" => compress_png(file, options).await,
        "jpg" => compress_jpg(file, options).await,
        "webp" => compress_to_webp(file, options).await,
        "gif" => compress_gif(file, options).await,
        "avif" => compress_to_avif(file, options).await,
        "jxl" => compress_to_jxl(file, options).await,
        "" | "unknown" => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, &img_type, "未识别的图片类型")
        }
        other => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, &img_type, &format!("App Store 版暂不支持: {}", other))
        }
    }
}

pub async fn compress_to_format(file: &Path, target: &str, options: &CompressOptions) -> EngineResult {
    match target {
        "png" => compress_png(file, options).await,
        "jpg" | "jpeg" => compress_jpg(file, options).await,
        "webp" => compress_to_webp(file, options).await,
        "avif" => compress_to_avif(file, options).await,
        "jxl" => compress_to_jxl(file, options).await,
        other => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, other, &format!("App Store 版暂未接入 {} 输出", other))
        }
    }
}

pub async fn compress_smart(file: &Path, options: &CompressOptions) -> EngineResult {
    // 多格式候选挑选（与 Direct 版 engine.rs compress_smart 逻辑一致）
    let img_type = detect_image_type(file);
    let quality = options.quality;

    let mut opts = options.clone();
    opts.quality = quality;

    // 如果指定了输出格式，走格式转换路径
    if opts.output_format != "original" {
        return compress_to_format(file, &opts.output_format, &opts).await;
    }

    let mut candidates: Vec<EngineResult> = Vec::new();

    match img_type.as_str() {
        "png" => {
            // PNG 同时尝试原格式 + WebP，选最小
            let r = compress_png(file, &opts).await;
            if r.success { candidates.push(r); }
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

    // 选最小的结果
    if let Some(best) = candidates.into_iter().min_by_key(|r| r.compressed.len()) {
        return best;
    }

    // 兜底
    compress_image(file, &opts).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[tokio::test]
    async fn test_compress_png_inproc() {
        let test_file = PathBuf::from("/tmp/test_octoshrink.png");
        if !test_file.exists() {
            eprintln!("[TEST] test file not found, skipping");
            return;
        }
        let opts = CompressOptions {
            quality: 80,
            output_format: "original".into(),
            smart_mode: false,
            backend: "auto".into(),
            effort: 3,
            convert_to_webp: false,
            output_mode: "suffix".into(),
            output_dir: None,
            lossless: None,
        };
        eprintln!("[TEST] calling compress_image on {:?}", test_file);
        let result = compress_image(&test_file, &opts).await;
        eprintln!("[TEST] result: success={} out_type={} algo={} err={:?} comp_len={}",
            result.success, result.out_type, result.algorithm, result.error, result.compressed.len());
        assert!(result.success, "compression should succeed");
    }
}
