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

// MARK: - App Page（主窗口内部页面：与 Tauri 前端 showView 一致）

enum AppPage: String, CaseIterable {
    case main, history, settings
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

    // 页面导航（主窗口内部视图，切换不销毁队列、不影响压缩）
    @Published var page: AppPage = .main

    // 暂停：只拦「还没开始」的文件，正在跑的那个会正常完成
    @Published var compressionPaused = false

    // 历史记录页 / 设置页
    @Published var historyEntries: [HistoryEntry] = []
    @Published var retentionDays = Retention.defaultDays
    // CPU 使用上限：nil = 自动。生效值还要按本机并行能力 clamp。
    @Published var cpuThreadLimit: Int? = nil

    // 持久层：压缩历史 + 原图备份（App Support，去留由保留档位决定）
    let history = HistoryStore()
    let settingsStore = SettingsStore()
    let cpuInfo = CpuInfo.detect()
    // 暂停和 CPU 上限是同一套闸门，不分两层锁。用 let 而不是 lazy var：
    // 压缩 worker 在别的线程上读它，lazy 的隐式初始化判定不是线程安全的。
    let scheduler: CompressionScheduler

    /// 本机真正生效的并行份数（换到核更少的机器会自动收敛）。
    var effectiveCpuThreadLimit: Int {
        CPULimit.effective(configured: cpuThreadLimit, detected: cpuInfo.budgetCeiling)
    }

    /// 队列摘要里的「CPU 4/10」。自动档不假装知道具体数字。
    var cpuSummaryText: String {
        CPUStatusText.summary(info: cpuInfo,
                              configured: cpuThreadLimit,
                              effective: effectiveCpuThreadLimit)
    }

    init() {
        let settings = settingsStore.load()
        retentionDays = settings.originalRetentionDays
        cpuThreadLimit = settings.cpuThreadLimit
        scheduler = CompressionScheduler(maxParallelism: CPULimit.effective(
            configured: settings.cpuThreadLimit, detected: cpuInfo.budgetCeiling))
        let report = history.cleanupExpired(retentionDays: retentionDays)
        if report.removedEntries > 0 || report.removedBackups > 0 {
            NSLog("OctoShrink 启动清理: 历史记录 -%d 条，原图备份 -%d 份，保留 %d 份",
                  report.removedEntries, report.removedBackups, report.keptBackups)
        }
        for warning in report.warnings { NSLog("OctoShrink 启动清理未完成: %@", warning) }
        historyEntries = history.list()
    }

    // 自动压缩续队列
    private var pendingAutoCompress = false
    private let cancelBox = CancelBox()

    // MARK: - 页面导航

    func showPage(_ page: AppPage) {
        self.page = page
        if page == .history { refreshHistory() }
    }

    // MARK: - 历史记录页

    func refreshHistory() {
        historyEntries = history.list()
    }

    /// 历史页的「恢复原图」：路径全部从存储里读，前端不自己拼。
    func restoreHistoryEntry(id: String) {
        guard let entry = history.find(id) else {
            showToast("找不到这条历史记录")
            refreshHistory()
            return
        }
        restore(entry: entry)
    }

    func clearHistory() {
        guard !historyEntries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "确定要清空 \(historyEntries.count) 条历史记录吗？"
        alert.informativeText = "只清理 OctoShrink 保存的原图备份，不会删除你的图片。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let report = history.clear()
        refreshHistory()
        var message = "已清空历史记录"
        if report.removedBackups > 0 { message += "，原图备份 \(report.removedBackups) 份已删除" }
        showToast(message)
        for warning in report.warnings { showToast(warning) }
    }

    func setRetentionDays(_ days: Int) {
        let clamped = Retention.clamp(days)
        retentionDays = clamped
        settingsStore.setRetentionDays(clamped)
        showToast(clamped == Retention.noRetain
            ? "原图备份改为不保留，关闭应用时清理"
            : "原图备份保留 \(clamped) 天，下次启动时清理过期记录")
    }

