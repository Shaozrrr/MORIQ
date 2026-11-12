import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-md-syntax-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let asset = root.appendingPathComponent("图片 space.png")
let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic-with-image.docx")
let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); unzip.arguments = ["-p", fixture.path, "word/media/image1.png"]
let pipe = Pipe(); unzip.standardOutput = pipe; try unzip.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit(); precondition(unzip.terminationStatus == 0); try bytes.write(to: asset)
let markdown = root.appendingPathComponent("example.md")
let sample = """
# MORIQ reference image

Inline literal: `![example](does-not-exist.png)`

```markdown
![example](also-missing.png)
```

![测试图片][figure]

![figure][]

![figure]

<img src="图片 space.png">

[figure]: <图片 space.png>
"""
try sample.write(to: markdown, atomically: true, encoding: .utf8)
do {
 let result = try DocumentConverter().convert(input: markdown, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
 let listing = Process(); listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); listing.arguments = ["-Z1", result.path]
 let out = Pipe(); listing.standardOutput = out; try listing.run(); let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); listing.waitUntilExit()
 guard listing.terminationStatus == 0 && text.contains("word/media/") else { throw DocumentConversionError.invalidOutput }
 let xml = Process(); xml.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); xml.arguments = ["-p", result.path, "word/document.xml"]
 let xmlPipe = Pipe(); xml.standardOutput = xmlPipe; try xml.run(); let body = String(decoding: xmlPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); xml.waitUntilExit()
 guard body.contains("does-not-exist.png"), body.contains("also-missing.png"), body.components(separatedBy: "<w:drawing").count - 1 >= 4 else { print("DETAIL inline=\(body.contains("does-not-exist.png")) fenced=\(body.contains("also-missing.png")) drawings=\(body.components(separatedBy: "<w:drawing").count - 1)"); throw DocumentConversionError.invalidOutput }
 print("PASS references, raw HTML, and literal code remain correct")
} catch { print("FAIL Markdown syntax: \(error)"); exit(1) }

let nested = root.appendingPathComponent("nested", isDirectory: true)
try fm.createDirectory(at: nested, withIntermediateDirectories: false)
try fm.createSymbolicLink(atPath: nested.appendingPathComponent("linked.png").path, withDestinationPath: "../图片 space.png")
for (name, link) in [("parent", "<../图片 space.png>"), ("symlink", "linked.png")] {
 let file = nested.appendingPathComponent(name + ".md")
 try "![image](\(link))".write(to: file, atomically: true, encoding: .utf8)
 do { _ = try DocumentConverter().convert(input: file, outputDirectory: nested, format: UTType(filenameExtension: "docx")!); fatalError("outside-directory resource accepted") }
 catch DocumentConversionError.resourceUnavailable { print("PASS outside-directory \(name) blocked") }
}
