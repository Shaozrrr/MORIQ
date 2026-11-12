import AppKit
import Foundation

final class SlowStartupVault: ClipboardBackingStore {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var saved: [ClipboardEntry]
    init(_ saved: [ClipboardEntry]) { self.saved = saved }
    func load() throws -> [ClipboardEntry] {
        entered.signal(); release.wait()
        lock.lock(); defer { lock.unlock() }; return saved
    }
    func save(_ entries: [ClipboardEntry]) throws { lock.lock(); defer { lock.unlock() }; saved = entries }
    func clear() throws { lock.lock(); defer { lock.unlock() }; saved = [] }
}
@main struct Run {
    @MainActor static func main() async {
        func entry(_ value: String) -> ClipboardEntry {
            ClipboardEntry(id: UUID(), created: Date(), source: "test", items: [[NSPasteboard.PasteboardType.string.rawValue: Data(value.utf8)]])
        }
        let favorite = entry("old favorite"), history = entry("old history")
        let suite = "local.moriq.test.startup.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.test.startup.\(UUID())"))
        defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
        defaults.set([favorite.id.uuidString], forKey: "moriq.clipboard.favoriteIDs")
        let vault = SlowStartupVault([favorite, history]), store = ClipboardStore(board: board, vault: vault, defaults: defaults)
        let start = Date(); store.start()
        precondition(Date().timeIntervalSince(start) < 0.5 && store.recovering)
        precondition(vault.entered.wait(timeout: .now() + 2) == .success)
        board.clearContents(); board.setString("new copy", forType: .string); store.poll(); store.waitForCaptures()
        store.clearHistory()
        board.clearContents(); board.setString("newest copy", forType: .string); store.poll(); store.waitForCaptures()
        vault.release.signal()
        for _ in 0..<200 where store.recovering { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(!store.recovering && !store.persistenceLocked)
        precondition(store.items.map(\.text) == ["newest copy", "old favorite"])
        precondition(store.favorites.contains(favorite.id))
        store.shutdown()
        print("PASS slow startup returns immediately and merges changes while preserving favorites")

        let delayed = SlowStartupVault([history]), second = ClipboardStore(board: board, vault: delayed, defaults: defaults)
        second.start(); precondition(delayed.entered.wait(timeout: .now() + 2) == .success)
        second.clear(); delayed.release.signal()
        for _ in 0..<200 where second.persistenceLocked { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(second.items.isEmpty && !second.recovering)
        second.shutdown()
        print("PASS clear during startup cannot resurrect an earlier snapshot")

        let shutdownVault = SlowStartupVault([history]), third = ClipboardStore(board: board, vault: shutdownVault, defaults: defaults)
        third.start(); precondition(shutdownVault.entered.wait(timeout: .now() + 2) == .success)
        board.clearContents(); board.setString("before quit", forType: .string); third.poll(); third.waitForCaptures()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { shutdownVault.release.signal() }
        third.shutdown()
        precondition(shutdownVault.saved.map(\.text) == ["before quit", "old history"])
        try? await Task.sleep(for: .milliseconds(50))
        precondition(third.items.map(\.text) == ["before quit", "old history"])
        print("PASS shutdown waits for startup merge and persists newest copy exactly once")
    }
}
