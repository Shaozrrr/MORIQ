import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-webp-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let png = dir.appendingPathComponent("sample.png")
let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(dest))
precondition(ExternalMediaConverter.executable != nil)
let webp = try ExternalMediaConverter().convertImage(input: png, outputDirectory: dir)
let source = CGImageSourceCreateWithURL(webp as CFURL, nil)!
let converted = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let bitmap = NSBitmapImageRep(cgImage: converted)
precondition(bitmap.colorAt(x: 90, y: 50)!.alphaComponent < 0.05)
let heic = try ImageConverter().convert(input: png, outputDirectory: dir, format: .heic)
let second = try ExternalMediaConverter().convertImage(input: heic, outputDirectory: dir)
precondition(FileManager.default.fileExists(atPath: second.path) && FileManager.default.fileExists(atPath: png.path))
let oriented = dir.appendingPathComponent("oriented.png")
let orientedContext = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
orientedContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); orientedContext.fill(CGRect(x: 0, y: 0, width: 15, height: 20))
orientedContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); orientedContext.fill(CGRect(x: 15, y: 0, width: 15, height: 20))
let orientedDest = CGImageDestinationCreateWithURL(oriented as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(orientedDest, orientedContext.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary); precondition(CGImageDestinationFinalize(orientedDest))
let orientedWebP = try ExternalMediaConverter().convertImage(input: oriented, outputDirectory: dir)
let orientedSource = CGImageSourceCreateWithURL(orientedWebP as CFURL, nil)!
let props = CGImageSourceCopyPropertiesAtIndex(orientedSource, 0, nil) as! [CFString: Any]
let rendered = CGImageSourceCreateThumbnailAtIndex(orientedSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary)!
guard rendered.width == 20 && rendered.height == 30 else { print("FAIL WebP orientation dimensions \(rendered.width)x\(rendered.height), metadata \(props)"); exit(1) }
let originalSource = CGImageSourceCreateWithURL(oriented as CFURL, nil)!
let originalRendered = CGImageSourceCreateThumbnailAtIndex(originalSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary)!
let originalBitmap = NSBitmapImageRep(cgImage: originalRendered), resultBitmap = NSBitmapImageRep(cgImage: rendered)
for y in [5, 24] {
 let before = originalBitmap.colorAt(x: 10, y: y)!.usingColorSpace(.deviceRGB)!
 let after = resultBitmap.colorAt(x: 10, y: y)!.usingColorSpace(.deviceRGB)!
 precondition(abs(before.redComponent - after.redComponent) < 0.05 && abs(before.blueComponent - after.blueComponent) < 0.05, "WebP pixels rotated incorrectly")
}
print("PASS WebP preserves display orientation")
let tiff = dir.appendingPathComponent("pages.tiff")
let tiffWriter = CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
CGImageDestinationAddImage(tiffWriter, context.makeImage()!, nil)
CGImageDestinationAddImage(tiffWriter, orientedContext.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
precondition(CGImageDestinationFinalize(tiffWriter))
let multipage = try ExternalMediaConverter().convertImage(input: tiff, outputDirectory: dir)
let files = try FileManager.default.contentsOfDirectory(atPath: multipage.path).sorted()
precondition(files == ["001.webp", "002.webp"])
let firstSource = CGImageSourceCreateWithURL(multipage.appendingPathComponent(files[0]) as CFURL, nil)!
let firstImage = CGImageSourceCreateImageAtIndex(firstSource, 0, nil)!
precondition(NSBitmapImageRep(cgImage: firstImage).colorAt(x: 90, y: 50)!.alphaComponent < 0.05)
let lastSource = CGImageSourceCreateWithURL(multipage.appendingPathComponent(files[1]) as CFURL, nil)!
let lastImage = CGImageSourceCreateThumbnailAtIndex(lastSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary)!
precondition(lastImage.width == 20 && lastImage.height == 30)
let lastBitmap = NSBitmapImageRep(cgImage: lastImage)
for y in [5, 24] {
 let before = originalBitmap.colorAt(x: 10, y: y)!.usingColorSpace(.deviceRGB)!
 let after = lastBitmap.colorAt(x: 10, y: y)!.usingColorSpace(.deviceRGB)!
 precondition(abs(before.redComponent - after.redComponent) < 0.05 && abs(before.blueComponent - after.blueComponent) < 0.05)
}
let duplicate = try ExternalMediaConverter().convertImage(input: tiff, outputDirectory: dir)
precondition(duplicate != multipage && FileManager.default.fileExists(atPath: tiff.path))
print("PASS multipage TIFF to WebP preserves both pages, orientation, alpha and collisions")
for count in [1, 2] {
 let pdf = dir.appendingPathComponent("pdf-\(count).pdf")
 let consumer = CGDataConsumer(url: pdf as CFURL)!
 var bounds = CGRect(x: 0, y: 0, width: 60, height: 40)
 let pdfContext = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
 for index in 0..<count {
  pdfContext.beginPDFPage(nil); pdfContext.setFillColor((index == 0 ? NSColor.red : NSColor.blue).cgColor); pdfContext.fill(bounds); pdfContext.endPDFPage()
 }
 pdfContext.closePDF()
 let output = try ExternalMediaConverter().convertPDFPages(input: pdf, outputDirectory: dir)
 let files: [URL]
 if count == 1 { files = [output] } else { files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent } }
 precondition(files.count == count)
 for (index, file) in files.enumerated() {
  let src = CGImageSourceCreateWithURL(file as CFURL, nil)!, img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let color = NSBitmapImageRep(cgImage: img).colorAt(x: img.width / 2, y: img.height / 2)!.usingColorSpace(.deviceRGB)!
  precondition(index == 0 ? color.redComponent > 0.8 : color.blueComponent > 0.8)
 }
}
print("PASS single and multipage PDF to WebP preserve page count and content")
print("PASS: PNG and HEIC to lossless WebP, alpha retained and source protected")
