import AppKit
import CoreGraphics
import CoreMedia
import AVFoundation
import ScreenCaptureKit
import Speech
import SwiftUI
import Translation
import Combine

enum CaptionAudioSource: String, CaseIterable {
    case system
    var label: String { "系统声音" }
    func accepts(_ type: SCStreamOutputType) -> Bool { type == .audio }
}

enum CaptionSessionMode: String { case captions }

/// A signed bundle must explicitly opt in to the known atomic protocol.
/// No runtime environment variable or unknown config enables product traffic.
enum CaptionNativeProductPolicy {
    static func enabled(config: Any?) -> Bool { (config as? String) == "batch-v1" }
}

#if MORIQ_NATIVE_TRANSLATION_PRODUCT
private struct CaptionReviewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
enum CaptionReviewLayoutPolicy {
    static let maximumContentHeight: CGFloat = 180
    static func contentHeight(_ measured: CGFloat) -> CGFloat { min(maximumContentHeight, max(1, ceil(measured))) }
    static func panelHeight(expanded: Bool, measured: CGFloat, available: CGFloat) -> CGFloat {
        min(available, 196 + (expanded ? contentHeight(measured) : 0))
    }
}
#endif

enum CaptionCaptureFailurePolicy {
    static func status(source: String, permitted: Bool) -> (message: String, canRetry: Bool) {
        permitted ? ("\(source)已意外停止，部分声音可能遗漏；请重试。", true)
                  : ("屏幕与系统音频权限已撤销，字幕已停止。", false)
    }
}

enum ManagedSpeechRecoveryDecision: Equatable { case ignore, permissionsLost, startupFailed, retry, stopAfterRetry }
enum ManagedSpeechRecoveryPolicy {
    static func decide(current: Bool, capturing: Bool, permission: Bool, consent: Bool, attempts: Int) -> ManagedSpeechRecoveryDecision {
        guard current else { return .ignore }
        guard permission && consent else { return .permissionsLost }
        guard capturing else { return .startupFailed }
        return attempts == 0 ? .retry : .stopAfterRetry
    }
}

enum ManagedSpeechEventFence {
    static func permits(generation: UUID, setup: UUID, currentGeneration: UUID, currentSetup: UUID, sameModel: Bool, cancelled: Bool) -> Bool {
        !cancelled && sameModel && generation == currentGeneration && setup == currentSetup
    }
}

struct CaptionHistoryEntry: Identifiable {
    let id: UUID
    let original: String
    var sourceLanguage: String
    var targetLanguage: String
    var translated: String
    var isNotice = false
    var isIncomplete = false
    /// An ambiguous provider label must not be translated as the user's
    /// selected language later by the history catch-up queue.
    var languageEvidenceBlocked = false
}

/// Provider labels are hints, not a reason to silently switch languages.
enum CaptionLanguageEvidence {
    enum Decision { case absent, agrees, uncertain }
    static func decide(labels: [String]?, selected: String) -> Decision {
        guard let labels, !labels.isEmpty else { return .absent }
        func base(_ value: String) -> String {
            value.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
        }
        let accepted = Set(["en", "zh", "ja", "ko"])
        let selectedBase = base(selected)
        let observed = Set(labels.map(base))
        guard accepted.contains(selectedBase), observed.count == 1,
              let only = observed.first, accepted.contains(only), only == selectedBase else { return .uncertain }
        return .agrees
    }
}

/// Compare only pairs whose writing system is known. In particular, an
/// English locale change is the same language, while Simplified and
/// Traditional Chinese must not be treated as interchangeable.
enum CaptionLanguagePair {
    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    static func isSame(_ source: String, _ target: String) -> Bool {
        let source = normalized(source), target = normalized(target)
        guard !source.isEmpty, !target.isEmpty else { return false }
        if source == target { return true }
        let sourceParts = source.split(separator: "-").map(String.init)
        let targetParts = target.split(separator: "-").map(String.init)
        guard sourceParts.first == targetParts.first else { return false }
        if sourceParts.first != "zh" { return true }
        // zh-HK may be Cantonese rather than Mandarin; sharing Traditional
        // characters alone is not proof that translation can be skipped.
        if sourceParts.contains("hk") || targetParts.contains("hk") { return false }
        func chineseScript(_ parts: [String]) -> String? {
            if parts.contains("hans") || parts.contains("cn") || parts.contains("sg") { return "hans" }
            if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo") { return "hant" }
            return nil
        }
        guard let sourceScript = chineseScript(sourceParts), let targetScript = chineseScript(targetParts) else { return false }
        return sourceScript == targetScript
    }
}

enum CaptionHistoryVisibility {
    static func lines(_ item: CaptionHistoryEntry, mode: String) -> [String] {
        if item.isIncomplete { return [item.original + "（未完成）"] }
        if item.isNotice || item.languageEvidenceBlocked { return [item.original] }
        if CaptionLanguagePair.isSame(item.sourceLanguage, item.targetLanguage) { return [item.original] }
        var lines: [String] = []
        if mode != "zh" { lines.append(item.original) }
        if mode != "original" && !item.translated.isEmpty { lines.append(item.translated) }
        return lines
    }
}

