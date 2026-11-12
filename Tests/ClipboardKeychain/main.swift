import AppKit
import Foundation
import Security
let args = CommandLine.arguments
if args.count == 5 {
 let phase = args[1], service = args[2], root = URL(fileURLWithPath: args[3]), suite = args[4]
 let defaults = UserDefaults(suiteName: suite)!
 let vault = ClipboardVault(testService: service, directory: root)
 let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.test.keychain.\(UUID().uuidString)"))
 MainActor.assumeIsolated {
  let store = ClipboardStore(board: board, vault: vault, defaults: defaults); store.start(initialLoadSynchronously: true)
  if phase == "write" {
   for n in 0..<3 { board.clearContents(); board.setString("synthetic note \(n)", forType: .string); store.poll(); store.waitForCaptures() }
   store.toggleFavorite(store.items[0]); store.stop(); store.flushPendingWrites(); defaults.synchronize()
   guard (try? vault.load().count) == 3 else { print("FAIL isolated keychain save"); exit(1) }
   print("PASS isolated keychain write")
  } else {
   guard store.items.count == 3, store.items.first?.text == "synthetic note 2", let id = store.items.first?.id, store.favorites.contains(id) else { print("FAIL isolated keychain reopen"); exit(1) }
   store.clearHistory(); store.stop(); store.flushPendingWrites(); defaults.synchronize()
   guard (try? vault.load().count) == 1 else { print("FAIL isolated favorite retention"); exit(1) }
   print("PASS new process restored history and favorite")
  }
 }
} else {
 let fm = FileManager.default
 let root = fm.temporaryDirectory.appendingPathComponent("moriq-keychain-test-\(UUID().uuidString)")
 try fm.createDirectory(at: root, withIntermediateDirectories: true)
 let service = "local.moriq.test.clipboard.\(UUID().uuidString)", suite = service
 defer {
  let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "history"]
  SecItemDelete(query as CFDictionary)
  let raceQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".race", kSecAttrAccount as String: "history"]
  SecItemDelete(raceQuery as CFDictionary)
  let missingQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".missing", kSecAttrAccount as String: "history"]
  SecItemDelete(missingQuery as CFDictionary)
  UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  try? fm.removeItem(at: root)
 }
 for phase in ["write", "read"] {
  let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  p.arguments = [phase, service, root.path, suite]
  try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw NSError(domain: "MORIQClipboardTest", code: Int(p.terminationStatus)) }
 }
 let encrypted = try Data(contentsOf: root.appendingPathComponent("clipboard-history.enc"))
 precondition(!String(decoding: encrypted, as: UTF8.self).contains("synthetic note"))
 let lock = NSLock(); var errors = 0
 DispatchQueue.concurrentPerform(iterations: 8) { n in
  do {
   let vault = ClipboardVault(testService: service + ".race", directory: root.appendingPathComponent("race-\(n)"))
   let entry = ClipboardEntry(id: UUID(), created: Date(), source: "test", items: [[NSPasteboard.PasteboardType.string.rawValue: Data("race \(n)".utf8)]])
   try vault.save([entry]); guard try vault.load().first?.id == entry.id else { throw NSError(domain: "MORIQRace", code: 1) }
  } catch { lock.lock(); errors += 1; lock.unlock() }
 }
 precondition(errors == 0, "concurrent isolated key creation failed")
 print("PASS real Keychain key across processes and concurrent creation")
 let missingService = service + ".missing"
 let missingVault = ClipboardVault(testService: missingService, directory: root.appendingPathComponent("missing"))
 let sample = ClipboardEntry(id: UUID(), created: Date(), source: "test", items: [[NSPasteboard.PasteboardType.string.rawValue: Data("saved".utf8)]])
 try missingVault.save([sample])
 guard try missingVault.loadSilently().first?.id == sample.id else { fatalError("silent keychain load failed") }
 let archived = try Data(contentsOf: root.appendingPathComponent("missing/clipboard-history.enc"))
 let missingQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: missingService, kSecAttrAccount as String: "history"]
 guard SecItemDelete(missingQuery as CFDictionary) == errSecSuccess else { fatalError("could not remove isolated key") }
 do { _ = try missingVault.load(); fatalError("missing key accepted") } catch { }
 guard SecItemCopyMatching(missingQuery as CFDictionary, nil) == errSecItemNotFound else { fatalError("loading recreated a missing key") }
 let afterFailedLoad = try Data(contentsOf: root.appendingPathComponent("missing/clipboard-history.enc"))
 precondition(afterFailedLoad == archived)
 print("PASS missing key does not get silently replaced during load")
}

