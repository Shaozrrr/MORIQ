import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-md-image-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic-with-image.docx")
let converter = DocumentConverter()
var inputs = [fixture]
for ext in ["odt", "rtf", "epub"] {
 let dir = root.appendingPathComponent("prepare-\(ext)"); try fm.createDirectory(at: dir, withIntermediateDirectories: false)
 inputs.append(try converter.convert(input: fixture, outputDirectory: dir, format: UTType(filenameExtension: ext)!))
}
let regex = try NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^\s\)]+)"#)
var failures = 0
for input in inputs {
 do {
  let dir = root.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: dir, withIntermediateDirectories: false)
  let output = try converter.convert(input: input, outputDirectory: dir, format: UTType(filenameExtension: "md")!)
  let isDirectory = (try output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  let md = isDirectory ? try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "md" })! : output
  let text = try String(contentsOf: md, encoding: .utf8)
  let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
  guard !matches.isEmpty else { throw DocumentConversionError.invalidOutput }
  for match in matches {
   let value = String(text[Range(match.range(at: 1), in: text)!])
   guard fm.fileExists(atPath: md.deletingLastPathComponent().appendingPathComponent(value).path) else { throw DocumentConversionError.resourceUnavailable }
  }
  for ext in ["docx", "epub", "html"] {
   let roundDir = dir.appendingPathComponent("round-\(ext)"); try fm.createDirectory(at: roundDir, withIntermediateDirectories: false)
   let round = try converter.convert(input: md, outputDirectory: roundDir, format: UTType(filenameExtension: ext)!)
   if ext == "html" {
    let html = try String(contentsOf: round, encoding: .utf8)
    guard html.contains("data:image/") else { throw DocumentConversionError.invalidOutput }
   } else {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-Z1", round.path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run(); let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
    guard p.terminationStatus == 0 && listing.contains(ext == "docx" ? "word/media/" : "media/") else { throw DocumentConversionError.invalidOutput }
   }
  }
  let second = try converter.convert(input: input, outputDirectory: dir, format: UTType(filenameExtension: "md")!)
  guard second != output && fm.fileExists(atPath: output.path) && fm.fileExists(atPath: input.path) else { throw DocumentConversionError.invalidOutput }
  print("PASS \(input.pathExtension) → Markdown → DOCX / EPUB / HTML retains image")
 } catch { failures += 1; print("FAIL \(input.pathExtension) → Markdown: \(error)") }
}
let missing = root.appendingPathComponent("missing.md")
try "![missing](assets/missing.png)".write(to: missing, atomically: true, encoding: .utf8)
do { _ = try converter.convert(input: missing, outputDirectory: root, format: UTType(filenameExtension: "docx")!); failures += 1; print("FAIL missing image accepted") }
catch DocumentConversionError.resourceUnavailable { print("PASS missing Markdown image reported") }
exit(failures == 0 ? 0 : 1)
