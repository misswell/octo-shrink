// OctoShrink Swift 线 —— 历史 / 原图备份 / 暂停 / CPU 上限的行为自检。
//
// 跑法：bash scripts/test_swift_history.sh
// Swift 线用 swiftc 直接编译、没有 Package.swift 测试 target，所以这里是可执行自检而不是 XCTest。
//
// 守的是规范里最不能坏的几条：备份绝不覆盖真正原图、启动清理只删 OctoShrink
// 自己的副本、「不保留」档只在正常退出时清备份（崩溃现场那份可能是唯一的原图）、
// 恢复必须原子写回、压缩后被外部改过必须先问用户、暂停和改 CPU 上限都只拦
// 「还没开始」的任务、CPU 上限真的限住同时跑的任务数。

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

let fm = FileManager.default

func freshRoot(_ tag: String) -> String {
    let dir = NSTemporaryDirectory() + "octoshrink-swift-check-\(tag)-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func tempStore(_ tag: String, at root: String? = nil) -> HistoryStore {
    HistoryStore(root: root ?? freshRoot(tag))
}

func makeFile(_ path: String, _ bytes: [UInt8]) {
    try? fm.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
    )
    fm.createFile(atPath: path, contents: Data(bytes))
}

func writeData(_ path: String, _ bytes: [UInt8]) {
    try? Data(bytes).write(to: URL(fileURLWithPath: path))
}

func readBytes(_ path: String) -> [UInt8] {
    Array(fm.contents(atPath: path) ?? Data())
}

// MARK: - 并发观测（CPU 并行上限自检）

/// 「同时在跑几个」的峰值记录器。
final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var peakValue = 0
    private var doneValue = 0

    func begin() {
        lock.lock()
        running += 1
        peakValue = max(peakValue, running)
        lock.unlock()
    }

    func end() {
        lock.lock()
        running -= 1
        doneValue += 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }

    var done: Int {
        lock.lock()
        defer { lock.unlock() }
        return doneValue
    }
}

typealias TaskGroup = DispatchGroup

/// 铺下 tasks 个任务让它们通过调度器跑，每个占住名额 holdSeconds 秒，不等待收尾。
///
/// 队列必须是并发队列：worker 会在 acquire 里堵着等名额，串行队列会自己等自己。
func launchTasks(
    _ scheduler: CompressionScheduler, tasks: Int, holdSeconds: Double
) -> (meter: PeakMeter, group: TaskGroup) {
    let meter = PeakMeter()
    let group = TaskGroup()
    let queue = DispatchQueue(label: "octoshrink-scheduler-check", attributes: .concurrent)
    for _ in 0..<tasks {
        group.enter()
        queue.async {
            let permit = scheduler.acquire()
            meter.begin()
            Thread.sleep(forTimeInterval: holdSeconds)
            meter.end()
            permit.release()
            group.leave()
        }
    }
    return (meter, group)
}

/// 等某个条件成立，超时返回 false —— 测试里宁可慢一秒，不要死等。
func waitUntil(timeout: TimeInterval = 1.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return true
}

