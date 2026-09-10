import Foundation

enum ProcessingMode: String, CaseIterable {
    case system = "system"
    case advanced = "advanced"

    var label: String {
        switch self {
        case .system: return "系统转换"
        case .advanced: return "高级压缩"
        }
    }
}

enum OutputFormat: String, CaseIterable {
    case original = "original"
    case jpg = "jpg"
    case png = "png"
    case heic = "heic"
    case webp = "webp"
    case avif = "avif"

    var label: String {
        switch self {
        case .original: return "原格式"
        case .jpg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIF"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }
}

enum OutputMode: String, CaseIterable {
    case replace = "replace"
    case suffix = "suffix"
    case folder = "folder"

    var label: String {
        switch self {
        case .replace: return "覆盖原文件"
        case .suffix: return "添加自定义后缀"
        case .folder: return "输出到指定文件夹"
        }
    }
}

enum SystemImageSize: String, CaseIterable {
    case actual = "actual"
    case large = "large"
    case medium = "medium"
    case small = "small"

    var label: String {
        switch self {
        case .actual: return "实际大小"
        case .large: return "大（最长边 1280 px）"
        case .medium: return "中（最长边 640 px）"
        case .small: return "小（最长边 320 px）"
        }
    }

    /// 与 Tauri 一致的算法后缀标签
    var shortLabel: String {
        switch self {
        case .actual: return "实际大小"
        case .large: return "大"
        case .medium: return "中"
        case .small: return "小"
        }
    }
}

enum CompressionBackend: String, CaseIterable {
    case auto = "auto"
    case sharp = "sharp"
    case cli = "cli"

    var label: String {
        switch self {
        case .auto: return "自动选择（推荐）"
        case .sharp: return "现代引擎（推荐）"
        case .cli: return "CLI 工具"
        }
    }
}

enum CompressionEffort: Int, CaseIterable {
    case fast = 4
    case balanced = 6
    case high = 7
    case extreme = 9

    var label: String {
        switch self {
        case .fast: return "快速"
        case .balanced: return "平衡（推荐）"
        case .high: return "高质量"
        case .extreme: return "极致压缩（慢）"
        }
    }
}

struct CompressOptions {
    var processingMode: ProcessingMode = .advanced
    var systemImageSize: SystemImageSize = .actual
    var preserveMetadata: Bool = true
    var quality: Int = 75
    var smartMode: Bool = false
    var outputFormat: OutputFormat = .original
    var backend: CompressionBackend = .auto
    var effort: CompressionEffort = .balanced
    var convertToWebp: Bool = false
    var outputMode: OutputMode = .suffix
    var outputSuffix: String = "_compressed"
    var outputDir: String?
    var sourceRoots: [String] = []
}
