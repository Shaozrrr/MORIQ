import AppKit
import Foundation
MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let suite = "local.moriq.island.tabs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = IslandPreviewContent(defaults: defaults)
    model.contents[.shelf] = ["fixture shelf"]
    model.contents[.clipboard] = ["fixture clipboard"]
    let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 460, height: 280), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = makeIslandContentSnapshotView(model: model)
    panel.orderFrontRegardless(); panel.contentView?.layoutSubtreeIfNeeded()
    let point = NSPoint(x: 78, y: 259)
    guard panel.contentView?.hitTest(point) != nil else { print("FAIL missing hit view"); exit(1) }
    func event(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    }
    guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { exit(2) }
    panel.sendEvent(down); panel.sendEvent(up)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    print("selected=\(model.selection.selected?.rawValue ?? "none")")
    let ok = model.selection.selected == .clipboard && model.contents[.clipboard] == ["fixture clipboard"]
    panel.orderOut(nil); exit(ok ? 0 : 1)
}
