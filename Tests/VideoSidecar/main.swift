import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-sidecar-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let h264 = ExternalMediaConverter.h264Encoder(engine: engine)!
func run(_ args: [String]) -> Bool {
    let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
func firstTimestamp(_ url: URL, stream: String, audio: Bool) -> Double? {
    let p = Process(); p.executableURL = engine
    p.arguments = ["-nostdin", "-hide_banner", "-copyts", "-i", url.path, "-map", stream, audio ? "-af" : "-vf", audio ? "ashowinfo" : "showinfo", audio ? "-frames:a" : "-frames:v", "1", "-f", "null", "-"]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8), let rx = try? NSRegularExpression(pattern: #"pts_time:\s*([-+0-9.]+)"#), let match = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
    return Double(text[range])
}
let subtitle = root.appendingPathComponent("subtitle.srt")
try "1\n00:00:00,000 --> 00:00:00,500\nMORIQ subtitle 4826\n".write(to: subtitle, atomically: true, encoding: .utf8)
let source = root.appendingPathComponent("source.mkv")
precondition(run(["-f", "lavfi", "-i", "color=red:s=160x120:r=10", "-f", "lavfi", "-i", "color=blue:s=160x120:r=10", "-f", "lavfi", "-i", "sine=frequency=440", "-itsoffset", "0.3", "-f", "lavfi", "-i", "sine=frequency=880", "-i", subtitle.path, "-t", "0.8", "-map", "0:v", "-map", "1:v", "-map", "2:a", "-map", "3:a", "-map", "4:s", "-map", "4:s", "-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "srt", source.path]))
let sourceData = try Data(contentsOf: source)
for ext in ["avi", "flv"] {
    let destination = root.appendingPathComponent(ext); try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let existing = destination.appendingPathComponent("source 转换结果", isDirectory: true)
    try fm.createDirectory(at: existing, withIntermediateDirectories: false)
    let sentinel = existing.appendingPathComponent("保留.txt"); try Data("unchanged".utf8).write(to: sentinel)
    let result = try ExternalMediaConverter().convert(input: source, outputDirectory: destination, format: UTType(filenameExtension: ext)!, video: true)
    precondition(result.lastPathComponent == "source 转换结果 (2)")
    let video = result.appendingPathComponent("视频.\(ext)"), extraVideo = result.appendingPathComponent("画面 2.mkv")
    let extraAudio = result.appendingPathComponent("音轨 2.mka")
    precondition(run(["-i", video.path, "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"]))
    precondition(run(["-i", video.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]))
    precondition(run(["-i", extraVideo.path, "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"]))
    precondition(run(["-i", extraAudio.path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]))
    guard let originalStart = firstTimestamp(source, stream: "0:a:1", audio: true), let sidecarStart = firstTimestamp(extraAudio, stream: "0:a:0", audio: true), abs(originalStart - sidecarStart) < 0.03 else { fatalError("second audio timestamp changed") }
    print("PASS \(ext) delayed second audio timestamp retained")
    for i in 1...2 {
        let sub = result.appendingPathComponent("字幕 \(i).mks"), readback = destination.appendingPathComponent("readback-\(i).srt")
        precondition(run(["-i", sub.path, "-map", "0:s:0", readback.path]))
        let text = try String(contentsOf: readback, encoding: .utf8)
        precondition(text.contains("MORIQ subtitle 4826"))
    }
    let sourceAfter = try Data(contentsOf: source), sentinelAfter = try Data(contentsOf: sentinel)
    precondition(sourceAfter == sourceData && sentinelAfter == Data("unchanged".utf8))
    print("PASS \(ext): main video and audio plus second video/audio and subtitle; source and existing folder preserved")
}
// Attachments can contain fonts needed for styled subtitles; don't claim a
// complete result if the sidecar path cannot preserve them.
let attachment = root.appendingPathComponent("font.dat")
try Data("fixture attachment".utf8).write(to: attachment)
let attached = root.appendingPathComponent("attached.mkv")
precondition(run(["-i", source.path, "-map", "0", "-c", "copy", "-attach", attachment.path, "-metadata:s:t", "mimetype=application/octet-stream", attached.path]))
let rejected = root.appendingPathComponent("unsupported"); try fm.createDirectory(at: rejected, withIntermediateDirectories: false)
do {
    _ = try ExternalMediaConverter().convert(input: attached, outputDirectory: rejected, format: UTType(filenameExtension: "flv")!, video: true)
    fatalError("attachment must not be discarded")
} catch {
    precondition((try? fm.contentsOfDirectory(atPath: rejected.path))?.isEmpty == true)
    print("PASS unsupported attachment fails without leaving partial output")
}
let simpleAttached = root.appendingPathComponent("simple-attached.mkv")
precondition(run(["-i", source.path, "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-attach", attachment.path, "-metadata:s:t", "mimetype=application/octet-stream", simpleAttached.path]))
for ext in ["mp4", "avi", "flv"] {
    let destination = root.appendingPathComponent("attachment-\(ext)")
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
        _ = try ExternalMediaConverter().convert(input: simpleAttached, outputDirectory: destination, format: UTType(filenameExtension: ext)!, video: true)
        fatalError("attachment must not be silently discarded in fast path")
    } catch ExternalMediaError.unsupportedTracks {
        precondition((try? fm.contentsOfDirectory(atPath: destination.path))?.isEmpty == true)
        print("PASS \(ext) fast path rejects attachment without partial output")
    }
}
