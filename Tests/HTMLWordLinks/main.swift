import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-html-link-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let sourceDir = root.appendingPathComponent("来源 文件", isDirectory: true)
try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
let source = sourceDir.appendingPathComponent("source.html")
let html = "<html><body><p>链接测试 4812</p><a href=\"参考.pdf\">文档链接</a><a href=\"https://example.com/page\">网页</a><a href=\"#section\">页内</a><p id=\"section\">尾部</p></body></html>"
try html.write(to: source, atomically: true, encoding: .utf8)
try Data("fixture".utf8).write(to: sourceDir.appendingPathComponent("参考.pdf"))
let result = try DocumentConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
unzip.arguments = ["-p", result.path, "word/_rels/document.xml.rels"]
let pipe = Pipe(); unzip.standardOutput = pipe; try unzip.run()
let rels = pipe.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit(); precondition(unzip.terminationStatus == 0)
let xml = try XMLDocument(data: rels)
let targets = try xml.nodes(forXPath: "//*[local-name()='Relationship']").compactMap { ($0 as? XMLElement)?.attribute(forName: "Target")?.stringValue }
guard let local = targets.compactMap(URL.init(string:)).first(where: { $0.isFileURL }) else { fatalError("no local file hyperlink: \(targets)") }
precondition(local.standardizedFileURL == sourceDir.appendingPathComponent("参考.pdf").standardizedFileURL, "local link wrong: \(local)")
precondition(targets.contains("https://example.com/page"))
precondition(try! String(contentsOf: source, encoding: .utf8) == html)
let bodyProcess = Process(); bodyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
bodyProcess.arguments = ["-p", result.path, "word/document.xml"]
let bodyPipe = Pipe(); bodyProcess.standardOutput = bodyPipe; try bodyProcess.run()
let bodyData = bodyPipe.fileHandleForReading.readDataToEndOfFile(); bodyProcess.waitUntilExit()
let body = String(decoding: bodyData, as: UTF8.self)
precondition(body.contains("链接测试 ") && body.contains("4812") && body.contains("anchor=\"section\""), "editable text or anchor lost")
let baseDirectory = sourceDir.appendingPathComponent("sub", isDirectory: true)
try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
let baseSource = sourceDir.appendingPathComponent("base.html")
let baseHTML = "<html><head><base href=\"sub/\"></head><body><a href=\"other.pdf\">目标</a></body></html>"
try baseHTML.write(to: baseSource, atomically: true, encoding: .utf8)
let baseResult = try DocumentConverter().convert(input: baseSource, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
let baseProc = Process(); baseProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); baseProc.arguments = ["-p", baseResult.path, "word/_rels/document.xml.rels"]
let basePipe = Pipe(); baseProc.standardOutput = basePipe; try baseProc.run(); let baseRels = basePipe.fileHandleForReading.readDataToEndOfFile(); baseProc.waitUntilExit()
let baseXML = try XMLDocument(data: baseRels)
let baseTargets = try baseXML.nodes(forXPath: "//*[local-name()='Relationship']").compactMap { ($0 as? XMLElement)?.attribute(forName: "Target")?.stringValue }
guard let baseLocal = baseTargets.compactMap(URL.init(string:)).first(where: { $0.isFileURL }) else { fatalError("base link missing") }
precondition(baseLocal.standardizedFileURL == baseDirectory.appendingPathComponent("other.pdf").standardizedFileURL, "base link wrong")
precondition(try! String(contentsOf: baseSource, encoding: .utf8) == baseHTML)
print("PASS text, local/web/fragment links, relative base and unmodified inputs")
