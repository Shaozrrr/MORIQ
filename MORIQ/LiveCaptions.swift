import AppKit
import CoreGraphics
import CoreMedia
import AVFoundation
import ScreenCaptureKit
import Speech
import SwiftUI
import Translation

enum CaptionAudioSource: String, CaseIterable {
    case system, microphone
    var label: String { self == .system ? "系统声音" : "麦克风" }
    func accepts(_ type: SCStreamOutputType) -> Bool {
        (self == .system && type == .audio) || (self == .microphone && type == .microphone)
    }
}

enum CaptionSessionMode: String, CaseIterable {
    case captions, interpretation
    var label: String { self == .captions ? "实时字幕" : "同声传译" }
    var audioSources: [CaptionAudioSource] { self == .captions ? [.system] : [.system, .microphone] }
}

@MainActor private final class CaptionTrackModels: ObservableObject {
    @Published var microphone: LiveCaptionState?
}

enum CaptionMicrophoneDeviceDecision { case unchanged, changed, unavailable }
enum CaptionMicrophoneDevicePolicy {
    static func decide(configured: String, current: String?) -> CaptionMicrophoneDeviceDecision {
        guard let current, !current.isEmpty else { return .unavailable }
        return current == configured ? .unchanged : .changed
    }
}

struct CaptionHistoryEntry: Identifiable {
    let id: UUID
    let original: String
    let sourceLanguage: String
    let targetLanguage: String
    var translated: String
}

/// Current subtitle and bounded history exist only in memory for this session.
@MainActor final class LiveCaptionState: ObservableObject {
    @Published private(set) var original = ""
    @Published private(set) var translated = ""
    @Published private(set) var revision = UUID()
    @Published private(set) var segmentID = UUID()
    @Published var status = "准备中"
    @Published var mode = "bilingual" { didSet { if mode != oldValue { if !managedSpeech { translated = "" }; revision = UUID() } } }
    @Published var sourceLanguage = "en-US"
    @Published var targetLanguage = "zh-Hans" {
        didSet { if targetLanguage != oldValue { translated = ""; translatedForOriginal = ""; revision = UUID() } }
    }
    @Published var audioSource: CaptionAudioSource = .system
    @Published var fontSize: Double = 23
    @Published var showHistory = false
    @Published var isCapturing = false
    @Published var needsSpeechModel = false
    /// Independent provider streams are intentionally not paired into history.
    @Published var managedSpeech = false
    @Published private(set) var history: [CaptionHistoryEntry] = []
    #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
    @Published private(set) var experimentalAttribution: [String] = []
    @Published var experimentalSpeakerEnabled = false
    private var experimentalWindows: [Int64: [(String, String)]] = [:]
    private var experimentalNames = CaptionSpeakerNames()
    func clearExperimentalAttribution() { experimentalAttribution = []; experimentalWindows.removeAll(); experimentalNames = CaptionSpeakerNames() }
    func acceptExperimentalAttribution(_ value: CaptionAttributedWindow) {
        guard value.window.isFinal else { return }
        let session = experimentalNames.sessionID
        var lines: [(String, String)] = []
        for word in value.words {
            let id = value.diarizationAvailable ? word.speakerID : nil
            if let id { _ = experimentalNames.observe(id, session: session) }
            let label = experimentalNames.displayName(for: id, session: session)
            if lines.last?.0 == label { lines[lines.count - 1].1 += word.word.text }
            else { lines.append((label, word.word.text)) }
        }
        experimentalWindows[value.window.startSample] = lines
        if experimentalWindows.count > 30 { for key in experimentalWindows.keys.sorted().prefix(experimentalWindows.count - 30) { experimentalWindows.removeValue(forKey: key) } }
        var combined: [(String, String)] = []
        for key in experimentalWindows.keys.sorted() {
            for (label, text) in experimentalWindows[key] ?? [] {
                if combined.last?.0 == label {
                    // A new rolling window may start without a leading space.
                    // Add one only between adjacent ASCII word characters;
                    // never insert it between CJK characters or punctuation.
                    let left = combined[combined.count - 1].1.last, right = text.first
                    if let left, let right, left.isASCII && right.isASCII && left.isLetter && right.isLetter { combined[combined.count - 1].1 += " " }
                    combined[combined.count - 1].1 += text
                } else { combined.append((label, text)) }
            }
        }
        experimentalAttribution = combined.map { "\($0.0)：\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" }
    }
    #endif
    private var translatedForOriginal = ""
    private var managedSourceSegment: Int?
    private var stableTranslationText = ""
    private var lastRecognitionUpdate = Date.distantPast
    private(set) var segmentFinalized = false
    /// Do not translate an incomplete trailing English word. Recognition
    /// results are revised as audio arrives and a fragment often means
    /// something entirely different from the completed word.
    var translationSnapshot: String {
        guard !original.isEmpty else { return "" }
        guard !segmentFinalized, sourceLanguage.hasPrefix("en") else { return original }
        // Some recognizers pause without sending a final event. After a quiet
        // interval, translate their complete latest hypothesis rather than
        // permanently omitting its last word.
        if Date().timeIntervalSince(lastRecognitionUpdate) >= 1.0 { return original }
        return stableTranslationText
    }
    var isTranslationCurrent: Bool { !translated.isEmpty && translatedForOriginal == original }
    func accept(_ text: String, final: Bool = false) {
        let bounded = String(text.suffix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let priorHypothesis = segmentFinalized ? "" : original
        if segmentFinalized && bounded != original {
            segmentID = UUID(); segmentFinalized = false
            translated = ""; translatedForOriginal = ""
            stableTranslationText = ""
        }
        if bounded != original && sourceLanguage.hasPrefix("en") {
            // Whisper partial hypotheses may invent the end of a phrase and
            // revise it two seconds later. Only translate words that survive
            // two consecutive hypotheses; the final result remains complete.
            let previous = priorHypothesis.split(whereSeparator: \.isWhitespace)
            let current = bounded.split(whereSeparator: \.isWhitespace)
            // Marswind's MIT-licensed LocalAgreement normalizes case and
            // punctuation when comparing consecutive Whisper hypotheses:
            // https://github.com/glenau/marswind/blob/51b0e6548b18349fab6c75e90a0c082a57c3e99b/src-tauri/src/asr/agreement.rs
            // Only trim edge punctuation here: internal apostrophes and
            // hyphens can change meaning ("can't" must not match "cant").
            func comparisonWord(_ word: Substring) -> String {
                String(word).trimmingCharacters(in: .punctuationCharacters)
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
            }
            let count = zip(previous, current).prefix {
                let left = comparisonWord($0), right = comparisonWord($1)
                return !left.isEmpty && left == right
            }.count
            stableTranslationText = count >= 3 ? current.prefix(count).joined(separator: " ") : ""
        }
        // A recognizer may replace the whole partial hypothesis, rather than
        // append to it. A translation of the old hypothesis must not be shown
        // under unrelated new words.
        if !original.isEmpty, !bounded.isEmpty, !bounded.hasPrefix(original),
           !original.hasPrefix(bounded), !translatedForOriginal.isEmpty,
           !bounded.hasPrefix(translatedForOriginal) {
            translated = ""; translatedForOriginal = ""
        }
        if bounded != original { original = bounded; lastRecognitionUpdate = Date(); revision = UUID() }
        if final && !bounded.isEmpty && history.last?.id != segmentID {
            history.append(CaptionHistoryEntry(id: segmentID, original: bounded, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, translated: translatedForOriginal == bounded ? translated : ""))
            if history.count > 30 { history.removeFirst(history.count - 30) }
        }
        if final && !bounded.isEmpty && !segmentFinalized { segmentFinalized = true; revision = UUID() }
    }
    func acceptTranslation(_ text: String, revision: UUID) {
        guard revision == self.revision else { return }
        acceptTranslation(text, forOriginal: original)
    }
    func clearTranslation() { translated = ""; translatedForOriginal = "" }
    func acceptManagedTranslation(_ text: String) {
        guard managedSpeech else { return }
        translated = String(text.suffix(4_000))
        translatedForOriginal = ""
    }
    func acceptManagedSource(_ text: String, segment: Int, final: Bool) {
        guard managedSpeech, segment >= 0 else { return }
        if managedSourceSegment != segment {
            managedSourceSegment = segment; segmentID = UUID(); segmentFinalized = false
            original = ""; stableTranslationText = ""; translatedForOriginal = ""
        }
        accept(text, final: final)
    }
    func acceptTranslation(_ text: String, forOriginal source: String) {
        acceptTranslation(text, forOriginal: source, segment: segmentID)
    }
    func acceptTranslation(_ text: String, forOriginal source: String, segment: UUID, target: String? = nil) {
        let target = target ?? targetLanguage
        if let index = history.indices.last(where: { history[$0].id == segment && history[$0].original == source && history[$0].targetLanguage == target }) { history[index].translated = text }
        guard target == targetLanguage, segment == segmentID, !source.isEmpty, original.hasPrefix(source) else { return }
        if original.hasPrefix(translatedForOriginal), !translatedForOriginal.isEmpty,
           source.count < translatedForOriginal.count { return }
        translated = text
        translatedForOriginal = source
    }
    func clearCurrent() {
        original = ""; translated = ""; translatedForOriginal = ""; stableTranslationText = ""; managedSourceSegment = nil; lastRecognitionUpdate = .distantPast; segmentFinalized = false; segmentID = UUID(); revision = UUID()
        #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
        clearExperimentalAttribution()
        #endif
    }
    func restoreHistory(_ entries: [CaptionHistoryEntry]) { history = Array(entries.suffix(30)) }
    func reset() { clearCurrent(); history.removeAll(); isCapturing = false }
}

/// Routes only the explicitly selected source; audio is never written to disk.
private final class LiveCaptionAudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var analyzerHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var whisperHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var audioSource: CaptionAudioSource = .system
    private weak var activeStream: SCStream?
    func selectSource(_ source: CaptionAudioSource, stream: SCStream) { lock.lock(); audioSource = source; activeStream = stream; lock.unlock() }
    func setWhisper(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) { lock.lock(); whisperHandler = handler; lock.unlock() }
    func setAnalyzer(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) { lock.lock(); analyzerHandler = handler; lock.unlock() }
    private var recent: [(CMSampleBuffer, Double)] = []
    private var recentDuration = 0.0
    // A short in-memory overlap bridges recognizer renewal. It is never saved.
    func set(_ request: SFSpeechAudioBufferRecognitionRequest?, replay: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
        if replay, let request { for (sample, _) in recent { request.appendAudioSampleBuffer(sample) } }
    }
    func clear() { lock.lock(); activeStream = nil; request = nil; analyzerHandler = nil; whisperHandler = nil; recent.removeAll(); recentDuration = 0; lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        lock.lock(); defer { lock.unlock() }
        guard activeStream === stream, audioSource.accepts(type) else { return }
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        let seconds = duration.isFinite && duration > 0 ? min(duration, 1) : 0.05
        recent.append((sample, seconds)); recentDuration += seconds
        while recent.count > 128 || (recent.count > 1 && recentDuration > 1) { recentDuration -= recent.removeFirst().1 }
        request?.appendAudioSampleBuffer(sample)
        analyzerHandler?(sample)
        whisperHandler?(sample)
    }
}

