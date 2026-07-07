import UIKit

/// LRU hot-cache for recently viewed remote sessions: re-entering renders
/// instantly from memory and re-subscribes INCREMENTALLY (haveByte) instead of
/// re-shipping a 1MB tail. Capped at 3 sessions; flushed on memory pressure.
@MainActor
final class ThreadCache {
    static let shared = ThreadCache()

    struct Entry {
        var rawLines: [String]
        var cachedRecords: [RawRecord]
        var decodedLineCount: Int
        var historyStart: UInt64
        var historyComplete: Bool
        var endByte: UInt64
        var contextTokens: Int?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let cap = 3

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.entries.removeAll(); self?.order.removeAll() }
        }
    }

    func get(_ id: String) -> Entry? { entries[id] }

    func put(_ id: String, _ e: Entry) {
        entries[id] = e
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > cap, let old = order.first {
            order.removeFirst(); entries.removeValue(forKey: old)
        }
    }
}
