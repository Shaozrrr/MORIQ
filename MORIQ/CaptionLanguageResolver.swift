import Foundation
#if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
import NaturalLanguage
#endif

/// Experimental, sentence-scoped policy. It does not infer audio language,
/// download models, call Translation, or change the user's selection.
struct CaptionTextLanguageGuess {
    let language: String
    let confidence: Double
    let runnerUpConfidence: Double
}

enum CaptionLanguageSelection { case manual(String), automatic }
enum CaptionManualEvidence: Equatable { case unavailable, consistent, conflicting, mixedOrUnsupported }
enum CaptionUnresolvedReason: Equatable {
    case awaitingFinal, insufficientText, mixed, missingEvidence, malformedEvidence
    case ambiguousScript, weakTextEvidence, conflictingEvidence
}
enum CaptionLanguageResolution: Equatable {
    case manual(language: String, evidence: CaptionManualEvidence)
    case candidate(language: String, evidence: String)
    case unsupported(language: String)
    case unresolved(CaptionUnresolvedReason)
}

/// Opaque identifiers must change when the session, sentence, or request
/// generation changes. The consumer must recheck the entire context before
/// using an asynchronously produced result.
struct CaptionLanguageContext: Equatable {
    let session: UUID
    let segment: UUID
    let generation: UUID
    let sourceSelection: String
    let target: String
}
struct CaptionBoundLanguageResolution: Equatable {
    let context: CaptionLanguageContext
    let resolution: CaptionLanguageResolution
    func isCurrent(_ current: CaptionLanguageContext) -> Bool { context == current }
}

struct CaptionLanguageResolver {
    typealias TextDetector = (String) -> CaptionTextLanguageGuess?
    private let detector: TextDetector?
    private let supported = Set(["en", "zh", "ja", "ko"])

    init(detector: TextDetector? = nil) { self.detector = detector }

    func resolveBound(context: CaptionLanguageContext, selection: CaptionLanguageSelection,
                      text: String, isFinal: Bool, providerLabels: [String]?) -> CaptionBoundLanguageResolution {
        let matchesSource: Bool
        switch selection {
        case .automatic: matchesSource = context.sourceSelection == "auto"
        case .manual(let selected): matchesSource = context.sourceSelection == selected
        }
        guard matchesSource else { return CaptionBoundLanguageResolution(context: context, resolution: .unresolved(.conflictingEvidence)) }
        return CaptionBoundLanguageResolution(context: context, resolution: resolve(selection: selection, text: text, isFinal: isFinal, providerLabels: providerLabels))
    }

    /// Provider languages are hints only. A candidate is not proof of the
    /// speech language or a guarantee that a particular translation pair is
    /// supported by the local Translation framework.
    func resolve(selection: CaptionLanguageSelection, text: String, isFinal: Bool,
                 providerLabels: [String]?) -> CaptionLanguageResolution {
        if case .manual(let selected) = selection {
            guard let selectedBase = Self.base(selected) else { return .unresolved(.malformedEvidence) }
            guard supported.contains(selectedBase) else { return .unsupported(language: selected) }
            // A user's explicit selection remains unchanged; conflicting final
            // evidence is surfaced separately, never used to override it.
            guard isFinal, let labels = providerLabels, !labels.isEmpty else {
                return .manual(language: selected, evidence: .unavailable)
            }
            let bases = labels.compactMap(Self.base)
            guard bases.count == labels.count else { return .manual(language: selected, evidence: .mixedOrUnsupported) }
            let distinct = Set(bases)
            guard distinct.count == 1, let label = distinct.first, supported.contains(label) else {
                return .manual(language: selected, evidence: .mixedOrUnsupported)
            }
            return .manual(language: selected, evidence: label == selectedBase ? .consistent : .conflicting)
        }
        // No interim label or detector result becomes an automatic choice.
        guard isFinal else { return .unresolved(.awaitingFinal) }
        let script = Self.scriptEvidence(text)
        if script.mixed { return .unresolved(.mixed) }
        guard script.longEnough else { return .unresolved(.insufficientText) }
        if let labels = providerLabels, !labels.isEmpty {
            let bases = labels.compactMap(Self.base)
            guard bases.count == labels.count else { return .unresolved(.malformedEvidence) }
            let distinct = Set(bases)
            guard distinct.count == 1, let language = distinct.first else { return .unresolved(.mixed) }
            guard supported.contains(language) else { return .unsupported(language: language) }
            guard script.compatible(with: language) else { return .unresolved(.conflictingEvidence) }
            guard !(language == "ja" && script.han > 0 && script.kana == 0) else { return .unresolved(.ambiguousScript) }
            if let detector {
                guard let guess = detector(text) else { return .unresolved(.missingEvidence) }
                guard Self.strong(guess) else { return .unresolved(.weakTextEvidence) }
                guard let textLanguage = Self.base(guess.language) else { return .unresolved(.malformedEvidence) }
                guard textLanguage == language else { return .unresolved(.conflictingEvidence) }
                return .candidate(language: language, evidence: "provider_and_text")
            }
            return .candidate(language: language, evidence: "provider_final")
        }
        guard let guess = detector?(text) else { return .unresolved(.missingEvidence) }
        guard Self.strong(guess) else {
            return .unresolved(.weakTextEvidence)
        }
        guard let language = Self.base(guess.language) else { return .unresolved(.malformedEvidence) }
        guard supported.contains(language) else { return .unsupported(language: language) }
        guard script.compatible(with: language) else { return .unresolved(.conflictingEvidence) }
        guard !(language == "ja" && script.han > 0 && script.kana == 0) else { return .unresolved(.ambiguousScript) }
        return .candidate(language: language, evidence: "text_detector")
    }

