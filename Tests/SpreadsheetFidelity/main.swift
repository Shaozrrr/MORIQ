import Foundation
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = root.appendingPathComponent("budget.xlsx")
let odsDir = root.appendingPathComponent("ods", isDirectory: true)
let xlsxDir = root.appendingPathComponent("xlsx", isDirectory: true)
let pdfDir = root.appendingPathComponent("pdf", isDirectory: true)
for dir in [odsDir, xlsxDir, pdfDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
let converter = DocumentConverter()
let ods = try converter.convert(input: source, outputDirectory: odsDir, format: UTType(filenameExtension: "ods")!)
let restored = try converter.convert(input: ods, outputDirectory: xlsxDir, format: UTType(filenameExtension: "xlsx")!)
let pdf = try converter.convert(input: source, outputDirectory: pdfDir, format: .pdf)
print("ROUNDTRIP=\(restored.path)")
print("PDF=\(pdf.path)")
