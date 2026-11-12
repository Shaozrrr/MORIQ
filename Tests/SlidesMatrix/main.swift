import Foundation
import PDFKit
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-slides-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = DocumentConverter.officeEngine else { fatalError("LibreOffice unavailable") }
let seed = root.appendingPathComponent("source.pptx")
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
try fm.copyItem(at: fixture, to: seed)
func office(_ input: URL, _ format: String, _ dir: URL) -> Bool {
    let p = Process(); p.executableURL = engine
    let profile = root.appendingPathComponent("profile-\(UUID().uuidString)")
    p.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", format, "--outdir", dir.path, input.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); try? fm.removeItem(at: profile); return p.terminationStatus == 0 } catch { return false }
}
var inputs: [URL] = [seed]
for ext in ["ppt", "odp"] {
    precondition(office(seed, ext, root), "fixture \(ext)")
    let url = root.appendingPathComponent("source.\(ext)"); precondition(fm.fileExists(atPath: url.path)); inputs.append(url)
}
var failed = 0, passed = 0
for input in inputs {
    for target in DocumentConverter.targets(for: .slides) {
        guard let ext = target.preferredFilenameExtension, ext != input.pathExtension.lowercased() else { continue }
        let folder = root.appendingPathComponent("out-\(UUID().uuidString)"); try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let output = try DocumentConverter().convert(input: input, outputDirectory: folder, format: target)
            let pdf: URL
            if target == .pdf { pdf = output } else {
                let readback = folder.appendingPathComponent("readback", isDirectory: true); try fm.createDirectory(at: readback, withIntermediateDirectories: false)
                guard office(output, "pdf", readback) else { throw DocumentConversionError.failed }
                pdf = readback.appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".pdf")
            }
            guard let doc = PDFDocument(url: pdf), doc.pageCount > 0, (doc.string ?? "").contains("MORIQ slide test") else { throw DocumentConversionError.invalidOutput }
            passed += 1; print("PASS \(input.pathExtension)->\(ext)"); fflush(stdout)
        } catch { failed += 1; print("FAIL \(input.pathExtension)->\(ext): \(error)"); fflush(stdout) }
    }
}
print("SLIDES_MATRIX passed=\(passed) failed=\(failed)")
exit(failed == 0 ? 0 : 1)
