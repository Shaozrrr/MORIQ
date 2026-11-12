import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-float-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
func output(_ args: [String]) throws -> Data {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw ExternalMediaError.failed }; return data
}
let native = ProcessInfo.processInfo.environment["MORIQ_TEST_NATIVE_AUDIO"] == "1"
var failed = 0
for depth in [32,64] {
 let source = root.appendingPathComponent("source-\(depth).wav")
 _ = try output(["-f", "lavfi", "-i", "aevalsrc=1.2*sin(2*PI*997*t):s=48000:d=0.2", "-c:a", depth == 32 ? "pcm_f32le" : "pcm_f64le", source.path])
 let reference = try output(["-i", source.path, "-f", "f64le", "-"])
 do {
  if native { _ = try AudioConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "flac")!) }
  else { _ = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "flac")!, video: false) }
  failed += 1; print("FAIL float FLAC silently quantized")
 } catch AudioConversionError.precisionUnsupported { print("PASS float FLAC rejected without quantization") }
 for ext in ["wav", "aiff", "caf"] {
  do {
   let type = UTType(filenameExtension: ext)!
   let converted = try native ? AudioConverter().convert(input: source, outputDirectory: root, format: type) : ExternalMediaConverter().convert(input: source, outputDirectory: root, format: type, video: false)
   let decoded = try output(["-i", converted.path, "-f", "f64le", "-"])
   guard decoded == reference else { throw ExternalMediaError.failed }
   print("PASS exact float\(depth) → \(ext)")
  } catch { failed += 1; print("FAIL float\(depth) → \(ext): \(error)") }
 }
}
exit(failed == 0 ? 0 : 1)
