import Foundation

enum ScreenDisplaySelection {
    static func index(target: UInt32?, candidates: [UInt32]) -> Int? {
        guard let target else { return nil }
        return candidates.firstIndex(of: target)
    }
    static func shouldRestart(active: UInt32?, target: UInt32?) -> Bool {
        guard let active else { return false }
        return target != active
    }
}

/// Keeps a bounded history of recent screen samples without reusing stale frames.
struct ScreenFrameBuffer {
    private struct Sample { let data: Data; let capturedAt: Date; let displayID: UInt32? }
    private var samples: [Sample] = []
    private let capacity: Int
    private let maximumAge: TimeInterval
    private let maximumBytes: Int
    private(set) var byteCount = 0
    init(capacity: Int = 6, maximumAge: TimeInterval = 15, maximumBytes: Int = 12 * 1024 * 1024) {
        self.capacity = max(0, capacity)
        self.maximumAge = max(0, maximumAge)
        self.maximumBytes = max(0, maximumBytes)
    }
    var isEmpty: Bool { samples.isEmpty }
    mutating func removeAll() { samples.removeAll(); byteCount = 0 }
    mutating func prune(at now: Date) {
        samples.removeAll { sample in
            guard now.timeIntervalSince(sample.capturedAt) > maximumAge else { return false }
            byteCount -= sample.data.count; return true
        }
    }
    mutating func append(_ data: Data, capturedAt: Date, displayID: UInt32? = nil) {
        guard !data.isEmpty, capacity > 0, data.count <= maximumBytes else { return }
        prune(at: capturedAt)
        // Completion callbacks can arrive out of capture order. Keep history in
        // capture order so the newest suffix cannot accidentally contain an old
        // frame after a more recent one, or evict a newer frame at capacity.
        let sample = Sample(data: data, capturedAt: capturedAt, displayID: displayID)
        let insertion = samples.firstIndex { $0.capturedAt > capturedAt } ?? samples.endIndex
        samples.insert(sample, at: insertion)
        byteCount += data.count
        while samples.count > capacity || byteCount > maximumBytes {
            byteCount -= samples.removeFirst().data.count
        }
    }
    func recent(at now: Date, limit: Int, displayID: UInt32? = nil) -> [Data] {
        guard limit > 0 else { return [] }
        return Array(samples.filter { let age = now.timeIntervalSince($0.capturedAt); return age >= 0 && age <= maximumAge && (displayID == nil || $0.displayID == displayID) }.suffix(limit).map(\.data))
    }
}
