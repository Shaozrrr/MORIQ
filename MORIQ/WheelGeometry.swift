import CoreGraphics
import Foundation

enum WheelGeometry {
    static let panelSize: CGFloat = 420
    static let outerRadius: CGFloat = 184
    static let innerStart: CGFloat = 56
    static let innerEnd: CGFloat = 116
    static let outerStart: CGFloat = 122
    static func innerCount(for count: Int) -> Int { count > 16 ? (count + 1) / 2 : (count > 8 ? max(4, count - 8) : 0) }
    private static func sector(_ angle: CGFloat, count: Int) -> Int? {
        let sweep = 2 * CGFloat.pi / CGFloat(count)
        let nearest = (angle / sweep).rounded()
        // Match the 1.5-degree visual inset on each side of WheelSegment.
        let distance = abs(angle - nearest * sweep)
        guard distance <= max(0, sweep / 2 - .pi / 120) else { return nil }
        return Int(nearest) % count
    }
    static func index(point: CGPoint, center: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = hypot(dx, dy)
        let angle = atan2(dx, dy)
        let positive = angle < 0 ? angle + 2 * .pi : angle
        if count > 8 {
            let innerCount = innerCount(for: count)
            let outerCount = count - innerCount
            if radius >= innerStart && radius <= innerEnd {
                return sector(positive, count: innerCount)
            }
            if radius >= outerStart && radius <= outerRadius {
                guard let index = sector(positive, count: outerCount) else { return nil }
                return innerCount + index
            }
            return nil
        }
        guard radius >= innerStart && radius <= outerRadius else { return nil }
        return sector(positive, count: count)
    }
    static func frame(center: CGPoint, size: CGSize, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        let x = min(max(center.x - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(center.y - height / 2, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
