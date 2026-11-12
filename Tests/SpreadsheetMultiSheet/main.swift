import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-multisheet-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let office = DocumentConverter.officeEngine else { fatalError("LibreOffice unavailable") }
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic-multisheet.xlsx")
func officeConvert(_ ext: String) throws -> URL {
 let p = Process(); p.executableURL = office
 p.arguments = ["-env:UserInstallation=\(root.appendingPathComponent(UUID().uuidString).absoluteString)", "--headless", "--convert-to", ext, "--outdir", root.path, source.path]
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
 try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
 return root.appendingPathComponent("synthetic-multisheet.\(ext)")
}
let inputs = try [source, officeConvert("xls"), officeConvert("ods")]
for input in inputs {
 for ext in ["csv", "tsv"] {
  let outDir = root.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: outDir, withIntermediateDirectories: false)
  let output = try DocumentConverter().convert(input: input, outputDirectory: outDir, format: UTType(filenameExtension: ext)!)
  let files = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
  precondition(files.count == 2 && files.allSatisfy { $0.pathExtension == ext })
  let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "|")
  precondition(text.contains("MORIQ FIRST") && text.contains("MORIQ SECOND"))
  precondition(text.contains(ext == "csv" ? "," : "\t"))
  precondition(text.contains("中文,含逗号") && text.contains("包含\"\"引号\"\"") && text.contains("第一行\n第二行"))
  precondition(text.contains("测试\t制表符") && text.contains("42") && text.contains("21"))
  let second = try DocumentConverter().convert(input: input, outputDirectory: outDir, format: UTType(filenameExtension: ext)!)
  precondition(second != output && fm.fileExists(atPath: output.path) && fm.fileExists(atPath: input.path))
  print("PASS all sheets \(input.pathExtension) → \(ext)")
 }
}
