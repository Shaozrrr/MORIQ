import AppKit
import CryptoKit
import Foundation
final class FixtureVault: ClipboardBackingStore {
    let url: URL; let key = SymmetricKey(data: Data(repeating: 0x41, count: 32))
    init(_ url: URL) { self.url = url }
    func load() throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ClipboardEntry].self, from: ClipboardCipher.open(Data(contentsOf: url), using: key))
    }
    func save(_ entries: [ClipboardEntry]) throws { try ClipboardCipher.seal(JSONEncoder().encode(entries), using: key).write(to: url, options: .atomic) }
    func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
let args = CommandLine.arguments
let name = args.count > 2 ? args[2] : "local.moriq.cross-app.\(UUID().uuidString)"
let board = NSPasteboard(name: NSPasteboard.Name(name))
let fixtureText = "模拟富文本 ✓"
if args.count > 1 {
    precondition(Bundle.main.bundleIdentifier == "local.moriq.cross-app." + args[1])
    if args[1] == "write" {
        let rich = NSAttributedString(string: fixtureText, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 { for x in 0..<3 { pixels.setColor(NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.9, alpha: 1), atX: x, y: y) } }
        let tiff = pixels.representation(using: .tiff, properties: [:])!
        let item = NSPasteboardItem(); item.setString(fixtureText, forType: .string); item.setData(rtf, forType: .rtf); item.setData(tiff, forType: .tiff)
        board.clearContents(); precondition(board.writeObjects([item]))
    } else {
        guard let data = board.data(forType: .rtf), let image = NSImage(pasteboard: board), image.size.width > 0 else { fatalError("receiver could not read RTF or image") }
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        precondition(text.string == fixtureText)
        precondition((text.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue)
        let imageData = board.data(forType: .tiff)!, decoded = NSBitmapImageRep(data: imageData)!
        precondition(decoded.pixelsWide == 3 && decoded.pixelsHigh == 2)
        let color = decoded.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        precondition(color.blueComponent > 0.8 && color.redComponent < 0.3)
        print("PASS separate AppKit receiver reads formatted RTF and image")
    }
} else {
    defer { board.releaseGlobally() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-cross-app-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
    let suite = "local.moriq.cross-app.defaults.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let vault = FixtureVault(root.appendingPathComponent("history.enc"))
    func child(_ phase: String) {
        let bundle = root.appendingPathComponent(phase + ".app"), contents = bundle.appendingPathComponent("Contents"), macos = contents.appendingPathComponent("MacOS")
        try! FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let binary = macos.appendingPathComponent("fixture")
        try! FileManager.default.copyItem(at: URL(fileURLWithPath: args[0]), to: binary)
        let plist: [String: Any] = ["CFBundleIdentifier": "local.moriq.cross-app." + phase, "CFBundleExecutable": "fixture", "CFBundleName": phase, "CFBundlePackageType": "APPL"]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try! data.write(to: contents.appendingPathComponent("Info.plist"))
        let process = Process(); process.executableURL = binary; process.arguments = [phase, name]
        try! process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
    }
    MainActor.assumeIsolated {
        let store = ClipboardStore(board: board, vault: vault, defaults: defaults); store.start(initialLoadSynchronously: true)
        child("write"); store.poll(); store.waitForCaptures()
        let entry = store.items.first!; let rtf = entry.items[0][NSPasteboard.PasteboardType.rtf.rawValue]!, tiff = entry.items[0][NSPasteboard.PasteboardType.tiff.rawValue]!
        store.toggleFavorite(entry); store.shutdown()
        let sealed = try! Data(contentsOf: vault.url); precondition(!sealed.contains(Data(fixtureText.utf8)))
        let reopened = ClipboardStore(board: board, vault: vault, defaults: defaults); reopened.start(initialLoadSynchronously: true)
        let favorite = reopened.items.first!; precondition(reopened.favorites.contains(favorite.id))
        precondition(favorite.items[0][NSPasteboard.PasteboardType.rtf.rawValue] == rtf && favorite.items[0][NSPasteboard.PasteboardType.tiff.rawValue] == tiff)
        board.clearContents(); precondition(reopened.copy(favorite)); child("read"); reopened.shutdown()
    }
    print("PASS encrypted favorite survives restart and cross-process read")
}
