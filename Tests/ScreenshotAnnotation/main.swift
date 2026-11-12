import Foundation
import AppKit
import CoreGraphics
import ImageIO
let width = 400, height = 200
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
let original = context.makeImage()!
func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
let baseline = ScreenshotAnnotationRenderer.render(original, annotations: [])!
let framed = ScreenshotAnnotationRenderer.render(original, annotations: [.rectangle(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))])!
let text = ScreenshotAnnotationRenderer.render(original, annotations: [.text("MORIQ", CGPoint(x: 0.2, y: 0.4))])!
let both = ScreenshotAnnotationRenderer.render(original, annotations: [.rectangle(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)), .text("MORIQ", CGPoint(x: 0.2, y: 0.4))])!
precondition(png(original) == png(baseline))
precondition(png(framed) != png(baseline) && png(text) != png(baseline))
precondition(png(both) != png(framed) && png(both) != png(text))
precondition(both.width == width && both.height == height)
let arrow = ScreenshotAnnotationRenderer.render(original, annotations: [.arrow(CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.7, y: 0.4))])!
let pen = ScreenshotAnnotationRenderer.render(original, annotations: [.pen([CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.4, y: 0.1)])])!
let redacted = ScreenshotAnnotationRenderer.render(original, annotations: [.redact(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))])!
precondition(png(arrow) != png(baseline) && png(pen) != png(baseline))
let originalPixel = NSBitmapImageRep(cgImage: original).colorAt(x: width / 2, y: height / 2)!.usingColorSpace(.deviceRGB)!
let redactedPixel = NSBitmapImageRep(cgImage: redacted).colorAt(x: width / 2, y: height / 2)!.usingColorSpace(.deviceRGB)!
precondition(originalPixel.redComponent > 0.9 && redactedPixel.redComponent < 0.01 && redactedPixel.greenComponent < 0.01 && redactedPixel.blueComponent < 0.01)
print("PASS: rectangle, text, arrow, pen, irreversible pixel cover and output dimensions")
let small = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
small.setFillColor(CGColor(gray: 1, alpha: 1)); small.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
let masked = ScreenshotAnnotationRenderer.render(small.makeImage()!, annotations: [.redact(CGRect(x: 0.225, y: 0.225, width: 0.3, height: 0.3))])!
let pixels = NSBitmapImageRep(cgImage: masked)
for x in 4...10 { for y in 4...10 {
 let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
 precondition(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01, "redaction edge leaked at \(x),\(y)")
} }
precondition(pixels.colorAt(x: 3, y: 3)!.usingColorSpace(.deviceRGB)!.redComponent > 0.99)
print("PASS fractional redaction covers every touched pixel without antialiasing")
