import Foundation
import Speech
let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-caption-synthetic-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let audio = root.appendingPathComponent("speech.aiff")
let sentence = "The meeting starts at nine. Please review the project timeline. "
let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
say.arguments = ["-v", "Samantha", "-r", "180", "-o", audio.path, String(repeating: sentence, count: 20)]
say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
try say.run(); say.waitUntilExit(); precondition(say.terminationStatus == 0)
let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
precondition(size > 100_000)
print("PASS synthetic spoken English fixture created locally (20 repeated sentences)")
guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
    print("SKIP on-device recognition: speech permission not previously granted; no permission requested")
    exit(0)
}
guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
    print("SKIP on-device recognition: English local speech model unavailable")
    exit(0)
}
let request = SFSpeechURLRecognitionRequest(url: audio); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
let done = DispatchSemaphore(value: 0), lock = NSLock()
var final = "", failure: Error?
let task = recognizer.recognitionTask(with: request) { result, error in
    if let result, result.isFinal { lock.lock(); final = result.bestTranscription.formattedString; lock.unlock(); done.signal() }
    else if let error { lock.lock(); failure = error; lock.unlock(); done.signal() }
}
guard done.wait(timeout: .now() + 60) == .success else { task.cancel(); print("FAIL on-device recognition timed out"); exit(1) }
lock.lock(); let text = final, error = failure; lock.unlock()
guard error == nil, !text.isEmpty else { print("FAIL on-device recognition unavailable"); exit(1) }
let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
let matches = tokens.filter { ["meeting", "project", "timeline"].contains($0) }.count
print("PASS local on-device recognition produced \(tokens.count) words; reference keywords matched \(matches) times")
