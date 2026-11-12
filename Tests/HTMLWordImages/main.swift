import AppKit
import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-html-word-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let img = NSImage(size: NSSize(width: 30, height: 20))
img.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 30, height: 20).fill(); img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("image.png"))
let source = root.appendingPathComponent("source.html")
let html = "<html><body><p>图文测试 4812</p><img src=image.png></body></html>"
try html.write(to: source, atomically: true, encoding: .utf8)
let converter = DocumentConverter()
let result = try converter.convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
guard try String(contentsOf: source, encoding: .utf8) == html else { fatalError("original HTML modified") }
let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-Z1", result.path]; let pipe = Pipe(); unzip.standardOutput = pipe
try unzip.run(); let listing = pipe.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit()
guard unzip.terminationStatus == 0, String(decoding: listing, as: UTF8.self).contains("word/media/") else { fatalError("image not embedded") }
let text = try NSAttributedString(url: result, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
guard text.contains("图文测试 4812") else { fatalError("text lost") }
try fm.removeItem(at: root.appendingPathComponent("image.png"))
do { _ = try converter.convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!); fatalError("missing image accepted") }
catch DocumentConversionError.resourceUnavailable { print("PASS embedded image and text; source unchanged; missing image rejected") }
let misleading = root.appendingPathComponent("misleading.html")
let markup = """
<html><body><!-- <img src="comment-missing.png"> -->
<script>let example = '<img src="script-missing.png">';</script>
<p data-src="attribute-missing.png">Visible marker</p><img data-src="lazy-missing.png">
</body></html>
"""
try markup.write(to: misleading, atomically: true, encoding: .utf8)
let noImageResult = try converter.convert(input: misleading, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
guard fm.fileExists(atPath: noImageResult.path) else { fatalError("comment/script/data-src treated as image") }
let latin = root.appendingPathComponent("latin.html")
let latinHTML = "<html><head><meta charset=\"windows-1252\"></head><body>Résumé café 4812</body></html>"
try latinHTML.data(using: .windowsCP1252)!.write(to: latin)
let latinResult = try converter.convert(input: latin, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let latinText = try NSAttributedString(url: latinResult, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
guard latinText.contains("Résumé café 4812") else { fatalError("non-UTF-8 text corrupted: \(latinText)") }
print("PASS comments, script, data-src ignored; Windows-1252 HTML preserved")
try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("image.png"))
let cssSource = root.appendingPathComponent("background.html")
let cssHTML = "<html><body><p style=\"background-image:url(image.png)\">Background marker</p></body></html>"
try cssHTML.write(to: cssSource, atomically: true, encoding: .utf8)
let cssResult = try converter.convert(input: cssSource, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
guard fm.fileExists(atPath: cssResult.path), try String(contentsOf: cssSource, encoding: .utf8) == cssHTML else { fatalError("background conversion or input preservation failed") }
guard let notice = DocumentConverter.pdfResultNotice(input: cssSource, targetExtension: "docx"), notice.contains("背景图"), notice.contains("可能") else { fatalError("missing fidelity notice") }
guard DocumentConverter.pdfResultNotice(input: cssSource, targetExtension: "txt") == nil else { fatalError("notice incorrectly applied to another format") }
print("PASS CSS background conversion retained with clear fidelity notice; source unchanged")

try fm.removeItem(at: root.appendingPathComponent("image.png"))
let missingBackground = try converter.convert(input: cssSource, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
guard fm.fileExists(atPath: missingBackground.path), DocumentConverter.pdfResultNotice(input: cssSource, targetExtension: "docx")?.contains("背景图") == true else { fatalError("missing background warning") }
print("PASS missing background retains explicit fidelity notice")
