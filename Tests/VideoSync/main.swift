import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-video-sync-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let engine = ExternalMediaConverter.executable!
let encoder = ExternalMediaConverter.h264Encoder(engine: engine)!
func run(_ arguments: [String], capture: Bool = false) -> (Int32, Data) {
    let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + arguments
    let pipe = Pipe(); p.standardOutput = capture ? pipe : FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data(); p.waitUntilExit(); return (p.terminationStatus, data) }
    catch { return (-1, Data()) }
}
let source = root.appendingPathComponent("sync.mkv")
let args = ["-f", "lavfi", "-i", "color=black:s=160x120:r=10:d=3", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3", "-vf", "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t,1,2)'", "-af", "volume=0:enable='lt(t,1)+gte(t,2)'", "-c:v", encoder, "-pix_fmt", "yuv420p", "-c:a", "aac", source.path]
precondition(run(args).0 == 0)
func videoBrightness(_ file: URL, _ time: Double) -> Double? {
    let result = run(["-ss", "\(time)", "-i", file.path, "-frames:v", "1", "-vf", "scale=1:1,format=gray", "-f", "rawvideo", "-"], capture: true)
    return result.0 == 0 ? result.1.first.map(Double.init) : nil
}
func audioLevel(_ file: URL, _ time: Double) -> Double? {
    let result = run(["-ss", "\(time)", "-i", file.path, "-t", "0.1", "-map", "0:a:0", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"], capture: true)
    guard result.0 == 0, result.1.count > 100 else { return nil }
    let bytes = [UInt8](result.1); var sum = 0.0
    for i in stride(from: 0, to: bytes.count - 1, by: 2) { sum += abs(Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))) }
    return sum / Double(bytes.count / 2)
}
for ext in ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv"] {
    let directory = root.appendingPathComponent(ext); try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    let result = try ExternalMediaConverter().convert(input: source, outputDirectory: directory, format: UTType(filenameExtension: ext)!, video: true)
    guard let beforeV = videoBrightness(result, 0.8), let startV = videoBrightness(result, 1.2), let endV = videoBrightness(result, 1.8), let afterV = videoBrightness(result, 2.2),
          let beforeA = audioLevel(result, 0.8), let startA = audioLevel(result, 1.2), let endA = audioLevel(result, 1.8), let afterA = audioLevel(result, 2.2),
          beforeV < 40, startV > 200, endV > 200, afterV < 40, beforeA < 300, startA > 1000, endA > 1000, afterA < 300 else {
        print("FAIL sync windows → \(ext)"); exit(1)
    }
    print("PASS synchronized flash and tone near both transitions → \(ext)")
}
