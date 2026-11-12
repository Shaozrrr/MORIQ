import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-picture-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let h264 = ExternalMediaConverter.h264Encoder(engine: engine)!
func run(_ args: [String]) -> Bool {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
 do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
func sample(_ input: URL, track: Int) throws -> [UInt8] {
 let p = Process(); p.executableURL = engine
 p.arguments = ["-nostdin", "-v", "error", "-i", input.path, "-map", "0:v:\(track)", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 guard p.terminationStatus == 0, data.count >= 3 else { throw ExternalMediaError.failed }
 return Array(data.prefix(3))
}
let source = root.appendingPathComponent("source.mkv")
precondition(run(["-f", "lavfi", "-i", "color=red:size=160x120:rate=10", "-f", "lavfi", "-i", "color=blue:size=120x80:rate=10", "-t", "0.4", "-map", "0:v", "-map", "1:v", "-c:v", h264, "-pix_fmt", "yuv420p", source.path]))
var failures = 0
for ext in ["mp4", "mov", "m4v", "mkv", "webm"] {
 do {
  let folder = root.appendingPathComponent(ext); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
  let output = try ExternalMediaConverter().convert(input: source, outputDirectory: folder, format: UTType(filenameExtension: ext)!, video: true)
  guard run(["-i", output.path, "-map", "0:v:1", "-frames:v", "1", "-f", "null", "-"]) else { throw ExternalMediaError.failed }
  let red = try sample(output, track: 0), blue = try sample(output, track: 1)
  guard red[0] > red[2] + 100, blue[2] > blue[0] + 100 else { throw ExternalMediaError.failed }
  print("PASS distinct video tracks → \(ext)")
 } catch { failures += 1; print("FAIL second video track → \(ext): \(error)") }
}
exit(failures == 0 ? 0 : 1)
