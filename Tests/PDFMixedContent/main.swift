import AppKit
import CoreText
import PDFKit
import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
precondition(DocumentConverter.packagedPDFEngine != nil, "packaged PDF engine is missing")
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-mixed-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let pdfURL = root.appendingPathComponent("mixed.pdf")
var box = CGRect(x: 0, y: 0, width: 400, height: 400)
let consumer = CGDataConsumer(url: pdfURL as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(NSColor.white.cgColor); pdf.fill(box)
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MORIQ MIXED 7193", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor]))
pdf.textPosition = CGPoint(x: 30, y: 330); CTLineDraw(line, pdf)
let imageContext = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
imageContext.setFillColor(NSColor.systemBlue.cgColor); imageContext.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
pdf.draw(imageContext.makeImage()!, in: CGRect(x: 40, y: 100, width: 200, height: 160))
pdf.endPDFPage(); pdf.closePDF()
precondition(DocumentConverter.pdfResultNotice(input: pdfURL, targetExtension: "txt")?.contains("提取文字") == true)
precondition(DocumentConverter.pdfResultNotice(input: pdfURL, targetExtension: "docx")?.contains("检查版式和图片") == true)
precondition(DocumentConverter.pdfResultNotice(input: pdfURL, targetExtension: "png") == nil)
let scannedURL = root.appendingPathComponent("scanned.pdf")
let scanned = CGContext(consumer: CGDataConsumer(url: scannedURL as CFURL)!, mediaBox: &box, nil)!
scanned.beginPDFPage(nil); scanned.draw(imageContext.makeImage()!, in: box); scanned.endPDFPage(); scanned.closePDF()
precondition(DocumentConverter.pdfResultNotice(input: scannedURL, targetExtension: "docx")?.contains("图片保留") == true)
let docx = try DocumentConverter().convert(input: pdfURL, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let text = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
precondition(text.contains("MORIQ MIXED 7193"), "text lost")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-Z1", docx.path]
let pipe = Pipe(); p.standardOutput = pipe; try p.run(); let listing = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
precondition((String(data: listing, encoding: .utf8) ?? "").contains("word/media/"), "embedded image lost")
print("PASS: PDF text and image both survive DOCX conversion")
// A scan between editable pages must not force every page to become an image.
let mixedPages = PDFDocument()
mixedPages.insert(PDFDocument(url: pdfURL)!.page(at: 0)!, at: 0)
mixedPages.insert(PDFDocument(url: scannedURL)!.page(at: 0)!, at: 1)
mixedPages.insert(PDFDocument(url: pdfURL)!.page(at: 0)!, at: 2)
let mixedPagesURL = root.appendingPathComponent("mixed-pages.pdf")
precondition(mixedPages.write(to: mixedPagesURL))
let mixedDocx = try DocumentConverter().convert(input: mixedPagesURL, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let read = Process(); read.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); read.arguments = ["-p", mixedDocx.path, "word/document.xml"]
let xmlPipe = Pipe(); read.standardOutput = xmlPipe; try read.run(); let xmlData = xmlPipe.fileHandleForReading.readDataToEndOfFile(); read.waitUntilExit()
let xml = String(data: xmlData, encoding: .utf8) ?? ""
precondition(xml.components(separatedBy: "MORIQ MIXED 7193").count == 3, "editable text was lost across scanned page")
let list = Process(); list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); list.arguments = ["-Z1", mixedDocx.path]
let listPipe = Pipe(); list.standardOutput = listPipe; try list.run(); let mixedList = listPipe.fileHandleForReading.readDataToEndOfFile(); list.waitUntilExit()
precondition((String(data: mixedList, encoding: .utf8) ?? "").contains("word/media/"), "scanned page was lost")
print("PASS: scanned page and editable pages retained together")
