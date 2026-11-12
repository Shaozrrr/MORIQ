import Foundation
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = root.appendingPathComponent("budget.xlsx")
let out = root.appendingPathComponent("missing-output", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
do {
    _ = try DocumentConverter().convert(input: source, outputDirectory: out, format: UTType(filenameExtension: "ods")!)
    fatalError("conversion must not succeed without the packaged view-preservation engine")
} catch DocumentConversionError.packagedEngineMissing {
    let remaining = try FileManager.default.contentsOfDirectory(atPath: out.path)
    precondition(remaining.isEmpty)
    print("PASS: missing packaged engine is reported without creating a misleading output")
}
