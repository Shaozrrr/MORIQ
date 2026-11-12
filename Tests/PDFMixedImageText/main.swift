import AppKit
import CoreText
import Foundation
import UniformTypeIdentifiers
import PDFKit

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-mixed-ocr-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("mixed.pdf")
var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
let pdf = CGContext(consumer: CGDataConsumer(url: source as CFURL)!, mediaBox: &bounds, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(NSColor.white.cgColor); pdf.fill(bounds)
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): NSColor.black.cgColor]
let title = CTLineCreateWithAttributedString(NSAttributedString(string: "NATIVE TITLE", attributes: attrs))
pdf.textPosition = CGPoint(x: 30, y: 340); CTLineDraw(title, pdf)
let imageContext = CGContext(data: nil, width: 520, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
imageContext.setFillColor(NSColor.white.cgColor); imageContext.fill(CGRect(x: 0, y: 0, width: 520, height: 180))
let innerFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 46, nil)
let imageAttrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): innerFont, .init(kCTForegroundColorAttributeName as String): NSColor.black.cgColor]
let scan = CTLineCreateWithAttributedString(NSAttributedString(string: "INVOICE 4826", attributes: imageAttrs))
imageContext.textPosition = CGPoint(x: 24, y: 70); CTLineDraw(scan, imageContext)
pdf.draw(imageContext.makeImage()!, in: CGRect(x: 30, y: 80, width: 520, height: 180))
pdf.endPDFPage(); pdf.closePDF()
let result = try DocumentConverter().convert(input: source, outputDirectory: root, format: .plainText)
let text = try String(contentsOf: result, encoding: .utf8)
guard text.contains("NATIVE TITLE"), text.contains("4826") else { fputs("FAIL mixed PDF image text missing: \(text)\n", stderr); exit(1) }
guard text.components(separatedBy: "NATIVE TITLE").count == 2, text.range(of:"NATIVE TITLE")!.lowerBound < text.range(of:"4826")!.lowerBound else { fatalError("native duplicate or wrong reading order: \(text)") }
print("PASS native text and embedded image text retained")
for rotation in [0, 90, 180, 270] {
    let doc = PDFDocument(url: source)!, page = doc.page(at: 0)!
    page.setBounds(CGRect(x: 10, y: 20, width: 570, height: 360), for: .cropBox)
    page.rotation = rotation
    let input = root.appendingPathComponent("rotated-\(rotation).pdf")
    precondition(doc.write(to: input))
    let output = try DocumentConverter().convert(input: input, outputDirectory: root, format: .plainText)
    let actual = try String(contentsOf: output, encoding: .utf8)
    guard actual.contains("NATIVE TITLE"), actual.contains("4826"), actual.components(separatedBy: "NATIVE TITLE").count == 2, actual.components(separatedBy: "4826").count == 2 else {
        fputs("FAIL crop and rotation \(rotation): \(actual)\n", stderr); exit(1)
    }
    print("PASS crop and rotation \(rotation) retain native and image text without native duplication")
}
let first = PDFDocument(url: source)!, other = PDFDocument(url: source)!
first.insert(other.page(at: 0)!, at: 1)
let multi = root.appendingPathComponent("multi.pdf"); precondition(first.write(to: multi))
let multiOut = try DocumentConverter().convert(input: multi, outputDirectory: root, format: .plainText)
let multiText = try String(contentsOf: multiOut, encoding: .utf8)
guard multiText.components(separatedBy: "NATIVE TITLE").count == 3, multiText.components(separatedBy: "4826").count == 3 else { fatalError("multi-page text missing or duplicated: \(multiText)") }
print("PASS multiple mixed pages retained once each")
let pure = root.appendingPathComponent("pure.pdf")
let pureContext = CGContext(consumer: CGDataConsumer(url: pure as CFURL)!, mediaBox: &bounds, nil)!
pureContext.beginPDFPage(nil); pureContext.setFillColor(NSColor.white.cgColor); pureContext.fill(bounds)
pureContext.textPosition = CGPoint(x: 30, y: 340); CTLineDraw(title, pureContext)
pureContext.endPDFPage(); pureContext.closePDF()
let pureOut = try DocumentConverter().convert(input: pure, outputDirectory: root, format: .plainText)
let pureText = try String(contentsOf: pureOut, encoding: .utf8)
guard pureText.components(separatedBy: "NATIVE TITLE").count == 2 else { fatalError("plain PDF text duplicated: \(pureText)") }
enum TestOCRFailure: Error { case expected }
do {
    _ = try DocumentConverter.pdfText(PDFDocument(url: source)!.page(at: 0)!, recognize: { _ in throw TestOCRFailure.expected })
    fatalError("OCR failure was silently ignored")
} catch TestOCRFailure.expected { print("PASS OCR failures propagate instead of silently dropping text") }
print("PASS native-only page is not duplicated")
let overlapping = try DocumentConverter.pdfText(PDFDocument(url: source)!.page(at: 0)!, recognize: { _ in
    [OCRBlock(text: "NATIVE TITLE BONUS 4826", confidence: 1, boundingBox: CGRect(x: 0.05, y: 0.84, width: 0.48, height: 0.08))]
})
guard overlapping.contains("BONUS 4826") else { fatalError("overlapping OCR extra text was lost") }
let croppedPage = PDFDocument(url: pure)!.page(at: 0)!
croppedPage.setBounds(CGRect(x: 0, y: 0, width: 600, height: 300), for: .cropBox)
let fullNative = croppedPage.string ?? ""
let croppedResult = try DocumentConverter.pdfText(croppedPage, recognize: { _ in
    [OCRBlock(text: "IMAGE 4826", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.1))]
})
guard (!fullNative.contains("NATIVE TITLE") || croppedResult.contains("NATIVE TITLE")), croppedResult.contains("IMAGE 4826") else { fatalError("crop lost source text") }
print("PASS overlapping OCR extra text and unmapped native text are retained")
