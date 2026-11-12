import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-pdf-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let input = dir.appendingPathComponent("sample.pdf")
let consumer = CGDataConsumer(url: input as CFURL)!
var box = CGRect(x: 0, y: 0, width: 100, height: 120)
let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
for index in 0..<2 {
    pdf.beginPDFPage(nil); pdf.setFillColor(index == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1)); pdf.fill(box); pdf.endPDFPage()
}
pdf.closePDF()
let existing = dir.appendingPathComponent("sample 页面", isDirectory: true)
try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
let sentinel = existing.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
let output = try PDFPageExporter().convert(input: input, outputDirectory: dir, format: .png)
precondition(output.lastPathComponent == "sample 页面 (2)")
let jpegOutput = try PDFPageExporter().convert(input: input, outputDirectory: dir, format: .jpeg)
var outputs = [(output, UTType.png.preferredFilenameExtension!), (jpegOutput, UTType.jpeg.preferredFilenameExtension!)]
for format in PDFPageExporter.supportedFormats() where format != .png && format != .jpeg {
 outputs.append((try PDFPageExporter().convert(input: input, outputDirectory: dir, format: format), format.preferredFilenameExtension!))
}
precondition(outputs.count >= 6)
for (folder, ext) in outputs {
    for index in 1...2 {
        let file = folder.appendingPathComponent(String(format: "%03d.%@", index, ext))
        let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == 200 && image.height == 240)
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: 100, y: 120)!.usingColorSpace(.deviceRGB)!
        precondition(index == 1 ? color.redComponent > 0.8 && color.blueComponent < 0.2 : color.blueComponent > 0.8 && color.redComponent < 0.2, "page content mismatch")
    }
}
precondition(FileManager.default.fileExists(atPath: sentinel.path) && FileManager.default.fileExists(atPath: input.path))
print("PASS: multi-page PDF to \(outputs.count) image formats, page content, collision avoidance and original preservation")
let longInput = dir.appendingPathComponent("long.pdf")
let longConsumer = CGDataConsumer(url: longInput as CFURL)!
var longBounds = CGRect(x: 0, y: 0, width: 120, height: 160)
let longPDF = CGContext(consumer: longConsumer, mediaBox: &longBounds, nil)!
for index in 0..<80 {
    longPDF.beginPDFPage(nil)
    let value = CGFloat(index) / 79
    longPDF.setFillColor(CGColor(red: value, green: 0.2, blue: 1 - value, alpha: 1))
    longPDF.fill(longBounds); longPDF.endPDFPage()
}
longPDF.closePDF()
let longOutput = try PDFPageExporter().convert(input: longInput, outputDirectory: dir, format: .png)
let longFiles = try FileManager.default.contentsOfDirectory(atPath: longOutput.path)
precondition(longFiles.count == 80)
var previousRed: CGFloat = -1
for index in [0, 19, 39, 59, 79] {
    let file = longOutput.appendingPathComponent(String(format: "%03d.png", index + 1))
    let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let color = NSBitmapImageRep(cgImage: image).colorAt(x: 50, y: 50)!.usingColorSpace(.deviceRGB)!
    precondition(color.redComponent > previousRed + 0.05, "page sequence mismatch")
    previousRed = color.redComponent
}
print("PASS: 80-page PDF exports every page in the correct order")
