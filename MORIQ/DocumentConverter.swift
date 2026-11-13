import Foundation
import AppKit
import UniformTypeIdentifiers
import PDFKit
import ImageIO
import Darwin
import libxml2

// Keep cancellation checks on the task's own thread while a background worker
// waits for the process and, when necessary, drains its output pipe.
private final class DocumentPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func set(_ data: Data) { lock.lock(); bytes = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
@discardableResult private func waitDocumentProcess(_ process: Process, pipe: Pipe? = nil) throws -> Data {
    let finished = DispatchSemaphore(value: 0)
    let readFinished = DispatchGroup()
    let buffer = DocumentPipeBuffer()
    if let pipe {
        readFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            buffer.set(pipe.fileHandleForReading.readDataToEndOfFile())
            readFinished.leave()
        }
    }
    DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); finished.signal() }
    var cancellationTime: DispatchTime?
    var killed = false
    while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
        if Task.isCancelled && cancellationTime == nil {
            cancellationTime = .now()
            if process.isRunning { process.terminate() }
        }
        if let start = cancellationTime {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            if elapsed >= 2_000_000_000 && !killed {
                killed = true
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            if elapsed >= 5_000_000_000 { throw CancellationError() }
        }
    }
    // A child may inherit stderr after its parent exits. Do not wait forever.
    if readFinished.wait(timeout: .now() + .seconds(2)) == .timedOut {
        try? pipe?.fileHandleForReading.close()
        try Task.checkCancellation()
        throw DocumentConversionError.failed
    }
    try Task.checkCancellation()
    return buffer.get()
}

#if DEBUG
func testWaitDocumentProcess(_ process: Process, pipe: Pipe) throws -> Data {
    try waitDocumentProcess(process, pipe: pipe)
}
#endif

