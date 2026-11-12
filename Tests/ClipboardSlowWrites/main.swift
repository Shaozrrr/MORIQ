import Foundation
import AppKit

final class BlockingVault: ClipboardBackingStore {
    private let lock = NSLock()
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private var saves: [[ClipboardEntry]] = []
    private var hasBlocked = false
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws {
        lock.lock(); saves.append(entries); let first = !hasBlocked; hasBlocked = true; lock.unlock()
        if first { firstStarted.signal(); releaseFirst.wait() }
    }
    func clear() throws { lock.lock(); saves.removeAll(); lock.unlock() }
    func snapshot() -> [[ClipboardEntry]] { lock.lock(); defer { lock.unlock() }; return saves }
}

@main struct Run {
 @MainActor static func main() async {
    let suite = "local.moriq.clipboard-slow.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.clipboard-slow.\(UUID().uuidString)"))
    defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
    let vault = BlockingVault(), store = ClipboardStore(board: board, vault: vault, defaults: defaults)
    store.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("first", forType: .string); store.poll(); store.waitForCaptures()
    try? await Task.sleep(for: .milliseconds(350))
    guard vault.firstStarted.wait(timeout: .now() + 1) == .success else { fatalError("first write did not start") }
    for index in 0..<30 {
        board.clearContents(); board.setString("next \(index)", forType: .string); store.poll(); store.waitForCaptures()
        try? await Task.sleep(for: .milliseconds(20))
    }
    guard vault.snapshot().count == 1 else { fatalError("writes overlapped") }
    vault.releaseFirst.signal()
    for _ in 0..<100 where vault.snapshot().count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
    store.shutdown()
    let saves = vault.snapshot()
    guard saves.count == 2, saves.last?.first?.text == "next 29" else { fatalError("intermediate snapshots accumulated or last copy lost: \(saves.count)") }
    print("PASS slow clipboard writes keep one pending latest snapshot")
    let secondVault = BlockingVault(), second = ClipboardStore(board: board, vault: secondVault, defaults: defaults)
    second.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("discard this", forType: .string); second.poll(); second.waitForCaptures()
    try? await Task.sleep(for: .milliseconds(350))
    guard secondVault.firstStarted.wait(timeout: .now() + 1) == .success else { fatalError("second first write did not start") }
    second.clear()
    board.clearContents(); board.setString("keep this", forType: .string); second.poll(); second.waitForCaptures()
    try? await Task.sleep(for: .milliseconds(300))
    secondVault.releaseFirst.signal()
    try? await Task.sleep(for: .milliseconds(300))
    second.shutdown()
    let afterClear = secondVault.snapshot()
    guard !afterClear.isEmpty, afterClear.allSatisfy({ $0.map(\.text) == ["keep this"] }) else { fatalError("old data reappeared after clear") }
    print("PASS clear while a write is blocked keeps only new content")
    let thirdVault = BlockingVault(), third = ClipboardStore(board: board, vault: thirdVault, defaults: defaults)
    third.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("first write", forType: .string); third.poll(); third.waitForCaptures()
    try? await Task.sleep(for: .milliseconds(350))
    guard thirdVault.firstStarted.wait(timeout: .now() + 1) == .success else { fatalError("third first write did not start") }
    board.clearContents(); board.setString("final write", forType: .string); third.poll(); third.waitForCaptures()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { thirdVault.releaseFirst.signal() }
    third.shutdown()
    let stopped = thirdVault.snapshot()
    guard stopped.count == 2, stopped.last?.first?.text == "final write" else { fatalError("shutdown lost pending latest copy") }
    print("PASS shutdown waits for the latest snapshot during a slow write")
 }
}

