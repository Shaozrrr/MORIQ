import AppKit
import CoreGraphics

// Simulated displays only: each has a different global origin, scale and color.
// The production selection callback receives display-local AppKit coordinates;
// toolbar placement receives the corresponding global coordinates.
let displays: [(CGRect, CGFloat, NSColor)] = [
    (CGRect(x: 0, y: 0, width: 160, height: 100), 2, .red),
    (CGRect(x: -160, y: -40, width: 160, height: 100), 1, .blue),
    (CGRect(x: 160, y: 30, width: 160, height: 100), 1.5, .green),
    (CGRect(x: 0, y: -100, width: 160, height: 100), 2, .yellow)
]
let selection = CGRect(x: 30, y: 25, width: 40, height: 30)
for (frame, scale, expected) in displays {
    let width = Int(frame.width * scale), height = Int(frame.height * scale)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(expected.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let rect = ScreenshotGeometry.crop(selection: selection, screen: frame.size,
                                       pixels: CGSize(width: width, height: height))!
    precondition(rect == CGRect(x: 30 * scale, y: 45 * scale, width: 40 * scale, height: 30 * scale).integral)
    let crop = context.makeImage()!.cropping(to: rect)!
    let actual = NSBitmapImageRep(cgImage: crop).colorAt(x: crop.width / 2, y: crop.height / 2)!.usingColorSpace(.deviceRGB)!
    let color = expected.usingColorSpace(.deviceRGB)!
    precondition(abs(actual.redComponent - color.redComponent) < 0.02 && abs(actual.greenComponent - color.greenComponent) < 0.02 && abs(actual.blueComponent - color.blueComponent) < 0.02)
    let global = selection.offsetBy(dx: frame.minX, dy: frame.minY)
    let layout = ScreenshotGeometry.inlineLayout(selection: global, screen: frame, visible: frame,
                                                  toolbarSize: CGSize(width: 60, height: 12))!
    precondition(layout.image == global && frame.contains(layout.toolbar))
}
print("PASS simulated displays: negative and positive origins, mixed scales, crop pixels and toolbar placement")
