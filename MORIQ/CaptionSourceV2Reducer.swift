import Foundation
import CryptoKit

// Connection-scoped review validation. Call only after the corresponding caption batch is committed.
struct SourceMarker: Decodable {
    let type: String, session: UUID, epoch: UUID, unit: UUID, original_stream_id: UUID
    let revision: UInt64, batch_seq: UInt64, confirmed_through_byte: Int, start_byte: Int, end_byte: Int
    let source_sha256: String, boundary_reason: String
}

// The caller delivers batch commit and markers on the same serial executor.
// Review failures never throw into the caption renderer.
struct SourceV2Verifier {
    let session: UUID, epoch: UUID, stream: UUID
    var experimentalSentenceV1 = false
    private(set) var reviewEnabled = true
    private(set) var visibleCaption = ""
    private(set) var acceptedUnits: [UUID] = []
    private(set) var acceptedMarkers: [SourceMarker] = []
    private var lastBatch: UInt64 = 0
    private var snapshotLengths: [UInt64: Int] = [:]
    private var priorConfirmed = ""
    private var lastEnd = 0
    private var seen = Set<UUID>()

    mutating func commitBatch(_ seq: UInt64, confirmed: String) {
        // Caption rendering always proceeds independently of review validation.
        visibleCaption = confirmed
        guard reviewEnabled else { return }
        guard seq == lastBatch + 1, confirmed.utf8.starts(with: priorConfirmed.utf8), snapshotLengths.count < 1024 else { disable(); return }
        lastBatch = seq
        priorConfirmed = confirmed
        snapshotLengths[seq] = confirmed.utf8.count
    }
    // Isolated experimental contract; caller must establish both handshake flags.
    mutating func punctBatch(_ seq: UInt64, confirmed: String, units: [[String: Any]], ranges: [[String: Int]], coverage: [String: Any], finished: Bool, negotiated: Bool) -> Bool {
        guard negotiated, !units.isEmpty || ranges.isEmpty || finished,
              let through = coverage["confirmed_through_byte"] as? Int,
              let covered = coverage["covered_through_byte"] as? Int,
              let state = coverage["state"] as? String,
              through == confirmed.utf8.count, state == (finished ? "complete" : "open") else { return false }
        let starts = units.compactMap { $0["start_byte"] as? Int }, rangeStarts = ranges.compactMap { $0["start_byte"] }
        guard starts.count == units.count, rangeStarts.count == ranges.count,
              starts == starts.sorted(), rangeStarts == rangeStarts.sorted(), ranges.isEmpty || finished else { return false }
        var trial = self; trial.experimentalSentenceV1 = true; trial.commitBatch(seq, confirmed: confirmed)
        guard trial.reviewEnabled else { return false }
        let bytes = Array(confirmed.utf8)
        var entries: [(Int, Int, Bool, [String: Any])] = []
        for unit in units { guard let a=unit["start_byte"] as? Int, let b=unit["end_byte"] as? Int else { return false }; entries.append((a,b,false,unit)) }
        for range in ranges { guard Set(range.keys) == Set(["start_byte", "end_byte"]), let a=range["start_byte"], let b=range["end_byte"] else { return false }; entries.append((a,b,true,[:])) }
        entries.sort { $0.0 < $1.0 }
        var pos=trial.lastEnd; var sawSkip=false
        for (start,end,skip,unit) in entries {
            guard start == pos, start >= 0, end > start, end <= through else { return false }
            if sawSkip && !skip { return false }
            sawSkip = sawSkip || skip
            if skip {
                guard bytes[start..<end].allSatisfy({ [9,10,13,32].contains(Int($0)) }) else { return false }
                trial.lastEnd=end
            } else {
                guard let raw=try? JSONSerialization.data(withJSONObject:unit) else { return false }
                trial.marker(raw); guard trial.reviewEnabled else { return false }
            }
            pos=end
        }
        guard covered == pos, !finished || pos == through else { return false }
        // Atomic punct batches cannot contain markers from older batches.
        trial.snapshotLengths.removeAll(keepingCapacity: true)
        self=trial; return true
    }
    mutating func marker(_ data: Data) {
        guard reviewEnabled else { return }
        guard let m = try? JSONDecoder().decode(SourceMarker.self, from: data),
              m.type == "source_unit_v2", m.session == session, m.epoch == epoch, m.original_stream_id == stream,
              m.revision > 0, m.revision <= 9_007_199_254_740_991,
              (["endpoint", "finish"].contains(m.boundary_reason) || (experimentalSentenceV1 && m.boundary_reason == "sentence_v1")), !seen.contains(m.unit),
              let length = snapshotLengths[m.batch_seq], m.batch_seq > 0, m.batch_seq <= lastBatch,
              m.confirmed_through_byte == length,
              m.start_byte >= lastEnd, m.end_byte > m.start_byte, m.end_byte <= m.confirmed_through_byte else { disable(); return }
        func boundaries(_ value: String) -> Set<Int> {
            var result: Set<Int> = [0], position = 0
            for character in value { position += String(character).utf8.count; result.insert(position) }
            return result
        }
        let bytes = Array(visibleCaption.utf8)
        guard length <= bytes.count, let text = String(bytes: bytes.prefix(length), encoding: .utf8) else { disable(); return }
        let atBatch = boundaries(text), now = boundaries(visibleCaption)
        guard atBatch.contains(m.start_byte), atBatch.contains(m.end_byte),
              now.contains(m.start_byte), now.contains(m.end_byte) else { disable(); return }
        let digest = SHA256.hash(data: Data(bytes[m.start_byte..<m.end_byte])).map { String(format: "%02x", $0) }.joined()
        guard m.source_sha256 == digest else { disable(); return }
        lastEnd = m.end_byte; seen.insert(m.unit); acceptedUnits.append(m.unit); acceptedMarkers.append(m)
    }
    mutating func disable() { reviewEnabled = false; snapshotLengths.removeAll(); priorConfirmed = ""; acceptedUnits.removeAll(); acceptedMarkers.removeAll() }
}

