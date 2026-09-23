import Foundation

// OctoShrink Swift 原生线 —— 持久化的压缩历史与原图备份。
//
// 与 src-tauri/src/history.rs 同一套语义，只是落在自己的 App Support 目录：
// 清理只针对 OctoShrink 自己写的副本 —— 用户的原图和压缩结果永远不在删除范围内。
//
// 清理只有一个时机：**正常退出**，启动时一律不动备份。
// retentionDays == 0（「不保留」，默认档）：本次运行的记录连同原图备份在退出时一起走，
// 上次异常退出遗留的那批多给一次会话的机会；retentionDays > 0：退出时按天数窗口清理。
// 为什么不是"下次启动"：崩溃现场那份备份可能是被覆盖原图唯一还活着的副本。

// MARK: - 时间与文件属性

enum OctoClock {
    static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static var nowNanos: Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }
}

let historyDayMillis: Int64 = 86_400_000
/// mtime 比文件大小更容易被无关操作扰动；容忍 2 秒以内的写入抖动。
let historyMtimeToleranceMillis: Int64 = 2_000

func fileMtimeMillis(_ path: String) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let date = attrs[.modificationDate] as? Date else { return nil }
    return Int64(date.timeIntervalSince1970 * 1000)
}

func fileLength(_ path: String) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? -1
}

func fileExists(at path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

/// 两个路径指的是不是同一个文件。
///
/// 记录里的 `sourcePath` 是规范路径，`outputPath` 是当时那个字符串 —— macOS 上
/// `/var/…` 与 `/private/var/…`、任何软链目录都会让两者字面不等。同格式 replace 的
/// 压缩输出**就是**源文件本身，判成"另一个文件"会在恢复之后把刚写回的原图删掉。
func sameFile(_ a: String, _ b: String) -> Bool {
    a == b || canonicalPath(a) == canonicalPath(b)
}

/// 落盘到"崩溃后还在"：写完立刻 fsync，数据先于 rename 生效。
func syncFile(at path: String) {
    let fd = Darwin.open(path, O_RDONLY)
    if fd >= 0 {
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
    }
}

/// 覆盖式复制：FileManager.copyItem 目标存在即失败，此处对齐 Rust fs::copy 的覆盖语义。
@discardableResult
func copyFileOverwriting(from src: String, to dst: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst) {
        try? fm.removeItem(atPath: dst)
    }
    return (try? fm.copyItem(atPath: src, toPath: dst)) != nil
}

/// 截断重写会让崩溃留下半个 history.json；先写 tmp、再 rename。
func writeAtomic(path: String, data: Data) -> Bool {
    let parent = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    let tmp = "\(path).tmp-\(OctoClock.nowNanos)"
    do {
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
    } catch {
        return false
    }
    if Darwin.rename(tmp, path) != 0 {
        try? FileManager.default.removeItem(atPath: tmp)
        return false
    }
    return true
}

// MARK: - 稳定哈希

enum StableHash {
    /// Swift 的 hashValue 每次启动换 seed，备份目录名必须跨启动稳定 → 自己实现 FNV-1a。
    static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - 历史记录

enum HistoryStatus: String, Codable {
    /// 压缩结果仍在，原图备份可恢复
    case compressed
    /// 已恢复到真正原图
    case restored
    /// 压缩结果或原图位置已不存在（外部改名/删除）
    case missing
    /// `history.json` 损坏后从备份目录重建出来的条目：压缩明细已丢失，但原图还能一键恢复
    case recoveryAvailable
}

struct HistoryEntry: Codable, Identifiable {
    let id: String
    var createdAt: Int64
    var expiresAt: Int64
    var sourcePath: String
    var outputPath: String?
    var fileName: String
    var outputMode: String
    var originalSize: Int64
    var compressedSize: Int64
    var savings: Double
    var outType: String
    var algorithm: String
    /// 只有 replace 模式才有：覆盖原文件前保存的那份真正原图。
    var backupPath: String?
    var status: HistoryStatus
    var restoredAt: Int64?
    /// 压缩结果写入完成时的 mtime，用于检测压缩后被外部编辑器改过的文件。
    var outputModifiedAt: Int64?
    /// 派生字段：读取时刷新。
    var sourceExists: Bool
    var backupExists: Bool
    /// 压缩结果此刻还在不在：历史页的「另存为 / 对比 / 删除这次压缩结果」都靠它决定，
    /// 用户手动删过产物之后这些按钮就不该出现。
    var outputExists: Bool

