#if DEBUG
import CoreMedia
import Foundation

/// Development-only single-source wiring. Nothing is enabled merely because
/// this file is present. Callbacks run off the main thread. The caller owns
/// capture authorization, source selection, UI, and main-thread delivery.
final class ExperimentalCaptionSpeakerAdapter: @unchecked Sendable {
    enum SetupError: Error { case invalidPaths, unsupportedLanguage }
    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private weak var target: ExperimentalCaptionSpeakerAdapter?
        private var pendingFailure: String?
        var owner: ExperimentalCaptionSpeakerAdapter? { lock.lock(); defer { lock.unlock() }; return target }
        func bind(_ owner: ExperimentalCaptionSpeakerAdapter) {
            lock.lock(); target = owner; let failure = pendingFailure; pendingFailure = nil; lock.unlock()
            if let failure { owner.fail(failure) }
        }
        func fail(_ message: String) {
            lock.lock(); let current = target; if current == nil && pendingFailure == nil { pendingFailure = message }; lock.unlock()
            current?.fail(message)
        }
    }
    private let lock = NSLock()
    private let relay: Relay
    private var stopped = false
    private let pipeline: CaptionSpeakerPipeline
    private var engine: LocalWhisperCaptionEngine?
    private let onError: @Sendable (String) -> Void

    /// Returns nil unless an explicit debug-environment opt-in is present.
    /// The caller must pass manually installed local helpers and models; this
    /// adapter never downloads models or activates microphone capture.
    static func make(environment: [String: String], whisperHelper: URL, whisperModel: URL,
                     speakerHelper: URL, speakerModel: URL, language: String,
                     minimumCoverage: Double, maximumCompetition: Double,
                     onText: @escaping @Sendable (String, Bool) -> Void,
                     onUpdate: @escaping @Sendable (CaptionAttributedWindow) -> Void,
                     onError: @escaping @Sendable (String) -> Void,
                     onAcceptedSamples: @escaping @Sendable (Int64) -> Void = { _ in }) throws -> ExperimentalCaptionSpeakerAdapter? {
        guard environment["MORIQ_EXPERIMENTAL_SPEAKER"] == "1" else { return nil }
        guard language == "en" || language.hasPrefix("en-") else { throw SetupError.unsupportedLanguage }
        guard FileManager.default.isExecutableFile(atPath: whisperHelper.path),
              FileManager.default.isExecutableFile(atPath: speakerHelper.path),
              FileManager.default.fileExists(atPath: whisperModel.path),
              FileManager.default.fileExists(atPath: speakerModel.path) else { throw SetupError.invalidPaths }
        return try ExperimentalCaptionSpeakerAdapter(whisperHelper: whisperHelper, whisperModel: whisperModel,
            speakerHelper: speakerHelper, speakerModel: speakerModel, language: language,
            minimumCoverage: minimumCoverage, maximumCompetition: maximumCompetition,
            onText: onText, onUpdate: onUpdate, onError: onError, onAcceptedSamples: onAcceptedSamples)
    }
    private init(whisperHelper: URL, whisperModel: URL, speakerHelper: URL, speakerModel: URL, language: String,
                 minimumCoverage: Double, maximumCompetition: Double,
                 onText: @escaping @Sendable (String, Bool) -> Void,
                 onUpdate: @escaping @Sendable (CaptionAttributedWindow) -> Void,
                 onError: @escaping @Sendable (String) -> Void,
                 onAcceptedSamples: @escaping @Sendable (Int64) -> Void) throws {
        self.onError = onError
        let relay = Relay(); self.relay = relay
        self.pipeline = try CaptionSpeakerPipeline(helper: speakerHelper, model: speakerModel,
            minimumCoverage: minimumCoverage, maximumCompetition: maximumCompetition,
            onUpdate: onUpdate, onFailure: { [weak relay] in relay?.fail("说话人识别不可用，已停止实验会话。") })
        self.engine = nil
        do {
            self.engine = try LocalWhisperCaptionEngine(helper: whisperHelper, model: whisperModel, language: language,
                onText: onText, onError: { [weak relay] message in relay?.fail(message) },
                onTimedWords: { [weak relay] window in relay?.owner?.pipeline.accept(window) },
                onAcceptedPCM: { [weak relay] pcm, offset, _ in
                    guard let owner = relay?.owner else { return }
                    if owner.pipeline.appendPCM(pcm, offset: offset) { onAcceptedSamples(offset + Int64(pcm.count / 4)) }
                    else { owner.fail("音频时间轴中断，已停止说话人识别。") }
                })
            relay.bind(self)
        } catch { pipeline.stop(); throw error }
    }
    func append(_ sample: CMSampleBuffer) { lock.lock(); let value = stopped ? nil : engine; lock.unlock(); value?.append(sample) }
    func appendTestPCM(_ pcm: Data) { lock.lock(); let value = stopped ? nil : engine; lock.unlock(); value?.appendSyntheticPCM(pcm) }
    func finishSpeakerInput() { lock.lock(); let active = !stopped; lock.unlock(); if active { pipeline.finish() } }
    @discardableResult private func stopOnce() -> Bool {
        lock.lock(); guard !stopped else { lock.unlock(); return false }; stopped = true
        let value = engine; engine = nil; lock.unlock()
        value?.stop(); pipeline.stop()
        return true
    }
    func stop() { _ = stopOnce() }
    private func fail(_ message: String) {
        if stopOnce() { onError(message) }
    }
    deinit { stop() }
}
#endif
