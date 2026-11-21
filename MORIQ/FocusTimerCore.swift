import Foundation

/// Pure timer state. Durations are measured against a continuous monotonic
/// clock within a boot, with a wall-clock fallback after a reboot.
enum FocusTimerPhase: String, Codable { case focus, rest }
enum FocusTimerStatus: String, Codable { case idle, running, paused, finished }

struct FocusTimerInstant {
    let wall: Date
    /// Seconds on a clock which advances through system sleep (e.g. mach_continuous_time).
    let continuous: TimeInterval
    /// Identifier stable during one boot and changed on reboot.
    let bootID: String
}

struct FocusTimerSnapshot: Codable {
    var phase: FocusTimerPhase
    var status: FocusTimerStatus
    var remainingAtAnchor: TimeInterval
    var wallAnchor: Date
    var continuousAnchor: TimeInterval
    var bootID: String
}

/// Notifications are injectable so the core is usable without permissions.
protocol FocusTimerNotifications {
    func schedule(after seconds: TimeInterval, phase: FocusTimerPhase)
    func cancel()
}

struct FocusTimerCore {
    private(set) var snapshot: FocusTimerSnapshot
    private let notifications: FocusTimerNotifications

    init(now: FocusTimerInstant, notifications: FocusTimerNotifications, restored: FocusTimerSnapshot? = nil) {
        self.notifications = notifications
        let fallback = FocusTimerSnapshot(phase: .focus, status: .idle, remainingAtAnchor: 25 * 60, wallAnchor: now.wall, continuousAnchor: now.continuous, bootID: now.bootID)
        if let restored, restored.remainingAtAnchor.isFinite,
           (0...Self.duration(for: restored.phase)).contains(restored.remainingAtAnchor),
           restored.continuousAnchor.isFinite, restored.continuousAnchor >= 0,
           restored.wallAnchor.timeIntervalSinceReferenceDate.isFinite, !restored.bootID.isEmpty {
            self.snapshot = restored
        } else { self.snapshot = fallback }
        refresh(now: now)
        if snapshot.status == .running { notifications.schedule(after: snapshot.remainingAtAnchor, phase: snapshot.phase) }
    }

    static func duration(for phase: FocusTimerPhase) -> TimeInterval { phase == .focus ? 25 * 60 : 5 * 60 }

    mutating func start(phase: FocusTimerPhase, now: FocusTimerInstant) {
        notifications.cancel()
        snapshot = FocusTimerSnapshot(phase: phase, status: .running, remainingAtAnchor: Self.duration(for: phase), wallAnchor: now.wall, continuousAnchor: now.continuous, bootID: now.bootID)
        notifications.schedule(after: snapshot.remainingAtAnchor, phase: phase)
    }

    mutating func pause(now: FocusTimerInstant) {
        guard snapshot.status == .running else { return }
        refresh(now: now)
        guard snapshot.status == .running else { return }
        snapshot.status = .paused
        notifications.cancel()
    }

    mutating func resume(now: FocusTimerInstant) {
        guard snapshot.status == .paused, snapshot.remainingAtAnchor > 0 else { return }
        setAnchor(now)
        snapshot.status = .running
        notifications.schedule(after: snapshot.remainingAtAnchor, phase: snapshot.phase)
    }

    mutating func end(now: FocusTimerInstant) {
        notifications.cancel()
        snapshot.status = .idle
        snapshot.remainingAtAnchor = Self.duration(for: snapshot.phase)
        setAnchor(now)
    }

    /// Call on ticks, wake and restore; return true only when transitioning to finished.
    @discardableResult mutating func refresh(now: FocusTimerInstant) -> Bool {
        guard snapshot.status == .running else { return false }
        let elapsed: TimeInterval
        if now.bootID == snapshot.bootID && now.continuous >= snapshot.continuousAnchor {
            elapsed = now.continuous - snapshot.continuousAnchor
        } else {
            // Across reboot the old monotonic reference is unavailable. A backward
            // wall-clock jump never adds time to the saved remaining duration.
            elapsed = max(0, now.wall.timeIntervalSince(snapshot.wallAnchor))
        }
        snapshot.remainingAtAnchor = max(0, snapshot.remainingAtAnchor - elapsed)
        setAnchor(now)
        if snapshot.remainingAtAnchor == 0 {
            snapshot.status = .finished
            // Do not cancel here: the system alert may still be queued at the
            // deadline. Starting or ending another timer cancels stale alerts.
            return true
        }
        return false
    }

    private mutating func setAnchor(_ now: FocusTimerInstant) {
        snapshot.wallAnchor = now.wall
        snapshot.continuousAnchor = now.continuous
        snapshot.bootID = now.bootID
    }
}
