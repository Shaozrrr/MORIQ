import Foundation

/// Session-only labels for anonymous diarization IDs. This type does not infer
/// speaker identity, persist voiceprints, or match IDs between recordings.
/// Its owner must serialize access, for example on the main actor.
struct CaptionSpeakerNames {
    private(set) var sessionID: UUID
    private var numbers: [String: Int] = [:]
    private var names: [String: String] = [:]
    private var segmentOverrides: [UUID: String] = [:]
    private var unknownSegments: Set<UUID> = []

    init(sessionID: UUID = UUID()) { self.sessionID = sessionID }

    /// A new session invalidates pending callbacks from the old one.
    @discardableResult mutating func beginSession() -> UUID {
        sessionID = UUID()
        numbers.removeAll()
        names.removeAll()
        segmentOverrides.removeAll()
        unknownSegments.removeAll()
        return sessionID
    }

    /// Only call this for a non-ambiguous ID returned by an actual diarizer.
    @discardableResult mutating func observe(_ id: String?, session: UUID) -> Bool {
        guard session == sessionID, let id, Self.validID(id) else { return false }
        if numbers[id] == nil { numbers[id] = numbers.count + 1 }
        return true
    }

    /// An explicit user edit; passing nil removes a previously entered name.
    @discardableResult mutating func setUserName(_ name: String?, for id: String, session: UUID) -> Bool {
        guard session == sessionID, numbers[id] != nil else { return false }
        guard let name else { names.removeValue(forKey: id); return true }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80,
              clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        names[id] = clean
        return true
    }

    func displayName(for id: String?, session: UUID) -> String {
        guard session == sessionID, let id, let number = numbers[id] else { return "未知说话人" }
        return names[id] ?? "说话人 \(number)"
    }

    /// Explicit correction for one subtitle segment; nil marks it unknown.
    @discardableResult mutating func setSpeakerForSegment(_ segment: UUID, id: String?, session: UUID) -> Bool {
        guard session == sessionID else { return false }
        if let id {
            guard numbers[id] != nil else { return false }
            segmentOverrides[segment] = id
            unknownSegments.remove(segment)
        } else {
            segmentOverrides.removeValue(forKey: segment)
            unknownSegments.insert(segment)
        }
        return true
    }

    /// Remove a user's correction and return to the engine's current result.
    @discardableResult mutating func clearSegmentCorrection(_ segment: UUID, session: UUID) -> Bool {
        guard session == sessionID else { return false }
        segmentOverrides.removeValue(forKey: segment)
        unknownSegments.remove(segment)
        return true
    }

    func displayName(forSegment segment: UUID, inferredID: String?, session: UUID) -> String {
        guard session == sessionID, !unknownSegments.contains(segment) else { return "未知说话人" }
        return displayName(for: segmentOverrides[segment] ?? inferredID, session: session)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
            && id.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
