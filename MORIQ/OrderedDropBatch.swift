import Foundation

/// Collect asynchronous item-provider results in their original drag order.
final class OrderedDropBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<Int>
    private var values: [URL?]
    private var completed = false
    private let completion: @Sendable ([URL], Int) -> Void

    init(count: Int, timeout: TimeInterval = 20, completion: @escaping @Sendable ([URL], Int) -> Void) {
        let size = max(0, count)
        self.pending = Set(0..<size); self.values = Array(repeating: nil, count: size); self.completion = completion
        if size == 0 { completed = true; completion([], 0) }
        else { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { [self] in finish() } }
    }
    func submit(_ url: URL?, at index: Int) {
        lock.lock()
        guard !completed, pending.remove(index) != nil else { lock.unlock(); return }
        values[index] = url
        let ready = pending.isEmpty
        lock.unlock()
        if ready { finish() }
    }
    private func finish() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let urls = values.compactMap { $0 }
        let failed = values.count - urls.count
        lock.unlock()
        completion(urls, failed)
    }
}
