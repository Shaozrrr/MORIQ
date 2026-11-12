import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-short-animation-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("fractional.png")
try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAFAAAAA8CAIAAAB+RarbAAAACGFjVEwAAAADAAAAAM7tusAAAAAaZmNUTAAAAAAAAABQAAAAPAAAAAAAAAAAAAEAPAAAw5gtVQAAAHVJREFUeJzlzjEBADAMgDCGf8+di/YgCvKGFomRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGK8D2z68HAF3TH9TeQAAABpmY1RMAAAAAQAAAFAAAAA8AAAAAAAAAAAAAgA8AAAfS71RAAAAeWZkQVQAAAACeJzlzjEBADAMgDCGf8+di/YgCvIYUiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYrwObPu7HQF3rBzRkgAAABpmY1RMAAAAAwAAAFAAAAA8AAAAAAAAAAAABAA8AAB9nZsYAAAAemZkQVQAAAAEeJzlzjEBADAMgDCGf8+di/YgCvJgKJEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYifE6sO0Duh4Bd0LblqsAAAAASUVORK5CYII=")!.write(to: input)
let engine = ExternalMediaConverter.executable!
var failures = 0
for target in ExternalMediaConverter.videoTargets() where target != .gif {
    let ext = target.preferredFilenameExtension ?? "unknown"
    do {
        let output = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: target, video: true)
        let process = Process(); process.executableURL = engine
        process.arguments = ["-nostdin", "-v", "error", "-i", output.path, "-vf", "fps=60", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let stride = 80 * 60 * 3, count = data.count / stride
        guard process.terminationStatus == 0, count == 7 else { print("FAIL \(ext): \(count) samples instead of 7"); failures += 1; continue }
        for (frame, channel) in [(0, 0), (1, 1), (2, 1), (3, 2), (6, 2)] {
            let offset = frame * stride
            let pixel = [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
            guard pixel[channel] > 100 && pixel[channel] > pixel[(channel + 1) % 3] + 50 && pixel[channel] > pixel[(channel + 2) % 3] + 50 else { throw ExternalMediaError.failed }
        }
        print("PASS \(ext): APNG 1/60, 2/60, 4/60 seconds")
    } catch { failures += 1; print("FAIL \(ext): \(error)") }
}
exit(failures == 0 ? 0 : 1)