    /// Shared guard before invoking any experimental text classifier. Script
    /// mixing and very short snippets must never become confident guesses.
    static func permitsDetectorText(_ text: String) -> Bool {
        let evidence = scriptEvidence(text)
        return evidence.longEnough && !evidence.mixed
    }

    // Provisional safety heuristics, not calibrated confidence guarantees;
    // calibrate against representative speech transcripts before release.
    private static func strong(_ guess: CaptionTextLanguageGuess) -> Bool {
        guess.confidence.isFinite && guess.runnerUpConfidence.isFinite &&
        (0...1).contains(guess.confidence) && (0...1).contains(guess.runnerUpConfidence) &&
        guess.confidence >= 0.95 && guess.confidence - guess.runnerUpConfidence >= 0.20
    }

    private static func base(_ label: String) -> String? {
        let normalized = label.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.utf8.count),
              first.utf8.allSatisfy({ (97...122).contains($0) }),
              parts.dropFirst().allSatisfy({ (2...8).contains($0.utf8.count) && $0.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) }) else { return nil }
        return String(first)
    }

    private struct ScriptEvidence {
        var han = 0, kana = 0, hangul = 0, latin = 0
        var mixed: Bool { (han + kana + hangul) > 0 && latin >= 2 || (kana > 0 && hangul > 0) }
        var longEnough: Bool { (han + kana + hangul) >= 4 || latin >= 12 }
        func compatible(with language: String) -> Bool {
            switch language {
            case "en": return latin >= 12 && han == 0 && kana == 0 && hangul == 0
            case "zh": return han >= 4 && kana == 0 && hangul == 0 && latin < 2
            case "ja": return han + kana >= 4 && hangul == 0 && latin < 2
            case "ko": return hangul >= 4 && kana == 0 && latin < 2
            default: return false
            }
        }
    }
    private static func scriptEvidence(_ text: String) -> ScriptEvidence {
        var result = ScriptEvidence()
        for scalar in text.unicodeScalars {
            let c = scalar.value
            if (0x3400...0x4DBF).contains(c) || (0x4E00...0x9FFF).contains(c) || (0x20000...0x2FA1F).contains(c) { result.han += 1 }
            else if (0x3040...0x30FF).contains(c) { result.kana += 1 }
            else if (0xAC00...0xD7AF).contains(c) || (0x1100...0x11FF).contains(c) { result.hangul += 1 }
            else if (65...90).contains(c) || (97...122).contains(c) { result.latin += 1 }
        }
        return result
    }
}

#if DEBUG && MORIQ_AUTO_LANGUAGE_EXPERIMENTAL
/// Developer-only candidate source. Scores are model heuristics, not
/// calibrated probabilities or proof of the language of the recorded audio.
/// The resolver independently checks script, supported labels, provider
/// conflicts, finality, and its provisional confidence/margin thresholds.
enum CaptionNaturalLanguageDetector {
    static func detect(_ text: String) -> CaptionTextLanguageGuess? {
        guard CaptionLanguageResolver.permitsDetectorText(text) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
            .sorted { $0.value > $1.value }
        guard hypotheses.count >= 2, let first = hypotheses.first else { return nil }
        return CaptionTextLanguageGuess(language: first.key.rawValue,
            confidence: first.value, runnerUpConfidence: hypotheses[1].value)
    }
}
#endif
