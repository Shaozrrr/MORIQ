import CoreGraphics
import AppKit
let screen = CGSize(width: 100, height: 50)
let pixels = CGSize(width: 200, height: 100)
precondition(ScreenshotGeometry.crop(selection: CGRect(x: 10, y: 10, width: 20, height: 15), screen: screen, pixels: pixels) == CGRect(x: 20, y: 50, width: 40, height: 30))
precondition(ScreenshotGeometry.crop(selection: CGRect(x: -10, y: 40, width: 20, height: 20), screen: screen, pixels: pixels) == CGRect(x: 0, y: 0, width: 20, height: 20))
precondition(ScreenshotGeometry.crop(selection: CGRect(x: 200, y: 0, width: 5, height: 5), screen: screen, pixels: pixels) == nil)
precondition(ScreenshotGeometry.crop(selection: CGRect(x: 0, y: 0, width: 5, height: 5), screen: .zero, pixels: pixels) == nil)
precondition(ScreenshotGeometry.crop(selection: CGRect(x: 30, y: 25, width: -20, height: -15), screen: screen, pixels: pixels) == CGRect(x: 20, y: 50, width: 40, height: 30))
precondition(ScreenshotGeometry.crop(selection: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), screen: CGSize(width: 100, height: 100), pixels: CGSize(width: 150, height: 150)) == CGRect(x: 0, y: 149, width: 1, height: 1))
precondition(ScreenshotGeometry.crop(selection: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), screen: screen, pixels: pixels) == nil)
print("PASS: screenshot crop mapping, scaling, clipping and invalid geometry")
// Exercise real CGImage cropping, not only the arithmetic: left and right
// regions have different colors, as do top and bottom.
let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 100, y: 50, width: 100, height: 50))
let image = context.makeImage()!
func color(_ selection: CGRect) -> NSColor {
    let rect = ScreenshotGeometry.crop(selection: selection, screen: screen, pixels: pixels)!
    let crop = image.cropping(to: rect)!
    return NSBitmapImageRep(cgImage: crop).colorAt(x: crop.width / 2, y: crop.height / 2)!.usingColorSpace(.deviceRGB)!
}
let leftColor = color(CGRect(x: 5, y: 5, width: 10, height: 10))
let lowerRight = color(CGRect(x: 60, y: 5, width: 10, height: 10))
let upperRightColor = color(CGRect(x: 60, y: 35, width: 10, height: 10))
precondition(leftColor.redComponent > 0.8 && leftColor.blueComponent < 0.2)
precondition(lowerRight.blueComponent > 0.8 && lowerRight.redComponent < 0.2)
precondition(upperRightColor.greenComponent > 0.3 && upperRightColor.blueComponent < 0.4)
print("PASS: actual cropped pixels match left, lower-right and upper-right selections")
let monitor = CGRect(x: 0, y: 0, width: 1440, height: 900)
let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
let middle = ScreenshotGeometry.inlineLayout(selection: CGRect(x: 400, y: 400, width: 300, height: 200), screen: monitor, visible: visible)!
precondition(middle.image == CGRect(x: 400, y: 400, width: 300, height: 200))
precondition(middle.toolbar.maxY <= middle.image.minY && visible.contains(middle.toolbar))
let low = ScreenshotGeometry.inlineLayout(selection: CGRect(x: 10, y: 27, width: 140, height: 100), screen: monitor, visible: visible)!
precondition(low.toolbar.minY >= low.image.maxY && visible.contains(low.toolbar))
let upperRight = ScreenshotGeometry.inlineLayout(selection: CGRect(x: 1380, y: 810, width: 60, height: 60), screen: monitor, visible: visible)!
precondition(visible.contains(upperRight.toolbar) && upperRight.toolbar.maxX == visible.maxX)
let whole = ScreenshotGeometry.inlineLayout(selection: monitor, screen: monitor, visible: visible)!
precondition(whole.image == monitor && visible.contains(whole.toolbar))
let secondScreen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
let other = ScreenshotGeometry.inlineLayout(selection: CGRect(x: -1840, y: 100, width: 300, height: 200), screen: secondScreen, visible: secondScreen)!
precondition(secondScreen.contains(other.toolbar) && other.image.minX == -1840)
precondition(ScreenshotGeometry.inlineLayout(selection: CGRect(x: 1500, y: 0, width: 10, height: 10), screen: monitor, visible: visible) == nil)
precondition(ScreenshotGeometry.inlineLayout(selection: CGRect(x: 0, y: 0, width: 10, height: 10), screen: .zero, visible: visible) == nil)
print("PASS inline placement near selection, screen edges and negative-origin display")
