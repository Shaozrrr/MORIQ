import AppKit
import Foundation
let image = NSImage(size: NSSize(width: 1000, height: 300))
image.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 300).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.black]
("PRIVATE SECRET 12345" as NSString).draw(at: NSPoint(x: 30, y: 205), withAttributes: attributes)
("VISIBLE MORIQ 67890" as NSString).draw(at: NSPoint(x: 30, y: 45), withAttributes: attributes)
image.unlockFocus()
var bounds = NSRect(origin: .zero, size: image.size)
let source = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)!
let edited = ScreenshotAnnotationRenderer.render(source, annotations: [.redact(CGRect(x: 0, y: 0, width: 1, height: 0.5))])!
let originalText = try OCREngine().recognize(source).uppercased()
let editedText = try OCREngine().recognize(edited).uppercased()
precondition(originalText.contains("SECRET") && originalText.contains("VISIBLE"))
precondition(!editedText.contains("PRIVATE") && !editedText.contains("SECRET") && editedText.contains("VISIBLE"))
print("PASS: OCR on edited image excludes redacted text while retaining visible text")
