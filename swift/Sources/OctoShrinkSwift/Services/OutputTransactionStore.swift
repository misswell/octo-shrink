import Foundation

// OctoShrink Swift 原生线 —— replace 模式的覆盖事务日志（crash journal）。
//
// 为什么需要它：backup 写完、压缩结果覆盖到用户文件上、history.add 还没跑 ——
// 就在这个窗口里崩溃或强杀，App 下次启动将完全不知道发生过这次压缩：
// 历史里没有记录，备份目录里躺着一份没人认领的原图，用户看到的却是压缩后的文件。
// transaction 文件就是那段时间的记账凭证：
//
//   ① ensureBackup  ② 写 transaction  ③ 同目录临时文件写压缩结果
//   ④ fsync        ⑤ rename 覆盖目标  ⑥ history.add
//   ⑦ 删 transaction
//
// 启动时凡是**不能被历史证明已完整提交**的事务，一律回滚成真正原图。
// 宁可丢掉一次压缩结果，也不能丢掉原图。
//
// 与 src-tauri/src/output_transaction.rs 同一套语义。

// MARK: - 覆盖失败的分类

/// 每一步的失败都要给出**不同**的处置说明：用户必须知道原图现在到底在哪。
enum OutputWriteError {
    case backupFailed(String)
    case transactionFailed(String)
    case outputWriteFailed(String)
    case historyWriteFailed
    case rollbackFailed(String)

    var userMessage: String {
        switch self {
        case .backupFailed(let detail):
            return "无法保存原图备份，已跳过覆盖（\(detail)）"
        case .transactionFailed(let detail):
            return "无法登记这次覆盖，已跳过覆盖（\(detail)）"
        case .outputWriteFailed(let detail):
            return "压缩结果写入失败，原图未被覆盖（\(detail)）"
        case .historyWriteFailed:
            return "压缩结果已生成，但历史记录保存失败，已自动恢复原图"
        case .rollbackFailed(let detail):
            return "历史记录保存失败，且自动恢复原图也没成功：原图还在那份备份里，"
                + "请不要清理备份，重试恢复即可（\(detail)）"
        }
    }
}

// MARK: - 事务记录

struct ReplaceTransaction: Codable {
    let id: String
    /// 与最终 `HistoryEntry.id` 同一个值：事务是否提交，就靠历史里有没有这个 id 判定。
    let historyId: String
    let sourcePath: String
    let outputPath: String
    let backupPath: String
    /// 压缩结果的临时文件名（rename 后通常已消失，留着只为回滚时清残骸）。
    var tempOutputPath: String?
    let originalSize: Int64
    let expectedOutputSize: Int64
    let createdAt: Int64
    /// PNG → JPG 这类跨格式 replace：压缩结果是个新文件，回滚时要一并删掉。
    let crossFormat: Bool
}

struct RecoveryReport {
    /// 历史已记录，只是删日志前崩溃：补删日志。
    var committed = 0
    /// 回滚成真正原图的事务数。
    var rolledBack = 0
    var warnings: [String] = []
}

// MARK: - 压缩结果的落盘：同目录临时文件 → fsync → rename

/// 临时文件必须和目标同目录，否则 rename 跨挂载点就不是原子操作了。
struct StagedWrite {
    let temp: String

    /// nil = 没写成；目标文件保持原样，临时文件已清掉。
    static func write(target: String, bytes: Data) -> StagedWrite? {
        let parent = (target as NSString).deletingLastPathComponent
        let temp = (parent as NSString).appendingPathComponent(
            ".octoshrink-write-\(OctoClock.nowMillis).tmp"
        )
        let staged = StagedWrite(temp: temp)
        do {
            try bytes.write(to: URL(fileURLWithPath: temp), options: [])
        } catch {
            staged.discard()
            return nil
        }
        // 落盘确认：崩溃后 rename 过去的不能是个只在内核缓存里的文件。
        syncFile(at: temp)
        guard Darwin.rename(temp, target) == 0 else {
            staged.discard()
            return nil
        }
        return staged
    }

