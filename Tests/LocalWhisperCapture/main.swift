import Foundation
import AVFoundation
import CoreMedia
let fixture = URL(fileURLWithPath: "/tmp/moriq-whisper-models/synthetic10.wav")
let helper = URL(fileURLWithPath: "Vendor/SpeechEngine/moriq-speech").standardizedFileURL
let model = URL(fileURLWithPath: "/tmp/moriq-whisper-models/ggml-base.bin")
let asset = AVURLAsset(url: fixture)
guard let track = asset.tracks(withMediaType: .audio).first else { fatalError("no fixture track") }
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
reader.add(output); precondition(reader.startReading())
final class Result: @unchecked Sendable {
 let lock = NSLock(); var text = "", done = false, error: String?
 func update(_ value: String,_ final: Bool) { lock.lock(); text += value; done = done || final; lock.unlock() }
 func fail(_ value: String) { lock.lock(); error = value; lock.unlock() }
 func get() -> (String,Bool,String?) { lock.lock(); defer { lock.unlock() }; return (text,done,error) }
}
let result = Result()
let engine = try LocalWhisperCaptionEngine(helper: helper, model: model, language: "en", onText: { result.update($0,$1) }, onError: { result.fail($0) })
var count = 0
while let sample = output.copyNextSampleBuffer() { engine.append(sample); count += 1; Thread.sleep(forTimeInterval: 0.001) }
precondition(reader.status == .completed && count > 0)
let deadline = Date().addingTimeInterval(25)
while !result.get().1 && result.get().2 == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
let current = result.get(); precondition(current.2 == nil && current.1 && current.0.lowercased().contains("meeting"), "sample conversion did not produce captions")
engine.stop()
print("PASS synthetic file → CMSampleBuffer → resample → stdin → local caption")
