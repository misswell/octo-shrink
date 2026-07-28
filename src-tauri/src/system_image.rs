//! macOS Finder-style image conversion implemented entirely with ImageIO.

use std::fs;
use std::path::Path;

use objc2_core_foundation::{
    CFBoolean, CFData, CFDictionary, CFMutableData, CFMutableDictionary, CFNumber, CFRetained,
    CFString, CFType,
};
use objc2_core_graphics::CGImage;
use objc2_image_io::{
    kCGImagePropertyOrientation, kCGImageSourceCreateThumbnailFromImageAlways,
    kCGImageSourceCreateThumbnailWithTransform, kCGImageSourceThumbnailMaxPixelSize,
    CGImageDestination, CGImageSource,
};

use crate::engine::{CompressOptions, EngineResult};

const LARGE_MAX_PIXEL: isize = 1280;
const MEDIUM_MAX_PIXEL: isize = 640;
const SMALL_MAX_PIXEL: isize = 320;

fn fail(original: Vec<u8>, out_type: &str, message: impl Into<String>) -> EngineResult {
    EngineResult {
        success: false,
        compressed: original,
        out_type: out_type.into(),
        algorithm: "macOS ImageIO".into(),
        error: Some(message.into()),
    }
}

fn target_type(target: &str) -> Option<(&'static str, &'static str)> {
    match target {
        "jpg" | "jpeg" => Some(("public.jpeg", "jpg")),
        "png" => Some(("public.png", "png")),
        "heic" | "heif" => Some(("public.heic", "heic")),
        _ => None,
    }
}

fn max_pixel_for(size: &str, actual_max_pixel: isize) -> isize {
    match size {
        "large" => LARGE_MAX_PIXEL.min(actual_max_pixel),
        "medium" => MEDIUM_MAX_PIXEL.min(actual_max_pixel),
        "small" => SMALL_MAX_PIXEL.min(actual_max_pixel),
        _ => actual_max_pixel,
    }
}

fn thumbnail_options(max_pixel: isize) -> CFRetained<CFDictionary<CFType, CFType>> {
    let size = CFNumber::new_isize(max_pixel.max(1));
    CFDictionary::<CFType, CFType>::from_slices(
        &[
            unsafe { kCGImageSourceCreateThumbnailFromImageAlways }.as_ref(),
            unsafe { kCGImageSourceCreateThumbnailWithTransform }.as_ref(),
            unsafe { kCGImageSourceThumbnailMaxPixelSize }.as_ref(),
        ],
        &[
            CFBoolean::new(true).as_ref(),
            CFBoolean::new(true).as_ref(),
            size.as_ref(),
        ],
    )
}

fn normalized_properties(
    source: &CGImageSource,
    preserve_metadata: bool,
) -> Option<CFRetained<CFMutableDictionary>> {
    if !preserve_metadata {
        return None;
    }

    let properties = unsafe { source.properties_at_index(0, None) }?;
    let properties = unsafe { CFMutableDictionary::new_copy(None, 0, Some(&properties)) }?;
    let orientation = CFNumber::new_i32(1);
    unsafe {
        CFMutableDictionary::set_value(
            Some(&properties),
            (kCGImagePropertyOrientation as *const CFString).cast(),
            (orientation.as_ref() as *const CFNumber).cast(),
        );
    }
    Some(properties)
}

pub fn convert(file: &Path, options: &CompressOptions) -> EngineResult {
    let original = match fs::read(file) {
        Ok(data) => data,
        Err(error) => return fail(Vec::new(), &options.output_format, error.to_string()),
    };
    let Some((uti, out_type)) = target_type(&options.output_format) else {
        return fail(
            original,
            &options.output_format,
            "系统转换仅支持 JPEG、PNG 和 HEIF",
        );
    };

    let input = CFData::from_bytes(&original);
    let Some(source) = (unsafe { CGImageSource::with_data(&input, None) }) else {
        return fail(original, out_type, "macOS 无法读取此图像");
    };
    let Some(full_image) = (unsafe { source.image_at_index(0, None) }) else {
        return fail(original, out_type, "macOS 无法解码此图像");
    };

    let actual_max =
        CGImage::width(Some(&full_image)).max(CGImage::height(Some(&full_image))) as isize;
    let thumbnail_options =
        thumbnail_options(max_pixel_for(&options.system_image_size, actual_max));
    let typed_thumbnail_options: &CFDictionary<CFType, CFType> = &thumbnail_options;
    let thumbnail_options: &CFDictionary = typed_thumbnail_options.as_ref();
    let Some(image) = (unsafe { source.thumbnail_at_index(0, Some(thumbnail_options)) }) else {
        return fail(original, out_type, "macOS 无法调整图像尺寸");
    };

    let Some(output) = CFMutableData::new(None, 0) else {
        return fail(original, out_type, "无法创建系统转换缓冲区");
    };
    let target_uti = CFString::from_str(uti);
    let Some(destination) =
        (unsafe { CGImageDestination::with_data(&output, &target_uti, 1, None) })
    else {
        return fail(
            original,
            out_type,
            format!("此 macOS 版本不支持 {} 输出", out_type),
        );
    };

    let properties = normalized_properties(&source, options.preserve_metadata);
    unsafe {
        destination.add_image(&image, properties.as_deref().map(AsRef::as_ref));
    }
    if !unsafe { destination.finalize() } {
        return fail(original, out_type, "macOS 系统转换失败");
    }

    EngineResult {
        success: true,
        compressed: output.to_vec(),
        out_type: out_type.into(),
        algorithm: format!(
            "macOS ImageIO · {}",
            match options.system_image_size.as_str() {
                "large" => "大",
                "medium" => "中",
                "small" => "小",
                _ => "实际大小",
            }
        ),
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finder_size_presets_match_expected_pixels() {
        assert_eq!(max_pixel_for("actual", 4000), 4000);
        assert_eq!(max_pixel_for("large", 4000), 1280);
        assert_eq!(max_pixel_for("medium", 4000), 640);
        assert_eq!(max_pixel_for("small", 4000), 320);
        assert_eq!(max_pixel_for("large", 800), 800);
    }

    #[test]
    fn finder_formats_are_limited_to_native_choices() {
        assert_eq!(target_type("jpg"), Some(("public.jpeg", "jpg")));
        assert_eq!(target_type("png"), Some(("public.png", "png")));
        assert_eq!(target_type("heif"), Some(("public.heic", "heic")));
        assert_eq!(target_type("webp"), None);
    }

    #[test]
    fn image_io_converts_and_resizes_without_external_tools() {
        let temp = tempfile::tempdir().unwrap();
        let input = temp.path().join("input.png");
        let image = image::RgbImage::from_pixel(900, 600, image::Rgb([30, 120, 220]));
        image.save(&input).unwrap();

        let mut options = CompressOptions::default();
        options.processing_mode = "system".into();
        options.system_image_size = "small".into();
        options.output_format = "jpg".into();
        options.preserve_metadata = false;

        let result = convert(&input, &options);
        assert!(result.success, "{:?}", result.error);
        assert_eq!(result.out_type, "jpg");
        let decoded = image::load_from_memory(&result.compressed).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (320, 213));

        options.system_image_size = "actual".into();
        options.output_format = "heif".into();
        let heif = convert(&input, &options);
        assert!(heif.success, "{:?}", heif.error);
        assert_eq!(heif.out_type, "heic");
        assert!(!heif.compressed.is_empty());
    }
}
