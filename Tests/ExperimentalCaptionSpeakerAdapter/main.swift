import Foundation

let args = CommandLine.arguments
precondition(args.count == 5, "speaker helper, speaker model, whisper helper, public WAV")
let speakerHelper = URL(fileURLWithPath: args[1]), speakerModel = URL(fileURLWithPath: args[2]), whisperHelper = URL(fileURLWithPath: args[3])
let whisperModel = URL(fileURLWithPath: "Vendor/SpeechEngine/ggml-base.bin").standardizedFileURL
let ffmpeg = Process(), pipe = Pipe()
ffmpeg.executableURL = URL(fileURLWithPath: "Vendor/MediaEngine/ffmpeg").standardizedFileURL
ffmpeg.arguments = ["-v", "error", "-i", args[4], "-ar", "16000", "-ac", "1", "-f", "f32le", "-"]
ffmpeg.standardOutput = pipe; ffmpeg.standardError = FileHandle.nullDevice
try ffmpeg.run(); let audio = pipe.fileHandleForReading.readDataToEndOfFile(); ffmpeg.waitUntilExit()
precondition(ffmpeg.terminationStatus == 0 && !audio.isEmpty)
final class Results: @unchecked Sendable {
    let lock = NSLock(); var updates: [Int64: CaptionAttributedWindow] = [:]; var samples: Int64 = 0; var errors: [String] = []
    func add(_ value: CaptionAttributedWindow) { lock.lock(); updates[value.window.startSample] = value; lock.unlock() }
    func accepted(_ n: Int64) { lock.lock(); samples = n; lock.unlock() }
    func fail(_ s: String) { lock.lock(); errors.append(s); lock.unlock() }
    func snapshot() -> ([CaptionAttributedWindow], Int64, [String]) { lock.lock(); defer { lock.unlock() }; return (Array(updates.values), samples, errors) }
}
let results = Results()
func create(_ env: [String: String], _ language: String) throws -> ExperimentalCaptionSpeakerAdapter? {
    try ExperimentalCaptionSpeakerAdapter.make(environment: env, whisperHelper: whisperHelper, whisperModel: whisperModel,
        speakerHelper: speakerHelper, speakerModel: speakerModel, language: language, minimumCoverage: 0.7, maximumCompetition: 0.2,
        onText: { _,_ in }, onUpdate: { results.add($0) }, onError: { results.fail($0) }, onAcceptedSamples: { results.accepted($0) })
}
let disabled = try create([:], "en")
precondition(disabled == nil, "opt in is required")
do { _ = try create(["MORIQ_EXPERIMENTAL_SPEAKER": "1"], "zh"); fatalError("unsupported language accepted") }
catch ExperimentalCaptionSpeakerAdapter.SetupError.unsupportedLanguage { }
guard let adapter = try create(["MORIQ_EXPERIMENTAL_SPEAKER": "1"], "en") else { fatalError("missing adapter") }
for offset in stride(from: 0, to: audio.count, by: 12800) {
    adapter.appendTestPCM(audio.subdata(in: offset..<min(offset + 12800, audio.count)))
    Thread.sleep(forTimeInterval: 0.03)
}
let acceptedDeadline = Date().addingTimeInterval(90)
while results.snapshot().1 < Int64(audio.count / 4) && results.snapshot().2.isEmpty && Date() < acceptedDeadline { Thread.sleep(forTimeInterval: 0.1) }
precondition(results.snapshot().1 == Int64(audio.count / 4) && results.snapshot().2.isEmpty)
adapter.finishSpeakerInput()
let deadline = Date().addingTimeInterval(90)
while Date() < deadline {
    let snap = results.snapshot()
    if Set(snap.0.flatMap { $0.words.compactMap(\.speakerID) }).count >= 2 && snap.0.contains(where: { $0.window.isFinal }) { break }
    if !snap.2.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.1)
}
let snap = results.snapshot()
let final = snap.0.filter { $0.window.isFinal }
let assigned = final.flatMap(\.words).filter { $0.speakerID != nil }.count
let speakerCount = Set(final.flatMap { $0.words.compactMap(\.speakerID) }).count
precondition(snap.2.isEmpty && assigned > 0 && speakerCount >= 2)
adapter.stop()
print("PASS explicit debug opt-in, English-only adapter, real ASR and diarization: samples=\(snap.1), assigned=\(assigned), speakers=\(speakerCount)")
