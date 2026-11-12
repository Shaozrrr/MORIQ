import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-sparse-animation-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("source.gif")
let writer = CGImageDestinationCreateWithURL(input as CFURL, UTType.gif.identifier as CFString, 2, nil)!
for (color, delay) in [(CGColor(red: 1, green: 0, blue: 0, alpha: 1), 0.01), (CGColor(red: 0, green: 0, blue: 1, alpha: 1), 9.99)] {
 let ctx = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
 CGImageDestinationAddImage(writer, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(writer))
let engine = ExternalMediaConverter.executable!
func run(_ output: URL, _ arguments: [String]) throws -> Data {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error", "-i", output.path] + arguments
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 guard p.terminationStatus == 0 else { throw ExternalMediaError.failed }; return data
}
for target in ExternalMediaConverter.videoTargets() where target != .gif {
print("CHECK \(target.preferredFilenameExtension!)"); fflush(stdout)
let output = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: target, video: true)
let md5 = String(decoding: try run(output, ["-fps_mode", "passthrough", "-f", "framemd5", "-"]), as: UTF8.self)
let encodedCount = md5.split(separator: "\n").filter { !$0.hasPrefix("#") }.count
let expectedCount = ["avi", "flv"].contains(target.preferredFilenameExtension ?? "") ? 1000 : 3
guard encodedCount == expectedCount else { fatalError("expected \(expectedCount) encoded frames, got \(encodedCount)") }
let bytes = [UInt8](try run(output, ["-vf", "fps=100", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]))
let stride = 80 * 60 * 3
guard bytes.count == 1000 * stride else { fatalError("wrong playback duration: \(bytes.count / stride) frames") }
for (frame, channel) in [(0, 0), (1, 2), (999, 2)] {
 let p = frame * stride, pixel = [Int(bytes[p]), Int(bytes[p + 1]), Int(bytes[p + 2])]
 guard pixel[channel] > 100 && pixel[channel] > pixel[(channel + 1) % 3] + 50 && pixel[channel] > pixel[(channel + 2) % 3] + 50 else { fatalError("wrong color at \(frame): \(pixel)") }
}
print("PASS \(target.preferredFilenameExtension!) preserves ten-second timeline with \(encodedCount) encoded frames")
}
