import Foundation
import AppKit
let suite = "local.moriq.shelf-test.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-shelf-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
let first = directory.appendingPathComponent("one.txt")
let second = directory.appendingPathComponent("two.txt")
try Data("original".utf8).write(to: first)
try Data("second".utf8).write(to: second)
MainActor.assumeIsolated {
    let store = ShelfStore(defaults: defaults)
    store.add([first, first, second])
    precondition(store.items.count == 2)
    let restored = ShelfStore(defaults: defaults)
    precondition(restored.items.count == 2 && restored.items.allSatisfy(\.available))
    restored.remove(restored.items[0].id)
    precondition(restored.items.count == 1)
    precondition(FileManager.default.fileExists(atPath: first.path))
    try! FileManager.default.removeItem(at: second)
    precondition(!restored.items[0].available)
    let missingAfterRestart = ShelfStore(defaults: defaults)
    precondition(missingAfterRestart.items.count == 1 && !missingAfterRestart.items[0].available)
    let many = (0..<125).map { directory.appendingPathComponent("bulk-\($0).txt") }
    for url in many { try! Data("fixture".utf8).write(to: url) }
    missingAfterRestart.add(many)
    precondition(missingAfterRestart.items.count == 126)
    let restoredMany = ShelfStore(defaults: defaults)
    precondition(restoredMany.items.count == 126 && restoredMany.items.first?.url == second)
    print("PASS: shelf deduplicates, restores, removes references only, and marks missing files")
}
