import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct Inventory {
 static func main() throws {
  let args = CommandLine.arguments
  guard args.count == 2 else { fputs("usage: inventory <copied DocumentConverter.swift>\n", stderr); exit(2) }
  let source = try String(contentsOfFile: args[1], encoding: .utf8)
  guard let start = source.range(of: "static func kind(_ url: URL)"), let end = source.range(of: "static var officeEngine:", range: start.upperBound..<source.endIndex) else { throw NSError(domain: "inventory.source", code: 1) }
  let block = String(source[start.upperBound..<end.lowerBound])
  let regex = try NSRegularExpression(pattern: "\"([a-z0-9]+)\"")
  var documentExts: Set<String> = []
  for line in block.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespaces).hasPrefix("case ") {
   let ns = line as NSString
   for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) { documentExts.insert(ns.substring(with: match.range(at: 1))) }
  }
  guard documentExts.contains("pdf"), documentExts.contains("docx"), documentExts.contains("xlsx") else { throw NSError(domain: "inventory.parse", code: 2) }
  func ext(_ type: UTType) -> String { ExternalMediaConverter.fileExtension(for: type) ?? type.identifier }
  func kindName(_ kind: DocumentConverter.Kind) -> String {
   switch kind { case .word: return "document"; case .sheet: return "spreadsheet"; case .slides: return "slides"; case .pdf: return "pdf" }
  }
  let resources = Bundle.main.resourceURL!
  #if arch(arm64)
  let arch = "arm64"
  #else
  let arch = "x86_64"
  #endif
  let fm = FileManager.default
  let bundledOffice = resources.appendingPathComponent("OfficeSuite/LibreOffice-\(arch).app/Contents/MacOS/soffice")
  let bundledPandoc = resources.appendingPathComponent("Pandoc/pandoc-\(arch)")
  let bundledFFmpeg = resources.appendingPathComponent("ffmpeg")
  let engines: [String: Any] = [
   "office_effective": DocumentConverter.officeEngine != nil, "office_bundled_executable": fm.isExecutableFile(atPath: bundledOffice.path),
   "pandoc_effective": DocumentConverter.pandocEngine != nil, "pandoc_bundled_executable": fm.isExecutableFile(atPath: bundledPandoc.path),
   "ffmpeg_effective": ExternalMediaConverter.executable != nil, "ffmpeg_bundled_executable": fm.isExecutableFile(atPath: bundledFFmpeg.path),
   "pdf_document_engine_present": DocumentConverter.packagedPDFEngine != nil,
   "system_tar_available": fm.isExecutableFile(atPath: "/usr/bin/tar"), "system_zip_available": fm.isExecutableFile(atPath: "/usr/bin/zip")
  ]
  var pairs: [[String: String]] = []
  func add(_ category: String, _ input: String, _ target: String, _ caveat: String) {
   guard input != target else { return }
   pairs.append(["category":category, "input":input, "target":target, "status":"declared_conditional_not_verified", "condition":caveat])
  }
  for input in documentExts.sorted() {
   guard let kind = DocumentConverter.kind(URL(fileURLWithPath: "/synthetic/input.\(input)")) else { continue }
   for target in DocumentConverter.targets(for: kind) {
    add(kindName(kind), input, ext(target), kind == .pdf ? "PDF content, available engine, and target determine behavior" : "requires available engine; file validity and fidelity not checked")
   }
  }
  let imageDecoders = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
  let imageEncoders = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
  let imageTargets = (ImageConverter.allowed + ImageConverter.additionalOutputs).filter { imageEncoders.contains($0.identifier) } + [.pdf] + (ExternalMediaConverter.executable == nil ? [] : [UTType("org.webmproject.webp")].compactMap { $0 })
  for type in ImageConverter.allowedInputs where imageDecoders.contains(type.identifier) {
   for input in (type.tags[.filenameExtension] ?? []).sorted() {
    for target in imageTargets where target == .pdf || !type.conforms(to: target) {
     add("still_image", input.lowercased(), ext(target), "single readable frame; displayed targets depend on runtime ImageIO and engine")
    }
   }
  }
  if ExternalMediaConverter.executable != nil {
   for input in ExternalMediaConverter.audioInputs.sorted() { for target in ExternalMediaConverter.audioTargets() { add("audio", input, ext(target), "file, codec, channel layout and precision may reject target") } }
   for input in ExternalMediaConverter.videoInputs.sorted() {
    for target in ExternalMediaConverter.videoTargets() { add("video", input, ext(target), "file, codec and track compatibility may reject target") }
    for target in ExternalMediaConverter.audioTargets() { add("video_to_audio", input, ext(target), "shown only if all selected videos have audio; subject to codec compatibility") }
   }
   for input in ["gif", "png", "apng", "webp"] { for target in ExternalMediaConverter.videoTargets() { add("animated_image", input, ext(target), "only for valid multi-frame animation; timing and transparency restrictions apply") } }
  } else {
   for input in AudioConverter.inputs.sorted() { for target in AudioConverter.targets { add("audio", input, ext(target), "system fallback; file, codec, channel layout and precision may reject target") } }
  }
  let tiffTargets = PDFPageExporter.supportedFormats() + [.pdf] + (ExternalMediaConverter.executable == nil ? [] : [UTType("org.webmproject.webp")].compactMap { $0 })
  for target in tiffTargets { add("multipage_tiff", "tiff", ext(target), "multi-page TIFF only; page count capped at 500; output image pages in folder") }
  pairs.sort { ($0["category"]!, $0["input"]!, $0["target"]!) < ($1["category"]!, $1["input"]!, $1["target"]!) }
  let output: [String: Any] = ["schema":1, "architecture":arch, "engines":engines, "pairs":pairs,
   "archive_targets":["zip", "tar", "tar.gz"], "archive_condition":"existing file or directory; runtime permissions, duplicate names and disk limits apply",
   "video_system_fallback":"AVFoundation targets require inspection of each actual file; no invented static matrix",
   "evidence":"Declarations only; no conversion was run. Refer to KNOWN_GAPS.md and docs/CONVERSION_AUDIT_2026-11-11.md for limited evidence; no pair is certified by this inventory.",
   "limitations":["source code and supplied bundle may not be the same build", "multi-file target intersection and same-type behavior are input dependent", "exported image format lists depend on macOS ImageIO", "audio track, codec and timing validation needs real fixtures", "identifier aliases may denote the same format"]]
  let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
  FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
 }
}
