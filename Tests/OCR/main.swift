import AppKit
import Foundation
let image = NSImage(size: NSSize(width: 1000, height: 220))
image.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 220).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.black]
("MORIQ TEST 2026" as NSString).draw(at: NSPoint(x: 25, y: 125), withAttributes: attributes)
("测试截图 会议安排" as NSString).draw(at: NSPoint(x: 25, y: 50), withAttributes: attributes)
image.unlockFocus()
var rect = NSRect(origin: .zero, size: image.size)
let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let blocks = try OCREngine().recognizeBlocks(cg)
precondition(!blocks.isEmpty && blocks.allSatisfy { (0...1).contains($0.confidence) && $0.boundingBox.width > 0 && $0.boundingBox.height > 0 })
let result = blocks.map(\.text).joined(separator: "\n")
precondition(result.uppercased().contains("MORIQ"))
precondition(result.contains("测试") && result.contains("会议"))
print("PASS Vision OCR synthetic Chinese and English with confidence and bounding boxes")
