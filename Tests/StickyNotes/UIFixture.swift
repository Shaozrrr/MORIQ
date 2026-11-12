import AppKit
import Foundation
@main struct Run {
 @MainActor static func main() {
  guard CommandLine.arguments.count == 3 else { exit(2) }
  let file = URL(fileURLWithPath: CommandLine.arguments[1]); guard file.path.hasPrefix(NSTemporaryDirectory()) else { exit(3) }
  let app = NSApplication.shared; app.setActivationPolicy(.regular)
  let notes = StickyNotesCoordinator(file: file); notes.enable()
  if CommandLine.arguments[2] == "create" { notes.create() } else { notes.showAll() }
  guard let panel = app.windows.first(where: { $0.title == "屏幕便签" }) as? NSPanel,
        panel.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1,
        panel.level.rawValue < NSWindow.Level.normal.rawValue, panel.collectionBehavior.contains(.canJoinAllSpaces),
        panel.collectionBehavior.contains(.fullScreenNone), !panel.hidesOnDeactivate else { print("FAIL_PANEL_CONFIGURATION"); exit(4) }
  print("PASS_PANEL_CONFIGURATION"); fflush(stdout)
  withExtendedLifetime(notes) { app.run() }
 }
}
