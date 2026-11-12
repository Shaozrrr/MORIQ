import Foundation
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-local-whisper-test-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let model = URL(fileURLWithPath: "/tmp/moriq-whisper-models/ggml-base.bin")
let helper = URL(fileURLWithPath: "Vendor/SpeechEngine/moriq-speech").standardizedFileURL
precondition(LocalWhisperModel.valid(model), "synthetic test model checksum must match official model")
let corrupt = root.appendingPathComponent("bad.bin"); try Data("bad".utf8).write(to: corrupt)
precondition(!LocalWhisperModel.valid(corrupt))
let ffmpeg = URL(fileURLWithPath: "Vendor/MediaEngine/ffmpeg").standardizedFileURL
let generate = Process(); generate.executableURL = ffmpeg
let pipe = Pipe(); generate.standardOutput = pipe; generate.standardError = FileHandle.nullDevice
generate.arguments = ["-nostdin","-v","error","-i","/tmp/moriq-whisper-models/synthetic10.wav","-ac","1","-ar","16000","-f","f32le","-"]
try generate.run(); let audio = pipe.fileHandleForReading.readDataToEndOfFile(); generate.waitUntilExit(); precondition(generate.terminationStatus == 0)
final class Results: @unchecked Sendable {
 let lock = NSLock(); var text = "", final = false, error: String?
 func append(_ value: String, _ isFinal: Bool) { lock.lock(); text += value; final = final || isFinal; lock.unlock() }
 func fail(_ value: String) { lock.lock(); error = value; lock.unlock() }
 func snapshot() -> (String,Bool,String?) { lock.lock(); defer { lock.unlock() }; return (text,final,error) }
}
let result = Results()
let engine = try LocalWhisperCaptionEngine(helper: helper, model: model, language: "en", onText: { result.append($0,$1) }, onError: { result.fail($0) })
var offset = 0
while offset < audio.count {
 let end = min(offset + 16_000, audio.count); engine.appendSyntheticPCM(audio.subdata(in: offset..<end)); offset = end
 Thread.sleep(forTimeInterval: 0.005)
}
let deadline = Date().addingTimeInterval(25)
while !result.snapshot().1 && result.snapshot().2 == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
let values = result.snapshot()
precondition(values.2 == nil && values.1 && values.0.lowercased().contains("meeting"), "synthetic speech did not reach final caption")
engine.stop()
let stopDeadline = Date().addingTimeInterval(3)
while engine.debugIsRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
precondition(!engine.debugIsRunning, "helper survived stop")
let badHelper = root.appendingPathComponent("fail-helper")
try Data("#!/bin/sh\nexit 7\n".utf8).write(to: badHelper); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: badHelper.path)
let failure = Results()
let failed = try LocalWhisperCaptionEngine(helper: badHelper, model: model, language: "en", onText: { failure.append($0,$1) }, onError: { failure.fail($0) })
let failureDeadline = Date().addingTimeInterval(3)
while failure.snapshot().2 == nil && Date() < failureDeadline { Thread.sleep(forTimeInterval: 0.02) }
precondition(failure.snapshot().2 != nil, "helper exit was not reported")
failed.stop()
print("PASS synthetic PCM → helper → caption, checksum, process stop and helper failure")