/// Current subtitle and bounded history exist only in memory for this session.
@MainActor final class LiveCaptionState: ObservableObject {
    @Published private(set) var original = ""
    /// Ephemeral and unanchored: never part of transcript or translation.
    @Published private(set) var unanchoredPreview = ""
    @Published private(set) var translated = ""
    @Published private(set) var revision = UUID()
    @Published private(set) var segmentID = UUID()
    @Published var status = "准备中"
    @Published var mode = "bilingual" { didSet { if mode != oldValue {
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        invalidateExperimentalPreviewRequest()
        #endif
        translationContext = UUID(); if usesLocalTranslation { translated = "" }; revision = UUID()
    } } }
    @Published var sourceLanguage = "en-US" {
        didSet { if sourceLanguage != oldValue {
            #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
            experimentalAutomaticText = ""; experimentalAutomaticFailure = false
            #endif
            #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
            archiveNativeCaption()
            #endif
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            invalidateExperimentalContext()
            experimentalEligible.removeAll(); experimentalErrors.removeAll()
            #endif
            translationContext = UUID(); translated = ""; translatedForOriginal = ""; revision = UUID()
        } }
    }
    @Published var targetLanguage = "zh-Hans" {
        didSet { if targetLanguage != oldValue {
            #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
            experimentalAutomaticText = ""; experimentalAutomaticFailure = false
            #endif
            #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
            archiveNativeCaption()
            #endif
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            invalidateExperimentalContext()
            #endif
            translationContext = UUID(); translated = ""; translatedForOriginal = ""; revision = UUID()
        } }
    }
    @Published var audioSource: CaptionAudioSource = .system
    @Published var fontSize: Double = 23
    @Published var captionWindowAvailable: CGFloat = 900
    @Published var captionReviewAvailable: CGFloat = 0
    @Published var showHistory = false
    @Published var isCapturing = false
    @Published var needsSpeechModel = false
    /// Independent provider streams are intentionally not paired into history.
    @Published var managedSpeech = false { didSet { if !managedSpeech { clearUnanchoredPreview() } } }
    @Published var managedSpeechProvidesTranslation = true
    var usesLocalTranslation: Bool { !managedSpeech || !managedSpeechProvidesTranslation }
    #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
    struct NativeHistoryEpoch: Identifiable {
        let id = UUID()
        let sourceLanguage: String
        let targetLanguage: String
        let original: String
        let translation: String
        var isNotice = false
    }
    @Published private(set) var nativeActive = false
    #if MORIQ_NATIVE_TRANSLATION_PRODUCT
    @Published var reviewSource: CaptionReviewSourceUnit? { didSet { if reviewSource == nil { reviewPanelExpanded = false } } }
    @Published var sourceReviewStatus = ""
    @Published var reviewPanelExpanded = false
    @Published var reviewContentHeight: CGFloat = 80
    #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
    @Published var experimentalAutomaticMode = false
    @Published var experimentalAutomaticText = ""
    @Published var experimentalAutomaticFailure = false
    #endif
    func failPunctReview() {
        reviewSource = nil; reviewPanelExpanded = false
        sourceReviewStatus = "字幕连接中断，校订不可用"
        #if MORIQ_AUTO_TRANSLATION_PRODUCT
        experimentalAutomaticFailure = true
        #endif
    }
    func disablePunctReview() {
        reviewSource=nil; reviewPanelExpanded=false
        sourceReviewStatus="当前字幕模式暂不支持校订"
    }
    func closePunctReview() {
        reviewSource = nil; reviewPanelExpanded = false
        sourceReviewStatus = "字幕已结束，校订不可用"
    }
    func publishPunctReview(_ reducer: SourceV2Verifier) {
        if let marker = reducer.acceptedMarkers.last { reviewSource = CaptionReviewSourceUnit.fromValidated(marker) }
    }
    func acceptSourceReviewBatch(_ event: ManagedSpeechEvent, reducer: inout SourceV2Verifier) {
        if let seq = event.batchSeq, !event.sourceUnitsUnavailable, let units = event.sourceMarkersRaw {
            reducer.commitBatch(seq, confirmed: nativeOriginal.confirmed)
            for unit in units { reducer.marker(Data(unit.utf8)) }
        } else { reducer.disable() }
        if reducer.reviewEnabled {
            if let marker = reducer.acceptedMarkers.last { reviewSource = CaptionReviewSourceUnit.fromValidated(marker) }
        } else { reviewSource = nil; sourceReviewStatus = "校订暂不可用，字幕继续" }
    }
    #endif
    #if DEBUG && MORIQ_SOURCE_UNITS_V2_EXPERIMENTAL
    @Published var debugSourceReviewStatus = "校订模拟：未连接"
    #endif
    @Published private(set) var nativePresentationSelected = false
    private struct NativeLanes { var original = CaptionLanePages(); var translation = CaptionLanePages() }
    @Published private var nativeLanes = NativeLanes()
    private(set) var nativeOriginal: CaptionLanePages {
        get { nativeLanes.original }
        set { nativeLanes.original = newValue }
    }
    private(set) var nativeTranslation: CaptionLanePages {
        get { nativeLanes.translation }
        set { nativeLanes.translation = newValue }
    }
    @Published private(set) var nativeHistory: [NativeHistoryEpoch] = []
    private var nativeOriginalRevision: UInt64 = 0
    private var nativeTranslationRevision: UInt64 = 0
    private var nativeConfirmedBytes = 0
    private var nativeArchivedBytes = 0
    private var nativeSourceLanguage = ""
    private var nativeTargetLanguage = ""
    private let nativeMaximumBytes = 512_000
    func beginNativeCaption() {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
        reviewPanelExpanded = false
        #endif
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
        reviewSource = nil; sourceReviewStatus = ""
        #endif
        archiveNativeCaption()
        nativeOriginal.reset(); nativeTranslation.reset()
        nativeOriginalRevision = 0; nativeTranslationRevision = 0
        nativeConfirmedBytes = 0
        nativeSourceLanguage = sourceLanguage; nativeTargetLanguage = targetLanguage
        nativePresentationSelected = true; nativeActive = true
    }
    @discardableResult func acceptNativeCaption(_ update: ManagedNativeLaneUpdate) -> Bool {
        guard nativeActive else { return false }
        let otherDraft = update.lane == .original ? nativeTranslation.provisional : nativeOriginal.provisional
        // Bound the entire session, including prior epochs. Stop visibly rather
        // than quietly discarding early captions or growing memory without limit.
        let nextBytes = nativeArchivedBytes + nativeConfirmedBytes + update.confirmedDelta.utf8.count + update.provisional.utf8.count + otherDraft.utf8.count
        guard nextBytes <= nativeMaximumBytes else { return false }
        switch update.lane {
        case .original:
            nativeOriginalRevision += 1
            guard nativeOriginal.append(confirmedDelta: update.confirmedDelta, provisional: update.provisional,
                                        revision: nativeOriginalRevision) else { return false }
        case .translation:
            nativeTranslationRevision += 1
            guard nativeTranslation.append(confirmedDelta: update.confirmedDelta, provisional: update.provisional,
                                           revision: nativeTranslationRevision) else { return false }
        }
        nativeConfirmedBytes += update.confirmedDelta.utf8.count
        return true
    }
    /// Apply validated provider operations to copies, then publish both lanes once.
    @discardableResult func acceptNativeBatch(_ updates: [ManagedNativeLaneUpdate]) -> Bool {
        guard nativeActive else { return false }
        var staged = nativeLanes
        var originalRevision = nativeOriginalRevision, translationRevision = nativeTranslationRevision
        var added = 0
        for update in updates {
            added += update.confirmedDelta.utf8.count
            switch update.lane {
            case .original:
                originalRevision += 1
                guard staged.original.append(confirmedDelta: update.confirmedDelta, provisional: update.provisional, revision: originalRevision) else { return false }
            case .translation:
                translationRevision += 1
                guard staged.translation.append(confirmedDelta: update.confirmedDelta, provisional: update.provisional, revision: translationRevision) else { return false }
            }
        }
        guard nativeArchivedBytes + nativeConfirmedBytes + added + staged.original.provisional.utf8.count + staged.translation.provisional.utf8.count <= nativeMaximumBytes else { return false }
        nativeOriginalRevision = originalRevision; nativeTranslationRevision = translationRevision
        nativeConfirmedBytes += added
        if !updates.isEmpty { nativeLanes = staged }
        return true
    }
    func resizeNativePages(_ capacity: Int) {
        let bounded = max(8, min(300, capacity))
        if nativeOriginal.pageCapacity != bounded { nativeOriginal.resize(pageCapacity: bounded) }
        if nativeTranslation.pageCapacity != bounded { nativeTranslation.resize(pageCapacity: bounded) }
    }
    func resizeNativePages(width: CGFloat) {
        nativeOriginal.resize(width: width, fontSize: fontSize)
        nativeTranslation.resize(width: width, fontSize: max(12, fontSize - 2))
    }
    func previousNativePage(_ lane: ManagedNativeLane) {
        if lane == .original { nativeOriginal.previous() } else { nativeTranslation.previous() }
    }
    func selectNativePage(_ lane: ManagedNativeLane, index: Int) {
        if lane == .original { nativeOriginal.selectPage(index) } else { nativeTranslation.selectPage(index) }
    }
    func nextNativePage(_ lane: ManagedNativeLane) {
        if lane == .original { nativeOriginal.next() } else { nativeTranslation.next() }
    }
    func followNativePage(_ lane: ManagedNativeLane) {
        if lane == .original { nativeOriginal.resumeFollowing() } else { nativeTranslation.resumeFollowing() }
    }
    private func archiveNativeCaption() {
        guard nativeActive else { return }
        let original = nativeOriginal.confirmed, translation = nativeTranslation.confirmed
        if !original.isEmpty || !translation.isEmpty {
            nativeHistory.append(NativeHistoryEpoch(sourceLanguage: nativeSourceLanguage, targetLanguage: nativeTargetLanguage,
                                                    original: original, translation: translation))
            nativeArchivedBytes += original.utf8.count + translation.utf8.count
        }
        nativeOriginal.discardProvisional(); nativeTranslation.discardProvisional()
        nativeActive = false
    }
    var nativeHistoryForContinuation: [NativeHistoryEpoch] {
        var result = nativeHistory
        if nativeActive && (!nativeOriginal.confirmed.isEmpty || !nativeTranslation.confirmed.isEmpty) {
            result.append(NativeHistoryEpoch(sourceLanguage: nativeSourceLanguage, targetLanguage: nativeTargetLanguage,
                                             original: nativeOriginal.confirmed, translation: nativeTranslation.confirmed))
        }
        return result
    }
    func restoreNativeHistory(_ entries: [NativeHistoryEpoch]) {
        nativeHistory = entries
        nativeArchivedBytes = entries.reduce(0) { $0 + $1.original.utf8.count + $1.translation.utf8.count }
        if !entries.isEmpty { nativePresentationSelected = true }
    }
    /// Keep confirmed content in the live viewport across transport epochs.
    /// Notices stay in history; they do not become provider transcript text.
    /// Never mix a previous language pair into the new live presentation.
    func nativeDisplayText(_ lane: ManagedNativeLane) -> String {
        let samePair = nativeSourceLanguage == sourceLanguage && nativeTargetLanguage == targetLanguage
        #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
        if experimentalAutomaticMode && lane == .translation { return experimentalAutomaticText }
        #endif
        let current = samePair ? (lane == .original ? nativeOriginal.text : nativeTranslation.text) : ""
        if !nativeActive && !current.isEmpty { return current }
        var epochs: [String] = []
        for entry in nativeHistory.reversed() {
            if entry.isNotice { continue }
            guard entry.sourceLanguage == sourceLanguage && entry.targetLanguage == targetLanguage else { break }
            let text = lane == .original ? entry.original : entry.translation
            if !text.isEmpty { epochs.append(text) }
        }
        let previous = epochs.reversed().joined(separator: "\n")
        if previous.isEmpty { return current }
        if current.isEmpty { return previous }
        return previous + "\n" + current
    }
    func disableNativePresentation() { archiveNativeCaption(); nativePresentationSelected = false }
    #endif
    @Published private(set) var history: [CaptionHistoryEntry] = []
    /// Invalidates asynchronous translations when mode, languages or the
    /// current session change, even if the user later switches back.
    private(set) var translationContext = UUID()
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
    private(set) var managedConfirmedPrefix = ""
    private(set) var managedProvisionalTail = ""
    private var managedUsesConfirmedDeltas = false
    private(set) var languageEvidenceBlocked = false
    #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
    var experimentalAutomaticLanguage: Bool {
        sourceLanguage == "auto" && ProcessInfo.processInfo.environment["MORIQ_AUTO_LANGUAGE_EXPERIMENTAL"] == "1"
    }
    @Published private(set) var experimentalPreviewTranslation = ""
    private(set) var experimentalPreviewInput = ""
    private(set) var experimentalPreviewContext = UUID()
    private var experimentalPreviewRequestInput = ""
    func beginExperimentalPreview(source: String) -> UUID {
        experimentalPreviewContext = UUID(); experimentalPreviewRequestInput = source
        return experimentalPreviewContext
    }
    private func previewPrefixMatches(_ prefix: String, in text: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        let end = text.index(text.startIndex, offsetBy: prefix.count)
        if let last = prefix.last, last.isASCII && last.isLetter, end < text.endIndex {
            let next = text[end]
            if next.isASCII && (next.isLetter || next.isNumber) { return false }
        }
        return true
    }
    func experimentalPreviewIsCurrent(source: String, language: String, segment: UUID, target: String, context: UUID) -> Bool {
        guard context == experimentalPreviewContext, source == experimentalPreviewRequestInput,
              segment == segmentID, target == targetLanguage,
              let candidate = experimentalPreviewCandidate(), candidate.language == language else { return false }
        return previewPrefixMatches(source, in: candidate.text)
    }
    private func invalidateExperimentalPreviewRequest() { experimentalPreviewContext = UUID(); experimentalPreviewRequestInput = "" }
    // Monotonic clock is injectable for deterministic stability tests.
    var experimentalPreviewClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private struct ProvisionalObservation {
        let character: Character
        let firstSeen: TimeInterval
        let observations: Int
    }
    private var experimentalProvisionalSegment: Int?
    private var experimentalProvisional: [ProvisionalObservation] = []
    private func observeProvisional(_ tail: String, segment: Int) {
        if experimentalProvisionalSegment != segment { experimentalProvisionalSegment = segment; experimentalProvisional.removeAll() }
        let now = experimentalPreviewClock()
        let characters = Array(tail.prefix(4_000))
        let shared = zip(experimentalProvisional, characters).prefix { $0.character == $1 }.count
        var next: [ProvisionalObservation] = []
        next.reserveCapacity(characters.count)
        for index in characters.indices {
            if index < shared {
                let old = experimentalProvisional[index]
                next.append(ProvisionalObservation(character: old.character, firstSeen: old.firstSeen, observations: min(2, old.observations + 1)))
            } else { next.append(ProvisionalObservation(character: characters[index], firstSeen: now, observations: 1)) }
        }
        experimentalProvisional = next
    }
    private func resetProvisionalObservations() { experimentalProvisionalSegment = nil; experimentalProvisional.removeAll() }
    /// A candidate only: scores are uncalibrated, so this remains a labelled
    /// preview and is never written to caption history.
    func experimentalPreviewCandidate() -> (text: String, language: String)? {
        guard managedUsesConfirmedDeltas, !segmentFinalized, usesLocalTranslation,
              ProcessInfo.processInfo.environment["MORIQ_CAPTION_CONFIRMED_DELTA_V1"] == "1",
              let detector = experimentalTextLanguageDetector else { return nil }
        // Even the volatile suffix may reveal a language switch. Do not
        // present a monolingual guess while the live hypothesis is mixed.
        guard CaptionLanguageResolver.permitsDetectorText(managedConfirmedPrefix + managedProvisionalTail) else { return nil }
        let now = experimentalPreviewClock()
        let stableTail = String(experimentalProvisional.prefix { $0.observations >= 2 && now - $0.firstSeen >= 0.6 }.map(\.character))
        let safeInput = managedConfirmedPrefix + stableTail
        var text = safeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid guessing an unfinished Latin word at the token boundary.
        if let last = safeInput.last, last.isASCII && last.isLetter {
            guard let lastBoundary = text.lastIndex(where: { $0.isWhitespace || $0.isPunctuation }) else { return nil }
            text = String(text[...lastBoundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let resolution = CaptionLanguageResolver(detector: detector).resolve(selection: .automatic, text: text, isFinal: true, providerLabels: nil)
        guard case .candidate(let language, _) = resolution,
              sourceLanguage == "auto" || sourceLanguage.lowercased().split(separator: "-").first.map(String.init) == language,
              !CaptionLanguagePair.isSame(language, targetLanguage) else { return nil }
        return (text, language)
    }
    func acceptExperimentalPreview(_ text: String, source: String, language: String, segment: UUID, target: String, context: UUID) {
        guard experimentalPreviewIsCurrent(source: source, language: language, segment: segment, target: target, context: context), !text.isEmpty else { return }
        experimentalPreviewInput = source; experimentalPreviewTranslation = text
    }
    private func clearExperimentalPreview() { experimentalPreviewTranslation = ""; experimentalPreviewInput = ""; invalidateExperimentalPreviewRequest() }
    private var experimentalResolvedSource: String?
    private struct PendingExperimentalSentence {
        let id: UUID
        let text: String
        let labels: [String]
        let target: String
        let epoch: UUID
        let sequence: Int
    }
    private var experimentalEpoch = UUID()
    private var experimentalSequence = 0
    private var experimentalEligible: Set<UUID> = []
    @Published private(set) var experimentalErrors: [UUID: String] = [:]
    func experimentalCanSelectLanguage(_ id: UUID) -> Bool {
        experimentalAutomaticLanguage && experimentalEligible.contains(id)
    }
    func experimentalTranslationFailed(segment: UUID, target: String, context: UUID, message: String) {
        guard experimentalCanSelectLanguage(segment), context == translationContext, target == targetLanguage,
              history.contains(where: { $0.id == segment && $0.targetLanguage == target }) else { return }
        experimentalErrors[segment] = message; revision = UUID()
    }
    private var experimentalPending: [PendingExperimentalSentence] = []
    // The default exists only in the experimental compile; callers may inject
    // a different detector. Weak or unavailable evidence preserves text.
    var experimentalTextLanguageDetector: CaptionLanguageResolver.TextDetector? = CaptionNaturalLanguageDetector.detect
    private func invalidateExperimentalContext() {
        experimentalEpoch = UUID(); experimentalSequence = 0
        experimentalPending.removeAll(); experimentalResolvedSource = nil; clearExperimentalPreview(); resetProvisionalObservations()
    }
    private func recoverExperimentalContext(nextText: String, labels: [String]?) {
        guard let detector = experimentalTextLanguageDetector, let labels, !labels.isEmpty else {
            experimentalPending.removeAll { experimentalSequence - $0.sequence >= 2 }
            return
        }
        let resolver = CaptionLanguageResolver(detector: detector)
        experimentalPending.removeAll { candidate in
            let age = experimentalSequence - candidate.sequence
            guard candidate.epoch == experimentalEpoch, candidate.target == targetLanguage,
                  age > 0, age <= 2,
                  let index = history.firstIndex(where: { $0.id == candidate.id && $0.original == candidate.text && $0.sourceLanguage == "auto" && $0.languageEvidenceBlocked }) else { return true }
            // Require labels for both finalized sentences, plus a strong text
            // detector result that agrees with both. Context is never translated
            // in place of the pending sentence.
            let combined = String((candidate.text + " " + nextText).prefix(512))
            let result = resolver.resolve(selection: .automatic, text: combined, isFinal: true, providerLabels: candidate.labels + labels)
            if case .candidate(let language, _) = result {
                history[index].sourceLanguage = language
                history[index].languageEvidenceBlocked = false
                revision = UUID()
                return true
            }
            switch result {
            case .unresolved(.mixed), .unresolved(.conflictingEvidence), .unresolved(.malformedEvidence), .unsupported:
                return true // Never bridge a known language boundary.
            default:
                return age >= 2
            }
        }
    }
    func nextExperimentalTranslation(target: String) -> CaptionHistoryEntry? {
        guard experimentalAutomaticLanguage else { return nil }
        return history.first { !$0.isNotice && !$0.languageEvidenceBlocked && $0.sourceLanguage != "auto" && $0.targetLanguage == target && $0.translated.isEmpty && experimentalErrors[$0.id] == nil && !CaptionLanguagePair.isSame($0.sourceLanguage, target) }
    }
    func recoverExperimentalLanguage(segment: UUID, language: String) {
        guard experimentalAutomaticLanguage, ["en-US", "zh-CN", "ja-JP", "ko-KR"].contains(language),
              experimentalCanSelectLanguage(segment),
              let index = history.firstIndex(where: { $0.id == segment && !$0.isNotice }) else { return }
        history[index].sourceLanguage = language
        history[index].targetLanguage = targetLanguage
        history[index].translated = ""
        history[index].languageEvidenceBlocked = false
        experimentalPending.removeAll { $0.id == segment }
        experimentalErrors.removeValue(forKey: segment)
        if status == "此句语言未确认，原文已保留；可选择语言后重试。" {
            status = isCapturing ? "正在聆听\(audioSource.label)" : "准备中"
        }
        if segment == segmentID { languageEvidenceBlocked = false; translated = ""; translatedForOriginal = "" }
        translationContext = UUID(); revision = UUID()
    }
    #endif
    private var historySourceLanguage: String {
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        if experimentalAutomaticLanguage { return experimentalResolvedSource ?? "auto" }
        #endif
        return sourceLanguage
    }
    private static let languageEvidenceWarning = "此句语言可能与所选语言不一致，请核对后再翻译。"
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
            history.append(CaptionHistoryEntry(id: segmentID, original: bounded, sourceLanguage: historySourceLanguage, targetLanguage: targetLanguage, translated: translatedForOriginal == bounded ? translated : "", languageEvidenceBlocked: languageEvidenceBlocked))
            if history.count > 30 { history.removeFirst(history.count - 30) }
        }
        if final && !bounded.isEmpty && !segmentFinalized { segmentFinalized = true; revision = UUID() }
    }
    func acceptTranslation(_ text: String, revision: UUID) {
        guard revision == self.revision else { return }
        acceptTranslation(text, forOriginal: original)
    }
    func clearTranslation() { translated = ""; translatedForOriginal = "" }
    func acceptUnanchoredPreview(_ text: String?) {
        guard managedSpeech else { return }
        let bounded = String((text ?? "").suffix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        if unanchoredPreview != bounded { unanchoredPreview = bounded }
    }
    func clearUnanchoredPreview() { unanchoredPreview = "" }
    func acceptManagedTranslation(_ text: String) {
        guard managedSpeech else { return }
        translated = String(text.suffix(4_000))
        translatedForOriginal = ""
    }
    func acceptManagedDelta(confirmed: String, provisional: String, segment: Int, final: Bool, languageLabels: [String]? = nil) {
        guard managedSpeech, segment >= 0, !final || provisional.isEmpty else { return }
        translationContext = UUID()
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        let visibleSource = (confirmed + provisional).trimmingCharacters(in: .whitespacesAndNewlines)
        if final || (managedSourceSegment != nil && managedSourceSegment != segment) ||
            (!experimentalPreviewInput.isEmpty && (!previewPrefixMatches(experimentalPreviewInput, in: visibleSource) || !CaptionLanguageResolver.permitsDetectorText(visibleSource))) { clearExperimentalPreview() }
        if !experimentalPreviewRequestInput.isEmpty && (!previewPrefixMatches(experimentalPreviewRequestInput, in: visibleSource) || !CaptionLanguageResolver.permitsDetectorText(visibleSource)) { invalidateExperimentalPreviewRequest() }
        if final { resetProvisionalObservations() } else { observeProvisional(provisional, segment: segment) }
        #endif
        if final && managedUsesConfirmedDeltas { languageEvidenceBlocked = false }
        acceptManagedSource(confirmed + provisional, segment: segment, final: final, languageLabels: languageLabels)
        managedUsesConfirmedDeltas = !final
        managedConfirmedPrefix = final ? "" : confirmed
        managedProvisionalTail = final ? "" : provisional
        // Provider provisional text can change. Do not submit it to translation
        // or put it into formal history as a confirmed sentence.
        if !final { languageEvidenceBlocked = true; revision = UUID() }
    }
    func acceptManagedSource(_ text: String, segment: Int, final: Bool, languageLabels: [String]? = nil) {
        guard managedSpeech, segment >= 0 else { return }
        if managedSourceSegment != segment {
            managedSourceSegment = segment; segmentID = UUID(); segmentFinalized = false
            original = ""; stableTranslationText = ""; translatedForOriginal = ""
            languageEvidenceBlocked = false
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            experimentalResolvedSource = nil
            if experimentalAutomaticLanguage { languageEvidenceBlocked = true }
            #endif
            if status == Self.languageEvidenceWarning { status = isCapturing ? "正在聆听\(audioSource.label)" : "准备中" }
            if usesLocalTranslation { translated = "" }
        }
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        if experimentalAutomaticLanguage && usesLocalTranslation {
            if final && history.last?.id == segmentID { return }
            var shouldQueueShortSentence = false
            if final {
                experimentalSequence += 1
                recoverExperimentalContext(nextText: text, labels: languageLabels)
                switch CaptionLanguageResolver(detector: experimentalTextLanguageDetector).resolve(selection: .automatic, text: text, isFinal: true, providerLabels: languageLabels) {
                case .candidate(let language, _):
                    experimentalResolvedSource = language
                    languageEvidenceBlocked = false
                case .unresolved(.insufficientText):
                    experimentalResolvedSource = nil
                    languageEvidenceBlocked = true
                    shouldQueueShortSentence = languageLabels?.isEmpty == false && experimentalTextLanguageDetector != nil
                    status = "此句语言未确认，原文已保留；可选择语言后重试。"
                default:
                    experimentalResolvedSource = nil
                    languageEvidenceBlocked = true
                    status = "此句语言未确认，原文已保留；可选择语言后重试。"
                }
                translationContext = UUID(); translated = ""; translatedForOriginal = ""
            }
            accept(text, final: final)
            if final, history.last?.id == segmentID { experimentalEligible.insert(segmentID) }
            if shouldQueueShortSentence, let labels = languageLabels,
               let entry = history.last, entry.id == segmentID {
                experimentalPending.append(PendingExperimentalSentence(id: entry.id, text: entry.original, labels: labels, target: targetLanguage, epoch: experimentalEpoch, sequence: experimentalSequence))
                if experimentalPending.count > 2 { experimentalPending.removeFirst(experimentalPending.count - 2) }
            }
            return
        }
        #endif
        if final && usesLocalTranslation && CaptionLanguageEvidence.decide(labels: languageLabels, selected: sourceLanguage) == .uncertain {
            // Invalidate any translation already in flight. A label is not
            // authoritative, so warn and preserve text instead of switching.
            languageEvidenceBlocked = true; translationContext = UUID()
            translated = ""; translatedForOriginal = ""; status = Self.languageEvidenceWarning
        }
        accept(text, final: final)
    }
    func acceptTranslation(_ text: String, forOriginal source: String) {
        acceptTranslation(text, forOriginal: source, segment: segmentID)
    }
    func acceptTranslation(_ text: String, forOriginal source: String, segment: UUID, target: String? = nil, context: UUID? = nil) {
        guard context == nil || context == translationContext else { return }
        let target = target ?? targetLanguage
        if let index = history.indices.last(where: { index in
            let item = history[index]
            return item.id == segment && item.original == source && item.targetLanguage == target && !item.languageEvidenceBlocked
        }) { history[index].translated = text }
        guard !languageEvidenceBlocked, target == targetLanguage, segment == segmentID, !source.isEmpty, original.hasPrefix(source) else { return }
        if original.hasPrefix(translatedForOriginal), !translatedForOriginal.isEmpty,
           source.count < translatedForOriginal.count { return }
        translated = text
        translatedForOriginal = source
    }
    func clearCurrent() {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        archiveNativeCaption()
        #endif
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        invalidateExperimentalContext()
        experimentalEligible.removeAll(); experimentalErrors.removeAll()
        #endif
        clearUnanchoredPreview(); translationContext = UUID(); original = ""; translated = ""; translatedForOriginal = ""; stableTranslationText = ""; managedSourceSegment = nil; managedUsesConfirmedDeltas = false; managedConfirmedPrefix = ""; managedProvisionalTail = ""; languageEvidenceBlocked = false; lastRecognitionUpdate = .distantPast; segmentFinalized = false; segmentID = UUID(); revision = UUID()
        #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
        clearExperimentalAttribution()
        #endif
    }
    func restoreHistory(_ entries: [CaptionHistoryEntry]) { history = Array(entries.suffix(30)) }
    /// History already contains only finalized provider results (and notices).
    /// Never promote the current hypothesis merely because the connection ends.
    var confirmedHistoryForContinuation: [CaptionHistoryEntry] {
        var result = history
        let prefix = managedConfirmedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if managedUsesConfirmedDeltas && !segmentFinalized && !prefix.isEmpty && !result.contains(where: { $0.id == segmentID }) {
            result.append(CaptionHistoryEntry(id: segmentID, original: prefix, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, translated: "", isIncomplete: true, languageEvidenceBlocked: true))
        }
        return Array(result.suffix(30))
    }
    /// A transport gap is not a transcript: keep it visible in every mode.
    func markManagedConnectionGap(_ notice: String = "连接中断，部分声音可能遗漏") {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        let nativeWasActive = nativeActive
        #endif
        history = confirmedHistoryForContinuation
        history.append(CaptionHistoryEntry(id: UUID(), original: notice, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, translated: "", isNotice: true))
        if history.count > 30 { history.removeFirst(history.count - 30) }
        clearCurrent()
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        if nativeWasActive {
            nativeHistory.append(NativeHistoryEpoch(sourceLanguage: "", targetLanguage: "", original: notice, translation: "", isNotice: true))
            nativeArchivedBytes += notice.utf8.count
        }
        #endif
    }
    func reset() {
        clearCurrent(); history.removeAll(); isCapturing = false
        #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
        experimentalAutomaticMode = false; experimentalAutomaticText = ""; experimentalAutomaticFailure = false
        #endif
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        nativeHistory.removeAll(); nativeOriginal.reset(); nativeTranslation.reset(); nativeArchivedBytes = 0; nativeConfirmedBytes = 0; nativePresentationSelected = false
        #endif
    }
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

@MainActor final class LiveCaptionsCoordinator: NSObject, SCStreamDelegate, ObservableObject {
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
    private var managedRecoveryAttempts = 0
    private var diagnosticCaptionSession: (UUID, TimeInterval)?
    private var diagnosticSessionID: UUID?
    private var diagnosticEpochID: UUID?
    private var diagnosticTranslationRecorded = false
    private var generation = UUID(), recognitionID = UUID(), recognitionSetupID = UUID()
    private var panel: NSPanel?
    #if MORIQ_NATIVE_TRANSLATION_PRODUCT
    private var reviewPanelSizeObserver: AnyCancellable?
    #endif
    @Published private(set) var state: LiveCaptionState?
    var onStop: (() -> Void)?

    /// Called only from a user action.
    func start(sourceLanguage: String = "en-US", audioSource: CaptionAudioSource = .system, preserveSession: Bool = false, targetLanguage: String? = nil) {
        let diagnosticID = UUID(), diagnosticStart = ProcessInfo.processInfo.systemUptime
        let sessionID = preserveSession ? (diagnosticSessionID ?? UUID()) : UUID()
        LocalDiagnostics.shared.record(.captions, .start, .started, operationID: diagnosticID, stage:.captionCapture, captionSession:sessionID)
        guard !(Bundle.main.bundleIdentifier ?? "").hasPrefix("local.moriq.internal"), Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor") == nil else {
            LocalDiagnostics.shared.record(.captions, .complete, .failure, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: diagnosticID, stage:.captionCapture, captionSession:sessionID)
            FileHandle.standardError.write(Data("MORIQ runtime refused system audio capture\n".utf8)); return
        }
        if !preserveSession { managedRecoveryAttempts = 0 }
        let savedHistory = preserveSession ? state?.confirmedHistoryForContinuation ?? [] : []
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        let savedNativeHistory = preserveSession ? state?.nativeHistoryForContinuation ?? [] : []
        #endif
        let savedMode = preserveSession ? state?.mode : nil
        let savedTarget = preserveSession ? state?.targetLanguage : nil
        let savedSize = preserveSession ? state?.fontSize : nil
        let savedFrame = preserveSession ? panel?.frame : nil
        stop(notify: false)
        diagnosticCaptionSession = (diagnosticID, diagnosticStart)
        diagnosticSessionID = sessionID; diagnosticEpochID = nil; diagnosticTranslationRecorded = false
        let model = LiveCaptionState(); model.sourceLanguage = sourceLanguage; model.targetLanguage = targetLanguage ?? savedTarget ?? "zh-Hans"; model.audioSource = audioSource; state = model
        model.restoreHistory(savedHistory)
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        model.restoreNativeHistory(savedNativeHistory)
        #endif
        if let savedMode { model.mode = savedMode }; if let savedSize { model.fontSize = savedSize }
        showPanel(model, frame: savedFrame)
        let id = UUID(); generation = id
        setup = Task { @MainActor [weak self] in
            var diagnosticOutcome: DiagnosticOutcome = .cancelled
            defer { LocalDiagnostics.shared.record(.captions, .complete, diagnosticOutcome, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: diagnosticID, stage:.captionCapture, captionSession:sessionID) }
            guard let self else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["MORIQ_DIAGNOSTICS_HOLD_CAPTION_START"] == "1" {
                try? await Task.sleep(for:.seconds(10))
                guard !Task.isCancelled, self.generation == id else {return}
            }
            #endif
            guard CGPreflightScreenCaptureAccess() else { diagnosticOutcome = .failure; model.needsSpeechModel = true; model.status = "请先授权屏幕与系统音频录制，然后重试。"; return }
            guard await self.installRecognition(language: model.sourceLanguage, generation: id) else { diagnosticOutcome = Task.isCancelled ? .cancelled : .failure; return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, self.generation == id else { return }
                guard let display = content.displays.first else { throw CaptionFailure.display }
                let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                if #available(macOS 15.0, *) {
                    config.captureMicrophone = false
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.sink.selectSource(audioSource, stream: stream)
                try stream.addStreamOutput(self.sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.moriq.captions.audio", qos: .userInitiated))
                self.stream = stream
                try await stream.startCapture()
                guard !Task.isCancelled, self.generation == id else { try? await stream.stopCapture(); return }
                model.isCapturing = true
                diagnosticOutcome = .success
                model.status = model.managedSpeech ? "正在向语音服务发送\(audioSource.label)" : "正在聆听\(audioSource.label)"
                self.renewal = Task { @MainActor [weak self] in
                    var elapsed = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self, self.generation == id else { return }
                        guard CGPreflightScreenCaptureAccess() else {
                            CaptionAudioPermissionProbe.verifiedThisLaunch = false; CaptionAudioPermissionProbe.previouslyVerified = false
                            self.endCapture(); model.status = "屏幕与系统音频权限已撤销，字幕已停止。"; return
                        }
                        elapsed += 1
                        // One reconnect per unstable period; a new failure
                        // after 30 seconds of healthy capture may retry once.
                        if elapsed == 30 && self.managedSpeechStream != nil { self.managedRecoveryAttempts = 0 }
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
                diagnosticOutcome = Task.isCancelled || self.generation != id ? .cancelled : .failure
                guard !Task.isCancelled, self.generation == id else { return }
                CaptionAudioPermissionProbe.verifiedThisLaunch = false; CaptionAudioPermissionProbe.previouslyVerified = false
                self.endCapture(); model.status = "\(audioSource.label)无法启动，请检查相关系统权限。"
            }
        }
    }
    #if DEBUG && MORIQ_SPEAKER_EXPERIMENTAL
    private func installExperimentalRecognition(language: String, generation: UUID, environment: [String: String]) -> Bool {
        guard let model = state, model.audioSource == .system else {
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
            let consentKeys = [ManagedSpeechConsentMonitor.key]
            guard consentKeys.allSatisfy({ UserDefaults.standard.bool(forKey: $0) }) else {
                model.needsSpeechModel = true; model.status = "请先在通用设置中允许在线字幕翻译，然后重试。"; return false
            }
            managedSpeechConsentObserver?.stop()
            managedSpeechConsentObserver = ManagedSpeechConsentMonitor(requiredKeys: consentKeys) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.setup?.cancel(); self.endCapture(); self.state?.status = "声音发送授权已撤销，字幕已停止。"
            }
            // Automatic renewal is enabled only once both speech and assistant
            // hold shared leases. Rotating here can revoke an active AI stream.
            guard let value = configured as? String, let endpoint = URL(string: value) else {
                model.needsSpeechModel = true; model.status = "字幕服务暂不可用，请稍后重试。"; return false
            }
            var source = String(language.prefix(2)).lowercased()
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            if model.experimentalAutomaticLanguage { source = "auto" }
            #endif
            let target = String(model.targetLanguage.prefix(2)).lowercased()
            var supportedSources = ["en", "zh", "ja", "ko"]
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            if model.experimentalAutomaticLanguage { supportedSources.append("auto") }
            #endif
            guard supportedSources.contains(source), ["en", "zh"].contains(target) else {
                model.status = "请选择受支持的语音与翻译语言。"; return false
            }
            do {
                sink.setWhisper(nil); managedSpeechAudio?.stop(); managedSpeechAudio = nil
                managedSpeechEvents?.cancel(); managedSpeechEvents = nil
                if let previous = managedSpeechStream { managedSpeechStream = nil; await previous.cancel() }
                guard self.generation == generation, self.recognitionSetupID == setupID, !Task.isCancelled else { return false }
                var credentialLease: DeviceRenewalCoordinator.Lease?
                defer { if let lease = credentialLease { Task { await DeviceRenewalCoordinator.shared.release(lease) } } }
                let token: String
                if Bundle.main.object(forInfoDictionaryKey: "MORIQSharedSessionLeasesEnabled") as? Bool == true {
                    try RuntimeCredentialPolicy.current.requireAccess()
                }
                if Bundle.main.object(forInfoDictionaryKey: "MORIQSharedSessionLeasesEnabled") as? Bool == true,
                   let value = Bundle.main.object(forInfoDictionaryKey: "MORIQDeviceActivationEndpoint") as? String,
                   let renewalEndpoint = URL(string: value),
                   (try DeviceRenewalKeychain().load() != nil || Bundle.main.object(forInfoDictionaryKey: "MORIQAnonymousDeviceEnabled") as? Bool == true) {
                    let anonymousEnabled = Bundle.main.object(forInfoDictionaryKey: "MORIQAnonymousDeviceEnabled") as? Bool == true
                    let lease = try await DeviceRenewalCoordinator.shared.acquire(endpoint: renewalEndpoint, autoActivateAnonymous: anonymousEnabled)
                    credentialLease = lease; token = lease.token
                } else {
                    guard let existing = try ManagedAIAccountToken().load(), !existing.isEmpty else { throw ManagedAIError.notSignedIn }
                    token = existing
                }
                guard self.generation == generation, self.recognitionSetupID == setupID, !Task.isCancelled else { return false }
                model.clearUnanchoredPreview()
                var nativeEnabled = false
                #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                nativeEnabled = CaptionNativeProductPolicy.enabled(config: Bundle.main.object(forInfoDictionaryKey: "MORIQNativeCaptionMode"))
                #elseif DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
                nativeEnabled = ProcessInfo.processInfo.environment["MORIQ_CAPTION_NATIVE_TRANSLATION_V1"] == "1"
                #endif
                var nativeBatchEnabled = false
                #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                nativeBatchEnabled = nativeEnabled
                #elseif DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
                nativeBatchEnabled = nativeEnabled && ProcessInfo.processInfo.environment["MORIQ_CAPTION_NATIVE_BATCH_V1"] == "1"
                #endif
                var deltaEnabled = false
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                deltaEnabled = !nativeEnabled && ProcessInfo.processInfo.environment["MORIQ_CAPTION_CONFIRMED_DELTA_V1"] == "1"
                #endif
                let previewEnabled = !nativeEnabled && !deltaEnabled && (Bundle.main.object(forInfoDictionaryKey: "MORIQUnanchoredPreviewEnabled") as? Bool == true)
                #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                let reviewEnabled = CaptionSourceReviewPolicy.enabled(config: Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionSourceReviewMode"), nativeBatch: nativeBatchEnabled)
                    && CaptionReviewClient.configured(Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionReviewEndpoint"), enabled: true, tokenLoader: { nil }) != nil
                    && !(Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionReviewRecipient") as? String ?? "").isEmpty
                #else
                let reviewEnabled = false
                #endif
                #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
                // Preserve the existing automatic-translation path for prior
                // configured installations. Only the new protocol is opt-in.
                let automaticEnabled = CaptionAutomaticProductPolicy.enabled(config: Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionAutomaticMode"), nativeBatch: nativeBatchEnabled)
                #else
                let automaticEnabled = false
                #endif
                let enhancedRequested = (Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionPunctAvailable") as? Bool == true)
                    && UserDefaults.standard.bool(forKey: CaptionPunctProductPolicy.preferenceKey)
                if enhancedRequested && !automaticEnabled {
                    model.status = "增强实时翻译尚未配置，请检查服务设置或在通用设置中关闭。"
                    return false
                }
                let sourceEnabled = reviewEnabled || automaticEnabled
                #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
                let punctEnabled = CaptionPunctProductPolicy.enabled(
                    available: Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionPunctAvailable"),
                    optedIn: UserDefaults.standard.bool(forKey: CaptionPunctProductPolicy.preferenceKey),
                    automatic: automaticEnabled)
                #elseif DEBUG && MORIQ_NATIVE_TRANSLATION_PRODUCT
                let punctEnabled = sourceEnabled && ProcessInfo.processInfo.environment["MORIQ_CAPTION_PUNCT_V1"] == "1"
                #else
                let punctEnabled = false
                #endif
                let diagnostic = CaptionConnectionDiagnostic(session: diagnosticSessionID)
                diagnosticEpochID=diagnostic.epoch; diagnosticTranslationRecorded=false
                diagnosticCaptionSession=(diagnostic.operation,diagnostic.started)
                var wssOutcome: DiagnosticOutcome = .failure
                defer { diagnostic.finish(Task.isCancelled ? .cancelled : wssOutcome) }
                let remote = try ManagedSpeechStream(endpoint: endpoint, token: token, requestUnanchoredPreview: previewEnabled, requestConfirmedDeltas: deltaEnabled, requestNativeTranslation: nativeEnabled, requestNativeBatch: nativeBatchEnabled, requestSourceUnitsV2: sourceEnabled, requestSourceAtomicV1: sourceEnabled, requestAutomaticTranslation: automaticEnabled, requestSourcePunctV1: punctEnabled)
                if let lease = credentialLease {
                    await remote.attachCredentialRelease { await DeviceRenewalCoordinator.shared.release(lease) }
                    credentialLease = nil
                }
                managedSpeechStream = remote
                // Older translation gateways require a distinct target. A
                // transcription-only gateway ignores this compatibility value.
                let requestTarget = !nativeEnabled && source == target ? (source == "en" ? "zh" : "en") : target
                let events = try await remote.start(source: source, target: requestTarget)
                var iterator = events.makeAsyncIterator()
                guard let first = try await iterator.next() else { throw ManagedSpeechError.connectionClosed }
                if let terminalMessage = managedTerminalMessage(first) {
                    await remote.cancel()
                    guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                    managedSpeechStream = nil
                    model.needsSpeechModel = false; model.status = terminalMessage
                    return false
                }
                if first.type == "error", ["unsupported_source_language", "unsupported_source_language_english_only"].contains(first.code ?? "") {
                    await remote.cancel()
                    guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                    managedSpeechStream = nil
                    model.status = first.code == "unsupported_source_language_english_only" ? "在线字幕目前仅支持英语，请切换语音语言。" : "在线字幕目前支持中文和英语，请切换语音语言。"; return false
                }
                guard first.type == "ready", self.generation == generation, self.recognitionSetupID == setupID,
                      consentKeys.allSatisfy({ UserDefaults.standard.bool(forKey: $0) }), !Task.isCancelled else {
                    await remote.cancel()
                    guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                    managedSpeechStream = nil
                    model.status = "语音服务未能连接，请重试。"; return false
                }
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                if model.experimentalAutomaticLanguage && first.mode != "transcription" && !nativeEnabled {
                    await remote.cancel(); managedSpeechStream = nil
                    model.status = "实验自动语言模式需要转写服务。"; return false
                }
                #endif
                model.managedSpeechProvidesTranslation = first.mode != "transcription"
                #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
                if nativeEnabled && first.nativeTranslationV1 == true && first.mode == "translation" { model.beginNativeCaption() }
                else { model.disableNativePresentation() }
                #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
                model.experimentalAutomaticMode = automaticEnabled
                #endif
                #endif
                let bridge = ManagedSpeechAudioBridge(stream: remote) { [weak self] in
                    Task { @MainActor in self?.recoverManagedConnection(generation: generation, setupID: setupID) }
                }
                managedSpeechAudio = bridge
                sink.setWhisper { [weak bridge] sample in bridge?.append(sample) }
                managedSpeechEvents = Task { @MainActor [weak self] in
                    do {
                        var accumulator = ManagedSpeechAccumulator()
                        var confirmedAccumulator = ManagedConfirmedDeltaAccumulator()
                        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
                        let nativeEpoch = UUID()
                        var nativeAccumulator = ManagedNativeLaneAccumulator(epoch: nativeEpoch)
                        #endif
                        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                        var reviewReducer: SourceV2Verifier?
                        if sourceEnabled, first.sourceUnitsV2 == true, first.sourceAtomicV1 == true,
                           let session = first.sourceSessionID.flatMap(UUID.init(uuidString:)),
                           let epoch = first.sourceEpochID.flatMap(UUID.init(uuidString:)),
                           let stream = first.originalStreamID.flatMap(UUID.init(uuidString:)) {
                            reviewReducer = SourceV2Verifier(session: session, epoch: epoch, stream: stream)
                        } else if sourceEnabled { model.sourceReviewStatus = "校订暂不可用，字幕继续" }
                        #if MORIQ_AUTO_TRANSLATION_PRODUCT
                        var automaticState: CaptionAutomaticTranslationState?
                        let priorAutomaticText = model.experimentalAutomaticText
                        if automaticEnabled, first.automaticTranslationV1 == true,
                           let session = first.sourceSessionID.flatMap(UUID.init(uuidString:)),
                           let epoch = first.sourceEpochID.flatMap(UUID.init(uuidString:)),
                           let stream = first.originalStreamID.flatMap(UUID.init(uuidString:)) {
                            automaticState = CaptionAutomaticTranslationState(session: session, epoch: epoch, stream: stream, target: target == "zh" ? "zh-Hans" : "en-US")
                        } else if automaticEnabled { model.experimentalAutomaticFailure = true }
                        #endif
                        #endif
                        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                        var punctCoordinator: PunctCoordinator?
                        var bufferedTerminalTranslations: [ManagedSpeechEvent] = []
                        var punctDegraded = false
                        if punctEnabled {
                            guard first.sourcePunctV1 == true, let reducer = reviewReducer else {
                                model.failPunctReview(); await remote.cancel(); return
                            }
                            punctCoordinator = PunctCoordinator(verifier: reducer)
                        }
                        #endif
                        accumulator.sourceSnapshots = first.mode == "transcription"
                        while let event = try await iterator.next() {
                            guard let self, ManagedSpeechEventFence.permits(generation: generation, setup: setupID, currentGeneration: self.generation, currentSetup: self.recognitionSetupID, sameModel: self.state === model, cancelled: Task.isCancelled) else { return }
                            if self.handleManagedQuota(event, model: model) { return }
                            #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
                            if nativeBatchEnabled && event.type == "lane_batch" {
                                guard try self.consumeNativeBatch(event, model: model, generation: generation, setupID: setupID,
                                                                  epoch: nativeEpoch, accumulator: &nativeAccumulator) else { return }
                                #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                                if punctEnabled && event.sourceUnitsUnavailable {
                                    guard let raw=event.sourcePunctBatchRaw,let data=raw.data(using:.utf8),let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],Set(obj.keys)==Set(["type","events","batch_seq","source_units_unavailable"]),obj["source_units_unavailable"] as? Bool == true else { model.failPunctReview(); await remote.cancel(); return }
                                    punctDegraded=true; bufferedTerminalTranslations.removeAll(); model.closePunctReview()
                                    model.sourceReviewStatus="自动翻译暂不可用，原文继续显示"
                                    #if MORIQ_AUTO_TRANSLATION_PRODUCT
                                    automaticState=nil;model.experimentalAutomaticFailure=true
                                    #endif
                                    continue
                                }
                                if punctEnabled && punctDegraded { continue }
                                if punctEnabled && reviewReducer == nil { model.failPunctReview(); await remote.cancel(); return }
                                if var reducer = reviewReducer {
                                    if punctEnabled {
                                        guard var coordinator = punctCoordinator, !event.sourceUnitsUnavailable,
                                              let raw=event.sourcePunctBatchRaw, let data=raw.data(using:.utf8),
                                              let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                                              let seq=event.batchSeq, let units=object["source_units"] as? [[String:Any]],
                                              let ranges=object["nonbillable_ranges"] as? [[String:Int]],
                                              let coverage=object["source_coverage"] as? [String:Any],
                                              coordinator.batch(seq:seq,confirmed:model.nativeOriginal.confirmed,units:units,ranges:ranges,coverage:coverage,negotiated:first.sourcePunctV1 == true) else {
                                            model.failPunctReview(); await remote.cancel(); return
                                        }
                                        reducer=coordinator.verifier; punctCoordinator=coordinator
                                        model.disablePunctReview()
                                    } else { model.acceptSourceReviewBatch(event, reducer: &reducer) }
                                    #if MORIQ_AUTO_TRANSLATION_PRODUCT
                                    if var automatic = automaticState {
                                        if !reducer.reviewEnabled { model.experimentalAutomaticFailure = true; automaticState = nil }
                                        else { for marker in reducer.acceptedMarkers { automatic.register(marker) }; automaticState = automatic }
                                    }
                                    #endif
                                    reviewReducer = reducer
                                }
                                #endif
                                continue
                            }
                            if nativeEnabled && event.type == "lane_delta" {
                                guard try self.consumeNativeLane(event, model: model, generation: generation, setupID: setupID,
                                                                 epoch: nativeEpoch, accumulator: &nativeAccumulator) else { return }
                                continue
                            }
                            if nativeEnabled && event.type == "stream_marker" { continue }
                            #endif
                            #if MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT
                            if automaticEnabled && ["auto_translation_v1", "auto_translation_error_v1"].contains(event.type) {
                                if punctEnabled && punctDegraded { continue }
                                if punctEnabled && punctCoordinator?.awaitingFinished == true {
                                    guard bufferedTerminalTranslations.count < 8 else { model.failPunctReview(); await remote.cancel(); return }
                                    bufferedTerminalTranslations.append(event); continue
                                }
                                guard let raw = event.automaticTranslationRaw,
                                      let wire = try? JSONDecoder().decode(CaptionAutomaticWireEvent.self, from: Data(raw.utf8)),
                                      var automatic = automaticState else { model.experimentalAutomaticFailure = true; continue }
                                if wire.type == "auto_translation_v1", let text = wire.text {
                                    let item = CaptionAutomaticTranslationEvent(session: wire.session, epoch: wire.epoch, originalStreamID: wire.original_stream_id, unit: wire.unit, revision: wire.revision, sourceSHA256: wire.source_sha256, target: wire.target, text: text, associationVerified: true, autoApply: true)
                                    if automatic.accept(item) { model.experimentalAutomaticText = [priorAutomaticText, automatic.visible].filter { !$0.isEmpty }.joined(separator: "\n") }
                                    else { model.experimentalAutomaticFailure = true }
                                } else if !automatic.acceptFailure(wire) { model.experimentalAutomaticFailure = true }
                                model.experimentalAutomaticFailure = model.experimentalAutomaticFailure || automatic.hasFailure
                                automaticState = automatic
                                continue
                            }
                            #endif
                            #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                            if punctEnabled && event.type == "finished" {
                                if punctDegraded { return }
                                guard var coordinator=punctCoordinator, coordinator.finish(negotiated:first.sourcePunctV1 == true) else { model.failPunctReview(); await remote.cancel(); return }
                                reviewReducer=coordinator.verifier; punctCoordinator=coordinator
                                model.closePunctReview()
                                #if MORIQ_AUTO_TRANSLATION_PRODUCT
                                if var automatic=automaticState {
                                    for marker in coordinator.verifier.acceptedMarkers { automatic.register(marker) }
                                    for queued in bufferedTerminalTranslations {
                                        guard let raw=queued.automaticTranslationRaw, let wire=try? JSONDecoder().decode(CaptionAutomaticWireEvent.self,from:Data(raw.utf8)) else { model.failPunctReview(); await remote.cancel(); return }
                                        if wire.type == "auto_translation_v1", let text=wire.text {
                                            let item=CaptionAutomaticTranslationEvent(session:wire.session,epoch:wire.epoch,originalStreamID:wire.original_stream_id,unit:wire.unit,revision:wire.revision,sourceSHA256:wire.source_sha256,target:wire.target,text:text,associationVerified:true,autoApply:true)
                                            guard automatic.accept(item) else { model.failPunctReview(); await remote.cancel(); return }
                                        } else if !automatic.acceptFailure(wire) { model.failPunctReview(); await remote.cancel(); return }
                                    }
                                    model.experimentalAutomaticText = [priorAutomaticText,automatic.visible].filter { !$0.isEmpty }.joined(separator:"\n")
                                    automaticState=automatic
                                } else if !bufferedTerminalTranslations.isEmpty { model.failPunctReview(); await remote.cancel(); return }
                                #endif
                                bufferedTerminalTranslations.removeAll(); return
                            }
                            #endif
                            if event.type == "confirmed_delta" {
                                let current = try confirmedAccumulator.accept(event)
                                model.acceptManagedDelta(confirmed: current.confirmed, provisional: current.provisional, segment: current.segment, final: current.final, languageLabels: event.languageLabels)
                                continue
                            }
                            if event.type == "unanchored_preview" {
                                model.acceptUnanchoredPreview(event.text)
                                continue
                            }
                            // Independent tracks: the provider has not promised
                            // that original/translation segment IDs correspond.
                            guard let current = accumulator.accept(event), let segment = event.segment else { continue }
                            if event.type == "source" { model.acceptManagedSource(current.text, segment: segment, final: current.final, languageLabels: event.languageLabels) }
                            else if event.type == "translation" { model.acceptManagedTranslation(current.text) }
                        }
                        guard let self, !Task.isCancelled else { return }
                        self.recoverManagedConnection(generation: generation, setupID: setupID)
                    } catch {
                        guard let self, ManagedSpeechEventFence.permits(generation: generation, setup: setupID, currentGeneration: self.generation, currentSetup: self.recognitionSetupID, sameModel: self.state === model, cancelled: Task.isCancelled) else { return }
                        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                        model.reviewSource = nil
                        if reviewEnabled { model.sourceReviewStatus = "字幕连接中断，校订不可用" }
                        #endif
                        self.recoverManagedConnection(generation: generation, setupID: setupID)
                    }
                }
                // Includes server ready and the local bridge/task setup; not an exact handshake metric.
                wssOutcome = .success
                return true
            } catch {
                // A superseded setup must not cancel or overwrite the new
                // session after an awaited operation returns late.
                guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                if let remote = managedSpeechStream { await remote.cancel() }
                guard self.generation == generation, self.recognitionSetupID == setupID else { return false }
                managedSpeechStream = nil
                model.needsSpeechModel = true
                let enhancedRequested = (Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionPunctAvailable") as? Bool == true)
                    && UserDefaults.standard.bool(forKey: CaptionPunctProductPolicy.preferenceKey)
                if case ManagedSpeechError.capabilityUnavailable = error {
                    model.status = "当前字幕服务未支持增强实时翻译，可在通用设置中关闭后重试。"
                } else {
                    model.status = enhancedRequested ? "增强实时翻译未能启用，请检查网络或账户权限；也可在通用设置中关闭。" : "语音服务未能连接，请检查网络或账户后重试。"
                }
                return false
            }
        }
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        if state?.experimentalAutomaticLanguage == true {
            state?.status = "实验自动语言模式需要配置转写服务。"; return false
        }
        #endif
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
        // Retiring the recognizer does not confirm its partial hypothesis.
        // Finalized entries are already in history; discard only the live text.
        model.clearCurrent()
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
            self.handleActiveStreamFailure()
        }
    }
    private func handleActiveStreamFailure() {
        LocalDiagnostics.shared.record(.captions,.disconnect,.failure,stage:.captionCapture,captionSession:diagnosticSessionID,captionEpoch:diagnosticEpochID)
        CaptionAudioPermissionProbe.verifiedThisLaunch = false; CaptionAudioPermissionProbe.previouslyVerified = false
        let source = self.state?.audioSource.label ?? "声音"
        let permitted = CGPreflightScreenCaptureAccess()
        self.state?.markManagedConnectionGap("\(source)意外停止，部分声音可能遗漏")
        self.endCapture()
        let failure = CaptionCaptureFailurePolicy.status(source: source, permitted: permitted)
        self.state?.needsSpeechModel = failure.canRetry
        self.state?.status = failure.message
    }
    #if DEBUG
    func debugSimulateActiveStreamFailure() { handleActiveStreamFailure() }
    #endif
    private func installModel() {
        guard let model = state else { return }
        managedRecoveryAttempts = 0
        start(sourceLanguage: model.sourceLanguage, audioSource: model.audioSource, preserveSession: true)
    }
    /// Stop capture before retrying so no unbounded audio is buffered. A gap
    /// remains visible because queued/in-flight audio cannot be recovered.
    private func recoverManagedConnection(generation: UUID, setupID: UUID) {
        guard let model = state, model.managedSpeech else { return }
        var consent: Bool
        var permission: Bool
        #if DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
        if debugLocalRecoveryRestart != nil { consent = true; permission = true }
        else {
            consent = UserDefaults.standard.bool(forKey: ManagedSpeechConsentMonitor.key)
            permission = CGPreflightScreenCaptureAccess()
        }
        #else
        consent = UserDefaults.standard.bool(forKey: ManagedSpeechConsentMonitor.key)
        permission = CGPreflightScreenCaptureAccess()
        #endif
        let decision = ManagedSpeechRecoveryPolicy.decide(current: self.generation == generation && recognitionSetupID == setupID, capturing: model.isCapturing, permission: permission, consent: consent, attempts: managedRecoveryAttempts)
        switch decision {
        case .ignore: return
        case .permissionsLost:
            setup?.cancel(); endCapture(); model.status = consent ? "屏幕与系统音频权限已撤销，字幕已停止。" : "声音发送授权已撤销，字幕已停止。"; return
        case .startupFailed:
            setup?.cancel(); endCapture(); model.needsSpeechModel = true; model.status = "语音连接未能启动，请重试。"; return
        case .stopAfterRetry:
            model.markManagedConnectionGap(); endCapture(); model.needsSpeechModel = true; model.status = "连接再次中断，部分声音可能遗漏；请重试。"; return
        case .retry:
            LocalDiagnostics.shared.record(.captions,.reconnect,.started,stage:.captionReconnect,protocolVersion:.managedSpeechV1,captionSession:diagnosticSessionID,captionEpoch:diagnosticEpochID)
            break
        }
        managedRecoveryAttempts += 1
        model.markManagedConnectionGap()
        let language = model.sourceLanguage, target = model.targetLanguage, source = model.audioSource
        endCapture()
        model.status = "连接中断，部分声音可能遗漏；正在重连。"
        scheduleManagedRetry(generation: generation, model: model, consent: { [weak self] in
            #if DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
            if self?.debugLocalRecoveryRestart != nil { return true }
            #endif
            return UserDefaults.standard.bool(forKey: ManagedSpeechConsentMonitor.key)
        }, permission: { [weak self] in
            #if DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
            if self?.debugLocalRecoveryRestart != nil { return true }
            #endif
            return CGPreflightScreenCaptureAccess()
        }) { [weak self] in
            guard let self else { return }
            #if DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
            if let restart = self.debugLocalRecoveryRestart { restart(); return }
            #endif
            self.start(sourceLanguage: language, audioSource: source, preserveSession: true, targetLanguage: target)
        }
    }
    private func scheduleManagedRetry(generation: UUID, model: LiveCaptionState, consent: @escaping @MainActor () -> Bool, permission: @escaping @MainActor () -> Bool, restart: @escaping @MainActor () -> Void) {
        setup = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.generation == generation, self.state === model, !Task.isCancelled else { return }
            guard consent() else {
                model.status = "声音发送授权已撤销，字幕已停止。"; return
            }
            guard permission() else {
                model.status = "屏幕与系统音频权限已撤销，字幕已停止。"; return
            }
            restart()
        }
    }
    private func showPanel(_ model: LiveCaptionState, frame: NSRect? = nil) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        // Leave room underneath so review expansion can preserve the caption
        // baseline instead of pushing subtitles upward on the screen.
        let initialY = screen.minY + min(240, max(0, screen.height - 196))
        let panel = NSPanel(contentRect: CGRect(x: screen.midX - 310, y: initialY, width: 620, height: 196), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let frame { panel.setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 620, height: 196), display: false) }
        let host = NSHostingView(rootView: LiveCaptionView(state: model, close: { [weak self] in self?.stop() }, installModel: { [weak self] in self?.installModel() }, changeLanguage: { [weak self] language in
            guard let self else { return }
            if self.stream == nil { self.start(sourceLanguage: language, preserveSession: true); return }
            model.clearCurrent(); model.isCapturing = true
            let token = self.generation
            self.setup?.cancel()
            self.setup = Task { @MainActor in
                let installed = await self.installRecognition(language: language, generation: token)
                guard self.generation == token, self.state?.sourceLanguage == language else { return }
                if !installed { self.endCapture() }
            }
        }, changeAudioSource: { _ in }, changeTargetLanguage: { [weak self] target in
            guard let self, model.managedSpeech else { return }
            self.start(sourceLanguage: model.sourceLanguage, preserveSession: true, targetLanguage: target)
        }))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
        reviewPanelSizeObserver = Publishers.CombineLatest3(
            Publishers.CombineLatest4(model.$reviewPanelExpanded, model.$reviewContentHeight, model.$fontSize, model.$mode),
            model.$sourceLanguage, model.$targetLanguage)
            .combineLatest(Publishers.Merge(
                NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: panel).map { _ in () },
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () }
            ).prepend(()))
            .sink { [weak panel, weak model] combined, _ in
            let (args, source, target) = combined
            let (expanded, measured, fontSize, mode) = args
            let contentHeight = expanded ? CaptionReviewLayoutPolicy.contentHeight(measured) : 0
            let effectiveMode = CaptionWindowSizing.effectiveMode(mode: mode, sameLanguage: CaptionLanguagePair.isSame(source, target))
            guard let panel else { return }
            let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
            let availableReview = min(contentHeight, max(0, visible.height - 196))
            if model?.captionWindowAvailable != visible.height { model?.captionWindowAvailable = visible.height }
            if model?.captionReviewAvailable != availableReview { model?.captionReviewAvailable = availableReview }
            let height = CaptionWindowSizing.windowHeight(fontSize: fontSize, mode: effectiveMode, review: availableReview, available: visible.height)
            var frame = panel.frame
            let top = frame.maxY
            frame.size.height = height
            frame.origin.y = min(max(top - height, visible.minY), visible.maxY - height)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.setFrame(frame, display: true) }
            else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
        #endif
        panel.orderFrontRegardless()
    }
    private func endCapture() {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
        state?.reviewPanelExpanded = false
        state?.reviewSource = nil
        #endif
        state?.clearUnanchoredPreview()
        // A stopped stream cannot later confirm its last hypothesis. Discard
        // unfinished visible text; finalized captions already live in history.
        if let state, !state.segmentFinalized { state.clearCurrent() }
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
    private func handleManagedQuota(_ event: ManagedSpeechEvent, model: LiveCaptionState) -> Bool {
        guard let message = managedTerminalMessage(event) else { return false }
        model.markManagedConnectionGap(message)
        endCapture()
        model.needsSpeechModel = false; model.status = message
        return true
    }
    private func managedTerminalMessage(_ event: ManagedSpeechEvent) -> String? {
        guard event.type == "error" else { return nil }
        switch event.code {
        case "quota_exhausted": return "在线字幕额度或请求频率已达上限。"
        case "session_expired": return "在线字幕会话已过期或不可用。"
        case "source_capacity": return "字幕记录达到本次容量上限，已停止；可重新开始。"
        default: return nil
        }
    }
    #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
    /// Common runtime/test path: no event bypasses generation, setup, model,
    /// lane-revision or current-language guards.
    private func consumeNativeBatch(_ event: ManagedSpeechEvent, model: LiveCaptionState, generation: UUID,
                                    setupID: UUID, epoch: UUID, accumulator: inout ManagedNativeLaneAccumulator) throws -> Bool {
        guard ManagedSpeechEventFence.permits(generation: generation, setup: setupID, currentGeneration: self.generation,
                                             currentSetup: recognitionSetupID, sameModel: state === model,
                                             cancelled: Task.isCancelled), model.nativeActive else { return false }
        guard event.type == "lane_batch", let children = event.events else { throw ManagedSpeechError.invalidResponse }
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_SOURCE_UNITS_V2_EXPERIMENTAL)
        // An atomic finish may commit no text but still carry source metadata.
        if children.isEmpty && (event.sourceMarkersRaw != nil || event.sourceUnitsUnavailable) { return true }
        #endif
        var staged = accumulator
        let updates = try staged.acceptBatch(children, epoch: epoch)
        guard model.acceptNativeBatch(updates) else {
            endCapture(); model.showHistory = true
            model.status = "字幕记录已达到本次上限，已停止；可复制已确认记录。"
            return false
        }
        accumulator = staged
        if let session=diagnosticCaptionSession, !model.nativeOriginal.text.isEmpty {
            LocalDiagnostics.shared.record(.captions,.firstOutput,.success,duration:ProcessInfo.processInfo.systemUptime-session.1,operationID:session.0,stage:.captionOriginalAccepted,protocolVersion:.managedSpeechV1,captionSession:diagnosticSessionID,captionEpoch:diagnosticEpochID)
            diagnosticCaptionSession = nil
        }
        if !diagnosticTranslationRecorded && !model.nativeTranslation.text.isEmpty, let sessionID=diagnosticSessionID {
            diagnosticTranslationRecorded=true
            LocalDiagnostics.shared.record(.captions,.firstOutput,.success,stage:.captionTranslationAccepted,protocolVersion:.managedSpeechV1,captionSession:sessionID,captionEpoch:diagnosticEpochID)
        }
        return true
    }
    private func consumeNativeLane(_ event: ManagedSpeechEvent, model: LiveCaptionState, generation: UUID,
                                   setupID: UUID, epoch: UUID, accumulator: inout ManagedNativeLaneAccumulator) throws -> Bool {
        guard ManagedSpeechEventFence.permits(generation: generation, setup: setupID, currentGeneration: self.generation,
                                             currentSetup: recognitionSetupID, sameModel: state === model,
                                             cancelled: Task.isCancelled), model.nativeActive else { return false }
        let update = try accumulator.accept(event, epoch: epoch)
        guard model.acceptNativeCaption(update) else {
            endCapture(); model.showHistory = true
            model.status = "字幕记录已达到本次上限，已停止；可复制已确认记录。"
            return false
        }
        return true
    }
    #endif
    func stop(notify: Bool = true) {
        if let sessionID=diagnosticSessionID { LocalDiagnostics.shared.record(.captions,notify ? .stop : .teardown,.started,stage:.captionStop,captionSession:sessionID,captionEpoch:diagnosticEpochID) }
        diagnosticSessionID = nil; diagnosticEpochID = nil; diagnosticTranslationRecorded = false
        diagnosticCaptionSession = nil
        generation = UUID(); setup?.cancel(); setup = nil; endCapture()
        panel?.orderOut(nil); panel = nil; state?.reset(); state = nil
        if notify { onStop?() }
    }
    private enum CaptionFailure: Error { case display }

    #if DEBUG
    #if MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL
    private var debugNativeAccumulator = ManagedNativeLaneAccumulator()
    private var debugNativeSetupID = UUID()
    private var debugNativeGeneration = UUID()
    private var debugLocalRecoveryRestart: (@MainActor () -> Void)?
    private var debugOldBatch: (ManagedSpeechEvent, UUID, UUID, UUID, ManagedNativeLaneAccumulator)?
    var debugRecoveryConnections = 0
    var debugOldBatchRejected = false
    /// Local-only fixture: real stream decoding, coordinator event fence,
    /// recovery policy, teardown and delayed retry; no audio bridge is made.
    func debugStartLocalRecovery(endpoint: URL) {
        debugOpenNativeWithoutCapture(visible: true)
        debugRecoveryConnections = 0; debugOldBatchRejected = false; debugOldBatch = nil
        debugLocalRecoveryRestart = { [weak self] in self?.debugConnectLocalRecovery(endpoint: endpoint) }
        debugConnectLocalRecovery(endpoint: endpoint)
    }
    private func debugConnectLocalRecovery(endpoint: URL) {
        guard let model = state else { return }
        let testGeneration = generation, testSetup = UUID(); recognitionSetupID = testSetup
        setup = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            let diagnostic = CaptionConnectionDiagnostic(session: self.diagnosticSessionID)
            self.diagnosticEpochID=diagnostic.epoch; self.diagnosticTranslationRecorded=false
            self.diagnosticCaptionSession=(diagnostic.operation,diagnostic.started)
            var outcome: DiagnosticOutcome = .failure
            defer { diagnostic.finish(Task.isCancelled ? .cancelled : outcome) }
            do {
                #if MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
                let autoTest = ProcessInfo.processInfo.environment["MORIQ_TEST_AUTO_TRANSLATION"] == "1"
                #else
                let autoTest = false
                #endif
                let remote = try ManagedSpeechStream(endpoint: endpoint, token: String(repeating: "x", count: 40), requestNativeTranslation: true, requestNativeBatch: true, allowLoopbackForTesting: true, requestSourceUnitsV2: autoTest, requestSourceAtomicV1: autoTest, requestAutomaticTranslation: autoTest, requestSourcePunctV1: autoTest && ProcessInfo.processInfo.environment["MORIQ_TEST_PUNCT"] == "1")
                self.managedSpeechStream = remote
                let events = try await remote.start(source: "en", target: "zh"); var iterator = events.makeAsyncIterator()
                guard let ready = try await iterator.next(), ready.nativeBatchV1 == true, self.generation == testGeneration, self.recognitionSetupID == testSetup else { throw ManagedSpeechError.invalidResponse }
                model.beginNativeCaption(); model.isCapturing = true
                model.status = "正在向语音服务发送\(model.audioSource.label)"
                self.debugRecoveryConnections += 1
                #if MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
                var sourceVerifier: SourceV2Verifier?
                var automaticState: CaptionAutomaticTranslationState?
                let previousAutomaticText = model.experimentalAutomaticText
                let previousAutomaticFailure = model.experimentalAutomaticFailure
                if autoTest, ready.automaticTranslationV1 == true,
                   let session = ready.sourceSessionID.flatMap(UUID.init(uuidString:)),
                   let sourceEpoch = ready.sourceEpochID.flatMap(UUID.init(uuidString:)),
                   let streamID = ready.originalStreamID.flatMap(UUID.init(uuidString:)) {
                    sourceVerifier = SourceV2Verifier(session: session, epoch: sourceEpoch, stream: streamID)
                    automaticState = CaptionAutomaticTranslationState(session: session, epoch: sourceEpoch, stream: streamID, target: "zh-Hans")
                    model.experimentalAutomaticMode = true
                    try await remote.sendPCM(Data(repeating: 0, count: 3200))
                } else if autoTest { model.failPunctReview(); await remote.cancel(); return }
                #endif
                #if MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
                let punctTest = autoTest && ProcessInfo.processInfo.environment["MORIQ_TEST_PUNCT"] == "1"
                var punct = sourceVerifier.map { PunctCoordinator(verifier:$0) }
                var pendingTranslations: [ManagedSpeechEvent] = []
                var punctTestDegraded = false
                #endif
                var accumulator = ManagedNativeLaneAccumulator(); let epoch = accumulator.epoch
                if let old = self.debugOldBatch {
                    var stale = old.4
                    self.debugOldBatchRejected = try !self.consumeNativeBatch(old.0, model: model, generation: old.1, setupID: old.2, epoch: old.3, accumulator: &stale)
                }
                self.managedSpeechEvents = Task { @MainActor [weak self, weak model] in
                    guard let self, let model else { return }
                    do {
                        while let event = try await iterator.next() {
                            #if MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
                            if event.type == "finished", punctTest {
                                if punctTestDegraded { return }
                                guard var pc=punct, pc.finish(negotiated:ready.sourcePunctV1 == true), var automatic=automaticState else { await remote.cancel();return }
                                for marker in pc.verifier.acceptedMarkers { automatic.register(marker) }
                                for queued in pendingTranslations {
                                    guard let raw=queued.automaticTranslationRaw, let wire=try? JSONDecoder().decode(CaptionAutomaticWireEvent.self,from:Data(raw.utf8)) else { await remote.cancel();return }
                                    if wire.type == "auto_translation_v1", let text=wire.text {
                                        let result=CaptionAutomaticTranslationEvent(session:wire.session,epoch:wire.epoch,originalStreamID:wire.original_stream_id,unit:wire.unit,revision:wire.revision,sourceSHA256:wire.source_sha256,target:wire.target,text:text,associationVerified:true,autoApply:true)
                                        guard automatic.accept(result) else { await remote.cancel();return }
                                    } else if !automatic.acceptFailure(wire) { await remote.cancel();return }
                                }
                                model.experimentalAutomaticText=[previousAutomaticText,automatic.visible].filter { !$0.isEmpty }.joined(separator:"\n")
                                model.closePunctReview()
                                automaticState=automatic;punct=pc;pendingTranslations.removeAll();return
                            }
                            if punctTestDegraded && ["auto_translation_v1","auto_translation_error_v1"].contains(event.type) { continue }
                            if punctTest && punct?.awaitingFinished == true && ["auto_translation_v1","auto_translation_error_v1"].contains(event.type) {
                                guard pendingTranslations.count < 8 else { await remote.cancel();return }
                                pendingTranslations.append(event);continue
                            }
                            #endif
                            if event.type == "finished" { return }
                            if self.handleManagedQuota(event, model: model) { return }
                            #if MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
                            if event.type == "auto_translation_v1", let raw = event.automaticTranslationRaw,
                               let wire = try? JSONDecoder().decode(CaptionAutomaticWireEvent.self, from: Data(raw.utf8)),
                               let text = wire.text, var automatic = automaticState {
                                let result = CaptionAutomaticTranslationEvent(session: wire.session, epoch: wire.epoch, originalStreamID: wire.original_stream_id, unit: wire.unit, revision: wire.revision, sourceSHA256: wire.source_sha256, target: wire.target, text: text, associationVerified: true, autoApply: true)
                                if automatic.accept(result) {
                                    model.experimentalAutomaticText = [previousAutomaticText, automatic.visible].filter { !$0.isEmpty }.joined(separator: "\n")
                                }
                                model.experimentalAutomaticFailure = previousAutomaticFailure || automatic.hasFailure
                                automaticState = automatic
                                continue
                            }
                            if event.type == "auto_translation_error_v1", let raw = event.automaticTranslationRaw,
                               let wire = try? JSONDecoder().decode(CaptionAutomaticWireEvent.self, from: Data(raw.utf8)),
                               var automatic = automaticState {
                                if automatic.acceptFailure(wire) { model.experimentalAutomaticFailure = true }
                                automaticState = automatic
                                continue
                            }
                            #endif
                            if event.type == "lane_batch" {
                                let before = accumulator
                                guard try self.consumeNativeBatch(event, model: model, generation: testGeneration, setupID: testSetup, epoch: epoch, accumulator: &accumulator) else { return }
                                #if MORIQ_AUTO_TRANSLATION_EXPERIMENTAL
                                if punctTest && event.sourceUnitsUnavailable {
                                    guard let raw=event.sourcePunctBatchRaw,let data=raw.data(using:.utf8),let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],Set(obj.keys)==Set(["type","events","batch_seq","source_units_unavailable"]),obj["source_units_unavailable"] as? Bool == true else { model.failPunctReview(); await remote.cancel();return }
                                    punctTestDegraded=true;pendingTranslations.removeAll();automaticState=nil;model.closePunctReview();model.experimentalAutomaticFailure=true;model.sourceReviewStatus="自动翻译暂不可用，原文继续显示";continue
                                }
                                if punctTest && punctTestDegraded {continue}
                                if var verifier = sourceVerifier, var automatic = automaticState {
                                    if punctTest {
                                        guard var pc=punct, let raw=event.sourcePunctBatchRaw, let data=raw.data(using:.utf8),
                                              let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let seq=event.batchSeq,
                                              let units=object["source_units"] as? [[String:Any]], let ranges=object["nonbillable_ranges"] as? [[String:Int]],
                                              let coverage=object["source_coverage"] as? [String:Any],
                                              pc.batch(seq:seq,confirmed:model.nativeOriginal.confirmed,units:units,ranges:ranges,coverage:coverage,negotiated:ready.sourcePunctV1 == true) else { model.failPunctReview(); await remote.cancel();return }
                                        verifier=pc.verifier;punct=pc
                                        model.disablePunctReview()
                                    } else { model.acceptSourceReviewBatch(event, reducer: &verifier) }
                                    guard verifier.reviewEnabled else { throw ManagedSpeechError.invalidResponse }
                                    for marker in verifier.acceptedMarkers { automatic.register(marker) }
                                    sourceVerifier = verifier; automaticState = automatic
                                }
                                #endif
                                if self.debugOldBatch == nil { self.debugOldBatch = (event, testGeneration, testSetup, epoch, before) }
                            }
                        }
                        self.recoverManagedConnection(generation: testGeneration, setupID: testSetup)
                    } catch { self.recoverManagedConnection(generation: testGeneration, setupID: testSetup) }
                }
                outcome = .success
            } catch { model.status = "测试连接失败" }
        }
    }
    /// Test hook: uses the production coordinator event fence and view but
    /// never starts system audio capture or contacts an external provider.
    func debugOpenNativeWithoutCapture(visible: Bool = false) {
        debugOpenWithoutCapture()
        if ProcessInfo.processInfo.environment["MORIQ_DIAGNOSTICS_TEST_FILE"] != nil { diagnosticCaptionSession = (UUID(), ProcessInfo.processInfo.systemUptime); diagnosticSessionID = UUID(); diagnosticEpochID = UUID() }
        guard let model = state else { return }
        model.managedSpeech = true; model.managedSpeechProvidesTranslation = true
        model.isCapturing = true; model.beginNativeCaption()
        debugNativeAccumulator = ManagedNativeLaneAccumulator()
        debugNativeSetupID = recognitionSetupID; debugNativeGeneration = generation
        if visible { panel?.setFrameOrigin(NSPoint(x: 150, y: 150)); panel?.orderFrontRegardless() }
    }
    func debugAcceptNative(_ event: ManagedSpeechEvent) throws -> Bool {
        guard let model = state else { return false }
        let epoch = debugNativeAccumulator.epoch
        return try consumeNativeLane(event, model: model, generation: debugNativeGeneration,
                                     setupID: debugNativeSetupID, epoch: epoch, accumulator: &debugNativeAccumulator)
    }
    func debugAcceptNativeBatch(_ event: ManagedSpeechEvent) throws -> Bool {
        guard let model = state else { return false }
        return try consumeNativeBatch(event, model: model, generation: debugNativeGeneration, setupID: debugNativeSetupID,
                                      epoch: debugNativeAccumulator.epoch, accumulator: &debugNativeAccumulator)
    }
    #if MORIQ_SOURCE_UNITS_V2_EXPERIMENTAL
    /// Only the local diagnostic installs this monitor. It is independent of
    /// receiving another message so a dropped final marker cannot go unnoticed.
    func debugMonitorSourceReview(_ remote: ManagedSpeechStream) {
        let expectedGeneration = debugNativeGeneration, expectedSetup = debugNativeSetupID
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let model = self.state,
                      ManagedSpeechEventFence.permits(generation: expectedGeneration, setup: expectedSetup,
                          currentGeneration: self.generation, currentSetup: self.recognitionSetupID,
                          sameModel: self.state === model, cancelled: Task.isCancelled) else { return }
                if !(await remote.debugSourceReviewHealthy()) {
                    guard ManagedSpeechEventFence.permits(generation: expectedGeneration, setup: expectedSetup,
                          currentGeneration: self.generation, currentSetup: self.recognitionSetupID,
                          sameModel: self.state === model, cancelled: Task.isCancelled) else { return }
                    model.debugSourceReviewStatus = "校订模拟不可用，字幕继续"
                    return
                }
            }
        }
    }
    #endif
    var debugNativeState: LiveCaptionState? { state }
    func debugHandleManagedQuota(_ event: ManagedSpeechEvent) -> Bool {
        guard let model = state else { return false }
        return handleManagedQuota(event, model: model)
    }
    var debugNativeWindowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }
    #endif
    /// Offscreen UI/lifecycle test hook. Never starts a stream or recognizer.
    func debugOpenWithoutCapture(mode: CaptionSessionMode = .captions) {
        stop(notify: false)
        let model = LiveCaptionState(); model.audioSource = .system; state = model
        showPanel(model, frame: NSRect(x: -3000, y: -3000, width: 620, height: 196))
    }
    /// Runs the same delayed retry gate with fake authorization and no audio.
    func debugScheduleManagedRetryWithoutCapture(_ restart: @escaping @MainActor () -> Void) {
        debugOpenWithoutCapture()
        guard let model = state else { return }
        scheduleManagedRetry(generation: generation, model: model, consent: { true }, permission: { true }, restart: restart)
    }
    var debugHasPanel: Bool { panel != nil }
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

