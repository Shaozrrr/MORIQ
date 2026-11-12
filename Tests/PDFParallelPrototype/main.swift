import AppKit
import CoreText
import Foundation
import PDFKit

let mode = CommandLine.arguments[1]
let path = URL(fileURLWithPath: CommandLine.arguments[2])
if mode == "fixture" {
    var bounds = CGRect(x: 0, y: 0, width: 900, height: 1200)
    let context = CGContext(consumer: CGDataConsumer(url: path as CFURL)!, mediaBox: &bounds, nil)!
    for page in 0..<6 {
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): NSColor.black.cgColor]
        for row in 0..<16 {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "DOCUMENT PAGE \(page) ROW \(row) 4826", attributes: attrs))
            context.textPosition = CGPoint(x: 40, y: 1100 - row * 60); CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF(); exit(0)
}
let count = PDFDocument(url: path)!.pageCount
let lock = NSLock()
var texts = Array<String?>(repeating: nil, count: count)
var failed = false
let workers = mode == "parallel" ? 2 : 1
let started = ProcessInfo.processInfo.systemUptime
DispatchQueue.concurrentPerform(iterations: workers) { worker in
    guard let doc = PDFDocument(url: path) else { lock.lock(); failed = true; lock.unlock(); return }
    for index in stride(from: worker, to: count, by: workers) {
        do {
            guard let page = doc.page(at: index) else { throw DocumentConversionError.invalidOutput }
            let text = try DocumentConverter.pdfText(page)
            lock.lock(); texts[index] = text; lock.unlock()
        } catch { lock.lock(); failed = true; lock.unlock() }
    }
}
guard !failed, texts.enumerated().allSatisfy({ $0.element?.contains("PAGE \($0.offset)") == true }) else { fatalError("page content/order failed") }
print("PASS \(mode) pages=\(count) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime-started))")
