import AppKit
import SwiftUI

@main struct Run {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let session = ScreenshotEditSession(image: context.makeImage()!, renderer: { source, annotations in
            Thread.sleep(forTimeInterval: 0.5)
            return ScreenshotAnnotationRenderer.render(source, annotations: annotations)
        })
        session.append(.redact(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        let renderer = ImageRenderer(content: ScreenshotInlineCanvas(session: session).frame(width: 80, height: 80))
        guard let image = renderer.cgImage else { fatalError("preview render failed") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let center = bitmap.colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!
        let corner = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        precondition(center.redComponent < 0.05 && corner.redComponent > 0.9, "pending preview exposed redacted pixels")
        session.close()
        print("PASS redaction immediately covers preview while bitmap rendering is pending")
    }
}
