import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-plain-fidelity-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("source.txt")
let original = "#include <iostream>\n* asterisk literal\n[link](not-a-link)\n"
try original.write(to: input, atomically: true, encoding: .utf8)
let c = DocumentConverter()
for ext in ["md", "epub"] {
 let output = try c.convert(input: input, outputDirectory: root, format: UTType(filenameExtension: ext)!)
 let pandoc = DocumentConverter.pandocEngine!
 let text = root.appendingPathComponent("result-\(ext).txt")
 let p = Process(); p.executableURL = pandoc; p.arguments = ["--sandbox", output.path, "--to", "plain", "-o", text.path]
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
 try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
 let actual = try String(contentsOf: text, encoding: .utf8)
 guard actual.contains("#include <iostream>"), actual.contains("* asterisk literal"), actual.contains("[link](not-a-link)") else { print("FAIL \(ext): \(actual)"); exit(1) }
 print("PASS literal punctuation → \(ext)")
}
