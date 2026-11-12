import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-tracks-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let h264 = ExternalMediaConverter.h264Encoder(engine: engine)!
func run(_ args: [String]) -> Bool {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
 do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
let sub = root.appendingPathComponent("sub.srt")
try "1\n00:00:00,000 --> 00:00:00,500\nMORIQ subtitle 4826\n".write(to: sub, atomically: true, encoding: .utf8)
let source = root.appendingPathComponent("source.mkv")
precondition(run(["-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-f", "lavfi", "-i", "sine=frequency=440", "-f", "lavfi", "-i", "sine=frequency=880", "-i", sub.path, "-t", "0.6", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "srt", source.path]))
var failures = 0
for ext in ["mp4", "mov", "m4v", "mkv", "webm"] {
 do {
  let folder = root.appendingPathComponent(ext); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
  let output = try ExternalMediaConverter().convert(input: source, outputDirectory: folder, format: UTType(filenameExtension: ext)!, video: true)
  let subtitle = folder.appendingPathComponent("readback.srt")
  guard run(["-i", output.path, "-map", "0:a:1", "-frames:a", "1", "-f", "null", "-"]), run(["-i", output.path, "-map", "0:s:0", subtitle.path]), (try String(contentsOf: subtitle, encoding: .utf8)).contains("MORIQ subtitle 4826") else { throw ExternalMediaError.failed }
  print("PASS both audio tracks and subtitle → \(ext)")
 } catch { failures += 1; print("FAIL tracks → \(ext): \(error)") }
}
exit(failures == 0 ? 0 : 1)
