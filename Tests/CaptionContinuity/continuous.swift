import Foundation
import SwiftUI
@main struct Probe: App {
 @StateObject var state = LiveCaptionState()
 var body: some Scene { WindowGroup { LiveCaptionView(state: state, close: {}, installModel: {}, changeLanguage: { _ in }, changeAudioSource: { _ in }).task {
  var sawTranslationDuringUpdates = false
  let sentence = "The meeting starts at three o'clock this afternoon and the team will review our progress together before discussing the schedule for next week."
  let words = sentence.split(separator: " ")
  for i in 1...words.count {
   state.accept(words.prefix(i).joined(separator: " "))
   if !state.translated.isEmpty { sawTranslationDuringUpdates = true }
   try? await Task.sleep(for: .milliseconds(180))
  }
  for _ in 0..<200 { if state.isTranslationCurrent { break }; try? await Task.sleep(for: .milliseconds(100)) }
  guard sawTranslationDuringUpdates, state.isTranslationCurrent else { print("FAIL streaming translation: updated=\(sawTranslationDuringUpdates), current=\(state.isTranslationCurrent), status=\(state.status)"); fflush(stdout); exit(1) }
  let translation = state.translated
  guard translation.contains("会"), translation.contains("三") || translation.contains("3"), translation.contains("下午") else {
   print("FAIL: translation missed meeting or afternoon time"); fflush(stdout); exit(1)
  }
  print("PASS translated during continuous input and reached final sentence"); fflush(stdout); exit(0)
 } } }
}
