import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("moriq-image-depth-\(UUID().uuidString)")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let source = dir.appendingPathComponent("gradient.png")
let width = 256, height = 4
var pixels = (0..<(width * height)).map { UInt16(($0 % width) * 257) }
let original = pixels.withUnsafeMutableBytes { bytes -> CGImage in
    let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 2,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    return context.makeImage()!
}
let writer = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(writer, original, nil); precondition(CGImageDestinationFinalize(writer))
let input = CGImageSourceCreateWithURL(source as CFURL, nil)!
let sourceImage = CGImageSourceCreateImageAtIndex(input, 0, nil)!
precondition(sourceImage.bitsPerComponent == 16)
func normalized(_ image: CGImage) -> [UInt16] {
    var out = [UInt16](repeating: 0, count: width * height)
    out.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 2,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return out
}
let reference = normalized(sourceImage)
for format in [UTType.png, .tiff] {
    let result = try ImageConverter().convert(input: source, outputDirectory: dir, format: format)
    let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(result as CFURL, nil)!, 0, nil)!
    guard decoded.bitsPerComponent == 16 else { print("FAIL \(format.identifier): \(decoded.bitsPerComponent)-bit output"); exit(1) }
    precondition(normalized(decoded) == reference, "16-bit grayscale values changed")
    print("PASS 16-bit source → \(format.identifier) remains 16-bit")
}
let jpeg = try ImageConverter().convert(input: source, outputDirectory: dir, format: .jpeg)
let notice = ImageConverter.resultNotice(input: source, output: jpeg) ?? ""
precondition(notice.contains("色彩精度降低") && notice.contains("有损压缩"))
