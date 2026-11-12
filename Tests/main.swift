import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent("MORIQ-converter-test-\(UUID().uuidString)")
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
let input = directory.appendingPathComponent("sample.png")
let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
let dest = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(dest))
let original = try Data(contentsOf: input)
let engine = ImageConverter()
var fixtures: [URL] = [input]
for format in [UTType.jpeg, .tiff, .heic] {
    let output = try engine.convert(input: input, outputDirectory: directory, format: format)
    guard CGImageSourceCreateWithURL(output as CFURL, nil) != nil else { fatalError("invalid output") }
    fixtures.append(output)
    print("PASS", format.identifier, output.lastPathComponent)
}
for fixture in fixtures {
    for format in [UTType.png, .jpeg, .tiff, .heic] {
        let converted = try engine.convert(input: fixture, outputDirectory: directory, format: format)
        precondition(CGImageSourceCreateWithURL(converted as CFURL, nil) != nil)
    }
}
print("PASS 16 image format pairs")
let second = try engine.convert(input: input, outputDirectory: directory, format: .jpeg)
precondition(second.lastPathComponent != "sample.jpeg")
let current = try Data(contentsOf: input)
precondition(current == original)
let bad = directory.appendingPathComponent("bad.png"); try Data("not an image".utf8).write(to: bad)
do { _ = try engine.convert(input: bad, outputDirectory: directory, format: .jpeg); fatalError("invalid input accepted") } catch ImageConversionError.invalidInput { print("PASS invalid input rejected") }
let leftovers = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".moriq-") }
precondition(leftovers.isEmpty)
print("PASS collision protection, source preservation, temporary cleanup")
