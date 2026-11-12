import Foundation
import UniformTypeIdentifiers
import ImageIO
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("ffmpeg unavailable") }
func run(_ args: [String]) -> Bool {
    let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
let seed = root.appendingPathComponent("source.mov")
guard let encoder = ExternalMediaConverter.h264Encoder(engine: engine) else { fatalError("H.264 encoder unavailable") }
precondition(run(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=12", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "0.4", "-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", seed.path]))
let converter = ExternalMediaConverter()
let targets = ExternalMediaConverter.videoTargets()
var inputs: [URL] = [seed]
for target in targets where target.preferredFilenameExtension != "mov" {
    do { let out = try converter.convert(input: seed, outputDirectory: root, format: target, video: true); inputs.append(out) }
    catch { print("FIXTURE_FAIL \(target.identifier): \(error)"); fflush(stdout); exit(1) }
}
// Include supported containers that the wheel accepts as inputs but does not
// emit, so the matrix covers source formats as well as destination formats.
let extraInputs: [(String, [String])] = [
    ("wmv", ["-c:v", "wmv2", "-c:a", "wmav2", "-f", "asf"]),
    ("ts", ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpegts"]),
    ("mts", ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpegts"]),
    ("m2ts", ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpegts"]),
    ("mpg", ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpeg"]),
    ("mpeg", ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpeg"]),
    ("3gp", ["-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "3gp"]),
    ("3g2", ["-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "3g2"])
]
for (ext, options) in extraInputs {
    let fixture = root.appendingPathComponent("fixture.\(ext)")
    guard run(["-i", seed.path] + options + [fixture.path]) else { print("FIXTURE_FAIL \(ext)"); exit(1) }
    inputs.append(fixture)
}
var passed = 0, failed = 0, extracted = 0, extractionFailed = 0
for input in inputs {
    let hasAudio = ExternalMediaConverter.videoTargets(for: [input]).contains(UTType(filenameExtension: "mp3")!)
    for target in targets {
        guard let ext = target.preferredFilenameExtension, ext != input.pathExtension.lowercased() else { continue }
        let folder = root.appendingPathComponent("out-\(UUID().uuidString)"); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let out = try converter.convert(input: input, outputDirectory: folder, format: target, video: true)
            guard run(["-i", out.path, "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"]) else { throw ExternalMediaError.failed }
            if ext == "gif" {
                guard let gif = CGImageSourceCreateWithURL(out as CFURL, nil), CGImageSourceGetCount(gif) > 1 else { throw ExternalMediaError.failed }
            } else if hasAudio { guard run(["-i", out.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]) else { throw ExternalMediaError.failed } }
            passed += 1; print("PASS \(input.pathExtension)->\(ext)")
        } catch { failed += 1; print("FAIL \(input.pathExtension)->\(ext): \(error)") }
        fflush(stdout)
    }
    if hasAudio {
        for target in ExternalMediaConverter.audioTargets() {
            let ext = ExternalMediaConverter.fileExtension(for: target) ?? "unknown"
            let folder = root.appendingPathComponent("audio-\(UUID().uuidString)"); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                let out = try converter.convert(input: input, outputDirectory: folder, format: target, video: false)
                guard run(["-i", out.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]) else { throw ExternalMediaError.failed }
                extracted += 1; print("PASS_AUDIO \(input.pathExtension)->\(ext)")
            } catch { extractionFailed += 1; print("FAIL_AUDIO \(input.pathExtension)->\(ext): \(error)") }
            fflush(stdout)
        }
    }
}
print("VIDEO_MATRIX passed=\(passed) failed=\(failed) audio_passed=\(extracted) audio_failed=\(extractionFailed)")
exit(failed == 0 && extractionFailed == 0 ? 0 : 1)
