import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-gif-timing-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { if ProcessInfo.processInfo.environment["MORIQ_KEEP_GIF_TEST"] != "1" { try? fm.removeItem(at: root) } }
if ProcessInfo.processInfo.environment["MORIQ_KEEP_GIF_TEST"] == "1" { print("FIXTURE=\(root.path)") }
let source = root.appendingPathComponent("source.gif")
let writer = CGImageDestinationCreateWithURL(source as CFURL, UTType.gif.identifier as CFString, 3, nil)!
let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
for (color, delay) in zip(colors, [0.1, 0.3, 0.6]) {
    let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
    CGImageDestinationAddImage(writer, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(writer))
let checkInput = CGImageSourceCreateWithURL(source as CFURL, nil)!
for index in 0..<3 {
 let image = CGImageSourceCreateImageAtIndex(checkInput, index, nil)!
 let color = NSBitmapImageRep(cgImage: image).colorAt(x: 40, y: 30)!.usingColorSpace(.deviceRGB)!
 let channels = [color.redComponent, color.greenComponent, color.blueComponent]
 guard channels[index] > 0.85 else { print("FAIL fixture frame \(index) RGB=\(channels)"); exit(1) }
}
let output = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: .gif, video: true)
let decoded = CGImageSourceCreateWithURL(output as CFURL, nil)!
let count = CGImageSourceGetCount(decoded)
precondition(count == 3, "frame count changed")
var durations: [Double] = []
for index in 0..<count {
    let props = CGImageSourceCopyPropertiesAtIndex(decoded, index, nil) as! [CFString: Any]
    let gif = props[kCGImagePropertyGIFDictionary] as! [CFString: Any]
    durations.append((gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? (gif[kCGImagePropertyGIFDelayTime] as! NSNumber).doubleValue)
    let image = CGImageSourceCreateImageAtIndex(decoded, index, nil)!
    let color = NSBitmapImageRep(cgImage: image).colorAt(x: 40, y: 30)!.usingColorSpace(.deviceRGB)!
    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
    guard channels[index] > 0.85 else { print("FAIL frame \(index) RGB=\(channels) durations=\(durations)"); exit(1) }
}
for (actual, expected) in zip(durations, [0.1, 0.3, 0.6]) { precondition(abs(actual - expected) < 0.011, "frame timing changed: \(durations)") }
print("PASS variable GIF frame durations and colors preserved")

// Check the rendered timeline as well as the encoded frame count. Some video
// muxers keep all three frames but truncate the last frame's display duration.
let engine = ExternalMediaConverter.executable!
var videoFailures = 0
let webp = root.appendingPathComponent("variable.webp")
try Data(base64Encoded: "UklGRrQAAABXRUJQVlA4WAoAAAACAAAATwAAOwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAE8AADsAAGQAAAJWUDhMDwAAAC9PwA4ABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAE8AADsAACwBAABWUDhMDwAAAC9PwA4AB9D/iP4HIqL/AQBBTk1GKAAAAAAAAAAAAE8AADsAAFgCAABWUDhMDwAAAC9PwA4ABxDR//4HIqL/AQA=")!.write(to: webp)
precondition(ExternalMediaConverter.animationResultNotice(input: webp, outputExtension: "mp4") == nil, "opaque WebP must not claim transparency loss")
let apng = root.appendingPathComponent("variable.png")
try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAFAAAAA8CAIAAAB+RarbAAAACGFjVEwAAAADAAAAAM7tusAAAAAaZmNUTAAAAAAAAABQAAAAPAAAAAAAAAAAAAEACgAA4360dwAAAHVJREFUeJzlzjEBADAMgDCGf8+di/YgCvKGFomRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGK8D2z68HAF3TH9TeQAAABpmY1RMAAAAAQAAAFAAAAA8AAAAAAAAAAAAAwAKAAACzQ3DAAAAeWZkQVQAAAACeJzlzjEBADAMgDCGf8+di/YgCvIYUiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYrwObPu7HQF3rBzRkgAAABpmY1RMAAAAAwAAAFAAAAA8AAAAAAAAAAAAAwAFAADkB5kXAAAAemZkQVQAAAAEeJzlzjEBADAMgDCGf8+di/YgCvJgKJEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYifE6sO0Duh4Bd0LblqsAAAAASUVORK5CYII=")!.write(to: apng)
for input in [source, webp, apng] {
if input != source {
    do {
        let result = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: .gif, video: true)
        guard let decoded = CGImageSourceCreateWithURL(result as CFURL, nil), CGImageSourceGetCount(decoded) == 3 else { throw ExternalMediaError.failed }
        var delays: [Double] = []
        for index in 0..<3 {
            let properties = CGImageSourceCopyPropertiesAtIndex(decoded, index, nil) as! [CFString: Any]
            let gif = properties[kCGImagePropertyGIFDictionary] as! [CFString: Any]
            delays.append((gif[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue)
            let image = CGImageSourceCreateImageAtIndex(decoded, index, nil)!
            let color = NSBitmapImageRep(cgImage: image).colorAt(x: 40, y: 30)!.usingColorSpace(.deviceRGB)!
            guard [color.redComponent, color.greenComponent, color.blueComponent][index] > 0.85 else { throw ExternalMediaError.failed }
        }
        guard zip(delays, [0.1, 0.3, 0.6]).allSatisfy({ abs($0 - $1) < 0.011 }) else {
            print("FAIL \(input.pathExtension) → GIF: durations \(delays)"); videoFailures += 1; continue
        }
        print("PASS \(input.pathExtension) → GIF: visible colors and variable timing")
    } catch { videoFailures += 1; print("FAIL \(input.pathExtension) → GIF: \(error)") }
}
for target in ExternalMediaConverter.videoTargets() where target != .gif {
    let label = target.preferredFilenameExtension ?? "unknown"
    let sourceLabel = input.pathExtension.uppercased()
    do {
        let video = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: target, video: true)
        let process = Process(); process.executableURL = engine
        process.arguments = ["-nostdin", "-v", "error", "-i", video.path, "-vf", "fps=100", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let frameBytes = 80 * 60 * 3
        let count = data.count / frameBytes
        guard process.terminationStatus == 0, (99...101).contains(count) else {
            print("FAIL \(sourceLabel) → \(label): expected about 100 displayed frames, got \(count)")
            videoFailures += 1; continue
        }
        for (frame, channel) in [(5, 0), (20, 1), (70, 2)] {
            let offset = frame * frameBytes
            let pixel = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
            guard pixel[channel] > 100 && pixel[channel] > pixel[(channel + 1) % 3] + 50 && pixel[channel] > pixel[(channel + 2) % 3] + 50 else {
                throw ExternalMediaError.failed
            }
        }
        print("PASS \(sourceLabel) → \(label): visible colors and variable timing")
    } catch {
        videoFailures += 1; print("FAIL \(sourceLabel) → \(label): \(error)")
    }
}
}
exit(videoFailures == 0 ? 0 : 1)
