import Foundation
import CoreGraphics

/// Pure interaction logic. All times are monotonic seconds supplied by the host.
struct IslandInteraction {
    enum Phase: Equatable { case hidden, compact, expanded }
    private(set) var phase: Phase = .hidden
    private var candidateSince: TimeInterval?
    private var compactSince: TimeInterval?
    private var outsideSince: TimeInterval?
    private var activeScreen: UInt32?
    let enterDelay: TimeInterval = 0.16
    let expandDelay: TimeInterval = 0.30
    let leaveDelay: TimeInterval = 0.45

    mutating func reset() {
        phase = .hidden; candidateSince = nil; compactSince = nil
        outsideSince = nil; activeScreen = nil
    }

    mutating func click() {
        guard phase == .compact else { return }
        phase = .expanded; compactSince = nil
    }

    mutating func sample(now: TimeInterval, screen: UInt32?, inTrigger: Bool, inPanelOrCorridor: Bool, interacting: Bool) {
        switch phase {
        case .hidden:
            guard inTrigger, let screen else { candidateSince = nil; activeScreen = nil; return }
            if activeScreen != screen { activeScreen = screen; candidateSince = now }
            if candidateSince == nil { candidateSince = now }
            if let since = candidateSince, now - since >= enterDelay {
                phase = .expanded; compactSince = nil; outsideSince = nil
            }
        case .compact, .expanded:
            let within = screen == activeScreen && (inTrigger || inPanelOrCorridor)
            if within || interacting { outsideSince = nil }
            else if outsideSince == nil { outsideSince = now }
            if let since = outsideSince, now - since >= leaveDelay { reset(); return }
            if phase == .compact, within, inPanelOrCorridor,
               let since = compactSince, now - since >= expandDelay {
                phase = .expanded; compactSince = nil
            }
        }
    }
}