enum DocumentConversionError: Error { case unsupported, engineMissing, packagedEngineMissing, failed, invalidInput, invalidOutput, noText, resourceUnavailable, filesystem(Int32) }
struct DocumentConverter {
    enum Kind { case word, sheet, slides, pdf }
    /// The bundled office runtime may inherit a fontconfig built for a
    /// different prefix. Point it at macOS's installed fonts so exported
    /// CJK text remains visible on a clean Mac; no fonts are redistributed.
    private func configureOfficeFonts(_ process: Process, scratch: URL) throws {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let cache = cacheRoot.appendingPathComponent("MORIQ/OfficeFonts", isDirectory:true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories:true)
        func xmlEscape(_ s:String) -> String {
            s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
        }
        let config = scratch.appendingPathComponent("office-fonts.conf")
        let content = """
        <?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>
        <dir>/System/Library/Fonts</dir><dir>/System/Library/Fonts/Supplemental</dir><dir>/Library/Fonts</dir>
        <cachedir>\(xmlEscape(cache.path))</cachedir></fontconfig>
        """
        try content.write(to:config,atomically:true,encoding:.utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["FONTCONFIG_FILE"] = config.path
        process.environment = environment
    }
    /// Describe known fidelity limits without inspecting or altering user content.
    static func pdfResultNotice(input: URL, targetExtension: String) -> String? {
        let source = input.pathExtension.lowercased()
        if ["html", "htm"].contains(source) && targetExtension.lowercased() == "docx" {
            return "已转换；网页背景图可能仅保留首页或丢失，请检查版式和图片"
        }
        guard source == "pdf" else { return nil }
        switch targetExtension {
        case "txt": return "已提取文字并识别图片文字；请检查识别结果及阅读顺序"
        case "docx":
            guard let pdf = PDFDocument(url: input), !pdf.isLocked else { return "已转换；请检查版式和图片" }
            let imagePages = (0..<pdf.pageCount).contains { index in
                guard let page = pdf.page(at: index) else { return true }
                return (page.attributedString?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if imagePages { return packagedPDFEngine == nil ? "页面以图片保留；文字不可编辑" : "扫描页面以图片保留；请检查版式" }
            return "已转换；请检查版式和图片"
        case "rtf", "html", "odt": return "已转换；请检查版式和图片"
        case "gif": return "已逐页转换；GIF 颜色已量化"
        case "jpg", "jpeg": return "已逐页转换；JPG 使用有损压缩"
        default: return nil
        }
    }
    /// Merge PDFKit text lines and OCR lines in page space. Original text is
    /// authoritative wherever it overlaps OCR; OCR supplements image-only
    /// areas. Coordinates are normalized into the rotated thumbnail space.
    static func pdfText(_ page: PDFPage, recognize: (CGImage) throws -> [OCRBlock] = { try OCREngine().recognizeBlocks($0) }) throws -> String {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { throw DocumentConversionError.invalidOutput }
        let rotation = ((page.rotation % 360) + 360) % 360
        guard [0, 90, 180, 270].contains(rotation) else { throw DocumentConversionError.invalidOutput }
        func point(_ p: CGPoint) -> CGPoint {
            let x = (p.x - box.minX) / box.width, y = (p.y - box.minY) / box.height
            switch rotation {
            case 90: return CGPoint(x: y, y: 1-x)
            case 180: return CGPoint(x: 1-x, y: 1-y)
            case 270: return CGPoint(x: 1-y, y: x)
            default: return CGPoint(x: x, y: y)
            }
        }
        func normalized(_ r: CGRect) -> CGRect {
            let ps = [point(CGPoint(x:r.minX,y:r.minY)), point(CGPoint(x:r.maxX,y:r.minY)), point(CGPoint(x:r.minX,y:r.maxY)), point(CGPoint(x:r.maxX,y:r.maxY))]
            let xs = ps.map(\.x), ys = ps.map(\.y)
            return CGRect(x:xs.min()!, y:ys.min()!, width:xs.max()!-xs.min()!, height:ys.max()!-ys.min()!)
        }
        let native = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selections = page.selection(for: box)?.selectionsByLine() ?? []
        var lines: [(text: String, rect: CGRect)] = selections.compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rect = normalized(line.bounds(for: page))
            return text.isEmpty || rect.isEmpty ? nil : (text, rect)
        }
        // A crop can omit native text returned by PDFKit's page.string. If
        // line geometry does not account for all native characters, retain
        // the complete native string instead of silently discarding any.
        func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
        let nativeMapped = compact(lines.map(\.text).joined()) == compact(native)
        let nativeRects = lines
        let scale = min(3, 3000 / max(box.width, box.height))
        let thumbnail = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
        var rect = NSRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw DocumentConversionError.invalidOutput }
        let blocks = try recognize(image)
        var addedOCR = false
        for block in blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !block.boundingBox.isEmpty else { continue }
            let overlapping = nativeRects.filter { line in
                let intersection = line.rect.intersection(block.boundingBox)
                return !intersection.isNull && intersection.width * intersection.height >= block.boundingBox.width * block.boundingBox.height * 0.35
            }
            // Overlap alone is not enough: an OCR line may contain both a
            // native word and extra image text. Never drop that extra text.
            let covered = overlapping.contains { compact($0.text).caseInsensitiveCompare(compact(text)) == .orderedSame }
            if !covered { lines.append((text, block.boundingBox)); addedOCR = true }
        }
        if !addedOCR && !native.isEmpty { return native }
        if !nativeMapped && !native.isEmpty {
            return ([native] + lines.dropFirst(nativeRects.count).map(\.text)).joined(separator: "\n")
        }
        lines.sort { a,b in
            // A pair-dependent height tolerance is not transitive and can
            // produce unstable ordering. Fixed page-space bands are sortable.
            let ay = (a.rect.midY * 1000).rounded(), by = (b.rect.midY * 1000).rounded()
            if ay != by { return ay > by }
            return a.rect.minX < b.rect.minX
        }
        return lines.map(\.text).joined(separator: "\n")
    }
    static func kind(_ url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "doc", "docx", "odt", "rtf", "txt", "html", "htm": return .word
        case "md", "epub": return pandocEngine == nil ? nil : .word
        case "xls", "xlsx", "ods", "csv", "tsv": return .sheet
        case "ppt", "pptx", "odp": return .slides
        case "pdf": return .pdf
        default: return nil
        }
    }
    static var officeEngine: URL? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MORIQ_TEST_DISABLE_OFFICE"] == "1" { return nil }
        #endif
        #if arch(arm64)
        let archName = "arm64"
        #else
        let archName = "x86_64"
        #endif
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("OfficeSuite/LibreOffice-\(archName).app/Contents/MacOS/soffice")
        var locations = [bundled].compactMap { $0 } + [
            URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"),
            URL(fileURLWithPath: "/opt/homebrew/bin/soffice"),
            URL(fileURLWithPath: "/usr/local/bin/soffice")
        ]
        #if DEBUG
        locations.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/codex-runtimes/codex-primary-runtime/dependencies/native/libreoffice-headless/libreoffice/LibreOfficeDev.app/Contents/MacOS/soffice"))
        #endif
        return locations.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static var qualityPDFEngine: (python: URL, modules: URL)? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MORIQ_TEST_DISABLE_OFFICE"] == "1" { return nil }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modules = project.appendingPathComponent("Tools/pdf2docx", isDirectory: true)
        let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: modules.appendingPathComponent("pdf2docx/__init__.py").path) else { return nil }
        return (python, modules)
        #else
        return nil
        #endif
    }
    /// The packaged converter keeps editable text, images and detected tables.
    static var packagedPDFEngine: (java: URL, jar: URL)? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MORIQ_TEST_DISABLE_OFFICE"] == "1" { return nil }
        #endif
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("OfficeEngine", isDirectory: true)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let java = root.appendingPathComponent("jre-\(architecture)/bin/java")
        let jar = root.appendingPathComponent("converter.jar")
        guard FileManager.default.isExecutableFile(atPath: java.path), FileManager.default.fileExists(atPath: jar.path) else { return nil }
        return (java, jar)
    }
    private static func packagedDocument(_ input: URL, in scratch: URL, engine: (java: URL, jar: URL)) throws -> URL {
        let output = scratch.appendingPathComponent("quality.docx")
        let process = Process()
        process.executableURL = engine.java
        process.arguments = ["-Djava.awt.headless=true", "-jar", engine.jar.path, input.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw DocumentConversionError.failed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(process); timeout.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else { throw DocumentConversionError.failed }
        return output
    }
    /// Headless spreadsheet export can omit view state; translate frozen panes
    /// using each format's own view metadata without modifying the source.
    private static func preserveSpreadsheetView(input: URL, output: URL) throws {
        let source = input.pathExtension.lowercased(), target = output.pathExtension.lowercased()
        guard (source == "xlsx" && target == "ods") || (source == "ods" && target == "xlsx") else { return }
        guard let engine = packagedPDFEngine else { throw DocumentConversionError.packagedEngineMissing }
        let helper = engine.jar.deletingLastPathComponent().appendingPathComponent("sheet-view-preserver.jar")
        guard FileManager.default.fileExists(atPath: helper.path) else { throw DocumentConversionError.packagedEngineMissing }
        let p = Process(); p.executableURL = engine.java
        p.arguments = ["-Djava.awt.headless=true", "-jar", helper.path, input.path, output.path, source, target]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try p.run() } catch { throw DocumentConversionError.failed }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(p); timeout.cancel()
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else { throw DocumentConversionError.failed }
    }
    private static func qualityDocument(_ input: URL, in scratch: URL, engine: (python: URL, modules: URL)) throws -> URL {
        let output = scratch.appendingPathComponent("quality.docx")
        let process = Process(); process.executableURL = engine.python
        process.arguments = ["-c", "import sys; from pdf2docx import Converter; c=Converter(sys.argv[1]); c.convert(sys.argv[2]); c.close()", input.path, output.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = engine.modules.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw DocumentConversionError.failed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(process); timeout.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw DocumentConversionError.failed }
        return output
    }
    static var pandocEngine: URL? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var locations = [Bundle.main.resourceURL?.appendingPathComponent("Pandoc/pandoc-\(architecture)")].compactMap { $0 }
        locations += [URL(fileURLWithPath: "/opt/homebrew/bin/pandoc"), URL(fileURLWithPath: "/usr/local/bin/pandoc")]
        #if DEBUG
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        locations.append(project.appendingPathComponent("Tools/pandoc/pandoc-3.13-arm64/bin/pandoc"))
        #endif
        return locations.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private func pandocConvert(_ input: URL, format: String, scratch: URL, engine: URL) throws -> URL {
        var source = input
        let sourceExt = input.pathExtension.lowercased()
        if ["doc", "rtf", "txt"].contains(sourceExt) {
            guard let docx = UTType(filenameExtension: "docx") else { throw DocumentConversionError.unsupported }
            source = try convert(input: input, outputDirectory: scratch, format: docx)
        }
        if sourceExt == "md" { source = try prepareMarkdown(input, scratch: scratch) }
        let wantsPDF = format == "pdf"
        let outExt = wantsPDF ? "docx" : format
        let output = scratch.appendingPathComponent("pandoc-result.\(outExt)")
        let process = Process(); process.executableURL = engine
        var arguments = ["--sandbox", "--standalone", "--metadata", "title=\(input.deletingPathExtension().lastPathComponent)"]
        if outExt == "html" { arguments.append("--embed-resources") }
        if outExt == "md" { arguments.append("--extract-media=assets"); process.currentDirectoryURL = scratch }
        let writer = outExt == "txt" ? "plain" : (outExt == "md" ? "markdown" : outExt)
        arguments += [source.path, "--to", writer, "--output", output.path]
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try Task.checkCancellation()
        do { try process.run() } catch { throw DocumentConversionError.failed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        let errorData = try waitDocumentProcess(process, pipe: errors)
        timeout.cancel()
        try Task.checkCancellation()
        let diagnostic = (String(data: errorData, encoding: .utf8) ?? "").lowercased()
        if diagnostic.contains("could not fetch resource") || diagnostic.contains("could not find resource") { throw DocumentConversionError.resourceUnavailable }
        guard process.terminationStatus == 0 else { throw DocumentConversionError.failed }
        return wantsPDF ? try convert(input: output, outputDirectory: scratch, format: .pdf) : output
    }
    static func targets(for kind: Kind, officeAvailable: Bool? = nil) -> [UTType] {
        let hasOffice = officeAvailable ?? (officeEngine != nil)
        if kind == .pdf {
            let webp = ExternalMediaConverter.executable == nil ? [] : [UTType("org.webmproject.webp")].compactMap { $0 }
            let native: [UTType] = [.plainText] + PDFPageExporter.supportedFormats() + webp + ["docx"].compactMap { UTType(filenameExtension: $0) }
            return hasOffice ? native + ["rtf", "html", "odt"].compactMap { UTType(filenameExtension: $0) } : native
        }
        guard hasOffice else { return [] }
        let names: [String]
        switch kind {
        case .word: names = ["pdf", "docx", "odt", "rtf", "txt", "html"] + (pandocEngine == nil ? [] : ["md", "epub"])
        case .sheet: names = ["pdf", "xlsx", "ods", "csv", "tsv"]
        case .slides: names = ["pdf", "pptx", "odp"]
        case .pdf: names = []
        }
        return names.compactMap { UTType(filenameExtension: $0) }
    }
    /// Preserve all pages of scanned or mixed PDFs as images. This keeps appearance
    /// rather than pretending the result is editable text.
    private static func imageDocument(_ pdf: PDFDocument, in scratch: URL) throws -> URL {
        let fm = FileManager.default
        let package = scratch.appendingPathComponent("docx", isDirectory: true)
        let media = package.appendingPathComponent("word/media", isDirectory: true)
        let rels = package.appendingPathComponent("word/_rels", isDirectory: true)
        let rootRels = package.appendingPathComponent("_rels", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        try fm.createDirectory(at: rels, withIntermediateDirectories: true)
        try fm.createDirectory(at: rootRels, withIntermediateDirectories: true)
        func write(_ text: String, _ path: String) throws { try Data(text.utf8).write(to: package.appendingPathComponent(path), options: .withoutOverwriting) }
        try write("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """, "[Content_Types].xml")
        try write("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """, "_rels/.rels")
        var body = "", links = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { throw DocumentConversionError.invalidOutput }
            let box = page.bounds(for: .cropBox)
            guard box.width > 0 && box.height > 0 else { throw DocumentConversionError.invalidOutput }
            let scale = min(2, 2000 / max(box.width, box.height))
            let bitmap = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
            guard let tiff = bitmap.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw DocumentConversionError.failed }
            let number = index + 1
            try png.write(to: media.appendingPathComponent("page\(number).png"), options: .withoutOverwriting)
            let fit = min(6.5 / box.width, 9.0 / box.height)
            let cx = Int(box.width * fit * 914400), cy = Int(box.height * fit * 914400)
            links += "<Relationship Id=\"rId\(number)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/page\(number).png\"/>"
            if index > 0 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            body += """
            <w:p><w:r><w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(number)" name="Page \(number)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(number)" name="Page \(number)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId\(number)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
        }
        try write("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(links)</Relationships>
        """, "word/_rels/document.xml.rels")
        try write("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr/></w:body></w:document>
        """, "word/document.xml")
        let output = scratch.appendingPathComponent("result.docx")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = package; process.arguments = ["-q", "-r", output.path, "."]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        try waitDocumentProcess(process)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw DocumentConversionError.failed }
        return output
    }

    private struct SimplePageBackground {
        let image: CGImage
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let repeats: Bool
        let cover: Bool
        let centered: Bool
    }
    private struct SimpleTableGeometry {
        let columnWidths: [Double]
        let rowHeights: [Double]
    }
    /// Supported subset: body inline style or a single body stylesheet rule,
    /// repeat or no-repeat with pixel offsets; page-level cover also supports
    /// centered positioning. Other CSS remains on the warning-bearing fallback.
    private func simplePageBackground(_ input: URL) throws -> SimplePageBackground? {
        let data = try Data(contentsOf: input)
        guard data.count <= Int(Int32.max) else { return nil }
        let doc = data.withUnsafeBytes { bytes -> htmlDocPtr? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            return htmlReadMemory(base, Int32(bytes.count), nil, String(data: data, encoding: .utf8) == nil ? nil : "UTF-8", Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue))
        }
        guard let doc else { return nil }; defer { xmlFreeDoc(doc) }
        func findBody(_ first: xmlNodePtr?) -> xmlNodePtr? {
            var cursor = first
            while let node = cursor {
                if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name, String(cString: name).lowercased() == "body" { return node }
                if let found = findBody(node.pointee.children) { return found }
                cursor = node.pointee.next
            }
            return nil
        }
        var stylesheets: [String] = []
        var unsupportedStyles = false
        func collectStyles(_ first: xmlNodePtr?) {
            var current = first
            while let node = current {
                if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name {
                    let tag = String(cString: name).lowercased()
                    if tag == "link" || tag == "base" { unsupportedStyles = true }
                    if tag == "html" && xmlHasProp(node, "style") != nil { unsupportedStyles = true }
                    if tag == "style" {
                        if xmlHasProp(node, "media") != nil || xmlHasProp(node, "type") != nil { unsupportedStyles = true }
                        if let value = xmlNodeGetContent(node) { stylesheets.append(String(cString: value)); xmlFree?(value) }
                    }
                }
                collectStyles(node.pointee.children)
                current = node.pointee.next
            }
        }
        collectStyles(xmlDocGetRootElement(doc))
        guard !unsupportedStyles, let body = findBody(xmlDocGetRootElement(doc)) else { return nil }
        let style: String
        if stylesheets.isEmpty, let styleValue = xmlGetProp(body, "style") {
            style = String(cString: styleValue); xmlFree?(styleValue)
        } else if stylesheets.count == 1, xmlHasProp(body, "style") == nil {
            // One unambiguous body rule only; do not guess the CSS cascade.
            let sheet = stylesheets[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sheet.contains("/*"), let open = sheet.firstIndex(of: "{"), let close = sheet.lastIndex(of: "}"), open < close,
                  sheet[sheet.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sheet[..<open].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "body",
                  !sheet[sheet.index(after: open)..<close].contains("{") else { return nil }
            style = String(sheet[sheet.index(after: open)..<close])
        } else { return nil }
        guard !style.contains("/*") else { return nil }
        var properties: [String: String] = [:]
        for part in style.split(separator: ";") {
            if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let bits = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard bits.count == 2 else { return nil }
            let key = bits[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard properties[key] == nil else { return nil }
            properties[key] = bits[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let allowed: Set<String> = ["background-image", "background-repeat", "background-position", "background-size", "margin", "padding", "height"]
        guard Set(properties.keys).isSubset(of: allowed), properties["margin"] == "0", properties["padding"] == "0",
              let imageCSS = properties["background-image"],
              properties["background"] == nil,
              imageCSS.lowercased().hasPrefix("url("), imageCSS.hasSuffix(")") else { return nil }
        // CSS defaults to repeat when background-repeat is omitted.
        let repeatMode = properties["background-repeat"]?.lowercased() ?? "repeat"
        guard ["no-repeat", "repeat"].contains(repeatMode) else { return nil }
        var raw = String(imageCSS.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count >= 2 && ((raw.first == "\"" && raw.last == "\"") || (raw.first == "'" && raw.last == "'")) { raw = String(raw.dropFirst().dropLast()) }
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty, !decoded.contains(":"), !decoded.hasPrefix("/") else { throw DocumentConversionError.resourceUnavailable }
        let position = (properties["background-position"] ?? "0px 0px").split(whereSeparator: { $0.isWhitespace })
        let centered = position == ["center"] || position == ["center", "center"] || position == ["50%", "50%"]
        func pixels(_ value: Substring) -> Double? {
            guard value.lowercased().hasSuffix("px"), let result = Double(value.dropLast(2)), result >= 0, result <= 10000 else { return nil }
            return result
        }
        guard centered || position.count == 2 else { return nil }
        guard let x = centered ? 0 : pixels(position[0]), let y = centered ? 0 : pixels(position[1]) else { return nil }
        let directory = input.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let url = directory.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/"), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width <= 10000, image.height <= 10000 else { throw DocumentConversionError.resourceUnavailable }
        var width = Double(image.width), height = Double(image.height)
        let cover = properties["background-size"]?.lowercased() == "cover"
        // A CSS body cover scales to the body's own area, which can be much
        // taller than a printed page. Only resolve it against a page when the
        // source explicitly describes a viewport-sized, short single block.
        if cover {
            guard properties["height"]?.lowercased() == "100vh" else { return nil }
            var children: [xmlNodePtr] = []
            var cursor = body.pointee.children
            while let node = cursor {
                if node.pointee.type == XML_ELEMENT_NODE { children.append(node) }
                else if node.pointee.type == XML_TEXT_NODE, let value = node.pointee.content,
                        !String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                cursor = node.pointee.next
            }
            guard children.count == 1, let tag = children[0].pointee.name,
                  ["p", "div"].contains(String(cString: tag).lowercased()),
                  children[0].pointee.properties == nil,
                  let content = xmlNodeGetContent(children[0]) else { return nil }
            var child = children[0].pointee.children
            while let node = child {
                if node.pointee.type == XML_ELEMENT_NODE { xmlFree?(content); return nil }
                child = node.pointee.next
            }
            let text = String(cString: content); xmlFree?(content)
            guard !text.isEmpty, text.count <= 200, !text.contains("\n") else { return nil }
        } else if properties["height"] != nil { return nil }
        // Centered positioning is only resolved against the page for cover.
        guard !centered || cover else { return nil }
        if let size = properties["background-size"], size.lowercased() != "auto", !cover {
            let dimensions = size.split(whereSeparator: { $0.isWhitespace })
            guard dimensions.count == 2, let w = pixels(dimensions[0]), let h = pixels(dimensions[1]), w > 0, h > 0 else { return nil }
            width = w; height = h
        }
        return SimplePageBackground(image: image, x: x, y: y, width: width, height: height, repeats: repeatMode == "repeat", cover: cover, centered: centered)
    }
    /// A narrow, non-reflowing element case: a single short plain-text
    /// paragraph with an explicitly sized, stretched local background image.
    /// Anything more complex keeps the normal conversion warning.
    private func simpleElementBackground(_ input: URL) throws -> (SimplePageBackground, String, SimpleTableGeometry?)? {
        let data = try Data(contentsOf: input)
        guard data.count <= Int(Int32.max) else { return nil }
        let doc = data.withUnsafeBytes { bytes -> htmlDocPtr? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            return htmlReadMemory(base, Int32(bytes.count), nil, String(data: data, encoding: .utf8) == nil ? nil : "UTF-8", Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue))
        }
        guard let doc else { return nil }; defer { xmlFreeDoc(doc) }
        var body: xmlNodePtr?, invalid = false
        func scan(_ first: xmlNodePtr?) {
            var cursor = first
            while let node = cursor {
                if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name {
                    let tag = String(cString: name).lowercased()
                    if tag == "body" { if body != nil { invalid = true }; body = node }
                    else if !["html", "head", "meta", "p", "table", "tbody", "tr", "td"].contains(tag) { invalid = true }
                    if tag == "html" && node.pointee.properties != nil { invalid = true }
                }
                scan(node.pointee.children); cursor = node.pointee.next
            }
        }
        scan(xmlDocGetRootElement(doc))
        guard !invalid, let body, let bodyStyle = xmlGetProp(body, "style") else { return nil }
        let bodyString = String(cString: bodyStyle); xmlFree?(bodyStyle)
        func properties(_ style: String) -> [String:String]? {
            var result: [String:String] = [:]
            for part in style.split(separator:";") {
                let bits = part.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
                guard bits.count == 2 else { return nil }
                let key = bits[0].trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                guard result[key] == nil else { return nil }
                result[key] = bits[1].trimmingCharacters(in:.whitespacesAndNewlines)
            }
            return result
        }
        guard let b = properties(bodyString), b.count == 2, b["margin"] == "0", b["padding"] == "0" else { return nil }
        var nodes: [xmlNodePtr] = []; var cursor = body.pointee.children
        while let node = cursor {
            if node.pointee.type == XML_ELEMENT_NODE { nodes.append(node) }
            else if node.pointee.type == XML_TEXT_NODE, let content = node.pointee.content,
                    !String(cString:content).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return nil }
            cursor = node.pointee.next
        }
        func soleChild(_ parent: xmlNodePtr, named expected: String) -> xmlNodePtr? {
            var result: xmlNodePtr?, child = parent.pointee.children
            while let item = child {
                if item.pointee.type == XML_ELEMENT_NODE {
                    guard result == nil, let name = item.pointee.name,
                          String(cString:name).lowercased() == expected else { return nil }
                    result = item
                } else if item.pointee.type == XML_TEXT_NODE, let content = item.pointee.content,
                          !String(cString:content).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return nil }
                child = item.pointee.next
            }
            return result
        }
        guard nodes.count == 1, let first = nodes.first, let firstName = first.pointee.name else { return nil }
        let nodesToPaint: [xmlNodePtr]
        var cellsPerRow = 1
        if String(cString:firstName).lowercased() == "p" { nodesToPaint = [first] }
        else if String(cString:firstName).lowercased() == "table" {
            // The initial table case deliberately permits one unstyled row
            // and cell only; multiple cells need a separate layout mapping.
            let parent = soleChild(first,named:"tbody") ?? first
            guard (parent == first || parent.pointee.properties == nil) else { return nil }
            var rows: [xmlNodePtr] = [], rowCursor = parent.pointee.children
            while let item = rowCursor {
                if item.pointee.type == XML_ELEMENT_NODE {
                    guard let name = item.pointee.name, String(cString:name).lowercased() == "tr", item.pointee.properties == nil else { return nil }
                    rows.append(item)
                } else if item.pointee.type == XML_TEXT_NODE, let content = item.pointee.content,
                          !String(cString:content).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return nil }
                rowCursor = item.pointee.next
            }
            guard (1...2).contains(rows.count) else { return nil }
            var cells: [xmlNodePtr] = []
            for (index,row) in rows.enumerated() {
                var rowCells: [xmlNodePtr] = [], cursor = row.pointee.children
                while let item = cursor {
                    if item.pointee.type == XML_ELEMENT_NODE {
                        guard let name = item.pointee.name, String(cString:name).lowercased() == "td" else { return nil }
                        rowCells.append(item)
                    } else if item.pointee.type == XML_TEXT_NODE, let content = item.pointee.content,
                              !String(cString:content).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return nil }
                    cursor = item.pointee.next
                }
                guard (1...2).contains(rowCells.count), index == 0 || rowCells.count == cellsPerRow else { return nil }
                if index == 0 { cellsPerRow = rowCells.count }
                cells.append(contentsOf:rowCells)
            }
            guard rows.count == 1 || cellsPerRow == 2 else { return nil }
            if cells.count == 1 { guard first.pointee.properties == nil else { return nil } }
            else {
                // Separate CSS table borders have gaps that cannot be mapped
                // by a contiguous row image. Only accept explicit collapse.
                guard let attr = first.pointee.properties, attr.pointee.next == nil,
                      let name = attr.pointee.name, String(cString:name).lowercased() == "style",
                      let value = xmlGetProp(first,"style") else { return nil }
                let raw = String(cString:value); xmlFree?(value)
                guard let style = properties(raw), style == ["border-collapse":"collapse"] else { return nil }
            }
            nodesToPaint = cells
        } else { return nil }
        func parseNode(_ node: xmlNodePtr) throws -> (SimplePageBackground, String)? {
        guard let onlyAttribute = node.pointee.properties, onlyAttribute.pointee.next == nil,
              let attributeName = onlyAttribute.pointee.name, String(cString:attributeName).lowercased() == "style",
              let style = xmlGetProp(node,"style") else { return nil }
        let styleString = String(cString:style); xmlFree?(style)
        let required: Set<String> = ["margin","padding","width","height","background-image","background-size","background-repeat"]
        guard let p = properties(styleString), required.isSubset(of: Set(p.keys)), Set(p.keys).isSubset(of: required.union(["background-position"])),
              p["margin"] == "0", p["padding"] == "0", p["background-repeat"] == "no-repeat",
              let size = p["background-size"]?.lowercased(), ["100% 100%", "cover"].contains(size),
              (size == "cover" || p["background-position"] == nil),
              let imageCSS = p["background-image"], imageCSS.lowercased().hasPrefix("url("), imageCSS.hasSuffix(")") else { return nil }
        // Restrict support to unambiguous CSS positions.  Unsupported forms
        // fall back to the ordinary converter rather than silently centering.
        let position = (p["background-position"] ?? "center").lowercased().split(whereSeparator: { $0.isWhitespace })
        func percent(_ value: Substring) -> Double? {
            guard value.hasSuffix("%"), let n = Double(value.dropLast()), n.isFinite, (0...100).contains(n) else { return nil }
            return n / 100
        }
        func axis(_ value: Substring, horizontal: Bool) -> Double? {
            if value == "center" { return 0.5 }
            if horizontal && value == "left" || !horizontal && value == "top" { return 0 }
            if horizontal && value == "right" || !horizontal && value == "bottom" { return 1 }
            return percent(value)
        }
        var positionX = 0.5, positionY = 0.5
        if size == "cover" {
            if position.count == 1, let x = axis(position[0], horizontal: true) { positionX = x }
            else if position.count == 1, let y = axis(position[0], horizontal: false) { positionY = y }
            else if position.count == 2, let x = axis(position[0], horizontal: true), let y = axis(position[1], horizontal: false) { positionX = x; positionY = y }
            else { return nil }
            // Vertical cropping needs cross-reader verification before enabling.
            guard positionY == 0.5 else { return nil }
        }
        func dimension(_ key:String) -> Double? {
            guard let raw = p[key], raw.hasSuffix("px"), let n = Double(raw.dropLast(2)), n.isFinite else { return nil }; return n
        }
        guard let width = dimension("width"), let height = dimension("height"), width >= 200, width <= 500, height >= 25, height <= 300,
              let content = xmlNodeGetContent(node) else { return nil }
        var child = node.pointee.children
        while let item = child { if item.pointee.type != XML_TEXT_NODE { xmlFree?(content); return nil }; child = item.pointee.next }
        let text = String(cString:content); xmlFree?(content)
        guard !text.isEmpty, text.count <= 8, text.unicodeScalars.allSatisfy({ (32..<127).contains($0.value) || (0x3400...0x9fff).contains($0.value) }) else { return nil }
        var raw = String(imageCSS.dropFirst(4).dropLast()).trimmingCharacters(in:.whitespacesAndNewlines)
        if raw.count >= 2 && ((raw.first == "\"" && raw.last == "\"") || (raw.first == "'" && raw.last == "'")) { raw = String(raw.dropFirst().dropLast()) }
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty, !decoded.contains(":"), !decoded.hasPrefix("/") else { throw DocumentConversionError.resourceUnavailable }
        let directory = input.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let url = directory.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/"), let source = CGImageSourceCreateWithURL(url as CFURL,nil), let original = CGImageSourceCreateImageAtIndex(source,0,nil), original.width <= 10000, original.height <= 10000 else { throw DocumentConversionError.resourceUnavailable }
        var image = original
        if size == "cover" {
            // Resolve the CSS cover crop inside the fixed element, not the page.
            // Clip before drawing so the resulting bitmap matches the element box.
            guard let ctx = CGContext(data:nil, width:Int(ceil(width)), height:Int(ceil(height)), bitsPerComponent:8, bytesPerRow:0,
                                      space:CGColorSpaceCreateDeviceRGB(), bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DocumentConversionError.failed }
            let scale = max(width / Double(original.width), height / Double(original.height))
            let w = Double(original.width) * scale, h = Double(original.height) * scale
            // Core Graphics uses a bottom-left origin; CSS positions use top-left.
            ctx.draw(original,in:CGRect(x:(width-w)*positionX,y:(height-h)*(1-positionY),width:w,height:h))
            guard let rendered = ctx.makeImage() else { throw DocumentConversionError.failed }
            image = rendered
        }
        return (SimplePageBackground(image:image,x:0,y:0,width:width,height:height,repeats:false,cover:false,centered:false),text)
        }
        var parts: [(SimplePageBackground, String)] = []
        for node in nodesToPaint { guard let parsed = try parseNode(node) else { return nil }; parts.append(parsed) }
        guard let firstPart = parts.first else { return nil }
        if parts.count == 1 { return (firstPart.0, firstPart.1, nil) }
        let widths = parts.prefix(cellsPerRow).map { $0.0.width }
        let rowCount = parts.count / cellsPerRow
        var heights: [Double] = []
        for row in 0..<rowCount {
            let rowParts = parts[(row*cellsPerRow)..<((row+1)*cellsPerRow)]
            guard Set(rowParts.map { $0.0.height }).count == 1 else { return nil }
            heights.append(rowParts.first!.0.height)
            for column in 0..<cellsPerRow where parts[row*cellsPerRow+column].0.width != widths[column] { return nil }
        }
        guard Set(parts.map { $0.1 }).count == parts.count, Set(widths).count == 1, Set(heights).count == 1,
              widths.reduce(0,+) <= 500,
              heights.reduce(0,+) <= 400 else { return nil }
        let totalWidth = widths.reduce(0,+), totalHeight = heights.reduce(0,+)
        guard let ctx = CGContext(data:nil,width:Int(ceil(totalWidth)),height:Int(ceil(totalHeight)),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DocumentConversionError.failed }
        var top = 0.0
        for row in 0..<rowCount {
            var x = 0.0
            for column in 0..<cellsPerRow {
                let part = parts[row*cellsPerRow+column].0
                ctx.draw(part.image,in:CGRect(x:x,y:totalHeight-top-heights[row],width:part.width,height:heights[row])); x += part.width
            }
            top += heights[row]
        }
        guard let image = ctx.makeImage() else { throw DocumentConversionError.failed }
        return (SimplePageBackground(image:image,x:0,y:0,width:totalWidth,height:totalHeight,repeats:false,cover:false,centered:false),firstPart.1,SimpleTableGeometry(columnWidths:widths,rowHeights:heights))
    }

    private func addPageBackground(_ background: SimplePageBackground, to docx: URL, scratch: URL, elementText: String? = nil, tableGeometry: SimpleTableGeometry? = nil) throws {
        let fm = FileManager.default
        let repair = scratch.appendingPathComponent("page-background", isDirectory: true)
        let paths = ["word/document.xml", "word/_rels/document.xml.rels", "[Content_Types].xml"]
        try fm.createDirectory(at: repair.appendingPathComponent("word/media", isDirectory: true), withIntermediateDirectories: true)
        for path in paths {
            let file = repair.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: file.path, contents: nil) else { throw DocumentConversionError.failed }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-p", docx.path, path == "[Content_Types].xml" ? "\\[Content_Types\\].xml" : path]; unzip.standardOutput = handle; unzip.standardError = FileHandle.nullDevice
            try Task.checkCancellation(); try unzip.run(); try waitDocumentProcess(unzip); try handle.close()
            guard unzip.terminationStatus == 0 else { throw DocumentConversionError.invalidOutput }
        }
        let document = try XMLDocument(contentsOf: repair.appendingPathComponent(paths[0]))
        var renderedImage = background.image
        var anchorX = background.x, anchorY = background.y
        var anchorWidth = background.width, anchorHeight = background.height
        var repeatSection: XMLElement?
        if background.repeats || background.cover {
            let sections = try document.nodes(forXPath: "//*[local-name()='sectPr']").compactMap { $0 as? XMLElement }
            guard sections.count == 1, let section = sections.first,
                  try section.nodes(forXPath: "./*[local-name()='headerReference']").isEmpty,
                  let page = try section.nodes(forXPath: "./*[local-name()='pgSz']").first as? XMLElement,
                  let wText = page.attribute(forName: "w:w")?.stringValue, let hText = page.attribute(forName: "w:h")?.stringValue,
                  let pageTwipsW = Double(wText), let pageTwipsH = Double(hText) else { return }
            let pageW = pageTwipsW / 15, pageH = pageTwipsH / 15
            guard pageW > 0, pageH > 0, pageW <= 2000, pageH <= 3000,
                  background.width >= 1, background.height >= 1,
                  ceil(pageW / background.width + 2) * ceil(pageH / background.height + 2) <= 100000 else { return }
            let width = Int(ceil(pageW)), height = Int(ceil(pageH))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DocumentConversionError.failed }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            if background.cover {
                let scale = max(pageW / background.width, pageH / background.height)
                let w = background.width * scale, h = background.height * scale
                let x = background.centered ? (pageW - w) / 2 : background.x
                let y = background.centered ? (pageH - h) / 2 : background.y
                context.draw(background.image, in: CGRect(x: x, y: y, width: w, height: h))
            } else {
                let startX = background.x.truncatingRemainder(dividingBy: background.width) - background.width
                let startY = background.y.truncatingRemainder(dividingBy: background.height) - background.height
                var y = startY
                while y < pageH {
                    try Task.checkCancellation()
                    var x = startX
                    while x < pageW {
                        context.draw(background.image, in: CGRect(x:x,y:y,width:background.width,height:background.height))
                        x += background.width
                    }
                    y += background.height
                }
            }
            guard let composite = context.makeImage() else { throw DocumentConversionError.failed }
            renderedImage = composite; anchorX = 0; anchorY = 0; anchorWidth = pageW; anchorHeight = pageH
            repeatSection = section
        }
        let media = repair.appendingPathComponent("word/media/moriq-page-background.png")
        guard let destination = CGImageDestinationCreateWithURL(media as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw DocumentConversionError.failed }
        CGImageDestinationAddImage(destination, renderedImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw DocumentConversionError.failed }
        let relationships = try XMLDocument(contentsOf: repair.appendingPathComponent(paths[1]))
        let rels = try relationships.nodes(forXPath: "//*[local-name()='Relationship']").compactMap { $0 as? XMLElement }
        let ids = Set(rels.compactMap { $0.attribute(forName: "Id")?.stringValue })
        var id = "rIdMoriqPageBackground"; var number = 2
        while ids.contains(id) { id = "rIdMoriqPageBackground\(number)"; number += 1 }
        let relationship = XMLElement(name: "Relationship")
        relationship.addAttribute(XMLNode.attribute(withName: "Id", stringValue: id) as! XMLNode)
        relationship.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image") as! XMLNode)
        relationship.addAttribute(XMLNode.attribute(withName: "Target", stringValue: "media/moriq-page-background.png") as! XMLNode)
        relationships.rootElement()?.addChild(relationship)
        try relationships.xmlData.write(to: repair.appendingPathComponent(paths[1]))
        let types = try XMLDocument(contentsOf: repair.appendingPathComponent(paths[2]))
        let defaults = try types.nodes(forXPath: "//*[local-name()='Default']").compactMap { $0 as? XMLElement }
        if !defaults.contains(where: { $0.attribute(forName: "Extension")?.stringValue?.lowercased() == "png" }) {
            let png = XMLElement(name: "Default")
            png.addAttribute(XMLNode.attribute(withName: "Extension", stringValue: "png") as! XMLNode)
            png.addAttribute(XMLNode.attribute(withName: "ContentType", stringValue: "image/png") as! XMLNode)
            types.rootElement()?.addChild(png)
        }
        try types.xmlData.write(to: repair.appendingPathComponent(paths[2]))
        let paragraphPath = elementText == nil ? "//*[local-name()='body']/*[local-name()='p']" : "//*[local-name()='body']//*[local-name()='p']"
        let paragraphs = try document.nodes(forXPath: paragraphPath).compactMap { $0 as? XMLElement }
        let paragraph: XMLElement
        if let elementText {
            let matching = try paragraphs.filter { paragraph in
                try paragraph.nodes(forXPath: ".//*[local-name()='t']").compactMap { $0.stringValue }.joined() == elementText
            }
            guard matching.count == 1, let match = matching.first else { return }
            paragraph = match
            let cells = try match.nodes(forXPath: "./ancestor::*[local-name()='tc']").compactMap { $0 as? XMLElement }
            if !cells.isEmpty {
                // Writer's HTML import may shrink a CSS-sized one-cell table
                // to its text width. Restore the explicit CSS box before
                // anchoring the image, or text wraps independently of it.
                guard cells.count == 1, let cell = cells.first,
                      let row = try cell.nodes(forXPath: "./ancestor::*[local-name()='tr']").first as? XMLElement,
                      let table = try row.nodes(forXPath: "./ancestor::*[local-name()='tbl']").first as? XMLElement else { return }
                let columnWidths = tableGeometry?.columnWidths ?? [background.width]
                let rowHeights = tableGeometry?.rowHeights ?? [background.height]
                let tableCells = try table.nodes(forXPath: ".//*[local-name()='tc']").compactMap { $0 as? XMLElement }
                let grid = try table.nodes(forXPath: "./*[local-name()='tblGrid']/*[local-name()='gridCol']").compactMap { $0 as? XMLElement }
                let tableRows = try table.nodes(forXPath: "./*[local-name()='tr']").compactMap { $0 as? XMLElement }
                guard tableRows.count == rowHeights.count, tableCells.count == columnWidths.count * rowHeights.count,
                      grid.count == columnWidths.count,
                      let tableWidth = try table.nodes(forXPath: "./*[local-name()='tblPr']/*[local-name()='tblW']").first as? XMLElement,
                      let total = tableWidth.attribute(forName:"w:w") else { return }
                total.stringValue = String(Int((columnWidths.reduce(0,+) * 15).rounded()))
                for i in columnWidths.indices {
                    guard let gridWidth = grid[i].attribute(forName:"w:w") else { return }
                    let twips = String(Int((columnWidths[i] * 15).rounded()))
                    gridWidth.stringValue = twips
                }
                for i in tableCells.indices {
                    guard let cellWidth = try tableCells[i].nodes(forXPath:"./*[local-name()='tcPr']/*[local-name()='tcW']").first as? XMLElement,
                          let attr = cellWidth.attribute(forName:"w:w") else { return }
                    attr.stringValue = String(Int((columnWidths[i % columnWidths.count] * 15).rounded()))
                    guard let align = try tableCells[i].nodes(forXPath:"./*[local-name()='tcPr']/*[local-name()='vAlign']").first as? XMLElement,
                          let value = align.attribute(forName:"w:val") else { return }
                    value.stringValue = "top"
                    for spacing in try tableCells[i].nodes(forXPath:".//*[local-name()='pPr']/*[local-name()='spacing']").compactMap({ $0 as? XMLElement }) {
                        spacing.attribute(forName:"w:after")?.stringValue = "0"
                    }
                }
                for i in tableRows.indices {
                    guard let rowProperties = try tableRows[i].nodes(forXPath:"./*[local-name()='trPr']").first as? XMLElement,
                          try rowProperties.nodes(forXPath:"./*[local-name()='trHeight']").isEmpty else { return }
                    let rowHeight = try XMLElement(xmlString:"<w:trHeight xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" w:val=\"\(Int((rowHeights[i] * 15).rounded()))\" w:hRule=\"exact\"/>")
                    rowProperties.addChild(rowHeight)
                }
                if let spacing = try match.nodes(forXPath:"./*[local-name()='pPr']/*[local-name()='spacing']").first as? XMLElement {
                    spacing.attribute(forName:"w:after")?.stringValue = "0"
                }
            }
        } else {
            guard let first = paragraphs.first else { throw DocumentConversionError.invalidOutput }
            paragraph = first
        }
        let x = Int((anchorX * 9525).rounded()), y = Int((anchorY * 9525).rounded())
        let width = Int((anchorWidth * 9525).rounded()), height = Int((anchorHeight * 9525).rounded())
        let run = """
        <w:r xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" allowOverlap="1" behindDoc="1" locked="0" layoutInCell="1" relativeHeight="0"><wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>\(x)</wp:posOffset></wp:positionH><wp:positionV relativeFrom="page"><wp:posOffset>\(y)</wp:posOffset></wp:positionV><wp:extent cx="\(width)" cy="\(height)"/><wp:effectExtent t="0" r="0" b="0" l="0"/><wp:wrapNone/><wp:docPr id="987654" name="Page Background"/><wp:cNvGraphicFramePr/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="Page Background"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>
        """
        var positionedRun = elementText == nil ? run : run.replacingOccurrences(of: "relativeFrom=\"page\"", with: "relativeFrom=\"column\"", range: run.range(of: "relativeFrom=\"page\""))
            .replacingOccurrences(of: "relativeFrom=\"page\"", with: "relativeFrom=\"paragraph\"")
        if tableGeometry != nil { positionedRun = positionedRun.replacingOccurrences(of: "layoutInCell=\"1\"", with: "layoutInCell=\"0\"") }
        var extraPaths: [String] = []
        if let section = repeatSection {
            // A page-relative picture in a header repeats on each Word page;
            // use it only when no existing header or other section can be lost.
            let headerName = "moriq-background-\(UUID().uuidString).xml"
            var headerID = "rIdMoriqRepeatHeader"; var n = 2
            while ids.contains(headerID) { headerID = "rIdMoriqRepeatHeader\(n)"; n += 1 }
            let headerRel = XMLElement(name: "Relationship")
            headerRel.addAttribute(XMLNode.attribute(withName: "Id", stringValue: headerID) as! XMLNode)
            headerRel.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header") as! XMLNode)
            headerRel.addAttribute(XMLNode.attribute(withName: "Target", stringValue: headerName) as! XMLNode)
            relationships.rootElement()?.addChild(headerRel)
            try relationships.xmlData.write(to: repair.appendingPathComponent(paths[1]))
            let override = XMLElement(name: "Override")
            override.addAttribute(XMLNode.attribute(withName: "PartName", stringValue: "/word/\(headerName)") as! XMLNode)
            override.addAttribute(XMLNode.attribute(withName: "ContentType", stringValue: "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml") as! XMLNode)
            types.rootElement()?.addChild(override)
            try types.xmlData.write(to: repair.appendingPathComponent(paths[2]))
            for kind in ["default", "first", "even"] {
                let reference = try XMLElement(xmlString: "<w:headerReference xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" w:type=\"\(kind)\" r:id=\"\(headerID)\"/>")
                section.insertChild(reference, at: 0)
            }
            let headerPath = "word/\(headerName)", relPath = "word/_rels/\(headerName).rels"
            let header = """
            <?xml version="1.0" encoding="UTF-8"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="1" w:lineRule="exact"/></w:pPr>\(run)</w:p></w:hdr>
            """
            let headerRelationships = """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="\(id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/moriq-page-background.png"/></Relationships>
            """
            try Data(header.utf8).write(to: repair.appendingPathComponent(headerPath))
            try Data(headerRelationships.utf8).write(to: repair.appendingPathComponent(relPath))
            extraPaths = [headerPath, relPath]
        } else {
            paragraph.addChild(try XMLElement(xmlString: positionedRun))
        }
        try document.xmlData.write(to: repair.appendingPathComponent(paths[0]))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = repair
        zip.arguments = ["-q", docx.path] + paths + ["word/media/moriq-page-background.png"] + extraPaths
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try Task.checkCancellation(); try zip.run(); try waitDocumentProcess(zip)
        guard zip.terminationStatus == 0 else { throw DocumentConversionError.failed }
    }

    /// LibreOffice writes file hyperlinks relative to its temporary output
    /// folder. Make them absolute before moving the document out of scratch.
    private func stabilizeHTMLWordLinks(_ docx: URL, scratch: URL) throws {
        let fm = FileManager.default
        let relDir = scratch.appendingPathComponent("link-repair/word/_rels", isDirectory: true)
        try fm.createDirectory(at: relDir, withIntermediateDirectories: true)
        let relFile = relDir.appendingPathComponent("document.xml.rels")
        guard fm.createFile(atPath: relFile.path, contents: nil) else { throw DocumentConversionError.failed }
        let handle = try FileHandle(forWritingTo: relFile)
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", docx.path, "word/_rels/document.xml.rels"]
        unzip.standardOutput = handle; unzip.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try unzip.run() } catch { try? handle.close(); throw DocumentConversionError.failed }
        defer { try? handle.close() }
        try waitDocumentProcess(unzip)
        try handle.close()
        guard unzip.terminationStatus == 0, let document = try? XMLDocument(contentsOf: relFile) else { throw DocumentConversionError.invalidOutput }
        let elements = try document.nodes(forXPath: "//*[local-name()='Relationship']").compactMap { $0 as? XMLElement }
        var changed = false
        for element in elements {
            guard element.attribute(forName: "Type")?.stringValue?.hasSuffix("/hyperlink") == true,
                  element.attribute(forName: "TargetMode")?.stringValue == "External",
                  let target = element.attribute(forName: "Target"), let raw = target.stringValue,
                  !raw.hasPrefix("#"), let parsed = URL(string: raw), parsed.scheme == nil,
                  let decoded = raw.removingPercentEncoding else { continue }
            let url = URL(fileURLWithPath: decoded, relativeTo: docx.deletingLastPathComponent().appendingPathComponent("", isDirectory: true)).absoluteURL
            target.stringValue = url.standardizedFileURL.absoluteString
            changed = true
        }
        guard changed else { return }
        try document.xmlData.write(to: relFile, options: .atomic)
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = scratch.appendingPathComponent("link-repair", isDirectory: true)
        zip.arguments = ["-q", docx.path, "word/_rels/document.xml.rels"]
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try zip.run() } catch { throw DocumentConversionError.failed }
        try waitDocumentProcess(zip)
        guard zip.terminationStatus == 0 else { throw DocumentConversionError.failed }
    }

    /// Make HTML self-contained: the scratch directory is removed after publishing.
    private func inlineHTMLImages(_ htmlURL: URL, scratch: URL, sourceURL: URL? = nil) throws {
        // libxml's HTML parser distinguishes real img/src attributes from
        // comments, scripts and attributes such as data-src. NONET prevents
        // parsing from fetching external resources.
        let original = try Data(contentsOf: htmlURL)
        guard original.count <= Int(Int32.max) else { throw DocumentConversionError.invalidInput }
        let isUTF8 = String(data: original, encoding: .utf8) != nil
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue)
        let document = original.withUnsafeBytes { bytes -> htmlDocPtr? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            return htmlReadMemory(base, Int32(bytes.count), nil, isUTF8 ? "UTF-8" : nil, options)
        }
        guard let document else { throw DocumentConversionError.invalidInput }
        defer { xmlFreeDoc(document) }
        let root = scratch.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var modified = false
        var baseURL = sourceURL
        if let sourceURL {
            // The temporary HTML copy must retain the original document base;
            // otherwise LibreOffice resolves relative links into scratch.
            func firstBase(_ first: xmlNodePtr?) -> xmlNodePtr? {
                var current = first
                while let node = current {
                    if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name,
                       String(cString: name).lowercased() == "base", xmlHasProp(node, "href") != nil { return node }
                    if let found = firstBase(node.pointee.children) { return found }
                    current = node.pointee.next
                }
                return nil
            }
            if let base = firstBase(xmlDocGetRootElement(document)), let value = xmlGetProp(base, "href") {
                let raw = String(cString: value); xmlFree?(value)
                if let resolved = URL(string: raw, relativeTo: sourceURL)?.absoluteURL {
                    baseURL = resolved
                    guard resolved.absoluteString.withCString({ xmlSetProp(base, "href", $0) }) != nil else { throw DocumentConversionError.invalidOutput }
                    modified = true
                }
            }
        }
        func walk(_ first: xmlNodePtr?) throws {
            var current = first
            while let node = current {
                if let baseURL, node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name,
                   String(cString: name).lowercased() == "a", let value = xmlGetProp(node, "href") {
                    let raw = String(cString: value); xmlFree?(value)
                    if !raw.isEmpty, !raw.hasPrefix("#"), let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                       resolved.absoluteString != raw {
                        guard resolved.absoluteString.withCString({ xmlSetProp(node, "href", $0) }) != nil else { throw DocumentConversionError.invalidOutput }
                        modified = true
                    }
                }
                if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name,
                   String(cString: name).lowercased() == "img", let value = xmlGetProp(node, "src") {
                    let raw = String(cString: value)
                    xmlFree?(value)
                    if !raw.lowercased().hasPrefix("data:image/") {
                        let decoded = raw.removingPercentEncoding ?? raw
                        guard !decoded.hasPrefix("/"), !decoded.contains(":") else { throw DocumentConversionError.resourceUnavailable }
                        let path = scratch.appendingPathComponent(decoded).resolvingSymlinksInPath().standardizedFileURL
                        guard path.path.hasPrefix(root),
                              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 100_000_000,
                              let data = try? Data(contentsOf: path, options: .mappedIfSafe),
                              let image = CGImageSourceCreateWithData(data as CFData, nil),
                              let identifier = CGImageSourceGetType(image) as String?,
                              let type = UTType(identifier), let mime = type.preferredMIMEType, mime.hasPrefix("image/") else { throw DocumentConversionError.resourceUnavailable }
                        let embedded = "data:\(mime);base64,\(data.base64EncodedString())"
                        guard embedded.withCString({ xmlSetProp(node, "src", $0) }) != nil else { throw DocumentConversionError.invalidOutput }
                        modified = true
                    }
                }
                try walk(node.pointee.children)
                current = node.pointee.next
            }
        }
        try walk(xmlDocGetRootElement(document))
        // Preserve encoding and exact input bytes when no rewriting is needed.
        guard modified else { return }
        var output: UnsafeMutablePointer<xmlChar>?
        var count: Int32 = 0
        htmlDocDumpMemoryFormat(document, &output, &count, 0)
        guard let output, count > 0 else { throw DocumentConversionError.invalidOutput }
        defer { xmlFree?(output) }
        try Data(bytes: output, count: Int(count)).write(to: htmlURL, options: .atomic)
    }

    private func prepareMarkdown(_ input: URL, scratch: URL) throws -> URL {
        let text = try String(contentsOf: input, encoding: .utf8)
        let original = text as NSString
        let whole = NSRange(location: 0, length: original.length)
        var protected: [NSRange] = []
        var location = 0
        var fence: (marker: Character, count: Int)?
        while location < original.length {
            var start = 0, end = 0, contentsEnd = 0
            original.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = original.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if let current = fence {
                protected.append(NSRange(location: start, length: end - start))
                let run = trimmed.prefix(while: { $0 == current.marker }).count
                if indent <= 3 && run >= current.count && trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            } else if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix(while: { $0 == marker }).count
                if run >= 3 { fence = (marker, run); protected.append(NSRange(location: start, length: end - start)) }
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                protected.append(NSRange(location: start, length: end - start))
            }
            location = end
        }
        let code = try NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)[^\n]*?(?<!`)\1(?!`)"#)
        protected += code.matches(in: text, range: whole).map(\.range)
        func isProtected(_ range: NSRange) -> Bool { protected.contains { NSIntersectionRange($0, range).length > 0 } }
        func normalized(_ id: String) -> String { id.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
        let definitions = try NSRegularExpression(pattern: #"(?m)^ {0,3}\[([^\]]+)\]:[ \t]*(?:<([^>]+)>|([^\s]+))"#)
        var references: [String: String] = [:]
        for match in definitions.matches(in: text, range: whole) where !isProtected(match.range) {
            let key = normalized(original.substring(with: match.range(at: 1)))
            let index = match.range(at: 2).location != NSNotFound ? 2 : 3
            if references[key] == nil { references[key] = original.substring(with: match.range(at: index)) }
        }
        struct Replacement { let range: NSRange; let link: String; let alt: String? }
        var replacements: [Replacement] = []
        let inline = try NSRegularExpression(pattern: #"(?<!\\)\!\[[^\]]*\]\((?:<([^>]+)>|([^\s\)]+))"#)
        for match in inline.matches(in: text, range: whole) where !isProtected(match.range) {
            let index = match.range(at: 1).location != NSNotFound ? 1 : 2
            replacements.append(Replacement(range: match.range(at: index), link: original.substring(with: match.range(at: index)), alt: nil))
        }
        let referencesPattern = try NSRegularExpression(pattern: #"(?<!\\)\!\[([^\]]*)\]\[([^\]]*)\]"#)
        for match in referencesPattern.matches(in: text, range: whole) where !isProtected(match.range) {
            let alt = original.substring(with: match.range(at: 1)), label = original.substring(with: match.range(at: 2))
            if let link = references[normalized(label.isEmpty ? alt : label)] { replacements.append(Replacement(range: match.range, link: link, alt: alt)) }
        }
        let shortcut = try NSRegularExpression(pattern: #"(?<!\\)\!\[([^\]]+)\](?![\[(])"#)
        for match in shortcut.matches(in: text, range: whole) where !isProtected(match.range) {
            let alt = original.substring(with: match.range(at: 1))
            if let link = references[normalized(alt)] { replacements.append(Replacement(range: match.range, link: link, alt: alt)) }
        }
        let rawHTML = try NSRegularExpression(pattern: #"(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#)
        let altPattern = try NSRegularExpression(pattern: #"(?i)\balt\s*=\s*["']([^"']*)["']"#)
        for match in rawHTML.matches(in: text, range: whole) where !isProtected(match.range) {
            let tag = original.substring(with: match.range)
            let altMatch = altPattern.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
            let alt = altMatch.map { (tag as NSString).substring(with: $0.range(at: 1)).replacingOccurrences(of: "]", with: "\\]") } ?? ""
            replacements.append(Replacement(range: match.range, link: original.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&"), alt: alt))
        }
        let base = input.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = base.path == "/" ? "/" : base.path + "/"
        let preparedText = NSMutableString(string: text)
        for item in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            let link = item.link.removingPercentEncoding ?? item.link
            let lowercase = link.lowercased()
            if lowercase.hasPrefix("data:") || lowercase.hasPrefix("https://") || lowercase.hasPrefix("http://") {
                if let alt = item.alt { preparedText.replaceCharacters(in: item.range, with: "![\(alt)](\(link))") }
                continue
            }
            guard !link.hasPrefix("/"), !link.contains(":"), !link.contains("#") else { throw DocumentConversionError.resourceUnavailable }
            let file = base.appendingPathComponent(link).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let size = attrs[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= 100_000_000,
                  let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let identifier = CGImageSourceGetType(image) as String?, let type = UTType(identifier),
                  let mime = type.preferredMIMEType, mime.hasPrefix("image/") else { throw DocumentConversionError.resourceUnavailable }
            let dataURL = "data:\(mime);base64,\(bytes.base64EncodedString())"
            preparedText.replaceCharacters(in: item.range, with: item.alt.map { "![\($0)](\(dataURL))" } ?? dataURL)
        }
        let prepared = scratch.appendingPathComponent("moriq-input-\(UUID().uuidString).md")
        try Data((preparedText as String).utf8).write(to: prepared, options: .withoutOverwriting)
        return prepared
    }

    /// Markdown images are external files, so publish them together with the document.
    private func publishMarkdownIfNeeded(_ markdown: URL, input: URL, scratch: URL, outputDirectory: URL) throws -> URL? {
        // Use the same code-aware validation as input conversion; literals inside
        // Markdown examples must not be mistaken for missing image files.
        _ = try prepareMarkdown(markdown, scratch: scratch)
        let assets = scratch.appendingPathComponent("assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: assets.path), !(try FileManager.default.contentsOfDirectory(atPath: assets.path)).isEmpty else { return nil }
        let package = scratch.appendingPathComponent("markdown-package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: assets, to: package.appendingPathComponent("assets", isDirectory: true))
        let base = input.deletingPathExtension().lastPathComponent
        try FileManager.default.moveItem(at: markdown, to: package.appendingPathComponent(base).appendingPathExtension("md"))
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(base) - Markdown\(suffix)", isDirectory: true)
            let result = package.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
            if result == 0 { return output }
            if errno != EEXIST { throw DocumentConversionError.filesystem(errno) }
        }
        throw DocumentConversionError.failed
    }

    /// CSV and TSV hold one sheet each; count the sheets before export.
    private func sheetCount(_ input: URL, scratch: URL, engine: URL) throws -> Int {
        let ext = input.pathExtension.lowercased()
        guard ["xls", "xlsx", "ods"].contains(ext) else { return 1 }
        var source = input
        if ext == "xls" {
            let folder = scratch.appendingPathComponent("sheet-check", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let p = Process(); p.executableURL = engine
            try configureOfficeFonts(p, scratch:scratch)
            p.arguments = ["-env:UserInstallation=\(scratch.appendingPathComponent("check-profile").absoluteString)", "--headless", "--convert-to", "xlsx", "--outdir", folder.path, input.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try Task.checkCancellation()
            do { try p.run() } catch { throw DocumentConversionError.failed }
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
            try waitDocumentProcess(p); timeout.cancel()
        try Task.checkCancellation()
            guard p.terminationStatus == 0 else { throw DocumentConversionError.failed }
            source = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension("xlsx")
        }
        let xml = scratch.appendingPathComponent("sheet-check.xml")
        guard FileManager.default.createFile(atPath: xml.path, contents: nil), let handle = try? FileHandle(forWritingTo: xml) else { throw DocumentConversionError.failed }
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", source.path, ext == "ods" ? "content.xml" : "xl/workbook.xml"]
        unzip.standardOutput = handle; unzip.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try unzip.run() } catch { try? handle.close(); throw DocumentConversionError.failed }
        let timeout = DispatchWorkItem { if unzip.isRunning { unzip.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        try waitDocumentProcess(unzip); timeout.cancel(); try? handle.close()
        try Task.checkCancellation()
        guard unzip.terminationStatus == 0, let parser = XMLParser(contentsOf: xml) else { throw DocumentConversionError.invalidOutput }
        let counter = SheetCounter(ods: ext == "ods")
        parser.delegate = counter; parser.shouldResolveExternalEntities = false
        guard parser.parse(), counter.count > 0 else { throw DocumentConversionError.invalidOutput }
        return counter.count
    }

    private func exportSheets(_ input: URL, outputDirectory: URL, scratch: URL, engine: URL, ext: String, count: Int) throws -> URL {
        let folder = scratch.appendingPathComponent("sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let separator = ext == "tsv" ? "9" : "44"
        let filter = "\(ext):Text - txt - csv (StarCalc):\(separator),34,76,1,,0,false,true,true,false,false,-1"
        let p = Process(); p.executableURL = engine
        try configureOfficeFonts(p, scratch:scratch)
        p.arguments = ["-env:UserInstallation=\(scratch.appendingPathComponent("export-profile").absoluteString)", "--headless", "--convert-to", filter, "--outdir", folder.path, input.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try p.run() } catch { throw DocumentConversionError.failed }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(p); timeout.cancel()
        try Task.checkCancellation()
        let outputs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        guard p.terminationStatus == 0, outputs.count == count,
              outputs.allSatisfy({ $0.pathExtension.lowercased() == ext && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) }) else { throw DocumentConversionError.invalidOutput }
        let base = input.deletingPathExtension().lastPathComponent + " - " + ext.uppercased() + " 工作表"
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent(base + suffix, isDirectory: true)
            let result = folder.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
            if result == 0 { return output }
            if errno != EEXIST { throw DocumentConversionError.filesystem(errno) }
        }
        throw DocumentConversionError.failed
    }

    func convert(input: URL, outputDirectory: URL, format: UTType) throws -> URL {
        try Task.checkCancellation()
        guard let kind = Self.kind(input), let ext = format.preferredFilenameExtension else { throw DocumentConversionError.unsupported }
        if !Self.targets(for: kind).contains(format) {
            if Self.officeEngine == nil && Self.targets(for: kind, officeAvailable: true).contains(format) { throw DocumentConversionError.engineMissing }
            throw DocumentConversionError.unsupported
        }
        // Office ZIP-based containers must not be silently interpreted by the
        // conversion engine as plain text when their content is not a package.
        let packageEntries = ["docx": "word/document.xml", "xlsx": "xl/workbook.xml", "pptx": "ppt/presentation.xml", "odt": "content.xml", "ods": "content.xml", "odp": "content.xml", "epub": "META-INF/container.xml"]
        if let requiredEntry = packageEntries[input.pathExtension.lowercased()] {
            guard let handle = try? FileHandle(forReadingFrom: input) else { throw DocumentConversionError.invalidInput }
            defer { try? handle.close() }
            guard (try? handle.read(upToCount: 4)) == Data([0x50, 0x4b, 0x03, 0x04]) else { throw DocumentConversionError.invalidInput }
            let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            check.arguments = ["-Z1", input.path, requiredEntry]
            check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
            try Task.checkCancellation()
            do { try check.run() } catch { throw DocumentConversionError.invalidInput }
            let timeout = DispatchWorkItem { if check.isRunning { check.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
            try waitDocumentProcess(check); timeout.cancel()
        try Task.checkCancellation()
            guard check.terminationStatus == 0 else { throw DocumentConversionError.invalidInput }
        }
        if kind == .pdf && PDFPageExporter.supportedFormats().contains(format) { return try PDFPageExporter().convert(input: input, outputDirectory: outputDirectory, format: format) }
        if kind == .pdf && format.identifier == "org.webmproject.webp" { return try ExternalMediaConverter().convertPDFPages(input: input, outputDirectory: outputDirectory) }
        let fm = FileManager.default
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: scratch, withIntermediateDirectories: false) }
        catch { throw DocumentConversionError.failed }
        defer { try? fm.removeItem(at: scratch) }
        let generated: URL
        if kind == .pdf {
            guard let pdf = PDFDocument(url: input), !pdf.isLocked else { throw DocumentConversionError.failed }
            let attributed = NSMutableAttributedString()
            var hasText = false
            var hasUnrepresentedPage = false
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                if index > 0 { attributed.append(NSAttributedString(string: "\n\n")) }
                if let content = page.attributedString, !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    attributed.append(content); hasText = true
                } else {
                    hasUnrepresentedPage = true
                }
            }
            let editableTarget = ["docx", "rtf", "html", "odt"].contains(ext)
            if format != .plainText && hasUnrepresentedPage && !editableTarget { throw DocumentConversionError.noText }
            if !hasText && !editableTarget && format != .plainText { throw DocumentConversionError.noText }
            if editableTarget, let engine = Self.packagedPDFEngine {
                let document = try Self.packagedDocument(input, in: scratch, engine: engine)
                generated = ext == "docx" ? document : try DocumentConverter().convert(input: document, outputDirectory: scratch, format: format)
            } else if ext == "docx" && hasUnrepresentedPage {
                generated = try Self.imageDocument(pdf, in: scratch)
            } else if ext == "docx", let engine = Self.qualityPDFEngine {
                generated = try Self.qualityDocument(input, in: scratch, engine: engine)
            } else if ext == "docx" {
                // Falling back to an attributed string silently drops embedded images.
                throw DocumentConversionError.packagedEngineMissing
            } else if editableTarget {
                throw DocumentConversionError.packagedEngineMissing
            } else if format == .plainText {
                var pages: [String] = []
                var foundText = false
                for index in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: index) else { throw DocumentConversionError.invalidOutput }
                    let text = try Self.pdfText(page)
                    if text.isEmpty { pages.append("[第\(index + 1)页未识别到文字]") }
                    else { foundText = true; pages.append(text) }
                }
                guard foundText else { throw DocumentConversionError.noText }
                let extracted = scratch.appendingPathComponent("result.txt")
                try Data(pages.joined(separator: "\n\n").utf8).write(to: extracted, options: .withoutOverwriting)
                generated = extracted
            } else {
                let outputType: NSAttributedString.DocumentType
                if ext == "docx" { outputType = .officeOpenXML }
                else if ext == "html" { outputType = .html }
                else { outputType = .rtf }
                let intermediateExt = outputType == .officeOpenXML ? "docx" : (outputType == .html ? "html" : "rtf")
                let intermediate = scratch.appendingPathComponent("result.\(intermediateExt)")
                let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: outputType])
                try data.write(to: intermediate, options: .withoutOverwriting)
                generated = ext == intermediateExt ? intermediate : try DocumentConverter().convert(input: intermediate, outputDirectory: scratch, format: format)
            }
        } else if kind == .word && (["md", "epub"].contains(input.pathExtension.lowercased()) || ["md", "epub"].contains(ext)) {
            guard let engine = Self.pandocEngine else { throw DocumentConversionError.engineMissing }
            generated = try pandocConvert(input, format: ext, scratch: scratch, engine: engine)
        } else {
            guard let engine = Self.officeEngine else { throw DocumentConversionError.engineMissing }
            if kind == .sheet && ["csv", "tsv"].contains(ext) {
                let count = try sheetCount(input, scratch: scratch, engine: engine)
                if count > 1 { return try exportSheets(input, outputDirectory: outputDirectory, scratch: scratch, engine: engine, ext: ext, count: count) }
            }
            let profile = scratch.appendingPathComponent("profile", isDirectory: true)
            let process = Process(); process.executableURL = engine
            try configureOfficeFonts(process, scratch:scratch)
            let isHTML = ["html", "htm"].contains(input.pathExtension.lowercased())
            let pageBackground = isHTML && ext == "docx" ? try simplePageBackground(input) : nil
            let elementBackground = isHTML && ext == "docx" && pageBackground == nil ? try simpleElementBackground(input) : nil
            let filter = kind == .sheet && ext == "tsv" ? "tsv:Text - txt - csv (StarCalc):9,34,76,1" : (isHTML && ext == "docx" ? "docx:Office Open XML Text" : (isHTML && ext == "rtf" ? "rtf:Rich Text Format" : ext))
            // Writer otherwise retains HTML image links, so the resulting Word
            // file silently loses pictures when moved or the source disappears.
            // Work on a private copy and embed readable local images first.
            var officeInput = input
            if isHTML && ext == "docx" {
                let prepared = scratch.appendingPathComponent("source", isDirectory: true)
                try fm.createDirectory(at: prepared, withIntermediateDirectories: false)
                officeInput = prepared.appendingPathComponent(input.lastPathComponent)
                try fm.copyItem(at: input, to: officeInput)
                try inlineHTMLImages(officeInput, scratch: input.deletingLastPathComponent(), sourceURL: input)
            }
            process.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", filter, "--outdir", scratch.path, officeInput.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try Task.checkCancellation()
            do { try process.run() } catch { throw DocumentConversionError.failed }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
            try waitDocumentProcess(process); timeout.cancel()
        try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw DocumentConversionError.failed }
            generated = scratch.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
            if isHTML && ext == "docx" {
                try stabilizeHTMLWordLinks(generated, scratch: scratch)
                if let pageBackground { try addPageBackground(pageBackground, to: generated, scratch: scratch) }
                else if let elementBackground { try addPageBackground(elementBackground.0, to: generated, scratch: scratch, elementText: elementBackground.1, tableGeometry: elementBackground.2) }
            }
            if kind == .sheet { try Self.preserveSpreadsheetView(input: input, output: generated) }
        }
        if ext == "html" { try inlineHTMLImages(generated, scratch: scratch) }
        if ext == "md", let package = try publishMarkdownIfNeeded(generated, input: input, scratch: scratch, outputDirectory: outputDirectory) { return package }
        let attributes = try? fm.attributesOfItem(atPath: generated.path)
        guard let bytes = attributes?[.size] as? NSNumber, bytes.intValue > 0 else { throw DocumentConversionError.invalidOutput }
        if format == .pdf { guard let pdf = PDFDocument(url: generated), pdf.pageCount > 0 else { throw DocumentConversionError.invalidOutput } }
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).\(ext)")
            let result = generated.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw DocumentConversionError.filesystem(errno) }
        }
        throw DocumentConversionError.failed
    }
}

/// Archive one file or folder without moving it or overwriting an existing archive.
enum ArchiveConversionError: Error { case unsupported, duplicateNames, failed, invalidOutput, filesystem(Int32) }
struct ArchiveConverter {
    static let tarType = UTType(importedAs: "local.moriq.archive.tar", conformingTo: .archive)
    static let tarGzipType = UTType(importedAs: "local.moriq.archive.targz", conformingTo: .archive)
    static func isArchiveTarget(_ type: UTType) -> Bool { type == .zip || type == tarType || type == tarGzipType }
    /// Bundle multiple selections in one archive without copying or moving originals.
    func batch(inputs: [URL], outputDirectory: URL, format: UTType) throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard inputs.count > 1, Self.isArchiveTarget(format), inputs.allSatisfy({ $0.isFileURL && fm.fileExists(atPath: $0.path) }) else { throw ArchiveConversionError.unsupported }
        let names = inputs.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(names).count == names.count else { throw ArchiveConversionError.duplicateNames }
        let ext = format == .zip ? "zip" : (format == Self.tarGzipType ? "tar.gz" : "tar")
        // Never place the archive inside a selected directory: tar could otherwise
        // include its own growing temporary output while walking that directory.
        let selectedDirectories = inputs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        var destination = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        while selectedDirectories.contains(where: { path in destination.path == path || destination.path.hasPrefix(path == "/" ? "/" : path + "/") }) {
            let parent = destination.deletingLastPathComponent()
            guard parent.path != destination.path else { throw ArchiveConversionError.unsupported }
            destination = parent
        }
        let temporary = destination.appendingPathComponent(".moriq-\(UUID().uuidString).\(ext)")
        defer { try? fm.removeItem(at: temporary) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        var args = ["-a", "-cf", temporary.path]
        for input in inputs { args += ["-C", input.deletingLastPathComponent().path, "./" + input.lastPathComponent] }
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw ArchiveConversionError.failed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(process); timeout.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, let bytes = (try? fm.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber, bytes.intValue > 0 else { throw ArchiveConversionError.invalidOutput }
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let resultURL = destination.appendingPathComponent("归档文件\(suffix).\(ext)")
            let result = temporary.withUnsafeFileSystemRepresentation { src in resultURL.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return resultURL }
            if errno != EEXIST { throw ArchiveConversionError.filesystem(errno) }
        }
        throw ArchiveConversionError.failed
    }
    func tar(input: URL, outputDirectory: URL, gzip: Bool) throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard input.isFileURL, fm.fileExists(atPath: input.path), fm.isExecutableFile(atPath: "/usr/bin/tar") else { throw ArchiveConversionError.unsupported }
        let ext = gzip ? "tar.gz" : "tar"
        let temporary = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).\(ext)")
        defer { try? fm.removeItem(at: temporary) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [gzip ? "-czf" : "-cf", temporary.path, "-C", input.deletingLastPathComponent().path, "--", input.lastPathComponent]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw ArchiveConversionError.failed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(process); timeout.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, let bytes = (try? fm.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber, bytes.intValue > 0 else { throw ArchiveConversionError.invalidOutput }
        let isDirectory = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let name = isDirectory ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).\(ext)")
            let result = temporary.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw ArchiveConversionError.filesystem(errno) }
        }
        throw ArchiveConversionError.failed
    }
    func zip(input: URL, outputDirectory: URL) throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard input.isFileURL, fm.fileExists(atPath: input.path), fm.isExecutableFile(atPath: "/usr/bin/ditto") else { throw ArchiveConversionError.unsupported }
        let temporary = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temporary) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, temporary.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw ArchiveConversionError.failed }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        try waitDocumentProcess(process); timeout.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, let bytes = (try? fm.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber, bytes.intValue > 0 else { throw ArchiveConversionError.invalidOutput }
        let isDirectory = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let name = isDirectory ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).zip")
            let result = temporary.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw ArchiveConversionError.filesystem(errno) }
        }
        throw ArchiveConversionError.failed
    }
}

private final class SheetCounter: NSObject, XMLParserDelegate {
    let ods: Bool
    var count = 0
    init(ods: Bool) { self.ods = ods }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if ods ? elementName == "table:table" : elementName == "sheet" { count += 1 }
    }
}
