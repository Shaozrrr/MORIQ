import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("MORIQ-image-edges-\(UUID().uuidString)")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let src = dir.appendingPathComponent("source.png")
let ctx = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: 30, height: 20))
ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)); ctx.fill(CGRect(x: 4, y: 4, width: 20, height: 12))
let dest = CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary); precondition(CGImageDestinationFinalize(dest))
for type in [UTType.png, .tiff, .heic, .jpeg] {
 let output = try ImageConverter().convert(input: src, outputDirectory: dir, format: type)
 let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
 let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
 let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
 let alpha = NSBitmapImageRep(cgImage: decoded).colorAt(x: 0, y: 0)?.alphaComponent ?? -1
 precondition((props[kCGImagePropertyOrientation] as? Int) == 6)
 if type == .jpeg {
  let notice = ImageConverter.resultNotice(input: src, output: output) ?? ""
  precondition(notice.contains("透明通道未保留") && notice.contains("有损压缩"))
  precondition(alpha > 0.99)
  let pixel = NSBitmapImageRep(cgImage: decoded).colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
  guard pixel.redComponent > 0.9 && pixel.greenComponent > 0.9 && pixel.blueComponent > 0.9 else { print("FAIL JPEG transparent background: \(pixel)"); exit(1) }
 } else { precondition(alpha < 0.03) }
}
let avif = try ImageConverter().convert(input: src, outputDirectory: dir, format: UTType("public.avif")!)
let avifSource = CGImageSourceCreateWithURL(avif as CFURL, nil)!
let avifImage = CGImageSourceCreateThumbnailAtIndex(avifSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary)!
precondition(avifImage.width == 20 && avifImage.height == 30, "AVIF display orientation was not preserved")

let pdf = try ImageConverter().convert(input: src, outputDirectory: dir, format: .pdf)
let page = PDFDocument(url: pdf)!.page(at: 0)!.bounds(for: .mediaBox)
precondition(Int(page.width) == 20 && Int(page.height) == 30)
print("PASS: image orientation metadata, alpha behavior, and oriented PDF dimensions")
