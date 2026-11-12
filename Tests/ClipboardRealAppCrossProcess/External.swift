import AppKit
import Foundation
let args = CommandLine.arguments
precondition(args.count == 3 && args[2].hasPrefix("local.moriq.external.test."))
let board = NSPasteboard(name: NSPasteboard.Name(args[2]))
let value = "模拟富文本 ✓"
if args[1] == "write" {
    let rich = NSAttributedString(string: value, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
    let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<2 { for x in 0..<3 { pixels.setColor(NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.9, alpha: 1), atX: x, y: y) } }
    let item = NSPasteboardItem(); item.setString(value, forType: .string); item.setData(rtf, forType: .rtf); item.setData(pixels.representation(using: .tiff, properties: [:])!, forType: .tiff)
    board.clearContents(); precondition(board.writeObjects([item])); print("PASS independent app wrote test contents")
} else if args[1] == "cleanup" {
    board.releaseGlobally()
} else {
    guard let rtf = board.data(forType: .rtf), let imageData = board.data(forType: .tiff) else { fatalError("missing formats") }
    let text = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    precondition(text.string == value && (text.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue)
    let image = NSBitmapImageRep(data: imageData)!, c = image.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
    precondition(image.pixelsWide == 3 && image.pixelsHigh == 2 && c.blueComponent > 0.8 && c.redComponent < 0.3)
    print("PASS independent app received text, formatting and image pixels")
}