/// 把一条记录改老，用来模拟"跨过保留期后再次启动"。
func ageEntry(_ id: String, daysAgo: Double, in store: HistoryStore) {
    var entries = store.list()
    for index in entries.indices where entries[index].id == id {
        entries[index].createdAt = OctoClock.nowMillis - Int64(daysAgo * Double(historyDayMillis))
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    _ = writeAtomic(path: store.historyFile, data: data)
}

func result(file: String, size: Int64, outType: String = "png") -> CompressResult {
    var item = CompressResult(
        engine: EngineResult(success: true, compressed: Data([1, 2, 3]), outType: outType, algorithm: "mozjpeg"),
        file: file,
        originalSize: 1000
    )
    item.compressedSize = size
    return item
}

// ─── 1. 同一张图重压多次：备份永远是第一次压缩之前的真正原图 ────────────────
print("[1] ensureBackup 绝不覆盖真正原图")
do {
    let store = tempStore("1")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-1/a.png")
    makeFile(source, [1, 1, 1])

    let first = store.ensureBackup(for: source)
    writeData(source, [9, 9, 9]) // 模拟第一次压缩覆盖了原图
    let second = store.ensureBackup(for: source)

    check(first != nil, "第一次备份成功")
    check(first == second, "同一张图复用同一个备份槽位")
    check(first.flatMap { readBytes($0) } == [1, 1, 1], "备份里仍是真正的原图，不是上一版压缩结果")
    check(readBytes(source) == [9, 9, 9], "重压不改动磁盘上的当前版本")
}

// ─── 2. 备份 key 跨启动稳定 ────────────────────────────────────────────────
print("[2] backupKey 跨启动稳定")
do {
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-2/b.jpg")
    makeFile(source, [4, 4])
    let keyA = HistoryStore.backupKey(forPath: source)
    let keyB = tempStore("2").ensureBackup(for: source).flatMap { HistoryStore.key(ofBackupPath: $0) }
    check(keyA == keyB, "备份目录名 = 源路径的稳定哈希")
    check(keyA.count == 16, "key 是 16 位十六进制")
    check(tempStore("2").ensureBackup(for: source).flatMap { HistoryStore.key(ofBackupPath: $0) } == keyA,
          "换一个 store 实例（相当于重启）仍指向同一备份")

    // 哈希撞槽时往后挪位，不能串了别人的原图
    let store = tempStore("2b")
    let taken = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-2b/taken.png")
    makeFile(taken, [7])
    let dir = store.backupsDir + "/" + HistoryStore.backupKey(forPath: taken)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    writeData(dir + "/" + HistoryStore.metaFileName,
              Array("{\"sourcePath\":\"/somewhere/else\",\"createdAt\":1}".utf8))
    let moved = store.ensureBackup(for: taken)
    check(moved != nil && moved != dir + "/original.png", "槽位被别的源占用时挪到下一个槽位")
    check(moved.map { readBytes($0) } == [7], "挪位后备份的仍是本图真正原图")
}

// ─── 3. 启动清理只删 OctoShrink 自己的记录与备份 ───────────────────────────
// 这里测的是"按天保留"那一支，所以显式写 3 天，不用 Retention.defaultDays
// （默认档已经变成 0 = 不保留，见 [19]）。
print("[3] cleanupExpired 只清自己的副本")
do {
    let store = tempStore("3")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-3/c.png")
    makeFile(source, [7, 7, 7])
    let userOutput = ((source as NSString).deletingPathExtension) + "_compressed.png"
    makeFile(userOutput, [8, 8])

    let backup = store.ensureBackup(for: source)!
    let entry = HistoryEntry.record(
        source: source,
        result: result(file: source, size: 3),
        output: source,
        backup: backup,
        retentionDays: 3
    )
    store.add(entry)
    ageEntry(entry.id, daysAgo: 10, in: store)

    let report = store.cleanupExpired(retentionDays: 3)
    check(report.removedEntries == 1, "过期历史记录被删除")
    check(report.removedBackups == 1, "无人引用的原图备份被删除")
    check(store.list().isEmpty, "历史页清空")
    check(!fm.fileExists(atPath: backup), "备份文件本体已删除")
    check(fm.fileExists(atPath: source), "用户的原图绝不因历史过期而被删")
    check(fm.fileExists(atPath: userOutput), "用户的压缩结果绝不因历史过期而被删")

    let freshBackup = store.ensureBackup(for: userOutput)!
    let fresh = HistoryEntry.record(
        source: userOutput,
        result: result(file: userOutput, size: 2),
        output: userOutput,
        backup: freshBackup,
        retentionDays: 30
    )
    store.add(fresh)
    let second = store.cleanupExpired(retentionDays: 3)
    check(second.keptBackups == 1 && second.removedBackups == 0, "未过期备份被保留")
    check(fm.fileExists(atPath: userOutput) && fm.fileExists(atPath: source), "保留期内用户文件不受影响")
}

// ─── 4. 恢复：原子写回真正原图 + 清跨格式孤儿 + 共享备份一起标已恢复 ────────
print("[4] restore 原子写回并共享备份")
do {
    let store = tempStore("4")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-4/d.png")
    makeFile(source, [1, 2, 3])
    let backup = store.ensureBackup(for: source)!

    // 跨格式 replace：压缩结果是个新文件
    let output = ((source as NSString).deletingPathExtension) + ".jpg"
    writeData(output, [5, 5, 5, 5])
    writeData(source, [6, 6, 6])

    var compressed = result(file: source, size: 4, outType: "jpg")
    compressed.outputPath = output
    compressed.outputMode = "replace"
    let first = HistoryEntry.record(source: source, result: compressed, output: output,
                                    backup: backup, retentionDays: 3)
    store.add(first)
    let second = HistoryEntry.record(source: source, result: compressed, output: output,
                                     backup: backup, retentionDays: 3)
    store.add(second)

    let ids = try? store.restore(entry: first, force: false)
    check(ids?.count == 2, "共享同一备份的两条记录一起处理（\(ids?.count ?? 0) 条）")
    check(readBytes(source) == [1, 2, 3], "写回的是真正的原图")
    check(!fm.fileExists(atPath: output), "跨格式的压缩结果不留孤儿")
    check(!fm.fileExists(atPath: backup), "备份目录已清理")
    let listed = store.list()
    check(listed.count == 2 && listed.allSatisfy { $0.status == .restored }, "两条记录都是「已恢复」")
    check(listed.allSatisfy { $0.backupPath == nil && !$0.backupExists }, "已恢复记录不再引用备份")
    let again = store.restoreOutcome(entry: listed[0], force: false)
    check(!again.success && !again.conflict, "重复恢复被拒：\(again.error ?? "")")
    // 目录里没有残留的 .octoshrink-restore-*.tmp（原子替换不留临时文件）
    let leftovers = ((try? fm.contentsOfDirectory(atPath: (source as NSString).deletingLastPathComponent)) ?? [])
        .filter { $0.hasPrefix(".octoshrink-restore-") }
    check(leftovers.isEmpty, "恢复不留临时文件")
}

// ─── 5. 压缩后被外部改过：先报冲突，force 才覆盖 ───────────────────────────
print("[5] 外部修改检测")
do {
    let store = tempStore("5")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-5/e.png")
    makeFile(source, [1, 0, 0])
    let backup = store.ensureBackup(for: source)!
    writeData(source, [2, 2, 2]) // 压缩结果落盘
    var compressed = result(file: source, size: 3)
    compressed.outputPath = source
    compressed.outputMode = "replace"
    let entry = HistoryEntry.record(source: source, result: compressed, output: source,
                                    backup: backup, retentionDays: 3)
    store.add(entry)
    check(!HistoryStore.hasConflict(entry), "刚压完不算冲突")

    writeData(source, [3, 3, 3, 3, 3]) // 用户又用别的 App 改过
    let refreshed = store.find(entry.id)!
    check(HistoryStore.hasConflict(refreshed), "体积变了 = 压缩后被改过")

    let outcome = store.restoreOutcome(entry: refreshed, force: false)
    check(!outcome.success && outcome.conflict, "不 force 时只报冲突")
    check(readBytes(source) == [3, 3, 3, 3, 3], "冲突时当前版本保持原样")
    check(fm.fileExists(atPath: backup), "冲突时备份不被销毁")

    let forced = store.restoreOutcome(entry: refreshed, force: true)
    check(forced.success, "用户确认后 force 恢复成功")
    check(readBytes(source) == [1, 0, 0], "force 后写回真正原图")
}

// ─── 6. mtime 抖动容忍窗 ───────────────────────────────────────────────────
print("[6] mtime 抖动容忍 2 秒")
do {
    let store = tempStore("6")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-6/f.png")
    makeFile(source, [1, 1])
    let backup = store.ensureBackup(for: source)!
    writeData(source, [2, 2])
    var compressed = result(file: source, size: 2)
    compressed.outputPath = source
    compressed.outputMode = "replace"
    var entry = HistoryEntry.record(source: source, result: compressed, output: source,
                                    backup: backup, retentionDays: 3)
    let current = fileMtimeMillis(source) ?? 0
    entry.outputModifiedAt = current - 1_000
    check(!HistoryStore.hasConflict(entry), "1 秒抖动不误报")
    entry.outputModifiedAt = current - 60_000
    check(HistoryStore.hasConflict(entry), "1 分钟差 = 真被改过")
    entry.outputMode = "suffix"
    check(!HistoryStore.hasConflict(entry), "非覆盖模式永不报冲突")
}

// ─── 7. 后缀/目录模式：撤销 = 只删这次生成的压缩结果 ───────────────────────
print("[7] 非覆盖模式的撤销")
do {
    let store = tempStore("7")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-7/g.png")
    makeFile(source, [1, 1, 1])
    let output = ((source as NSString).deletingPathExtension) + "_compressed.png"
    makeFile(output, [2, 2])
    var compressed = result(file: source, size: 2)
    compressed.outputPath = output
    compressed.outputMode = "suffix"
    let entry = HistoryEntry.record(source: source, result: compressed, output: output,
                                    backup: nil, retentionDays: 3)
    store.add(entry)

    let ids = try? store.restore(entry: entry, force: false)
    check(ids == [entry.id], "撤销返回被处理的记录 id")
    check(!fm.fileExists(atPath: output), "这次生成的压缩结果被删掉")
    check(readBytes(source) == [1, 1, 1], "原图从头到尾没被碰过")
    check(store.find(entry.id) == nil, "撤销后这条历史不再存在")
}

// ─── 8. 主队列按源路径取最近一条未恢复记录 ─────────────────────────────────
print("[8] findLatest(forSource:)")
do {
    let store = tempStore("8")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-8/h.png")
    makeFile(source, [1])
    var compressed = result(file: source, size: 1)
    compressed.outputPath = source
    compressed.outputMode = "replace"
    let backup = store.ensureBackup(for: source)!
    let older = HistoryEntry.record(source: source, result: compressed, output: source,
                                    backup: backup, retentionDays: 3)
    store.add(older)
    Thread.sleep(forTimeInterval: 0.01)
    let newer = HistoryEntry.record(source: source, result: compressed, output: source,
                                    backup: store.ensureBackup(for: source), retentionDays: 3)
    store.add(newer)
    check(store.findLatest(forSource: source)?.id == newer.id, "取最近一条未恢复的记录")
    // 符号链接写法（/var ↔ /private/var）也要命中同一条记录
    check(store.findLatest(forSource: NSTemporaryDirectory().replacingOccurrences(of: "/private", with: "")
                              + "octoshrink-check-8/h.png")?.id == newer.id, "路径规范化后才比对")
    _ = try? store.restore(entry: newer, force: false)
    check(store.findLatest(forSource: source) == nil, "共享备份的兄弟记录一起标已恢复")
}

// ─── 9. 清空历史只删自己的备份 ─────────────────────────────────────────────
print("[9] clear 清空历史")
do {
    let store = tempStore("9")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-9/i.png")
    makeFile(source, [1, 2])
    var compressed = result(file: source, size: 2)
    compressed.outputPath = source
    compressed.outputMode = "replace"
    let backup = store.ensureBackup(for: source)!
    store.add(HistoryEntry.record(source: source, result: compressed, output: source,
                                  backup: backup, retentionDays: 3))
    let report = store.clear()
    check(report.removedEntries == 1 && report.removedBackups == 1, "记录与备份一起清掉")
    check(store.list().isEmpty, "历史为空")
    check(fm.fileExists(atPath: source), "用户图片仍在")
}

// ─── 10. 保留天数持久化与钳制 ──────────────────────────────────────────────
print("[10] 保留天数持久化")
do {
    let root = freshRoot("10")
    let settings = SettingsStore(root: root)
    // 写死 0，不让断言变成"默认值等于默认值"的同义反复。
    check(Retention.defaultDays == 0 && Retention.noRetain == 0, "默认档就是「不保留」")
    check(settings.load().originalRetentionDays == 0, "缺文件时按默认「不保留」")
    settings.setRetentionDays(14)
    check(SettingsStore(root: root).load().originalRetentionDays == 14, "重启后仍是 14 天")
    settings.setRetentionDays(0)
    check(SettingsStore(root: root).load().originalRetentionDays == 0,
          "「不保留」存得住，不被当成没设置")
    check(Retention.clamp(0) == 0
            && Retention.clamp(-5) == Retention.minDays
            && Retention.clamp(9000) == Retention.maxDays,
          "clamp 保住 0，只有越界才夹进 1…30")
    check(Retention.label(0) == "不保留" && Retention.label(7) == "保留 7 天",
          "「不保留」不许写成「保留 0 天」")
    writeData(root + "/settings.json", Array("not json".utf8))
    check(SettingsStore(root: root).load().originalRetentionDays == 0,
          "settings.json 损坏时回落默认值，不崩")
}

// ─── 11. 备份写不成就不碰用户文件 ──────────────────────────────────────────
print("[11] 备份失败时绝不覆盖原图")
do {
    let root = freshRoot("11")
    writeData(root + "/backups", [0]) // backups 位置做成普通文件 → 建目录必失败
    let store = HistoryStore(root: root)
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-11/j.png")
    makeFile(source, [1, 2, 3])
    check(store.ensureBackup(for: source) == nil, "备份写不成时返回 nil")
    check(readBytes(source) == [1, 2, 3], "调用方据此跳过覆盖，用户文件保持原样")
}

// ─── 12. 调度闸门只拦新任务（暂停与 CPU 上限共用一把锁） ────────────────────
print("[12] CompressionScheduler：暂停只拦新任务")
do {
    let scheduler = CompressionScheduler(maxParallelism: 3)
    let meter = PeakMeter()
    check(!scheduler.isPaused, "初始未暂停")
    check(scheduler.state == "idle", "没有批次在跑时状态为 idle")

    scheduler.beginBatch()
    check(scheduler.state == "running", "批次开始后状态为 running")
    scheduler.pause()
    check(scheduler.isPaused, "pause 后处于暂停")
    check(scheduler.state == "paused", "状态为 paused")

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        let permit = scheduler.acquire()
        meter.begin()
        permit.release()
        meter.end()
        group.leave()
    }
    Thread.sleep(forTimeInterval: 0.15)
    check(meter.peak == 0, "暂停期间不开工新任务（正在跑的不受影响）")

    scheduler.resume()
    group.wait()
    check(meter.peak == 1, "resume 后等待中的任务继续")

    scheduler.pause()
    scheduler.beginBatch()
    check(!scheduler.isPaused, "新批次不继承上一批的暂停")
    scheduler.pause()
    scheduler.endBatch()
    check(!scheduler.isPaused, "批次收尾必然解除暂停")
    check(scheduler.state == "idle", "批次收尾后回到 idle")
}

