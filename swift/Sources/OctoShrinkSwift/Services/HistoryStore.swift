import Foundation

// OctoShrink Swift 原生线 —— 持久化的压缩历史与原图备份。
//
// 与 src-tauri/src/history.rs 同一套语义，只是落在自己的 App Support 目录：
// 清理只针对 OctoShrink 自己写的副本 —— 用户的原图和压缩结果永远不在删除范围内。
//
// retentionDays > 0：备份随退出保留，在**下一次启动**按天数清理。
// retentionDays == 0（「不保留」，默认档）：备份随这次运行存活，覆盖原文件前照写
// 不误，在**正常退出**时清干净；异常退出留下的等下次正常退出，启动时只扫无人引用的孤儿。

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
        backupExists: Bool
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, expiresAt, sourcePath, outputPath, fileName, outputMode
        case originalSize, compressedSize, savings, outType, algorithm, backupPath
        case status, restoredAt, outputModifiedAt, sourceExists, backupExists
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
    /// 一次成功产出对应一条历史。`expiresAt` 只用于展示：启动清理按 `created_at`
    /// 判定，所以同一张图重压多次时，备份的存活期顺延到最后一次相关压缩之后。
    static func record(
        source: String,
        result: CompressResult,
        output: String,
        backup: String?,
        retentionDays: Int
    ) -> HistoryEntry {
        let createdAt = OctoClock.nowMillis
        entrySequence.lock()
        entryCounter &+= 1
        let sequence = entryCounter
        entrySequence.unlock()
        let canonical = canonicalPath(source)
        return HistoryEntry(
            id: "\(OctoClock.nowNanos)-\(sequence)-\(HistoryStore.backupKey(forPath: canonical))",
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
        // 「不保留」档退出后就会走到这里：原图确实被覆盖过，只是备份没了。
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

    let root: String
    private let lock = NSLock()

    /// Swift 线用自己的 App Support 子目录：与 Direct / App Store 两条 Tauri 线
    /// 的 history.json 完全隔离，避免三个进程写同一份历史。
    static func appDataRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.misswell.octoshrink.swift").path
    }

    init(root: String = HistoryStore.appDataRoot()) {
        self.root = root
        try? FileManager.default.createDirectory(
            atPath: backupsDir, withIntermediateDirectories: true
        )
    }

    var historyFile: String { (root as NSString).appendingPathComponent(Self.historyFileName) }
    var backupsDir: String { (root as NSString).appendingPathComponent(Self.backupsDirName) }

    // ─── 读写 ────────────────────────────────────────────────────

    private func readRaw() -> [HistoryEntry] {
        guard let data = FileManager.default.contents(atPath: historyFile),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return entries
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
        return writeRaw(entries)
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

    /// 为一次 replace 压缩准备原图备份，返回 nil 表示备份没写成。
    ///
    /// 关键不变量：**已有有效备份时绝不覆盖**。同一张图连压三次，备份里永远是
    /// 第一次压缩前的真正原图，否则「恢复原图」只会回到上一版压缩结果。
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
            guard copyFileOverwriting(from: canonical, to: backupPath) else { return nil }
            let meta = BackupMeta(sourcePath: canonical, createdAt: OctoClock.nowMillis)
            if let data = try? JSONEncoder().encode(meta) {
                _ = writeAtomic(
                    path: (dir as NSString).appendingPathComponent(Self.metaFileName),
                    data: data
                )
            }
            return backupPath
        }
        return nil
    }

    // ─── 启动清理 ────────────────────────────────────────────────

    /// 只在启动时调用一次：删掉过期记录，再删掉已经没有任何记录引用的备份。
    /// 单个删除失败只记 warning，剩下的孤儿下次启动继续扫。
    ///
    /// `retentionDays == 0`（不保留）**不按时间过期**：这一档的清理挂在正常退出上，
    /// 这里只扫没人引用的孤儿。
    func cleanupExpired(retentionDays: Int) -> CleanupReport {
        lock.lock(); defer { lock.unlock() }
        var report = CleanupReport()
        let expiresByTime = retentionDays > Retention.noRetain
        let cutoff = OctoClock.nowMillis - Int64(max(1, retentionDays)) * historyDayMillis
        let all = readRaw()
        let kept = all.filter { entry in
            let expired = expiresByTime && entry.createdAt < cutoff
            if expired { report.removedEntries += 1 }
            return !expired
        }
        guard writeRaw(kept) else {
            report.warnings.append("history.json 写入失败")
            return report
        }
        sweepUnreferencedBackups(kept: kept, report: &report)
        return report
    }

    /// 「不保留」档：正常退出时把所有原图备份清干净。
    ///
    /// 历史条目本身留着 —— 那是用户的压缩记录，不是原图。只抹掉 `backupPath`，
    /// 读出来 `backupExists == false`，历史页自然显示「原图备份已清理」并收起恢复按钮。
    func purgeBackupsOnExit() -> CleanupReport {
        lock.lock(); defer { lock.unlock() }
        var report = CleanupReport()
        var cleared = readRaw()
        for index in cleared.indices { cleared[index].backupPath = nil }
        guard writeRaw(cleared) else {
            report.warnings.append("history.json 写入失败")
            return report
        }
        // 传空列表：备份目录里剩下的每一份都不再被引用，一并清掉。
        sweepUnreferencedBackups(kept: [], report: &report)
        return report
    }

    /// 删掉没有任何存活条目引用的备份目录。调用方必须已持有 `lock`。
    private func sweepUnreferencedBackups(kept: [HistoryEntry], report: inout CleanupReport) {
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

    private func markRestored(_ ids: [String]) {
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
        if touched { _ = writeRaw(entries) }
    }

    private func removeIds(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        let before = readRaw()
        let after = before.filter { !ids.contains($0.id) }
        if after.count != before.count { _ = writeRaw(after) }
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

    /// 把备份原子地写回源路径，并处理跨格式输出的清理。
    private func restoreBackupFiles(_ entry: HistoryEntry) throws {
        guard let backup = entry.backupPath, fileExists(at: backup) else {
            throw RestoreError.backupGone
        }
        let target = entry.sourcePath
        let parent = (target as NSString).deletingLastPathComponent
        let tmp = (parent as NSString).appendingPathComponent(
            ".octoshrink-restore-\(OctoClock.nowNanos).tmp"
        )
        guard copyFileOverwriting(from: backup, to: tmp) else {
            throw RestoreError.io("无法写入恢复临时文件")
        }
        if Darwin.rename(tmp, target) != 0 {
            // 覆盖到一半失败时保留原目标文件，只清掉临时文件。
            try? FileManager.default.removeItem(atPath: tmp)
            throw RestoreError.io("无法把原图写回目标位置")
        }
        // 跨格式 replace（PNG → JPG）时压缩结果是个新文件，恢复后不该留下孤儿。
        if let output = entry.outputPath, output != target {
            try? FileManager.default.removeItem(atPath: output)
        }
    }

    /// 统一恢复入口：主队列 / 历史页 / 恢复全部 都走这里，
    /// 避免三套逻辑对历史状态的处理不一致。
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
            removeIds([entry.id])
            return [entry.id]
        }
        if !force && Self.hasConflict(entry) { throw RestoreError.conflict }
        let ids = siblingsSharingBackup(entry)
        let backupDir = entry.backupPath.flatMap(Self.backupDir(ofBackupPath:))
        try restoreBackupFiles(entry)
        if let dir = backupDir {
            // 备份在 App Support 内，不需要任何沙盒授权。
            _ = removeDirectory(dir)
        }
        markRestored(ids)
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
    var sourcePath: String
    var createdAt: Int64
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
