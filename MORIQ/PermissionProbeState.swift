import Foundation

@MainActor final class PermissionProbeState {
    private(set) var inFlight = false
    private var valid: UUID?
    private var active: UUID?
    func begin() -> UUID? {
        guard !inFlight else { return nil }
        let token = UUID(); valid = token; active = token; inFlight = true; return token
    }
    func isCurrent(_ token: UUID) -> Bool { inFlight && valid == token }
    func finish(_ token: UUID) -> Bool {
        guard active == token else { return false }
        let current = isCurrent(token)
        active = nil; inFlight = false
        if current { valid = nil }
        return current
    }
    func invalidate() { valid = nil }
}

enum PermissionProbeKind: String { case folders, screen, audio }

enum PermissionProbeRetry {
    static func shouldRetry(_ kind: PermissionProbeKind, granted: Bool, previouslyRequested: Bool, screenAllowed: Bool) -> Bool {
        guard !granted else { return false }
        switch kind {
        case .folders: return previouslyRequested
        case .screen: return screenAllowed
        case .audio: return screenAllowed && previouslyRequested
        }
    }
}