// ─── 13. history.json 字段命名与 Tauri 线一致 ─────────────────────────────
print("[13] history.json 为 camelCase")
do {
    let store = tempStore("13")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-13/k.png")
    makeFile(source, [1])
    var compressed = result(file: source, size: 1)
    compressed.outputPath = source
    compressed.outputMode = "replace"
    store.add(HistoryEntry.record(source: source, result: compressed, output: source,
                                  backup: store.ensureBackup(for: source), retentionDays: 3))
    let raw = String(data: fm.contents(atPath: store.historyFile) ?? Data(), encoding: .utf8) ?? ""
    for key in ["sourcePath", "outputPath", "backupPath", "originalSize", "compressedSize",
                "outputMode", "outputModifiedAt", "createdAt", "expiresAt", "outType",
                "status", "sourceExists", "backupExists"] {
        check(raw.contains("\"\(key)\""), "字段 \(key)")
    }
    check(raw.contains("mozjpeg"), "算法名照常落库")

    _ = try? store.restore(entry: store.list()[0], force: false)
    let restored = String(data: fm.contents(atPath: store.historyFile) ?? Data(), encoding: .utf8) ?? ""
    check(restored.contains("\"restoredAt\""), "恢复之后才写入 restoredAt")
}

// ─── 14. CPU 并行上限真正限住同时跑的任务数（方案 §68） ─────────────────────
print("[14] CPU 上限限住并发任务数")
do {
    let four = CompressionScheduler(maxParallelism: 4)
    four.beginBatch(maxParallelism: 4)
    let (meter4, group4) = launchTasks(four, tasks: 100, holdSeconds: 0.002)
    group4.wait()
    check(meter4.done == 100, "100 个任务一个都没少")
    check(meter4.peak <= 4, "上限 4 时全程峰值并发 \(meter4.peak) 从未超过 4")
    check(meter4.peak >= 2, "预算内确实并行，不是退化成串行（峰值 \(meter4.peak)）")
    four.endBatch()

    let one = CompressionScheduler(maxParallelism: 1)
    one.beginBatch(maxParallelism: 1)
    let (meter1, group1) = launchTasks(one, tasks: 30, holdSeconds: 0.001)
    group1.wait()
    check(meter1.peak == 1, "上限 1 时严格串行（峰值 \(meter1.peak)）")
    one.endBatch()

    // 0 / 负数这类无效值不能把闸门拆成「不限」。
    check(CompressionScheduler(maxParallelism: 0).currentLimit == 1, "上限 0 兜底为 1")
    check(CompressionScheduler(maxParallelism: -5).currentLimit == 1, "负数上限兜底为 1")
}

