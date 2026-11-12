import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-resource-test-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic-with-image.docx")
func entries(_ file: URL) throws -> String {
 let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-Z1", file.path]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 precondition(p.terminationStatus == 0); return String(decoding: data, as: UTF8.self)
}
let converter = DocumentConverter()
let epub = try converter.convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "epub")!)
let epubEntries = try entries(epub)
precondition(epubEntries.contains("media/"), "EPUB lost embedded image")
let roundDir = root.appendingPathComponent("round"); try fm.createDirectory(at: roundDir, withIntermediateDirectories: false)
let round = try converter.convert(input: epub, outputDirectory: roundDir, format: UTType(filenameExtension: "docx")!)
let roundEntries = try entries(round)
precondition(roundEntries.contains("word/media/"), "DOCX lost embedded image")
let html = root.appendingPathComponent("missing.html")
try "<html><body>Example<img src='missing.png'></body></html>".write(to: html, atomically: true, encoding: .utf8)
do { _ = try converter.convert(input: html, outputDirectory: root, format: UTType(filenameExtension: "epub")!); fatalError("missing resource silently discarded") }
catch DocumentConversionError.resourceUnavailable { print("PASS missing resource is reported") }
print("PASS DOCX → EPUB → DOCX retains embedded image")
