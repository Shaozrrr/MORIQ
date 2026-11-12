import AppKit
import Foundation
@main struct Run {
 @MainActor static func main() {
  _ = NSApplication.shared
  let view = ShelfFileDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-missing-\(UUID())")
  view.urls = [missing]; view.isSelected = false
  var clickCalls = 0, dragCalls = 0, failures = 0
  view.select = { _ in clickCalls += 1 }; view.selectForDrag = { dragCalls += 1 }; view.transferFailure = { failures += 1 }
  func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
   NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
  }
  view.mouseDown(with: event(.leftMouseDown, 10)); view.mouseUp(with: event(.leftMouseUp, 10))
  precondition(clickCalls == 1 && dragCalls == 0)
  view.mouseDown(with: event(.leftMouseDown, 10)); view.mouseDragged(with: event(.leftMouseDragged, 12)); view.mouseUp(with: event(.leftMouseUp, 12))
  precondition(clickCalls == 2 && dragCalls == 0 && failures == 0, "small pointer motion must remain a click")
  view.mouseDown(with: event(.leftMouseDown, 10)); view.mouseDragged(with: event(.leftMouseDragged, 30))
  precondition(clickCalls == 2 && dragCalls == 1 && failures == 1)
  print("PASS click and small pointer jitter stay separate from drag-start selection")
 }
}
