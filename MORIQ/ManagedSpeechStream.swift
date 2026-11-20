import Foundation

enum ManagedSpeechRuntimePolicy {
    static func allows(bundleID: String?, flavorPresent: Bool) -> Bool {
        !(bundleID ?? "").hasPrefix("local.moriq.internal") && !flavorPresent
    }
}

/// Product-gateway events; the client never receives the upstream provider key.
struct ManagedSpeechEvent: Decodable, Sendable {
    let type: String
    let text: String?
    let final: Bool?
    let segment: Int?
    let message: String?
    var mode: String? = nil
    var code: String? = nil
    var supportsKeepalive: Bool? = nil
    var startMs: Int? = nil
    var endMs: Int? = nil
    var speakerChanged: Bool? = nil
    var languageLabel: String? = nil
    var languageLabels: [String]? = nil
    var protocolVersion: Int? = nil
    var sampleEpoch: String? = nil
    var sampleStart: UInt64? = nil
    var sampleEnd: UInt64? = nil
    var unanchoredPreview: Bool? = nil
    var confirmedDeltaV1: Bool? = nil
    var revision: Int? = nil
    var confirmedUTF8Offset: Int? = nil
    var confirmedDelta: String? = nil
    var provisional: String? = nil
    var segmentFinal: Bool? = nil
    var nativeTranslationV1: Bool? = nil
    var lane: String? = nil
    var marker: String? = nil
    var nativeBatchV1: Bool? = nil
    var events: [ManagedSpeechEvent]? = nil
    var sourceUnitsV2: Bool? = nil
    var sourceAtomicV1: Bool? = nil
    var sourcePunctV1: Bool? = nil
    var sourcePunctBatchRaw: String? = nil
    var sourceMarkersRaw: [String]? = nil
    var sourceUnitsUnavailable = false
    var originalStreamID: String? = nil
    var sourceSessionID: String? = nil
    var sourceEpochID: String? = nil
    var batchSeq: UInt64? = nil
    var sourceMarkerRaw: String? = nil
    var automaticTranslationRaw: String? = nil
    var automaticTranslationV1: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case type, text, final, segment, message, mode, code
        case supportsKeepalive = "supports_keepalive"
        case startMs = "start_ms", endMs = "end_ms", speakerChanged = "speaker_changed"
        case languageLabel = "language_label", languageLabels = "language_labels"
        case protocolVersion = "protocol"
        case unanchoredPreview = "unanchored_preview"
        case confirmedDeltaV1 = "confirmed_delta_v1"
        case nativeTranslationV1 = "native_translation_v1"
        case lane, marker, events
        case nativeBatchV1 = "native_batch_v1"
        case revision, provisional
        case confirmedUTF8Offset = "confirmed_utf8_offset", confirmedDelta = "confirmed_delta", segmentFinal = "segment_final"
        case sampleEpoch = "sample_epoch", sampleStart = "sample_start", sampleEnd = "sample_end"
    }

    /// Ranges are scoped to one gateway connection, never a global clock.
    var hasValidSampleRange: Bool {
        if sampleEpoch == nil && sampleStart == nil && sampleEnd == nil { return true }
        guard let epoch = sampleEpoch, UUID(uuidString: epoch) != nil,
              let start = sampleStart, let end = sampleEnd, start < end else { return false }
        return true
    }
}

enum ManagedNativeLane: String, Sendable { case original, translation }

enum ManagedNativeHandshake {
    static func accepts(_ event: ManagedSpeechEvent, requested: Bool, batchRequested: Bool, alreadyReady: Bool) -> Bool {
        if requested && (alreadyReady || event.nativeTranslationV1 != true || event.mode != "translation") { return false }
        if !requested && event.nativeTranslationV1 != nil { return false }
        if batchRequested && event.nativeBatchV1 != true { return false }
        if !batchRequested && event.nativeBatchV1 != nil { return false }
        return true
    }
}

struct ManagedNativeLaneUpdate: Sendable {
    let lane: ManagedNativeLane
    let confirmedDelta: String
    let provisional: String
}

