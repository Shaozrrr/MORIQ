import CoreGraphics
import Foundation
let center = CGPoint(x: 210, y: 210)
for count in 1...8 {
    for index in 0..<count {
        let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
        let point = CGPoint(x: center.x + sin(angle) * 120, y: center.y + cos(angle) * 120)
        precondition(WheelGeometry.index(point: point, center: center, count: count) == index)
    }
}
for index in 0..<9 {
    let count = index < 4 ? 4 : 5
    let local = index < 4 ? index : index - 4
    let angle = CGFloat(local) * 2 * .pi / CGFloat(count)
    let radius: CGFloat = index < 4 ? 86 : 153
    let point = CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
    precondition(WheelGeometry.index(point: point, center: center, count: 9) == index)
}
precondition(WheelGeometry.index(point: CGPoint(x: 210, y: 329), center: center, count: 9) == nil)
precondition(WheelGeometry.index(point: center, center: center, count: 8) == nil)
precondition(WheelGeometry.index(point: CGPoint(x: 210, y: 395), center: center, count: 8) == nil)
precondition(WheelGeometry.index(point: center, center: center, count: 0) == nil)
for count in [4, 8, 9, 12] {
 let ringCount = count > 8 ? count - WheelGeometry.innerCount(for: count) : count
 let radius: CGFloat = count > 8 ? 153 : 120
 let boundary = CGFloat.pi / CGFloat(ringCount)
 for offset in [-0.5, 0.0, 0.5] {
  let angle = boundary + CGFloat(offset) * .pi / 180
  let point = CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
  precondition(WheelGeometry.index(point: point, center: center, count: count) == nil)
 }
 let inside = boundary - 3 * .pi / 180
 let point = CGPoint(x: center.x + sin(inside) * radius, y: center.y + cos(inside) * radius)
 precondition(WheelGeometry.index(point: point, center: center, count: count) != nil)
}
precondition(WheelGeometry.innerCount(for: 12) == 4)
precondition(WheelGeometry.innerCount(for: 18) == 9)
precondition(WheelGeometry.innerCount(for: 19) == 10)
for index in 0..<18 {
 let local = index % 9, angle = CGFloat(local) * 2 * .pi / 9, radius: CGFloat = index < 9 ? 86 : 153
 let point = CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
 precondition(WheelGeometry.index(point: point, center: center, count: 18) == index)
}
for index in 0..<12 {
 let inner = index < 4, local = inner ? index : index - 4, count = inner ? 4 : 8
 let angle = CGFloat(local) * 2 * .pi / CGFloat(count), radius: CGFloat = inner ? 86 : 153
 let point = CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
 precondition(WheelGeometry.index(point: point, center: center, count: 12) == index)
}
for bounds in [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1440, y: 200, width: 1440, height: 900)] {
    for center in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.midX, y: bounds.midY)] {
        let frame = WheelGeometry.frame(center: center, size: CGSize(width: 420, height: 420), visible: bounds)
        precondition(bounds.contains(frame))
    }
}
print("PASS: single and double wheel targets, visible sector gaps, empty center and multi-display edge clamping")
