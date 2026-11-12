import Foundation
import AVFoundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-audio-depth-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
func output(_ args: [String]) throws -> Data {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw ExternalMediaError.failed }; return data
}
var failed = 0
for depth in [24, 32] {
let source = root.appendingPathComponent("source-\(depth).wav")
_ = try output(["-f", "lavfi", "-i", "aevalsrc=0.34*sin(2*PI*997*t):s=48000:d=0.2", "-c:a", depth == 24 ? "pcm_s24le" : "pcm_s32le", source.path])
let reference = try output(["-i", source.path, "-f", "s32le", "-"])
for ext in ["wav", "aiff", "caf", "flac"] {
 do {
  let converted: URL
  if ProcessInfo.processInfo.environment["MORIQ_TEST_NATIVE_AUDIO"] == "1" { converted = try AudioConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: ext)!) }
  else { converted = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: ext)!, video: false) }
  let decoded = try output(["-i", converted.path, "-f", "s32le", "-"])
  guard decoded == reference else { throw ExternalMediaError.failed }
  if ext == "flac" && depth == 32 && ProcessInfo.processInfo.environment["MORIQ_TEST_NATIVE_AUDIO"] != "1" {
   print((try? AVAudioFile(forReading: converted)) != nil ? "INFO system can read 32-bit FLAC" : "INFO system cannot read 32-bit FLAC")
  }
  print("PASS exact \(depth)-bit PCM → \(ext)")
 } catch AudioConversionError.precisionUnsupported where depth == 32 && ext == "flac" && ProcessInfo.processInfo.environment["MORIQ_TEST_NATIVE_AUDIO"] == "1" {
  print("PASS refuses lossy native 32-bit FLAC")
 } catch { failed += 1; print("FAIL exact \(depth)-bit PCM → \(ext): \(error)") }
}
}
exit(failed == 0 ? 0 : 1)