/// Validation is connection-scoped; callers must also supply the currently
/// active consumer epoch before accepting an event. No translated timestamps or
/// source/translation sentence association are inferred by this layer.
struct ManagedNativeLaneAccumulator {
    let epoch: UUID
    private struct Track { var nextRevision = 1; var utf8Offset = 0 }
    private var original = Track()
    private var translation = Track()
    init(epoch: UUID = UUID()) { self.epoch = epoch }

    mutating func accept(_ event: ManagedSpeechEvent, epoch activeEpoch: UUID) throws -> ManagedNativeLaneUpdate {
        guard activeEpoch == epoch, event.type == "lane_delta",
              let name = event.lane, let lane = ManagedNativeLane(rawValue: name),
              let revision = event.revision, let offset = event.confirmedUTF8Offset,
              let delta = event.confirmedDelta, let provisional = event.provisional,
              delta.utf8.count <= 16_000, provisional.utf8.count <= 16_000 else { throw ManagedSpeechError.invalidResponse }
        switch lane {
        case .original: try Self.advance(&original, revision: revision, offset: offset, delta: delta)
        case .translation: try Self.advance(&translation, revision: revision, offset: offset, delta: delta)
        }
        return ManagedNativeLaneUpdate(lane: lane, confirmedDelta: delta, provisional: provisional)
    }

    /// Validate every operation on a copy, then commit both tracks at once.
    /// Return at most one aggregate per lane for a single MainActor update.
    mutating func acceptBatch(_ operations: [ManagedSpeechEvent], epoch activeEpoch: UUID) throws -> [ManagedNativeLaneUpdate] {
        guard activeEpoch == epoch, !operations.isEmpty, operations.count <= 4001 else { throw ManagedSpeechError.invalidResponse }
        var staged = self
        var result: [ManagedNativeLaneUpdate] = []
        for operation in operations {
            if operation.type == "stream_marker" {
                guard let marker = operation.marker, ["<end>", "<fin>"].contains(marker) else { throw ManagedSpeechError.invalidResponse }
                continue
            }
            let update = try staged.accept(operation, epoch: activeEpoch)
            if let i = result.firstIndex(where: { $0.lane == update.lane }) {
                let combined = result[i].confirmedDelta + update.confirmedDelta
                guard combined.utf8.count <= 16_000 else { throw ManagedSpeechError.invalidResponse }
                result[i] = ManagedNativeLaneUpdate(lane: update.lane, confirmedDelta: combined, provisional: update.provisional)
            } else { result.append(update) }
        }
        self = staged
        return result
    }

    private static func advance(_ track: inout Track, revision: Int, offset: Int, delta: String) throws {
        let (nextOffset, overflow) = track.utf8Offset.addingReportingOverflow(delta.utf8.count)
        guard !overflow, revision == track.nextRevision, offset == track.utf8Offset,
              nextOffset <= 9_007_199_254_740_991, track.nextRevision < Int.max else { throw ManagedSpeechError.invalidResponse }
        track.utf8Offset = nextOffset; track.nextRevision += 1
    }
}

/// Independently assemble the provider's source and translated streams.
/// Real AST 2.0 sessions observed incremental text followed by a full final
/// for each stream. No relationship between the two segment numbers is assumed.
struct ManagedSpeechAccumulator {
    /// ASR returns a revised full hypothesis; the older translation gateway
    /// returns deltas. Select this only after the server declares its mode.
    var sourceSnapshots = false
    private struct Track {
        var segment = -1
        var text = ""
        var finalized = false
    }
    private var source = Track()
    private var translation = Track()

    mutating func accept(_ event: ManagedSpeechEvent) -> (text: String, final: Bool)? {
        guard (event.type == "source" || event.type == "translation"), let segment = event.segment,
              segment >= 0, let delta = event.text, let final = event.final else { return nil }
        if event.type == "source" { return Self.update(&source, segment: segment, delta: delta, final: final, snapshot: sourceSnapshots) }
        return Self.update(&translation, segment: segment, delta: delta, final: final)
    }

