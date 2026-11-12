import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-fidelity-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let text = NSMutableAttributedString(string: "MORIQ bold heading\n", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 24)!, .foregroundColor: NSColor.systemRed])
text.append(NSAttributedString(string: "Body paragraph 7193", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]))
let input = root.appendingPathComponent("source.rtf")
let rtf = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
try rtf.write(to: input)
let converter = DocumentConverter()
let pdf = try converter.convert(input: input, outputDirectory: root, format: .pdf)
if let path = ProcessInfo.processInfo.environment["MORIQ_FIDELITY_PDF"] { try? fm.removeItem(atPath: path); try fm.copyItem(at: pdf, to: URL(fileURLWithPath: path)) }
let pdfAttributed = PDFDocument(url: pdf)!.page(at: 0)!.attributedString!
if let range = pdfAttributed.string.range(of: "MORIQ bold heading") {
    let f = pdfAttributed.attribute(.font, at: NSRange(range, in: pdfAttributed.string).location, effectiveRange: nil) as? NSFont
    print("PDF_SOURCE_FONT name=\(f?.fontName ?? "none") traits=\(f?.fontDescriptor.symbolicTraits.rawValue ?? 0)")
}
let word = try converter.convert(input: pdf, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let result = try NSAttributedString(url: word, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
guard let heading = result.string.range(of: "MORIQ bold heading"), result.string.contains("Body paragraph 7193") else { fatalError("lost text") }
let index = NSRange(heading, in: result.string).location
let font = result.attribute(.font, at: index, effectiveRange: nil) as? NSFont
let color = (result.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB)
let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
let red = color.map { $0.redComponent > $0.greenComponent + 0.15 && $0.redComponent > $0.blueComponent + 0.15 } ?? false
print("PDF_DOCX_FIDELITY bold=\(bold) red=\(red) fontSize=\(font?.pointSize ?? 0) name=\(font?.fontName ?? "none")")
exit(bold && red ? 0 : 1)
