import AppKit
import Foundation
import CoreGraphics
import ImageIO
let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.format-test.\(UUID().uuidString)"))
defer { board.releaseGlobally() }
MainActor.assumeIsolated {
 let store = ClipboardStore(board: board, persistent: false)
 let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
 context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
 let image = context.makeImage()!
 for type in ["public.jpeg", "com.compuserve.gif"] {
  let data = NSMutableData(); let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
  let item = NSPasteboardItem(); item.setData(data as Data, forType: NSPasteboard.PasteboardType(type))
  board.clearContents(); precondition(board.writeObjects([item])); store.poll(); store.waitForCaptures()
  let entry = store.items.first!; precondition(entry.summary == "图片" && entry.imageData == data as Data)
  store.toggleFavorite(entry); store.copy(entry)
  precondition(board.data(forType: NSPasteboard.PasteboardType(type)) == data as Data)
  precondition(store.favorites.contains(entry.id)); print("PASS \(type) copied and favorited")
 }
 let pdf = NSMutableData(); let consumer = CGDataConsumer(data: pdf)!
 var bounds = CGRect(x: 0, y: 0, width: 50, height: 50)
 let pdfContext = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
 pdfContext.beginPDFPage(nil); pdfContext.setFillColor(CGColor(gray: 0.3, alpha: 1)); pdfContext.fill(bounds); pdfContext.endPDFPage(); pdfContext.closePDF()
 let item = NSPasteboardItem(); let type = NSPasteboard.PasteboardType("com.adobe.pdf")
 item.setData(pdf as Data, forType: type); board.clearContents(); precondition(board.writeObjects([item])); store.poll(); store.waitForCaptures()
 let entry = store.items.first!; precondition(entry.summary == "PDF 内容"); store.copy(entry)
 precondition(board.data(forType: type) == pdf as Data); print("PASS PDF content copied")
 let urlType = NSPasteboard.PasteboardType.fileURL.rawValue
 let textType = NSPasteboard.PasteboardType.string.rawValue
 let file = URL(fileURLWithPath: "/tmp/moriq-fixture.txt").absoluteString.data(using: .utf8)!
 let text = "保留单独的文字项目".data(using: .utf8)!
 let mixed = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", items: [[urlType: file], [textType: text]])
 store.copy(mixed)
 let restored = board.pasteboardItems!
 precondition(restored.count == 2 && restored[0].data(forType: .fileURL) == file && restored[1].data(forType: .string) == text)
 print("PASS mixed file and text items remain available after copying")
 let empty = ClipboardEntry(id: UUID(), created: Date(), source: "fixture", items: [[:]])
 precondition(!store.copy(empty) && store.copyError != nil)
 precondition(store.copy(mixed) && store.copyError == nil)
 print("PASS copy failures are reported and clear on successful retry")
}
