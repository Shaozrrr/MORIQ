import Foundation
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
import PDFKit
import AppKit
let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent("MORIQ-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
let input = directory.appendingPathComponent("source.png")
let context = CGContext(data: nil, width: 24, height: 20, bitsPerComponent: 8, bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 24, height: 20))
let encoder = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(encoder))
let engine = ImageConverter()
var sources = try (ImageConverter.allowed + ImageConverter.additionalOutputs).map { try engine.convert(input: input, outputDirectory: directory, format: $0) }
let webp = directory.appendingPathComponent("source.webp")
try Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvBcAAAAdQsqKUu/+BiOh/AAA=")!.write(to: webp)
sources.append(webp)
for source in sources {
    let original = try Data(contentsOf: source)
    let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil)!
    let sourceImage = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil)!
    let expected = NSBitmapImageRep(cgImage: sourceImage).colorAt(x: sourceImage.width / 2, y: sourceImage.height / 2)!.usingColorSpace(.deviceRGB)!
    for target in ImageConverter.allowed + ImageConverter.additionalOutputs + [.pdf] {
        let result = try engine.convert(input: source, outputDirectory: directory, format: target)
        if target == .pdf { precondition(PDFDocument(url: result)?.pageCount == 1) }
        else {
            guard let data = CGImageSourceCreateWithURL(result as CFURL, nil), let decoded = CGImageSourceCreateImageAtIndex(data, 0, nil) else { fatalError("invalid result") }
            precondition(decoded.width == sourceImage.width && decoded.height == sourceImage.height, "dimensions changed")
            let actual = NSBitmapImageRep(cgImage: decoded).colorAt(x: decoded.width / 2, y: decoded.height / 2)!.usingColorSpace(.deviceRGB)!
            if expected.alphaComponent > 0.99 {
                precondition(abs(actual.redComponent - expected.redComponent) < 0.25 && abs(actual.greenComponent - expected.greenComponent) < 0.25 && abs(actual.blueComponent - expected.blueComponent) < 0.25, "center color changed")
            }
        }
    }
    let after = try Data(contentsOf: source)
    precondition(after == original)
}
let animation = directory.appendingPathComponent("animated.gif")
let animatedWriter = CGImageDestinationCreateWithURL(animation as CFURL, UTType.gif.identifier as CFString, 2, nil)!
CGImageDestinationAddImage(animatedWriter, context.makeImage()!, nil)
CGImageDestinationAddImage(animatedWriter, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(animatedWriter))
do { _ = try engine.convert(input: animation, outputDirectory: directory, format: .png); fatalError("animated image was silently flattened") }
catch ImageConversionError.invalidInput {}
print("PASS 9 input formats × 9 output formats, dimensions and opaque center color preserved, originals retained, animation not flattened")