// ─── 15. 运行中改上限：不抢占、立刻生效（方案 §59/§60） ─────────────────────
print("[15] 运行中下调 / 上调上限")
do {
    let scheduler = CompressionScheduler(maxParallelism: 8)
    scheduler.beginBatch(maxParallelism: 8)
    let (meter, group) = launchTasks(scheduler, tasks: 16, holdSeconds: 0.06)
    check(waitUntil { scheduler.activeJobs == 8 }, "上限 8 时确实同时跑着 8 个")

    scheduler.setMaxParallelism(2)
    check(scheduler.activeJobs == 8, "下调到 2 不抢回已在跑的任务，8 个各自跑完")

    // 第一波结束后，新启动的只能按新上限来。
    _ = waitUntil(timeout: 2.0) { scheduler.activeJobs <= 2 }
    var observed = 0
    for _ in 0..<15 {
        observed = max(observed, scheduler.activeJobs)
        Thread.sleep(forTimeInterval: 0.01)
    }
    check(observed <= 2, "第一波退去后同时跑的不超过新上限 2（实测 \(observed)）")

    group.wait()
    check(meter.done == 16, "改上限期间没有任务被丢弃")
    check(meter.peak > 2, "下调前起跑的那一批没被打断（峰值 \(meter.peak)）")
    scheduler.endBatch()

    // 2 → 6：等待中的 worker 要立刻被唤醒，而不是靠 250ms 超时兜底。
    let up = CompressionScheduler(maxParallelism: 2)
    up.beginBatch(maxParallelism: 2)
    let (_, upGroup) = launchTasks(up, tasks: 20, holdSeconds: 0.06)
    check(waitUntil { up.activeJobs == 2 }, "上调前先按 2 跑着")
    up.setMaxParallelism(6)
    let woke = Date()
    let reached = waitUntil(timeout: 1.0) { up.activeJobs == 6 }
    let latency = Date().timeIntervalSince(woke)
    check(reached, "2 → 6 后并发升到 6（实测 \(up.activeJobs)）")
    check(latency < 0.1, "唤醒立刻发生，不靠超时兜底（\(Int(latency * 1000))ms）")
    upGroup.wait()
    up.endBatch()
}

// ─── 16. 暂停与 CPU 上限叠加 ────────────────────────────────────────────────
print("[16] 暂停 × CPU 上限")
do {
    let scheduler = CompressionScheduler(maxParallelism: 2)
    scheduler.beginBatch(maxParallelism: 2)
    let (meter, group) = launchTasks(scheduler, tasks: 12, holdSeconds: 0.02)
    check(waitUntil { scheduler.activeJobs == 2 }, "上限 2 生效")

    scheduler.pause()
    let frozen = scheduler.activeJobs
    check(frozen > 0 && frozen <= 2, "暂停时正在跑的任务继续跑完（\(frozen) 个）")
    check(waitUntil(timeout: 1.0) { scheduler.activeJobs == 0 }, "跑完后不再启动新任务")
    let idleSamples = scheduler.activeJobs
    Thread.sleep(forTimeInterval: 0.05)
    check(idleSamples == 0 && scheduler.activeJobs == 0, "暂停期间保持 0 个在跑")

    scheduler.resume()
    group.wait()
    check(meter.done == 12, "恢复后剩余任务全部完成")
    check(meter.peak <= 2, "暂停叠加上限，全程峰值仍不超过 2（实测 \(meter.peak)）")
    scheduler.endBatch()
}

// ─── 17. 每个子进程只占 1 份预算（方案 §51–§54/§57） ────────────────────────
print("[17] CPUResourcePolicy")
do {
    let policy = CPUResourcePolicy(threadLimit: 1)
    check(policy.flags(for: "avifenc") == ["--jobs", "1"], "avifenc 显式 --jobs 1")
    check(policy.flags(for: "oxipng") == ["--threads", "1"], "oxipng 显式 --threads 1")
    check(policy.flags(for: "cwebp").isEmpty, "cwebp 单线程时不带 -mt")
    check(policy.flags(for: "pngquant").isEmpty, "pngquant 没有线程开关，不加无谓参数")
    check(policy.flags(for: "gifsicle").isEmpty, "gifsicle 同上")
    check(CPUResourcePolicy(threadLimit: 4).flags(for: "cwebp") == ["-mt"], "多线程才允许 -mt")
    check(policy.environment["RAYON_NUM_THREADS"] == "1"
              && policy.environment["OMP_NUM_THREADS"] == "1",
          "线程类环境变量压到 1 份")
    // 真子进程环境必须无条件带上预算，不能只在内置动态库存在时才设置。
    check(CLIRunner.environment()["RAYON_NUM_THREADS"] == "1", "子进程环境无条件生效")
    check(CLIRunner.environment()["OMP_NUM_THREADS"] == "1", "OMP 同样无条件生效")
}