enum CaptionSourceReviewPolicy {
    static func enabled(config: Any?, nativeBatch: Bool) -> Bool {
        nativeBatch && (config as? String) == "atomic-v1"
    }
}

/// Keeps local translations attached to the verified source unit that produced
/// them. The caller must enqueue only markers accepted by SourceV2Verifier.
struct CaptionLocalTranslationQueue {
    struct Work: Equatable {
        let session: UUID, epoch: UUID, unit: UUID
        let revision: UInt64
        let sourceHash: String, target: String, source: String
    }
    private(set) var pending: [Work] = []
    private var expected: [UUID: Work] = [:]
    private var order: [UUID] = []
    private var results: [UUID: String] = [:]
    private(set) var hasFailure = false
    private let session: UUID, epoch: UUID, target: String

    init(session: UUID, epoch: UUID, target: String) {
        self.session = session; self.epoch = epoch; self.target = target
    }

    @discardableResult mutating func enqueue(_ marker: SourceMarker, confirmed: String) -> Bool {
        guard !hasFailure, order.count < 1024, marker.session == session, marker.epoch == epoch,
              marker.revision > 0, expected[marker.unit] == nil else { return false }
        let bytes = Array(confirmed.utf8)
        guard marker.start_byte >= 0, marker.end_byte > marker.start_byte,
              marker.end_byte <= bytes.count,
              let source = String(bytes: bytes[marker.start_byte..<marker.end_byte], encoding: .utf8), source.utf8.count <= 4000,
              SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined() == marker.source_sha256 else { return false }
        let work = Work(session: session, epoch: epoch, unit: marker.unit, revision: marker.revision,
                        sourceHash: marker.source_sha256, target: target, source: source)
        expected[marker.unit] = work; order.append(marker.unit); pending.append(work)
        return true
    }

