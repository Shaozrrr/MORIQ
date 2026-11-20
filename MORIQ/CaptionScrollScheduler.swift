import Foundation

/// Pure scroll coordination. Text, history and persistence remain the caller's
/// responsibility. Anchors must come from the currently rendered layout.
struct CaptionScrollScheduler {
    struct Anchor: Equatable {
        let id: String
        let y: Double
    }
    struct Action: Equatable {
        let token: UInt64
        let anchorID: String
        let destinationY: Double
        let duration: TimeInterval
    }

    private let now: () -> TimeInterval
    private let maxPending: Int
    private let duration: TimeInterval
    private var anchors: [Anchor] = []
    private var cursorID: String?
    private var layoutID: UInt64?
    private var token: UInt64 = 0
    private var active: Action?
    private var earliestNext: TimeInterval = 0
    private(set) var followsLatest = true
    private(set) var reduceMotion = false

    init(maxPending: Int = 4, duration: TimeInterval = 0.2,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(maxPending > 0 && duration >= 0)
        self.maxPending = maxPending
        self.duration = duration
        self.now = now
    }

    /// Returns true if the caller must cancel its running visual animation.
    /// Increment layoutID whenever width/font/line layout changes. IDs must
    /// identify rendered lines and be unique within this snapshot.
    @discardableResult
    mutating func update(anchors newAnchors: [Anchor], layoutID newLayoutID: UInt64,
                         viewportY: Double) -> Bool {
        guard viewportY.isFinite, newAnchors.allSatisfy({ $0.y.isFinite }),
              Set(newAnchors.map(\.id)).count == newAnchors.count else { return false }
        let layoutChanged = layoutID != nil && layoutID != newLayoutID
        let invalidActive = active.map { current in
            !newAnchors.contains(where: { $0.id == current.anchorID && $0.y == current.destinationY })
        } ?? false
        let cancel = active != nil && (layoutChanged || invalidActive)
        anchors = newAnchors
        layoutID = newLayoutID
        if cancel { invalidateAction() }
        if layoutChanged || cursorID == nil || !newAnchors.contains(where: { $0.id == cursorID }) {
            cursorID = newAnchors.last(where: { $0.y <= viewportY + 0.5 })?.id ?? newAnchors.first?.id
        }
        return cancel
    }

    /// Called on deliberate user scrolling; immediately invalidate in-flight work.
    @discardableResult
    mutating func pauseFollowing() -> Bool {
        followsLatest = false
        let cancel = active != nil
        invalidateAction()
        return cancel
    }

    /// Resume from the line actually at the viewport, not from stale history.
    mutating func resumeFollowing(viewportY: Double) {
        guard viewportY.isFinite else { return }
        invalidateAction()
        followsLatest = true
        cursorID = anchors.last(where: { $0.y <= viewportY + 0.5 })?.id ?? anchors.first?.id
    }

    @discardableResult
    mutating func setReduceMotion(_ enabled: Bool) -> Bool {
        guard reduceMotion != enabled else { return false }
        reduceMotion = enabled
        let cancel = active != nil
        invalidateAction()
        return cancel
    }

    /// Returns one row transition; caller renders it and calls complete(token:).
    /// If overloaded, skips intermediate animations, never source/history data.
    mutating func nextAction() -> Action? {
        guard followsLatest, active == nil, now() >= earliestNext,
              let cursorID, let index = anchors.firstIndex(where: { $0.id == cursorID }),
              index + 1 < anchors.count else { return nil }
        let pendingCount = anchors.count - index - 1
        let targetIndex = pendingCount > maxPending ? anchors.count - maxPending : index + 1
        let anchor = anchors[targetIndex]
        token &+= 1
        let action = Action(token: token, anchorID: anchor.id, destinationY: anchor.y,
                            duration: reduceMotion || pendingCount > maxPending ? 0 : duration)
        active = action
        return action
    }

    /// Old completion callbacks after pause, relayout or draft removal are ignored.
    @discardableResult
    mutating func complete(token completed: UInt64) -> Bool {
        guard let action = active, action.token == completed else { return false }
        cursorID = action.anchorID
        active = nil
        earliestNext = now() + (reduceMotion ? 0 : 0.04)
        return true
    }

    private mutating func invalidateAction() {
        token &+= 1
        active = nil
        earliestNext = 0
    }
}
