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

    var originalSizeFormatted: String { Self.formatBytes(originalSize) }
    var compressedSizeFormatted: String { Self.formatBytes(compressedSize) }
    var savingsFormatted: String { String(format: "%.1f%%", savings) }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return String(format: "%.1fB", Double(bytes)) }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
    }

    init(engine: EngineResult, file: String, originalSize: Int64) {
        self.success = engine.success
        self.file = file
        self.originalSize = originalSize
        self.compressedSize = Int64(engine.compressed.count)
        self.savings = originalSize > 0
            ? (1.0 - Double(engine.compressed.count) / Double(originalSize)) * 100.0
            : 0
        self.outType = engine.outType
        self.algorithm = engine.algorithm
        self.error = engine.error
    }
}

enum QueueStatus: String {
    case waiting = "waiting"
    case compressing = "compressing"
    case done = "done"
    case failed = "failed"
    case cancelled = "cancelled"
    case skipped = "skipped"
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

let supportedExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif"
]

func expandImageFiles(paths: [String]) -> [String] {
    var result: [String] = []
    let fm = FileManager.default
    for path in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            if let enumerator = fm.enumerator(atPath: path) {
                while let item = enumerator.nextObject() as? String {
                    let full = (path as NSString).appendingPathComponent(item)
                    var itemIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &itemIsDir), !itemIsDir.boolValue else { continue }
                    let ext = (full as NSString).pathExtension.lowercased()
                    if supportedExtensions.contains(ext) {
                        result.append(full)
                    }
                }
            }
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                result.append(path)
            }
        }
    }
    // 去重但保持原始顺序（目录枚举顺序 + 文件选择顺序）
    var seen = Set<String>()
    return result.filter { seen.insert($0).inserted }
}