    init(
        id: String,
        createdAt: Int64,
        expiresAt: Int64,
        sourcePath: String,
        outputPath: String?,
        fileName: String,
        outputMode: String,
        originalSize: Int64,
        compressedSize: Int64,
        savings: Double,
        outType: String,
        algorithm: String,
        backupPath: String?,
        status: HistoryStatus,
        restoredAt: Int64?,
        outputModifiedAt: Int64?,
        sourceExists: Bool,
        backupExists: Bool,
        outputExists: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.fileName = fileName
        self.outputMode = outputMode
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.savings = savings
        self.outType = outType
        self.algorithm = algorithm
        self.backupPath = backupPath
        self.status = status
        self.restoredAt = restoredAt
        self.outputModifiedAt = outputModifiedAt
        self.sourceExists = sourceExists
        self.backupExists = backupExists
        self.outputExists = outputExists
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, expiresAt, sourcePath, outputPath, fileName, outputMode
        case originalSize, compressedSize, savings, outType, algorithm, backupPath
        case status, restoredAt, outputModifiedAt, sourceExists, backupExists, outputExists
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        createdAt = try box.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        expiresAt = try box.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
        sourcePath = try box.decode(String.self, forKey: .sourcePath)
        outputPath = try box.decodeIfPresent(String.self, forKey: .outputPath)
        fileName = try box.decodeIfPresent(String.self, forKey: .fileName) ?? "image"
        outputMode = try box.decodeIfPresent(String.self, forKey: .outputMode) ?? "replace"
        originalSize = try box.decodeIfPresent(Int64.self, forKey: .originalSize) ?? 0
        compressedSize = try box.decodeIfPresent(Int64.self, forKey: .compressedSize) ?? 0
        savings = try box.decodeIfPresent(Double.self, forKey: .savings) ?? 0
        outType = try box.decodeIfPresent(String.self, forKey: .outType) ?? ""
        algorithm = try box.decodeIfPresent(String.self, forKey: .algorithm) ?? ""
        backupPath = try box.decodeIfPresent(String.self, forKey: .backupPath)
        status = try box.decodeIfPresent(HistoryStatus.self, forKey: .status) ?? .compressed
        restoredAt = try box.decodeIfPresent(Int64.self, forKey: .restoredAt)
        outputModifiedAt = try box.decodeIfPresent(Int64.self, forKey: .outputModifiedAt)
        sourceExists = try box.decodeIfPresent(Bool.self, forKey: .sourceExists) ?? true
        backupExists = try box.decodeIfPresent(Bool.self, forKey: .backupExists) ?? false
        outputExists = try box.decodeIfPresent(Bool.self, forKey: .outputExists) ?? false
    }

    /// 备份 key = 备份目录名；目录名 = backups/<key>/original.<ext>
    var backupKey: String? {
        guard let backup = backupPath else { return nil }
        return HistoryStore.key(ofBackupPath: backup)
    }
}

private let entrySequence = NSLock()
private var entryCounter: UInt32 = 0

extension HistoryEntry {
    /// 事务 id 与历史 id 同一个值：覆盖是否提交成功就靠这两者对账。
    static func newId(forSource source: String) -> String {
        entrySequence.lock()
        entryCounter &+= 1
        let sequence = entryCounter
        entrySequence.unlock()
        return "\(OctoClock.nowNanos)-\(sequence)-\(HistoryStore.backupKey(forPath: canonicalPath(source)))"
    }

    /// 一次成功产出对应一条历史。`expiresAt` 只用于展示：退出清理按 `created_at`
    /// 判定，所以同一张图重压多次时，备份的存活期顺延到最后一次相关压缩之后。
    static func record(
        source: String,
        result: CompressResult,
        output: String,
        backup: String?,
        retentionDays: Int
    ) -> HistoryEntry {
        record(
            withId: newId(forSource: source),
            source: source, result: result, output: output,
            backup: backup, retentionDays: retentionDays
        )
    }

    /// replace 模式用事务里那个 id 建记录：事务日志先于覆盖写下这个 id，
    /// 历史里出现的必须是**同一个** id，否则回滚会把已提交的那次当成中断。
    static func record(
        withId id: String,
        source: String,
        result: CompressResult,
        output: String,
        backup: String?,
        retentionDays: Int
    ) -> HistoryEntry {
        let createdAt = OctoClock.nowMillis
        let canonical = canonicalPath(source)
        return HistoryEntry(
            id: id,
            createdAt: createdAt,
            // 「不保留」没有"几天后到期"这回事：这份备份的寿命就是这次运行。
            expiresAt: retentionDays == Retention.noRetain
                ? createdAt
                : createdAt + Int64(max(1, retentionDays)) * historyDayMillis,
            sourcePath: canonical,
            outputPath: output,
            fileName: (canonical as NSString).lastPathComponent,
            outputMode: result.outputMode ?? "replace",
            originalSize: result.originalSize,
            compressedSize: result.compressedSize,
            savings: result.savings,
            outType: result.outType,
            algorithm: result.algorithm,
            backupPath: backup,
            status: .compressed,
            restoredAt: nil,
            outputModifiedAt: fileMtimeMillis(output),
            sourceExists: true,
            backupExists: backup != nil
        )
    }
}

struct CleanupReport {
    var removedEntries = 0
    var removedBackups = 0
    var keptBackups = 0
    var warnings: [String] = []
    /// 损坏的 `history.json` 被留档成了哪个文件（只在这次真的处理过损坏时才有）。
    var quarantinedTo: String?
    /// 从备份目录重建出多少条恢复入口。
    var recoveredEntries = 0
}

enum RestoreError: Error {
    case notFound
    /// 没有可恢复的备份（后缀/目录模式，原图本来就没被覆盖）
    case notRestorable
    /// 原图确实被覆盖过，但那份备份已经不在了（「不保留」档退出时清理过）
    case backupGone
    /// 压缩之后目标文件被外部修改过，需要用户确认
    case conflict
    case io(String)
    /// 拿不到（也续不上）目标位置的访问授权
    case accessDenied

