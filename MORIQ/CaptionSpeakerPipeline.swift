import Foundation

/// Attribution is provisional until the diarizer has finalized a turn; nil is
/// always unknown, not a guess. The owner must also reject callbacks whose
/// generation is no longer current. All offsets are per-source 16 kHz samples.
struct CaptionAttributedWindow: Sendable {
    let generation: UUID
    let window: WhisperTimedWindow
    let words: [CaptionAlignedWord]
    let diarizationAvailable: Bool
}

/// Connects one Whisper input stream to one speaker engine. Do not combine
/// offsets across microphone and system sources: a separate, verified capture
/// PTS mapping is required for a shared cross-source clock.
final class CaptionSpeakerPipeline: @unchecked Sendable {
    let generation: UUID
    private let lock = NSLock()
    private let submissionLock = NSLock()
    private let events = DispatchQueue(label: "local.moriq.speaker.alignment", qos: .userInitiated)
    private let minimumCoverage: Double, maximumCompetition: Double
    private let onUpdate: @Sendable (CaptionAttributedWindow) -> Void
    private let onFailure: @Sendable () -> Void
    private var bridge: SpeakerDiarizationBridge?
    private var active = true, failed = false
    private var nextSample: Int64 = 0
    private var windows: [Int64: WhisperTimedWindow] = [:]
    private var turns: [CaptionSpeakerTurn] = []

    init(helper: URL, model: URL, generation: UUID = UUID(), minimumCoverage: Double,
         maximumCompetition: Double, onUpdate: @escaping @Sendable (CaptionAttributedWindow) -> Void,
         onFailure: @escaping @Sendable () -> Void = {}) throws {
        guard minimumCoverage.isFinite, maximumCompetition.isFinite,
              (0...1).contains(minimumCoverage), (0...1).contains(maximumCompetition),
              minimumCoverage > maximumCompetition else { throw CaptionPipelineError.invalidThresholds }
        self.generation = generation; self.minimumCoverage = minimumCoverage
        self.maximumCompetition = maximumCompetition; self.onUpdate = onUpdate; self.onFailure = onFailure
        self.bridge = nil
        self.bridge = try SpeakerDiarizationBridge(helper: helper, model: model,
            onTurns: { [weak self] turns in self?.receive(turns) },
            onFailure: { [weak self] in self?.modelFailed() })
    }
    enum CaptionPipelineError: Error { case invalidThresholds }

    /// Called only for PCM that Whisper accepted, in the order it was accepted.
    /// Any discontinuity invalidates this generation, including a dropped block.
    @discardableResult func appendPCM(_ data: Data, offset: Int64) -> Bool {
        submissionLock.lock(); defer { submissionLock.unlock() }
        lock.lock()
        guard active, !failed, !data.isEmpty, data.count % 4 == 0,
              offset == nextSample, let bridge else {
            let shouldFail = active && !failed
            lock.unlock(); if shouldFail { modelFailed() }; return false
        }
        nextSample += Int64(data.count / 4)
        lock.unlock()
        guard bridge.append(data) else { modelFailed(); return false }
        return true
    }

    /// Provisional ASR windows can be updated by later hypotheses. Final ASR
    /// windows are not overwritten by a late partial result.
    func accept(_ window: WhisperTimedWindow) {
        events.async { [weak self] in
            guard let self, self.isActive else { return }
            self.lock.lock(); let accepted = self.nextSample; self.lock.unlock()
            guard window.startSample >= 0, window.endSample > window.startSample, window.endSample <= accepted,
                  window.words.allSatisfy({ $0.startSample >= window.startSample && $0.endSample <= window.endSample && $0.endSample > $0.startSample }) else { return }
            if let old = self.windows[window.startSample],
               (old.isFinal && !window.isFinal || old.endSample > window.endSample) { return }
            self.windows[window.startSample] = window
            if self.windows.count > 64 {
                for key in self.windows.keys.sorted().prefix(self.windows.count - 64) { self.windows.removeValue(forKey: key) }
            }
            self.publish(window)
        }
    }
    func finish() { lock.lock(); let bridge = active && !failed ? bridge : nil; lock.unlock(); bridge?.finish() }
    func stop() { lock.lock(); let bridge = self.bridge; active = false; self.bridge = nil; lock.unlock(); bridge?.stop() }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    private var isFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    private func receive(_ incoming: [SpeakerDiarizationTurn]) {
        events.async { [weak self] in
            guard let self, self.isActive, !self.isFailed else { return }
            // Tentative labels can move between speakers: never assign them.
            for turn in incoming where turn.final {
                let item = CaptionSpeakerTurn(speakerID: String(turn.speaker), range: CaptionSampleRange(start: turn.startSample, end: turn.endSample))
                if !self.turns.contains(item) { self.turns.append(item) }
            }
            if self.turns.count > 4096 { self.turns.removeFirst(self.turns.count - 4096) }
            for window in self.windows.values.sorted(by: { $0.startSample < $1.startSample }) { self.publish(window) }
        }
    }
    private func modelFailed() {
        lock.lock(); let notify = active && !failed; failed = true; let bridge = self.bridge; lock.unlock()
        guard notify else { return }
        bridge?.stop()
        onFailure()
        events.async { [weak self] in
            guard let self, self.isActive else { return }
            self.turns.removeAll()
            for window in self.windows.values.sorted(by: { $0.startSample < $1.startSample }) { self.publish(window) }
        }
    }
    private func publish(_ window: WhisperTimedWindow) {
        guard isActive else { return }
        let available = !isFailed
        let words = window.words.map { CaptionTimedWord(text: $0.text, range: CaptionSampleRange(start: $0.startSample, end: $0.endSample)) }
        let aligned = CaptionSpeakerAlignment.align(words: words, turns: available ? turns : [], minimumCoverage: minimumCoverage, maximumCompetition: maximumCompetition)
        onUpdate(CaptionAttributedWindow(generation: generation, window: window, words: aligned, diarizationAvailable: available))
    }
    deinit { stop() }
}
