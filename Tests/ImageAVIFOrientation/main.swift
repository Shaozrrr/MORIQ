import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-avif-orient-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (color, rect) in [(NSColor.red, CGRect(x: 0, y: 0, width: 40, height: 30)), (NSColor.green, CGRect(x: 40, y: 0, width: 40, height: 30)), (NSColor.blue, CGRect(x: 0, y: 30, width: 40, height: 30)), (NSColor.yellow, CGRect(x: 40, y: 30, width: 40, height: 30))] {
 context.setFillColor(color.cgColor); context.fill(rect)
}
let image = context.makeImage()!, avif = UTType("public.avif")!
func displayed(_ url: URL) -> CGImage {
 let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
 _ = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
 return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 100] as CFDictionary)!
}
for orientation in 1...8 {
 let input = root.appendingPathComponent("orientation-\(orientation).png")
 let dest = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
 CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"]] as CFDictionary)
 precondition(CGImageDestinationFinalize(dest))
 let output = try ImageConverter().convert(input: input, outputDirectory: root, format: avif)
 let before = displayed(input), after = displayed(output)
 precondition(before.width == after.width && before.height == after.height, "wrong dimensions \(orientation)")
 let b = NSBitmapImageRep(cgImage: before), a = NSBitmapImageRep(cgImage: after)
 for x in [before.width / 4, before.width * 3 / 4] { for y in [before.height / 4, before.height * 3 / 4] {
  let first = b.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!, last = a.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
  precondition(abs(first.redComponent-last.redComponent) < 0.2 && abs(first.greenComponent-last.greenComponent) < 0.2 && abs(first.blueComponent-last.blueComponent) < 0.2, "wrong pixels \(orientation)")
 } }
 let src = CGImageSourceCreateWithURL(output as CFURL, nil)!, props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
 let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
 precondition(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:01:02 03:04:05", "lost date \(orientation)")
}
print("PASS all eight AVIF orientations, quadrant colors and EXIF date")
