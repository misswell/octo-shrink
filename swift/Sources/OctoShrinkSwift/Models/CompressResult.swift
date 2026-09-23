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
        self.success = engine.success
        self.file = file
        self.originalSize = originalSize
        self.compressedSize = Int64(engine.compressed.count)
        self.savings = Self.savings(originalSize: originalSize, compressedSize: self.compressedSize)
        self.outType = engine.outType
        self.algorithm = engine.algorithm
        self.error = engine.error
        self.options = options
    }

    /// 历史页要复用对比窗口/复制日志那一套，但记录里只有大小、没有字节本身。
    init(historyEntry entry: HistoryEntry) {
        self.success = true
        self.file = entry.sourcePath
        self.originalSize = entry.originalSize
        self.compressedSize = entry.compressedSize
        self.savings = entry.savings
        self.outType = entry.outType
        self.algorithm = entry.algorithm
        self.error = nil
        self.outputPath = entry.outputPath
        self.backupPath = entry.backupPath
        self.outputMode = entry.outputMode
        self.options = nil
    }

    static func savings(originalSize: Int64, compressedSize: Int64) -> Double {
        guard originalSize > 0 else { return 0 }
        let raw = (Double(originalSize) - Double(min(compressedSize, originalSize)))
            / Double(originalSize) * 100.0
        return (raw * 10).rounded() / 10
    }
}

/// 队列项的持久状态 —— **只有这六种**。
///
/// 暂停 / 停止是**这一轮执行**的状态（`CompressionPhase`），不是文件的状态：
/// 被停止挡在门外的文件照旧是 `pending`，下一轮「继续压缩」自然还会带上它。
/// 老实现用 `cancelled` 同时表达"用户把它移出队列"和"停止时这一轮没轮到它"，
/// 于是停止之后剩下的图全都变成"已跳过"，再也压不动 —— 这两件事必须分开。
enum QueueStatus: String {
    /// 还需要压缩：第一次没开始、暂停中等待、停止后留待下一轮、新导入，都是它。
    case pending = "pending"
    /// 真的在压。
    case running = "running"
    case done = "done"
    /// 压完了但失败。只有显式「重试」才会回到 pending，普通「继续压缩」不碰它。
    case failed = "failed"
    /// 用户把它移出了队列。
    case removed = "removed"
    /// 用户把这次压缩撤销了（原图回来了）。要压得重新点。
    case restored = "restored"
}

struct QueueItem: Identifiable {
    let id = UUID()
    var path: String
    var fileName: String
    var fileSize: Int64
    var status: QueueStatus = .pending
    var result: CompressResult?
}

/// 队列进度 —— **队列的派生值**，不是某一轮的计数器。
///
/// 主界面显示的永远是它（与 Tauri 前端 `getQueueProgress` 同一套判据）。
/// 停止之后重新开始一轮时，那一轮的目标会变小（只含 pending），
/// 但这里的 total 始终是整个队列，所以进度不会从 40/100 掉回 0/60。
struct QueueProgress {
    var total = 0
    var done = 0
    var failed = 0
    var running = 0
    var pending = 0

    /// 已处理 = 成功 + 失败。失败的文件确实跑完了一次，只是没成 ——
    /// 不算它的话，98 成功 + 2 失败的队列会永远停在 98%。
    var processed: Int { done + failed }
    var fraction: Double { total > 0 ? Double(processed) / Double(total) : 0 }

    /// 摘要那一行（失败为 0 时不写那一段）。
    var summaryText: String {
        failed > 0 ? "\(processed) / \(total) 已处理 · 失败 \(failed)" : "\(processed) / \(total) 已处理"
    }

    init(items: [QueueItem]) {
        for item in items {
            // removed / restored 已经离开了这套账：一个被移出队列，一个被用户撤销了。
            switch item.status {
            case .removed, .restored: continue
            case .done: done += 1
            case .failed: failed += 1
            case .running: running += 1
            case .pending: pending += 1
            }
            total += 1
        }
    }
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
