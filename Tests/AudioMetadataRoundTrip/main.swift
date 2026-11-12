import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-meta-escapes-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("no ffmpeg") }
func run(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = engine; p.arguments = ["-nostdin", "-v", "error"] + args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit(); return p.terminationStatus
}
let input = root.appendingPathComponent("多轨.mka")
let created = run(["-f","lavfi","-i","sine=frequency=440", "-f","lavfi","-i","sine=frequency=880", "-t","0.2", "-map","0:a", "-map","1:a", "-metadata:s:a:0","title=第一行\n第二行=\\;# 中文", "-metadata:s:a:1","title=第二轨🎵", "-c:a","pcm_s16le", input.path])
precondition(created == 0)
let collision = root.appendingPathComponent("多轨 转换结果"); try fm.createDirectory(at: collision, withIntermediateDirectories: false)
try Data("保留".utf8).write(to: collision.appendingPathComponent("sentinel"))
let result = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "m4a")!, video: false)
precondition(result.lastPathComponent == "多轨 转换结果 (2)")
let preserved = try Data(contentsOf: collision.appendingPathComponent("sentinel"))
precondition(preserved == Data("保留".utf8))
for index in 0..<2 {
    let reference = root.appendingPathComponent("reference-\(index).ffmetadata")
    precondition(run(["-i",input.path,"-map_metadata","0:s:a:\(index)","-map_chapters","-1","-f","ffmetadata",reference.path]) == 0)
    let sidecar = result.appendingPathComponent("音轨 \(index + 1) 元数据.ffmetadata")
    let a = try String(contentsOf: reference, encoding: .utf8), b = try String(contentsOf: sidecar, encoding: .utf8)
    precondition(ExternalMediaConverter.metadataEntries(a) == ExternalMediaConverter.metadataEntries(b))
}
print("PASS Unicode, escaped multi-line track metadata and conflict preservation")
