import SwiftUI
import AppKit
import Translation
@main struct Probe: App {
 @StateObject var session: ScreenshotEditSession
 init() {
  let image = NSImage(size: NSSize(width: 900, height: 160)); image.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:900,height:160).fill(); ("The meeting starts at three o'clock this afternoon." as NSString).draw(at:NSPoint(x:20,y:60),withAttributes:[.font:NSFont.systemFont(ofSize:32),.foregroundColor:NSColor.black]); image.unlockFocus()
  var r=NSRect(origin:.zero,size:image.size); let cg=image.cgImage(forProposedRect:&r,context:nil,hints:nil)!
  _session=StateObject(wrappedValue:ScreenshotEditSession(image:cg,pasteboard:NSPasteboard(name:NSPasteboard.Name("local.moriq.translation-probe"))))
 }
 var body: some Scene { WindowGroup { ScreenshotInlineDetails(session:session).task {
  for i in 1...2 { session.translateLocally(to:"zh-Hans"); for _ in 0..<1200 { if !session.busy { break }; try? await Task.sleep(for:.milliseconds(100)) }; print("iteration \(i): status=\(session.status), result=\(session.result)"); fflush(stdout); guard !session.busy && session.status == "本机翻译完成" else { exit(1) }; if i == 1 { session.append(.rectangle(CGRect(x: 0.02, y: 0.02, width: 0.95, height: 0.95))) } }
  exit(0)
 } } }
}