    @discardableResult mutating func complete(_ work: Work, text: String) -> Bool {
        guard !hasFailure, expected[work.unit] == work, results[work.unit] == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let value: String
        if work.target == "zh-Hans" {
            guard let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) else { return false }
            value = simplified
        } else { value = text }
        results[work.unit] = value
        pending.removeAll { $0 == work }
        return true
    }

    /// The caller can retain the existing provider preview when a local
    /// translation fails; do not silently claim a partial result is complete.
    @discardableResult mutating func fail(_ work: Work) -> Bool {
        guard expected[work.unit] == work, results[work.unit] == nil else { return false }
        hasFailure = true; pending.removeAll()
        return true
    }

    /// Only a contiguous prefix is publishable: later results must never jump
    /// ahead of an earlier unit that is still translating.
    var visible: String {
        var parts: [String] = []
        for unit in order {
            guard let text = results[unit] else { break }
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }
}

enum CaptionPunctProductPolicy {
    static let preferenceKey = "moriq.caption.punct.enabled"
    static func enabled(available: Any?, optedIn: Bool, automatic: Bool) -> Bool {
        (available as? Bool) == true && optedIn && automatic
    }
}

enum CaptionAutomaticProductPolicy {
    static func enabled(config: Any?, nativeBatch: Bool) -> Bool {
        nativeBatch && (config as? String) == "trusted-v1"
    }
}

#if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
/// Internal state only: the transport must authenticate and validate association
/// before constructing an event. Manual-review candidates are never accepted.
struct CaptionAutomaticTranslationEvent {
    let session: UUID, epoch: UUID, originalStreamID: UUID, unit: UUID
    let revision: UInt64
    let sourceSHA256: String, target: String, text: String
    let associationVerified: Bool, autoApply: Bool
}

struct CaptionAutomaticTranslationState {
    private(set) var results: [UUID: String] = [:]
    private var order: [UUID] = []
    private var failed = Set<UUID>()
    var hasFailure: Bool { !failed.isEmpty }
    var visible: String { order.compactMap { results[$0] }.joined(separator: " ") }
    private var expected: [UUID: SourceMarker] = [:]
    private let session: UUID, epoch: UUID, stream: UUID, target: String
    init(session: UUID, epoch: UUID, stream: UUID, target: String) {
        self.session = session; self.epoch = epoch; self.stream = stream; self.target = target
    }
    mutating func register(_ marker: SourceMarker) {
        guard marker.session == session, marker.epoch == epoch, marker.original_stream_id == stream else { return }
        if expected[marker.unit] == nil { order.append(marker.unit) }
        expected[marker.unit] = marker
    }
    @discardableResult mutating func accept(_ event: CaptionAutomaticTranslationEvent) -> Bool {
        guard event.associationVerified, event.autoApply, event.session == session, event.epoch == epoch,
              event.originalStreamID == stream, event.target == target, results[event.unit] == nil, !failed.contains(event.unit), let marker = expected[event.unit], event.revision == marker.revision,
              event.sourceSHA256 == marker.source_sha256,
              !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.text.unicodeScalars.count <= 4000 else { return false }
        results[event.unit] = event.text
        failed.remove(event.unit)
        return true
    }
    mutating func acceptFailure(_ event: CaptionAutomaticWireEvent) -> Bool {
        guard event.type == "auto_translation_error_v1", event.code == "unavailable", event.text == nil,
              event.session == session, event.epoch == epoch, event.original_stream_id == stream,
              event.target == target, results[event.unit] == nil, !failed.contains(event.unit), let marker = expected[event.unit], event.revision == marker.revision,
              event.source_sha256 == marker.source_sha256 else { return false }
        failed.insert(event.unit)
        return true
    }
}
#endif

#if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
struct CaptionAutomaticWireEvent: Decodable {
    let type: String, session: UUID, epoch: UUID, original_stream_id: UUID, unit: UUID
    let revision: UInt64, source_sha256: String, target: String
    let text: String?
    let code: String?
}
#endif
