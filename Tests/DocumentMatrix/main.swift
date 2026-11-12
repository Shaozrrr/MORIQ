import Foundation
import PDFKit
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-document-matrix-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = DocumentConverter.officeEngine else { fatalError("LibreOffice unavailable") }
let seed = root.appendingPathComponent("source.txt")
try "MORIQ MATRIX 7193\nSecond paragraph for conversion checking.".write(to: seed, atomically: true, encoding: .utf8)
func runOffice(_ input: URL, format: String, dir: URL) -> Bool {
    let p = Process(); p.executableURL = engine
    let profile = root.appendingPathComponent("profile-\(UUID().uuidString)")
    p.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", format, "--outdir", dir.path, input.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); try? fm.removeItem(at: profile); return p.terminationStatus == 0 } catch { return false }
}
var inputs: [URL] = [seed]
for ext in ["doc", "docx", "odt", "rtf", "html"] {
    precondition(runOffice(seed, format: ext, dir: root), "fixture \(ext)")
    let url = root.appendingPathComponent("source.\(ext)")
    precondition(fm.fileExists(atPath: url.path), "missing fixture \(ext)")
    inputs.append(url)
}
guard let pandoc = DocumentConverter.pandocEngine else { fatalError("Pandoc required for this matrix") }
let markdown = root.appendingPathComponent("source.md")
try "# MORIQ MATRIX 7193\n\nSecond paragraph for conversion checking.".write(to: markdown, atomically: true, encoding: .utf8)
inputs.append(markdown)
let ebook = root.appendingPathComponent("source.epub")
let makeBook = Process(); makeBook.executableURL = pandoc
makeBook.arguments = ["--sandbox", "--metadata", "title=Matrix", markdown.path, "-o", ebook.path]
makeBook.standardOutput = FileHandle.nullDevice; makeBook.standardError = FileHandle.nullDevice
try makeBook.run(); makeBook.waitUntilExit(); precondition(makeBook.terminationStatus == 0); inputs.append(ebook)
let targets = DocumentConverter.targets(for: .word)
var failed = 0, passed = 0
for input in inputs {
    for target in targets {
        guard let ext = target.preferredFilenameExtension, ext != input.pathExtension.lowercased() else { continue }
        let folder = root.appendingPathComponent("out-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let output = try DocumentConverter().convert(input: input, outputDirectory: folder, format: target)
            let content: String
            if target == .pdf { content = PDFDocument(url: output)?.string ?? "" }
            else if target == .plainText || ext == "md" { content = (try? String(contentsOf: output, encoding: .utf8)) ?? "" }
            else if ext == "epub" {
                let plain = folder.appendingPathComponent("epub-readback.txt")
                let p = Process(); p.executableURL = pandoc; p.arguments = ["--sandbox", output.path, "--to", "plain", "--output", plain.path]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw DocumentConversionError.failed }
                content = (try? String(contentsOf: plain, encoding: .utf8)) ?? ""
            }
            else {
                let extracted = folder.appendingPathComponent("readback", isDirectory: true)
                try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
                guard runOffice(output, format: "txt:Text", dir: extracted) else { throw DocumentConversionError.failed }
                content = (try? String(contentsOf: extracted.appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".txt"), encoding: .utf8)) ?? ""
            }
            let normalized = content.replacingOccurrences(of: "\u{00a0}", with: " ")
            guard normalized.contains("MORIQ MATRIX 7193") else { throw DocumentConversionError.invalidOutput }
            passed += 1; print("PASS \(input.pathExtension)->\(ext)"); fflush(stdout)
        } catch { failed += 1; print("FAIL \(input.pathExtension)->\(ext): \(error)"); fflush(stdout) }
    }
}
print("DOCUMENT_MATRIX passed=\(passed) failed=\(failed)")
exit(failed == 0 ? 0 : 1)
