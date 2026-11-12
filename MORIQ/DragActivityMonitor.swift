import AppKit

/// Observes presses cheaply while idle and follows the active drag at display-like cadence.
@MainActor final class DragActivityMonitor {
    private let tick: () -> Void
    private let onMouseDown: () -> Void
    private var mouseMonitors: [Any] = []
    private var idleTimer: Timer?
    private var followTimer: Timer?
    private var releasedAt: Date?
    private var activity: NSObjectProtocol?
    init(tick: @escaping () -> Void, onMouseDown: @escaping () -> Void = {}) { self.tick = tick; self.onMouseDown = onMouseDown }
    func start() {
        guard idleTimer == nil else { return }
        tick()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            Task { @MainActor in self?.onMouseDown(); self?.follow() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.onMouseDown(); self?.follow(); return event
        }) { mouseMonitors.append(local) }
        let idle = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 { self.follow() }
                else if self.followTimer == nil { self.tick() }
            }
        }
        idle.tolerance = 0.4
        RunLoop.main.add(idle, forMode: .common); idleTimer = idle
    }
    private func follow() {
        guard followTimer == nil else { return }
        releasedAt = nil
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Following a user file drag")
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTick() }
        }
        RunLoop.main.add(timer, forMode: .common); followTimer = timer
        tick()
    }
    private func followTick() {
        tick()
        if NSEvent.pressedMouseButtons & 1 != 0 { releasedAt = nil; return }
        if releasedAt == nil { releasedAt = Date() }
        if let releasedAt, Date().timeIntervalSince(releasedAt) >= 0.35 { endFollow() }
    }
    private func endFollow() {
        followTimer?.invalidate(); followTimer = nil; releasedAt = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    func stop() {
        endFollow(); idleTimer?.invalidate(); idleTimer = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }; mouseMonitors.removeAll()
    }
}
