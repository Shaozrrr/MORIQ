import AppKit
import CryptoKit
import Foundation
final class TestVault: ClipboardBackingStore {
 let url: URL; let key = SymmetricKey(size: .bits256)
 init(url: URL) { self.url = url }
 func load() throws -> [ClipboardEntry] {
  guard FileManager.default.fileExists(atPath: url.path) else { return [] }
  return try JSONDecoder().decode([ClipboardEntry].self, from: ClipboardCipher.open(Data(contentsOf: url), using: key))
 }
 func save(_ entries: [ClipboardEntry]) throws {
  Thread.sleep(forTimeInterval: 0.03)
  try ClipboardCipher.seal(JSONEncoder().encode(entries), using: key).write(to: url, options: .atomic)
 }
 func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-clipboard-persistence-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let suite = "local.moriq.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let vault = TestVault(url: root.appendingPathComponent("history.enc"))
let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.persistence.\(UUID().uuidString)"))
MainActor.assumeIsolated {
 let first = ClipboardStore(board: board, vault: vault, defaults: defaults); first.start(initialLoadSynchronously: true)
 for n in 0..<5 { board.clearContents(); board.setString("persistent sample \(n)", forType: .string); first.poll(); first.waitForCaptures() }
 let favorite = first.items[0]; first.toggleFavorite(favorite)
 board.clearContents(); board.setString("copied just before exit", forType: .string)
 var finished: Bool?
 first.prepareShutdown { finished = $0 }
 let deadline = Date().addingTimeInterval(5)
 while finished == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
 precondition(finished == true, "formal shutdown should preserve final clipboard content")
 let bytes = try! Data(contentsOf: vault.url); precondition(!String(decoding: bytes, as: UTF8.self).contains("persistent sample"))
 let reopened = ClipboardStore(board: board, vault: vault, defaults: defaults); reopened.start(initialLoadSynchronously: true)
 precondition(reopened.items.count == 6 && reopened.items[0].text == "copied just before exit")
 precondition(reopened.favorites.contains(favorite.id))
 reopened.clearHistory(); reopened.stop(); reopened.flushPendingWrites()
 let final = ClipboardStore(board: board, vault: vault, defaults: defaults); final.start(initialLoadSynchronously: true)
 precondition(final.items.count == 1 && final.items[0].id == favorite.id && final.favorites.contains(favorite.id))
 final.stop(); final.flushPendingWrites()
 print("PASS queued encrypted history, favorite and clear survive reopen")
}

