import Foundation
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-dpi-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(NSColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
let image = ctx.makeImage()!
let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 150, kCGImagePropertyOrientation: 6]
let png = root.appendingPathComponent("scan.png")
let writer = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(writer, image, props as CFDictionary); precondition(CGImageDestinationFinalize(writer))
let single = try ImageConverter().convert(input: png, outputDirectory: root, format: .pdf)
func check(_ page: PDFPage, _ expected: CGSize) {
 let size = page.bounds(for: .mediaBox).size
 precondition(abs(size.width - expected.width) < 0.2 && abs(size.height - expected.height) < 0.2, "unexpected PDF size \(size), wanted \(expected)")
}
check(PDFDocument(url: single)!.page(at: 0)!, CGSize(width: 96, height: 72))
let tiff = root.appendingPathComponent("scans.tiff")
let tw = CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
CGImageDestinationAddImage(tw, image, props as CFDictionary)
CGImageDestinationAddImage(tw, image, [kCGImagePropertyDPIWidth: 150, kCGImagePropertyDPIHeight: 300, kCGImagePropertyOrientation: 1] as CFDictionary)
precondition(CGImageDestinationFinalize(tw))
let multi = try ImageConverter().convert(input: tiff, outputDirectory: root, format: .pdf)
let doc = PDFDocument(url: multi)!
precondition(doc.pageCount == 2)
check(doc.page(at: 0)!, CGSize(width: 96, height: 72)); check(doc.page(at: 1)!, CGSize(width: 144, height: 48))
let avif = try ImageConverter().convert(input: tiff, outputDirectory: root, format: UTType("public.avif")!)
let first = CGImageSourceCreateWithURL(avif.appendingPathComponent("001.avif") as CFURL, nil)!
let avifImage = CGImageSourceCreateImageAtIndex(first, 0, nil)!
let avifProps = CGImageSourceCopyPropertiesAtIndex(first, 0, nil) as! [CFString: Any]
precondition(avifImage.width == 200 && avifImage.height == 300)
precondition(abs((avifProps[kCGImagePropertyDPIWidth] as! NSNumber).doubleValue - 150) < 1)
precondition(abs((avifProps[kCGImagePropertyDPIHeight] as! NSNumber).doubleValue - 300) < 1)
print("PASS single and multi-page image PDFs respect per-axis DPI and rotation")
print("PASS oriented AVIF retains the corrected per-axis DPI")