    /// 事后清理临时文件（正常情况下 rename 已经把它变成目标了）。
    func discard() {
        try? FileManager.default.removeItem(atPath: temp)
    }
}

// MARK: - 事务存储

/// 事务存储。除了一个只读的 `root`，没有任何进程内状态：每一次记账都是
/// 独立文件的原子写（id 唯一，互不覆盖），所以可以安全地跨线程用。
final class OutputTransactionStore: @unchecked Sendable {
    static let dirName = "transactions"

    let root: String

    init(root: String = HistoryStore.appDataRoot()) {
        self.root = (root as NSString).appendingPathComponent(Self.dirName)
    }

    private func path(of id: String) -> String {
        (root as NSString).appendingPathComponent("\(id).json")
    }

    /// 覆盖发生**之前**登记。写不进日志就不许覆盖 —— 没有记账凭证的覆盖等于不可恢复。
    func prepare(_ txn: ReplaceTransaction) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(txn) else {
            return "事务日志编码失败"
        }
        guard writeAtomic(path: path(of: txn.id), data: data) else {
            return "无法写入覆盖事务日志"
        }
        return nil
    }

    /// 事务已完整提交（历史也写成了）：销账。
    func finish(_ id: String) {
        try? FileManager.default.removeItem(atPath: path(of: id))
    }

    func list() -> [ReplaceTransaction] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let decoder = JSONDecoder()
        var found: [ReplaceTransaction] = []
        for name in names.sorted() {
            guard name.hasSuffix(".json") else { continue }
            let file = (root as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: file) else { continue }
            if let txn = try? decoder.decode(ReplaceTransaction.self, from: data) {
                found.append(txn)
            } else {
                // 半个日志文件：无法判定它代表哪次覆盖，改名留下现场，绝不据此删任何东西。
                let kept = (root as NSString).appendingPathComponent(
                    (name as NSString).deletingPathExtension + ".unparsed")
                try? fm.removeItem(atPath: kept)
                _ = Darwin.rename(file, kept)
            }
        }
        return found.sorted { $0.createdAt < $1.createdAt }
    }

    func hasPending() -> Bool {
        !list().isEmpty
    }

    /// 启动时第一件事：把上次没走完的事务结清。**必须早于任何清理** ——
    /// 回滚要用的那份备份如果被清理当成孤儿扫掉，原图就真没了。
    func recover(_ history: HistoryStore) -> RecoveryReport {
        var report = RecoveryReport()
        for txn in list() {
            if history.containsCommitted(txn.historyId) {
                finish(txn.id)
                report.committed += 1
                continue
            }
            if let error = Self.rollback(txn) {
                report.warnings.append("\(txn.sourcePath) 回滚失败，原图仍在备份里: \(error)")
            } else {
                finish(txn.id)
                report.rolledBack += 1
            }
        }
        return report
    }

    /// 用备份把真正原图写回源位置，再清掉这次生成的压缩结果。
    ///
    /// 备份本身**不删**：回滚半途失败时它是唯一的原图副本，留给历史页/下次启动处理。
    static func rollback(_ txn: ReplaceTransaction) -> String? {
        guard fileExists(at: txn.backupPath) else {
            return "备份已不存在，无法自动恢复原图"
        }
        do {
            try HistoryStore.writeBackupBack(to: txn.sourcePath, backup: txn.backupPath)
        } catch let error as RestoreError {
            return error.detail
        } catch {
            return error.localizedDescription
        }
        removeGeneratedOutput(txn)
        return nil
    }

    /// 删掉这次压缩产生的新文件与临时文件。同格式 replace 的输出就是源文件本身，绝不删。
    static func removeGeneratedOutput(_ txn: ReplaceTransaction) {
        if txn.crossFormat || !sameFile(txn.outputPath, txn.sourcePath) {
            try? FileManager.default.removeItem(atPath: txn.outputPath)
        }
        if let temp = txn.tempOutputPath {
            try? FileManager.default.removeItem(atPath: temp)
        }
    }
}
