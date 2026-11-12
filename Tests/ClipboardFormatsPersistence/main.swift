import AppKit
import CryptoKit
import Foundation
import ImageIO
final class FixtureVault: ClipboardBackingStore {
 let url: URL; let key = SymmetricKey(size: .bits256)
 init(_ url: URL) { self.url = url }
 func load() throws -> [ClipboardEntry] {
  guard FileManager.default.fileExists(atPath: url.path) else { return [] }
  return try JSONDecoder().decode([ClipboardEntry].self, from: ClipboardCipher.open(Data(contentsOf: url), using: key))
 }
 func save(_ entries: [ClipboardEntry]) throws { try ClipboardCipher.seal(JSONEncoder().encode(entries), using: key).write(to: url, options: .atomic) }
 func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-clipboard-formats-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let suite = "local.moriq.formats-persistence.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let board = NSPasteboard(name: NSPasteboard.Name(suite))
defer { board.releaseGlobally() }
let vault = FixtureVault(root.appendingPathComponent("history.enc"))
let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
let jpeg = NSMutableData(); let writer = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(writer, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(writer))
let pdf = NSMutableData(); let consumer = CGDataConsumer(data: pdf)!; var rect = CGRect(x: 0, y: 0, width: 20, height: 20)
let pdfContext = CGContext(consumer: consumer, mediaBox: &rect, nil)!
pdfContext.beginPDFPage(nil); pdfContext.fill(rect); pdfContext.endPDFPage(); pdfContext.closePDF()
MainActor.assumeIsolated {
 let store = ClipboardStore(board: board, vault: vault, defaults: defaults); store.start(initialLoadSynchronously: true)
 for (name, data) in [("public.jpeg", jpeg as Data), ("com.adobe.pdf", pdf as Data)] {
  let type = NSPasteboard.PasteboardType(name); let item = NSPasteboardItem(); item.setData(data, forType: type)
  board.clearContents(); precondition(board.writeObjects([item])); store.poll(); store.waitForCaptures()
  store.toggleFavorite(store.items[0])
 }
 store.shutdown()
 let sealed = try! Data(contentsOf: vault.url)
 precondition(!sealed.contains(jpeg as Data) && !sealed.contains(pdf as Data))
 let reopened = ClipboardStore(board: board, vault: vault, defaults: defaults); reopened.start(initialLoadSynchronously: true)
 precondition(reopened.items.count == 2 && reopened.items.allSatisfy { reopened.favorites.contains($0.id) })
 for (name, original) in [("public.jpeg", jpeg as Data), ("com.adobe.pdf", pdf as Data)] {
  let entry = reopened.items.first { $0.items.first?[name] != nil }!
  reopened.copy(entry)
  precondition(board.data(forType: NSPasteboard.PasteboardType(name)) == original)
 }
 reopened.clearHistory(); reopened.shutdown()
 let final = ClipboardStore(board: board, vault: vault, defaults: defaults); final.start(initialLoadSynchronously: true)
 precondition(final.items.count == 2 && final.items.allSatisfy { final.favorites.contains($0.id) })
 final.shutdown()
 print("PASS JPEG and PDF favorites survive encrypted restart and copy exactly")
}

