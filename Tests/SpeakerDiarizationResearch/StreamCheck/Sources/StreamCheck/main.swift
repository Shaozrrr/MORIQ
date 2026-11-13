import Foundation
import AVFoundation
import FluidAudio

@main struct Main {
 static func main() async throws {
   let input = URL(fileURLWithPath:CommandLine.arguments[1])
   let file = try AVAudioFile(forReading:input)
   let format = file.processingFormat
   precondition(format.channelCount == 1 && format.sampleRate == 16000)
   let model = try await SortformerModels.loadFromHuggingFace(config:.default, computeUnits:.cpuOnly)
   let diarizer = SortformerDiarizer(config:.default)
   diarizer.initialize(models:model)
   let buf = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1600)!
   var updates = 0
   let clock = ContinuousClock.now
   while file.framePosition < file.length {
     try file.read(into:buf,frameCount:1600)
     guard let channel = buf.floatChannelData?[0] else { fatalError("requires float") }
     let samples = Array(UnsafeBufferPointer(start:channel,count:Int(buf.frameLength)))
     if try diarizer.process(samples:samples,sourceSampleRate:format.sampleRate) != nil { updates += 1 }
   }
   _ = try diarizer.finalizeSession()
   print("updates=\(updates), elapsed=\(clock.duration(to:.now))")
   for (index, speaker) in diarizer.timeline.speakers.sorted(by:{$0.key < $1.key}) {
     for seg in speaker.finalizedSegments { print("\(index) \(seg.startTime) \(seg.endTime)") }
   }
 }
}
