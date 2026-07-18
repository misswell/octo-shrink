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

fn no_improvement(original: Vec<u8>, out_type: &str, algorithm: &str) -> EngineResult {
    EngineResult {
        success: true,
        compressed: original,
        out_type: out_type.into(),
        algorithm: algorithm.into(),
        error: Some("压缩后体积未减小".into()),
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

/// PNG：占位实现，用 image crate 重编码（PNG 无损最佳压缩）。
/// 后续接入 imagequant crate 做量化（与 pngquant 同源算法）+ oxipng crate 无损再压。
async fn compress_png(file: &Path, _options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    if let Ok(img) = image::open(file) {
        let mut buf = Vec::new();
        let encoder = image::codecs::png::PngEncoder::new_with_quality(
            &mut buf,
            image::codecs::png::CompressionType::Best,
            image::codecs::png::FilterType::Adaptive,
        );
        use image::ImageEncoder;
        let rgba = img.to_rgba8();
        if encoder
            .write_image(&rgba, img.width(), img.height(), image::ExtendedColorType::Rgba8)
            .is_ok()
            && !buf.is_empty()
            && (buf.len() as u64) < original_size
        {
            return ok(buf, "png", "image-png (inproc, 待升级 imagequant+oxipng)");
        }
    }
    no_improvement(original, "png", "image-png (inproc)")
}

/// JPEG：占位实现，用 image crate 按质量重编码。
/// 后续接入 mozjpeg crate（与 cjpeg 同源 trellis quant）。
async fn compress_jpg(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = fs::read(file).unwrap_or_default();
    let original_size = original.len() as u64;
    let quality = options.quality as u8;
    if let Ok(img) = image::open(file) {
        let rgb = img.to_rgb8();
        let mut buf = Vec::new();
        let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, quality);
        use image::ImageEncoder;
        if encoder
            .write_image(&rgb, img.width(), img.height(), image::ExtendedColorType::Rgb8)
            .is_ok()
            && !buf.is_empty()
            && (buf.len() as u64) < original_size
        {
            return ok(buf, "jpg", "image-jpeg (inproc, 待升级 mozjpeg)");
        }
    }
    no_improvement(original, "jpg", "image-jpeg (inproc)")
}

pub async fn compress_image(file: &Path, options: &CompressOptions) -> EngineResult {
    let img_type = detect_image_type(file);
    match img_type.as_str() {
        "png" => compress_png(file, options).await,
        "jpg" => compress_jpg(file, options).await,
        "webp" => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, "webp", "App Store 进程内版暂未接入 WebP，待加 webp crate")
        }
        "gif" => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, "gif", "App Store 进程内版暂未接入 GIF，待加 gif crate")
        }
        "avif" => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, "avif", "App Store 进程内版暂未接入 AVIF，待加 libavif")
        }
        "jxl" => {
            let original = fs::read(file).unwrap_or_default();
            unsupported(original, "jxl", "App Store 进程内版暂未接入 JPEG XL")
        }
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
