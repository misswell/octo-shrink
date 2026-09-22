import Foundation

// MARK: - 压缩调度器（暂停 + CPU 使用上限，同一套闸门）
//
// 两件事语义相同 —— 只决定「要不要再启动新任务」，绝不干预已经在跑的子进程：
// 暂停时正在压的那张继续跑完；上限从 8 调到 2 时已有的 8 个也允许跑完，
// 只是不再启动新的。反过来 2 → 8 立刻唤醒等待者。
//
// 不做 CPU affinity：数字只是「同时允许几份 CPU 并行压缩工作」。
final class CompressionScheduler: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    /// 是否有批次在跑，只影响 UI 显示的 state 文案。
    private var batchRunning = false
    private var maxParallelism: Int
    private var active = 0

    static let minParallelism = CPULimit.minParallelism

    init(maxParallelism: Int) {
        self.maxParallelism = max(Self.minParallelism, maxParallelism)
    }

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    /// idle / running / paused —— UI 的唯一真相来源。
    var state: String {
        condition.lock()
        defer { condition.unlock() }
        guard batchRunning else { return "idle" }
        return paused ? "paused" : "running"
    }

    var currentLimit: Int {
        condition.lock()
        defer { condition.unlock() }
        return max(Self.minParallelism, maxParallelism)
    }

    var activeJobs: Int {
        condition.lock()
        defer { condition.unlock() }
        return active
    }

    /// 是否有批次在跑 —— 清空历史这类破坏性操作的判据（与 Rust `is_batch_active` 一致）。
    var isBatchActive: Bool {
        condition.lock()
        defer { condition.unlock() }
        return batchRunning
    }

    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    /// 解除暂停并唤醒等待中的 worker。**只有用户点「继续」和批次收尾才走这里。**
    /// 取消一个文件时绝不调它 —— 那会把整批悄悄放行（用 `wakeWaiters()`）。
    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// 只把等待者叫醒，**不**解除暂停：让它们有机会看见"这个文件已经被取消了"。
    /// 取消 / 移除队列项走这一条，闸门保持关着，其余文件继续等待。
    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// 新一批永远从「未暂停」开始，不继承上一批的状态；同时按最新设置取上限。
    func beginBatch(maxParallelism limit: Int? = nil) {
        condition.lock()
        if let limit { maxParallelism = max(Self.minParallelism, limit) }
        paused = false
        batchRunning = true
        condition.broadcast()
        condition.unlock()
    }

    func endBatch() {
        condition.lock()
        paused = false
        batchRunning = false
        active = 0
        condition.broadcast()
        condition.unlock()
    }

    /// 运行中改上限：不抢回已在跑的名额，只影响之后的启动。
    func setMaxParallelism(_ limit: Int) {
        condition.lock()
        maxParallelism = max(Self.minParallelism, limit)
        condition.broadcast()
        condition.unlock()
    }

    /// 占一份 CPU 预算：暂停中或名额已满就等，拿到时闸门一定是开着的。
    ///
    /// 条件变量 + 250ms 超时兜底：即使漏掉一次唤醒，最坏情况只是延迟几百毫秒，
    /// 而不是永久卡住整个批次。
    func acquire() -> Permit {
        acquire(cancelled: { false })!
    }

    /// 带退出条件的等待：`cancelled()` 为真时**不拿名额**、直接返回 nil。
    ///
    /// 取消判定必须排在暂停 / 名额判定**之前**：暂停中被取消的文件如果继续等闸门，
    /// 就永远等不到自己"被取消"这件事生效。这是"闸门关着却没人开"的正解 ——
    /// 靠等待者自己退出，而不是靠取消操作偷偷开门。
    func acquire(cancelled: () -> Bool) -> Permit? {
        condition.lock()
        while true {
            if cancelled() {
                condition.unlock()
                return nil
            }
            if !paused && active < maxParallelism { break }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
        active += 1
        condition.unlock()
        return Permit(scheduler: self)
    }

    fileprivate func release() {
        condition.lock()
        active = max(0, active - 1)
        condition.broadcast()
        condition.unlock()
    }

    /// 一份 CPU 并行预算。忘记 release 也不会永久泄漏 —— deinit 兜底归还。
    final class Permit: @unchecked Sendable {
        private var scheduler: CompressionScheduler?

        init(scheduler: CompressionScheduler) {
            self.scheduler = scheduler
        }

        func release() {
            scheduler?.release()
            scheduler = nil
        }

        deinit { release() }
    }
}
