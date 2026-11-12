import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-cancel-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("many.pdf")
let consumer = CGDataConsumer(url: source as CFURL)!
var bounds = CGRect(x: 0, y: 0, width: 1000, height: 1400)
let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
for n in 0..<80 {
 context.beginPDFPage(nil)
 context.setFillColor(CGColor(red: CGFloat(n) / 80, green: 0.3, blue: 0.8, alpha: 1))
 context.fill(bounds); context.endPDFPage()
}
context.closePDF()
let sourceBytes = try Data(contentsOf: source)
let worker = Task.detached { try PDFPageExporter().convert(input: source, outputDirectory: root, format: .png) }
let deadline = Date().addingTimeInterval(10)
var rendered = false
while Date() < deadline {
 let scratch = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".moriq-") }
 if let scratch, !(try fm.contentsOfDirectory(atPath: scratch.path)).isEmpty { rendered = true; break }
 Thread.sleep(forTimeInterval: 0.01)
}
precondition(rendered, "did not observe a page before cancellation")
worker.cancel()
let done = DispatchSemaphore(value: 0)
Task.detached { defer { done.signal() }; do { _ = try await worker.value; preconditionFailure("cancelled PDF export published") } catch { } }
precondition(done.wait(timeout: .now() + 15) == .success, "cancelled export did not stop")
let remaining = try fm.contentsOfDirectory(atPath: root.path)
precondition(!remaining.contains(where: { $0.hasPrefix(".moriq-") || $0.hasPrefix("many 页面") }), "partial results remain")
precondition(try! Data(contentsOf: source) == sourceBytes, "input changed")
print("PASS multiple pages: cancellation after first page, no output or staging, input unchanged")
