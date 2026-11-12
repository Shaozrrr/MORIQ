import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-html-background-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
let imageDestination = CGImageDestinationCreateWithURL(root.appendingPathComponent("red.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(imageDestination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(imageDestination))
let source = root.appendingPathComponent("background.html")
let html = "<html><body style=\"margin:0;padding:0;background-image:url(red.png);background-repeat:no-repeat;background-position:100px 200px\"><p>EDITABLE 4812</p></body></html>"
try html.write(to: source, atomically: true, encoding: .utf8)
let result = try DocumentConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
if let path = ProcessInfo.processInfo.environment["MORIQ_BACKGROUND_OUTPUT"] { let url = URL(fileURLWithPath: path); try? fm.removeItem(at: url); try fm.copyItem(at: result, to: url) }
func extract(_ path: String) -> Data {
 let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", result.path, path]
 let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); precondition(p.terminationStatus == 0); return data
}
let body = String(decoding: extract("word/document.xml"), as: UTF8.self)
precondition(body.contains("EDITABLE") && body.contains("4812") && body.contains("behindDoc=\"1\""))
precondition(body.contains("952500") && body.contains("1905000"), "wrong background position")
precondition(!extract("word/media/moriq-page-background.png").isEmpty)
precondition(try! String(contentsOf: source, encoding: .utf8) == html)
let sheetSource = root.appendingPathComponent("sheet.html")
let sheetHTML = "<html><head><style>\nbody { margin:0; padding:0; background-image:url(red.png); background-repeat:no-repeat; background-position:100px 200px; background-size:180px 50px; }\n</style></head><body><p>网页文字 4812</p><a href=\"https://example.com/path\">链接</a></body></html>"
try sheetHTML.write(to: sheetSource, atomically: true, encoding: .utf8)
let sheetResult = try DocumentConverter().convert(input: sheetSource, outputDirectory: root, format: UTType(filenameExtension: "docx")!)
if let path = ProcessInfo.processInfo.environment["MORIQ_STYLESHEET_OUTPUT"] { let url = URL(fileURLWithPath: path); try? fm.removeItem(at: url); try fm.copyItem(at: sheetResult, to: url) }
func sheetPart(_ path: String) -> String {
 let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", sheetResult.path, path]
 let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); precondition(p.terminationStatus == 0); return String(decoding: data, as: UTF8.self)
}
let sheetBody = sheetPart("word/document.xml"), sheetRels = sheetPart("word/_rels/document.xml.rels")
precondition(sheetBody.contains("网页文字") && sheetBody.contains("4812") && sheetBody.contains("behindDoc=\"1\"") && sheetBody.contains("952500") && sheetBody.contains("1905000") && sheetBody.contains("1714500") && sheetBody.contains("476250"))
precondition(sheetRels.contains("https://example.com/path"), "link lost")
precondition(try! String(contentsOf: sheetSource, encoding: .utf8) == sheetHTML)
try fm.removeItem(at: root.appendingPathComponent("red.png"))
do { _ = try DocumentConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: "docx")!); fatalError("missing image accepted") }
catch DocumentConversionError.resourceUnavailable { }
do { _ = try DocumentConverter().convert(input: sheetSource, outputDirectory: root, format: UTType(filenameExtension: "docx")!); fatalError("missing stylesheet image accepted") }
catch DocumentConversionError.resourceUnavailable { }
print("PASS stylesheet background and linked text; page background anchored behind editable text with offsets; input unchanged; missing image rejected")
