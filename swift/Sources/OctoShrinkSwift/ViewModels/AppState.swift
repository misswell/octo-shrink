import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Cancel tracking (thread-safe, nonisolated)

final class CancelBox: @unchecked Sendable {
    private var paths: Set<String> = []
    private let lock = NSLock()
    func insert(_ p: String) { lock.lock(); paths.insert(p); lock.unlock() }
    func contains(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return paths.contains(p) }
    func removeAll() { lock.lock(); paths.removeAll(); lock.unlock() }
}

// MARK: - Theme

enum AppTheme: String, CaseIterable {
    case auto = "auto", light = "light", dark = "dark"
    var label: String {
        switch self {
        case .auto: return "自动（跟随系统）"
        case .light: return "亮色模式"
        case .dark: return "暗黑模式"
        }
    }
    var shortLabel: String {
        switch self {
        case .auto: return "自动"
        case .light: return "亮色"
        case .dark: return "暗黑"
        }
    }
    var iconName: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    func resolved() -> Bool { // true = dark
        switch self {
        case .dark: return true
        case .light: return false
        case .auto: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
    func next() -> AppTheme {
        let all = AppTheme.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}

// MARK: - Sort Key

enum SortKey: String, CaseIterable {
    case importOrder = "import"
    case name = "name"
    case originalSize = "original"
    case compressedSize = "compressed"
    case ratio = "ratio"
    case status = "status"

    var label: String {
        switch self {
        case .importOrder: return "导入顺序"
        case .name: return "名称"
        case .originalSize: return "原始大小"
        case .compressedSize: return "压缩后大小"
        case .ratio: return "压缩比"
        case .status: return "状态"
        }
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    // 队列
    @Published var items: [QueueItem] = []
    @Published var options = CompressOptions()
    @Published var isCompressing = false
    @Published var compressProgress: Double = 0
    @Published var compressCurrent = 0
    @Published var compressTotal = 0
    @Published var compressDoneText = ""

    // 设置 UI
    @Published var settingsExpanded = false
    @Published var autoCompress = false
    @Published var sortKey: SortKey = .importOrder
    @Published var sortAscending = true
    @Published var onlyShowFailed = false

    // 主题
    @Published var theme: AppTheme = .auto

    // Toast
    @Published var toastMessage: String?
    @Published var toastVisible = false

    // 关于
    @Published var showAbout = false

    // 版本
    @Published var appVersion: String = ""

    // 自动压缩续队列
    private var pendingAutoCompress = false
    private let cancelBox = CancelBox()

    // MARK: - Display items (filter + sort)

    var displayItems: [QueueItem] {
        var list = items
        if onlyShowFailed {
            list = list.filter { $0.status == .failed }
        }
        list.sort { a, b in
            let result: Bool
            switch sortKey {
            case .importOrder:
                let ai = items.firstIndex(where: { $0.id == a.id }) ?? 0
                let bi = items.firstIndex(where: { $0.id == b.id }) ?? 0
                return sortAscending ? ai < bi : ai > bi
            case .name:
                result = a.fileName.localizedCompare(b.fileName) == .orderedAscending
            case .originalSize:
                result = a.fileSize < b.fileSize
            case .compressedSize:
                let av = a.result?.compressedSize ?? a.fileSize
                let bv = b.result?.compressedSize ?? b.fileSize
                result = av < bv
            case .ratio:
                result = (a.result?.savings ?? -Double.greatestFiniteMagnitude) < (b.result?.savings ?? -Double.greatestFiniteMagnitude)
            case .status:
                let order: [QueueStatus: Int] = [.failed: 0, .compressing: 1, .waiting: 2, .done: 3, .restored: 4, .skipped: 5, .cancelled: 6]
                result = (order[a.status] ?? 9) < (order[b.status] ?? 9)
            }
            return sortAscending ? result : !result
        }
        return list
    }

    // MARK: - Stats

    var totalOriginal: Int64 {
        items.reduce(0) { sum, item in
            guard let r = item.result, r.success else { return sum }
            return sum + r.originalSize
        }
    }
    var totalCompressed: Int64 {
        items.reduce(0) { sum, item in
            guard let r = item.result, r.success else { return sum }
            return sum + r.compressedSize
        }
    }
    var totalSaved: Int64 { max(0, totalOriginal - totalCompressed) }
    var totalSavingsPct: Double {
        guard totalOriginal > 0 else { return 0 }
        return (1.0 - Double(totalCompressed) / Double(totalOriginal)) * 100.0
    }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var hasRestorable: Bool { items.contains { $0.result?.backupPath != nil && $0.status == .done } }
    var pendingCount: Int { items.filter { $0.status == .waiting || $0.status == .failed }.count }

    // MARK: - Settings summary

    var settingsSummary: String {
        var parts: [String] = []
        if autoCompress { parts.append("自动") }
        if options.processingMode == .system {
            parts.append("系统")
            parts.append(options.outputFormat.label)
            parts.append(options.systemImageSize.label.split(separator: "（").first.map(String.init) ?? "")
        } else {
            parts.append("Q\(options.quality)")
            parts.append(options.outputFormat == .original ? "原格式" : options.outputFormat.label.uppercased())
            parts.append(options.smartMode ? "智能" : "标准")
        }
        switch options.outputMode {
        case .replace: parts.append("覆盖")
        case .suffix: parts.append("后缀 \(options.outputSuffix)")
        case .folder: parts.append("目录")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Version

    func detectVersion() {
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.5.30"
        loadSettings()
        loadTheme()
    }

    // MARK: - Theme

    func cycleTheme() {
        theme = theme.next()
        saveTheme()
        let ns: NSAppearance
        if theme.resolved() { ns = NSAppearance(named: .darkAqua)! }
        else { ns = NSAppearance(named: .aqua)! }
        NSApp.appearance = ns
        showToast("主题: \(theme.shortLabel)")
    }

    private func loadTheme() {
        let raw = UserDefaults.standard.string(forKey: "octoshrink-theme") ?? "auto"
        theme = AppTheme(rawValue: raw) ?? .auto
        let ns: NSAppearance
        if theme.resolved() { ns = NSAppearance(named: .darkAqua)! }
        else { ns = NSAppearance(named: .aqua)! }
        NSApp.appearance = ns
    }

    private func saveTheme() {
        UserDefaults.standard.set(theme.rawValue, forKey: "octoshrink-theme")
    }

    // MARK: - Settings persistence

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(options.processingMode.rawValue, forKey: "setting-processingMode")
        d.set(options.systemImageSize.rawValue, forKey: "setting-systemImageSize")
        d.set(options.preserveMetadata, forKey: "setting-preserveMetadata")
        d.set(options.quality, forKey: "setting-quality")
        d.set(options.outputFormat.rawValue, forKey: "setting-outputFormat")
        d.set(options.backend.rawValue, forKey: "setting-backend")
        d.set(options.effort.rawValue, forKey: "setting-effort")
        d.set(options.convertToWebp, forKey: "setting-convertToWebp")
        d.set(options.smartMode, forKey: "setting-smartMode")
        d.set(options.outputMode.rawValue, forKey: "setting-outputMode")
        d.set(options.outputSuffix, forKey: "setting-outputSuffix")
        d.set(autoCompress, forKey: "setting-autoCompress")
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "setting-processingMode"), let v = ProcessingMode(rawValue: raw) { options.processingMode = v }
        if let raw = d.string(forKey: "setting-systemImageSize"), let v = SystemImageSize(rawValue: raw) { options.systemImageSize = v }
        if d.object(forKey: "setting-preserveMetadata") != nil { options.preserveMetadata = d.bool(forKey: "setting-preserveMetadata") }
        if d.object(forKey: "setting-quality") != nil { options.quality = d.integer(forKey: "setting-quality") }
        if let raw = d.string(forKey: "setting-outputFormat"), let v = OutputFormat(rawValue: raw) { options.outputFormat = v }
        if let raw = d.string(forKey: "setting-backend"), let v = CompressionBackend(rawValue: raw) { options.backend = v }
        if let raw = d.string(forKey: "setting-effort"), let v = CompressionEffort(rawValue: raw) { options.effort = v }
        if d.object(forKey: "setting-convertToWebp") != nil { options.convertToWebp = d.bool(forKey: "setting-convertToWebp") }
        if d.object(forKey: "setting-smartMode") != nil { options.smartMode = d.bool(forKey: "setting-smartMode") }
        if let raw = d.string(forKey: "setting-outputMode"), let v = OutputMode(rawValue: raw) { options.outputMode = v }
        if let raw = d.string(forKey: "setting-outputSuffix"), !raw.isEmpty { options.outputSuffix = raw }
        autoCompress = d.bool(forKey: "setting-autoCompress")
    }

    func resetSettings() {
        UserDefaults.standard.removeObject(forKey: "octoshrink-settings")
        options = CompressOptions()
        autoCompress = false
        saveSettings()
        showToast("已还原默认设置")
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toastMessage = message
        toastVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
            toastVisible = false
        }
    }

    // MARK: - Effective format (convertToWebp when original)

    var effectiveOutputFormat: OutputFormat {
        if options.processingMode == .advanced && options.convertToWebp && options.outputFormat == .original {
            return .webp
        }
        return options.outputFormat
    }

    // MARK: - Import

    func addFiles(paths: [String]) {
        let expanded = expandImageFiles(paths: paths)
        let existing = Set(items.map(\.path))
        var added = 0
        for path in expanded where !existing.contains(path) {
            // 移除已取消的同路径行，重新添加为 waiting
            if let idx = items.firstIndex(where: { $0.path == path && $0.status == .cancelled }) {
                items.remove(at: idx)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            items.append(QueueItem(
                path: path,
                fileName: (path as NSString).lastPathComponent,
                fileSize: size
            ))
            added += 1
        }
        // 记录来源根目录
        for root in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
               isDir.boolValue,
               !options.sourceRoots.contains(root) {
                options.sourceRoots.append(root)
            }
        }
        if added == 0 && !expanded.isEmpty {
            showToast("所选图片已在队列中")
        }
        // 自动压缩
        if autoCompress && added > 0 {
            if isCompressing {
                pendingAutoCompress = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                    if autoCompress && !isCompressing { startCompress() }
                }
            }
        }
    }

    func addFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            addFiles(paths: panel.urls.map(\.path))
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            addFiles(paths: panel.urls.map(\.path))
        }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            options.outputDir = url.path
            saveSettings()
        }
    }

    func clearQueue() {
        guard !isCompressing else {
            showToast("压缩进行中，请先取消")
            return
        }
        items.removeAll()
        options.sourceRoots.removeAll()
        pendingAutoCompress = false
    }

    func removeItem(path: String) {
        cancelBox.insert(path)
        if let idx = items.firstIndex(where: { $0.path == path }) {
            items[idx].status = .cancelled
        }
    }

    // MARK: - Batch compress

    func startCompress() {
        guard !isCompressing else { return }
        if options.outputMode == .folder && options.outputDir == nil {
            showToast("请先选择输出目录")
            return
        }
        let pending = items.filter { $0.status == .waiting || $0.status == .failed }
        guard !pending.isEmpty else { return }

        isCompressing = true
        compressTotal = pending.count
        compressCurrent = 0
        compressProgress = 0
        compressDoneText = ""
        cancelBox.removeAll()

        var opts = options
        opts.outputFormat = effectiveOutputFormat

        var processed = 0
        let semaphore = DispatchSemaphore(value: 3)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "octoshrink.compress", attributes: .concurrent)

        for item in pending {
            group.enter()
            queue.async { [self] in
                semaphore.wait()
                defer { semaphore.signal(); group.leave() }
                if isCancelled(item.path) {
                    DispatchQueue.main.async {
                        self.updateStatus(item.path, .cancelled)
                        processed += 1
                        self.compressCurrent = processed
                        self.compressProgress = Double(processed) / Double(pending.count)
                    }
                    return
                }
                DispatchQueue.main.async { self.updateStatus(item.path, .compressing) }
                let result = Self.compressOneStatic(path: item.path, options: opts)
                DispatchQueue.main.async {
                    self.applyResult(item.path, result: result)
                    processed += 1
                    self.compressCurrent = processed
                    self.compressProgress = Double(processed) / Double(pending.count)
                }
            }
        }

        group.notify(queue: .main) { [self] in
            self.isCompressing = false
            self.compressDoneText = options.processingMode == .system ? "转换完成" : "压缩完成"
            cancelBox.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                compressDoneText = ""
            }
            // 自动续队列
            let stillPending = items.filter { $0.status == .waiting || $0.status == .failed }
            if pendingAutoCompress && !stillPending.isEmpty {
                pendingAutoCompress = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                    self.startCompress()
                }
            } else {
                pendingAutoCompress = false
            }
        }
    }

    func cancelAll() {
        for i in items.indices {
            if items[i].status == .waiting || items[i].status == .compressing {
                cancelBox.insert(items[i].path)
                items[i].status = .cancelled
            }
        }
    }

    func cancelFile(path: String) {
        cancelBox.insert(path)
        if let idx = items.firstIndex(where: { $0.path == path }) {
            if items[idx].status == .compressing || items[idx].status == .waiting {
                items[idx].status = .cancelled
            }
        }
    }

    nonisolated private func isCancelled(_ path: String) -> Bool {
        cancelBox.contains(path)
    }

    private func updateStatus(_ path: String, _ status: QueueStatus) {
        if let idx = items.firstIndex(where: { $0.path == path }) {
            items[idx].status = status
        }
    }

    private func applyResult(_ path: String, result: CompressResult) {
        guard let idx = items.firstIndex(where: { $0.path == path }) else { return }
        items[idx].result = result
        if !result.success {
            items[idx].status = .failed
        } else if result.error != nil {
            items[idx].status = .skipped
        } else {
            items[idx].status = .done
        }
    }

    // MARK: - Single compress

    nonisolated private static func compressOneStatic(path: String, options: CompressOptions) -> CompressResult {
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let engineResult = CompressionEngine.compress(file: path, options: options)
        var result = CompressResult(engine: engineResult, file: path, originalSize: originalSize)
        writeOutputStatic(&result, compressed: engineResult.compressed, options: options)
        return result
    }

    nonisolated private static func writeOutputStatic(_ result: inout CompressResult, compressed: Data, options: CompressOptions) {
        guard result.success, !compressed.isEmpty else { return }
        let isFormatConversion = options.outputFormat != .original
        if !isFormatConversion && Int64(compressed.count) >= result.originalSize {
            result.error = "原图已是最优，无需替换"
            return
        }

        let outExt = ".\(result.outType)"
        let fm = FileManager.default
        let path = result.file

        switch options.outputMode {
        case .replace:
            let backupDir = NSTemporaryDirectory() + "octoshrink-backups"
            try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            let hash = String(path.hashValue.magnitude)
            let baseName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let backupPath = (backupDir as NSString).appendingPathComponent("\(baseName)_\(hash)")
            if !fm.fileExists(atPath: backupPath) {
                try? fm.copyItem(atPath: path, toPath: backupPath)
            }
            result.backupPath = backupPath

            let currentExt = ((path as NSString).pathExtension).lowercased()
            let sameFormat = currentExt == result.outType
                || (currentExt == "jpeg" && result.outType == "jpg")
                || (currentExt == "jpg" && result.outType == "jpeg")
                || (currentExt == "heif" && result.outType == "heic")
                || (currentExt == "heic" && result.outType == "heif")
            let outPath: String
            if options.processingMode == .system && isFormatConversion && !sameFormat {
                outPath = availableSystemConversionPath(file: path, outType: result.outType)
            } else {
                outPath = path
            }
            try? compressed.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            if outPath != path {
                try? fm.removeItem(atPath: path)
            }
            result.outputPath = outPath

        case .suffix:
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let dir = (path as NSString).deletingLastPathComponent
            let suffix = normalizedOutputSuffix(options.outputSuffix)
            let outPath = (dir as NSString).appendingPathComponent("\(stem)\(suffix)\(outExt)")
            try? compressed.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            result.outputPath = outPath

        case .folder:
            guard let outDir = options.outputDir else { return }
            let rel = relativePathFromRoots(file: path, roots: options.sourceRoots)
                ?? (path as NSString).lastPathComponent
            let relOut = (rel as NSString).deletingPathExtension + outExt
            let outPath = (outDir as NSString).appendingPathComponent(relOut)
            try? fm.createDirectory(
                atPath: (outPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? compressed.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            result.outputPath = outPath
        }
        result.outputMode = options.outputMode.rawValue
    }

    // MARK: - Retry single file

    func retryFile(path: String) {
        guard !isCompressing else { return }
        if let idx = items.firstIndex(where: { $0.path == path }) {
            items[idx].status = .waiting
            items[idx].result = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            startCompress()
        }
    }

    // MARK: - Restore

    func restoreFile(path: String) {
        guard let idx = items.firstIndex(where: { $0.path == path }),
              let result = items[idx].result else { return }

        // 删除输出文件
        if let outPath = result.outputPath, outPath != path {
            try? FileManager.default.removeItem(atPath: outPath)
        }
        // 从备份恢复
        if let backup = result.backupPath, FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: backup, toPath: path)
        }
        items[idx].result = nil
        items[idx].status = .restored
        items[idx].fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? items[idx].fileSize
        showToast("已恢复原图: \(items[idx].fileName)")
    }

    func restoreAll() {
        let restorable = items.filter { $0.status == .done && $0.result?.backupPath != nil }
        guard !restorable.isEmpty else { return }
        var count = 0
        for item in restorable {
            restoreFile(path: item.path)
            count += 1
        }
        showToast("已恢复 \(count) 个文件到原图")
    }

    // MARK: - Save as

    func saveResult(path: String) {
        guard let result = items.first(where: { $0.path == path })?.result,
              let outPath = result.outputPath else {
            showToast("无法保存：找不到压缩文件")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (outPath as NSString).lastPathComponent
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(atPath: outPath, toPath: dest.path)
            showToast("已保存到: \(dest.lastPathComponent)")
        }
    }

    // MARK: - Export all

    func exportAll() {
        let doneItems = items.filter { $0.status == .done && $0.result?.outputPath != nil }
        guard !doneItems.isEmpty else { return }
        let suffix = options.outputSuffix
        var count = 0
        for item in doneItems {
            guard let outPath = item.result?.outputPath else { continue }
            // 在原目录生成带后缀的副本
            let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let dir = (item.path as NSString).deletingLastPathComponent
            let ext = (outPath as NSString).pathExtension
            let destPath = (dir as NSString).appendingPathComponent("\(stem)\(suffix).\(ext)")
            if destPath != outPath {
                try? FileManager.default.copyItem(atPath: outPath, toPath: destPath)
                count += 1
            }
        }
        showToast("已导出 \(count) 个文件到原目录（\(suffix) 后缀）")
    }

    // MARK: - Copy log

    func copyLog(path: String) {
        guard let item = items.first(where: { $0.path == path }),
              let result = item.result else { return }
        var lines: [String] = []
        lines.append("版本: Swift Native")
        lines.append("=== OctoShrink 压缩日志 ===")
        lines.append("")
        lines.append("文件: \(result.file)")
        lines.append("状态: \(result.success ? "成功" : "失败")")
        lines.append("")
        lines.append("--- 压缩参数 ---")
        lines.append("quality: \(options.quality)")
        lines.append("smartMode: \(options.smartMode)")
        lines.append("outputFormat: \(effectiveOutputFormat.rawValue)")
        lines.append("backend: \(options.backend.rawValue)")
        lines.append("effort: \(options.effort.rawValue)")
        lines.append("convertToWebp: \(options.convertToWebp)")
        lines.append("outputMode: \(options.outputMode.rawValue)")
        lines.append("outputSuffix: \(options.outputSuffix)")
        lines.append("")
        lines.append("--- 压缩结果 ---")
        if result.success {
            lines.append("原始大小: \(result.originalSizeFormatted) (\(result.originalSize) bytes)")
            lines.append("压缩后大小: \(result.compressedSizeFormatted) (\(result.compressedSize) bytes)")
            lines.append("压缩率: \(result.savings >= 0 ? "-" : "+")\(String(format: "%.1f", abs(result.savings)))%")
            lines.append("输出格式: \(result.outType)")
            lines.append("算法: \(result.algorithm)")
        } else {
            lines.append("压缩失败")
        }
        lines.append("")
        lines.append("--- 错误信息 ---")
        lines.append(result.error ?? "(无)")
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("压缩日志已复制到剪贴板")
    }

    // MARK: - Open in Finder

    func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: - Helpers

    nonisolated private static func normalizedOutputSuffix(_ suffix: String) -> String {
        var s = suffix.isEmpty ? "_compressed" : suffix
        for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            s = s.replacingOccurrences(of: ch, with: "_")
        }
        return s
    }

    nonisolated private static func availableSystemConversionPath(file: String, outType: String) -> String {
        let preferred = (file as NSString).deletingPathExtension + "." + outType
        if !FileManager.default.fileExists(atPath: preferred) { return preferred }
        let stem = (file as NSString).deletingPathExtension
        let dir = (file as NSString).deletingLastPathComponent
        for i in 1... {
            let suffix = i == 1 ? "_converted" : "_converted_\(i)"
            let candidate = (dir as NSString).appendingPathComponent("\((stem as NSString).lastPathComponent)\(suffix).\(outType)")
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return preferred
    }

    nonisolated private static func relativePathFromRoots(file: String, roots: [String]) -> String? {
        for root in roots where file.hasPrefix(root + "/") {
            return String(file.dropFirst(root.count + 1))
        }
        return nil
    }
}