#if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
/// Two independently paged streams. Proximity is a reading aid only: the
/// upstream translation has no token timestamps and is not sentence-paired.
private struct NativeCaptionPresentation: View {
    @ObservedObject var state: LiveCaptionState
    var body: some View {
        GeometryReader { geometry in
            Group {
                if state.showHistory { nativeHistory }
                else {
                    VStack(spacing: 4) {
                        #if DEBUG && MORIQ_SOURCE_UNITS_V2_EXPERIMENTAL
                        Text(state.debugSourceReviewStatus).font(.caption).foregroundStyle(.secondary)
                        #endif
                        if state.mode != "zh" || CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage) {
                            lane(.original, title: "原文", page: state.nativeOriginal)
                        }
                        if state.mode != "original" && !CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage) {
                            lane(.translation, title: "译文", page: state.nativeTranslation)
                        }
                        #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                        if state.reviewPanelExpanded && state.captionReviewAvailable < 28 {
                            Text("屏幕空间不足，无法显示校订").font(.caption).foregroundStyle(.secondary)
                        } else if !state.sourceReviewStatus.isEmpty {
                            Text(state.sourceReviewStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        #endif
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { resize(width: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in resize(width: width) }
            .onChange(of: state.fontSize) { _, _ in resize(width: geometry.size.width) }
        }
    }
    private func resize(width: CGFloat) {
        // Reserve the fixed label and navigation widths used by the lane.
        state.resizeNativePages(width: max(20, width - 96))
    }
    private func lane(_ lane: ManagedNativeLane, title: String, page: CaptionLanePages) -> some View {
        NativeCaptionLane(state: state, lane: lane, title: title, page: page)
    }
    private var nativeHistory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(state.nativeHistory) { epoch in
                    if epoch.isNotice { Text(epoch.original).foregroundStyle(.secondary) }
                    else {
                        historyLane("原文 · \(epoch.sourceLanguage)", epoch.original)
                        #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
                        historyLane("译文 · \(epoch.targetLanguage)", state.experimentalAutomaticMode ? "" : epoch.translation)
                        #else
                        historyLane("译文 · \(epoch.targetLanguage)", epoch.translation)
                        #endif
                    }
                }
                if state.nativeActive {
                    historyLane("原文 · 当前", state.nativeOriginal.confirmed)
                    #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
                    historyLane("译文 · 当前", state.experimentalAutomaticMode ? state.experimentalAutomaticText : state.nativeTranslation.confirmed)
                    #else
                    historyLane("译文 · 当前", state.nativeTranslation.confirmed)
                    #endif
                }
                if state.nativeHistory.isEmpty && state.nativeOriginal.confirmed.isEmpty && state.nativeTranslation.confirmed.isEmpty {
                    Text("暂无已确认的字幕").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }
    private func historyLane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    .buttonStyle(.plain).disabled(text.isEmpty)
            }
            Text(text.isEmpty ? "—" : text).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeCaptionLane: View {
    @ObservedObject var state: LiveCaptionState
    let lane: ManagedNativeLane
    let title: String
    let page: CaptionLanePages
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fittedFontSize: CGFloat {
        let mode = CaptionWindowSizing.effectiveMode(mode: state.mode, sameLanguage: CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage))
        let content = max(0, state.captionWindowAvailable - 66 - state.captionReviewAvailable)
        return CaptionWindowSizing.fittedFontSize(requested: state.fontSize, mode: mode, availableContent: content)
    }
    var body: some View {
        let shown = page.visible
        #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
        let displayed = lane == .translation && state.experimentalAutomaticMode ? state.experimentalAutomaticText : (page.followsLatest ? state.nativeDisplayText(lane) : shown)
        #else
        let displayed = page.followsLatest ? state.nativeDisplayText(lane) : shown
        #endif
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
                if lane == .translation && state.experimentalAutomaticMode && state.experimentalAutomaticFailure {
                    Text("部分译文暂不可用").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                }
                #endif
            }
            #if (MORIQ_AUTO_TRANSLATION_PRODUCT && MORIQ_NATIVE_TRANSLATION_PRODUCT) || (DEBUG && MORIQ_AUTO_TRANSLATION_EXPERIMENTAL)
            .frame(width: lane == .translation && state.experimentalAutomaticMode && state.experimentalAutomaticFailure ? 80 : 24, alignment: .leading)
            #else
            .frame(width: 24, alignment: .leading)
            #endif
            .padding(.top, 4)
            CaptionContinuousViewport(text: displayed,
                                      fontSize: lane == .original ? fittedFontSize : max(6, fittedFontSize - 2),
                                      reduceMotion: reduceMotion, followsLatest: page.followsLatest)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                 .accessibilityLabel("\(title)：\(displayed)")
            HStack(spacing: 4) {
                if page.hasPrevious || page.hasNext || !page.followsLatest {
                    Button { state.previousNativePage(lane) } label: { Image(systemName: "chevron.left") }
                        .disabled(!page.hasPrevious).help("上一页\(title)")
                    if !page.followsLatest {
                        Button { state.followNativePage(lane) } label: { Image(systemName: "arrow.down") }.help("回到实时\(title)")
                    }
                    Button { state.nextNativePage(lane) } label: { Image(systemName: "chevron.right") }
                        .disabled(!page.hasNext).help("下一页\(title)")
                }
            }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


/// TextKit performs the real wrapping. Only the visual viewport moves; the
/// underlying confirmed/provisional model and its complete history are kept.
private struct CaptionContinuousViewport: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let reduceMotion: Bool
    let followsLatest: Bool
    func makeNSView(context: Context) -> CaptionTextViewport { CaptionTextViewport() }
    func updateNSView(_ view: CaptionTextViewport, context: Context) {
        // Bound the amount of text laid out on each token; complete history
        // remains in the caption model and is accessible through history.
        view.update(text: String(text.suffix(2000)), fontSize: fontSize,
                    reduceMotion: reduceMotion, followsLatest: followsLatest)
    }
}

private final class CaptionTextViewport: NSView {
    override var isFlipped: Bool { true }
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var content = ""
    private var fontSize: CGFloat = 0
    private var reduceMotion = false
    private var followsLatest = true
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private var scheduler = CaptionScrollScheduler()
    private var layoutID: UInt64 = 0
    private var configuring = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder; scroll.contentView.drawsBackground = false
        scroll.contentView.wantsLayer = true
        textView.drawsBackground = false; textView.isEditable = false; textView.isSelectable = true
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero; textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView; addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); scroll.frame.origin = .zero; scroll.frame.size.width = bounds.width
        if scroll.frame.height == 0 { scroll.frame.size.height = bounds.height }
        guard !configuring, abs(bounds.width - lastWidth) > 0.5 || abs(bounds.height - lastHeight) > 0.5 else { return }
        render(textChanged: false, reflow: true)
    }
    func update(text: String, fontSize: CGFloat, reduceMotion: Bool, followsLatest: Bool) {
        let changed = content != text
        let reflow = self.fontSize != fontSize || self.followsLatest != followsLatest || self.reduceMotion != reduceMotion
        self.content = text; self.fontSize = fontSize; self.reduceMotion = reduceMotion; self.followsLatest = followsLatest
        guard changed || reflow || abs(bounds.width - lastWidth) > 0.5 else { return }
        render(textChanged: changed, reflow: reflow)
    }
    private func render(textChanged: Bool, reflow: Bool) {
        guard bounds.width > 1, fontSize > 0, let manager = textView.layoutManager,
              let container = textView.textContainer else { return }
        configuring = true; defer { configuring = false }
        let width = bounds.width; let geometryChanged = reflow || abs(lastWidth - width) > 0.5
        lastWidth = width; lastHeight = bounds.height
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if let storage = textView.textStorage {
            if geometryChanged {
                storage.setAttributedString(NSAttributedString(string: content, attributes: attributes))
            } else if storage.string != content {
                // Keep the confirmed prefix in place; only replace the draft
                // suffix. Walk Characters to avoid splitting Unicode graphemes.
                let old = storage.string
                var prefix = ""
                for (a, b) in zip(old, content) {
                    guard a == b else { break }; prefix.append(a)
                }
                let offset = prefix.utf16.count
                let suffix = String(content.dropFirst(prefix.count))
                storage.replaceCharacters(in: NSRange(location: offset, length: old.utf16.count - offset),
                                          with: NSAttributedString(string: suffix, attributes: attributes))
            }
        }
        textView.frame.size.width = width
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        var lines: [(NSRect, Int)] = []
        let glyphs = manager.glyphRange(for: container)
        if glyphs.length > 0 {
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
                lines.append((rect, manager.characterIndexForGlyph(at: range.location)))
            }
        }
        if let first = lines.first {
            scroll.frame.size.height = min(bounds.height, ceil(first.0.height * 2))
        }
        // Using the taller outer lane creates empty scrollable space below a
        // two-line document; AppKit can then auto-scroll that space into view
        // and clip the first line. Size to the clip and actual text instead.
        // TextKit may shorten the final fragment. Pad the document to a full
        // line so the last two-line anchor remains reachable without exposing
        // a clipped sliver of the preceding line.
        let fullLastLineBottom = lines.last.map { $0.0.minY + (lines.first?.0.height ?? $0.0.height) } ?? 0
        textView.frame.size.height = max(scroll.contentView.bounds.height, ceil(used.maxY), ceil(fullLastLineBottom))
        let maxY = max(0, textView.frame.height - scroll.contentView.bounds.height)
        let topLines = Array(lines.prefix(max(1, lines.count - 1)))
        let anchors = topLines.map { CaptionScrollScheduler.Anchor(id: String($0.1), y: Double(min(max(0, $0.0.minY), maxY))) }
        if geometryChanged { layoutID &+= 1 }
        let target = followsLatest ? anchors.last?.y ?? 0 : 0
        if scroll.contentView.bounds.minY > maxY {
            scroll.contentView.layer?.removeAllAnimations()
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: followsLatest ? target : maxY))
            if followsLatest { scheduler.resumeFollowing(viewportY: target) }
        }
        if geometryChanged {
            scroll.contentView.layer?.removeAllAnimations()
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
        }
        _ = scheduler.setReduceMotion(reduceMotion)
        if followsLatest != scheduler.followsLatest {
            if followsLatest { scheduler.resumeFollowing(viewportY: Double(scroll.contentView.bounds.minY)) }
            else { _ = scheduler.pauseFollowing() }
        }
        if scheduler.update(anchors: anchors, layoutID: layoutID, viewportY: Double(scroll.contentView.bounds.minY)) {
            scroll.contentView.layer?.removeAllAnimations()
            let corrected = followsLatest ? target : min(max(0, Double(scroll.contentView.bounds.minY)), Double(maxY))
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: corrected))
            if followsLatest { scheduler.resumeFollowing(viewportY: corrected) }
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        driveScroll()
    }
    private func driveScroll() {
        guard let action = scheduler.nextAction() else { return }
        #if MORIQ_CAPTION_DIAGNOSTICS
        print("SCROLL action", action.token, action.destinationY, action.duration); fflush(stdout)
        #endif
        let destination = NSPoint(x: 0, y: action.destinationY)
        if action.duration == 0 {
            scroll.contentView.setBoundsOrigin(destination)
            if scheduler.complete(token: action.token) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.05)) { [weak self] in self?.driveScroll() }
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = action.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scroll.contentView.animator().setBoundsOrigin(destination)
            } completionHandler: { [weak self] in
                guard let self else { return }
                let completed = self.scheduler.complete(token: action.token)
                #if MORIQ_CAPTION_DIAGNOSTICS
                print("SCROLL complete", action.token, completed); fflush(stdout)
                #endif
                guard completed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.driveScroll() }
            }
        }
    }
}