    /// 改 CPU 上限：正在跑的任务不抢回来，只影响之后启动的新任务（与暂停同语义）。
    func setCpuThreadLimit(_ limit: Int?) {
        cpuThreadLimit = limit
        settingsStore.setCpuThreadLimit(limit)
        scheduler.setMaxParallelism(effectiveCpuThreadLimit)
        showToast(limit == nil
            ? "CPU 上限改为自动（\(effectiveCpuThreadLimit)）"
            : "CPU 上限改为 \(effectiveCpuThreadLimit) / \(cpuInfo.budgetCeiling)")
    }

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
            scheduler.resume()
            compressionPaused = false
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
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "octoshrink.compress", attributes: .concurrent)
        // 新批次从未暂停开始，不继承上一批的状态；上限取设置页当前值。
        scheduler.beginBatch(maxParallelism: effectiveCpuThreadLimit)
        compressionPaused = false
        let gate = scheduler
        let store = history
        let retention = retentionDays

        for path in paths {
            group.enter()
            queue.async { [self] in
                // 暂停中或 CPU 名额已满就堵在这里；拿到名额的一刻闸门一定是开着的。
                // 已经在跑的文件会正常完成（不 kill、不 SIGSTOP）。
                let permit = gate.acquire()
                defer { permit.release(); group.leave() }
                if isCancelled(path) {
                    DispatchQueue.main.async {
                        self.updateStatus(path, .cancelled)
                        self.tick(counter: counter, total: paths.count)
                    }
                    return
                }
                // 「压缩中」只在真正开工这一刻标记，等待中的行保持「等待」。
                DispatchQueue.main.async {
                    if let idx = self.items.firstIndex(where: { $0.path == path }),
                       self.items[idx].status == .waiting {
                        self.items[idx].status = .compressing
                    }
                }
                let result = Self.compressOneStatic(
                    path: path, options: opts, useSmart: useSmart,
                    history: store, retentionDays: retention
                )
                DispatchQueue.main.async {
                    self.applyResult(path, result: result)
                    self.tick(counter: counter, total: paths.count)
                }
            }
        }

        group.notify(queue: .main) { [self] in
            gate.endBatch()
            compressionPaused = false
            self.isCompressing = false
            self.compressDoneText = options.processingMode == .system ? "转换完成" : "压缩完成"
            cancelBox.removeAll()
            refreshHistory()
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

    /// 暂停 / 继续：后端只决定「要不要再启动新文件」，绝不打断正在跑的压缩。
    func togglePause() {
        guard isCompressing else { return }
        if compressionPaused {
            scheduler.resume()
            compressionPaused = false
            showToast("继续压缩")
        } else {
            scheduler.pause()
            compressionPaused = true
            showToast("已暂停，正在压缩的文件会先完成")
        }
    }

    /// 取消全部：等待中/压缩中的行标记为已跳过（与 Tauri 的 cancelled 状态一致）
    func cancelAll() {
        // 暂停中取消：等待中的 worker 必须先被唤醒，否则整批永远收不了尾。
        scheduler.resume()
        compressionPaused = false
        for i in items.indices {
            if items[i].status == .waiting || items[i].status == .compressing {
                cancelBox.insert(items[i].path)
                items[i].status = .cancelled
            }
        }
    }

    func cancelFile(path: String) {
        scheduler.resume()
        compressionPaused = false
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

    nonisolated private static func compressOneStatic(
        path: String, options: CompressOptions, useSmart: Bool,
        history: HistoryStore, retentionDays: Int
    ) -> CompressResult {
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let engineResult = useSmart
            ? CompressionEngine.compressSmart(file: path, options: options)
            : CompressionEngine.compress(file: path, options: options)
        var result = CompressResult(engine: engineResult, file: path, originalSize: originalSize, options: options)
        writeOutputStatic(
            &result, compressed: engineResult.compressed, options: options,
            history: history, retentionDays: retentionDays
        )
        return result
    }

    /// 落盘 + 记历史，与 Tauri 的 write_output_file 同构：
    /// replace 先备份再覆盖，输出确认写成后才追加一条历史记录。
    nonisolated private static func writeOutputStatic(
        _ result: inout CompressResult, compressed: Data, options: CompressOptions,
        history: HistoryStore, retentionDays: Int
    ) {
        guard result.success, !compressed.isEmpty else { return }
        let isFormatConversion = options.outputFormat != .original
        if !isFormatConversion && Int64(compressed.count) >= result.originalSize {
            result.error = "原图已是最优，无需替换"
            return
        }

        var backupFile: String?
        let outExt = ".\(result.outType)"
        let fm = FileManager.default
        let path = result.file
        let outPath: String?

        switch options.outputMode {
        case .replace:
            // 先备份再覆盖：备份没写成就不碰用户文件，否则原图永久丢失。
            guard let backup = history.ensureBackup(for: path) else {
                result.success = false
                result.error = "无法保存原图备份，已跳过覆盖"
                return
            }
            backupFile = backup
            result.backupPath = backup

            let currentExt = ((path as NSString).pathExtension).lowercased()
            let sameFormat = currentExt == result.outType
                || (currentExt == "jpeg" && result.outType == "jpg")
                || (currentExt == "jpg" && result.outType == "jpeg")
                || (currentExt == "heif" && result.outType == "heic")
                || (currentExt == "heic" && result.outType == "heif")
            if options.processingMode == .system && isFormatConversion && !sameFormat {
                outPath = availableSystemConversionPath(file: path, outType: result.outType)
            } else {
                outPath = path
            }

        case .suffix:
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let dir = (path as NSString).deletingLastPathComponent
            let suffix = normalizedOutputSuffix(options.outputSuffix)
            outPath = (dir as NSString).appendingPathComponent("\(stem)\(suffix)\(outExt)")

        case .folder:
            guard let outDir = options.outputDir else { return }
            let rel = relativePathFromRoots(file: path, roots: options.sourceRoots)
                ?? (path as NSString).lastPathComponent
            let relOut = (rel as NSString).deletingPathExtension + outExt
            let target = (outDir as NSString).appendingPathComponent(relOut)
            try? fm.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            outPath = target
        }

        guard let target = outPath else { return }
        guard (try? compressed.write(to: URL(fileURLWithPath: target), options: .atomic)) != nil else { return }
        if options.outputMode == .replace && target != path {
            try? fm.removeItem(atPath: path)
        }
        result.outputPath = target
        result.outputMode = options.outputMode.rawValue
        // 输出确认落盘之后才记历史：历史里绝不出现没写成的文件。
        let entry = HistoryEntry.record(
            source: path, result: result, output: target,
            backup: backupFile, retentionDays: retentionDays
        )
        if !history.add(entry) {
            NSLog("OctoShrink 写入压缩历史失败: %@", entry.id)
        }
    }

    // MARK: - Restore（统一服务：主队列 / 历史页 / 对比窗口 / 恢复全部 都走 HistoryStore.restore）

    /// 恢复一条历史记录。压缩之后又被外部改过时先问用户，坚持才 force 覆盖。
    /// 所有路径都由历史记录提供，调用方不参与拼路径。
    @discardableResult
    func restore(entry: HistoryEntry) -> Bool {
        var outcome = history.restoreOutcome(entry: entry, force: false)
        if outcome.conflict {
            let alert = NSAlert()
            alert.messageText = "这个文件在压缩后又被修改过。"
            alert.informativeText = "恢复原图会覆盖当前版本。"
            alert.addButton(withTitle: "仍然恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            outcome = history.restoreOutcome(entry: entry, force: true)
        }
        guard outcome.success else {
            showToast(outcome.error ?? "恢复失败")
            return false
        }
        markItemsRestored(forSource: entry.sourcePath)
        refreshHistory()
        showToast("已恢复原图: \(entry.fileName)")
        return true
    }

    /// 后端确认恢复成功后，把指向同一源路径的行改成「已恢复」。
    private func markItemsRestored(forSource sourcePath: String) {
        for index in items.indices where canonicalPath(items[index].path) == sourcePath {
            items[index].result = nil
            items[index].status = .restored
            let size = fileLength(sourcePath)
            if size >= 0 { items[index].fileSize = size }
        }
    }

    func restoreFile(path: String) {
        guard let entry = history.findLatest(forSource: path) else {
            showToast("找不到这条历史记录")
            return
        }
        restore(entry: entry)
    }

    func restoreAll() {
        let restorable = items.filter { $0.status == .done && $0.result?.success == true }
        guard !restorable.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "确定要恢复全部已压缩成功的原图吗？"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var restored = 0
        var conflicts = 0
        var failed = 0
        for item in restorable {
            guard let file = item.result?.file,
                  let entry = history.findLatest(forSource: file) else { failed += 1; continue }
            let outcome = history.restoreOutcome(entry: entry, force: false)
            if outcome.success {
                restored += 1
                markItemsRestored(forSource: entry.sourcePath)
            } else if outcome.conflict {
                conflicts += 1
            } else {
                failed += 1
            }
        }
        refreshHistory()
        // 冲突不静默覆盖：整批里遇到的都记下来，让用户去历史页逐个确认。
        var message = "已恢复 \(restored) 个文件到原图"
        if conflicts > 0 { message += "，\(conflicts) 个文件压缩后又被修改过，请在历史记录里逐个确认" }
        if failed > 0 { message += "，\(failed) 个未能恢复" }
        showToast(message)
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

    /// 对比窗口恢复后同步主窗口行状态（真正的恢复已走统一服务）
    func markRestored(path: String) {
        guard let idx = items.firstIndex(where: { $0.path == path }) else { return }
        items[idx].result = nil
        items[idx].status = .restored
        refreshHistory()
        showToast("已恢复原图: \(items[idx].fileName)")
    }

    func restoreFromCompare(path: String) -> Bool {
        guard let entry = history.findLatest(forSource: path) else {
            showToast("找不到这条历史记录")
            return false
        }
        return restore(entry: entry)
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

    /// 覆盖式复制：FileManager.copyItem 目标存在即失败，此处对齐 Rust fs::copy 的覆盖语义。
    @discardableResult
    nonisolated static func copyOverwriting(from src: String, to dst: String) -> Bool {
        copyFileOverwriting(from: src, to: dst)
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
