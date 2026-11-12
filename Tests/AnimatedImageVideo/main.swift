import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-animated-image-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("animation.gif")
let gif = CGImageDestinationCreateWithURL(input as CFURL, UTType.gif.identifier as CFString, 2, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
 let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
 CGImageDestinationAddImage(gif, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(gif))
precondition(ExternalMediaConverter.isAnimatedImage(input))
let engine = ExternalMediaConverter.executable!
func samples(_ input: URL) throws -> ([UInt8], [UInt8]) {
 let p = Process(); p.executableURL = engine
 p.arguments = ["-nostdin", "-v", "error", "-i", input.path, "-vf", "fps=5", "-frames:v", "4", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 let frameBytes = 120 * 80 * 3
 guard p.terminationStatus == 0, data.count >= frameBytes * 3 else { throw ExternalMediaError.failed }
 return (Array(data.prefix(3)), Array(data[(frameBytes * 2)..<(frameBytes * 2 + 3)]))
}
func frameCount(_ input: URL) throws -> Int {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error", "-i", input.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", "-"]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
 guard p.terminationStatus == 0 else { throw ExternalMediaError.failed }
 return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.count
}
func make(_ arguments: [String]) -> Bool {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error", "-y"] + arguments
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
 do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
let apng = root.appendingPathComponent("animation.png")
let webp = root.appendingPathComponent("animation.webp")
precondition(make(["-i", input.path, "-plays", "0", "-f", "apng", apng.path]))
// Synthetic red/blue two-frame lossless WebP; the bundled encoder need not
// support creating animated WebP for the input-decoding test to be valid.
try Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAdwAATwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAHcAAE8AAJABAAJWUDhMDwAAAC93wBMABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAHcAAE8AAJABAABWUDhMDwAAAC93wBMABxDR//4HIqL/AQA=")!.write(to: webp)
let inputs = [input, apng, webp]
var failures = 0
for source in inputs {
 precondition(ExternalMediaConverter.isAnimatedImage(source), "animated \(source.pathExtension) not detected")
for target in ExternalMediaConverter.videoTargets() {
 do {
  let result = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: target, video: true)
  let (first, second) = try samples(result)
  guard Int(first[0]) > Int(first[2]) + 100 && Int(second[2]) > Int(second[0]) + 100 else { throw ExternalMediaError.failed }
  if ["mp4", "m4v", "mov"].contains(target.preferredFilenameExtension ?? "") { guard try frameCount(result) <= 3 else { throw ExternalMediaError.failed } }
  print("PASS animated \(source.pathExtension) → \(target.preferredFilenameExtension!) retains both frames")
 } catch { failures += 1; print("FAIL animated \(source.pathExtension) → \(target.preferredFilenameExtension ?? "?"): \(error)") }
}
}
precondition(inputs.allSatisfy { fm.fileExists(atPath: $0.path) })
exit(failures == 0 ? 0 : 1)
