import AppKit
import Foundation
@main struct Run {
 @MainActor static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-sticky-test-\(UUID())", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("notes.json")
  let store = StickyNoteStore(file: url)
  let first = store.create()!, second = store.create()!
  store.updateText("第一条\n待办", id: first); store.updateText("Second note", id: second)
  let rect = CGRect(x: -600, y: 110, width: 320, height: 280)
  store.updateWindow(rect, open: false, id: first)
  store.updateWindow(CGRect(x: CGFloat.infinity, y: 0, width: 320, height: 280), open: true, id: first)
  precondition(store.notes.first(where: { $0.id == first })?.frame == rect)
  let oldScreen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
  let newScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  precondition(StickyNoteGeometry.restoreFrame(rect, visibleFrames: [newScreen]) == nil)
  let clipped = StickyNoteGeometry.restoreFrame(CGRect(x: -20, y: 20, width: 320, height: 280), visibleFrames: [newScreen])!
  precondition(newScreen.contains(clipped))
  precondition(StickyNoteGeometry.restoreFrame(rect, visibleFrames: [oldScreen]) == rect)
  precondition(StickyNoteGeometry.restoreFrame(CGRect(x: CGFloat.infinity, y: 0, width: 320, height: 280), visibleFrames: [newScreen]) == nil)
  precondition(store.flush())
  let restored = StickyNoteStore(file: url)
  precondition(restored.notes.count == 2 && restored.text(for: first) == "第一条\n待办")
  precondition(restored.notes.first(where: { $0.id == first })?.frame == rect && restored.notes.first(where: { $0.id == first })?.isOpen == false)
  precondition(restored.text(for: second) == "Second note")
  let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
  precondition(mode.intValue & 0o077 == 0)
  let invalid = root.appendingPathComponent("corrupt.json"); let bad = Data("not json".utf8); try bad.write(to: invalid)
  let corrupt = StickyNoteStore(file: invalid); precondition(!corrupt.canWrite && corrupt.create() == nil && corrupt.error != nil)
  let unchanged = try Data(contentsOf: invalid); precondition(unchanged == bad)
  let block = root.appendingPathComponent("block"); try Data().write(to: block)
  let failure = StickyNoteStore(file: block.appendingPathComponent("notes.json")); let item = failure.create()!; failure.updateText("retained", id: item)
  precondition(!failure.flush() && failure.error != nil && failure.text(for: item) == "retained")
  try FileManager.default.removeItem(at: block); precondition(failure.flush())
  precondition(StickyNoteStore(file: block.appendingPathComponent("notes.json")).text(for: item) == "retained")
  let backup = root.appendingPathComponent("block-backup")
  try FileManager.default.moveItem(at: block, to: backup); try Data().write(to: block)
  precondition(!failure.delete(item) && failure.text(for: item) == "retained" && failure.error != nil)
  try FileManager.default.removeItem(at: block); try FileManager.default.moveItem(at: backup, to: block)
  precondition(failure.delete(item))
  precondition(StickyNoteStore(file: block.appendingPathComponent("notes.json")).notes.isEmpty)
  print("PASS notes persistence, close state, display geometry, corruption protection, deletion and retry")
 }
}
