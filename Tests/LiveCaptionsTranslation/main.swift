import Foundation
import SwiftUI
@main struct Probe: App {
 @StateObject var state = LiveCaptionState()
 var body: some Scene { WindowGroup { LiveCaptionView(state: state, close: {}, installModel: {}, changeLanguage: { _ in }, changeAudioSource: { _ in }).task {
  state.accept("The meeting starts at three o'clock this afternoon.", final: true)
  for _ in 0..<200 { if state.isTranslationCurrent { break }; try? await Task.sleep(for: .milliseconds(100)) }
  guard !state.translated.isEmpty, state.translated != state.original, state.history.last?.translated == state.translated else { print("FAIL translation: \(state.translated), status: \(state.status)"); fflush(stdout); exit(1) }
  print("PASS bilingual: \(state.translated)")
  state.mode = "original"
  try? await Task.sleep(for: .seconds(1))
  guard state.translated.isEmpty else { print("FAIL original mode"); fflush(stdout); exit(1) }
  state.mode = "zh"
  for _ in 0..<200 { if state.isTranslationCurrent { break }; try? await Task.sleep(for: .milliseconds(100)) }
  guard !state.translated.isEmpty else { print("FAIL Chinese mode: \(state.status)"); fflush(stdout); exit(1) }
  print("PASS original and Chinese modes: \(state.translated)")
  state.accept("Please send me the report tomorrow.", final: true)
  for _ in 0..<200 { if state.isTranslationCurrent { break }; try? await Task.sleep(for: .milliseconds(100)) }
  guard !state.translated.isEmpty, state.translated != state.original, state.history.last?.translated == state.translated else { print("FAIL subsequent caption: \(state.status)"); fflush(stdout); exit(1) }
  print("PASS subsequent caption: \(state.translated)")
  state.accept("Today is Monday.")
  try? await Task.sleep(for: .milliseconds(100))
  state.accept("Today is Friday.", final: true)
  for _ in 0..<200 { if state.isTranslationCurrent { break }; try? await Task.sleep(for: .milliseconds(100)) }
  guard state.translated.contains("五"), !state.translated.contains("一"), state.history.last?.translated == state.translated else { print("FAIL latest revision: \(state.translated)"); fflush(stdout); exit(1) }
  print("PASS rapid changes use latest caption: \(state.translated)"); fflush(stdout); exit(0)
 } } }
}
