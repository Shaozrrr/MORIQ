import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-document-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let original = dir.appendingPathComponent("proposal.txt")
try "MORIQ document test\nPlease review the proposal by Friday.".write(to: original, atomically: true, encoding: .utf8)
let office = DocumentConverter.officeEngine
precondition(office != nil, "LibreOffice required for this test")
let converter = DocumentConverter()
let docx = try converter.convert(input: original, outputDirectory: dir, format: UTType(filenameExtension: "docx")!)
let pdf = try converter.convert(input: docx, outputDirectory: dir, format: .pdf)
let png = try converter.convert(input: pdf, outputDirectory: dir, format: .png)
precondition(FileManager.default.fileExists(atPath: png.path))
let text = try converter.convert(input: pdf, outputDirectory: dir, format: .plainText)
let wordFromPDF = try converter.convert(input: pdf, outputDirectory: dir, format: UTType(filenameExtension: "docx")!)
precondition((try? Data(contentsOf: wordFromPDF).prefix(2)) == Data([0x50, 0x4b]))
let recovered = try NSAttributedString(url: wordFromPDF, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
precondition(recovered.string.contains("MORIQ"), "PDF-to-Word must retain visible text")
let recoveredIndex = NSRange(recovered.string.range(of: "MORIQ")!, in: recovered.string).location
precondition(recovered.attribute(.font, at: recoveredIndex, effectiveRange: nil) != nil, "PDF-to-Word must retain text styling")
let scanImage = NSImage(size: NSSize(width: 180, height: 120))
scanImage.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 180, height: 120)).fill(); scanImage.unlockFocus()
let scanDocument = PDFDocument(); scanDocument.insert(PDFPage(image: scanImage)!, at: 0); scanDocument.insert(PDFPage(image: scanImage)!, at: 1)
let scanURL = dir.appendingPathComponent("scanned.pdf"); precondition(scanDocument.write(to: scanURL))
let scanDocx = try converter.convert(input: scanURL, outputDirectory: dir, format: UTType(filenameExtension: "docx")!)
let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); unzip.arguments = ["-Z1", scanDocx.path]
let listing = Pipe(); unzip.standardOutput = listing; try unzip.run(); let listed = listing.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit()
precondition(unzip.terminationStatus == 0 && (String(data: listed, encoding: .utf8) ?? "").contains("word/media/page1.png") && (String(data: listed, encoding: .utf8) ?? "").contains("word/media/page2.png"), "Scanned page image must be packaged in DOCX")
let scanRoundTrip = try converter.convert(input: scanDocx, outputDirectory: dir, format: .pdf)
let reopenedScan = PDFDocument(url: scanRoundTrip)
precondition(reopenedScan?.pageCount == 2, "Scanned page must survive Word export")
let thumb = reopenedScan!.page(at: 0)!.thumbnail(of: NSSize(width: 200, height: 260), for: .cropBox)
let bitmap = NSBitmapImageRep(data: thumb.tiffRepresentation!)!
var bluePixels = 0
for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.blueComponent > c.redComponent + 0.15 { bluePixels += 1 }
} }
precondition(bluePixels > 20, "Scanned page image must remain visible after DOCX round-trip")
do { _ = try converter.convert(input: scanURL, outputDirectory: dir, format: .plainText); fatalError("Scanned PDF must not claim to extract text") } catch DocumentConversionError.noText { }
let textScan = NSImage(size: NSSize(width: 1000, height: 300))
textScan.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
("MORIQ SCAN 9364" as NSString).draw(at: NSPoint(x: 45, y: 140), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 60), .foregroundColor: NSColor.black]); textScan.unlockFocus()
let scannedTextPDF = PDFDocument(); scannedTextPDF.insert(PDFPage(image: textScan)!, at: 0)
let scannedTextURL = dir.appendingPathComponent("scan-text.pdf"); precondition(scannedTextPDF.write(to: scannedTextURL))
let scannedTextResult = try converter.convert(input: scannedTextURL, outputDirectory: dir, format: .plainText)
let scannedText = try String(contentsOf: scannedTextResult, encoding: .utf8)
precondition(scannedText.uppercased().contains("MORIQ") && scannedText.contains("9364"), "scan OCR text must be extracted")
let pdfDocument = PDFDocument(url: pdf)!
precondition(pdfDocument.pageCount > 0 && (pdfDocument.string ?? "").contains("MORIQ"))
let extracted = try String(contentsOf: text, encoding: .utf8)
precondition(extracted.contains("MORIQ"))
for target in DocumentConverter.targets(for: .word) where target != UTType(filenameExtension: "docx")! && target != .pdf {
    _ = try converter.convert(input: docx, outputDirectory: dir, format: target)
}
let presentation = URL(fileURLWithPath: "/tmp/moriq-synthetic.pptx")
if FileManager.default.fileExists(atPath: presentation.path) {
    let localPresentation = dir.appendingPathComponent("slides.pptx")
    try FileManager.default.copyItem(at: presentation, to: localPresentation)
    for target in DocumentConverter.targets(for: .slides) where target != UTType(filenameExtension: "pptx")! {
        _ = try converter.convert(input: localPresentation, outputDirectory: dir, format: target)
    }
}
let csv = dir.appendingPathComponent("table.csv")
try "Name,Value\nTest,42\n".write(to: csv, atomically: true, encoding: .utf8)
let xlsx = try converter.convert(input: csv, outputDirectory: dir, format: UTType(filenameExtension: "xlsx")!)
for target in DocumentConverter.targets(for: .sheet) where target != UTType(filenameExtension: "xlsx")! {
    _ = try converter.convert(input: xlsx, outputDirectory: dir, format: target)
}
precondition((try? Data(contentsOf: xlsx).prefix(2)) == Data([0x50, 0x4b]))
precondition(FileManager.default.fileExists(atPath: original.path) && FileManager.default.fileExists(atPath: docx.path))
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
precondition(!files.contains { $0.hasPrefix(".moriq-") })
print("PASS: Word, PDF, spreadsheet and presentation target conversions, originals retained and scratch cleaned")
