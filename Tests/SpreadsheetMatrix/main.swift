import Foundation
import PDFKit
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-sheet-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = DocumentConverter.officeEngine else { fatalError("LibreOffice unavailable") }
let seed = root.appendingPathComponent("source.csv")
try "Name,Value,Note\nMORIQ,7193,跨语言测试\n".write(to: seed, atomically: true, encoding: .utf8)
func office(_ input: URL, _ format: String, _ dir: URL) -> Bool {
    let p = Process(); p.executableURL = engine
    let profile = root.appendingPathComponent("profile-\(UUID().uuidString)")
    p.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", format, "--outdir", dir.path, input.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); try? fm.removeItem(at: profile); return p.terminationStatus == 0 } catch { return false }
}
var inputs: [URL] = [seed]
for ext in ["xls", "xlsx", "ods"] {
    precondition(office(seed, ext, root), "fixture \(ext)")
    let url = root.appendingPathComponent("source.\(ext)"); precondition(fm.fileExists(atPath: url.path)); inputs.append(url)
}
let tsv = root.appendingPathComponent("source.tsv")
try "Name\tValue\tNote\nMORIQ\t7193\t跨语言测试\n".write(to: tsv, atomically: true, encoding: .utf8)
inputs.append(tsv)
var failed = 0, passed = 0
for input in inputs {
    for target in DocumentConverter.targets(for: .sheet) {
        guard let ext = target.preferredFilenameExtension, ext != input.pathExtension.lowercased() else { continue }
        let folder = root.appendingPathComponent("out-\(UUID().uuidString)"); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let output = try DocumentConverter().convert(input: input, outputDirectory: folder, format: target)
            let content: String
            if target == .pdf { content = PDFDocument(url: output)?.string ?? "" }
            else if ext == "csv" || ext == "tsv" { content = (try? String(contentsOf: output, encoding: .utf8)) ?? "" }
            else {
                let readback = folder.appendingPathComponent("readback", isDirectory: true); try fm.createDirectory(at: readback, withIntermediateDirectories: false)
                guard office(output, "csv", readback) else { throw DocumentConversionError.failed }
                content = (try? String(contentsOf: readback.appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".csv"), encoding: .utf8)) ?? ""
            }
            guard content.contains("MORIQ") && content.contains("7193") && (target == .pdf || content.contains("跨语言测试")) && (ext != "tsv" || content.contains("\t")) else { throw DocumentConversionError.invalidOutput }
            passed += 1; print("PASS \(input.pathExtension)->\(ext)"); fflush(stdout)
        } catch { failed += 1; print("FAIL \(input.pathExtension)->\(ext): \(error)"); fflush(stdout) }
    }
}
print("SPREADSHEET_MATRIX passed=\(passed) failed=\(failed)")
exit(failed == 0 ? 0 : 1)