    private static func update(_ track: inout Track, segment: Int, delta: String, final: Bool, snapshot: Bool = false) -> (text: String, final: Bool)? {
        guard segment >= track.segment else { return nil }
        if segment > track.segment { track = Track(segment: segment) }
        guard !track.finalized else { return nil }
        guard delta.utf8.count <= 16_000,
              final || snapshot || track.text.utf8.count + delta.utf8.count <= 16_000 else { return nil }
        if final { track.text = delta; track.finalized = true }
        else if snapshot { track.text = delta }
        else { track.text.append(delta) }
        return (track.text, final)
    }
}


/// One connection's strictly ordered confirmed increments and replaceable tail.
struct ManagedConfirmedDeltaAccumulator {
    private(set) var confirmed = ""
    private(set) var provisional = ""
    private var nextRevision = 1
    private var expectedSegment = 1
    mutating func accept(_ event: ManagedSpeechEvent) throws -> (confirmed: String, provisional: String, final: Bool, segment: Int) {
        guard event.type == "confirmed_delta", let segment = event.segment, segment == expectedSegment,
              let revision = event.revision, revision == nextRevision,
              let offset = event.confirmedUTF8Offset, offset == confirmed.utf8.count,
              let delta = event.confirmedDelta, let tail = event.provisional, let final = event.segmentFinal,
              delta.utf8.count <= 16_000, tail.utf8.count <= 16_000,
              confirmed.utf8.count + delta.utf8.count + tail.utf8.count <= 16_000,
              !final || (tail.isEmpty && !(confirmed + delta).isEmpty),
              !(!final && event.languageLabels != nil),
              nextRevision < Int.max, (!final || expectedSegment < Int.max)
        else { throw ManagedSpeechError.invalidResponse }
        confirmed += delta; provisional = tail; nextRevision += 1
        let result = (confirmed: confirmed, provisional: provisional, final: final, segment: segment)
        if final { expectedSegment += 1; confirmed = ""; provisional = "" }
        return result
    }
}

enum ManagedSpeechError: Error {
    case invalidEndpoint, invalidToken, notStarted, invalidAudio, invalidResponse, connectionClosed, audioQueueFull, capabilityUnavailable
}

enum ManagedSpeechAudioProtocol: Sendable { case v1, v2 }

/// AUD2 uses a big-endian sample offset and sample count; PCM remains S16LE.
struct ManagedSpeechAudioClock {
    private(set) var nextSample: UInt64 = 0
    init(nextSample: UInt64 = 0) { self.nextSample = nextSample }
    mutating func frame(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count <= 6400, pcm.count.isMultiple(of: 2) else { throw ManagedSpeechError.invalidAudio }
        let count = UInt32(pcm.count / 2)
        let (next, overflow) = nextSample.addingReportingOverflow(UInt64(count))
        guard !overflow else { throw ManagedSpeechError.invalidAudio }
        var position = nextSample.bigEndian, samples = count.bigEndian
        var frame = Data("AUD2".utf8)
        withUnsafeBytes(of: &position) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &samples) { frame.append(contentsOf: $0) }
        frame.append(pcm); nextSample = next
        return frame
    }
}

