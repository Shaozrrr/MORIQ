import Foundation
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-html-image-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic-with-image.docx")
let converter = DocumentConverter()
var inputs = [fixture]
for ext in ["odt", "rtf", "epub"] {
 let dir = root.appendingPathComponent("prepare-\(ext)"); try fm.createDirectory(at: dir, withIntermediateDirectories: false)
 inputs.append(try converter.convert(input: fixture, outputDirectory: dir, format: UTType(filenameExtension: ext)!))
}
let regex = try NSRegularExpression(pattern: #"(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#)
var failures = 0
for input in inputs {
 do {
  let dir = root.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: dir, withIntermediateDirectories: false)
  let out = try converter.convert(input: input, outputDirectory: dir, format: UTType(filenameExtension: "html")!)
  let html = try String(contentsOf: out, encoding: .utf8)
  let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
  guard !matches.isEmpty else { throw DocumentConversionError.invalidOutput }
  for match in matches {
   let value = String(html[Range(match.range(at: 1), in: html)!])
   guard value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","), let bytes = Data(base64Encoded: String(value[value.index(after: comma)...])), let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else { throw DocumentConversionError.resourceUnavailable }
  }
  let round = try converter.convert(input: out, outputDirectory: dir, format: UTType(filenameExtension: "docx")!)
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-Z1", round.path]
  let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
  try p.run(); let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
  guard p.terminationStatus == 0 && listing.contains("word/media/") else { throw DocumentConversionError.invalidOutput }
  print("PASS \(input.pathExtension) → HTML → DOCX retains image")
 } catch { failures += 1; print("FAIL \(input.pathExtension) → HTML: \(error)") }
}
exit(failures == 0 ? 0 : 1)
