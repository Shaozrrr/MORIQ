import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-rotation-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let raw = root.appendingPathComponent("raw.pdf")
let consumer = CGDataConsumer(url: raw as CFURL)!
var bounds = CGRect(x: 0, y: 0, width: 100, height: 160)
let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
context.beginPDFPage(nil)
let colors: [(CGColor, CGRect)] = [
 (CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGRect(x: 0, y: 80, width: 50, height: 80)),
 (CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGRect(x: 50, y: 80, width: 50, height: 80)),
 (CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGRect(x: 0, y: 0, width: 50, height: 80)),
 (CGColor(red: 1, green: 1, blue: 0, alpha: 1), CGRect(x: 50, y: 0, width: 50, height: 80))]
for (color, box) in colors { context.setFillColor(color); context.fill(box) }
context.endPDFPage(); context.closePDF()
let original = PDFDocument(url: raw)!.page(at: 0)!
let document = PDFDocument()
for (index, angle) in [0,90,180,270].enumerated() { let page = original.copy() as! PDFPage; page.rotation = angle; document.insert(page, at: index) }
let input = root.appendingPathComponent("rotations.pdf"); precondition(document.write(to: input))
for type in PDFPageExporter.supportedFormats() {
 let result = try PDFPageExporter().convert(input: input, outputDirectory: root, format: type)
 var previous: [String] = []
 for (index, angle) in [0,90,180,270].enumerated() {
  let file = result.appendingPathComponent(String(format: "%03d.%@",index + 1,type.preferredFilenameExtension!))
  let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(file as CFURL, nil)!, 0, nil)!
  let sideways = angle % 180 != 0
  precondition(image.width == (sideways ? 320 : 200) && image.height == (sideways ? 200 : 320), "dimensions at \(angle)")
  let bitmap = NSBitmapImageRep(cgImage: image)
  func color(_ x: Double, _ y: Double) -> String {
   let c = bitmap.colorAt(x: Int(Double(image.width) * x), y: Int(Double(image.height) * y))!.usingColorSpace(.deviceRGB)!
   if c.redComponent > 0.75 && c.greenComponent > 0.75 { return "Y" }
   if c.redComponent > 0.75 { return "R" }; if c.greenComponent > 0.75 { return "G" }; if c.blueComponent > 0.75 { return "B" }; return "?"
  }
  let actual = [color(0.25,0.25),color(0.75,0.25),color(0.25,0.75),color(0.75,0.75)]
  if index == 0 { precondition(Set(actual) == Set(["R","G","B","Y"])) }
  else { precondition(actual == [previous[2], previous[0], previous[3], previous[1]], "wrong rotation \(angle): \(actual), previous \(previous)") }
  previous = actual
  print("PASS \(type.preferredFilenameExtension!) rotation \(angle): \(actual.joined())")
 }
}
