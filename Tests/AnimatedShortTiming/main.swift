import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-short-animation-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("short.gif")
let writer = CGImageDestinationCreateWithURL(input as CFURL, UTType.gif.identifier as CFString, 3, nil)!
let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
for (color, delay) in zip(colors, [0.01, 0.02, 0.04]) {
    let ctx = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
    CGImageDestinationAddImage(writer, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(writer))
let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
let inputDelays = (0..<3).map { index -> Double in
    let p = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as! [CFString: Any]
    let g = p[kCGImagePropertyGIFDictionary] as! [CFString: Any]
    return (g[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue
}
guard zip(inputDelays, [0.01, 0.02, 0.04]).allSatisfy({ abs($0 - $1) < 0.001 }) else { fatalError("fixture timing \(inputDelays)") }
let engine = ExternalMediaConverter.executable!
var failures = 0
do {
    let output = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: .gif, video: true)
    guard let result = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(result) == 3 else { throw ExternalMediaError.failed }
    let delays = (0..<3).map { index -> Double in
        let p = CGImageSourceCopyPropertiesAtIndex(result, index, nil) as! [CFString: Any]
        let gif = p[kCGImagePropertyGIFDictionary] as! [CFString: Any]
        return (gif[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue
    }
    guard zip(delays, [0.01, 0.02, 0.04]).allSatisfy({ abs($0 - $1) < 0.001 }) else {
        print("FAIL gif: timing \(delays)"); failures += 1; throw ExternalMediaError.failed
    }
    print("PASS gif: 10/20/40 ms frames")
} catch { failures += 1; print("FAIL gif: \(error)") }
for target in ExternalMediaConverter.videoTargets() where target != .gif {
    let ext = target.preferredFilenameExtension ?? "unknown"
    do {
        let output = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: target, video: true)
        let process = Process(); process.executableURL = engine
        process.arguments = ["-nostdin", "-v", "error", "-i", output.path, "-vf", "fps=100", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let stride = 80 * 60 * 3, count = data.count / stride
        guard process.terminationStatus == 0, count == 7 else { print("FAIL \(ext): \(count) samples instead of 7"); failures += 1; continue }
        for (frame, channel) in [(0, 0), (1, 1), (2, 1), (3, 2), (6, 2)] {
            let offset = frame * stride
            let pixel = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
            guard pixel[channel] > 100 && pixel[channel] > pixel[(channel + 1) % 3] + 50 && pixel[channel] > pixel[(channel + 2) % 3] + 50 else { throw ExternalMediaError.failed }
        }
        print("PASS \(ext): 10/20/40 ms frames")
    } catch { failures += 1; print("FAIL \(ext): \(error)") }
}
exit(failures == 0 ? 0 : 1)