// ─── 18. cpuThreadLimit 落盘、取值与文案（方案 §46/§47/§63） ────────────────
print("[18] 设置持久化与展示文案")
do {
    let root = freshRoot("18")
    let store = SettingsStore(root: root)
    check(store.load().cpuThreadLimit == nil, "缺省为自动")
    _ = store.setCpuThreadLimit(4)
    check(store.load().cpuThreadLimit == 4, "改过的上限重启后还在")
    let raw = String(data: fm.contents(atPath: store.path) ?? Data(), encoding: .utf8) ?? ""
    check(raw.contains("\"cpuThreadLimit\""), "与 Tauri 线同名 camelCase 字段")
    check(raw.contains("\"originalRetentionDays\""), "同一份 settings.json，不另开文件")
    _ = store.setRetentionDays(7)
    check(store.load().cpuThreadLimit == 4 && store.load().originalRetentionDays == 7,
          "改保留时间不会顺手抹掉 CPU 上限")
    _ = store.setCpuThreadLimit(nil)
    let auto = String(data: fm.contents(atPath: store.path) ?? Data(), encoding: .utf8) ?? ""
    // Swift 的 Codable 对 nil 是「不写这个键」，Tauri 线写 null —— 两边读出来都是自动。
    check(store.load().cpuThreadLimit == nil && !auto.contains(": 4"),
          "回到自动后文件里不再留着旧数字")
    try? #"{"originalRetentionDays":3,"cpuThreadLimit":0}"#
        .write(toFile: store.path, atomically: true, encoding: .utf8)
    check(store.load().cpuThreadLimit == nil, "0 视为无效，回落自动")

    check(CPULimit.effective(configured: nil, detected: 10) == 3, "自动档不默认吃满全核")
    check(CPULimit.effective(configured: 12, detected: 8) == 8, "换到核少的机器静默收敛 12 → 8")
    check(CPULimit.effective(configured: 1, detected: 8) == 1, "最低档 1 份")
    check(CPULimit.effective(configured: nil, detected: 1) == 1, "单核机器自动档也只有 1")

    let m5 = CpuInfo(architecture: "aarch64", logicalCpus: 10, physicalCpus: 10,
                     performanceCpus: 4, efficiencyCpus: 6, modelName: "Apple M5",
                     availableParallelism: 10)
    check(m5.isAppleSilicon, "Apple M5 认作 Apple Silicon")
    check(CPUStatusText.device(m5) == "Apple M5 · ARM64", "设备行：型号 · 架构")
    check(CPUStatusText.cores(m5) == "10 核 CPU（4 性能核 + 6 能效核）", "Apple Silicon 报 P/E 核")
    check(CPUStatusText.limitLabel(info: m5, configured: nil, effective: 3) == "自动（3）",
          "自动档显示实际取值")
    check(CPUStatusText.limitLabel(info: m5, configured: 4, effective: 4) == "4 / 10", "手动档 4 / 10")
    check(CPUStatusText.limitLabel(info: m5, configured: 10, effective: 10) == "10 / 10（全部）",
          "吃满时标注（全部）")
    check(CPUStatusText.summary(info: m5, configured: nil, effective: 3) == " · CPU 自动",
          "自动档摘要不假装知道具体数字")
    check(CPUStatusText.summary(info: m5, configured: 4, effective: 4) == " · CPU 4/10",
          "手动档摘要 CPU 4/10")

    // aarch64 ≠ Apple Silicon：ARM Windows / Linux 不能凭空报性能核。
    let winArm = CpuInfo(architecture: "aarch64", logicalCpus: 8, physicalCpus: 8,
                         performanceCpus: nil, efficiencyCpus: nil,
                         modelName: "Snapdragon X Elite", availableParallelism: 8)
    check(!winArm.isAppleSilicon, "arm64 不能猜成 Apple Silicon")
    check(!CPUStatusText.cores(winArm).contains("性能核"), "非 Apple 平台不提性能核")

    let intel = CpuInfo(architecture: "x86_64", logicalCpus: 12, physicalCpus: 6,
                        performanceCpus: nil, efficiencyCpus: nil,
                        modelName: "Intel Core i5-8500", availableParallelism: 12)
    check(CPUStatusText.cores(intel) == "6 个物理核心 · 12 个逻辑处理器", "Intel 报物理 / 逻辑")

    let live = CpuInfo.detect()
    check(live.budgetCeiling >= 1, "本机并行能力至少 1 份")
    check(live.architecture == "aarch64" || live.architecture == "x86_64",
          "本机架构 \(live.architecture)")
}

// ─── 19. 「不保留」（默认档）：备份活到本次退出为止 ──────────────────────────
print("[19] 不保留：退出才清，启动不清")
do {
    let root = freshRoot("19")
    let store = tempStore("19", at: root)
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-19/i.png")
    makeFile(source, [1, 9])
    let userOutput = ((source as NSString).deletingPathExtension) + "_compressed.png"
    makeFile(userOutput, [2, 9])

    let backup = store.ensureBackup(for: source)!
    let entry = HistoryEntry.record(
        source: source,
        result: result(file: source, size: 2),
        output: source,
        backup: backup,
        retentionDays: Retention.noRetain
    )
    check(entry.expiresAt == entry.createdAt, "「不保留」没有几天后到期这回事")
    store.add(entry)
    // 上一次崩溃 / 强杀留下的现场：这份备份可能就是唯一还活着的原图。
    ageEntry(entry.id, daysAgo: 10, in: store)
    let orphan = store.ensureBackup(for: userOutput)!

    let startup = store.cleanupExpired(retentionDays: Retention.noRetain)
    check(startup.removedEntries == 0 && store.list().count == 1, "启动时不按时间过期，记录与备份都留着")
    check(fm.fileExists(atPath: backup) && readBytes(backup) == [1, 9],
          "还有人引用的原图备份绝不在启动时被删，且仍是真正的原图")
    check(!fm.fileExists(atPath: orphan), "无人引用的孤儿备份照旧扫掉")

    let quit = store.purgeBackupsOnExit()
    check(quit.removedBackups == 1, "退出时清掉原图备份（\(quit.removedBackups) 份）")
    check(!fm.fileExists(atPath: backup), "备份目录已删除")
    let kept = store.list()
    check(kept.count == 1, "历史记录本身留着 —— 那是用户的压缩记录，不是原图")
    check(kept[0].backupPath == nil && !kept[0].backupExists, "记录不再引用备份，历史页显示「原图备份已清理」")
    check(kept[0].status == .compressed, "退出清理不把记录伪造成「已恢复」")
    check(fm.fileExists(atPath: source) && fm.fileExists(atPath: userOutput), "用户文件一个都不碰")

    let nextLaunch = HistoryStore(root: root)
    check(nextLaunch.list().count == 1 && nextLaunch.list()[0].backupPath == nil,
          "下次启动读到的还是那条历史，只是备份已清")

    let outcome = store.restoreOutcome(entry: kept[0], force: false)
    check(!outcome.success && !outcome.conflict, "备份没了就不假装恢复成功")
    check(outcome.error == "原图备份已清理，无法恢复", "说清是备份没了：\(outcome.error ?? "")")
    check(store.purgeBackupsOnExit().removedBackups == 0, "重复退出清理是幂等的")

    // 不保留 ≠ 关掉备份：覆盖前照旧必须先有备份，这条不变量不能让新档位废掉。
    let again = store.ensureBackup(for: source)
    check(again != nil && readBytes(again!) == [1, 9], "「不保留」照样先备份再覆盖")
    check(Retention.options.first == Retention.noRetain, "设置页下拉第一档就是「不保留」")
}

