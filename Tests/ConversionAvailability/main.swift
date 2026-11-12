import Foundation
import AppKit
import UniformTypeIdentifiers
let withoutOffice = DocumentConverter.targets(for: .pdf, officeAvailable: false)
let withOffice = DocumentConverter.targets(for: .pdf, officeAvailable: true)
for type in [UTType.plainText, .png, .jpeg] + ["docx"].compactMap({ UTType(filenameExtension: $0) }) {
 precondition(withoutOffice.contains(type), "native PDF target missing: \(type)")
}
for ext in ["rtf", "html", "odt"] {
 precondition(!withoutOffice.contains { $0.preferredFilenameExtension == ext })
 precondition(withOffice.contains { $0.preferredFilenameExtension == ext })
}
precondition(DocumentConverter.targets(for: .sheet, officeAvailable: false).isEmpty)
print("PASS native PDF targets remain available without LibreOffice")
if ProcessInfo.processInfo.environment["MORIQ_TEST_DISABLE_OFFICE"] == "1" {
 let fm = FileManager.default
 let root = fm.temporaryDirectory.appendingPathComponent("moriq-native-pdf-\(UUID().uuidString)")
 try fm.createDirectory(at: root, withIntermediateDirectories: true)
 defer { try? fm.removeItem(at: root) }
 let source = root.appendingPathComponent("native.pdf")
 let text = NSAttributedString(string: "MORIQ NATIVE 4826", attributes: [.font: NSFont.systemFont(ofSize: 16)])
 let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)); view.textStorage?.setAttributedString(text)
 try view.dataWithPDF(inside: view.bounds).write(to: source)
 let converter = DocumentConverter()
 let textOutput = try converter.convert(input: source, outputDirectory: root, format: .plainText)
 let extracted = try String(contentsOf: textOutput, encoding: .utf8)
 precondition(extracted.contains("MORIQ NATIVE 4826"))
 do {
  _ = try converter.convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
  fatalError("must not silently drop images when the packaged engine is unavailable")
 } catch DocumentConversionError.packagedEngineMissing { print("PASS missing document engine is reported") }
}
