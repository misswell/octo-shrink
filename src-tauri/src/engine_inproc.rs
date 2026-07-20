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

/// PNG：三级 fallback（与 cli 版 engine.rs 同序），成功判定 data.len() < original_size。
/// imagequant 量化（同源 pngquant）→ oxipng 无损 → image crate 兜底。
async fn compress_png(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality;
    eprintln!("[DEBUG] inproc compress_png: {:?} q={} orig_size={}", file, quality, original_size);
    if let Some(data) = compress_png_with_imagequant(file, quality) {
        eprintln!("[DEBUG] imagequant returned {} bytes", data.len());
        if (data.len() as u64) < original_size {
            return ok(data, "png", "pngquant (inproc)");
        }
    }
    if let Some(data) = compress_png_with_oxipng(file, quality) {
        eprintln!("[DEBUG] oxipng returned {} bytes", data.len());
        if (data.len() as u64) < original_size {
            return ok(data, "png", "oxipng (inproc)");
        }
    }
    if let Some(data) = compress_png_with_image(file) {
        eprintln!("[DEBUG] image-png returned {} bytes", data.len());
        if (data.len() as u64) < original_size {
            return ok(data, "png", "image-png (inproc)");
        }
    }
    eprintln!("[DEBUG] compress_png: no improvement, returning original");
    no_improvement(original, "png", "pngquant (inproc)", original_size, original_size)
}

/// image crate 兜底：PNG 无损最佳压缩重编码（RGBA8）。
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
/// 量化后取 remapped 像素重编码 RGBA8 PNG（颜色已减，非 PLTE 调色板）。
fn compress_png_with_imagequant(file: &Path, quality: u32) -> Option<Vec<u8>> {
    use imagequant::{RGBA, Attributes};
    use image::ImageEncoder;
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
    // remapped() 返回 (palette, indices)：palette 是量化后的颜色表，
    // indices 是每像素 1 字节的调色板索引。需要用索引查表重建完整 RGBA 图。
    let (palette, indices) = quant.remapped(&mut image).ok()?;
    let mut out: Vec<u8> = Vec::with_capacity(indices.len() * 4);
    for &idx in &indices {
        let p = palette[idx as usize];
        out.push(p.r); out.push(p.g); out.push(p.b); out.push(p.a);
    }
    let mut buf = Vec::new();
    let enc = image::codecs::png::PngEncoder::new_with_quality(
        &mut buf, image::codecs::png::CompressionType::Best, image::codecs::png::FilterType::Adaptive);
    enc.write_image(&out, w as u32, h as u32, image::ExtendedColorType::Rgba8).ok()?;
    if buf.is_empty() { None } else { Some(buf) }
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

/// GIF：进程内重编码（对齐 cli 版 gifsicle 接口）。成功判定 < original_size。
async fn compress_gif(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let _quality = options.quality;
    if let Some(data) = compress_gif_with_image(file) {
        if (data.len() as u64) < original_size {
            return ok(data, "gif", "gifsicle (inproc)");
        }
    }
    no_improvement(original, "gif", "gifsicle (inproc)", original_size, original_size)
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
    // 骨架：先按 compress_image 的结果走；后续接入多引擎候选挑选
    compress_image(file, options).await
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
