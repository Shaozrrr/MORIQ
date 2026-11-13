import AppKit
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.test.\(UUID().uuidString)"))
MainActor.assumeIsolated {
    let store = ClipboardStore(board: board, persistent: false)
    @MainActor func put(_ values: [(NSPasteboard.PasteboardType, Data)]) {
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: type) }
        board.clearContents(); board.writeObjects([item]); store.poll(); store.waitForCaptures()
    }
    put([(.string, Data("A normal note".utf8)), (.html, Data("<b>A normal note</b>".utf8))])
    precondition(store.items.count == 1 && store.items[0].text == "A normal note")
    let saved = store.items[0]
    store.toggleFavorite(saved)
    precondition(store.favorites.contains(saved.id))
    store.copy(saved)
    precondition(board.string(forType: .string) == "A normal note" && board.data(forType: .html) != nil)
    store.copy(saved, plain: true)
    precondition(board.string(forType: .string) == "A normal note" && board.data(forType: .html) == nil)
    put([(.string, Data("sk-abcdefghijklmnopqrstuvwxyz".utf8))])
    precondition(store.items.count == 2 && store.items[0].text == "sk-abcdefghijklmnopqrstuvwxyz")
    put([(.string, Data("not retained".utf8)), (NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), Data())])
    precondition(store.items.count == 2)
    for marker in ["com.agilebits.onepassword", "net.antelle.keeweb", "de.petermaurer.TransientPasteboardType"] {
        put([(.string, Data("not retained".utf8)), (NSPasteboard.PasteboardType(marker), Data())])
        precondition(store.items.count == 2, "sensitive pasteboard markers must not enter history")
    }
    let ordinary = NSPasteboardItem(); ordinary.setString("ordinary first item", forType: .string)
    let sensitive = NSPasteboardItem(); sensitive.setString("sk-abcdefghijklmnopqrstuvwxyz", forType: .string)
    board.clearContents(); board.writeObjects([ordinary, sensitive]); store.poll(); store.waitForCaptures()
    precondition(store.items.count == 3 && store.items[0].items.count == 2)
    let hidden = NSPasteboardItem(); hidden.setString("second item", forType: .string)
    hidden.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let anotherOrdinary = NSPasteboardItem(); anotherOrdinary.setString("ordinary first item", forType: .string)
    board.clearContents(); board.writeObjects([anotherOrdinary, hidden]); store.poll(); store.waitForCaptures()
    precondition(store.items.count == 3 && store.items[0].items.count == 2)
    let first = NSPasteboardItem(); first.setString("file:///tmp/one.txt", forType: .fileURL)
    let second = NSPasteboardItem(); second.setString("file:///tmp/two.txt", forType: .fileURL)
    board.clearContents(); board.writeObjects([first, second]); store.poll(); store.waitForCaptures()
    precondition(store.items.first?.fileNames == ["one.txt", "two.txt"])
    store.copy(store.items[0]); precondition(board.pasteboardItems?.count == 2)
    let imageContext = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    imageContext.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); imageContext.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    let imageData = NSMutableData()
    let writer = CGImageDestinationCreateWithData(imageData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, imageContext.makeImage()!, nil); precondition(CGImageDestinationFinalize(writer))
    put([(.png, imageData as Data)])
    precondition(store.items.first?.imageData != nil)
    store.copy(store.items[0]); precondition(board.data(forType: .png) == imageData as Data)
    store.clearHistory()
    precondition(store.items.count == 1 && store.items[0].id == saved.id && store.favorites.contains(saved.id))
    store.copy(store.items[0]); precondition(board.string(forType: .string) == "A normal note")
    let key = SymmetricKey(size: .bits256)
    let plaintext = try! JSONEncoder().encode(store.items)
    let ciphertext = try! ClipboardCipher.seal(plaintext, using: key)
    precondition(ciphertext != plaintext && (try! ClipboardCipher.open(ciphertext, using: key)) == plaintext)
    do { _ = try ClipboardCipher.open(ciphertext, using: SymmetricKey(size: .bits256)); fatalError("wrong key accepted") } catch {}
    print("PASS: rich text, plain copy, filtering, files, images and authenticated encryption on isolated data")
}
