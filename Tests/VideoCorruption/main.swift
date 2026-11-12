import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-corrupt-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let encoder = ExternalMediaConverter.h264Encoder(engine: engine)!
let valid = root.appendingPathComponent("valid.mp4")
let generate = Process(); generate.executableURL = engine
generate.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=12", "-t", "2", "-c:v", encoder, "-pix_fmt", "yuv420p", "-movflags", "+faststart", valid.path]
try generate.run(); generate.waitUntilExit(); precondition(generate.terminationStatus == 0)
let bytes = try Data(contentsOf: valid)
let broken = root.appendingPathComponent("broken.mp4")
try bytes.prefix(bytes.count * 2 / 3).write(to: broken)
do {
    _ = try ExternalMediaConverter().convert(input: broken, outputDirectory: root, format: UTType(filenameExtension: "mkv")!, video: true)
    fatalError("corrupt input produced a successful output")
} catch ExternalMediaError.failed { }
let names = try fm.contentsOfDirectory(atPath: root.path)
precondition(!names.contains("broken.mkv") && !names.contains { $0.hasPrefix(".moriq-") })
let preserved = try Data(contentsOf: broken)
precondition(preserved == bytes.prefix(bytes.count * 2 / 3))
print("PASS corrupt video fails without publishing partial output or changing source")