// Disabled pending investigation of a reproducible system-framework SIGTRAP
// in AnalyzerInput(buffer:). Never run an unverified crash path in the app.
enum CaptionAnalyzerAvailability { static let enabled = false }

@available(macOS 26.0, *)
private final class CaptionAnalyzerBridge: @unchecked Sendable {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let sequence: AsyncStream<AnalyzerInput>
    private var resultTask: Task<Void, Never>?
    init(locale: Locale) {
        transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(100))
        sequence = stream.stream; continuation = stream.continuation
    }
    func start(onResult: @escaping @Sendable (String, Bool) -> Void, onError: @escaping @Sendable () -> Void) async throws {
        try await analyzer.start(inputSequence: sequence)
        resultTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch { if !Task.isCancelled { onError() } }
        }
    }
    func append(_ sample: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }
    func stop() {
        continuation.finish(); resultTask?.cancel(); resultTask = nil
        let analyzer = analyzer; Task { await analyzer.cancelAndFinishNow() }
    }
}

@MainActor final class LiveCaptionsCoordinator: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private let sink = LiveCaptionAudioSink()
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var analyzerBridge: AnyObject?
    private var whisper: LocalWhisperCaptionEngine?
    #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
    private var experimentalSpeaker: ExperimentalCaptionSpeakerAdapter?
    private var experimentalAcceptedSamples: Int64 = 0
    #endif
    private var managedSpeechStream: ManagedSpeechStream?
    private var managedSpeechAudio: ManagedSpeechAudioBridge?
    private var managedSpeechEvents: Task<Void, Never>?
    private var managedSpeechConsentObserver: ManagedSpeechConsentMonitor?
    private var renewal: Task<Void, Never>?
    private var setup: Task<Void, Never>?
    private var generation = UUID(), recognitionID = UUID(), recognitionSetupID = UUID()
    private var panel: NSPanel?
    private var state: LiveCaptionState?
    private var microphoneCoordinator: LiveCaptionsCoordinator?
    private var retainedMicrophoneHistory: [CaptionHistoryEntry] = []
    private var microphoneSourceLanguage = "zh-CN"
    private var microphoneTargetLanguage = "en-US"
    private let tracks = CaptionTrackModels()
    private let presentsPanel: Bool
    private var sessionMode: CaptionSessionMode = .captions
    private var onModelChange: ((LiveCaptionState?) -> Void)?
    var onStop: (() -> Void)?

    override convenience init() { self.init(presentsPanel: true) }
    private init(presentsPanel: Bool) { self.presentsPanel = presentsPanel; super.init() }

    /// Called only from a user action.
    func start(sourceLanguage: String = "en-US", audioSource: CaptionAudioSource = .system, preserveSession: Bool = false, mode: CaptionSessionMode? = nil, targetLanguage: String? = nil) {
        let selectedMode = mode ?? sessionMode
        let audioSource: CaptionAudioSource = presentsPanel ? .system : audioSource
        if preserveSession, let state, !state.original.isEmpty { state.accept(state.original, final: true) }
        if presentsPanel && preserveSession { retainMicrophoneHistory() }
        else if presentsPanel { retainedMicrophoneHistory.removeAll() }
        let savedHistory = preserveSession ? state?.history ?? [] : []
        let savedMode = preserveSession ? state?.mode : nil
        let savedTarget = preserveSession ? state?.targetLanguage : nil
        let savedSize = preserveSession ? state?.fontSize : nil
        let savedFrame = preserveSession ? panel?.frame : nil
        stop(notify: false)
        sessionMode = selectedMode
        let model = LiveCaptionState(); model.sourceLanguage = sourceLanguage; model.targetLanguage = targetLanguage ?? savedTarget ?? "zh-Hans"; model.audioSource = audioSource; state = model
        onModelChange?(model)
        model.restoreHistory(savedHistory)
        if let savedMode { model.mode = savedMode }; if let savedSize { model.fontSize = savedSize }
        if presentsPanel { showPanel(model, frame: savedFrame) }
        let id = UUID(); generation = id
        setup = Task { @MainActor [weak self] in
            guard let self else { return }
            guard CGPreflightScreenCaptureAccess() else { model.status = "请先授权屏幕与系统音频录制。"; return }
            if audioSource == .microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { model.status = "请先在系统设置中允许麦克风访问。"; return }
                guard !Task.isCancelled, self.generation == id else { return }
            }
            let microphoneID: String?
            if audioSource == .microphone {
                guard let id = AVCaptureDevice.default(for: .audio)?.uniqueID, !id.isEmpty else {
                    model.status = "没有可用的麦克风，请检查系统输入设备后重试。"; return
                }
                microphoneID = id
            } else { microphoneID = nil }
            guard await self.installRecognition(language: model.sourceLanguage, generation: id) else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, self.generation == id else { return }
                guard let display = content.displays.first else { throw CaptionFailure.display }
                let config = SCStreamConfiguration(); config.capturesAudio = audioSource == .system; config.excludesCurrentProcessAudio = true
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                if #available(macOS 15.0, *) {
                    config.captureMicrophone = audioSource == .microphone
                    if let microphoneID { config.microphoneCaptureDeviceID = microphoneID }
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.sink.selectSource(audioSource, stream: stream)
                try stream.addStreamOutput(self.sink, type: audioSource == .system ? .audio : .microphone, sampleHandlerQueue: DispatchQueue(label: "local.moriq.captions.audio", qos: .userInitiated))
                self.stream = stream
                try await stream.startCapture()
                guard !Task.isCancelled, self.generation == id else { try? await stream.stopCapture(); return }
                model.isCapturing = true
                model.status = model.managedSpeech ? "正在向语音服务发送\(audioSource.label)" : "正在聆听\(audioSource.label)"
                if self.presentsPanel && selectedMode.audioSources.contains(.microphone) {
                    let child = LiveCaptionsCoordinator(presentsPanel: false)
                    child.onModelChange = { [weak self] model in self?.tracks.microphone = model }
                    self.microphoneCoordinator = child
                    child.start(sourceLanguage: self.microphoneSourceLanguage, audioSource: .microphone, targetLanguage: self.microphoneTargetLanguage)
                    child.state?.restoreHistory(self.retainedMicrophoneHistory)
                }
                self.renewal = Task { @MainActor [weak self] in
                    var elapsed = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self, self.generation == id else { return }
                        guard CGPreflightScreenCaptureAccess() else {
                            CaptionAudioPermissionProbe.verifiedThisLaunch = false; CaptionAudioPermissionProbe.previouslyVerified = false
                            self.endCapture(); model.status = "屏幕与系统音频权限已撤销，字幕已停止。"; return
                        }
                        if audioSource == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                            self.endCapture(); model.status = "麦克风权限已撤销，字幕已停止。"; return
                        }
                        if let microphoneID {
                            switch CaptionMicrophoneDevicePolicy.decide(configured: microphoneID, current: AVCaptureDevice.default(for: .audio)?.uniqueID) {
                            case .unchanged: break
                            case .changed:
                                self.start(sourceLanguage: model.sourceLanguage, audioSource: .microphone, preserveSession: true); return
                            case .unavailable:
                                self.endCapture(); model.status = "麦克风已断开，请检查系统输入设备后重试。"; return
                            }
                        }
                        elapsed += 1
                        if elapsed >= 45 {
                            elapsed = 0
                            #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
                            let experimentalActive = self.experimentalSpeaker != nil
                            #else
                            let experimentalActive = false
                            #endif
                            if self.analyzerBridge == nil && self.whisper == nil && self.managedSpeechStream == nil && !experimentalActive { _ = await self.installRecognition(language: model.sourceLanguage, generation: id) }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, self.generation == id else { return }
                CaptionAudioPermissionProbe.verifiedThisLaunch = false; CaptionAudioPermissionProbe.previouslyVerified = false
                self.endCapture(); model.status = "\(audioSource.label)无法启动，请检查相关系统权限。"
            }
        }
    }
    #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
    private func installExperimentalRecognition(language: String, generation: UUID, environment: [String: String]) -> Bool {
        guard let model = state, presentsPanel, sessionMode == .captions, model.audioSource == .system else {
            state?.status = "实验说话人识别仅支持单路系统声音。"; return false
        }
        let keys = ["MORIQ_WHISPER_HELPER", "MORIQ_WHISPER_MODEL", "MORIQ_SPEAKER_HELPER", "MORIQ_SPEAKER_MODEL"]
        guard keys.allSatisfy({ environment[$0]?.hasPrefix("/") == true }),
              let minimum = environment["MORIQ_SPEAKER_MINIMUM_COVERAGE"].flatMap(Double.init),
              let maximum = environment["MORIQ_SPEAKER_MAXIMUM_COMPETITION"].flatMap(Double.init) else {
            model.status = "实验模型路径或阈值未配置。"; return false
        }
        let id = UUID(); recognitionID = id; experimentalAcceptedSamples = 0
        sink.set(nil); sink.setAnalyzer(nil); sink.setWhisper(nil)
        whisper?.stop(); whisper = nil
        experimentalSpeaker?.stop(); experimentalSpeaker = nil
        do {
            let adapter = try ExperimentalCaptionSpeakerAdapter.make(environment: environment,
                whisperHelper: URL(fileURLWithPath: environment[keys[0]]!), whisperModel: URL(fileURLWithPath: environment[keys[1]]!),
                speakerHelper: URL(fileURLWithPath: environment[keys[2]]!), speakerModel: URL(fileURLWithPath: environment[keys[3]]!),
                language: language, minimumCoverage: minimum, maximumCompetition: maximum,
                onText: { [weak self, weak model] text, final in
                    Task { @MainActor in guard let self, let model, self.generation == generation, self.recognitionID == id, self.state === model else { return }; model.accept(text, final: final) }
                }, onUpdate: { [weak self, weak model] update in
                    Task { @MainActor in guard let self, let model, self.generation == generation, self.recognitionID == id, self.state === model else { return }; model.acceptExperimentalAttribution(update) }
                }, onError: { [weak self, weak model] message in
                    Task { @MainActor in guard let self, let model, self.generation == generation, self.recognitionID == id, self.state === model else { return }; self.endCapture(); model.status = message }
                }, onAcceptedSamples: { [weak self] count in
                    Task { @MainActor in guard let self, self.generation == generation, self.recognitionID == id else { return }; self.experimentalAcceptedSamples = count }
                })
            guard let adapter else { model.status = "实验说话人识别未启用。"; return false }
            experimentalSpeaker = adapter
            model.experimentalSpeakerEnabled = true
            sink.setWhisper { [weak adapter] sample in adapter?.append(sample) }
            return true
        } catch {
            model.status = "实验说话人识别启动失败，请检查本机模型、语言与阈值。"; return false
        }
    }
    #endif
    private func installRecognition(language: String, generation: UUID) async -> Bool {
        let setupID = UUID(); recognitionSetupID = setupID
        #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
        if ProcessInfo.processInfo.environment["MORIQ_EXPERIMENTAL_SPEAKER"] == "1" {
            return installExperimentalRecognition(language: language, generation: generation, environment: ProcessInfo.processInfo.environment)
        }
        #endif
        // Explicit configuration is required; an invalid setup never silently
        // falls back to a local engine after the user selected managed speech.
        if let configured = Bundle.main.object(forInfoDictionaryKey: "MORIQManagedSpeechEndpoint") {
            guard let model = state else { return false }
            model.managedSpeech = true
            let consentKeys = [model.audioSource == .microphone ? ManagedSpeechConsentMonitor.microphoneKey : ManagedSpeechConsentMonitor.key]
            guard consentKeys.allSatisfy({ UserDefaults.standard.bool(forKey: $0) }) else {
                model.status = "请先在设置中同意发送所选声音。"; return false
            }
            managedSpeechConsentObserver?.stop()
            managedSpeechConsentObserver = ManagedSpeechConsentMonitor(requiredKeys: consentKeys) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.setup?.cancel(); self.endCapture(); self.state?.status = "声音发送授权已撤销，字幕已停止。"
            }
            guard let value = configured as? String, let endpoint = URL(string: value),
                  let token = try? ManagedAIAccountToken().load(), !token.isEmpty else {
                model.status = "语音服务或账户尚未配置。"; return false
            }
            let source = String(language.prefix(2)).lowercased()
            let target = String(model.targetLanguage.prefix(2)).lowercased()
            guard ["en", "zh", "ja", "ko"].contains(source), ["en", "zh"].contains(target), source != target else {
                model.status = "请选择受支持且不同的语音与翻译语言。"; return false
            }
            do {
                sink.setWhisper(nil); managedSpeechAudio?.stop(); managedSpeechAudio = nil
                managedSpeechEvents?.cancel(); managedSpeechEvents = nil
                if let previous = managedSpeechStream { managedSpeechStream = nil; await previous.cancel() }
                let remote = try ManagedSpeechStream(endpoint: endpoint, token: token)
                managedSpeechStream = remote
                let events = try await remote.start(source: source, target: target)
                var iterator = events.makeAsyncIterator()
                guard let first = try await iterator.next(), first.type == "ready", self.generation == generation, self.recognitionSetupID == setupID,
                      consentKeys.allSatisfy({ UserDefaults.standard.bool(forKey: $0) }), !Task.isCancelled else {
                    await remote.cancel(); managedSpeechStream = nil
                    model.status = "语音服务未能连接，请重试。"; return false
                }
                let bridge = ManagedSpeechAudioBridge(stream: remote) { [weak self] in
                    Task { @MainActor in guard let self, self.generation == generation, self.recognitionSetupID == setupID else { return }; self.endCapture(); self.state?.status = "语音连接中断，字幕已停止。" }
                }
                managedSpeechAudio = bridge
                sink.setWhisper { [weak bridge] sample in bridge?.append(sample) }
                managedSpeechEvents = Task { @MainActor [weak self] in
                    do {
                        var accumulator = ManagedSpeechAccumulator()
                        while let event = try await iterator.next() {
                            guard let self, self.generation == generation, self.recognitionSetupID == setupID, !Task.isCancelled else { return }
                            // Independent tracks: the provider has not promised
                            // that original/translation segment IDs correspond.
                            guard let current = accumulator.accept(event), let segment = event.segment else { continue }
                            if event.type == "source" { model.acceptManagedSource(current.text, segment: segment, final: current.final) }
                            else if event.type == "translation" { model.acceptManagedTranslation(current.text) }
                        }
                        guard let self, self.generation == generation, !Task.isCancelled else { return }
                        self.endCapture(); model.status = "语音连接已结束，字幕已停止。"
                    } catch {
                        guard let self, self.generation == generation, !Task.isCancelled else { return }
                        self.endCapture(); model.status = "语音连接中断，字幕已停止。"
                    }
                }
                return true
            } catch {
                if let remote = managedSpeechStream { await remote.cancel() }
                managedSpeechStream = nil
                guard self.generation == generation else { return false }
                model.status = "语音服务未能连接，请检查网络或账户后重试。"; return false
            }
        }
        state?.managedSpeech = false
        if let helper = LocalWhisperModel.helper, let model = state {
            model.status = "正在准备本机字幕模型…"; model.needsSpeechModel = false
            do {
                let path = try await LocalWhisperModel.prepare { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == generation, self.recognitionSetupID == setupID else { return }
                        let percent = fraction.isFinite ? Int(max(0, min(1, fraction)) * 100) : 0
                        self.state?.status = "正在下载本机字幕模型 · \(percent)%"
                    }
                }
                try Task.checkCancellation()
                guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                let id = UUID(); recognitionID = id
                sink.set(nil); sink.setAnalyzer(nil); sink.setWhisper(nil)
                speechRequest?.endAudio(); speechTask?.cancel(); speechRequest = nil; speechTask = nil
                if #available(macOS 26.0, *), let bridge = analyzerBridge as? CaptionAnalyzerBridge { bridge.stop() }
                analyzerBridge = nil; whisper?.stop()
                let languageCode = String(language.prefix(2)).lowercased()
                let engine = try LocalWhisperCaptionEngine(helper: helper, model: path, language: languageCode, onText: { [weak self] text, final in
                    Task { @MainActor in guard let self, self.generation == generation, self.recognitionID == id else { return }; self.state?.accept(text, final: final) }
                }, onError: { [weak self] message in
                    Task { @MainActor in guard let self, self.generation == generation, self.recognitionID == id else { return }; self.endCapture(); self.state?.status = message }
                })
                whisper = engine; sink.setWhisper { [weak engine] sample in engine?.append(sample) }
                return true
            } catch is CancellationError { return false }
            catch {
                guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                if let fallback = SFSpeechRecognizer(locale: Locale(identifier: language)), fallback.supportsOnDeviceRecognition, fallback.isAvailable {
                    model.status = "模型准备失败，尝试系统本机语音识别。"
                } else {
                    model.needsSpeechModel = true; model.status = "本机字幕模型下载或校验失败，请检查网络后重试。"; return false
                }
            }
        }
        if #available(macOS 26.0, *), CaptionAnalyzerAvailability.enabled, SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            guard self.generation == generation, self.recognitionSetupID == setupID, let model = state else { return false }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            var assetStatus = await AssetInventory.status(forModules: [transcriber])
            guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
            if assetStatus == .supported || assetStatus == .downloading {
                model.needsSpeechModel = false; model.status = "正在准备系统语音资源…"
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        let progress = request.progress
                        let monitor = Task { @MainActor in
                            while !Task.isCancelled && self.generation == generation && self.recognitionSetupID == setupID {
                                let fraction = progress.fractionCompleted
                                let percent = fraction.isFinite ? Int(max(0, min(1, fraction)) * 100) : 0
                                model.status = "正在准备系统语音资源 · \(percent)%"
                                try? await Task.sleep(for: .milliseconds(300))
                            }
                        }
                        defer { monitor.cancel() }
                        try await request.downloadAndInstall()
                    }
                    try Task.checkCancellation()
                    assetStatus = await AssetInventory.status(forModules: [transcriber])
                    guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                } catch is CancellationError { return false }
                catch {
                    guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                    model.needsSpeechModel = true; model.status = "语音资源下载失败，请检查网络后重试。"; return false
                }
            }
            if assetStatus == .installed {
                let id = UUID(); recognitionID = id
                sink.set(nil); sink.setAnalyzer(nil); speechRequest?.endAudio(); speechTask?.cancel(); speechRequest = nil; speechTask = nil
                if let old = analyzerBridge as? CaptionAnalyzerBridge { old.stop() }; analyzerBridge = nil
                let bridge = CaptionAnalyzerBridge(locale: locale)
                do {
                    try await bridge.start(onResult: { [weak self] text, final in
                        Task { @MainActor in guard let self, self.generation == generation, self.recognitionID == id else { return }; self.state?.accept(text, final: final) }
                    }, onError: { [weak self] in
                        Task { @MainActor in guard let self, self.generation == generation, self.recognitionID == id else { return }; self.endCapture(); self.state?.status = "本机语音识别已停止，请重试。" }
                    })
                    guard self.generation == generation, self.recognitionSetupID == setupID else { bridge.stop(); return false }
                    analyzerBridge = bridge; sink.setAnalyzer { [weak bridge] sample in bridge?.append(sample) }
                    model.needsSpeechModel = false
                    return true
                } catch { bridge.stop(); model.status = "本机语音识别无法启动，请重试。"; return false }
            }
            if assetStatus == .supported || assetStatus == .downloading {
                model.needsSpeechModel = true; model.status = "系统语音资源尚未准备好，请重试。"; return false
            }
        }
        guard self.generation == generation, self.recognitionSetupID == setupID, !Task.isCancelled else { return false }
        let authorization: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            state?.status = "本机模型不可用，正在请求系统语音识别权限。"
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { authorization = SFSpeechRecognizer.authorizationStatus() }
        guard self.generation == generation, self.recognitionSetupID == setupID, !Task.isCancelled else { return false }
        guard authorization == .authorized else {
            state?.needsSpeechModel = true
            state?.status = "系统语音识别未获授权；请允许该权限，或重试下载本机模型。"
            return false
        }
        sink.setAnalyzer(nil)
        if #available(macOS 26.0, *), let bridge = analyzerBridge as? CaptionAnalyzerBridge { bridge.stop() }
        analyzerBridge = nil
        state?.needsSpeechModel = false
        guard let model = state, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            state?.status = "本机语音识别暂不可用；可在系统设置 → 键盘 → 听写中尝试添加该语言，或切换语言。"; return false
        }
        // Commit the last partial before retiring a long-running recognizer.
        // The old callback is invalidated below, so it cannot overwrite the new one.
        if !model.original.isEmpty { model.accept(model.original, final: true) }
        let id = UUID(); recognitionID = id
        sink.set(nil); speechRequest?.endAudio(); speechTask?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true
        speechRequest = request; sink.set(request, replay: true)
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == generation, self.recognitionID == id else { return }
                if let result { model.accept(result.bestTranscription.formattedString, final: result.isFinal) }
                if let error {
                    self.endCapture(); model.status = "语音识别已停止，请检查本机语言资源后重试。"
                    _ = error
                } else if result?.isFinal == true {
                    Task { @MainActor in _ = await self.installRecognition(language: language, generation: generation) }
                }
            }
        }
        return true
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            CaptionAudioPermissionProbe.verifiedThisLaunch = false; CaptionAudioPermissionProbe.previouslyVerified = false
            let source = self.state?.audioSource.label ?? "声音"
            self.endCapture(); self.state?.status = "\(source)已停止，请检查权限后重试。"
        }
    }
    private func installModel() {
        guard let model = state else { return }
        start(sourceLanguage: model.sourceLanguage, audioSource: model.audioSource, preserveSession: true)
    }
    private func retainMicrophoneHistory() {
        guard let microphone = microphoneCoordinator?.state else { return }
        microphoneSourceLanguage = microphone.sourceLanguage
        microphoneTargetLanguage = microphone.targetLanguage
        if !microphone.original.isEmpty { microphone.accept(microphone.original, final: true) }
        retainedMicrophoneHistory = microphone.history
    }
    private func showPanel(_ model: LiveCaptionState, frame: NSRect? = nil) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let panelHeight: CGFloat = sessionMode == .interpretation ? 292 : 196
        let panel = NSPanel(contentRect: CGRect(x: screen.midX - 310, y: screen.minY + 70, width: 620, height: panelHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let frame { panel.setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 620, height: panelHeight), display: false) }
        panel.contentView = NSHostingView(rootView: CaptionTrackStack(tracks: tracks, mainState: model, combined: sessionMode == .interpretation, main: makeCaptionView(model, secondary: false), microphone: { [weak self] mic in
            self?.makeCaptionView(mic, secondary: true)
        }))
        self.panel = panel; panel.orderFrontRegardless()
    }
    private func makeCaptionView(_ model: LiveCaptionState, secondary: Bool) -> LiveCaptionView {
        LiveCaptionView(state: model, close: { [weak self] in self?.stop() }, installModel: { [weak self] in
            if secondary { self?.microphoneCoordinator?.installModel() } else { self?.installModel() }
        }, changeLanguage: { [weak self] language in
            guard let self else { return }
            if secondary {
                self.microphoneSourceLanguage = language
                self.microphoneTargetLanguage = model.targetLanguage
                self.microphoneCoordinator?.start(sourceLanguage: language, audioSource: .microphone, preserveSession: true, targetLanguage: model.targetLanguage)
                return
            }
            if self.stream == nil { self.start(sourceLanguage: language, audioSource: model.audioSource); return }
            model.clearCurrent(); model.isCapturing = true
            let token = self.generation
            self.setup?.cancel()
            self.setup = Task { @MainActor in
                let installed = await self.installRecognition(language: language, generation: token)
                guard self.generation == token, self.state?.sourceLanguage == language else { return }
                if !installed { self.endCapture() }
            }
        }, changeAudioSource: { [weak self] source in
            self?.start(sourceLanguage: model.sourceLanguage, audioSource: source, preserveSession: true)
        }, changeSessionMode: { [weak self] mode in
            self?.start(sourceLanguage: model.sourceLanguage, audioSource: .system, preserveSession: true, mode: mode)
        }, changeTargetLanguage: { [weak self] target in
            guard let self else { return }
            if secondary { self.microphoneTargetLanguage = target }
            // Local translation updates its own task. A managed stream has a
            // fixed language pair, so restart only the affected audio track.
            guard model.managedSpeech else { return }
            if secondary {
                self.microphoneCoordinator?.start(sourceLanguage: model.sourceLanguage, audioSource: .microphone, preserveSession: true, targetLanguage: target)
            } else {
                self.start(sourceLanguage: model.sourceLanguage, audioSource: .system, preserveSession: true, targetLanguage: target)
            }
        }, selectedSessionMode: sessionMode, secondaryTrack: secondary, embeddedTrack: sessionMode == .interpretation)
    }
    private func endCapture() {
        if presentsPanel { microphoneCoordinator?.stop(notify: false); microphoneCoordinator = nil; tracks.microphone = nil }
        state?.isCapturing = false
        recognitionID = UUID(); recognitionSetupID = UUID(); renewal?.cancel(); renewal = nil
        sink.clear(); managedSpeechAudio?.stop(); managedSpeechAudio = nil
        managedSpeechConsentObserver?.stop(); managedSpeechConsentObserver = nil
        managedSpeechEvents?.cancel(); managedSpeechEvents = nil
        if let remote = managedSpeechStream { managedSpeechStream = nil; Task { await remote.cancel() } }
        whisper?.stop(); whisper = nil
        #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
        experimentalSpeaker?.stop(); experimentalSpeaker = nil
        state?.experimentalSpeakerEnabled = false
        state?.clearExperimentalAttribution()
        #endif
        if #available(macOS 26.0, *), let bridge = analyzerBridge as? CaptionAnalyzerBridge { bridge.stop() }
        analyzerBridge = nil; speechRequest?.endAudio(); speechTask?.cancel(); speechRequest = nil; speechTask = nil
        if let stream { self.stream = nil; Task { try? await stream.stopCapture() } }
    }
    func stop(notify: Bool = true) {
        microphoneCoordinator?.stop(notify: false); microphoneCoordinator = nil; tracks.microphone = nil
        if notify { retainedMicrophoneHistory.removeAll() }
        generation = UUID(); setup?.cancel(); setup = nil; endCapture()
        panel?.orderOut(nil); panel = nil; state?.reset(); state = nil
        onModelChange?(nil)
        if notify { onStop?() }
    }
    private enum CaptionFailure: Error { case display }

    #if DEBUG
    /// Offscreen UI/lifecycle test hook. Never starts a stream or recognizer.
    func debugOpenWithoutCapture(mode: CaptionSessionMode, preserveSession: Bool = false) {
        if preserveSession { retainMicrophoneHistory() }
        else { retainedMicrophoneHistory.removeAll() }
        stop(notify: false)
        sessionMode = mode
        let model = LiveCaptionState(); model.audioSource = .system; state = model
        if mode == .interpretation {
            let child = LiveCaptionsCoordinator(presentsPanel: false)
            let mic = LiveCaptionState(); mic.audioSource = .microphone; mic.sourceLanguage = microphoneSourceLanguage; mic.targetLanguage = microphoneTargetLanguage; mic.restoreHistory(retainedMicrophoneHistory)
            child.state = mic; microphoneCoordinator = child; tracks.microphone = mic
        }
        showPanel(model, frame: NSRect(x: -3000, y: -3000, width: 620, height: 196))
    }
    var debugHasPanel: Bool { panel != nil }
    var debugHasMicrophoneTrack: Bool { tracks.microphone != nil }
    var debugSessionMode: CaptionSessionMode { sessionMode }
    func debugAcceptMicrophone(_ text: String) { microphoneCoordinator?.state?.accept(text) }
    var debugMicrophoneHistory: [CaptionHistoryEntry] { microphoneCoordinator?.state?.history ?? [] }
    var debugMicrophoneLanguages: (String, String)? { microphoneCoordinator?.state.map { ($0.sourceLanguage, $0.targetLanguage) } }
    #if MORIQ_SPEAKER_EXPERIMENTAL
    func debugStartSpeakerWithoutCapture(environment: [String: String], language: String = "en-US") -> Bool {
        debugOpenWithoutCapture(mode: .captions)
        state?.sourceLanguage = language
        return installExperimentalRecognition(language: language, generation: generation, environment: environment)
    }
    func debugAppendSpeakerPCM(_ data: Data) { experimentalSpeaker?.appendTestPCM(data) }
    func debugFinishSpeakerPCM() { experimentalSpeaker?.finishSpeakerInput() }
    var debugSpeakerAttribution: [String] { state?.experimentalAttribution ?? [] }
    var debugSpeakerAcceptedSamples: Int64 { experimentalAcceptedSamples }
    func debugSaveSpeakerPreview(to url: URL) throws {
        guard let view = panel?.contentView else { throw CaptionFailure.display }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptionFailure.display }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CaptionFailure.display }
        try data.write(to: url)
    }
    #endif
    #endif
}

