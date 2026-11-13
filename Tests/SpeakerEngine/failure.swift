import Foundation
final class Counter: @unchecked Sendable {
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    var count = 0
    func record() { lock.lock(); count += 1; lock.unlock(); done.signal() }
}
@main struct Main {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("fake helper path required") }
        let counter = Counter()
        let bridge = try SpeakerDiarizationBridge(helper: URL(fileURLWithPath: CommandLine.arguments[1]), model: URL(fileURLWithPath: "/unused"), onTurns: { _ in fatalError("unexpected speaker") }, onFailure: { counter.record() })
        precondition(!bridge.append(Data(repeating: 0, count: 512_004)))
        precondition(counter.done.wait(timeout: .now() + 5) == .success)
        precondition(!bridge.append(Data(repeating: 0, count: 6400)))
        bridge.stop(); usleep(200_000)
        counter.lock.lock(); let count = counter.count; counter.lock.unlock()
        precondition(count == 1)
        print("PASS overflow fails once and rejects later samples")
    }
}
