import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-tiff-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let input = root.appendingPathComponent("pages.tiff")
let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for (i, color) in [NSColor.red, .blue].enumerated() {
 let context = CGContext(data: nil, width: 80, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
 context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 80, height: 50))
 CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: i == 1 ? 6 : 1, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(destination))
let original = try Data(contentsOf: input)
precondition(ImageConverter.isMultipageTIFF(input))
for format in ImageConverter.allowed + ImageConverter.additionalOutputs {
 print("Testing \(format.identifier)"); fflush(stdout)
 let folder = try ImageConverter().convert(input: input, outputDirectory: root, format: format)
 let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
 precondition(entries.count == 2)
 for i in 0..<2 {
  let path = folder.appendingPathComponent(String(format: "%03d.%@", i + 1, format.preferredFilenameExtension!))
  let source = CGImageSourceCreateWithURL(path as CFURL, nil)!
  if format.identifier == "public.avif" {
   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
   let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
   precondition(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:01:02 03:04:05")
  }
  let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 100]
  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)!
  precondition(CGSize(width: image.width, height: image.height) == (i == 0 ? CGSize(width: 80, height: 50) : CGSize(width: 50, height: 80)))
  let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)!.usingColorSpace(.deviceRGB)!
  precondition(i == 0 ? color.redComponent > 0.8 : color.blueComponent > 0.8)
 }
}
let result = try ImageConverter().convert(input: input, outputDirectory: root, format: .pdf)
let pdf = PDFDocument(url: result)!
precondition(pdf.pageCount == 2)
for i in 0..<2 {
 let page = pdf.page(at: i)!, bounds = page.bounds(for: .mediaBox)
 precondition(bounds.size == (i == 0 ? CGSize(width: 80, height: 50) : CGSize(width: 50, height: 80)))
 let image = page.thumbnail(of: bounds.size, for: .mediaBox)
 var rect = NSRect(origin: .zero, size: image.size)
 let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
 let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
 precondition(i == 0 ? color.redComponent > 0.8 : color.blueComponent > 0.8)
}
let after = try Data(contentsOf: input)
precondition(after == original)
let second = try ImageConverter().convert(input: input, outputDirectory: root, format: .pdf)
precondition(second != result && PDFDocument(url: second)?.pageCount == 2)
let transparent = root.appendingPathComponent("transparent.tiff")
let transparentWriter = CGImageDestinationCreateWithURL(transparent as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for _ in 0..<2 {
 let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
 context.clear(CGRect(x: 0, y: 0, width: 40, height: 40)); context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
 CGImageDestinationAddImage(transparentWriter, context.makeImage()!, nil)
}
precondition(CGImageDestinationFinalize(transparentWriter))
for format in [UTType.png, .heic] {
 let folder = try ImageConverter().convert(input: transparent, outputDirectory: root, format: format)
 for index in 1...2 {
  let file = folder.appendingPathComponent(String(format: "%03d.%@", index, format.preferredFilenameExtension!))
  let src = CGImageSourceCreateWithURL(file as CFURL, nil)!, img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let alpha = NSBitmapImageRep(cgImage: img).colorAt(x: 0, y: 0)!.alphaComponent
  precondition(alpha < 0.1, "transparent page lost transparency in \(format.identifier)")
 }
}
print("PASS multipage TIFF image and PDF formats preserve page order, orientation, original and tested transparency")
