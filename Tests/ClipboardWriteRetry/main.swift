import Foundation
import AppKit

final class FlakyVault: ClipboardBackingStore {
    private let lock = NSLock()
    private var failures: Int
    private var saved: [ClipboardEntry] = []
    private var attempts = 0
    init(failures: Int) { self.failures = failures }
    func load() throws -> [ClipboardEntry] { lock.lock(); defer { lock.unlock() }; return saved }
    func save(_ entries: [ClipboardEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        if failures > 0 { failures -= 1; throw NSError(domain: "test", code: 1) }
        saved = entries
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; saved.removeAll() }
    func snapshot() -> (Int, [ClipboardEntry]) { lock.lock(); defer { lock.unlock() }; return (attempts, saved) }
}
final class BlockingFailureVault: ClipboardBackingStore {
    private let lock = NSLock()
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private var count = 0, saved: [ClipboardEntry] = []
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws {
        lock.lock(); count += 1; let first = count == 1; lock.unlock()
        if first { started.signal(); release.wait(); throw NSError(domain: "test", code: 2) }
        lock.lock(); saved = entries; lock.unlock()
    }
    func clear() throws { lock.lock(); saved.removeAll(); lock.unlock() }
    func latest() -> String? { lock.lock(); defer { lock.unlock() }; return saved.first?.text }
}

@main struct Run {
 @MainActor static func main() async {
    let suite = "local.moriq.clipboard-retry.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.clipboard-retry.\(UUID().uuidString)"))
    defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
    let vault = FlakyVault(failures: 2), store = ClipboardStore(board: board, vault: vault, defaults: defaults)
    store.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("first", forType: .string); store.poll(); store.waitForCaptures()
    for _ in 0..<100 where vault.snapshot().0 < 1 { try? await Task.sleep(for: .milliseconds(20)) }
    guard vault.snapshot().0 == 1 else { fatalError("first attempt missing") }
    board.clearContents(); board.setString("latest", forType: .string); store.poll(); store.waitForCaptures()
    for _ in 0..<200 where vault.snapshot().0 < 3 || !store.encryptedStorage { try? await Task.sleep(for: .milliseconds(20)) }
    let result = vault.snapshot()
    guard result.0 == 3, result.1.first?.text == "latest", store.encryptedStorage else { fatalError("retry did not persist latest state") }
    store.shutdown()
    print("PASS failed writes retry with backoff and retain the newest copy")

    let flushVault = FlakyVault(failures: 1), second = ClipboardStore(board: board, vault: flushVault, defaults: defaults)
    second.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("flush retry", forType: .string); second.poll(); second.waitForCaptures()
    second.flushPendingWrites()
    guard !second.encryptedStorage, flushVault.snapshot().0 == 1 else { fatalError("failed flush not reported") }
    for _ in 0..<150 where flushVault.snapshot().1.first?.text != "flush retry" { try? await Task.sleep(for: .milliseconds(20)) }
    guard flushVault.snapshot().1.first?.text == "flush retry" else { fatalError("failed flush was not retried") }
    second.shutdown()
    print("PASS failed forced flush remains queued for retry")

    let clearVault = FlakyVault(failures: 1), third = ClipboardStore(board: board, vault: clearVault, defaults: defaults)
    third.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("do not restore", forType: .string); third.poll(); third.waitForCaptures()
    for _ in 0..<100 where clearVault.snapshot().0 < 1 { try? await Task.sleep(for: .milliseconds(20)) }
    third.clear()
    try? await Task.sleep(for: .seconds(1))
    third.shutdown()
    guard clearVault.snapshot().1.isEmpty else { fatalError("cleared content returned after retry") }
    print("PASS clearing cancels retry of older contents")

    let blockedVault = BlockingFailureVault(), fourth = ClipboardStore(board: board, vault: blockedVault, defaults: defaults)
    fourth.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("in flight retry", forType: .string); fourth.poll(); fourth.waitForCaptures()
    try? await Task.sleep(for: .milliseconds(350))
    guard blockedVault.started.wait(timeout: .now() + 1) == .success else { fatalError("blocked write missing") }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { blockedVault.release.signal() }
    fourth.flushPendingWrites()
    guard !fourth.encryptedStorage else { fatalError("failed in-flight flush not reported") }
    for _ in 0..<150 where blockedVault.latest() != "in flight retry" { try? await Task.sleep(for: .milliseconds(20)) }
    guard blockedVault.latest() == "in flight retry" else { fatalError("in-flight failure lost retry snapshot") }
    fourth.shutdown()
    print("PASS in-flight failure during flush retries without a new copy")
 }
}