#endif

/// Explicit drag affordance for a borderless panel whose SwiftUI host may
/// consume background clicks. It occupies only the blank header spacer.
private struct CaptionPanelDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        private var dragMouseOrigin: NSPoint?
        private var dragWindowOrigin: NSPoint?
        override func mouseDown(with event: NSEvent) {
            dragMouseOrigin = window?.convertPoint(toScreen: event.locationInWindow)
            dragWindowOrigin = window?.frame.origin
        }
        override func mouseDragged(with event: NSEvent) {
            guard let mouseOrigin = dragMouseOrigin, let windowOrigin = dragWindowOrigin, let window else { return }
            let current = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: windowOrigin.x + current.x - mouseOrigin.x,
                                          y: windowOrigin.y + current.y - mouseOrigin.y))
        }
        override func mouseUp(with event: NSEvent) { dragMouseOrigin = nil; dragWindowOrigin = nil }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct LiveCaptionView: View {
    @ObservedObject var state: LiveCaptionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let close: () -> Void
    let installModel: () -> Void
    let changeLanguage: (String) -> Void
    let changeAudioSource: (CaptionAudioSource) -> Void
    var changeTargetLanguage: ((String) -> Void)? = nil
    @State private var configuration: TranslationSession.Configuration?
    @State private var debounce: Task<Void, Never>?
    @State private var translationInFlight = false
    @State private var translationSource = ""
    @State private var translationLanguage = ""
    @State private var translationSelection = ""
    @State private var translationTargetLanguage = ""
    @State private var translationRequestID = UUID()
    @State private var translationSegment = UUID()
    @State private var translationContext = UUID()
    #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
    @State private var translationIsPreview = false
    @State private var lastPreviewRequest = Date.distantPast
    #endif
    @State private var visibleOriginal = ""
    @State private var visibleTranslation = ""
    @State private var followingLiveCaption = true
    @State private var userIsScrollingCaptions = false
    @State private var lastFollowedContentHeight: CGFloat = 0
    #if DEBUG && MORIQ_CAPTION_REVIEW_EXPERIMENTAL
    @State private var showCaptionReviewDiagnostic = false
    #endif
    private var isCaptionReviewDiagnosticVisible: Bool {
        #if DEBUG && MORIQ_CAPTION_REVIEW_EXPERIMENTAL
        return showCaptionReviewDiagnostic
        #else
        return false
        #endif
    }
    private var languageName: String {
        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
        if state.experimentalAutomaticLanguage { return "自动" }
        #endif
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
    private var sourceMatchesTarget: Bool { CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage) }
    private var usesNativeCaptionPresentation: Bool {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        return state.nativePresentationSelected
        #else
        return false
        #endif
    }
    @ViewBuilder private var nativeCaptionPresentation: some View {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        NativeCaptionPresentation(state: state)
        #else
        EmptyView()
        #endif
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
                CaptionPanelDragHandle().frame(maxWidth: .infinity).frame(height: 26)
                if state.needsSpeechModel { Button("重试", action: installModel).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).help("重新启动字幕") }
                Menu {
                    Picker("语音语言", selection: $state.sourceLanguage) {
                        #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                        if ProcessInfo.processInfo.environment["MORIQ_AUTO_LANGUAGE_EXPERIMENTAL"] == "1" { Text("自动（实验）").tag("auto") }
                        #endif
                        Text("英语").tag("en-US"); Text("中文").tag("zh-CN"); Text("日语").tag("ja-JP"); Text("韩语").tag("ko-KR")
                    }
                    Picker("翻译语言", selection: $state.targetLanguage) { Text("中文").tag("zh-Hans"); Text("英语").tag("en-US") }
                } label: { HStack(spacing: 4) { Text("\(languageName) → \(targetLanguageName)"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择语音与翻译语言").accessibilityLabel("语音语言，\(languageName)，翻译语言，\(targetLanguageName)")
                Menu {
                    Picker("字幕模式", selection: $state.mode) { Text("双语").tag("bilingual"); Text("原文").tag("original"); Text("译文").tag("zh") }
                } label: { HStack(spacing: 4) { Text(modeName); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择字幕模式").accessibilityLabel("字幕模式，\(modeName)")
                Button {
                    state.showHistory.toggle()
                    #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                    if state.showHistory { state.reviewPanelExpanded = false }
                    #endif
                } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 22, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(state.showHistory ? Color.accentColor : Color.secondary).help("字幕记录").accessibilityLabel("字幕记录")
                #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                if state.reviewSource != nil, !state.showHistory,
                   let recipient = Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionReviewRecipient") as? String, !recipient.isEmpty,
                   CaptionReviewClient.configured(Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionReviewEndpoint"), enabled: true, tokenLoader: { nil }) != nil {
                    Button { state.reviewPanelExpanded.toggle() } label: { Image(systemName: "text.badge.checkmark").frame(width: 22, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(state.reviewPanelExpanded ? Color.accentColor : Color.secondary)
                        .help("字幕校订").accessibilityLabel(state.reviewPanelExpanded ? "收起字幕校订" : "展开字幕校订")
                }
                #endif
                #if DEBUG && MORIQ_CAPTION_REVIEW_EXPERIMENTAL
                Button("校订实验") { showCaptionReviewDiagnostic.toggle() }
                    .buttonStyle(.plain).help("打开仅使用模拟数据的校订实验")
                    .accessibilityIdentifier("caption-review-entry")
                #endif
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("停止字幕").accessibilityLabel("停止字幕")
            }
            .font(.system(size: 11, weight: .medium))
            .frame(height: 26)
            Color.clear.frame(height: 6)
            if isCaptionReviewDiagnosticVisible {
                #if DEBUG && MORIQ_CAPTION_REVIEW_EXPERIMENTAL
                ExperimentalCaptionReviewPanel { showCaptionReviewDiagnostic = false }
                #else
                EmptyView()
                #endif
            } else if usesNativeCaptionPresentation {
                VStack(spacing: 0) {
                    let actualMode = CaptionWindowSizing.effectiveMode(mode: state.mode, sameLanguage: CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage))
                    let availableContent = max(0, state.captionWindowAvailable - 66 - state.captionReviewAvailable)
                    if CaptionWindowSizing.canFit(mode: actualMode, availableContent: availableContent) {
                        nativeCaptionPresentation.frame(height: min(availableContent, CaptionWindowSizing.nativeHeight(fontSize: CaptionWindowSizing.fittedFontSize(requested: state.fontSize, mode: actualMode, availableContent: availableContent), mode: actualMode)))
                    } else {
                        Text("屏幕空间不足，无法显示字幕").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.5).frame(height: availableContent)
                    }
                    #if MORIQ_NATIVE_TRANSLATION_PRODUCT
                    if state.reviewPanelExpanded, state.captionReviewAvailable >= 28, let source = state.reviewSource,
                       let recipient = Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionReviewRecipient") as? String,
                       let client = CaptionReviewClient.configured(Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionReviewEndpoint"), enabled: true, tokenLoader: { try ManagedAIAccountToken().load() }) {
                        ScrollView {
                            CaptionReviewUserAction(source: source, target: state.targetLanguage, client: client, recipientDisclosure: recipient)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: CaptionReviewHeightKey.self, value: geometry.size.height)
                                    }
                                }
                        }
                        .frame(height: state.captionReviewAvailable)
                        .onPreferenceChange(CaptionReviewHeightKey.self) { value in
                            guard value > 0 else { return }
                            let measured = CaptionReviewLayoutPolicy.contentHeight(value)
                            if abs(state.reviewContentHeight - measured) > 0.5 { state.reviewContentHeight = measured }
                        }
                    }
                    #endif
                }
            } else if state.showHistory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.history) { item in
                            HStack {
                                Text((item.isIncomplete ? item.original + "（未完成）" : item.original) + (item.translated.isEmpty ? "" : "\n" + item.translated)).textSelection(.enabled)
                                Spacer()
                                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                                if state.experimentalCanSelectLanguage(item.id) {
                                    Menu {
                                        Button("英语") { state.recoverExperimentalLanguage(segment: item.id, language: "en-US") }
                                        Button("中文") { state.recoverExperimentalLanguage(segment: item.id, language: "zh-CN") }
                                        Button("日语") { state.recoverExperimentalLanguage(segment: item.id, language: "ja-JP") }
                                        Button("韩语") { state.recoverExperimentalLanguage(segment: item.id, language: "ko-KR") }
                                    } label: { Text(item.languageEvidenceBlocked ? "选择语言" : "更正语言") }
                                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("为此句选择语言")
                                    if let message = state.experimentalErrors[item.id] { Text(message).foregroundStyle(.secondary) }
                                }
                                #endif
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
                                    ForEach(Array(CaptionHistoryVisibility.lines(item, mode: state.mode).enumerated()), id: \.offset) { _, line in Text(line) }
                                }.font(.system(size: max(14, state.fontSize - 5))).foregroundStyle(.secondary.opacity(0.7))
                            }
                            VStack(spacing: 3) {
                                if state.original.isEmpty && state.unanchoredPreview.isEmpty {
                                    Text("等待语音").font(.system(size: 15)).foregroundStyle(.secondary)
                                } else if !state.original.isEmpty {
                                    if state.mode != "zh" || sourceMatchesTarget || state.languageEvidenceBlocked { Text(visibleOriginal).font(.system(size: state.fontSize, weight: .medium)).foregroundStyle(.primary) }
                                    if state.mode != "original" && !sourceMatchesTarget && !visibleTranslation.isEmpty { Text(visibleTranslation).font(.system(size: state.fontSize - 2)).foregroundStyle(.secondary) }
                                    #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                                    if state.mode != "original" && !state.experimentalPreviewTranslation.isEmpty {
                                        Text("译文预览 · " + state.experimentalPreviewTranslation).font(.system(size: state.fontSize - 2)).foregroundStyle(.secondary)
                                    }
                                    #endif
                                }
                                if !state.unanchoredPreview.isEmpty {
                                    Text(state.unanchoredPreview)
                                        .font(.system(size: state.fontSize - 2))
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("临时识别预览，尚未确认时间位置：\(state.unanchoredPreview)")
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
                    // Dissolve the clipped top edge of older lines rather than
                    // exposing fragments of glyphs as history scrolls away.
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.08), .init(color: .white, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
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
                    .onChange(of: state.segmentID) { _, nextSegment in
                        guard followingLiveCaption else { return }
                        Task { @MainActor in
                            // The new segment and its animated text do not reach
                            // layout on the same run-loop turn. Scrolling too
                            // early leaves the latest caption below the viewport.
                            // One bounded settle per segment avoids scrolling on
                            // every character while the user reads.
                            try? await Task.sleep(for: .milliseconds(220))
                            guard !Task.isCancelled, state.segmentID == nextSegment,
                                  followingLiveCaption, !userIsScrollingCaptions else { return }
                            if reduceMotion { scroll.scrollTo("current-caption", anchor: .bottom) }
                            else { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("current-caption", anchor: .bottom) } }
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
        }.padding(.horizontal, 18).padding(.vertical, 12).frame(width: 620).frame(maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            }
        .onChange(of: state.revision) { _, _ in scheduleTranslation() }
        .task(id: state.original) { await reveal(state.original, into: $visibleOriginal) }
        .task(id: state.translated) { await reveal(state.translated, into: $visibleTranslation) }
        .onChange(of: state.sourceLanguage) { _, value in changeLanguage(value); restartTranslation() }
        .onChange(of: state.targetLanguage) { _, value in changeTargetLanguage?(value); restartTranslation() }
        .onDisappear { debounce?.cancel(); debounce = nil }
        .translationTask(configuration) { session in
            guard state.usesLocalTranslation else { return }
            let source = translationSource, language = translationLanguage, selection = translationSelection, target = translationTargetLanguage, segment = translationSegment, request = translationRequestID, context = translationContext
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            let isPreview = translationIsPreview
            #endif
            var completed = false
            defer {
                if request == translationRequestID {
                    translationInFlight = false
                    #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                    let requestCurrent = isPreview ? state.experimentalPreviewIsCurrent(source: source, language: language, segment: segment, target: target, context: context) : context == state.translationContext
                    #else
                    let requestCurrent = context == state.translationContext
                    #endif
                    if state.mode != "original", (!requestCurrent ||
                       (completed && (state.original != source || state.segmentID != segment || state.history.contains(where: { !$0.isNotice && !$0.languageEvidenceBlocked && ($0.sourceLanguage == state.sourceLanguage || state.sourceLanguage == "auto") && $0.targetLanguage == state.targetLanguage && $0.translated.isEmpty && !CaptionLanguagePair.isSame($0.sourceLanguage, $0.targetLanguage) })))) { scheduleTranslation() }
                }
            }
            guard state.mode != "original", !source.isEmpty else { return }
            do {
                let result = try await session.translate(source)
                guard !Task.isCancelled, request == translationRequestID, state.mode != "original", state.sourceLanguage == selection, state.targetLanguage == target, !language.isEmpty, !result.targetText.isEmpty else { return }
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                if isPreview {
                    guard state.experimentalPreviewIsCurrent(source: source, language: language, segment: segment, target: target, context: context) else { return }
                    state.acceptExperimentalPreview(result.targetText, source: source, language: language, segment: segment, target: target, context: context); completed = true; return
                }
                #endif
                guard context == state.translationContext else { return }
                state.acceptTranslation(result.targetText, forOriginal: source, segment: segment, target: target, context: context); completed = true
            }
            catch {
                guard !Task.isCancelled, request == translationRequestID, context == state.translationContext, state.mode != "original", state.targetLanguage == target else { return }
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                if isPreview { return }
                if state.experimentalAutomaticLanguage {
                    state.experimentalTranslationFailed(segment: segment, target: target, context: context, message: "翻译失败，可更正语言后重试。")
                    return
                }
                #endif
                guard state.segmentID == segment, state.original.hasPrefix(source) else { return }
                state.status = "翻译不可用，请检查系统翻译语言包。"
            }
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
        if state.status == "语音与翻译语言相同，请选择不同语言。" {
            state.status = state.isCapturing ? "正在聆听\(state.audioSource.label)" : "准备中"
        }
        scheduleTranslation()
    }
    private func scheduleTranslation() {
        guard state.usesLocalTranslation else { return }
        guard state.mode != "original", !state.original.isEmpty else { return }
        if CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage) {
            state.clearTranslation(); return
        }
        guard debounce == nil, !translationInFlight else { return }
        debounce = Task { @MainActor in
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            try? await Task.sleep(for: .milliseconds(650))
            #else
            try? await Task.sleep(for: .milliseconds(500))
            #endif
            guard !Task.isCancelled, state.mode != "original", !state.original.isEmpty else { debounce = nil; return }
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            let elapsed = Date().timeIntervalSince(lastPreviewRequest)
            if elapsed < 1.2 {
                try? await Task.sleep(for: .milliseconds(Int((1.2 - elapsed) * 1000)))
                guard !Task.isCancelled, state.mode != "original", !state.original.isEmpty else { debounce = nil; return }
            }
            #endif
            let selection = state.sourceLanguage, targetID = state.targetLanguage
            var pending = state.history.first(where: { !$0.isNotice && !$0.languageEvidenceBlocked && $0.sourceLanguage == selection && $0.targetLanguage == targetID && $0.translated.isEmpty })
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            if state.experimentalAutomaticLanguage { pending = state.nextExperimentalTranslation(target: targetID) }
            let proposedPreview = pending == nil ? state.experimentalPreviewCandidate() : nil
            let preview: (text: String, language: String)? = proposedPreview.flatMap { candidate in
                // Keep a valid earlier translation while an extension settles;
                // do not repeatedly translate the same or a shorter prefix.
                if !state.experimentalPreviewTranslation.isEmpty && state.experimentalPreviewInput.hasPrefix(candidate.text) { return nil }
                return candidate
            }
            if state.experimentalAutomaticLanguage && pending == nil && preview == nil { debounce = nil; return }
            let language = preview?.language ?? pending?.sourceLanguage ?? selection
            #else
            let language = pending?.sourceLanguage ?? selection
            #endif
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            let previewSegment = state.segmentID
            let expectedContext = preview.map { state.beginExperimentalPreview(source: $0.text) } ?? state.translationContext
            #else
            let expectedContext = state.translationContext
            #endif
            let source = Locale.Language(identifier: language), target = Locale.Language(identifier: targetID)
            let available = await LanguageAvailability().status(from: source, to: target)
            debounce = nil
            guard !Task.isCancelled, state.sourceLanguage == selection, state.targetLanguage == targetID, state.mode != "original" else { return }
            #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
            if let preview {
                guard state.experimentalPreviewIsCurrent(source: preview.text, language: language, segment: previewSegment, target: targetID, context: expectedContext) else { scheduleTranslation(); return }
            } else { guard state.translationContext == expectedContext else { scheduleTranslation(); return } }
            #else
            guard state.translationContext == expectedContext else { return }
            #endif
            switch available {
            case .installed:
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                guard pending != nil || preview != nil || !state.languageEvidenceBlocked else { return }
                translationIsPreview = preview != nil
                if translationIsPreview { lastPreviewRequest = Date() }
                translationSource = pending?.original ?? preview?.text ?? state.translationSnapshot
                #else
                guard pending != nil || !state.languageEvidenceBlocked else { return }
                translationSource = pending?.original ?? state.translationSnapshot
                #endif
                guard !translationSource.isEmpty else { scheduleTranslation(); return }
                translationLanguage = language
                translationSelection = selection
                translationTargetLanguage = targetID
                translationSegment = pending?.id ?? state.segmentID
                translationContext = expectedContext
                translationRequestID = UUID()
                translationInFlight = true
                if configuration == nil { configuration = TranslationSession.Configuration(source: source, target: target) }
                else { configuration?.source = source; configuration?.target = target; configuration?.invalidate() }
            case .supported:
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                if preview != nil { return }
                if state.experimentalAutomaticLanguage, let pending { state.experimentalTranslationFailed(segment: pending.id, target: targetID, context: expectedContext, message: "请先下载对应翻译语言包。") }
                else { state.status = "请在系统设置中下载对应翻译语言包。" }
                #else
                state.status = "请在系统设置中下载对应翻译语言包。"
                #endif
            case .unsupported:
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                if preview != nil { return }
                if state.experimentalAutomaticLanguage, let pending { state.experimentalTranslationFailed(segment: pending.id, target: targetID, context: expectedContext, message: "系统不支持此语言组合。") }
                else { state.status = "系统不支持此语言组合。" }
                #else
                state.status = "系统不支持此语言组合。"
                #endif
            @unknown default:
                configuration = nil
                #if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
                if preview != nil { return }
                if state.experimentalAutomaticLanguage, let pending { state.experimentalTranslationFailed(segment: pending.id, target: targetID, context: expectedContext, message: "无法检查语言包，请重试。") }
                else { state.status = "无法检查翻译语言包。" }
                #else
                state.status = "无法检查翻译语言包。"
                #endif
            }
        }
    }
}

#if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
/// Developer-only UI harness. Never starts capture or configures a service.
@MainActor func debugExperimentalCaptionView(_ model: LiveCaptionState, close: @escaping () -> Void = {}, changeLanguage: @escaping (String) -> Void = { _ in }) -> NSView {
    NSHostingView(rootView: LiveCaptionView(state: model, close: close, installModel: {}, changeLanguage: changeLanguage, changeAudioSource: { _ in }))
}
#endif

#if DEBUG && MORIQ_CAPTION_REVIEW_EXPERIMENTAL
/// Developer-only host used to verify the actual toolbar entry.
@MainActor func debugCaptionReviewHost(_ model: LiveCaptionState) -> NSView {
    NSHostingView(rootView: LiveCaptionView(state: model, close: {}, installModel: {}, changeLanguage: { _ in }, changeAudioSource: { _ in }))
}
#endif

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
    static let state = PermissionProbeState()
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
