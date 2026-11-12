import AppKit
import Foundation
let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.roundtrip.\(UUID().uuidString)"))
defer { board.releaseGlobally() }
MainActor.assumeIsolated {
    let store = ClipboardStore(board: board, persistent: false)
    let fixtures: [(NSPasteboard.PasteboardType, Data)] = [
        (.string, Data("Password: example sk-abcdefghijklmnopqr".utf8)),
        (.string, Data(String(repeating: "字", count: 100_001).utf8)),
        (.rtf, Data([0xff, 0x00, 0x12])),
        (.html, Data([0xff, 0xfe, 0x3c, 0x00])) ,
        (.rtf, Data(#"{\rtf1\ansi Password: example sk-abcdefghijklmnopqr}"#.utf8)),
        (.html, Data(("<html><body>" + String(repeating: "<span></span>", count: 12000) + "&#115;k-abcdefghijklmnopqr</body></html>").utf8))
    ]
    for (type, data) in fixtures {
        let item = NSPasteboardItem(); precondition(item.setData(data, forType: type))
        board.clearContents(); precondition(board.writeObjects([item])); store.poll(); store.waitForCaptures()
        guard let entry = store.items.first else { preconditionFailure("missing \(type)") }
        precondition(entry.items[0][type.rawValue] == data)
        precondition(store.copy(entry)); precondition(board.data(forType: type) == data)
    }
    let marker = NSPasteboardItem()
    marker.setString("fixture", forType: .string)
    marker.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let before = store.items.count
    board.clearContents(); precondition(board.writeObjects([marker])); store.poll(); store.waitForCaptures()
    precondition(store.items.count == before)
    let prior = store.items.count
    let oversized = NSPasteboardItem()
    oversized.setData(Data(repeating: 42, count: 8_000_001), forType: .png)
    board.clearContents(); precondition(board.writeObjects([oversized])); store.poll(); store.waitForCaptures()
    precondition(store.items.count == prior && store.captureWarning != nil)
    let many = (0..<51).map { index -> NSPasteboardItem in
        let item = NSPasteboardItem(); item.setString("fixture \(index)", forType: .string); return item
    }
    board.clearContents(); precondition(board.writeObjects(many)); store.poll(); store.waitForCaptures()
    precondition(store.items.count == prior && store.captureWarning != nil)
    store.dismissCaptureWarning(); precondition(store.captureWarning == nil)
    @MainActor func triggerWarning() {
        let fresh = (0..<51).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString("fixture \(index)", forType: .string); return item
        }
        board.clearContents(); precondition(board.writeObjects(fresh)); store.poll(); store.waitForCaptures()
        precondition(store.captureWarning != nil)
    }
    triggerWarning(); store.clearHistory(); precondition(store.captureWarning == nil)
    triggerWarning(); store.clear(); precondition(store.captureWarning == nil)
    triggerWarning(); store.stop(); precondition(store.captureWarning == nil)
    triggerWarning(); store.start(); precondition(store.captureWarning == nil); store.stop()
    print("PASS isolated clipboard roundtrip, capacity warning, dismissal and lifecycle resets")
}
