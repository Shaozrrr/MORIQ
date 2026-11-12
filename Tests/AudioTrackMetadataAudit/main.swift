import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-meta-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("no ffmpeg") }
func run(_ args: [String]) -> (Int32,String) {
 let p=Process(); p.executableURL=engine; p.arguments=["-nostdin","-hide_banner"]+args
 let pipe=Pipe(); p.standardError=pipe; p.standardOutput=FileHandle.nullDevice
 try! p.run(); let data=pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 return (p.terminationStatus, String(decoding:data,as:UTF8.self))
}
let input=root.appendingPathComponent("source.mka")
let gen=run(["-f","lavfi","-i","sine=frequency=440", "-f","lavfi","-i","sine=frequency=880", "-t","0.3", "-map","0:a", "-map","1:a", "-metadata","title=MORIQ_ALBUM_TEST", "-metadata:s:a:0","title=MORIQ_TRACK_FIRST", "-metadata:s:a:1","title=MORIQ_TRACK_SECOND", "-c:a","pcm_s16le",input.path])
precondition(gen.0 == 0)
let original = run(["-i",input.path]).1; print("original album=\(original.contains("MORIQ_ALBUM_TEST")) first=\(original.contains("MORIQ_TRACK_FIRST")) second=\(original.contains("MORIQ_TRACK_SECOND"))")
for ext in ["flac","m4a"] {
 let dir=root.appendingPathComponent(ext); try fm.createDirectory(at:dir,withIntermediateDirectories:false)
 if ext == "m4a" { let collision=dir.appendingPathComponent("source 转换结果"); try fm.createDirectory(at:collision,withIntermediateDirectories:false); try Data("keep".utf8).write(to:collision.appendingPathComponent("sentinel")) }
 let result=try ExternalMediaConverter().convert(input:input,outputDirectory:dir,format:UTType(filenameExtension:ext)!,video:false)
 if ext == "m4a" { precondition(result.lastPathComponent == "source 转换结果 (2)"); precondition(fm.fileExists(atPath:dir.appendingPathComponent("source 转换结果/sentinel").path)) }
 let files=try fm.contentsOfDirectory(at:result,includingPropertiesForKeys:nil)
 let metadata = files.filter { $0.pathExtension == "ffmetadata" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
 precondition(metadata.count == 2, "two track metadata sidecars required")
 let first = try String(contentsOf:metadata[0],encoding:.utf8)
 precondition(first.contains("MORIQ_TRACK_FIRST"))
 let second = try String(contentsOf:metadata[1],encoding:.utf8)
 precondition(second.contains("MORIQ_TRACK_SECOND"))
 let outputs=files.filter { $0.pathExtension == ext }
 precondition(outputs.count == (ext == "flac" ? 2 : 1))
 precondition(outputs.allSatisfy { run(["-i",$0.path]).1.contains("MORIQ_ALBUM_TEST") })
 print("PASS \(ext): all audio and track metadata preserved, global title retained")
}
let plain=root.appendingPathComponent("plain.mka")
let plainGen=run(["-f","lavfi","-i","sine=frequency=440", "-f","lavfi","-i","sine=frequency=880", "-t","0.3", "-map","0:a", "-map","1:a", "-c:a","pcm_s16le",plain.path])
precondition(plainGen.0 == 0)
let plainResult=try ExternalMediaConverter().convert(input:plain,outputDirectory:root,format:UTType(filenameExtension:"m4a")!,video:false)
var isDirectory: ObjCBool=false
precondition(fm.fileExists(atPath:plainResult.path,isDirectory:&isDirectory) && !isDirectory.boolValue, "unnecessary metadata package")
print("PASS untagged multi-track M4A remains one file")
