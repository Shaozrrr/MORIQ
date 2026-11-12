import Foundation
import AppKit
import PDFKit
import ImageIO
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-webp-cancel-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func makePDF(_ file: URL, count: Int) {
 let consumer = CGDataConsumer(url: file as CFURL)!
 var bounds = CGRect(x: 0, y: 0, width: 100, height: 150)
 let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
 for n in 0..<count {
  context.beginPDFPage(nil)
  context.setFillColor(CGColor(red: CGFloat(n) / CGFloat(count), green: 0.3, blue: 0.8, alpha: 1))
  context.fill(bounds); context.endPDFPage()
 }
 context.closePDF()
}
guard ExternalMediaConverter.executable != nil else { fatalError("ffmpeg missing") }
let source = root.appendingPathComponent("normal.pdf"); makePDF(source, count: 3)
let before = try Data(contentsOf: source)
let collision = root.appendingPathComponent("normal 页面", isDirectory: true)
try fm.createDirectory(at: collision, withIntermediateDirectories: false)
try Data("keep".utf8).write(to: collision.appendingPathComponent("sentinel"))
let out = try ExternalMediaConverter().convertPDFPages(input: source, outputDirectory: root)
precondition(out.lastPathComponent == "normal 页面 (2)")
for n in 1...3 {
 let page = out.appendingPathComponent(String(format: "%03d.webp", n))
 guard let image = CGImageSourceCreateWithURL(page as CFURL, nil), let decoded = CGImageSourceCreateImageAtIndex(image, 0, nil) else { fatalError("bad output") }
 precondition(decoded.width == 200 && decoded.height == 300)
}
precondition(fm.fileExists(atPath: collision.appendingPathComponent("sentinel").path)); precondition(try! Data(contentsOf: source) == before)
let long = root.appendingPathComponent("long.pdf"); makePDF(long, count: 80)
let longBefore = try Data(contentsOf: long)
let worker = Task.detached { try ExternalMediaConverter().convertPDFPages(input: long, outputDirectory: root) }
let deadline = Date().addingTimeInterval(20); var reached = false
while Date() < deadline {
 let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
 if let scratch = entries.first(where: { $0.lastPathComponent.hasPrefix(".moriq-") }) {
  let webps = scratch.appendingPathComponent("webp-pages")
  if (try? fm.contentsOfDirectory(atPath: webps.path).contains { $0.hasSuffix(".webp") }) == true { reached = true; break }
 }
 Thread.sleep(forTimeInterval: 0.01)
}
precondition(reached, "WebP encoding stage was not observed")
worker.cancel()
let done = DispatchSemaphore(value: 0)
Task.detached { defer { done.signal() }; do { _ = try await worker.value; preconditionFailure("cancelled output published") } catch { } }
precondition(done.wait(timeout: .now() + 10) == .success)
let files = try fm.contentsOfDirectory(atPath: root.path)
precondition(!files.contains { $0.hasPrefix(".moriq-") || $0.hasPrefix("long 页面") })
precondition(try! Data(contentsOf: long) == longBefore)
print("PASS normal multi-page WebP, collision, original preservation, cancellation during WebP stage and cleanup")
