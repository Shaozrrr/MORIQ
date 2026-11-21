import AppKit
import Foundation
@MainActor final class Host: NSObject, NSApplicationDelegate {
    private var island: IslandPrototype?
    private var selected: String?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { print("SKIP no screen"); exit(2) }
        let prototype = IslandPrototype(); island = prototype
        prototype.onSelect = { [weak self] in self?.selected = $0 }
        prototype.start()
        prototype.diagnosticShowExpanded(on: screen)
        guard let panel = prototype.diagnosticPanel(), panel.isVisible else { print("FAIL panel unavailable"); exit(1) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 60, y: panel.frame.height / 2)
        guard let view = panel.contentView?.hitTest(point) else { print("FAIL no hit view"); exit(1) }
        print("hitView=\(type(of: view))")
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { print("FAIL event creation"); exit(1) }
        panel.sendEvent(down); panel.sendEvent(up)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let result = selected == "截图"
            print("selected=\(selected ?? "none")")
            prototype.stop()
            let released = prototype.diagnosticResourcesReleased()
            print("resourcesReleased=\(released)")
            fflush(stdout); exit(result && released ? 0 : 1)
        }
    }
}
MainActor.assumeIsolated { let app = NSApplication.shared; let host = Host(); app.delegate = host; app.run() }
