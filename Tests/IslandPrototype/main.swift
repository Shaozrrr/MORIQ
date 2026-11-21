import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor final class Host: NSObject, NSApplicationDelegate {
    private let suite = "local.moriq.island.windowserver.\(UUID())"
    private var island: IslandPrototype?
    private var phases: [IslandInteraction.Phase] = []
    private var selections: [String] = []
    private var original: CGPoint?
    private var fullscreenWindow: AXUIElement?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hardware = Process()
        let output = Pipe()
        hardware.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        hardware.arguments = ["-n", "hw.model"]
        hardware.standardOutput = output
        do { try hardware.run(); hardware.waitUntilExit() } catch { finish("Hardware check failed", status: 2) }
        let model = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard model.hasPrefix("VirtualMac") else { finish("Refused to post events outside a virtual Mac", status: 2) }
        guard CGPreflightPostEventAccess(), let screen = NSScreen.main,
              let event = CGEvent(source: nil),
              let safari = NSWorkspace.shared.frontmostApplication,
              safari.bundleIdentifier == "com.apple.Safari" else { finish("Safari must be active in the guest and guest event posting authorized", status: 2) }
        NSApp.setActivationPolicy(.accessory)
        original = event.location
        if CommandLine.arguments.contains("--fullscreen") {
            Task { @MainActor in
                await self.enterFullscreen(safari: safari)
                guard let currentScreen = NSScreen.main else { self.finish("Missing full-screen display", status: 2) }
                self.testInteraction(screen: currentScreen, safari: safari)
            }
        } else {
            testInteraction(screen: screen, safari: safari)
        }
    }

    private func enterFullscreen(safari: NSRunningApplication) async {
        let application = AXUIElementCreateApplication(safari.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            finish("Safari has no accessible focused window", status: 2)
        }
        let element = window as! AXUIElement
        if !isFullscreen(element) {
            guard AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanTrue) == .success else {
                finish("Cannot request Safari native full screen", status: 2)
            }
            fullscreenWindow = element
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !isFullscreen(element) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isFullscreen(element) else { finish("Safari did not enter native full screen", status: 1) }
        try? await Task.sleep(for: .seconds(1))
        print("PASS Safari native full-screen state verified")
    }

    private func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else { return false }
        return value as? Bool == true
    }

    private func testInteraction(screen: NSScreen, safari: NSRunningApplication) {
        let defaults = UserDefaults(suiteName: suite)!
        let content = IslandPreviewContent(defaults: defaults)
        for module in IslandModule.allCases { content.setEnabled(module, module == .shelf || module == .notes) }
        content.move(.shelf, to: 0)
        content.select(.shelf)
        content.contents[.shelf] = ["MORIQ-SHELF-TEST"]
        content.contents[.notes] = ["MORIQ-NOTES-TEST"]
        let prototype = IslandPrototype(content: content, focusTimer: FocusTimerStore(defaults: defaults))
        island = prototype
        prototype.onPhaseChange = { [weak self] phase in self?.phases.append(phase) }
        prototype.onSelect = { [weak self] value in self?.selections.append(value) }
        prototype.start()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let top = CGPoint(x: bounds.midX + 100, y: bounds.minY + max(3, screen.safeAreaInsets.top + 2))
        let outside = CGPoint(x: bounds.minX + 30, y: bounds.midY)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.move(top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard let panel = prototype.diagnosticPanel(), panel.isVisible, self.phases.contains(.expanded) else {
                self.finish("Hover did not display an actual panel", status: 1)
            }
            // The fixture has two tabs (both two characters). The second is
            // within the first 100 points of the horizontal tab strip.
            let tab = CGPoint(x: bounds.minX + panel.frame.minX - screen.frame.minX + 74,
                              y: bounds.minY + screen.frame.maxY - panel.frame.maxY + 19)
            self.move(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.post(.leftMouseDown, at: tab) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.post(.leftMouseUp, at: tab) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { self.move(outside) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == safari.processIdentifier
            let selectedOnce = self.selections == [IslandModule.notes.rawValue]
            let closed = prototype.diagnosticPanel()?.isVisible == false && self.phases.last == .hidden
            print("selectedOnce=\(selectedOnce) closed=\(closed) safariFocus=\(frontmost)")
            let passed = selectedOnce && closed && frontmost
            self.finish(passed ? "PASS guest WindowServer hover, tab click and hide" : "FAIL guest WindowServer interaction", status: passed ? 0 : 1)
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        if type == .leftMouseDown || type == .leftMouseUp { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    private func move(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        post(.mouseMoved, at: point)
    }

    private func finish(_ message: String, status: Int32) -> Never {
        island?.stop()
        if let original { move(original) }
        if let fullscreenWindow { AXUIElementSetAttributeValue(fullscreenWindow, "AXFullScreen" as CFString, kCFBooleanFalse) }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        print(message)
        fflush(stdout)
        exit(status)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Host()
    app.delegate = delegate
    app.run()
}
