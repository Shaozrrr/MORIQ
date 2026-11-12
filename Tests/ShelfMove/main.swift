import Foundation
import AppKit

let suite = "local.moriq.shelf-move-test.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent("moriq-shelf-move-\(UUID().uuidString)")
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
let first = directory.appendingPathComponent("first.txt")
let moved = directory.appendingPathComponent("renamed.txt")
let missing = directory.appendingPathComponent("missing.txt")
let extra = directory.appendingPathComponent("extra.txt")
for url in [first, missing, extra] { try Data("fixture".utf8).write(to: url) }

Task { @MainActor in
    defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: directory) }
    let store = ShelfStore(defaults: defaults)
    store.add([first, missing])
    let id = store.items[0].id
    let before = defaults.array(forKey: "moriq.shelf.bookmarks") as! [[String: Any]]
    guard let oldBookmark = before[1]["bookmark"] as? Data else { fatalError("missing initial bookmark") }
    try! fm.moveItem(at: first, to: moved)
    try! fm.removeItem(at: missing)
    await store.refreshMovedFiles()
    guard store.items.count == 2, store.items[0].id == id, store.items[0].url == moved, store.items[1].url == missing else { fatalError("move refresh failed") }
    store.add([extra])
    let after = defaults.array(forKey: "moriq.shelf.bookmarks") as! [[String: Any]]
    guard after[1]["bookmark"] as? Data == oldBookmark else { fatalError("missing bookmark was discarded") }
    let restored = ShelfStore(defaults: defaults)
    guard restored.items.count == 3, restored.items[0].url == moved, restored.items[1].url == missing else { fatalError("restart lost references") }
    let movedAgain = directory.appendingPathComponent("moved-again.txt")
    try! fm.moveItem(at: moved, to: movedAgain)
    let refresh = Task { await store.refreshMovedFiles() }
    await Task.yield()
    store.remove(id)
    await refresh.value
    guard store.items.count == 2, !store.items.contains(where: { $0.id == id }), store.items.map(\.url) == [missing, extra] else { fatalError("refresh resurrected or reordered a removed item") }
    let afterConcurrentChange = ShelfStore(defaults: defaults)
    guard afterConcurrentChange.items.map(\.url) == [missing, extra] else { fatalError("refresh corrupted persisted records") }
    print("PASS shelf refreshes renamed files while preserving selection identity and missing bookmarks")
    print("PASS refresh cannot resurrect a removed item or corrupt later records")
    exit(0)
}
RunLoop.main.run()