// ─── 20. history.json 读不出来：隔离现场 + 按备份重建 + 本次禁止清理 ─────────
print("[20] 历史损坏不得变成\"备份没人引用\"")
do {
    let root = freshRoot("20")
    let store = HistoryStore(root: root)
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-20/k.png")
    makeFile(source, [1, 2, 3])
    let backup = store.ensureBackup(for: source)!
    store.add(HistoryEntry.record(
        source: source, result: result(file: source, size: 3), output: source,
        backup: backup, retentionDays: 3
    ))
    // 崩溃留下的半个 history.json：老实现把它当空历史，下一次启动就把所有备份删光。
    writeData(store.historyFile, Array("[{\"id\":\"x\",\"sourcePa".utf8))

    let reopened = HistoryStore(root: root)
    // 生产代码的顺序：先取启动报告（落日志），再跑启动清理。
    let startup = reopened.takeStartupReport()
    check(startup?.recoveredEntries == 1, "启动报告统计到重建条目")
    check(reopened.takeStartupReport() == nil, "启动报告只报一次")
    let report = reopened.cleanupExpired(retentionDays: 3)
    check(report.removedEntries == 0 && report.removedBackups == 0,
          "损坏现场一次备份都不许删（removedBackups \(report.removedBackups)）")
    check(fm.fileExists(atPath: backup) && readBytes(backup) == [1, 2, 3],
          "原图备份完整保留，内容仍是真正原图")
    check(reopened.cleanupIsLocked(), "本次启动锁死备份清理")
    check(report.warnings.contains { $0.contains("已损坏") },
          "报告说清是损坏：\(report.warnings.joined(separator: " / "))")
    check(((try? fm.contentsOfDirectory(atPath: root)) ?? [])
            .contains { $0.hasPrefix("history.corrupt-") },
          "损坏现场被改名留档，而不是被 [] 覆盖")

    // 来历记录是 v1（只有 sourcePath/createdAt）也必须认：老用户的历史就靠它重建。
    let rebuilt = reopened.list()
    check(rebuilt.count == 1, "按备份重建出 1 条恢复入口（实际 \(rebuilt.count)）")
    check(rebuilt.first?.status == .recoveryAvailable, "状态是 recoveryAvailable")
    check(rebuilt.first?.algorithm == HistoryStore.recoveryAlgorithm, "算法位标明不是真实压缩")
    check(rebuilt.first?.backupPath == backup, "重建条目带着备份位置")
    check(rebuilt.first?.sourcePath == source, "重建条目认得原图属于谁")

    // 锁定期内连退出清理也不许动手：历史不可信时备份可能是原图唯一的副本。
    let quit = reopened.purgeBackupsOnExit()
    check(quit.removedBackups == 0 && fm.fileExists(atPath: backup),
          "损坏锁定期内退出也不清备份")

    // 重建条目必须真的能一键恢复，而且不误报冲突（明细填的是当下实测值）。
    let restored = reopened.restoreOutcome(entry: rebuilt[0], force: false)
    check(restored.success, "重建出来的条目能直接恢复：\(restored.error ?? "")")
    check(readBytes(source) == [1, 2, 3], "恢复后源文件回到真正原图")
    check(!fm.fileExists(atPath: backup), "恢复成功后备份才让位")
}

// ─── 21. 覆盖事务：不能被历史证明提交的覆盖一律回滚 ─────────────────────────
print("[21] replace 事务与崩溃恢复")
func transaction(_ id: String, source: String, output: String, backup: String,
                 crossFormat: Bool = false) -> ReplaceTransaction {
    ReplaceTransaction(
        id: id, historyId: id, sourcePath: source, outputPath: output, backupPath: backup,
        tempOutputPath: nil, originalSize: 3, expectedOutputSize: 1,
        createdAt: OctoClock.nowMillis, crossFormat: crossFormat
    )
}

