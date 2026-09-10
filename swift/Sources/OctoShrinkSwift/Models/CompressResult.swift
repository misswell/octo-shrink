import Foundation

struct EngineResult {
    var success: Bool
    var compressed: Data
    var outType: String
    var algorithm: String
    var error: String?
}

struct CompressResult: Identifiable {
    let id = UUID()
    var success: Bool
    var file: String
    var originalSize: Int64
    var compressedSize: Int64
    var savings: Double
    var outType: String
    var algorithm: String
    var error: String?
    var outputPath: String?
    var backupPath: String?
    var outputMode: String?
    /// 本批次使用的压缩参数快照（复制日志用，与 Tauri 的 result.compressOptions 对应）
    var options: CompressOptions?

    var originalSizeFormatted: String { Self.formatBytes(originalSize) }
    var compressedSizeFormatted: String { Self.formatBytes(compressedSize) }
    var savingsFormatted: String { String(format: "%.1f%%", savings) }
    /// 与 Tauri 前端一致：节省 >= 0 显示 "-N.N%"，否则 "+N.N%"
    var savingsSignedText: String {
        "\(savings >= 0 ? "-" : "+")\(String(format: "%.1f", abs(savings)))%"
    }

    /// 与 Rust `engine::format_bytes` 对齐（用于 originalSizeFormatted / compressedSizeFormatted）
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return String(format: "%.1fB", Double(bytes)) }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
    }

    /// 与前端 JS `formatBytes` 对齐（用于统计条、队列行大小）：0 显示为 "0B"
    static func formatBytesJS(_ bytes: Int64) -> String {
        if bytes == 0 { return "0B" }
        if bytes < 1024 { return String(format: "%.1fB", Double(bytes)) }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
    }

    init(engine: EngineResult, file: String, originalSize: Int64, options: CompressOptions? = nil) {
        let compressedSize = Int64(engine.compressed.count)
        self.success = engine.success
        self.file = file
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        let raw: Double
        if originalSize > 0 {
            raw = (Double(originalSize) - Double(min(compressedSize, originalSize))) / Double(originalSize) * 100.0
        } else {
            raw = 0
        }
        self.savings = (raw * 10).rounded() / 10
        self.outType = engine.outType
        self.algorithm = engine.algorithm
        self.error = engine.error
        self.options = options
    }
}

enum QueueStatus: String {
    case waiting = "waiting"
    case compressing = "compressing"
    case done = "done"
    case failed = "failed"
    /// 用户从队列里移除（等待中移除）
    case removed = "removed"
    /// 压缩过程中被取消 / 跳过
    case cancelled = "cancelled"
    case restored = "restored"
}

struct QueueItem: Identifiable {
    let id = UUID()
    var path: String
    var fileName: String
    var fileSize: Int64
    var status: QueueStatus = .waiting
    var result: CompressResult?
}

func detectImageType(path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "unknown" }
    let bytes = [UInt8](data.prefix(12))
    if bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
        return "png"
    }
    if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        return "jpg"
    }
    if bytes.count >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
        return "gif"
    }
    if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
        return "webp"
    }
    if bytes.count >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D {
        return "bmp"
    }
    if bytes.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
        let brand = String(bytes: bytes[8..<12], encoding: .utf8) ?? ""
        if ["heic", "heix", "mif1", "hevc"].contains(brand) {
            return "heic"
        }
    }
    return "unknown"
}

/// 与 Tauri 后端 collect_image_files 的支持扩展名保持一致
let supportedExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp",
    "avif", "jxl", "heic", "heif", "tif", "tiff"
]

/// 规范化路径（解析符号链接，如 /tmp → /private/tmp），与 Tauri `canonicalize` 对齐。
/// 去重必须基于规范化路径，否则同一文件以两种写法出现时会重复入队。
func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

func expandImageFiles(paths: [String]) -> [String] {
    var result: [String] = []
    let fm = FileManager.default
    for path in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            var dirFiles: [String] = []
            if let enumerator = fm.enumerator(atPath: path) {
                while let item = enumerator.nextObject() as? String {
                    let full = (path as NSString).appendingPathComponent(item)
                    var itemIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &itemIsDir), !itemIsDir.boolValue else { continue }
                    let ext = (full as NSString).pathExtension.lowercased()
                    if supportedExtensions.contains(ext) {
                        dirFiles.append(canonicalPath(full))
                    }
                }
            }
            result.append(contentsOf: dirFiles.sorted())
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                result.append(canonicalPath(path))
            }
        }
    }
    // 去重但保持顺序（目录内已排序 + 文件选择顺序）
    var seen = Set<String>()
    return result.filter { seen.insert($0).inserted }
}
