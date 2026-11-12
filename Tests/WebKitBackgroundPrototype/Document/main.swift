import Foundation
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: "/tmp/moriq-wk-background-probe", isDirectory: true)
for name in ["repeat", "cover"] {
 let source = root.appendingPathComponent("composite-\(name).html")
 let html = "<html><body style=\"margin:0;padding:0;background-image:url(snapshot-\(name).png);background-repeat:no-repeat;background-position:0px 0px;background-size:320px 240px\"><p>EDITABLE TEXT 4812</p></body></html>"
 try html.write(to: source, atomically: true, encoding: .utf8)
 let result = try DocumentConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
 let p = Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/unzip"); p.arguments=["-p",result.path,"word/document.xml"]
 let pipe=Pipe(); p.standardOutput=pipe;try p.run(); let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
 let xml=String(decoding:data,as:UTF8.self)
 precondition(p.terminationStatus == 0 && xml.contains("EDITABLE TEXT 4812") && xml.contains("behindDoc=\"1\""))
 print("PASS \(name) background with native text: \(result.path)")
}
