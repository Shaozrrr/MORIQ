import AppKit
import Foundation

final class RecoveringVault: ClipboardBackingStore {
    let lock = NSLock()
    var unavailable = true
    var silentCalls = 0
    var stored: [ClipboardEntry]
    init(_ stored: [ClipboardEntry]) { self.stored = stored }
    func load() throws -> [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw NSError(domain: "test", code: 1) }
        return stored
    }
    func save(_ entries: [ClipboardEntry]) throws { lock.lock(); defer { lock.unlock() }; stored = entries }
    func loadSilently() throws -> [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        silentCalls += 1
        if unavailable { throw NSError(domain: "test", code: 1) }
        return stored
    }
    func silentCallCount() -> Int { lock.lock(); defer { lock.unlock() }; return silentCalls }
    func clear() throws { lock.lock(); defer { lock.unlock() }; stored = [] }
    func unlock() { lock.lock(); unavailable = false; lock.unlock() }
}
final class DelayedVault: ClipboardBackingStore {
    let entry: ClipboardEntry
    let began = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
    var attempts = 0
    init(_ entry: ClipboardEntry) { self.entry = entry }
    func load() throws -> [ClipboardEntry] {
        attempts += 1
        if attempts == 1 { throw NSError(domain: "test", code: 1) }
        began.signal(); proceed.wait(); return [entry]
    }
    func save(_ entries: [ClipboardEntry]) throws {}
    func clear() throws {}
}
@main struct Run {
 @MainActor static func main() async {
    func entry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), created: Date(), source: "fixture", items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]])
    }
    let favorite = entry("old favorite"), oldHistory = entry("old history")
    let vault = RecoveringVault([favorite, oldHistory])
    let suite = "local.moriq.recovery.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set([favorite.id.uuidString], forKey: "moriq.clipboard.favoriteIDs")
    let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.recovery.\(UUID().uuidString)"))
    defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
    let store = ClipboardStore(board: board, vault: vault, defaults: defaults)
    store.start(initialLoadSynchronously: true); precondition(store.persistenceLocked)
    board.clearContents(); board.setString("temporary history", forType: .string); store.poll(); store.waitForCaptures()
    store.recover()
    for _ in 0..<100 where store.recovering { try? await Task.sleep(for: .milliseconds(20)) }
    precondition(store.persistenceLocked && store.items.first?.text == "temporary history")
    precondition(vault.stored.map(\.id) == [favorite.id, oldHistory.id])
    store.clearHistory()
    board.clearContents(); board.setString("new history", forType: .string); store.poll(); store.waitForCaptures()
    vault.unlock(); store.recover()
    for _ in 0..<100 where store.recovering { try? await Task.sleep(for: .milliseconds(20)) }
    precondition(!store.persistenceLocked && store.items.map(\.text) == ["new history", "old favorite"])
    precondition(store.favorites.contains(favorite.id))
    store.stop(); store.flushPendingWrites()
    let reopened = ClipboardStore(board: board, vault: vault, defaults: defaults); reopened.start(initialLoadSynchronously: true)
    precondition(reopened.items.map(\.text) == ["new history", "old favorite"])
    reopened.stop(); reopened.flushPendingWrites()
    let removedFavorite = entry("remove duplicate")
    let duplicateVault = RecoveringVault([removedFavorite])
    defaults.set([removedFavorite.id.uuidString], forKey: "moriq.clipboard.favoriteIDs")
    let second = ClipboardStore(board: board, vault: duplicateVault, defaults: defaults)
    second.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("remove duplicate", forType: .string); second.poll(); second.waitForCaptures()
    second.remove(second.items[0])
    duplicateVault.unlock(); second.recover()
    for _ in 0..<100 where second.recovering { try? await Task.sleep(for: .milliseconds(20)) }
    precondition(second.items.isEmpty && !second.favorites.contains(removedFavorite.id))
    second.stop(); second.flushPendingWrites()
    let preserved = entry("same favorite")
    let mergeVault = RecoveringVault([preserved])
    defaults.set([preserved.id.uuidString], forKey: "moriq.clipboard.favoriteIDs")
    let third = ClipboardStore(board: board, vault: mergeVault, defaults: defaults)
    third.start(initialLoadSynchronously: true)
    board.clearContents(); board.setString("same favorite", forType: .string); third.poll(); third.waitForCaptures()
    third.toggleFavorite(third.items[0])
    mergeVault.unlock(); third.recover()
    for _ in 0..<100 where third.recovering { try? await Task.sleep(for: .milliseconds(20)) }
    precondition(third.items.count == 1 && third.items[0].id == preserved.id && third.favorites.contains(preserved.id))
    third.stop(); third.flushPendingWrites()
    let delayed = DelayedVault(entry("must not reappear"))
    defaults.removeObject(forKey: "moriq.clipboard.favoriteIDs")
    let fourth = ClipboardStore(board: board, vault: delayed, defaults: defaults)
    fourth.start(initialLoadSynchronously: true); fourth.recover()
    precondition(delayed.began.wait(timeout: .now() + 2) == .success)
    fourth.clear(); delayed.proceed.signal()
    for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }
    precondition(fourth.items.isEmpty && !fourth.recovering)
    fourth.stop(); fourth.flushPendingWrites()
    let automaticFavorite = entry("automatic favorite")
    let automaticVault = RecoveringVault([automaticFavorite])
    defaults.set([automaticFavorite.id.uuidString], forKey: "moriq.clipboard.favoriteIDs")
    let automatic = ClipboardStore(board: board, vault: automaticVault, defaults: defaults)
    automatic.start(initialLoadSynchronously: true); precondition(automatic.persistenceLocked)
    board.clearContents(); board.setString("copied while locked", forType: .string); automatic.poll(); automatic.waitForCaptures()
    automaticVault.unlock()
    for _ in 0..<400 where automatic.persistenceLocked { try? await Task.sleep(for: .milliseconds(20)) }
    precondition(!automatic.persistenceLocked && automaticVault.silentCallCount() > 0)
    precondition(automatic.items.map(\.text) == ["copied while locked", "automatic favorite"])
    precondition(automatic.favorites.contains(automaticFavorite.id))
    automatic.stop(); automatic.flushPendingWrites()
    print("PASS automatic silent recovery merges new history and saved favorite")
    print("PASS recovery merges current copies and preserves clear-history and favorites")
 }
}