private final class SpeechRejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One short-lived duplex session. PCM is signed 16-bit little-endian, 16 kHz mono.
/// Consumer must wait for `ready` before sending audio, and cancel when capture stops.
actor ManagedSpeechStream {
    private var releaseCredential: (@Sendable () async -> Void)?
    func attachCredentialRelease(_ release: @escaping @Sendable () async -> Void) {
        if closed || releaseCredential != nil { Task { await release() } } else { releaseCredential = release }
    }
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var receiver: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ManagedSpeechEvent, Error>.Continuation?
    private var started = false
    private var closed = false
    private var finishing = false
    private var supportsKeepalive = false
    private var sentAudio = false
    private let audioProtocol: ManagedSpeechAudioProtocol
    private var protocolReady = false
    private let requestsUnanchoredPreview: Bool
    private let requestsConfirmedDeltas: Bool
    private let requestsNativeTranslation: Bool
    private let requestsNativeBatch: Bool
    private let requestsSourceUnitsV2: Bool
    private let requestsSourceAtomicV1: Bool
    private let requestsSourcePunctV1: Bool
    private let requestsAutomaticTranslation: Bool
    private var sourceReviewMarkerDropped = false
    #if DEBUG
    func debugSourceReviewHealthy() -> Bool { !sourceReviewMarkerDropped }
    #endif
    private var confirmedDeltasReady = false
    private var nativeTranslationReady = false
    private var nativeValidation = ManagedNativeLaneAccumulator()
    private var deltaValidation = ManagedConfirmedDeltaAccumulator()
    private var previewReady = false
    private var audioClock = ManagedSpeechAudioClock()
    private var sendTail: Task<Void, Error>?
    private var queuedPackets = 0

    init(endpoint: URL, token: String, audioProtocol: ManagedSpeechAudioProtocol = .v1, requestUnanchoredPreview: Bool = false, requestConfirmedDeltas: Bool = false, requestNativeTranslation: Bool = false, requestNativeBatch: Bool = false, allowLoopbackForTesting: Bool = false, requestSourceUnitsV2: Bool = false, requestSourceAtomicV1: Bool = false, requestAutomaticTranslation: Bool = false, requestSourcePunctV1: Bool = false) throws {
        var localInternalFixture = false
        #if DEBUG && MORIQ_INTERNAL_SMOKE && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
        localInternalFixture = Bundle.main.bundleIdentifier == "local.moriq.internal"
            && CommandLine.arguments.contains("--moriq-internal-smoke")
            && CommandLine.arguments.contains("--moriq-fake-caption-port")
            && allowLoopbackForTesting && endpoint.scheme == "ws" && endpoint.host == "127.0.0.1"
            && token == String(repeating: "x", count: 40)
        #endif
        if !ManagedSpeechRuntimePolicy.allows(bundleID: Bundle.main.bundleIdentifier, flavorPresent: Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor") != nil) && !localInternalFixture {
            FileHandle.standardError.write(Data("MORIQ runtime refused speech network\n".utf8))
            throw ManagedSpeechError.invalidEndpoint
        }
        guard let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let host = c.host, !host.isEmpty, c.path == "/v1/speech/stream" else { throw ManagedSpeechError.invalidEndpoint }
        #if !DEBUG
        guard !requestSourcePunctV1 else { throw ManagedSpeechError.invalidEndpoint }
        guard !requestSourceUnitsV2 || requestSourceAtomicV1 else { throw ManagedSpeechError.invalidEndpoint }
        guard !allowLoopbackForTesting && !requestConfirmedDeltas else { throw ManagedSpeechError.invalidEndpoint }
        #if !MORIQ_NATIVE_TRANSLATION_PRODUCT
        guard !requestNativeTranslation else { throw ManagedSpeechError.invalidEndpoint }
        #endif
        #endif
        let loopback = host == "127.0.0.1" || host == "::1"
        guard c.scheme == "wss" || (allowLoopbackForTesting && c.scheme == "ws" && loopback) else { throw ManagedSpeechError.invalidEndpoint }
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ManagedSpeechError.invalidToken }
        self.audioProtocol = audioProtocol
        guard [requestConfirmedDeltas, requestUnanchoredPreview, requestNativeTranslation].filter({ $0 }).count <= 1 else { throw ManagedSpeechError.invalidEndpoint }
        self.requestsUnanchoredPreview = requestUnanchoredPreview
        self.requestsConfirmedDeltas = requestConfirmedDeltas
        guard !requestNativeBatch || requestNativeTranslation else { throw ManagedSpeechError.invalidEndpoint }
        self.requestsNativeTranslation = requestNativeTranslation
        self.requestsNativeBatch = requestNativeBatch
        #if DEBUG
        guard !requestSourceUnitsV2 || (requestNativeBatch && ((allowLoopbackForTesting && c.scheme == "ws" && loopback) || (c.scheme == "wss" && !loopback))) else { throw ManagedSpeechError.invalidEndpoint }
        #else
        let localHost = host.lowercased() == "localhost" || host.lowercased().hasSuffix(".localhost") || host.hasPrefix("127.") || host.contains(":") || host == "0.0.0.0"
        guard !requestSourceUnitsV2 || (requestNativeBatch && c.scheme == "wss" && !localHost) else { throw ManagedSpeechError.invalidEndpoint }
        #endif
        self.requestsSourceUnitsV2 = requestSourceUnitsV2
        guard !requestSourceAtomicV1 || requestSourceUnitsV2 else { throw ManagedSpeechError.invalidEndpoint }
        #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
        let productHost = host.lowercased()
        let isLiteral = productHost.allSatisfy { $0.isNumber || $0 == "." } || productHost.contains(":")
        let isLocal = productHost == "localhost" || productHost.hasSuffix(".localhost") || productHost.hasSuffix(".local") || productHost.hasSuffix(".internal") || !productHost.contains(".") || isLiteral
        guard !requestAutomaticTranslation || (requestSourceUnitsV2 && requestSourceAtomicV1 && requestNativeBatch && !allowLoopbackForTesting && c.scheme == "wss" && !isLocal && (c.port == nil || c.port == 443) && token != String(repeating: "x", count: 40)) else { throw ManagedSpeechError.invalidEndpoint }
        #elseif DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
        guard !requestAutomaticTranslation || (requestSourceUnitsV2 && requestSourceAtomicV1 && requestNativeBatch && allowLoopbackForTesting) else { throw ManagedSpeechError.invalidEndpoint }
        #else
        guard !requestAutomaticTranslation else { throw ManagedSpeechError.invalidEndpoint }
        #endif
        self.requestsAutomaticTranslation = requestAutomaticTranslation
        guard !requestSourcePunctV1 || requestSourceAtomicV1 else { throw ManagedSpeechError.invalidEndpoint }
        self.requestsSourcePunctV1 = requestSourcePunctV1
        self.requestsSourceAtomicV1 = requestSourceAtomicV1
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: SpeechRejectRedirects(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 32_768
    }

    func start(source: String, target: String) async throws -> AsyncThrowingStream<ManagedSpeechEvent, Error> {
        guard !started, !closed else { throw ManagedSpeechError.notStarted }
        started = true
        // A review marker may be dropped under pressure; it must never evict
        // an already queued caption batch.
        let pair = AsyncThrowingStream<ManagedSpeechEvent, Error>.makeStream(bufferingPolicy: requestsSourceUnitsV2 ? .bufferingOldest(256) : .bufferingNewest(256))
        continuation = pair.continuation
        socket.resume()
        do {
            var request: [String: Any] = ["type":"start", "source":source, "target":target]
            if audioProtocol == .v2 { request["protocol"] = 2 }
            if requestsUnanchoredPreview { request["unanchored_preview"] = true }
            if requestsConfirmedDeltas { request["confirmed_delta_v1"] = true }
            if requestsNativeTranslation { request["native_translation_v1"] = true }
            if requestsNativeBatch { request["native_batch_v1"] = true }
            if requestsSourceUnitsV2 { request["source_units_v2"] = true }
            if requestsSourceAtomicV1 { request["source_units_atomic_v1"] = true }
            if requestsSourcePunctV1 { request["source_units_punct_v1"] = true }
            if requestsAutomaticTranslation { request["auto_translation_v1"] = true }
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else { throw ManagedSpeechError.invalidResponse }
            try await socket.send(.string(json))
        } catch { close(); throw error }
        receiver = Task { [weak self] in await self?.receiveLoop() }
        return pair.stream
    }

    func sendPCM(_ data: Data) async throws {
        guard started, !closed, !finishing else { throw ManagedSpeechError.notStarted }
        guard !data.isEmpty, data.count <= 6400, data.count % 2 == 0 else { throw ManagedSpeechError.invalidAudio }
        guard audioProtocol == .v1 || protocolReady else { throw ManagedSpeechError.notStarted }
        try Task.checkCancellation()
        guard queuedPackets < 50 else { close(); throw ManagedSpeechError.audioQueueFull }
        let packet = audioProtocol == .v2 ? try audioClock.frame(data) : data
        let previous = sendTail, socket = self.socket
        let operation = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await socket.send(.data(packet))
        }
        sendTail = operation; queuedPackets += 1
        defer { queuedPackets -= 1; if queuedPackets == 0 { sendTail = nil } }
        do {
            try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        } catch { close(); throw error }
        guard !closed, !finishing else { return }
        sentAudio = true
        startKeepaliveIfNeeded()
    }
    func finish() async throws {
        guard started, !closed, !finishing else { throw ManagedSpeechError.notStarted }
        finishing = true
        keepalive?.cancel(); keepalive = nil
        do {
            if let sendTail { try await sendTail.value }
            guard !closed else { throw ManagedSpeechError.connectionClosed }
            try await socket.send(.string("{\"type\":\"finish\"}"))
        }
        catch { close(); throw error }
    }
    func cancel() { close() }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled && !closed {
                let message = try await socket.receive()
                guard case .string(let raw) = message, raw.utf8.count <= 32_768, let data = raw.data(using: .utf8) else { throw ManagedSpeechError.invalidResponse }
                let rawObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let isReviewMarker = requestsSourceUnitsV2 && (rawObject?["type"] as? String) == "source_unit_v2"
                var event = try JSONDecoder().decode(ManagedSpeechEvent.self, from: isReviewMarker ? Data("{\"type\":\"source_unit_v2\"}".utf8) : data)
                if isReviewMarker { event.sourceMarkerRaw = raw }
                if event.type == "ready" {
                    event.automaticTranslationV1 = rawObject?["auto_translation_v1"] as? Bool
                    if requestsAutomaticTranslation && event.automaticTranslationV1 != true { throw ManagedSpeechError.invalidResponse }
                    if !requestsAutomaticTranslation && event.automaticTranslationV1 != nil { throw ManagedSpeechError.invalidResponse }
                }
                if ["auto_translation_v1", "auto_translation_error_v1"].contains(event.type) {
                    guard requestsAutomaticTranslation && nativeTranslationReady else { throw ManagedSpeechError.invalidResponse }
                    event.automaticTranslationRaw = raw
                    if let continuation, case .dropped = continuation.yield(event) { throw ManagedSpeechError.invalidResponse }
                    continue
                }
                if requestsSourceUnitsV2 && event.type == "ready" {
                    event.sourceUnitsV2 = rawObject?["source_units_v2"] as? Bool
                    event.sourceAtomicV1 = rawObject?["source_units_atomic_v1"] as? Bool
                    event.sourcePunctV1 = rawObject?["source_units_punct_v1"] as? Bool
                    if requestsSourcePunctV1 && event.sourcePunctV1 != true { throw ManagedSpeechError.capabilityUnavailable }
                    if !requestsSourcePunctV1 && event.sourcePunctV1 != nil { throw ManagedSpeechError.invalidResponse }
                    event.originalStreamID = rawObject?["original_stream_id"] as? String
                    event.sourceSessionID = rawObject?["session"] as? String
                    event.sourceEpochID = rawObject?["epoch"] as? String
                }
                if requestsSourceAtomicV1 && event.type == "lane_batch" {
                    let keys = Set(rawObject?.keys.map { $0 } ?? [])
                    let expected: Set<String> = requestsSourcePunctV1 ? ["type", "events", "batch_seq", "source_units", "nonbillable_ranges", "source_coverage"] : ["type", "events", "batch_seq", "source_units"]
                    if keys != expected { event.sourceUnitsUnavailable = true }
                    if requestsSourcePunctV1 { event.sourcePunctBatchRaw = raw }
                    if let units = rawObject?["source_units"] as? [[String: Any]],
                       units.count <= 200,
                       let encoded = try? units.map({ try JSONSerialization.data(withJSONObject: $0) }) {
                        event.sourceMarkersRaw = encoded.compactMap { String(data: $0, encoding: .utf8) }
                    } else { event.sourceUnitsUnavailable = true }
                    if rawObject?["source_units_unavailable"] as? Bool == true { event.sourceUnitsUnavailable = true }
                }
                if requestsSourceUnitsV2 && event.type == "lane_batch", let n = rawObject?["batch_seq"] as? NSNumber,
                   CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.uint64Value) { event.batchSeq = n.uint64Value }
                guard event.hasValidSampleRange else { throw ManagedSpeechError.invalidResponse }
                #if DEBUG
                if event.type == "source_unit_v2" && requestsSourceUnitsV2 && !requestsSourceAtomicV1 {
                    if let continuation, case .dropped = continuation.yield(event) { sourceReviewMarkerDropped = true }
                    continue
                }
                #endif
                guard ["ready", "source", "translation", "language_evidence", "unanchored_preview", "confirmed_delta", "lane_delta", "stream_marker", "lane_batch", "finished", "error"].contains(event.type) else { throw ManagedSpeechError.invalidResponse }
                if audioProtocol == .v2 && !protocolReady && event.type != "ready" && event.type != "error" { throw ManagedSpeechError.invalidResponse }
                if requestsNativeTranslation && !nativeTranslationReady && event.type != "ready" && event.type != "error" { throw ManagedSpeechError.invalidResponse }
                let validLabel: (String) -> Bool = { value in
                    (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                    }
                }
                guard event.languageLabel.map(validLabel) ?? true,
                      event.languageLabels.map({ $0.count <= 55 && $0.allSatisfy(validLabel) }) ?? true else { throw ManagedSpeechError.invalidResponse }
                if event.type == "language_evidence" {
                    guard event.languageLabel != nil, let segment = event.segment, segment >= 0 else { throw ManagedSpeechError.invalidResponse }
                }
                if event.type == "ready", let mode = event.mode, !["transcription", "translation"].contains(mode) { throw ManagedSpeechError.invalidResponse }
                if event.type == "ready" {
                    if audioProtocol == .v2 && (protocolReady || event.protocolVersion != 2) { throw ManagedSpeechError.invalidResponse }
                    if requestsConfirmedDeltas && (confirmedDeltasReady || event.confirmedDeltaV1 != true || event.mode != "transcription") { throw ManagedSpeechError.invalidResponse }
                    guard ManagedNativeHandshake.accepts(event, requested: requestsNativeTranslation,
                                                         batchRequested: requestsNativeBatch, alreadyReady: nativeTranslationReady) else { throw ManagedSpeechError.invalidResponse }
                    confirmedDeltasReady = requestsConfirmedDeltas && event.confirmedDeltaV1 == true
                    nativeTranslationReady = requestsNativeTranslation && event.nativeTranslationV1 == true
                    protocolReady = true
                    previewReady = requestsUnanchoredPreview && event.unanchoredPreview == true
                    supportsKeepalive = event.supportsKeepalive == true
                    startKeepaliveIfNeeded()
                }
                if event.type == "unanchored_preview" {
                    guard previewReady, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          Set(object.keys) == Set(["type", "text"]),
                          object["text"] is NSNull || object["text"] is String,
                          event.text.map({ $0.utf8.count <= 16_000 }) ?? true else { throw ManagedSpeechError.invalidResponse }
                }
                if event.type == "confirmed_delta" {
                    guard confirmedDeltasReady else { throw ManagedSpeechError.invalidResponse }
                    _ = try deltaValidation.accept(event)
                }
                if event.type == "lane_batch" {
                    guard nativeTranslationReady, requestsNativeBatch,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (Set(object.keys) == Set(["type", "events"]) || {
                              if requestsSourceAtomicV1 {
                                  // Review-only fields are advisory: malformed
                                  // metadata disables review, not caption delivery.
                                  return true
                              }
                              return requestsSourceUnitsV2 && Set(object.keys) == Set(["type", "events", "batch_seq"])
                          }()),
                          let rawEvents = object["events"] as? [[String: Any]], let events = event.events,
                          rawEvents.count == events.count else { throw ManagedSpeechError.invalidResponse }
                    for (raw, child) in zip(rawEvents, events) {
                        if child.type == "lane_delta" {
                            guard Set(raw.keys) == Set(["type", "lane", "revision", "confirmed_utf8_offset", "confirmed_delta", "provisional"]) else { throw ManagedSpeechError.invalidResponse }
                        } else if child.type == "stream_marker" {
                            guard Set(raw.keys) == Set(["type", "marker"]) else { throw ManagedSpeechError.invalidResponse }
                        } else { throw ManagedSpeechError.invalidResponse }
                    }
                    if !(requestsSourceAtomicV1 && events.isEmpty) { _ = try nativeValidation.acceptBatch(events, epoch: nativeValidation.epoch) }
                }
                if event.type == "lane_delta" || event.type == "stream_marker" {
                    guard nativeTranslationReady, !requestsNativeBatch, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ManagedSpeechError.invalidResponse }
                    if event.type == "lane_delta" {
                        guard Set(object.keys) == Set(["type", "lane", "revision", "confirmed_utf8_offset", "confirmed_delta", "provisional"]) else { throw ManagedSpeechError.invalidResponse }
                        _ = try nativeValidation.accept(event, epoch: nativeValidation.epoch)
                    } else {
                        guard Set(object.keys) == Set(["type", "marker"]), let marker = event.marker, ["<end>", "<fin>"].contains(marker) else { throw ManagedSpeechError.invalidResponse }
                    }
                }
                if nativeTranslationReady && ["source", "translation", "confirmed_delta", "unanchored_preview"].contains(event.type) { throw ManagedSpeechError.invalidResponse }
                if confirmedDeltasReady && (event.type == "source" || event.type == "translation") { throw ManagedSpeechError.invalidResponse }
                if event.type == "source" || event.type == "translation" {
                    guard let text = event.text, text.utf8.count <= 16000, let segment = event.segment, segment >= 0, event.final != nil else { throw ManagedSpeechError.invalidResponse }
                    guard event.startMs.map({ (0...2_147_483_647).contains($0) }) ?? true,
                          event.endMs.map({ (0...2_147_483_647).contains($0) }) ?? true else { throw ManagedSpeechError.invalidResponse }
                    if let start = event.startMs, let end = event.endMs, end < start { throw ManagedSpeechError.invalidResponse }
                }
                if let continuation {
                    if case .dropped = continuation.yield(event) { throw ManagedSpeechError.invalidResponse }
                }
                if event.type == "finished" { close(); return }
                if event.type == "error" { throw ManagedSpeechError.connectionClosed }
            }
        } catch {
            if !closed { continuation?.finish(throwing: error); continuation = nil }
            close()
        }
    }
    private func startKeepaliveIfNeeded() {
        guard supportsKeepalive, sentAudio, keepalive == nil, !closed, !finishing else { return }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if !(await self.sendKeepalive()) { return }
            }
        }
    }
    private func sendKeepalive() async -> Bool {
        guard !closed, !finishing, supportsKeepalive, sentAudio else { return false }
        do { try await socket.send(.string("{\"type\":\"keepalive\"}")); return !closed && !finishing }
        catch {
            if !closed {
                continuation?.finish(throwing: error); continuation = nil
                close()
            }
            return false
        }
    }
    private func close() {
        guard !closed else { return }
        closed = true; receiver?.cancel(); receiver = nil
        if let release = releaseCredential { releaseCredential = nil; Task { await release() } }
        keepalive?.cancel(); keepalive = nil
        sendTail?.cancel(); sendTail = nil
        continuation?.finish(); continuation = nil
        socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
}
