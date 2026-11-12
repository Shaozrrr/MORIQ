import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-float-tracks-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
func output(_ args: [String]) throws -> Data {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 guard p.terminationStatus == 0 else { throw ExternalMediaError.failed }; return data
}
var failures = 0
for depth in [32, 64] {
 let input = root.appendingPathComponent("source-\(depth).mka")
 _ = try output(["-f", "lavfi", "-i", "aevalsrc=1.2*sin(2*PI*440*t):s=48000:d=0.2", "-f", "lavfi", "-i", "aevalsrc=1.3*sin(2*PI*880*t):s=48000:d=0.2", "-map", "0:a", "-map", "1:a", "-c:a", "pcm_f\(depth)le", input.path])
 let references = try (0...1).map { try output(["-i", input.path, "-map", "0:a:\($0)", "-f", "f64le", "-"]) }
 for ext in ["wav", "aiff", "caf"] {
  do {
   let result = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: UTType(filenameExtension: ext)!, video: false)
   let tracks = try fm.contentsOfDirectory(at: result, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
   guard tracks.count == 2 else { throw ExternalMediaError.failed }
   for index in 0...1 {
    let decoded = try output(["-i", tracks[index].path, "-f", "f64le", "-"])
    guard decoded == references[index] else { throw ExternalMediaError.failed }
   }
   print("PASS float\(depth) MKA tracks → \(ext)")
  } catch { failures += 1; print("FAIL float\(depth) → \(ext): \(error)") }
 }
 do {
  _ = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "flac")!, video: false)
  failures += 1; print("FAIL float FLAC silently quantized")
 } catch AudioConversionError.precisionUnsupported { print("PASS float MKA → FLAC precision warning") }
}
// Different PCM types in one container must not quantize the integer track.
let mixed = root.appendingPathComponent("mixed.mka")
_ = try output(["-f", "lavfi", "-i", "aevalsrc=1.2*sin(2*PI*440*t):s=48000:d=0.2", "-f", "lavfi", "-i", "aevalsrc=0.123456789*sin(2*PI*880*t):s=48000:d=0.2", "-map", "0:a", "-map", "1:a", "-c:a:0", "pcm_f32le", "-c:a:1", "pcm_s32le", mixed.path])
do {
 let refs = try (0...1).map { try output(["-i", mixed.path, "-map", "0:a:\($0)", "-f", "f64le", "-"]) }
 let folder = try ExternalMediaConverter().convert(input: mixed, outputDirectory: root, format: UTType(filenameExtension: "wav")!, video: false)
 let tracks = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
 guard tracks.count == 2 else { throw ExternalMediaError.failed }
 for index in 0...1 {
  let decoded = try output(["-i", tracks[index].path, "-f", "f64le", "-"])
  guard decoded == refs[index] else { throw ExternalMediaError.failed }
 }
 print("PASS mixed float32 and int32 tracks → wav without quantization")
} catch { failures += 1; print("FAIL mixed precision: \(error)") }
exit(failures == 0 ? 0 : 1)
