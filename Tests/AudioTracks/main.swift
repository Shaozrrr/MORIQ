import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-audio-tracks-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("ffmpeg unavailable") }
func run(_ args: [String]) -> Bool {
    let process = Process(); process.executableURL = engine
    process.arguments = ["-nostdin", "-v", "error"] + args
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
}
let input = root.appendingPathComponent("source.mka")
precondition(run(["-f", "lavfi", "-i", "sine=frequency=440", "-f", "lavfi", "-i", "sine=frequency=880", "-t", "0.3", "-map", "0:a", "-map", "1:a", "-c:a", "pcm_s16le", input.path]))
var failures = 0
for ext in ["mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "caf"] {
    let folder = root.appendingPathComponent(ext)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    let type = ext == "opus" ? ExternalMediaConverter.opusType : UTType(filenameExtension: ext)!
    let supportsMultiple = ["m4a", "ogg", "opus"].contains(ext)
    do {
        let output = try ExternalMediaConverter().convert(input: input, outputDirectory: folder, format: type, video: false)
        if supportsMultiple {
            guard run(["-i", output.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]), run(["-i", output.path, "-map", "0:a:1", "-frames:a", "1", "-f", "null", "-"]) else { throw ExternalMediaError.failed }
            print("PASS both audio tracks → \(ext)")
        } else {
            let tracks = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard tracks.count == 2, tracks.allSatisfy({ run(["-i", $0.path, "-frames:a", "1", "-f", "null", "-"]) }) else { throw ExternalMediaError.failed }
            for (index, track) in tracks.enumerated() {
                let raw = folder.appendingPathComponent("track-\(index).raw")
                guard run(["-i", track.path, "-ac", "1", "-ar", "44100", "-f", "s16le", raw.path]) else { throw ExternalMediaError.failed }
                let bytes = [UInt8](try Data(contentsOf: raw)); try fm.removeItem(at: raw)
                let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
                let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
                let expected = index == 0 ? 132 : 264
                guard abs(crossings - expected) < 15 else { throw ExternalMediaError.failed }
            }
            let second = try ExternalMediaConverter().convert(input: input, outputDirectory: folder, format: type, video: false)
            guard second != output, fm.fileExists(atPath: output.path) else { throw ExternalMediaError.failed }
            print("PASS split tracks and protect output → \(ext)")
        }
    } catch {
        failures += 1; print("FAIL \(ext): \(error)")
    }
}
precondition(fm.fileExists(atPath: input.path), "source removed")
exit(failures == 0 ? 0 : 1)
