import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-audio-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let encoder = ExternalMediaConverter.h264Encoder(engine: engine)!
func run(_ args: [String]) -> Bool {
    let process = Process(); process.executableURL = engine
    process.arguments = ["-nostdin", "-v", "error"] + args
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
}
let source = root.appendingPathComponent("source.mkv")
precondition(run(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-f", "lavfi", "-i", "sine=frequency=440", "-f", "lavfi", "-i", "sine=frequency=880", "-t", "0.4", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", source.path]))
let silent = root.appendingPathComponent("silent.mkv")
precondition(run(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-t", "0.4", "-c:v", encoder, "-pix_fmt", "yuv420p", silent.path]))
let formats = ExternalMediaConverter.audioTargets()
let audibleTargets = ExternalMediaConverter.videoTargets(for: [source])
let silentTargets = ExternalMediaConverter.videoTargets(for: [silent])
let mixedTargets = ExternalMediaConverter.videoTargets(for: [source, silent])
precondition(formats.allSatisfy { audibleTargets.contains($0) })
precondition(formats.allSatisfy { !silentTargets.contains($0) })
precondition(formats.allSatisfy { !mixedTargets.contains($0) })
for format in formats {
    let dir = root.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: dir, withIntermediateDirectories: false)
    let output = try ExternalMediaConverter().convert(input: source, outputDirectory: dir, format: format, video: false)
    let folder = (try output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    if folder {
        let tracks = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        precondition(tracks.count == 2 && tracks.allSatisfy { run(["-i", $0.path, "-frames:a", "1", "-f", "null", "-"]) })
    } else {
        precondition(run(["-i", output.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]))
        precondition(run(["-i", output.path, "-map", "0:a:1", "-frames:a", "1", "-f", "null", "-"]))
    }
    print("PASS video audio tracks → \(ExternalMediaConverter.fileExtension(for: format)!)")
}
precondition(fm.fileExists(atPath: source.path))
print("PASS silent inputs hide audio targets and source remains intact")
