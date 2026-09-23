import Foundation

// MARK: - 批次阶段
//
// idle / running / paused / stopping —— 与 Tauri 线的 `CompressionState` 逐字一致，
// UI 只认这四个值，不再从"批次还没结束"猜当前是什么状态（暂停和压缩中在界面上
// 长得一模一样，正是"点了暂停却看不出暂停了"的根源）。
enum CompressionPhase: String {
    case idle
    case running
    case paused
    /// 用户点了停止：闸门对"还没开始"的文件**永久**关闭，已经在跑的跑完。
    case stopping
}

// MARK: - 压缩调度器（暂停 / 停止 + CPU 使用上限，同一套闸门）
//
// 三件事语义相同 —— 只决定「要不要再启动新任务」，绝不干预已经在跑的子进程：
// 暂停或停止时正在压的那张继续跑完；上限从 8 调到 2 时已有的 8 个也允许跑完，
// 只是不再启动新的。反过来 2 → 8 立刻唤醒等待者。
//
// 不做 CPU affinity：数字只是「同时允许几份 CPU 并行压缩工作」。
final class CompressionScheduler: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    /// 批次级的「停止」。与文件级的 cancelBox 是两件事：停止不需要逐条记账，
    /// 闸门本身对后来者永久关闭。
    private var stopping = false
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

    var isStopping: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopping
    }

    /// idle / running / paused / stopping —— UI 的唯一真相来源。
    var phase: CompressionPhase {
        condition.lock()
        defer { condition.unlock() }
        guard batchRunning else { return .idle }
        // 停止盖过暂停：暂停中点停止，状态就该是"正在停止"。
        if stopping { return .stopping }
        return paused ? .paused : .running
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
    /// 用户点了停止但批次还在收尾时它仍然为真：备份还在被认领，历史就不许被清。
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

    /// 停止整批：闸门对"还没开始"的文件永久关闭，已经在跑的跑完各自收尾。
    ///
    /// 绝不 kill 正在跑的进程：那会留下写了一半的临时文件、悬空的覆盖事务和
    /// 对不上账的历史 —— 正是「宁可慢一点也不能弄丢原图」要避免的。
    func stop() {
        condition.lock()
        stopping = true
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

    /// 新一批永远从「未暂停、未停止」开始，不继承上一批的状态；同时按最新设置取上限。
    func beginBatch(maxParallelism limit: Int? = nil) {
        condition.lock()
        if let limit { maxParallelism = max(Self.minParallelism, limit) }
        paused = false
        stopping = false
        batchRunning = true
        condition.broadcast()
        condition.unlock()
    }

    func endBatch() {
        condition.lock()
        paused = false
        stopping = false
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

    /// 带退出条件的等待：`cancelled()` 为真、或整批已「停止」时**不拿名额**、返回 nil。
    ///
    /// 判断顺序不能改，与 Rust 的 `acquire_or_cancelled` 一致：
    /// 取消 → 停止 → 暂停/名额。取消排最前，是为了让"暂停中被取消的文件"能立刻退出；
    /// 停止排在暂停之前，是为了让"暂停中按停止"能真的结束整批，而不是继续堵在
    /// 关着的闸门上等用户点「继续」（那正是「停止」的反面）。
    func acquire(cancelled: () -> Bool) -> Permit? {
        condition.lock()
        while true {
            if cancelled() {
                condition.unlock()
                return nil
            }
            if stopping {
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
