import Foundation

/// Run optional recognition off the caller's thread. A stalled system recognizer
/// must neither block image questions indefinitely nor accumulate background jobs.
final class BoundedTextRecognizer: @unchecked Sendable {
    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var text = ""
    }
    private let lock = NSLock()
    private var running = false
    func recognize(timeout: TimeInterval, work: @escaping @Sendable () -> String) -> String {
        lock.lock()
        guard !running else { lock.unlock(); return "" }
        running = true
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global(qos: .utility).async { [self] in
            let text = work()
            result.lock.lock(); result.text = text; result.lock.unlock()
            lock.lock(); running = false; lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + max(0, timeout)) == .success else { return "" }
        result.lock.lock(); defer { result.lock.unlock() }
        return result.text
    }
}
