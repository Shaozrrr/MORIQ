import Foundation
import SwiftUI
@main struct Probe: App {
 @StateObject var state = LiveCaptionState()
 var body: some Scene { WindowGroup { LiveCaptionView(state: state, close: {}, installModel: {}, changeLanguage: { _ in }, changeAudioSource: { _ in }).task {
  for (language, sentence) in [("ja-JP", "会議は今日の午後三時に始まります。"),("ko-KR", "회의는 오늘 오후 세 시에 시작합니다.")] {
   state.sourceLanguage = language; state.accept(sentence, final: true)
   for _ in 0..<200 { if state.isTranslationCurrent { break }; try? await Task.sleep(for: .milliseconds(100)) }
   guard !state.translated.isEmpty, state.translated != sentence else { print("FAIL \(language): \(state.status)"); fflush(stdout); exit(1) }
   print("PASS \(language): \(state.translated)"); fflush(stdout)
  }
  exit(0)
 } } }
}
