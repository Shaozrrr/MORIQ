import Foundation
import AppKit

final class CountingVault: ClipboardBackingStore {
    private let lock = NSLock()
    private var entries: [ClipboardEntry] = []
    private var saves = 0
    func load() throws -> [ClipboardEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    func save(_ newEntries: [ClipboardEntry]) throws {
        lock.lock(); defer { lock.unlock() }; saves += 1; entries = newEntries
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; entries.removeAll() }
    func snapshot() -> (Int, [ClipboardEntry]) { lock.lock(); defer { lock.unlock() }; return (saves, entries) }
}

let suite = "local.moriq.clipboard-coalescing.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.clipboard-coalescing.\(UUID().uuidString)"))
let vault = CountingVault()
defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
MainActor.assumeIsolated {
    let store = ClipboardStore(board: board, vault: vault, defaults: defaults)
    store.start(initialLoadSynchronously: true)
    for index in 0..<30 {
        board.clearContents(); board.setString("fixture \(index)", forType: .string); store.poll(); store.waitForCaptures()
    }
    store.flushPendingWrites()
    let first = vault.snapshot()
    precondition(first.0 == 1 && first.1.count == 30 && first.1.first?.text == "fixture 29")
    board.clearContents(); board.setString("before clear", forType: .string); store.poll(); store.waitForCaptures()
    store.clear()
    board.clearContents(); board.setString("after clear", forType: .string); store.poll(); store.waitForCaptures()
    store.shutdown()
    let last = vault.snapshot()
    precondition(last.1.count == 1 && last.1.first?.text == "after clear")
    print("PASS rapid clipboard writes coalesce; clear and shutdown preserve newest state")
}

