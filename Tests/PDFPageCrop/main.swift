import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-crop-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let raw = root.appendingPathComponent("raw.pdf")
let consumer = CGDataConsumer(url: raw as CFURL)!
var bounds = CGRect(x: 0, y: 0, width: 200, height: 160)
let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
context.beginPDFPage(nil)
context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(bounds)
context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 50, y: 30, width: 100, height: 100))
context.endPDFPage(); context.closePDF()
let document = PDFDocument(url: raw)!
let page = document.page(at: 0)!; page.setBounds(CGRect(x: 50, y: 30, width: 100, height: 100), for: .cropBox)
let input = root.appendingPathComponent("cropped.pdf"); precondition(document.write(to: input))
let result = try PDFPageExporter().convert(input: input, outputDirectory: root, format: .png)
let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(result as CFURL, nil)!, 0, nil)!
guard image.width == 200 && image.height == 200 else { print("FAIL cropped dimensions \(image.width)×\(image.height)"); exit(1) }
let c = NSBitmapImageRep(cgImage: image).colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!
guard c.blueComponent > 0.8 && c.redComponent < 0.2 else { print("FAIL cropped content \(c)"); exit(1) }
print("PASS crop box matches visible page")
