import Foundation

/// A compact snapshot of one queue row for a compression session.
/// Queue rows can move when a removed item is re-added, so workers validate both
/// the stable row id and its path before publishing a result.
struct CompressionWorkItem: Sendable {
    let id: UUID
    let path: String
}

/// Thread-safe pull queue shared by a bounded number of compression workers.
/// It stores one target per file, but creates no per-file Dispatch closure or
/// blocked scheduler waiter.
final class CompressionWorklist: @unchecked Sendable {
    private let lock = NSLock()
    private let items: [CompressionWorkItem]
    private var cursor = 0

    init(_ items: [CompressionWorkItem]) {
        self.items = items
    }

    func takeNext() -> CompressionWorkItem? {
        lock.lock()
        defer { lock.unlock() }
        guard cursor < items.count else { return nil }
        let item = items[cursor]
        cursor += 1
        return item
    }

    var count: Int { items.count }
}
