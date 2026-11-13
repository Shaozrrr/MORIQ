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
  precondition(CaptionAudioSource.allCases == [.system])
  precondition(CaptionAudioSource.system.accepts(.audio) && !CaptionAudioSource.system.accepts(.microphone))
  let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/LiveCaptionsSystemAudio/synthetic.wav")
  let asset=AVURLAsset(url:source)
  guard let track=try await asset.loadTracks(withMediaType:.audio).first else { fatalError("fixture missing") }
  let reader=try AVAssetReader(asset:asset)
  let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsNonInterleaved:false])
  reader.add(output); precondition(reader.startReading())
  var samples:[CMSampleBuffer]=[]
  while let sample=output.copyNextSampleBuffer() { samples.append(sample) }
  precondition(reader.status == .completed && !samples.isEmpty)
  let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
  guard let display=content.displays.first else { print("BLOCKED no display available"); exit(2) }
  let filter=SCContentFilter(display:display,excludingWindows:[])
  let config=SCStreamConfiguration(); config.capturesAudio=false; if #available(macOS 15, *) { config.captureMicrophone=false }
  // Construct only: neither real system audio nor a microphone is captured.
  let old=SCStream(filter:filter,configuration:config,delegate:nil)
  let active=SCStream(filter:filter,configuration:config,delegate:nil)
  let sink=LiveCaptionAudioSink(), counter=Counter(), sample=samples[0]
  sink.selectSource(.system,stream:active); sink.setWhisper { _ in counter.add() }
  sink.stream(old,didOutputSampleBuffer:sample,of:.audio)
  sink.stream(active,didOutputSampleBuffer:sample,of:.microphone)
  sink.stream(active,didOutputSampleBuffer:sample,of:.audio)
  precondition(counter.get()==1,"stale or microphone buffers must be rejected")
  DispatchQueue.concurrentPerform(iterations:10_000) { index in
   sink.stream(index % 2 == 0 ? active : old,didOutputSampleBuffer:sample,of:.audio)
  }
  precondition(counter.get()==5001,"concurrent routing mismatch")
  let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
  let result=Recognition()
  let engine=try LocalWhisperCaptionEngine(helper:base.appendingPathComponent("Vendor/SpeechEngine/moriq-speech"),model:base.appendingPathComponent("Vendor/SpeechEngine/ggml-base.bin"),language:"en",onText:{ text,_ in result.update(text) },onError:{ result.error($0) })
  sink.setWhisper { [weak engine] sample in engine?.append(sample) }
  for sample in samples { sink.stream(active,didOutputSampleBuffer:sample,of:.audio) }
  let deadline=Date().addingTimeInterval(20)
  while !result.status().0 && result.status().1 == nil && Date() < deadline { try await Task.sleep(for:.milliseconds(50)) }
  let status=result.status(); sink.clear(); engine.stop()
  precondition(status.0 && status.1 == nil,"synthetic system audio recognition failed")
  let stopped=Counter(); sink.setWhisper { _ in stopped.add() }
  sink.stream(active,didOutputSampleBuffer:sample,of:.audio)
  precondition(stopped.get()==0,"stopped stream must reject buffers")
  print("PASS system-only audio routing, microphone rejection, stale-stream isolation and synthetic recognition")
 }
}
