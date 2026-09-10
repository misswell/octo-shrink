import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum SystemImageConverter {
    static func convert(
        file: String,
        options: CompressOptions
    ) -> EngineResult {
        guard let original = FileManager.default.contents(atPath: file) else {
            return EngineResult(
                success: false, compressed: Data(), outType: options.outputFormat.rawValue,
                algorithm: "macOS ImageIO", error: "无法读取文件"
            )
        }

        let ext = (file as NSString).pathExtension.lowercased()
        let (uti, outType): (String, String)
        if options.outputFormat == .original {
            switch ext {
            case "jpg", "jpeg": (uti, outType) = ("public.jpeg", "jpg")
            case "png": (uti, outType) = ("public.png", "png")
            case "heic", "heif": (uti, outType) = ("public.heic", "heic")
            default: (uti, outType) = ("public.jpeg", "jpg")
            }
        } else {
            switch options.outputFormat {
            case .jpg: (uti, outType) = ("public.jpeg", "jpg")
            case .png: (uti, outType) = ("public.png", "png")
            case .heic: (uti, outType) = ("public.heic", "heic")
            default:
                return EngineResult(
                    success: false, compressed: original, outType: options.outputFormat.rawValue,
                    algorithm: "macOS ImageIO", error: "系统转换仅支持 JPEG、PNG 和 HEIF"
                )
            }
        }

        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else {
            return EngineResult(
                success: false, compressed: original, outType: outType,
                algorithm: "macOS ImageIO", error: "macOS 无法读取此图像"
            )
        }
        guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return EngineResult(
                success: false, compressed: original, outType: outType,
                algorithm: "macOS ImageIO", error: "macOS 无法解码此图像"
            )
        }

        let actualMax = max(fullImage.width, fullImage.height)
        let maxPixel: Int
        switch options.systemImageSize {
        case .large: maxPixel = min(1280, actualMax)
        case .medium: maxPixel = min(640, actualMax)
        case .small: maxPixel = min(320, actualMax)
        case .actual: maxPixel = actualMax
        }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return EngineResult(
                success: false, compressed: original, outType: outType,
                algorithm: "macOS ImageIO", error: "macOS 无法调整图像尺寸"
            )
        }

        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            destData as CFMutableData, uti as CFString, 1, nil
        ) else {
            return EngineResult(
                success: false, compressed: original, outType: outType,
                algorithm: "macOS ImageIO", error: "无法创建系统转换缓冲区"
            )
        }

        var props: [CFString: Any] = [:]
        if options.preserveMetadata, let srcProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            props = srcProps
            props[kCGImagePropertyOrientation] = 1
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return EngineResult(
                success: false, compressed: original, outType: outType,
                algorithm: "macOS ImageIO", error: "系统转换失败"
            )
        }

        let compressed = destData as Data
        return EngineResult(
            success: true, compressed: compressed, outType: outType,
            algorithm: "macOS ImageIO", error: nil
        )
    }
}
