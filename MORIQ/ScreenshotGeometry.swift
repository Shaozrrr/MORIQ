import CoreGraphics
import Foundation

enum ScreenshotGeometry {
    struct InlineLayout {
        /// Global AppKit coordinates, preserving the selected image's position.
        let image: CGRect
        let toolbar: CGRect
    }
    static func inlineLayout(selection: CGRect, screen: CGRect, visible: CGRect, toolbarSize: CGSize = CGSize(width: 440, height: 52), gap: CGFloat = 8) -> InlineLayout? {
        let values = [selection.minX, selection.minY, selection.width, selection.height, screen.minX, screen.minY, screen.width, screen.height, visible.minX, visible.minY, visible.width, visible.height, toolbarSize.width, toolbarSize.height, gap]
        guard values.allSatisfy(\.isFinite), screen.width > 0, screen.height > 0,
              visible.width > 0, visible.height > 0, toolbarSize.width > 0, toolbarSize.height > 0, gap >= 0 else { return nil }
        let image = selection.standardized.intersection(screen)
        let usable = visible.standardized.intersection(screen)
        guard !image.isNull, !image.isEmpty, !usable.isNull, !usable.isEmpty else { return nil }
        let width = min(toolbarSize.width, usable.width), height = min(toolbarSize.height, usable.height)
        let x = min(max(image.midX - width / 2, usable.minX), usable.maxX - width)
        let below = image.minY - gap - height
        let above = image.maxY + gap
        let y: CGFloat
        if below >= usable.minY && below + height <= usable.maxY { y = below }
        else if above >= usable.minY && above + height <= usable.maxY { y = above }
        else {
            // Full-screen selections leave no exterior space; keep controls on-screen.
            y = min(max(image.minY + gap, usable.minY), usable.maxY - height)
        }
        return InlineLayout(image: image, toolbar: CGRect(x: x, y: y, width: width, height: height))
    }
    /// AppKit selection coordinates are bottom-left based; CGImage cropping is top-left based.
    static func crop(selection: CGRect, screen: CGSize, pixels: CGSize) -> CGRect? {
        guard screen.width > 0, screen.height > 0, pixels.width > 0, pixels.height > 0,
              screen.width.isFinite, screen.height.isFinite, pixels.width.isFinite, pixels.height.isFinite,
              selection.minX.isFinite, selection.minY.isFinite, selection.width.isFinite, selection.height.isFinite else { return nil }
        let local = selection.standardized.intersection(CGRect(origin: .zero, size: screen))
        guard !local.isNull, !local.isEmpty else { return nil }
        let sx = pixels.width / screen.width, sy = pixels.height / screen.height
        let result = CGRect(x: local.minX * sx, y: (screen.height - local.maxY) * sy,
                            width: local.width * sx, height: local.height * sy)
            .integral.intersection(CGRect(origin: .zero, size: pixels))
        return result.isNull || result.isEmpty ? nil : result
    }
}
