// Integration test for the compression engine
use octor_compressor_lib::engine;
use std::fs;
use std::path::PathBuf;

fn make_test_image(path: &str, format: &str) {
    let img = image::RgbImage::from_fn(400, 300, |x, y| {
        image::Rgb([
            ((x * 255) / 400) as u8,
            ((y * 255) / 300) as u8,
            128,
        ])
    });
    let dynamic = image::DynamicImage::ImageRgb8(img);
    match format {
        "png" => { dynamic.save(path).unwrap(); }
        "jpg" => { dynamic.save_with_format(path, image::ImageFormat::Jpeg).unwrap(); }
        _ => { dynamic.save(path).unwrap(); }
    }
}

#[tokio::test]
async fn test_detect_image_type() {
    let tmp = tempfile::tempdir().unwrap();
    let png_path = tmp.path().join("test.png");
    make_test_image(png_path.to_str().unwrap(), "png");
    let detected = engine::detect_image_type(&png_path);
    assert_eq!(detected, "png");

    let jpg_path = tmp.path().join("test.jpg");
    make_test_image(jpg_path.to_str().unwrap(), "jpg");
    let detected = engine::detect_image_type(&jpg_path);
    assert_eq!(detected, "jpg");
}

#[tokio::test]
async fn test_compress_png() {
    let tmp = tempfile::tempdir().unwrap();
    let png_path = tmp.path().join("test.png");
    make_test_image(png_path.to_str().unwrap(), "png");
    let original_size = fs::metadata(&png_path).unwrap().len();

    let options = engine::CompressOptions {
        quality: 75,
        output_format: "original".into(),
        ..Default::default()
    };
    let result = engine::compress_image(&png_path, &options).await;

    assert!(result.success, "PNG compression should succeed");
    assert!(result.compressed.len() > 0, "Should have compressed data");
    let compressed_size = result.compressed.len() as u64;
    println!("PNG: {} -> {} bytes", original_size, compressed_size);
    assert!(compressed_size <= original_size, "Compressed should be <= original");
    assert_eq!(result.out_type, "png");
}

#[tokio::test]
async fn test_compress_jpg() {
    let tmp = tempfile::tempdir().unwrap();
    let jpg_path = tmp.path().join("test.jpg");
    make_test_image(jpg_path.to_str().unwrap(), "jpg");
    let original_size = fs::metadata(&jpg_path).unwrap().len();

    let options = engine::CompressOptions {
        quality: 75,
        output_format: "original".into(),
        ..Default::default()
    };
    let result = engine::compress_image(&jpg_path, &options).await;

    assert!(result.success, "JPG compression should succeed");
    assert!(result.compressed.len() > 0, "Should have compressed data");
    let compressed_size = result.compressed.len() as u64;
    println!("JPG: {} -> {} bytes (algorithm: {})", original_size, compressed_size, result.algorithm);
    assert!(compressed_size <= original_size, "Compressed should be <= original");
    assert_eq!(result.out_type, "jpg");
}

#[tokio::test]
async fn test_compress_to_webp() {
    let tmp = tempfile::tempdir().unwrap();
    let png_path = tmp.path().join("test.png");
    make_test_image(png_path.to_str().unwrap(), "png");

    let options = engine::CompressOptions {
        quality: 75,
        output_format: "webp".into(),
        ..Default::default()
    };
    let result = engine::compress_image(&png_path, &options).await;

    assert!(result.success, "WebP conversion should succeed");
    assert_eq!(result.out_type, "webp");
}

#[tokio::test]
async fn test_compress_smart() {
    let tmp = tempfile::tempdir().unwrap();
    let png_path = tmp.path().join("test.png");
    make_test_image(png_path.to_str().unwrap(), "png");

    let options = engine::CompressOptions {
        quality: 75,
        smart_mode: true,
        ..Default::default()
    };
    let result = engine::compress_smart(&png_path, &options).await;

    assert!(result.success, "Smart compression should succeed");
    assert!(result.compressed.len() > 0);
}

#[tokio::test]
async fn test_format_bytes() {
    assert_eq!(engine::format_bytes(500), "500.0B");
    assert_eq!(engine::format_bytes(1024), "1.0KB");
    assert_eq!(engine::format_bytes(1024 * 1024), "1.0MB");
}