do {
    let root = freshRoot("21")
    let store = HistoryStore(root: root)
    let journal = OutputTransactionStore(root: root)
    let dir = NSTemporaryDirectory() + "octoshrink-check-21"
    let source = canonicalPath(dir + "/a.png")
    makeFile(source, [9, 9, 9])                    // 崩溃现场：源文件已是压缩结果
    let backupFile = dir + "/original.png"
    writeData(backupFile, [1, 2, 3])               // 备份里是真正的原图

    check(journal.prepare(transaction("t-missing", source: source,
                                      output: source, backup: backupFile)) == nil,
          "覆盖前的记账凭证写得成")
    check(journal.hasPending(), "覆盖前登记的记账凭证还在")
    let report = journal.recover(store)
    check(report.rolledBack == 1 && report.warnings.isEmpty,
          "历史证明不了提交 → 自动回滚（\(report.warnings.joined(separator: " / "))）")
    check(readBytes(source) == [1, 2, 3], "源文件回到真正原图")
    check(!journal.hasPending(), "回滚完成即销账")
    check(fm.fileExists(atPath: backupFile), "回滚不许顺手删备份：它可能是原图唯一的副本")

    // 已提交：历史里有同 id 的记录 → 只补删日志，绝不碰用户文件。
    makeFile(source, [9, 9, 9])
    store.add(HistoryEntry.record(withId: "t-committed", source: source,
                                  result: result(file: source, size: 3), output: source,
                                  backup: backupFile, retentionDays: 3))
    _ = journal.prepare(transaction("t-committed", source: source,
                                    output: source, backup: backupFile))
    let committed = journal.recover(store)
    check(committed.committed == 1 && committed.rolledBack == 0, "已提交的事务只销账")
    check(readBytes(source) == [9, 9, 9], "已提交的事务绝不动用户文件")

    // 跨格式：PNG → JPG 的回滚要连转换出来的新文件一起删。
    let png = canonicalPath(dir + "/photo.png")
    makeFile(png, [9, 9])
    let jpg = dir + "/photo.jpg"
    writeData(jpg, [8, 8])
    writeData(backupFile, [1, 2, 3])
    _ = journal.prepare(transaction("t-cross", source: png,
                                    output: jpg, backup: backupFile, crossFormat: true))
    check(journal.recover(store).rolledBack == 1, "跨格式事务被回滚")
    check(readBytes(png) == [1, 2, 3], "跨格式回滚写回真正原图")
    check(!fm.fileExists(atPath: jpg), "跨格式回滚删掉转换出来的新文件")

    // 半个日志文件：认不出代表哪次覆盖，就一个文件都不许动。
    let brokenDir = freshRoot("21b")
    let brokenStore = HistoryStore(root: brokenDir)
    let brokenJournal = OutputTransactionStore(root: brokenDir)
    let kept = canonicalPath(brokenDir + "/kept.png")
    makeFile(kept, [9, 9])
    try? fm.createDirectory(atPath: brokenJournal.root, withIntermediateDirectories: true)
    writeData(brokenJournal.root + "/broken.json", Array("{ half".utf8))
    let unparsed = brokenJournal.recover(brokenStore)
    check(unparsed.rolledBack == 0, "读不懂的日志不做回滚")
    check(readBytes(kept) == [9, 9], "读不懂的日志一个字节都不删")
    check(fm.fileExists(atPath: brokenJournal.root + "/broken.unparsed"), "现场改名留档")
}

// ─── 22. 备份必须"文件 + 来历记录"双全，缺一半就不算备份 ────────────────────
print("[22] 备份必须文件与来历记录双全")
do {
    let root = freshRoot("22")
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-22/m.png")
    makeFile(source, [1, 2, 3])
    let store = HistoryStore(root: root)
    let key = HistoryStore.backupKey(forPath: source)

    // 只有压缩结果、没有来历记录的目录：认不出是谁的原图，绝不能当成备份复用。
    // `history.json` 损坏后就靠 backup-meta.json 重建恢复入口，缺一半等于无从恢复。
    let unlabeled = root + "/backups/\(key)"
    try? fm.createDirectory(atPath: unlabeled, withIntermediateDirectories: true)
    writeData(unlabeled + "/original.png", [9, 9, 9])
    let backup = store.ensureBackup(for: source)
    check(backup != nil, "来历记录缺失时另找槽位重写，而不是返回一个认不出的备份")
    check(backup != unlabeled + "/original.png", "绝不复用没有来历记录的那份")
    check(readBytes(backup!) == [1, 2, 3], "新槽位里是真正原图，不是那张认不出的残骸")
    check(readBytes(unlabeled + "/original.png") == [9, 9, 9],
          "残骸留在原地交给清理流程，不悄悄改写别的东西")

    let metaFile = (backup! as NSString).deletingLastPathComponent
        + "/\(HistoryStore.metaFileName)"
    check(fm.fileExists(atPath: metaFile), "备份写成时来历记录必须一起落盘")
    // JSON 会把路径里的 / 转义成 \/，不还原回来永远比不中。
    let metaRaw = ((String(data: fm.contents(atPath: metaFile) ?? Data(), encoding: .utf8) ?? "")
        .replacingOccurrences(of: "\\/", with: "/"))
    check(metaRaw.contains("\"version\""), "来历记录带版本号：v1 与 v2 要能分开认")
    check(metaRaw.contains(source), "来历记录认得这份原图属于谁")
    check(readBytes(source) == [1, 2, 3], "用户的源文件不受影响")
}

// ─── 23. 恢复的提交顺序：历史写失败时备份必须留着 ────────────────────────────
print("[23] 恢复先写文件，历史失败就保留备份")
do {
    let root = freshRoot("23")
    let store = HistoryStore(root: root)
    let source = canonicalPath(NSTemporaryDirectory() + "octoshrink-check-23/n.png")
    makeFile(source, [1, 2, 3])
    let backup = store.ensureBackup(for: source)!
    let entry = HistoryEntry.record(
        source: source, result: result(file: source, size: 3), output: source,
        backup: backup, retentionDays: 3
    )
    store.add(entry)
    writeData(source, [9, 9, 9])   // 模拟已被压缩结果覆盖
    let recorded = store.list()[0]
    // 让 history.json 的落盘必然失败，但**读得到**：根目录设成只读。
    // 若把 history.json 本身做成目录，读也一起坏了，测的就是另一件事（见 [20]）。
    chmod(root, 0o555)

    let outcome = store.restoreOutcome(entry: recorded, force: true)
    chmod(root, 0o755)
    check(!outcome.success, "历史没落盘就不能报\"恢复成功\"")
    check(outcome.error?.contains("文件已恢复") == true,
          "说清文件已回到原图：\(outcome.error ?? "")")
    check(readBytes(source) == [1, 2, 3], "文件确实先回到了原图")
    check(fm.fileExists(atPath: backup), "备份留着，用户重试即可收敛")
}

// ─── 24. 同格式 replace 的输出就是源文件：恢复后绝不删它 ─────────────────────
print("[24] 删压缩输出前必须判同一性")
do {
    let root = freshRoot("24")
    let store = HistoryStore(root: root)
    let realDir = NSTemporaryDirectory() + "octoshrink-check-24"
    let source = canonicalPath(realDir + "/o.png")
    makeFile(source, [1, 2, 3])
    let backup = store.ensureBackup(for: source)!
    // 规范路径是 /var/…（resolvingSymlinksInPath 会去掉 /private 前缀），
    // 而 /private/var/… 是同一个文件的另一种写法 —— 字面不等，历史里的
    // outputPath 记录的恰恰是当时那个原始字符串。
    let alias = "/private" + source
    check(alias != source && canonicalPath(alias) == source,
          "构造出同文件不同字面的路径对")
    let entry = HistoryEntry.record(
        source: source, result: result(file: source, size: 3), output: alias,
        backup: backup, retentionDays: 3
    )
    store.add(entry)
    writeData(source, [9, 9, 9])
    let outcome = store.restoreOutcome(entry: store.list()[0], force: true)
    check(outcome.success, "恢复成功：\(outcome.error ?? "")")
    check(fm.fileExists(atPath: alias), "刚写回的原图没被当成压缩产物删掉")
    check(readBytes(source) == [1, 2, 3], "源文件内容确实是真正原图")
}

