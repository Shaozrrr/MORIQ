import AVFoundation
import Speech
import Foundation
MainActor.assumeIsolated {
    precondition(CaptionAudioAuthorizationPolicy.decide(previouslyVerified: false, screenAllowed: true, result: .silent) == .needsAudio)
    precondition(CaptionAudioAuthorizationPolicy.decide(previouslyVerified: false, screenAllowed: true, result: .audioObserved) == .confirmed)
    precondition(CaptionAudioAuthorizationPolicy.decide(previouslyVerified: true, screenAllowed: true, result: .silent) == .previouslyVerifiedSilent)
    precondition(CaptionAudioAuthorizationPolicy.decide(previouslyVerified: true, screenAllowed: true, result: .failed) == .unavailable)
    precondition(CaptionAudioAuthorizationPolicy.decide(previouslyVerified: true, screenAllowed: false, result: .audioObserved) == .unavailable)
    let state = LiveCaptionState()
    precondition(state.mode == "bilingual" && state.sourceLanguage == "en-US" && !state.isCapturing)
    state.accept("First sentence", final: true)
    let first = state.revision
    state.accept("Second sentence", final: true)
    state.acceptTranslation("旧译文", revision: first)
    precondition(state.translated.isEmpty && state.history.count == 2)
    state.acceptTranslation("第二句", revision: state.revision)
    precondition(state.history.last?.translated == "第二句")
    state.accept("Second sentence", final: true); precondition(state.history.count == 2)
    state.accept("unfinished at restart"); state.accept(state.original, final: true)
    precondition(state.history.last?.original == "unfinished at restart")
    for index in 0..<40 { state.accept("fixture \(index)", final: true) }
    precondition(state.history.count == 30)
    state.clearCurrent(); precondition(state.original.isEmpty && state.history.count == 30)
    state.reset(); precondition(state.history.isEmpty && !state.isCapturing)
    print("PASS caption state bounded history, final deduplication and stale translation rejection")
}
