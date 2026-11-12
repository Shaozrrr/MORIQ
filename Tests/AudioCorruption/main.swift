import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-audio-corrupt-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let valid = root.appendingPathComponent("valid.wav")
let generate = Process(); generate.executableURL = engine
generate.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", valid.path]
try generate.run(); generate.waitUntilExit(); precondition(generate.terminationStatus == 0)
let bytes = try Data(contentsOf: valid)
let broken = root.appendingPathComponent("broken.wav")
try bytes.dropLast(137).write(to: broken)
do {
    _ = try ExternalMediaConverter().convert(input: broken, outputDirectory: root, format: UTType(filenameExtension: "mp3")!, video: false)
    fatalError("corrupt input produced a successful output")
} catch ExternalMediaError.failed { }
let names = try fm.contentsOfDirectory(atPath: root.path)
precondition(!names.contains("broken.mp3") && !names.contains { $0.hasPrefix(".moriq-") })
let preserved = try Data(contentsOf: broken)
precondition(preserved == bytes.dropLast(137))
print("PASS corrupt audio fails without publishing partial output or changing source")
