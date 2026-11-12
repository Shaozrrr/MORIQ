import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-odd-video-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("ffmpeg unavailable") }
func run(_ args: [String]) -> Bool {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
 do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}
let input = root.appendingPathComponent("odd.mkv")
precondition(run(["-f", "lavfi", "-i", "testsrc=size=161x121:rate=10", "-t", "0.3", "-c:v", "ffv1", input.path]))
var failures = 0
for target in ExternalMediaConverter.videoTargets() {
 do {
  let dir = root.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: dir, withIntermediateDirectories: false)
  let out = try ExternalMediaConverter().convert(input: input, outputDirectory: dir, format: target, video: true)
  guard run(["-i", out.path, "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"]) else { throw ExternalMediaError.failed }
  print("PASS odd → \(target.preferredFilenameExtension ?? "?")")
 } catch { failures += 1; print("FAIL odd → \(target.preferredFilenameExtension ?? "?"): \(error)") }
}
exit(failures == 0 ? 0 : 1)
