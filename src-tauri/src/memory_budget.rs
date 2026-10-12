//! Conservative, header-only estimates for image encoder working memory.

use std::path::Path;

pub const MIB: u64 = 1024 * 1024;
pub const MIN_BUDGET_BYTES: u64 = 256 * MIB;
pub const UNKNOWN_RAM_BUDGET_BYTES: u64 = 512 * MIB;

const DECODED_BYTES_PER_PIXEL: u64 = 16;
const ENCODED_MULTIPLIER: u64 = 2;
const KNOWN_IMAGE_OVERHEAD_BYTES: u64 = 64 * MIB;
const UNKNOWN_IMAGE_MULTIPLIER: u64 = 4;
const UNKNOWN_IMAGE_OVERHEAD_BYTES: u64 = 256 * MIB;

/// Use one quarter of installed physical RAM, with a floor that still allows one large image.
/// If the platform cannot report RAM, retain a conservative fixed budget.
pub fn budget_bytes() -> u64 {
    budget_from_ram(physical_memory_bytes())
}

fn budget_from_ram(bytes: Option<u64>) -> u64 {
    bytes
        .map(|bytes| (bytes / 4).max(MIN_BUDGET_BYTES))
        .unwrap_or(UNKNOWN_RAM_BUDGET_BYTES)
}

/// Estimate from the image header only; this never decodes or reads the full image into memory.
pub fn estimate_working_set(path: &Path) -> u64 {
    let encoded_bytes = std::fs::metadata(path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    match image::image_dimensions(path) {
        Ok((width, height)) => (width as u64)
            .saturating_mul(height as u64)
            .saturating_mul(DECODED_BYTES_PER_PIXEL)
            .saturating_add(encoded_bytes.saturating_mul(ENCODED_MULTIPLIER))
            .saturating_add(KNOWN_IMAGE_OVERHEAD_BYTES),
        Err(_) => encoded_bytes
            .saturating_mul(UNKNOWN_IMAGE_MULTIPLIER)
            .saturating_add(UNKNOWN_IMAGE_OVERHEAD_BYTES),
    }
}

#[cfg(target_os = "macos")]
fn physical_memory_bytes() -> Option<u64> {
    use std::ffi::{c_char, c_void, CString};
    use std::mem::size_of;
    use std::ptr;

    extern "C" {
        fn sysctlbyname(
            name: *const c_char,
            oldp: *mut c_void,
            oldlenp: *mut usize,
            newp: *mut c_void,
            newlen: usize,
        ) -> i32;
    }

    let name = CString::new("hw.memsize").ok()?;
    let mut bytes = 0u64;
    let mut length = size_of::<u64>();
    let status = unsafe {
        sysctlbyname(
            name.as_ptr(),
            (&mut bytes as *mut u64).cast(),
            &mut length,
            ptr::null_mut(),
            0,
        )
    };
    (status == 0 && length == size_of::<u64>() && bytes > 0).then_some(bytes)
}

#[cfg(not(target_os = "macos"))]
fn physical_memory_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageEncoder;

    #[test]
    fn estimates_from_dimensions_and_file_size_without_decoding() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("tiny.png");
        let pixels = [0u8; 2 * 3 * 4];
        image::codecs::png::PngEncoder::new(std::fs::File::create(&path).unwrap())
            .write_image(&pixels, 2, 3, image::ExtendedColorType::Rgba8)
            .unwrap();
        let file_size = std::fs::metadata(&path).unwrap().len();
        let expected = 2u64 * 3 * DECODED_BYTES_PER_PIXEL
            + file_size * ENCODED_MULTIPLIER
            + KNOWN_IMAGE_OVERHEAD_BYTES;
        assert_eq!(estimate_working_set(&path), expected);
    }

    #[test]
    fn unknown_dimensions_use_the_conservative_fallback() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("unknown.bin");
        std::fs::write(&path, b"not an image").unwrap();
        let file_size = std::fs::metadata(&path).unwrap().len();
        assert_eq!(
            estimate_working_set(&path),
            file_size * UNKNOWN_IMAGE_MULTIPLIER + UNKNOWN_IMAGE_OVERHEAD_BYTES
        );
    }

    #[test]
    fn ram_budget_has_a_floor_and_unknown_ram_fallback() {
        assert_eq!(budget_from_ram(Some(128 * MIB)), MIN_BUDGET_BYTES);
        assert_eq!(budget_from_ram(Some(4 * 1024 * MIB)), 1024 * MIB);
        assert_eq!(budget_from_ram(None), UNKNOWN_RAM_BUDGET_BYTES);
    }
}
