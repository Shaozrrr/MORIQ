import Foundation
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-gif-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!, encoder = ExternalMediaConverter.h264Encoder(engine: ExternalMediaConverter.executable!)!
let source = root.appendingPathComponent("source.mp4")
let p = Process(); p.executableURL = engine
p.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "1", "-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", source.path]
try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
let bytes = try Data(contentsOf: source)
let result = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: .gif, video: true)
let sourceGIF = CGImageSourceCreateWithURL(result as CFURL, nil)!
let count = CGImageSourceGetCount(sourceGIF)
precondition(count >= 9 && count <= 11, "GIF must retain animation frames")
var total = 0.0
for index in 0..<count {
    let props = CGImageSourceCopyPropertiesAtIndex(sourceGIF, index, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
    let frame = CGImageSourceCreateImageAtIndex(sourceGIF, index, nil)!
    precondition(frame.width == 160 && frame.height == 120)
}
precondition(total > 0.8 && total < 1.2, "GIF duration changed")
let after = try Data(contentsOf: source); precondition(after == bytes)
print("PASS video → animated GIF preserves size, frame count and duration; source intact")
