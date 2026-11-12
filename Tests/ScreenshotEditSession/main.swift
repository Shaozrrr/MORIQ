import AppKit
import CoreGraphics
@main struct Run {
 @MainActor static func main() async {
  let ctx = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
  let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.inline-test.\(UUID().uuidString)"))
  defer { board.releaseGlobally() }
  let session = ScreenshotEditSession(image: ctx.makeImage()!, pasteboard: board)
  precondition(session.render() === session.preview)
  let rect = ScreenshotAnnotation.rectangle(CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
  let cover = ScreenshotAnnotation.redact(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
  session.append(rect); session.append(cover)
  // Export before the asynchronous preview finishes: the new cover must
  // already be present in the copied image.
  session.copy(to: board)
  for _ in 0..<100 { if session.status != "正在复制…" { break }; try? await Task.sleep(for: .milliseconds(20)) }
  precondition(session.status == "已复制图片")
  let immediate = NSImage(pasteboard: board)!
  var immediateBox = NSRect(origin: .zero, size: immediate.size)
  let immediateImage = immediate.cgImage(forProposedRect: &immediateBox, context: nil, hints: nil)!
  precondition(NSBitmapImageRep(cgImage: immediateImage).colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!.redComponent < 0.01)
  precondition(session.canUndo && !session.canRedo)
  session.undo(); precondition(session.annotations == [rect] && session.canRedo)
  session.redo(); precondition(session.annotations == [rect, cover] && !session.canRedo)
  for _ in 0..<100 {
   let p = NSBitmapImageRep(cgImage: session.preview).colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!
   if p.redComponent < 0.01 { break }
   try? await Task.sleep(for: .milliseconds(20))
  }
  let center = NSBitmapImageRep(cgImage: session.preview).colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!
  precondition(center.redComponent < 0.01)
  precondition(session.render() === session.preview)
  session.copy(to: board)
  for _ in 0..<100 { if session.status != "正在复制…" { break }; try? await Task.sleep(for: .milliseconds(20)) }
  precondition(session.status == "已复制图片")
  let copied = NSImage(pasteboard: board)!
  var box = NSRect(origin: .zero, size: copied.size)
  let cg = copied.cgImage(forProposedRect: &box, context: nil, hints: nil)!
  precondition(NSBitmapImageRep(cgImage: cg).colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!.redComponent < 0.01)
  session.result = "识别的文字"; session.copyResult()
  precondition(board.string(forType: .string) == "识别的文字" && session.status == "已复制文字")
  session.undo(); session.append(.text("测试", CGPoint(x: 0.1, y: 0.1))); precondition(!session.canRedo)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-inline-save-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  session.save(to: directory); session.save(to: directory)
  precondition(session.saving)
  session.status = "后续操作的状态"
  for _ in 0..<100 {
   if !session.saving { break }
   try? await Task.sleep(for: .milliseconds(20))
  }
  precondition(!session.saving)
  precondition(session.status == "后续操作的状态")
  precondition((try! FileManager.default.contentsOfDirectory(atPath: directory.path)).filter { $0.hasSuffix(".png") }.count == 1)
  session.close()
  print("PASS inline edit state, undo/redo, asynchronous preview, redacted copy and duplicate-save prevention")
 }
}
