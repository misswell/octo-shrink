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
    /// 是否已导入过文件：与 Tauri 一致，压缩设置面板在首次导入后才显示
    @Published var hasImported = false
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
                let av = a.result?.originalSize ?? a.fileSize
                let bv = b.result?.originalSize ?? b.fileSize
                result = av < bv
            case .compressedSize:
                let av = a.result?.success == true ? a.result!.compressedSize : nil
                let bv = b.result?.success == true ? b.result!.compressedSize : nil
                if av == nil { return false }
                if bv == nil { return true }
                result = av! < bv!
            case .ratio:
                let av = a.result?.success == true ? a.result!.savings : nil
                let bv = b.result?.success == true ? b.result!.savings : nil
                if av == nil { return false }
                if bv == nil { return true }
                result = av! < bv!
            case .status:
                let order: [QueueStatus: Int] = [.failed: 0, .compressing: 1, .waiting: 2, .done: 3, .restored: 4, .removed: 5, .cancelled: 6]
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
    var totalSaved: Int64 { totalOriginal - totalCompressed }
    var totalSavingsPct: Double {
        guard totalOriginal > 0 else { return 0 }
        return Double(totalSaved) / Double(totalOriginal) * 100.0
    }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    /// 只要有成功结果即可恢复（与 Tauri 展示「恢复全部原图」的条件一致）
    var hasRestorable: Bool { items.contains { $0.result?.success == true } }
    var pendingCount: Int { items.filter { $0.status == .waiting || $0.status == .failed }.count }

    var comparableResults: [CompressResult] {
        items.compactMap(\.result).filter { $0.success }
    }

    // MARK: - Settings summary

    var settingsSummary: String {
        var parts: [String] = []
        if autoCompress { parts.append("自动") }
        if options.processingMode == .system {
            parts.append("系统")
            parts.append(options.outputFormat.label)
            let sizeLabel = options.systemImageSize.label
            parts.append(sizeLabel.split(separator: "（").first.map(String.init) ?? sizeLabel)
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
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
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
        if d.object(forKey: "setting-effort") != nil, let v = CompressionEffort(rawValue: d.integer(forKey: "setting-effort")) { options.effort = v }
        if d.object(forKey: "setting-convertToWebp") != nil { options.convertToWebp = d.bool(forKey: "setting-convertToWebp") }
        if d.object(forKey: "setting-smartMode") != nil { options.smartMode = d.bool(forKey: "setting-smartMode") }
        if let raw = d.string(forKey: "setting-outputMode"), let v = OutputMode(rawValue: raw) { options.outputMode = v }
        if let raw = d.string(forKey: "setting-outputSuffix"), !raw.isEmpty { options.outputSuffix = raw }
        autoCompress = d.bool(forKey: "setting-autoCompress")
    }

    func resetSettings() {
        let keys = ["setting-processingMode", "setting-systemImageSize", "setting-preserveMetadata",
                    "setting-quality", "setting-outputFormat", "setting-backend", "setting-effort",
                    "setting-convertToWebp", "setting-smartMode", "setting-outputMode",
                    "setting-outputSuffix", "setting-autoCompress"]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
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
        let incoming = uniqueFilePaths(paths)
        guard !incoming.isEmpty else { return }
        let expanded = expandImageFiles(paths: incoming)
        guard !expanded.isEmpty else {
            showToast("文件夹中没有找到可压缩的图片")
            return
        }
        let existing = Set(items.map(\.path))
        var added = 0
        for path in expanded where !existing.contains(path) {
            // 已移除的行只是历史展示，重新加入时创建全新的等待行
            if let idx = items.firstIndex(where: { $0.path == path && ($0.status == .removed || $0.status == .cancelled) }) {
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
        // 记录来源根目录（用于「输出到指定文件夹」保留相对路径）
        for root in incoming {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
               isDir.boolValue,
               !options.sourceRoots.contains(root) {
                options.sourceRoots.append(root)
            }
        }
        if added == 0 {
            hasImported = true
            showToast("所选图片已在队列中")
            return
        }
        hasImported = true
        // 自动压缩
        if autoCompress {
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
        guard panel.runModal() == .OK else { return }
        addFiles(paths: panel.urls.map(\.path))
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFiles(paths: panel.urls.map(\.path))
    }

    func pickOutputDir() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            options.outputDir = url.path
            saveSettings()
            return true
        }
        return false
    }

    func clearQueue() {
        guard !items.isEmpty || isCompressing else { return }
        let alert = NSAlert()
        alert.messageText = "确定要清空全部 \(items.count) 个文件吗？"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // 压缩中清空时先取消当前批次（与 Tauri clearAllFiles 语义一致）
        if isCompressing {
            for item in items { cancelBox.insert(item.path) }
        }
        items.removeAll()
        options.sourceRoots.removeAll()
        pendingAutoCompress = false
    }

    /// 移除队列中的一行（等待中/压缩中的用「移除」，已完成的不再显示移除按钮）
    func removeItem(path: String) {
        cancelBox.insert(path)
        if let idx = items.firstIndex(where: { $0.path == path }) {
            if items[idx].status == .waiting || items[idx].status == .compressing {
                items[idx].status = .removed
            }
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
        runBatch(paths: pending.map(\.path))
    }

    /// 重试单个文件（与 Tauri compressOneFile 对齐：只处理该文件）
    func retryFile(path: String) {
        guard !isCompressing else { return }
        guard options.outputMode != .folder || options.outputDir != nil else {
            showToast("请先选择输出目录")
            return
        }
        if let idx = items.firstIndex(where: { $0.path == path }) {
            items[idx].status = .waiting
            items[idx].result = nil
        }
        runBatch(paths: [path])
    }

    private func runBatch(paths: [String]) {
        guard !paths.isEmpty else { return }

        isCompressing = true
        compressTotal = paths.count
        compressCurrent = 0
        compressProgress = 0
        compressDoneText = ""
        cancelBox.removeAll()

        var opts = options
        opts.outputFormat = effectiveOutputFormat
        let useSmart = options.processingMode == .advanced
            && (options.smartMode || effectiveOutputFormat != .original)

        let counter = CounterBox()
        let semaphore = DispatchSemaphore(value: 3)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "octoshrink.compress", attributes: .concurrent)

        for path in paths {
            DispatchQueue.main.async { [self] in
                if let idx = items.firstIndex(where: { $0.path == path }), items[idx].status == .waiting {
                    items[idx].status = .compressing
                }
            }
            group.enter()
            queue.async { [self] in
                semaphore.wait()
                defer { semaphore.signal(); group.leave() }
                if isCancelled(path) {
                    DispatchQueue.main.async {
                        self.updateStatus(path, .cancelled)
                        self.tick(counter: counter, total: paths.count)
                    }
                    return
                }
                let result = Self.compressOneStatic(path: path, options: opts, useSmart: useSmart)
                DispatchQueue.main.async {
                    self.applyResult(path, result: result)
                    self.tick(counter: counter, total: paths.count)
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

    private func tick(counter: CounterBox, total: Int) {
        counter.increment()
        compressCurrent = counter.value
        compressProgress = total > 0 ? Double(counter.value) / Double(total) : 0
    }

    /// 取消全部：等待中/压缩中的行标记为已跳过（与 Tauri 的 cancelled 状态一致）
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
        if let idx = items.firstIndex(where: { $0.path == path }),
           items[idx].status == .compressing || items[idx].status == .waiting {
            items[idx].status = .cancelled
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
        items[idx].status = result.success ? .done : .failed
    }

    // MARK: - Single compress

    nonisolated private static func compressOneStatic(path: String, options: CompressOptions, useSmart: Bool) -> CompressResult {
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let engineResult = useSmart
            ? CompressionEngine.compressSmart(file: path, options: options)
            : CompressionEngine.compress(file: path, options: options)
        var result = CompressResult(engine: engineResult, file: path, originalSize: originalSize, options: options)
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
            let backupPath = (backupDir as NSString).appendingPathComponent(Self.base64URLName(path))
            if !fm.fileExists(atPath: backupPath) {
                Self.copyOverwriting(from: path, to: backupPath)
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

    // MARK: - Restore

    func restoreFile(path: String) {
        guard let idx = items.firstIndex(where: { $0.path == path }),
              let result = items[idx].result else { return }
        let succeeded = Self.performRestore(result: result, outputSuffix: result.options?.outputSuffix)
        if succeeded {
            items[idx].result = nil
            items[idx].status = .restored
            items[idx].fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? items[idx].fileSize
            showToast("已恢复原图: \(items[idx].fileName)")
        } else {
            showToast("恢复失败: 未知错误")
        }
    }

    nonisolated private static func performRestore(result: CompressResult, outputSuffix: String?) -> Bool {
        let fm = FileManager.default
        let mode = result.outputMode ?? "suffix"
        switch mode {
        case "replace":
            guard let backup = result.backupPath, fm.fileExists(atPath: backup) else { return false }
            if let out = result.outputPath, out != result.file {
                try? fm.removeItem(atPath: out)
            }
            // FileManager.copyItem 在目标已存在时会失败（Rust fs::copy 会覆盖），
            // 必须先移除再复制，否则 replace 模式恢复会静默失败并丢掉备份。
            try? fm.removeItem(atPath: result.file)
            guard (try? fm.copyItem(atPath: backup, toPath: result.file)) != nil else { return false }
            try? fm.removeItem(atPath: backup)
            return true
        case "suffix":
            if let out = result.outputPath {
                if fm.fileExists(atPath: out) { try? fm.removeItem(atPath: out) }
            } else {
                let stem = ((result.file as NSString).lastPathComponent as NSString).deletingPathExtension
                let dir = (result.file as NSString).deletingLastPathComponent
                let ext = (result.file as NSString).pathExtension
                let suffix = normalizedOutputSuffix(outputSuffix ?? "_compressed")
                let path = (dir as NSString).appendingPathComponent("\(stem)\(suffix).\(ext)")
                if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
            }
            return true
        case "folder":
            if let out = result.outputPath, fm.fileExists(atPath: out) { try? fm.removeItem(atPath: out) }
            if let backup = result.backupPath, fm.fileExists(atPath: backup) { try? fm.removeItem(atPath: backup) }
            return true
        default:
            return false
        }
    }

    func restoreAll() {
        let restorable = items.filter { $0.status == .done && $0.result?.success == true }
        guard !restorable.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "确定要恢复全部已压缩成功的原图吗？"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var count = 0
        for item in restorable {
            guard let result = item.result else { continue }
            if Self.performRestore(result: result, outputSuffix: result.options?.outputSuffix) {
                count += 1
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].result = nil
                    items[idx].status = .restored
                }
            }
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
            if Self.copyOverwriting(from: outPath, to: dest.path) {
                showToast("已保存到: \(dest.lastPathComponent)")
            } else {
                showToast("保存失败，请重试")
            }
        }
    }

    // MARK: - Export all

    func exportAll() {
        let doneItems = items.filter { $0.status == .done && $0.result?.success == true }
        guard !doneItems.isEmpty else { return }
        let suffix = Self.normalizedOutputSuffix(doneItems.first?.result?.options?.outputSuffix ?? options.outputSuffix)
        var count = 0
        for item in doneItems {
            guard let outPath = item.result?.outputPath else { continue }
            let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let dir = (item.path as NSString).deletingLastPathComponent
            let ext = (outPath as NSString).pathExtension
            let destPath = (dir as NSString).appendingPathComponent("\(stem)\(suffix).\(ext)")
            if destPath == outPath { count += 1; continue }
            if Self.copyOverwriting(from: outPath, to: destPath) {
                count += 1
            }
        }
        showToast("已导出 \(count) 个文件到原目录（\(suffix) 后缀）")
    }

    // MARK: - Copy log

    func copyLog(path: String) {
        guard let item = items.first(where: { $0.path == path }),
              let result = item.result else { return }
        let opts = result.options ?? options
        var lines: [String] = []
        lines.append("版本: Swift")
        lines.append("=== OctoShrink 压缩日志 ===")
        lines.append("")
        lines.append("文件: \(result.file)")
        lines.append("状态: \(result.success ? "成功" : "失败")")
        lines.append("")
        lines.append("--- 压缩参数 ---")
        lines.append("quality: \(opts.quality)")
        lines.append("smartMode: \(opts.smartMode)")
        lines.append("outputFormat: \(opts.outputFormat.rawValue)")
        lines.append("backend: \(opts.backend.rawValue)")
        lines.append("effort: \(opts.effort.rawValue)")
        lines.append("convertToWebp: \(opts.convertToWebp)")
        lines.append("outputMode: \(opts.outputMode.rawValue)")
        lines.append("outputSuffix: \(opts.outputSuffix)")
        lines.append("")
        lines.append("--- 压缩结果 ---")
        if result.success {
            lines.append("原始大小: \(CompressResult.formatBytesJS(result.originalSize)) (\(result.originalSize) bytes)")
            lines.append("压缩后大小: \(CompressResult.formatBytesJS(result.compressedSize)) (\(result.compressedSize) bytes)")
            lines.append("压缩率: \(result.savingsSignedText)")
            lines.append("输出格式: \(result.outType.isEmpty ? "(未知)" : result.outType)")
            lines.append("算法: \(result.algorithm.isEmpty ? "(未知)" : result.algorithm)")
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

    // MARK: - Compare integration

    /// 对比窗口重新压缩预览：写入临时文件，不改动用户目录，返回新结果。
    func recompressForCompare(path: String, quality: Int) -> CompressResult? {
        guard let idx = items.firstIndex(where: { $0.path == path }),
              let existing = items[idx].result else { return nil }
        var opts = options
        opts.quality = quality
        opts.backend = .auto
        opts.effort = .balanced
        opts.outputMode = .suffix
        opts.outputFormat = OutputFormat(rawValue: existing.outType) ?? .original
        // 预览用引擎（非 smart，且不做「原图已最优」替换判断）
        let engineResult = CompressionEngine.compress(file: path, options: opts)
        guard engineResult.success else { return nil }
        let dir = NSTemporaryDirectory() + "octoshrink-display"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let previewPath = (dir as NSString).appendingPathComponent("recompress-\(Int(Date().timeIntervalSince1970 * 1_000_000_000)).\(engineResult.outType)")
        do {
            try engineResult.compressed.write(to: URL(fileURLWithPath: previewPath), options: .atomic)
        } catch {
            return nil
        }
        let originalSize = existing.originalSize
        var newResult = CompressResult(engine: engineResult, file: path, originalSize: originalSize, options: opts)
        newResult.outputPath = previewPath
        newResult.backupPath = existing.backupPath
        newResult.outputMode = existing.outputMode

        // 主窗口保留真实输出/备份元数据，仅同步体积、算法与压缩率
        // （与 Tauri compare-recompressed 处理一致），确保另存为/恢复/导出仍指向真实结果。
        var merged = newResult
        merged.outputPath = existing.outputPath
        items[idx].result = merged
        return newResult
    }

    /// 对比窗口恢复后同步主窗口行状态
    func markRestored(path: String) {
        guard let idx = items.firstIndex(where: { $0.path == path }) else { return }
        items[idx].result = nil
        items[idx].status = .restored
        showToast("已恢复原图: \(items[idx].fileName)")
    }

    func restoreFromCompare(path: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.path == path }),
              let result = items[idx].result else { return false }
        return Self.performRestore(result: result, outputSuffix: result.options?.outputSuffix)
    }

    // MARK: - Helpers

    nonisolated private static func uniqueFilePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in paths {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || seen.contains(value) { continue }
            seen.insert(value)
            out.append(value)
        }
        return out
    }

    private func uniqueFilePaths(_ paths: [String]) -> [String] { Self.uniqueFilePaths(paths) }

    nonisolated private static func base64URLName(_ path: String) -> String {
        let data = Data(path.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 覆盖式复制：FileManager.copyItem 目标存在即失败，此处对齐 Rust fs::copy 的覆盖语义。
    @discardableResult
    nonisolated static func copyOverwriting(from src: String, to dst: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst) {
            try? fm.removeItem(atPath: dst)
        }
        return (try? fm.copyItem(atPath: src, toPath: dst)) != nil
    }

    nonisolated static func normalizedOutputSuffix(_ suffix: String) -> String {
        var s = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        for ch in s.unicodeScalars {
            if ch == "/" || ch == "\\" || ch.value == 0 || CharacterSet.controlCharacters.contains(ch) {
                out.append("_")
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        s = String(out)
        if s.isEmpty { s = "_compressed" }
        return String(s.prefix(64))
    }

    nonisolated private static func availableSystemConversionPath(file: String, outType: String) -> String {
        let preferred = (file as NSString).deletingPathExtension + "." + outType
        if !FileManager.default.fileExists(atPath: preferred) { return preferred }
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = (file as NSString).deletingLastPathComponent
        for i in 1... {
            let suffix = i == 1 ? "_converted" : "_converted_\(i)"
            let candidate = (dir as NSString).appendingPathComponent("\(stem)\(suffix).\(outType)")
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return preferred
    }

    nonisolated private static func relativePathFromRoots(file: String, roots: [String]) -> String? {
        // 文件路径已规范化，根目录需同样规范化后做前缀匹配；取最深的匹配根
        // （与 Tauri relative_path_from_source_roots 对齐）。
        let canonicalFile = canonicalPath(file)
        var best: (depth: Int, relative: String)?
        for root in roots {
            var rootPath = canonicalPath(root)
            if rootPath.hasSuffix("/") { rootPath = String(rootPath.dropLast()) }
            guard canonicalFile.hasPrefix(rootPath + "/") else { continue }
            let relative = String(canonicalFile.dropFirst(rootPath.count + 1))
            let depth = rootPath.split(separator: "/").count
            if best == nil || depth > best!.depth {
                best = (depth, relative)
            }
        }
        return best?.relative
    }
}

/// 简单的线程安全计数盒（批次进度跨线程累加）
final class CounterBox: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
