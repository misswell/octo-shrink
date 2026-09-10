import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum CompressionEngine {
    static func compress(file: String, options: CompressOptions) -> EngineResult {
        if options.processingMode == .system {
            return SystemImageConverter.convert(file: file, options: options)
        }
        let imgType = detectImageType(path: file)
        if options.outputFormat != .original {
            return compressToFormat(file: file, target: options.outputFormat.rawValue, options: options)
        }
        switch imgType {
        case "png": return compressPNG(file: file, options: options)
        case "jpg": return compressJPG(file: file, options: options)
        case "gif": return compressGIF(file: file, options: options)
        case "webp": return compressToWebP(file: file, options: options)
        case "heic": return compressHEIC(file: file, options: options)
        default:
            let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
            return EngineResult(
                success: false, compressed: original, outType: imgType,
                algorithm: "none", error: "不支持的图片类型: \(imgType)"
            )
        }
    }

    static func compressToFormat(file: String, target: String, options: CompressOptions) -> EngineResult {
        if options.processingMode == .system {
            var opts = options
            opts.outputFormat = OutputFormat(rawValue: target) ?? .original
            return SystemImageConverter.convert(file: file, options: opts)
        }
        switch target {
        case "webp": return compressToWebP(file: file, options: options)
        case "avif": return compressToAVIF(file: file, options: options)
        case "jpg", "jpeg": return compressJPG(file: file, options: options)
        case "png": return compressPNG(file: file, options: options)
        case "heic", "heif": return compressHEIC(file: file, options: options)
        default:
            let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
            return EngineResult(
                success: false, compressed: original, outType: target,
                algorithm: "none", error: "不支持的目标格式: \(target)"
            )
        }
    }

    // MARK: - PNG

    static func compressPNG(file: String, options: CompressOptions) -> EngineResult {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
        let originalSize = original.count
        let quality = options.quality

        if CLIRunner.toolURL(for: "pngquant") != nil {
            let tmp = scratchFile("png")
            let qLow = max(quality - 10, 10)
            let qHigh = min(quality, 100)
            let data = CLIRunner.runToFile(
                tool: "pngquant",
                args: [
                    "--quality=\(qLow)-\(qHigh)", "--speed=3", "--strip",
                    "--output", tmp, "--", file
                ],
                outputPath: tmp
            )
            if let data, data.count < originalSize {
                try? FileManager.default.removeItem(atPath: tmp)
                return EngineResult(success: true, compressed: data, outType: "png", algorithm: "pngquant")
            }
            try? FileManager.default.removeItem(atPath: tmp)
        }

        if CLIRunner.toolURL(for: "oxipng") != nil {
            let tmp = scratchFile("png")
            try? FileManager.default.copyItem(atPath: file, toPath: tmp)
            let level = min(max(quality / 20, 1), 6)
            let _ = CLIRunner.runToFile(
                tool: "oxipng",
                args: ["-o\(level)", "--strip", "safe", tmp],
                outputPath: tmp
            )
            if let data = FileManager.default.contents(atPath: tmp), !data.isEmpty, data.count < originalSize {
                try? FileManager.default.removeItem(atPath: tmp)
                return EngineResult(success: true, compressed: data, outType: "png", algorithm: "oxipng")
            }
            try? FileManager.default.removeItem(atPath: tmp)
        }

        if let data = compressPNGImageIO(file: file), data.count < originalSize {
            return EngineResult(success: true, compressed: data, outType: "png", algorithm: "ImageIO")
        }
        return noImprovement(original: original, outType: "png", algorithm: "pngquant", originalSize: originalSize)
    }

    static func compressPNGImageIO(file: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: file),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - JPEG

    static func compressJPG(file: String, options: CompressOptions) -> EngineResult {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
        let originalSize = original.count
        let quality = options.quality

        if CLIRunner.toolURL(for: "cjpeg") != nil,
           let ppmData = convertToPPM(file: file) {
            let data = CLIRunner.run(
                tool: "cjpeg",
                args: ["-quality", "\(quality)", "-optimize", "-progressive"],
                stdinData: ppmData
            )
            if let data, data.count < originalSize {
                return EngineResult(success: true, compressed: data, outType: "jpg", algorithm: "mozjpeg")
            }
        }

        if let data = compressJPGImageIO(file: file, quality: quality), data.count < originalSize {
            return EngineResult(success: true, compressed: data, outType: "jpg", algorithm: "ImageIO")
        }
        return noImprovement(original: original, outType: "jpg", algorithm: "mozjpeg", originalSize: originalSize)
    }

    static func compressJPGImageIO(file: String, quality: Int) -> Data? {
        guard let data = FileManager.default.contents(atPath: file),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let out = NSMutableData()
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func convertToPPM(file: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: file),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rawData = context.data else { return nil }
        var ppm = Data()
        ppm.append("P6\n\(width) \(height)\n255\n".data(using: .ascii)!)
        // CGContext RGBA -> need RGB; use context directly if RGB
        let rgbData = Data(bytes: rawData, count: width * height * 3)
        ppm.append(rgbData)
        return ppm
    }

    // MARK: - GIF

    static func compressGIF(file: String, options: CompressOptions) -> EngineResult {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
        let originalSize = original.count
        let quality = options.quality

        if CLIRunner.toolURL(for: "gifsicle") != nil {
            let tmp = scratchFile("gif")
            let colors = max(Int(Double(quality) / 100.0 * 256.0), 32)
            if let data = CLIRunner.runToFile(
                tool: "gifsicle",
                args: [
                    "--optimize=3", "--colors=\(colors)", "--no-comments",
                    "--output", tmp, file
                ],
                outputPath: tmp
            ), data.count < originalSize {
                try? FileManager.default.removeItem(atPath: tmp)
                return EngineResult(success: true, compressed: data, outType: "gif", algorithm: "gifsicle")
            }
            try? FileManager.default.removeItem(atPath: tmp)
        }
        return noImprovement(original: original, outType: "gif", algorithm: "gifsicle", originalSize: originalSize)
    }

    // MARK: - WebP

    static func compressToWebP(file: String, options: CompressOptions) -> EngineResult {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
        let originalSize = original.count
        let quality = options.quality

        if CLIRunner.toolURL(for: "cwebp") != nil {
            let tmp = scratchFile("webp")
            if let data = CLIRunner.runToFile(
                tool: "cwebp",
                args: [
                    "-q", "\(quality)", "-m", "6", "-pass", "10", "-mt",
                    "-o", tmp, file
                ],
                outputPath: tmp
            ), data.count < originalSize {
                try? FileManager.default.removeItem(atPath: tmp)
                return EngineResult(success: true, compressed: data, outType: "webp", algorithm: "cwebp")
            }
            try? FileManager.default.removeItem(atPath: tmp)
        }

        if let data = compressWebPImageIO(file: file, quality: quality) {
            return EngineResult(success: true, compressed: data, outType: "webp", algorithm: "ImageIO")
        }
        return noImprovement(original: original, outType: "webp", algorithm: "cwebp", originalSize: originalSize)
    }

    static func compressWebPImageIO(file: String, quality: Int) -> Data? {
        guard let data = FileManager.default.contents(atPath: file),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let out = NSMutableData()
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.webP.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - AVIF

    static func compressToAVIF(file: String, options: CompressOptions) -> EngineResult {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
        let quality = options.quality

        if CLIRunner.toolURL(for: "avifenc") != nil {
            let tmp = scratchFile("avif")
            if let data = CLIRunner.runToFile(
                tool: "avifenc",
                args: [
                    "--speed", "6", "--jobs", "4", "--min", "0", "--max", "\(quality)",
                    "-o", tmp, file
                ],
                outputPath: tmp
            ) {
                try? FileManager.default.removeItem(atPath: tmp)
                return EngineResult(success: true, compressed: data, outType: "avif", algorithm: "avifenc")
            }
            try? FileManager.default.removeItem(atPath: tmp)
        }
        return noImprovement(original: original, outType: "avif", algorithm: "avifenc", originalSize: original.count)
    }

    // MARK: - HEIC

    static func compressHEIC(file: String, options: CompressOptions) -> EngineResult {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
        let originalSize = original.count

        let tmp = scratchFile("jpg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-s", "format", "jpeg", file, "--out", tmp]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: tmp) {
                let result: EngineResult
                switch options.outputFormat {
                case .webp: result = compressToWebP(file: tmp, options: options)
                case .avif: result = compressToAVIF(file: tmp, options: options)
                case .png: result = compressPNG(file: tmp, options: options)
                case .jpg, .original:
                    result = compressJPG(file: tmp, options: options)
                default:
                    result = compressJPG(file: tmp, options: options)
                }
                if result.success {
                    try? FileManager.default.removeItem(atPath: tmp)
                    return EngineResult(
                        success: true, compressed: result.compressed,
                        outType: result.outType, algorithm: "sips+\(result.algorithm)",
                        error: result.error
                    )
                }
                // 回退：直接用 sips 转换后的 JPEG
                if let data = FileManager.default.contents(atPath: tmp), !data.isEmpty {
                    try? FileManager.default.removeItem(atPath: tmp)
                    return EngineResult(success: true, compressed: data, outType: "jpg", algorithm: "sips")
                }
                try? FileManager.default.removeItem(atPath: tmp)
            }
        } catch {}
        try? FileManager.default.removeItem(atPath: tmp)
        return noImprovement(original: original, outType: "heic", algorithm: "sips", originalSize: originalSize)
    }

    // MARK: - Helpers

    /// 在专用工作目录 `$TMPDIR/octoshrink-work/` 下创建中间文件。
    /// 集中到子目录后，启动/退出时删整个目录即可清掉崩溃残留与正常残留。
    private static func scratchFile(_ ext: String) -> String {
        let dir = NSTemporaryDirectory() + "octoshrink-work"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/" + UUID().uuidString + "." + ext
    }

    static func noImprovement(original: Data, outType: String, algorithm: String, originalSize: Int) -> EngineResult {
        let msg = "压缩后 \(CompressResult.formatBytes(Int64(original.count))) ≥ 原始 \(CompressResult.formatBytes(Int64(originalSize)))，原图已是最优压缩"
        return EngineResult(success: true, compressed: original, outType: outType, algorithm: algorithm, error: msg)
    }
}