    var message: String {
        switch self {
        case .notFound: return "找不到这条历史记录"
        case .notRestorable: return "原图未被覆盖，无需恢复"
        // 备份被退出清理收走、或被用户在 App 外面删掉：原图确实被覆盖过，只是副本没了。
        case .backupGone: return "原图备份已清理，无法恢复"
        case .conflict: return "这个文件在压缩后又被修改过"
        case .io: return "恢复失败"
        case .accessDenied: return "没有该文件夹的访问权限，请重新授权"
        }
    }

    var detail: String {
        if case .io(let inner) = self { return "恢复失败: \(inner)" }
        return message
    }
}

struct RestoreOutcome {
    let success: Bool
    /// true = 压缩之后目标文件又被改过，需要用户确认后 force = true 再来一次。
    let conflict: Bool
    let filePath: String
    let error: String?
    /// 一起被标记为「已恢复」的历史记录：同一张图重压多次会共享那份真正原图。
    let historyIds: [String]
}

// MARK: - 历史存储

/// 进程内共享的历史存储。所有读-改-写都在同一把锁里完成，
/// 3 个并发 worker 同时追加不会互相覆盖。
final class HistoryStore: @unchecked Sendable {
    static let backupsDirName = "backups"
    static let historyFileName = "history.json"
    static let metaFileName = "backup-meta.json"
    /// 上次运行是否走完了退出清理。清理只有一个时机，所以得留个记号区分"上次崩了"。
    static let cleanExitFileName = "clean-exit"
    /// `history.json` 损坏后重建出来的条目用的算法标记：它不是一次真实压缩。
    static let recoveryAlgorithm = "recovery"
    /// 历史条数硬上限：清理逻辑再怎么出错，也不能让 history.json 无限膨胀。
    /// 淘汰最老的记录，且只连带删它自己那份没人认领的备份。
    static let maxHistoryEntries = 10_000

    let root: String
    /// 本次运行的起点：「不保留」档靠它区分"这次造的记录"和"上次崩溃留下的记录"。
    let runStartedAt = OctoClock.nowMillis
    /// 上次运行有没有走完退出清理。为假说明磁盘上那批备份是崩溃现场留下的、
    /// 可能是原图唯一的副本，本次退出得再留它一次。
    let previousRunEndedCleanly: Bool
    private let lock = NSLock()
    /// `history.json` 读不出来过 → 本次启动锁死一切备份 sweep。
    /// 锁是整次启动的，不因后来某次写入成功而解除。
    private var cleanupLocked = false
    /// 损坏现场的处理结果，只报一次给启动流程。
    private var pendingReport: CleanupReport?
    /// 已经隔离 + 重建过一轮：同一次启动不反复隔离，也不在写失败时把现场丢掉。
    private var corruptHandled = false

    /// Swift 线用自己的 App Support 子目录：与 Direct / App Store 两条 Tauri 线
    /// 的 history.json 完全隔离，避免三个进程写同一份历史。
    static func appDataRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.misswell.octoshrink.swift").path
    }

    /// 全进程共用一份：损坏锁死、启动报告这些状态是**这一次运行**的，两处各 new 一个
    /// 实例会让退出清理看不到启动时立起来的锁 —— 现场刚被留档，备份就被 sweep 掉。
    static let shared = HistoryStore()

    init(root: String = HistoryStore.appDataRoot()) {
        self.root = root
        // 启动只把"上次到底结清过账没有"读走（读一次即抹掉记号）：清理挂在退出上。
        // 顺序不能颠倒 —— 这一行之前 self 还没初始化完，碰不得 backupsDir 这类实例属性。
        previousRunEndedCleanly = Self.takeCleanExitMarker(at: root)
        try? FileManager.default.createDirectory(
            atPath: backupsDir, withIntermediateDirectories: true
        )
    }

    var historyFile: String { (root as NSString).appendingPathComponent(Self.historyFileName) }
    var backupsDir: String { (root as NSString).appendingPathComponent(Self.backupsDirName) }

    // ─── 读写 ────────────────────────────────────────────────────

