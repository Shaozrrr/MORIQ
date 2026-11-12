import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-audio-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("ffmpeg unavailable") }
func run(_ args: [String]) -> Bool {
    let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
let seed = root.appendingPathComponent("source.wav")
precondition(run(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "0.3", seed.path]))
let converter = ExternalMediaConverter()
let targets = ExternalMediaConverter.audioTargets()
var inputs: [URL] = [seed]
for target in targets where ExternalMediaConverter.fileExtension(for: target) != "wav" {
    do { let out = try converter.convert(input: seed, outputDirectory: root, format: target, video: false); inputs.append(out) }
    catch { print("FIXTURE_FAIL \(target.identifier): \(error)"); fflush(stdout); exit(1) }
}
// Accepted input formats that are not wheel output targets must be exercised
// as sources too; otherwise the matrix misses nearly half its declared pairs.
let additionalSources: [(String, [String])] = [
    ("aif", ["-c:a", "pcm_s16be", "-f", "aiff"]),
    ("aifc", ["-c:a", "pcm_f32be", "-f", "aiff"]),
    ("aac", ["-c:a", "aac", "-f", "adts"]),
    ("alac", ["-c:a", "alac", "-f", "ipod"]),
    ("oga", ["-c:a", "libvorbis", "-f", "ogg"]),
    ("wma", ["-c:a", "wmav2", "-f", "asf"]),
    ("ac3", ["-c:a", "ac3", "-f", "ac3"]),
    ("mka", ["-c:a", "flac", "-f", "matroska"])
]
for (ext, codec) in additionalSources {
    let file = root.appendingPathComponent("fixture.\(ext)")
    guard run(["-i", seed.path] + codec + [file.path]) else { print("FIXTURE_FAIL \(ext)"); exit(1) }
    inputs.append(file)
}
func codecDescription(_ url: URL) -> String {
    let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-hide_banner", "-i", url.path]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice
    do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(data: data, encoding: .utf8) ?? "" } catch { return "" }
}
var passed = 0, failed = 0
for input in inputs {
    let eligible = ExternalMediaConverter.audioTargets(for: [input])
    if input.pathExtension == "aifc" {
        precondition(!eligible.contains { ExternalMediaConverter.fileExtension(for: $0) == "flac" })
        precondition(!ExternalMediaConverter.audioTargets(for: [seed, input]).contains { ExternalMediaConverter.fileExtension(for: $0) == "flac" })
        print("PASS floating-point input hides lossy FLAC conversion, including mixed selection")
    }
    for target in targets {
        guard let ext = ExternalMediaConverter.fileExtension(for: target), ext != input.pathExtension.lowercased() else { continue }
        if !eligible.contains(target) { print("NOT_OFFERED \(input.pathExtension)->\(ext): precision protection"); continue }
        let folder = root.appendingPathComponent("out-\(UUID().uuidString)"); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let out = try converter.convert(input: input, outputDirectory: folder, format: target, video: false)
            guard run(["-i", out.path, "-t", "0.1", "-f", "null", "-"]) else { throw ExternalMediaError.failed }
            if ext == "opus" && !codecDescription(out).contains("Audio: opus") { throw ExternalMediaError.failed }
            if ext == "ogg" && !codecDescription(out).contains("Audio: vorbis") { throw ExternalMediaError.failed }
            passed += 1; print("PASS \(input.pathExtension)->\(ext)")
        } catch { failed += 1; print("FAIL \(input.pathExtension)->\(ext): \(error)") }
        fflush(stdout)
    }
}
print("AUDIO_MATRIX passed=\(passed) failed=\(failed)")
exit(failed == 0 ? 0 : 1)
