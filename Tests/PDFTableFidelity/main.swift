import AppKit
import CoreText
import PDFKit
import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-table-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let pdfURL = root.appendingPathComponent("table.pdf")
var box = CGRect(x: 0, y: 0, width: 500, height: 500)
let consumer = CGDataConsumer(url: pdfURL as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
pdf.beginPDFPage(nil); pdf.setFillColor(NSColor.white.cgColor); pdf.fill(box)
pdf.setStrokeColor(NSColor.black.cgColor); pdf.setLineWidth(1)
for x in [40, 180, 320] { pdf.move(to: CGPoint(x: x, y: 200)); pdf.addLine(to: CGPoint(x: x, y: 350)) }
for y in [200, 250, 300, 350] { pdf.move(to: CGPoint(x: 40, y: y)); pdf.addLine(to: CGPoint(x: 320, y: y)) }
pdf.strokePath()
let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
let cells = [("ITEM",55,320),("VALUE",195,320),("APPLE",55,270),("19",195,270),("PEAR",55,220),("42",195,220)]
for (value,x,y) in cells {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor]))
    pdf.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, pdf)
}
pdf.endPDFPage(); pdf.closePDF()
let docx = try DocumentConverter().convert(input: pdfURL, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", docx.path, "word/document.xml"]
let pipe = Pipe(); p.standardOutput = pipe; try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
let xml = String(data: data, encoding: .utf8) ?? ""
let hasTable = xml.contains("<w:tbl>") || xml.contains("<w:tbl ")
let hasCells = ["ITEM", "VALUE", "APPLE", "PEAR", "19", "42"].allSatisfy(xml.contains)
print("PDF_TABLE_FIDELITY table=\(hasTable) cells=\(hasCells)")
exit(hasTable && hasCells ? 0 : 1)