private struct CaptionTrackStack: View {
    @ObservedObject var tracks: CaptionTrackModels
    @ObservedObject var mainState: LiveCaptionState
    let combined: Bool
    let main: LiveCaptionView
    let microphone: (LiveCaptionState) -> LiveCaptionView?
    var body: some View {
        VStack(spacing: 0) {
            main
            if let model = tracks.microphone, let view = microphone(model) { view }
        }
        .frame(width: 620, height: combined ? 292 : 196, alignment: .top)
        .background {
            if combined { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial) }
        }
        .overlay {
            if combined {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                VStack(spacing: 0) {
                    Spacer().frame(height: 146)
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 20)
                    Spacer()
                }.allowsHitTesting(false)
            }
        }
        .onReceive(tracks.$microphone) { model in
            model?.mode = mainState.mode
            model?.fontSize = mainState.fontSize
        }
        .onChange(of: mainState.mode) { _, value in tracks.microphone?.mode = value }
        .onChange(of: mainState.fontSize) { _, value in tracks.microphone?.fontSize = value }
    }
}

private struct LiveCaptionView: View {
    @ObservedObject var state: LiveCaptionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let close: () -> Void
    let installModel: () -> Void
    let changeLanguage: (String) -> Void
    let changeAudioSource: (CaptionAudioSource) -> Void
    var changeSessionMode: ((CaptionSessionMode) -> Void)? = nil
    var changeTargetLanguage: ((String) -> Void)? = nil
    var selectedSessionMode: CaptionSessionMode = .captions
    var secondaryTrack = false
    var embeddedTrack = false
    @State private var configuration: TranslationSession.Configuration?
    @State private var debounce: Task<Void, Never>?
    @State private var translationInFlight = false
    @State private var translationSource = ""
    @State private var translationLanguage = ""
    @State private var translationTargetLanguage = ""
    @State private var translationRequestID = UUID()
    @State private var translationSegment = UUID()
    @State private var visibleOriginal = ""
    @State private var visibleTranslation = ""
    @State private var followingLiveCaption = true
    @State private var userIsScrollingCaptions = false
    @State private var lastFollowedContentHeight: CGFloat = 0
    private var languageName: String {
        switch state.sourceLanguage { case "zh-CN": return "中文"; case "ja-JP": return "日语"; case "ko-KR": return "韩语"; default: return "英语" }
    }
    private var targetLanguageName: String { state.targetLanguage.hasPrefix("zh") ? "中文" : "英语" }
    private var modeName: String {
        switch state.mode { case "original": return "原文"; case "zh": return "译文"; default: return "双语" }
    }
    private var precedingHistory: [CaptionHistoryEntry] {
        if state.history.last?.id == state.segmentID { return Array(state.history.dropLast()) }
        return state.history
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(state.isCapturing ? Color(red: 0.18, green: 0.43, blue: 1) : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                Text(state.isCapturing && state.status == "正在处理系统音频 · 本机识别" ? "正在聆听" : state.status)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
                if state.experimentalSpeakerEnabled { Text("实验").font(.system(size: 10)).foregroundStyle(.secondary) }
                #endif
                Spacer()
                if state.needsSpeechModel { Button("重试", action: installModel).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).help("重试语音资源") }
                if secondaryTrack {
                    Text("麦克风").foregroundStyle(.secondary)
                } else if let changeSessionMode {
                    Menu {
                        ForEach(CaptionSessionMode.allCases, id: \.self) { mode in
                            Button(mode.label) { if mode != selectedSessionMode { changeSessionMode(mode) } }
                        }
                    } label: { HStack(spacing: 4) { Text(selectedSessionMode.label); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择字幕模式")
                } else {
                    Menu {
                        ForEach(CaptionAudioSource.allCases, id: \.self) { source in
                            Button(source.label) { if source != state.audioSource { changeAudioSource(source) } }
                        }
                    } label: { HStack(spacing: 4) { Text(state.audioSource.label); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择声音来源")
                }
                Menu {
                    Picker("语音语言", selection: $state.sourceLanguage) { Text("英语").tag("en-US"); Text("中文").tag("zh-CN"); Text("日语").tag("ja-JP"); Text("韩语").tag("ko-KR") }
                    Picker("翻译语言", selection: $state.targetLanguage) { Text("中文").tag("zh-Hans"); Text("英语").tag("en-US") }
                } label: { HStack(spacing: 4) { Text("\(languageName) → \(targetLanguageName)"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择语音与翻译语言").accessibilityLabel("语音语言，\(languageName)，翻译语言，\(targetLanguageName)")
                if !secondaryTrack {
                Menu {
                    Picker("字幕模式", selection: $state.mode) { Text("双语").tag("bilingual"); Text("原文").tag("original"); Text("译文").tag("zh") }
                } label: { HStack(spacing: 4) { Text(modeName); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择字幕模式").accessibilityLabel("字幕模式，\(modeName)")
                Button { state.showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 22, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(state.showHistory ? Color.accentColor : Color.secondary).help("字幕记录").accessibilityLabel("字幕记录")
                Button { state.fontSize = state.fontSize >= 29 ? 19 : state.fontSize + 2 } label: { Image(systemName: "textformat.size").frame(width: 22, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("调整字号").accessibilityLabel("调整字号")
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("停止字幕").accessibilityLabel("停止字幕")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(height: 26)
            Spacer(minLength: 6)
            if state.showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.history) { item in
                            HStack {
                                Text(item.translated.isEmpty ? item.original : item.original + "\n" + item.translated).textSelection(.enabled)
                                Spacer()
                                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.translated.isEmpty ? item.original : item.original + "\n" + item.translated, forType: .string) }.buttonStyle(.plain)
                            }
                        }
                        if state.history.isEmpty { Text("暂无已完成的字幕").foregroundStyle(.secondary) }
                    }
                }.font(.caption)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(precedingHistory) { item in
                                VStack(spacing: 3) {
                                    if state.mode != "zh" { Text(item.original) }
                                    if state.mode != "original" && !item.translated.isEmpty { Text(item.translated) }
                                }.font(.system(size: max(14, state.fontSize - 5))).foregroundStyle(.secondary.opacity(0.7))
                            }
                            VStack(spacing: 3) {
                                if state.original.isEmpty {
                                    Text("等待语音").font(.system(size: 15)).foregroundStyle(.secondary)
                                } else {
                                    if state.mode != "zh" { Text(visibleOriginal).font(.system(size: state.fontSize, weight: .medium)).foregroundStyle(.primary) }
                                    if state.mode != "original" && !visibleTranslation.isEmpty { Text(visibleTranslation).font(.system(size: state.fontSize - 2)).foregroundStyle(.secondary) }
                                }
                                #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
                                if !state.experimentalAttribution.isEmpty {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("实验：匿名归属（已确认片段）").font(.system(size: 10)).foregroundStyle(.secondary)
                                        ForEach(Array(state.experimentalAttribution.enumerated()), id: \.offset) { _, line in
                                            Text(line).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                #endif
                            }.id("current-caption")
                        }.frame(maxWidth: .infinity, minHeight: 58).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center).textSelection(.enabled)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    // Do not re-anchor on every partial word or translation revision.
                    // A completed sentence may advance only while the reader is following live.
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.visibleRect.maxY < 28
                    } action: { _, nearBottom in
                        if userIsScrollingCaptions { followingLiveCaption = nearBottom }
                    }
                    // A long live sentence can wrap beyond the available space.
                    // Follow only after roughly a new line has appeared, rather
                    // than moving the viewport for every incoming character.
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                        guard followingLiveCaption, !userIsScrollingCaptions else { return }
                        if height < lastFollowedContentHeight { lastFollowedContentHeight = height }
                        guard height - lastFollowedContentHeight >= 28 else { return }
                        lastFollowedContentHeight = height
                        Task { @MainActor in
                            await Task.yield()
                            if reduceMotion { scroll.scrollTo("current-caption", anchor: .bottom) }
                            else { withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("current-caption", anchor: .bottom) } }
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { userIsScrollingCaptions = true; followingLiveCaption = false }
                        else if phase == .idle { userIsScrollingCaptions = false }
                    }
                    .onChange(of: state.segmentID) { _, _ in
                        guard followingLiveCaption else { return }
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("current-caption", anchor: .bottom) }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followingLiveCaption {
                            Button {
                                followingLiveCaption = true
                                withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("current-caption", anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold))
                                    .padding(8).background(.regularMaterial, in: Circle())
                            }.buttonStyle(.plain).help("回到实时字幕").accessibilityLabel("回到实时字幕")
                        }
                    }
                }
            }
            Spacer(minLength: 6)
        }.padding(.horizontal, 18).padding(.vertical, 12).frame(width: 620, height: embeddedTrack ? 146 : 196)
            .background {
                if !embeddedTrack { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial) }
            }
            .overlay {
                if !embeddedTrack { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5) }
            }
        .onChange(of: state.revision) { _, _ in scheduleTranslation() }
        .task(id: state.original) { await reveal(state.original, into: $visibleOriginal) }
        .task(id: state.translated) { await reveal(state.translated, into: $visibleTranslation) }
        .onChange(of: state.sourceLanguage) { _, value in changeLanguage(value); restartTranslation() }
        .onChange(of: state.targetLanguage) { _, value in changeTargetLanguage?(value); restartTranslation() }
        .onDisappear { debounce?.cancel(); debounce = nil }
        .translationTask(configuration) { session in
            guard !state.managedSpeech else { return }
            let source = translationSource, language = translationLanguage, target = translationTargetLanguage, segment = translationSegment, request = translationRequestID
            var completed = false
            defer {
                if request == translationRequestID {
                    translationInFlight = false
                    if completed, state.mode != "original",
                       (state.original != source || state.segmentID != segment || state.history.contains(where: { $0.sourceLanguage == state.sourceLanguage && $0.targetLanguage == state.targetLanguage && $0.translated.isEmpty })) { scheduleTranslation() }
                }
            }
            guard state.mode != "original", !source.isEmpty else { return }
            do { let result = try await session.translate(source); guard !Task.isCancelled, request == translationRequestID, state.sourceLanguage == language, state.targetLanguage == target, !result.targetText.isEmpty else { return }; state.acceptTranslation(result.targetText, forOriginal: source, segment: segment, target: target); completed = true }
            catch { guard !Task.isCancelled, request == translationRequestID, state.targetLanguage == target, state.segmentID == segment, state.original.hasPrefix(source) else { return }; state.status = "翻译不可用，请检查系统翻译语言包。" }
        }
    }
    @MainActor private func reveal(_ target: String, into value: Binding<String>) async {
        guard !Task.isCancelled else { return }
        guard !target.isEmpty else { value.wrappedValue = ""; return }
        let current = Array(value.wrappedValue), next = Array(target)
        let shared = zip(current, next).prefix { $0 == $1 }.count
        // Recognition/translation may revise a word in the middle. Replace the
        // correction in one update instead of erasing and retyping its suffix.
        if shared < current.count || reduceMotion { value.wrappedValue = target; return }
        var position = shared
        let backlog = next.count - position
        let step = backlog <= 18 ? 1 : (backlog + 7) / 8
        while position < next.count && !Task.isCancelled {
            // Bound catch-up time when recognition delivers a long chunk. Short
            // partials still appear character by character, while a backlog
            // takes at most eight ticks instead of lagging behind the speaker.
            position = min(position + step, next.count)
            value.wrappedValue = String(next.prefix(position))
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    private func restartTranslation() {
        debounce?.cancel(); debounce = nil; translationRequestID = UUID(); translationInFlight = false; configuration = nil
        if state.isCapturing && state.status == "语音与翻译语言相同，请选择不同语言。" { state.status = "正在聆听\(state.audioSource.label)" }
        scheduleTranslation()
    }
    private func scheduleTranslation() {
        guard !state.managedSpeech else { return }
        guard state.mode != "original", !state.original.isEmpty else { return }
        if state.sourceLanguage.prefix(2).lowercased() == state.targetLanguage.prefix(2).lowercased() {
            state.clearTranslation(); state.status = "语音与翻译语言相同，请选择不同语言。"; return
        }
        guard debounce == nil, !translationInFlight else { return }
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, state.mode != "original", !state.original.isEmpty else { debounce = nil; return }
            let language = state.sourceLanguage, targetID = state.targetLanguage
            let source = Locale.Language(identifier: language), target = Locale.Language(identifier: targetID)
            let available = await LanguageAvailability().status(from: source, to: target)
            debounce = nil
            guard !Task.isCancelled, state.sourceLanguage == language, state.targetLanguage == targetID, state.mode != "original" else { return }
            switch available {
            case .installed:
                let pending = state.history.first(where: { $0.sourceLanguage == language && $0.targetLanguage == targetID && $0.translated.isEmpty })
                translationSource = pending?.original ?? state.translationSnapshot
                guard !translationSource.isEmpty else { scheduleTranslation(); return }
                translationLanguage = language
                translationTargetLanguage = targetID
                translationSegment = pending?.id ?? state.segmentID
                translationRequestID = UUID()
                translationInFlight = true
                if configuration == nil { configuration = TranslationSession.Configuration(source: source, target: target) }
                else { configuration?.source = source; configuration?.target = target; configuration?.invalidate() }
            case .supported: state.status = "请在系统设置中下载对应翻译语言包。"
            case .unsupported: state.status = "系统不支持此语言组合。"
            @unknown default: configuration = nil; state.status = "无法检查翻译语言包。"
            }
        }
    }
}