// ─── 25. 取消不解除暂停；被取消的任务在闸门之前就自己退出 ───────────────────
print("[25] 取消与暂停互不干扰")
do {
    let scheduler = CompressionScheduler(maxParallelism: 2)
    scheduler.beginBatch()
    scheduler.pause()
    let meter = PeakMeter()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        // 已取消：哪怕闸门关着，也不该在这儿等下去。
        let permit = scheduler.acquire(cancelled: { true })
        if permit != nil { meter.begin(); meter.end() }
        group.leave()
    }
    _ = group.wait(timeout: .now() + 2)
    check(meter.peak == 0, "取消的任务不占 CPU 名额")
    check(scheduler.isPaused, "取消不把暂停一起解除")

    // wakeWaiters：只唤醒等待者，闸门该关着还是关着。
    scheduler.wakeWaiters()
    check(scheduler.isPaused, "wakeWaiters 不解除暂停")
    let running = DispatchGroup()
    running.enter()
    DispatchQueue.global().async {
        scheduler.acquire(cancelled: { false })?.release()
        running.leave()
    }
    Thread.sleep(forTimeInterval: 0.1)
    check(running.wait(timeout: .now()) == .timedOut, "暂停中等待者仍被拦住")
    scheduler.resume()
    running.wait()
    check(!scheduler.isPaused, "resume 后闸门开")
    scheduler.endBatch()
    check(scheduler.state == "idle", "批次收尾回到 idle")
}

// ─── 26. 历史页每一行的按钮 = 这条记录此刻真能做到的事 ──────────────────────
print("[26] historyRowActions 与压缩完成行对齐")
do {
    let store = tempStore("26")
    let dir = NSTemporaryDirectory() + "octoshrink-check-26"
    let tail: [HistoryRowAction] = [.finder, .copyLog]

    // ① replace + 备份还在 → 有「恢复原图」，没有「删除这次压缩结果」
    let covered = canonicalPath(dir + "/a.png")
    makeFile(covered, [1, 2, 3])
    var replaceMode = result(file: covered, size: 3)
    replaceMode.outputMode = "replace"
    let replaceEntry = HistoryEntry.record(
        source: covered, result: replaceMode, output: covered,
        backup: store.ensureBackup(for: covered), retentionDays: 3)
    store.add(replaceEntry)
    check(historyRowActions(store.find(replaceEntry.id)!) == [.saveAs, .compare, .restore] + tail,
          "覆盖模式：另存为 + 对比 + 恢复原图，而不是删产物")

    // ② 后缀模式：原图从没被盖过，对等的反悔是删掉产物，而不是"恢复"
    let kept = canonicalPath(dir + "/b.png")
    let keptOut = ((kept as NSString).deletingPathExtension) + "_compressed.png"
    makeFile(kept, [7])
    makeFile(keptOut, [8, 8])
    var suffixMode = result(file: kept, size: 2)
    suffixMode.outputMode = "suffix"
    let suffixEntry = HistoryEntry.record(
        source: kept, result: suffixMode, output: keptOut,
        backup: nil, retentionDays: 3)
    store.add(suffixEntry)
    check(historyRowActions(store.find(suffixEntry.id)!) == [.saveAs, .compare, .deleteOutput] + tail,
          "后缀模式：给「删除这次压缩结果」，绝不给「恢复原图」")

    // ③ 用户自己把压缩产物删了：指向它的三个按钮一起收起
    try? fm.removeItem(atPath: keptOut)
    check(historyRowActions(store.find(suffixEntry.id)!) == tail,
          "压缩结果已不在了，这一行就不配再有反悔按钮")

    // ④ 备份被清掉：恢复不能继续挂在页面上骗人
    let orphan = canonicalPath(dir + "/c.png")
    makeFile(orphan, [4, 5, 6])
    var backupGone = result(file: orphan, size: 3)
    backupGone.outputMode = "replace"
    let goneEntry = HistoryEntry.record(
        source: orphan, result: backupGone, output: orphan,
        backup: store.ensureBackup(for: orphan), retentionDays: 3)
    store.add(goneEntry)
    check(historyRowActions(store.find(goneEntry.id)!).contains(.restore),
          "备份在时先给恢复")
    try? fm.removeItem(atPath: store.find(goneEntry.id)!.backupPath!)
    check(historyRowActions(store.find(goneEntry.id)!) == [.saveAs] + tail,
          "原图备份已清理 → 恢复和对比一起收起")

    // ⑤ 已恢复的记录：反悔已经用掉了，不再给第二次
    let undone = canonicalPath(dir + "/d.png")
    makeFile(undone, [9])
    var again = result(file: undone, size: 1)
    again.outputMode = "replace"
    let restoredEntry = HistoryEntry.record(
        source: undone, result: again, output: undone,
        backup: store.ensureBackup(for: undone), retentionDays: 3)
    store.add(restoredEntry)
    _ = try? store.restore(entry: store.find(restoredEntry.id)!, force: false)
    let doneActions = historyRowActions(store.find(restoredEntry.id)!)
    check(!doneActions.contains(.restore) && !doneActions.contains(.deleteOutput),
          "已恢复的行不再提供反悔按钮")

    // ⑥ history.json 损坏后按备份重建的条目：明细丢了，恢复仍然必须在
    let rebuiltSource = canonicalPath(dir + "/e.png")
    makeFile(rebuiltSource, [1])
    let rebuiltBackup = canonicalPath(dir + "/e-backup.png")
    makeFile(rebuiltBackup, [2])
    let rebuilt = HistoryEntry(
        id: "recovery-row", createdAt: OctoClock.nowMillis, expiresAt: OctoClock.nowMillis,
        sourcePath: rebuiltSource, outputPath: rebuiltSource,
        fileName: "e.png", outputMode: "replace",
        originalSize: 1, compressedSize: 1, savings: 0, outType: "png", algorithm: "",
        backupPath: rebuiltBackup, status: .recoveryAvailable,
        restoredAt: nil, outputModifiedAt: nil,
        sourceExists: true, backupExists: true, outputExists: true)
    check(historyRowActions(rebuilt) == [.saveAs, .compare, .restore] + tail,
          "重建条目照样给恢复按钮 —— 它存在的意义就是这个")
}

print(failures == 0
      ? "\n✓ Swift 历史 / 备份 / 暂停 / CPU 上限自检全部通过"
      : "\n✗ Swift 自检失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