    /// 严格读取：**"没有历史"和"历史读不出来"是两回事**。
    ///
    /// 老实现是 `contents + try? decode else []`，把半个 JSON 当成空历史；下一次清理
    /// 清理看到"没有任何记录引用这些备份"，就把用户所有原图备份删了 —— 拿原图换一个
    /// 不报错。损坏时改为：隔离现场留档 → 按 backup-meta 重建恢复入口 → 本次启动锁死
    /// 一切备份清理。
    private func readRaw() -> [HistoryEntry] {
        guard let data = FileManager.default.contents(atPath: historyFile) else {
            return []   // 文件不存在 = 真的没有历史，正常状态
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return [] }
        if let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            return entries
        }
        return handleCorrupt()
    }

    /// 损坏现场：改名留档（证据绝不能被 `[]` 覆盖）→ 从备份重建 → 锁死清理。
    /// 调用方必须已持有 `lock`。
    private func handleCorrupt() -> [HistoryEntry] {
        let rebuilt = rebuildFromBackups()
        guard !corruptHandled else { return rebuilt }
        corruptHandled = true
        cleanupLocked = true
        var report = CleanupReport()
        if let kept = quarantineHistoryFile() {
            report.quarantinedTo = kept
            report.warnings.append("历史记录文件已损坏，现场已留档为 \(kept)")
        } else {
            report.warnings.append("历史记录文件已损坏且无法留档，本次启动不会写历史、也不会清理备份")
        }
        report.recoveredEntries = rebuilt.count
        if !writeRaw(rebuilt) {
            report.warnings.append("重建的历史记录写入失败，本次启动跳过清理")
        }
        report.warnings.append("检测到可恢复的原图备份 \(rebuilt.count) 份（压缩明细已丢失，历史页可一键恢复）")
        pendingReport = report
        return rebuilt
    }

    /// 损坏文件改名留档。毫秒足够唯一，本项目不引日期库。
    private func quarantineHistoryFile() -> String? {
        let stamped = (root as NSString).appendingPathComponent(
            "history.corrupt-\(OctoClock.nowMillis).json")
        guard Darwin.rename(historyFile, stamped) == 0 else { return nil }
        return stamped
    }

    /// 本次启动是否禁止清理无人引用的备份。
    func cleanupIsLocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _ = readRaw()   // 触发一次加载/损坏处理
        return cleanupLocked
    }

    /// 取出损坏现场的处理结果（只有一份，报告完就没了）。
    func takeStartupReport() -> CleanupReport? {
        lock.lock(); defer { lock.unlock() }
        _ = readRaw()
        return takePendingReportLocked()
    }

    /// 调用方必须已持有 `lock`。
    private func takePendingReportLocked() -> CleanupReport? {
        defer { pendingReport = nil }
        return pendingReport
    }

    /// 按备份目录的来历记录重建恢复入口。只认得出"谁的备份、还在不在"，
    /// 压缩明细（省了多少、什么算法）已经无从得知 —— 但原图必须还能一键恢复。
    private func rebuildFromBackups() -> [HistoryEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backupsDir) else { return [] }
        let now = OctoClock.nowMillis
        var rebuilt: [HistoryEntry] = []
        for name in names.sorted() {
            let dir = (backupsDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let backup = existingBackupFile(name) else { continue }
            // 没有来历记录就不知道这份备份是谁的图，宁可不认也不许瞎猜。
            guard let meta = readMeta(name) else { continue }
            let source = meta.sourcePath
            rebuilt.append(HistoryEntry(
                id: "recovery-\(name)",
                createdAt: meta.createdAt,
                expiresAt: now,
                sourcePath: source,
                outputPath: source,          // replace 模式覆盖的就是源文件本身
                fileName: (source as NSString).lastPathComponent,
                outputMode: "replace",
                originalSize: meta.originalSize > 0 ? meta.originalSize : fileLength(backup),
                // 明细无从得知，但"此刻源文件什么样"是量得出来的：填实时值，
                // 否则每次恢复都会误报「压缩后又被修改过」。
                compressedSize: max(0, fileLength(source)),
                savings: 0,
                outType: ((source as NSString).pathExtension).lowercased(),
                algorithm: HistoryStore.recoveryAlgorithm,
                backupPath: backup,
                status: .recoveryAvailable,
                restoredAt: nil,
                outputModifiedAt: fileMtimeMillis(source) ?? meta.originalModifiedAt,
                sourceExists: fileExists(at: source),
                backupExists: true
            ))
        }
        return rebuilt
    }

    private func writeRaw(_ entries: [HistoryEntry]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }
        return writeAtomic(path: historyFile, data: data)
    }

    private func decorate(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.map { entry in
            var item = entry
            item.sourceExists = fileExists(at: entry.sourcePath)
            item.backupExists = entry.backupPath.map { fileExists(at: $0) } ?? false
            item.outputExists = entry.outputPath.map { fileExists(at: $0) } ?? false
            if !item.sourceExists && item.status == .compressed { item.status = .missing }
            return item
        }
    }

    /// 最新在前，历史页直接渲染。
    func list() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let entries = readRaw().sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
        return decorate(entries)
    }

    func find(_ historyId: String) -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        return decorate(readRaw()).first { $0.id == historyId }
    }

    /// 覆盖事务是否已提交：历史里有这条 id 且还没被恢复，就证明整条链路都走完了。
    ///
    /// 判定只依赖这一条事实 —— 别的都可能是崩溃现场的一部分。
    func containsCommitted(_ historyId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readRaw().contains { $0.id == historyId && $0.status != .restored }
    }

    /// 主队列的「恢复原图」不带 id 时，按源路径找最近一条还没恢复的记录。
    func findLatest(forSource sourcePath: String) -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        let canonical = canonicalPath(sourcePath)
        return decorate(readRaw())
            .filter { $0.sourcePath == canonical && $0.status != .restored }
            .max { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(_ entry: HistoryEntry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var entries = readRaw()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        guard entries.count > Self.maxHistoryEntries else { return writeRaw(entries) }
        // 淘汰最老的，直到回到上限内；备份只在"没有幸存记录再引用它"时才连带删。
        let overflow = entries.count - Self.maxHistoryEntries
        let oldest = Array(entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }.prefix(overflow))
        let doomed = Set(oldest.map { $0.id })
        let survivors = entries.filter { !doomed.contains($0.id) }
        guard writeRaw(survivors) else { return false }
        dropBackupsOf(evicted: oldest, survivors: survivors)
        return true
    }

    /// 被淘汰条目独享的备份目录才删；还有别的记录引用就留着。
    private func dropBackupsOf(evicted: [HistoryEntry], survivors: [HistoryEntry]) {
        let stillReferenced = Set(survivors.compactMap { $0.backupKey })
        for key in Set(evicted.compactMap { $0.backupKey }) where !stillReferenced.contains(key) {
            _ = removeDirectory(backupDir(key))
        }
    }

    func clear() -> CleanupReport {
        lock.lock(); defer { lock.unlock() }
        let entries = readRaw()
        let referenced = Set(entries.compactMap { $0.backupKey })
        var report = CleanupReport()
        report.removedEntries = entries.count
        guard writeRaw([]) else {
            report.warnings.append("history.json 写入失败")
            return report
        }
        for key in referenced {
            if removeDirectory(backupDir(key)) { report.removedBackups += 1 }
        }
        return report
    }

    // ─── 原图备份 ────────────────────────────────────────────────

    /// 稳定哈希：同一 sourcePath 在任意次启动后都落进同一个备份目录。
    static func backupKey(forPath path: String) -> String {
        StableHash.fnv1a64(canonicalPath(path))
    }

    /// 备份 key = 备份所在目录名
    static func key(ofBackupPath backupPath: String) -> String? {
        let dir = (backupPath as NSString).deletingLastPathComponent
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func backupDir(ofBackupPath backupPath: String) -> String? {
        let dir = (backupPath as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }

    private func backupDir(_ key: String) -> String {
        (backupsDir as NSString).appendingPathComponent(key)
    }

    private func readMeta(_ key: String) -> BackupMeta? {
        let path = (backupDir(key) as NSString).appendingPathComponent(Self.metaFileName)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(BackupMeta.self, from: data)
    }

    private func existingBackupFile(_ key: String) -> String? {
        let dir = backupDir(key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let matches = names
            .filter { $0.hasPrefix("original.") }
            .sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
        return matches.last
    }

    /// 为一次 replace 压缩准备原图备份，返回 nil 表示备份不可信。
    ///
    /// 关键不变量：**已有有效备份时绝不覆盖**。同一张图连压三次，备份里永远是
    /// 第一次压缩前的真正原图，否则「恢复原图」只会回到上一版压缩结果。
    ///
    /// 备份文件 + 来历记录**都在**才算成功：`history.json` 一旦损坏，重建恢复入口
    /// 只认得出"谁的备份"靠的就是这份 meta。缺一半等于没备份 —— 返回 nil，调用方
    /// 必须放弃这次覆盖（宁可压缩失败，也不能出现"覆盖了但没原图"）。
    func ensureBackup(for source: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let canonical = canonicalPath(source)
        guard fileExists(at: canonical) else { return nil }
        let baseKey = Self.backupKey(forPath: canonical)
        let ext = ((canonical as NSString).pathExtension).lowercased()
        let extensionName = (!ext.isEmpty && ext.count <= 8) ? ext : "bin"

        for index in 0..<32 {
            let key = index == 0 ? baseKey : "\(baseKey)-\(index)"
            let dir = backupDir(key)
            if let meta = readMeta(key) {
                // 命中同一源路径：复用，不重新拷贝。
                if meta.sourcePath == canonical, let existing = existingBackupFile(key) {
                    return existing
                }
                // 备份文件被外部删掉了：重新写一份真正原图（下方继续）。
                // 哈希撞上了别的文件则往后挪一个槽位。
                if meta.sourcePath != canonical { continue }
            } else if fileExists(at: dir) {
                continue
            }

            guard (try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)) != nil else { return nil }
            let backupPath = (dir as NSString).appendingPathComponent("original.\(extensionName)")
            // 先写临时名再 rename：崩溃不许留下半个 original.xxx 冒充有效备份。
            let staged = (dir as NSString).appendingPathComponent(".original.\(extensionName).tmp")
            guard copyFileOverwriting(from: canonical, to: staged) else {
                _ = removeDirectory(dir)
                return nil
            }
            syncFile(at: staged)
            guard Darwin.rename(staged, backupPath) == 0 else {
                _ = removeDirectory(dir)
                return nil
            }
            let meta = BackupMeta(
                version: 2,
                sourcePath: canonical,
                createdAt: OctoClock.nowMillis,
                originalSize: max(0, fileLength(backupPath)),
                originalModifiedAt: fileMtimeMillis(canonical),
                originalExtension: extensionName
            )
            guard let data = try? JSONEncoder().encode(meta),
                  writeAtomic(
                    path: (dir as NSString).appendingPathComponent(Self.metaFileName),
                    data: data
                  )
            else {
                _ = removeDirectory(dir)
                return nil
            }
            // 落盘后再认一次：任何一半缺失都不算备份。
            guard existingBackupFile(key) != nil, readMeta(key) != nil else {
                _ = removeDirectory(dir)
                return nil
            }
            return backupPath
        }
        return nil
    }

    // ─── 退出清理（唯一的清理时机）───────────────────────────────

    /// 正常退出时按保留档位清一次：删掉的记录写回 history.json，再删已经没人引用的备份。
    /// 单个删除失败只记 warning，剩下的孤儿下次退出继续扫。
    ///
    /// - 按天档位（1/3/7/14/30）：`createdAt` 超出窗口的记录过期。
    /// - 「不保留」（0）：**本次运行**造出的记录过期。`runStartedAt` 之前那条如果是上次
    ///   异常退出留下的、备份文件还在，就再留它一次（`previousRunEndedCleanly` 为假时）
    ///   —— 那份备份可能是被覆盖原图唯一的副本，而这一次会话是用户唯一看得见、
    ///   也恢复得了它的窗口。下一次干净退出收账。
    ///
    /// 只在正常退出跑，启动时一个备份都不动：崩溃现场那份可能是原图唯一的副本。
    func applyRetentionOnExit(
        retentionDays: Int,
        runStartedAt: Int64,
        previousRunEndedCleanly: Bool
    ) -> CleanupReport {
        lock.lock(); defer { lock.unlock() }
        var report = CleanupReport()
        let all = readRaw()          // 先触发加载，损坏时才会把锁置起来
        if cleanupLocked {
            // 引用关系不可信的时候一个备份都不许删：这是"history.json 损坏 →
            // 所有备份变成无人引用 → 全被清掉"那条链路唯一的断点。
            report.warnings.append("历史记录文件已损坏，本次退出跳过清理，原图备份全部保留")
            return report
        }
        let notRetained = retentionDays == Retention.noRetain
        let cutoff = OctoClock.nowMillis - Int64(max(1, retentionDays)) * historyDayMillis
        let kept = all.filter { entry in
            let survives: Bool
            if notRetained {
                // 别信 entry.backupExists：readRaw 给的是落盘时那份快照，备份目录
                // 后来被谁动过它不知道。豁免的唯一依据是"文件此刻还在"。
                let backupIsLive = entry.backupPath.map(fileExists(at:)) ?? false
                survives = entry.createdAt < runStartedAt && !previousRunEndedCleanly && backupIsLive
            } else {
                survives = entry.createdAt >= cutoff
            }
            if !survives { report.removedEntries += 1 }
            return survives
        }
        // 先落账再删文件：备份没了而 history.json 还说备份在，就是一个点开只会报错的
        // 恢复入口；写失败时一个文件都不许动。
        if kept.count != all.count && !writeRaw(kept) {
            report.warnings.append("history.json 写入失败")
            return report
        }
        sweepUnreferencedBackups(kept: kept, report: &report)
        return report
    }

    /// 读取并抹掉「上次运行走完了退出清理」的记号，只在启动时取一次。
    /// 崩溃 / 强杀写不下这个文件，所以"没有记号"就是上次没清账的证据。
    static func takeCleanExitMarker(at root: String) -> Bool {
        let path = (root as NSString).appendingPathComponent(cleanExitFileName)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    /// 只有退出清理真的跑完才留记号：跳过清理时不许留下"账已结清"的假证据。
    func markCleanExit() {
        let path = (root as NSString).appendingPathComponent(Self.cleanExitFileName)
        try? String(OctoClock.nowMillis).data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }

    /// 删掉没有任何存活条目引用的备份目录。调用方必须已持有 `lock`。
    private func sweepUnreferencedBackups(kept: [HistoryEntry], report: inout CleanupReport) {
        // 兜底：历史不可信的整次启动里，任何路径都不许走到"删无人引用的备份"。
        guard !cleanupLocked else {
            report.warnings.append("历史记录不可信，跳过备份清理")
            return
        }
        let referenced = Set(
            kept.filter { $0.status != .restored }.compactMap { $0.backupKey }
        )
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backupsDir) else {
            return
        }
        for name in names {
            let path = (backupsDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            if referenced.contains(name) {
                report.keptBackups += 1
                continue
            }
            if removeDirectory(path) { report.removedBackups += 1 } else {
                report.warnings.append("备份 \(name) 删除失败，留待下次清理")
            }
        }
    }

    private func removeDirectory(_ path: String) -> Bool {
        guard fileExists(at: path) else { return true }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    // ─── 恢复 ────────────────────────────────────────────────────

    /// false = 历史没落盘。调用方（restore）必须留着备份并报错，让用户重试。
    private func markRestored(_ ids: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stamp = OctoClock.nowMillis
        var entries = readRaw()
        var touched = false
        for index in entries.indices {
            guard ids.contains(entries[index].id), entries[index].status != .restored else { continue }
            entries[index].status = .restored
            entries[index].restoredAt = stamp
            entries[index].backupPath = nil
            entries[index].backupExists = false
            touched = true
        }
        return touched ? writeRaw(entries) : true
    }

    /// 写失败就抛错：撤销没落盘，这条记录还留在历史里，用户可以重试。
    private func removeIds(_ ids: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let before = readRaw()
        let after = before.filter { !ids.contains($0.id) }
        guard after.count != before.count else { return }
        guard writeRaw(after) else {
            throw RestoreError.io("history.json 写入失败")
        }
    }

    /// 同一条备份可能被多条记录引用（同一张图重压 N 次）。恢复的是那份真正原图，
    /// 所有这些记录的「已压缩」状态同时失效，必须一起标 Restored。
    private func siblingsSharingBackup(_ entry: HistoryEntry) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let key = entry.backupKey else { return [entry.id] }
        let shared = readRaw().filter {
            $0.status != .restored && $0.backupKey == key
        }.map { $0.id }
        return shared.isEmpty ? [entry.id] : shared
    }

    /// 恢复前的安全检查：压缩结果被外部改过就不要静默覆盖。
    static func hasConflict(_ entry: HistoryEntry) -> Bool {
        guard entry.outputMode == "replace" else { return false }
        let target = entry.outputPath ?? entry.sourcePath
        guard fileExists(at: target) else { return false }
        if fileLength(target) != entry.compressedSize { return true }
        guard let recorded = entry.outputModifiedAt,
              let current = fileMtimeMillis(target) else { return false }
        return abs(current - recorded) > historyMtimeToleranceMillis
    }

    /// 把一份备份原子地写回目标位置：同目录临时文件 → fsync → rename。
    ///
    /// `restore` 和事务回滚共用这一个实现 —— 恢复原图这件事绝不允许有两套写法。
    static func writeBackupBack(to target: String, backup: String) throws {
        let parent = (target as NSString).deletingLastPathComponent
        let tmp = (parent as NSString).appendingPathComponent(
            ".octoshrink-restore-\(OctoClock.nowNanos).tmp"
        )
        guard copyFileOverwriting(from: backup, to: tmp) else {
            throw RestoreError.io("无法写入恢复临时文件")
        }
        // 写回原图这一步不能只留在内核缓存里：崩溃后用户看到的必须真是原图。
        syncFile(at: tmp)
        if Darwin.rename(tmp, target) != 0 {
            // 覆盖到一半失败时保留原目标文件，只清掉临时文件。
            try? FileManager.default.removeItem(atPath: tmp)
            throw RestoreError.io("无法把原图写回目标位置")
        }
    }

    /// 跨格式 replace（PNG → JPG）时压缩结果是个新文件，恢复后不该留下孤儿。
    /// 同格式 replace 的输出就是源文件本身，绝不许删。
    private static func removeGeneratedOutput(_ entry: HistoryEntry) {
        guard let output = entry.outputPath else { return }
        guard !sameFile(output, entry.sourcePath) else { return }
        try? FileManager.default.removeItem(atPath: output)
    }

    /// 统一恢复入口：主队列 / 历史页 / 恢复全部 都走这里，
    /// 避免三套逻辑对历史状态的处理不一致。
    ///
    /// 提交顺序是**刻意**的：写回原图 → 历史落盘 → 才删压缩输出和备份目录。
    /// 反过来（先删备份再写历史）一旦历史写失败，历史会显示「已压缩」而备份已经没了 ——
    /// 用户看到一条永远恢复不了的记录。现在最坏只留下一个没人引用的孤儿目录。
    @discardableResult
    func restore(entry: HistoryEntry, force: Bool) throws -> [String] {
        guard entry.status != .restored else { throw RestoreError.notRestorable }
        guard entry.outputMode == "replace" else {
            // 后缀/目录模式原图从未被改动：撤销 = 删掉这次生成的压缩结果。
            if let output = entry.outputPath, fileExists(at: output) {
                do {
                    try FileManager.default.removeItem(atPath: output)
                } catch {
                    throw RestoreError.io(error.localizedDescription)
                }
            }
            try removeIds([entry.id])
            return [entry.id]
        }
        if !force && Self.hasConflict(entry) { throw RestoreError.conflict }
        guard let backup = entry.backupPath, fileExists(at: backup) else {
            throw RestoreError.backupGone
        }
        let ids = siblingsSharingBackup(entry)
        let backupDirectory = entry.backupPath.flatMap(Self.backupDir(ofBackupPath:))
        try Self.writeBackupBack(to: entry.sourcePath, backup: backup)
        guard markRestored(ids) else {
            // 文件已经回到原图，但状态没落盘：备份必须留着，用户重试即可收敛。
            throw RestoreError.io("文件已恢复，但历史记录状态保存失败，原图备份已保留")
        }
        Self.removeGeneratedOutput(entry)
        if let dir = backupDirectory {
            // 备份在 App Support 内，不需要任何沙盒授权。删不掉只是孤儿，下次退出扫。
            _ = removeDirectory(dir)
        }
        return ids
    }

    /// restore 的对外门面：把异常翻成与 Tauri 线一致的 RestoreOutcome，
    /// 调用方只需要判断 success / conflict。
    func restoreOutcome(entry: HistoryEntry, force: Bool) -> RestoreOutcome {
        do {
            let ids = try restore(entry: entry, force: force)
            return RestoreOutcome(
                success: true, conflict: false,
                filePath: entry.sourcePath, error: nil, historyIds: ids
            )
        } catch let error as RestoreError {
            return RestoreOutcome(
                success: false,
                conflict: error.isConflict,
                filePath: entry.sourcePath,
                error: error.detail,
                historyIds: []
            )
        } catch {
            return RestoreOutcome(
                success: false, conflict: false, filePath: entry.sourcePath,
                error: RestoreError.io(error.localizedDescription).detail, historyIds: []
            )
        }
    }
}

extension RestoreError {
    var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}

private struct BackupMeta: Codable {
    /// 1 = 只有 sourcePath/createdAt（老版本）；2 = 带大小、mtime、扩展名。
    /// 老文件必须还能读：`history.json` 损坏时就靠这份记录重建恢复入口。
    var version: Int = 2
    var sourcePath: String
    var createdAt: Int64
    var originalSize: Int64 = 0
    var originalModifiedAt: Int64? = nil
    var originalExtension: String = ""
}

// MARK: - 历史页每一行能做什么

/// 只有真正被覆盖过、且备份还在的记录才谈得上「恢复原图」。
/// 放在服务层而不是视图层：前端 `canRestoreHistory` 与这条判据必须逐字一致，
/// 两边都有自检钉住（`scripts/test_swift_history.sh` / `tests/history-view.cjs`）。
func historyCanRestore(_ entry: HistoryEntry) -> Bool {
    if entry.status == .recoveryAvailable {
        return entry.backupExists && entry.sourceExists
    }
    return entry.status == .compressed
        && entry.outputMode == "replace"
        && entry.backupExists
        && entry.sourceExists
}

enum HistoryRowAction: Hashable {
    case saveAs        // 另存为：压缩结果还在手上
    case compare       // 对比查看：原图与压缩结果两边都在
    case restore       // 恢复原图：覆盖模式且备份还在
    case deleteOutput  // 删除这次压缩结果：后缀 / 目录模式的对等撤销
    case finder        // 在访达中显示
    case copyLog       // 复制日志

    var title: String {
        switch self {
        case .saveAs: return "另存为"
        case .compare: return "对比查看"
        case .restore: return "恢复原图"
        case .deleteOutput: return "删除这次压缩结果"
        case .finder: return "在访达中显示"
        case .copyLog: return "复制日志"
        }
    }

    var symbol: String {
        switch self {
        case .saveAs: return "square.and.arrow.down"
        case .compare: return "rectangle.split.2x1"
        case .restore: return "arrow.uturn.backward"
        case .deleteOutput: return "trash"
        case .finder: return "folder"
        case .copyLog: return "doc.on.doc"
        }
    }
}

/// 历史行的按钮，与「压缩完成」那一行同一套动作。
///
/// 判据只用 `decorate` 现算出来的三个 exists 标志：按下去却不成立的按钮一律不出现 ——
/// 后缀模式的原图从没被覆盖过，给它「恢复原图」只会让人以为能撤销，而真正对等的动作是
/// 删掉这次生成的产物；备份已经清掉的记录则连一个反悔按钮都不该有。
func historyRowActions(_ entry: HistoryEntry) -> [HistoryRowAction] {
    var actions: [HistoryRowAction] = []
    // 「原图还摸得着吗」按模式判：覆盖模式只有备份算数（源位置此刻躺着的是压缩结果），
    // 后缀 / 目录模式的源文件本身就没被动过。
    let originalAvailable = entry.outputMode == "replace"
        ? entry.backupExists
        : entry.sourceExists
    if entry.outputExists { actions.append(.saveAs) }
    // 两边都是真实存在、且不是同一个文件才比得出差别 —— 备份没了还挂一个「对比」，
    // 比的是那张压缩图和它自己。
    if entry.outputExists && originalAvailable { actions.append(.compare) }
    if historyCanRestore(entry) {
        actions.append(.restore)
    } else if entry.status == .compressed && entry.outputMode != "replace" && entry.outputExists {
        actions.append(.deleteOutput)
    }
    actions.append(.finder)
    actions.append(.copyLog)
    return actions
}

// MARK: - App 级设置（保留天数）

enum Retention {
    /// `0` = **不保留**（默认档）：覆盖原文件前照旧写备份，正常退出时清干净。
    ///
    /// 这一档不按时间过期 —— 崩溃 / 强杀留下的那份备份可能是唯一还活着的原图。
    static let noRetain = 0
    static let defaultDays = noRetain
    static let minDays = 1
    static let maxDays = 30
    /// 设置页下拉：与 Tauri 前端 retentionDays 选项一致
    static let options = [noRetain, 1, 3, 7, 14, 30]

    static func clamp(_ days: Int) -> Int {
        // 「不保留」是真实档位，不是"没设置"：clamp 到 1 会把它悄悄变成保留 1 天。
        guard days != noRetain else { return noRetain }
        return min(max(days, minDays), maxDays)
    }

    /// 下拉与提示里的档位文案；「不保留」不能说成"保留 0 天"。
    static func label(_ days: Int) -> String {
        days == noRetain ? "不保留" : "保留 \(days) 天"
    }
}

struct AppSettings: Codable {
    /// OctoShrink 自己保存的原图备份保留多久；与用户真实文件无关。
    var originalRetentionDays: Int = Retention.defaultDays
    /// `nil` = 自动。与 Tauri 的 `settings.json` 同一份语义。
    var cpuThreadLimit: Int? = nil
}

final class SettingsStore {
    let path: String

    init(root: String = HistoryStore.appDataRoot()) {
        path = (root as NSString).appendingPathComponent("settings.json")
    }

    /// 读取失败或文件不存在都按默认值处理：老版本升级上来不能崩。
    func load() -> AppSettings {
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return AppSettings(
            originalRetentionDays: Retention.clamp(parsed.originalRetentionDays),
            cpuThreadLimit: (parsed.cpuThreadLimit ?? 0) >= 1 ? parsed.cpuThreadLimit : nil
        )
    }

    @discardableResult
    func save(_ settings: AppSettings) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return false }
        return writeAtomic(path: path, data: data)
    }

    /// 改一项不能顺手把另一项写没：一律读-改-写。
    @discardableResult
    func setRetentionDays(_ days: Int) -> AppSettings {
        var settings = load()
        settings.originalRetentionDays = Retention.clamp(days)
        _ = save(settings)
        return settings
    }

    /// `nil` = 自动；0 是无效值（至少得允许 1 份并行）。
    @discardableResult
    func setCpuThreadLimit(_ limit: Int?) -> AppSettings {
        var settings = load()
        settings.cpuThreadLimit = limit
        _ = save(settings)
        return settings
    }
}
