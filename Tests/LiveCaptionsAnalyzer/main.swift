import Foundation
import AVFoundation
import Speech
@main struct Test {
 static func main() async throws {
  guard #available(macOS 26, *) else { print("SKIP: SpeechAnalyzer requires macOS 26"); return }
  guard CommandLine.arguments.count == 2 else { print("usage: test synthetic-audio.aiff"); exit(2) }
  guard SFSpeechRecognizer.authorizationStatus() == .authorized else { print("SKIP: speech authorization not granted; no prompt requested"); return }
  guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { print("SKIP: on-device analyzer unavailable"); return }
  let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
  guard await AssetInventory.status(forModules: [transcriber]) == .installed else { print("SKIP: progressive English asset not installed; no download requested"); return }
  let audio = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
  let analyzer = SpeechAnalyzer(modules: [transcriber])
  let began = Date()
  let results = Task { () throws -> (String, Double?, Int) in
    var final = "", first: Double?, revisions = 0
    for try await result in transcriber.results {
      if first == nil { first = Date().timeIntervalSince(began) }
      if result.isFinal { final += String(result.text.characters) + " " } else { revisions += 1 }
    }
    return (final, first, revisions)
  }
  try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
  let (text, first, revisions) = try await results.value
  let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
  let matches = words.filter { ["meeting", "project", "timeline"].contains($0) }.count
  guard !words.isEmpty, matches > 0 else { print("FAIL: no expected synthetic keywords"); exit(1) }
  print("PASS synthetic analyzer words=\(words.count) keywords=\(matches) firstResult=\(first ?? -1)s partials=\(revisions)")
 }
}
