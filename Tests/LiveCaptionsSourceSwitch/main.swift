import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

final class Counter: @unchecked Sendable {
 private let lock=NSLock(); private var value=0
 func add() { lock.lock(); value += 1; lock.unlock() }
 func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
final class Recognition: @unchecked Sendable {
 private let lock=NSLock(); private var matched=false; private var failure: String?
 func update(_ text:String) { lock.lock(); if text.lowercased().contains("meeting") { matched=true }; lock.unlock() }
 func error(_ message:String) { lock.lock(); failure=message; lock.unlock() }
 func status() -> (Bool,String?) { lock.lock(); defer { lock.unlock() }; return (matched,failure) }
}
@main struct Check {
 static func main() async throws {
  precondition(CaptionMicrophoneDevicePolicy.decide(configured:"input-a",current:"input-a") == .unchanged)
  precondition(CaptionMicrophoneDevicePolicy.decide(configured:"input-a",current:"input-b") == .changed)
  precondition(CaptionMicrophoneDevicePolicy.decide(configured:"input-a",current:nil) == .unavailable)
  precondition(CaptionMicrophoneDevicePolicy.decide(configured:"input-a",current:"") == .unavailable)
  let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/LiveCaptionsSystemAudio/synthetic.wav")
  let asset=AVURLAsset(url:source)
  guard let track=try await asset.loadTracks(withMediaType:.audio).first else { fatalError("fixture missing") }
  let reader=try AVAssetReader(asset:asset)
  let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsNonInterleaved:false])
  reader.add(output); precondition(reader.startReading())
  guard let sample=output.copyNextSampleBuffer(), sample.isValid else { fatalError("synthetic sample missing") }
  var samples=[sample]
  while let next=output.copyNextSampleBuffer() { samples.append(next) }
  precondition(reader.status == .completed)
  let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
  guard let display=content.displays.first else { print("BLOCKED no display available"); exit(2) }
  let filter=SCContentFilter(display:display,excludingWindows:[])
  let config=SCStreamConfiguration(); config.capturesAudio=false; if #available(macOS 15, *) { config.captureMicrophone=false }
  // Construct only: no stream is started, no system or microphone audio is collected.
  let old=SCStream(filter:filter,configuration:config,delegate:nil)
  let middle=SCStream(filter:filter,configuration:config,delegate:nil)
  let newest=SCStream(filter:filter,configuration:config,delegate:nil)
  let sink=LiveCaptionAudioSink(), counter=Counter()
  sink.setWhisper { _ in counter.add() }
  sink.selectSource(.system,stream:old)
  sink.stream(old,didOutputSampleBuffer:sample,of:.audio)
  sink.stream(old,didOutputSampleBuffer:sample,of:.microphone)
  sink.stream(newest,didOutputSampleBuffer:sample,of:.audio)
  precondition(counter.get()==1,"wrong source or stream accepted")
  sink.selectSource(.microphone,stream:middle)
  sink.stream(old,didOutputSampleBuffer:sample,of:.audio)
  sink.stream(middle,didOutputSampleBuffer:sample,of:.audio)
  sink.stream(middle,didOutputSampleBuffer:sample,of:.microphone)
  precondition(counter.get()==2,"microphone routing or stale stream failed")
  sink.selectSource(.system,stream:newest)
  sink.stream(old,didOutputSampleBuffer:sample,of:.audio)
  sink.stream(middle,didOutputSampleBuffer:sample,of:.microphone)
  sink.stream(newest,didOutputSampleBuffer:sample,of:.audio)
  precondition(counter.get()==3,"stale system/microphone frames crossed sessions")
  DispatchQueue.concurrentPerform(iterations:10_000) { index in
   sink.stream(index % 2 == 0 ? newest : old, didOutputSampleBuffer:sample,of:.audio)
  }
  precondition(counter.get()==5003,"concurrent routing mismatch")
  sink.clear(); sink.stream(newest,didOutputSampleBuffer:sample,of:.audio)
  precondition(counter.get()==5003,"stop did not clear routing")
  let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
  for (source, stream, type) in [(CaptionAudioSource.system,old,SCStreamOutputType.audio),(.microphone,middle,.microphone),(.system,newest,.audio)] {
   let result=Recognition()
   let engine=try LocalWhisperCaptionEngine(helper:base.appendingPathComponent("Vendor/SpeechEngine/moriq-speech"),model:base.appendingPathComponent("Vendor/SpeechEngine/ggml-base.bin"),language:"en",onText:{ text,_ in result.update(text) },onError:{ result.error($0) })
   sink.selectSource(source,stream:stream); sink.setWhisper { [weak engine] sample in engine?.append(sample) }
   for sample in samples { sink.stream(stream,didOutputSampleBuffer:sample,of:type) }
   let deadline=Date().addingTimeInterval(20)
   while !result.status().0 && result.status().1 == nil && Date() < deadline { try await Task.sleep(for:.milliseconds(50)) }
   let status=result.status(); sink.clear(); engine.stop()
   precondition(status.0 && status.1 == nil,"synthetic recognition failed after source switch")
  }
  print("PASS synthetic source switching, default device policy, stale stream rejection, 10000 concurrent callbacks and stop")
 }
}