/// A user-initiated, transient capability check. It retains no audio or video.
enum CaptionAudioProbeResult { case audioObserved, silent, failed }
enum CaptionAudioAuthorizationDecision: Equatable { case confirmed, previouslyVerifiedSilent, needsAudio, unavailable }
enum CaptionAudioAuthorizationPolicy {
    static func decide(previouslyVerified: Bool, screenAllowed: Bool, result: CaptionAudioProbeResult) -> CaptionAudioAuthorizationDecision {
        guard screenAllowed else { return .unavailable }
        switch result {
        case .audioObserved: return .confirmed
        case .silent: return previouslyVerified ? .previouslyVerifiedSilent : .needsAudio
        case .failed: return .unavailable
        }
    }
}

@MainActor enum CaptionAudioPermissionProbe {
    private static let verifiedKey = "moriq.captionAudioPreviouslyVerified"
    static var previouslyVerified: Bool {
        get { UserDefaults.standard.bool(forKey: verifiedKey) }
        set { UserDefaults.standard.set(newValue, forKey: verifiedKey) }
    }
    static var verifiedThisLaunch = false
    private final class Discard: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var received = false
        private var stopped = false
        var hasAudio: Bool { lock.lock(); defer { lock.unlock() }; return received }
        var hasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stream(_ stream: SCStream, didStopWithError error: Error) { lock.lock(); stopped = true; lock.unlock() }
        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, sample.isValid, CMSampleBufferGetNumSamples(sample) > 0 else { return }
            lock.lock(); received = true; lock.unlock()
        }
    }
    static func verify(timeout: TimeInterval = 4) async throws -> CaptionAudioProbeResult {
        guard CGPreflightScreenCaptureAccess() else { throw ProbeError.unavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ProbeError.unavailable }
        let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        let sink = Discard(), stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.moriq.captions.permission-probe"))
        try await stream.startCapture()
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while !sink.hasAudio && !sink.hasStopped && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        guard !sink.hasStopped else { throw ProbeError.unavailable }
        return sink.hasAudio ? .audioObserved : .silent
    }
    private enum ProbeError: Error { case unavailable }
}
