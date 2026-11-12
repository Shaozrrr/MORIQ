import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-stereo-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
func run(_ args: [String], capture: Bool = false) -> (Int32,String) {
 let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-hide_banner"] + args
 let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice
 do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return (p.terminationStatus,String(decoding: data, as: UTF8.self)) } catch { return (-1, "") }
}
func distinctChannels(_ input: URL) throws -> Bool {
 let p = Process(); p.executableURL = engine
 p.arguments = ["-nostdin", "-v", "error", "-i", input.path, "-t", "0.5", "-f", "f32le", "-acodec", "pcm_f32le", "-"]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 guard p.terminationStatus == 0, data.count >= 8000 else { return false }
 let values = [UInt8](data); var differences = 0
 for offset in stride(from: 0, to: min(values.count - 7, 32000), by: 8) {
  func float(_ i: Int) -> Float { let bits = UInt32(values[i]) | UInt32(values[i+1]) << 8 | UInt32(values[i+2]) << 16 | UInt32(values[i+3]) << 24; return Float(bitPattern: bits) }
  if abs(float(offset) - float(offset + 4)) > 0.05 { differences += 1 }
 }
 return differences > 100
}
let source = root.appendingPathComponent("stereo.wav")
precondition(run(["-f", "lavfi", "-i", "aevalsrc=0.5*sin(2*PI*440*t)|0.5*sin(2*PI*880*t):s=48000:d=1", "-c:a", "pcm_s16le", source.path]).0 == 0)
var fails = 0
for type in ExternalMediaConverter.audioTargets() {
 let ext = ExternalMediaConverter.fileExtension(for: type)!
 do {
  let output = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: type, video: false)
  let details = run(["-i", output.path]).1
  guard details.contains("48000 Hz"), details.contains("stereo"), details.contains("Duration: 00:00:01."), try distinctChannels(output) else { print("FAIL \(ext): \(details)"); fails += 1; continue }
  print("PASS distinct stereo channels, 48 kHz, duration → \(ext)")
 } catch { fails += 1; print("FAIL \(ext): \(error)") }
}
exit(fails == 0 ? 0 : 1)
