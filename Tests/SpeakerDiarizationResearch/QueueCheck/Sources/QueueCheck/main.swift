import Foundation
import AVFoundation
import FluidAudio

enum Work { case reset(Int), audio(Int,[Float]), finish(Int), cancel }
// Research only: one worker owns inference and producers never block on it.
final class PCMWorker: @unchecked Sendable {
 let condition = NSCondition(), queue = DispatchQueue(label:"research.diarization.worker")
 let models: SortformerModels, limit: Int, done = DispatchSemaphore(value:0)
 var work:[Work] = [], pending = 0, generation = 0, closed = false, accepted = 0, discarded = 0
 var output:[(Int,Double,Double)] = []
 var failure: String?
 func failed() -> Bool { condition.lock(); defer { condition.unlock() }; return failure != nil }
 init(_ models:SortformerModels, limit:Int = 32) { self.models = models; self.limit = limit; queue.async { [self] in run() } }
 func switchSource() -> Int {
  condition.lock(); defer { condition.unlock() }; precondition(!closed)
  generation += 1; discarded += pending; pending = 0; work.removeAll(); work.append(.reset(generation)); output.removeAll(); condition.signal(); return generation
 }
 func submit(_ data:[Float], generation g:Int) -> Bool {
  condition.lock(); defer { condition.unlock() }; guard !closed,g == generation,pending < limit else { return false }
  work.append(.audio(g,data)); pending += 1; accepted += 1; condition.signal(); return true
 }
 func finish(_ g:Int) { condition.lock(); defer { condition.unlock() }; guard !closed,g == generation else { return }; closed = true; work.append(.finish(g)); condition.signal() }
 func cancel() { condition.lock(); defer { condition.unlock() }; if !closed { closed = true; discarded += pending; pending = 0; work = [.cancel]; condition.signal() } }
 func wait() -> ([(Int,Double,Double)],Int,Int) { done.wait(); condition.lock(); defer { condition.unlock() }; return (output,accepted,discarded) }
 func run() {
  defer { done.signal() }; var active:SortformerDiarizer?
  while true {
   condition.lock(); while work.isEmpty { condition.wait() }; let item = work.removeFirst(); if case .audio = item { pending -= 1 }; let current = generation; condition.unlock()
   do { switch item {
   case .reset(let g): guard g == current else { continue }; let d = SortformerDiarizer(config:.default); d.initialize(models:models); active = d
   case .audio(let g,let samples): guard g == current,let active else { continue }; _ = try active.process(samples:samples,sourceSampleRate:16000)
   case .finish(let g): guard g == current,let active else { return }; _ = try active.finalizeSession(); let segments = active.timeline.speakers.flatMap { index,speaker in speaker.finalizedSegments.map { (index,Double($0.startTime),Double($0.endTime)) } }; condition.lock(); if generation == g { output = segments }; condition.unlock(); return
   case .cancel: active = nil; return
   }} catch { condition.lock(); failure = String(describing:error); closed = true; work.removeAll(); pending = 0; condition.unlock(); return }
  }
 }
}
@main struct Main {
 static func main() async throws {
  let file = try AVAudioFile(forReading:URL(fileURLWithPath:CommandLine.arguments[1])); precondition(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16000)
  let models = try await SortformerModels.loadFromHuggingFace(config:.default,computeUnits:.cpuOnly)
  let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:1600)!; var chunks:[[Float]] = []
  while file.framePosition < file.length { try file.read(into:buffer,frameCount:1600); guard let p = buffer.floatChannelData?[0] else { fatalError("requires float") }; chunks.append(Array(UnsafeBufferPointer(start:p,count:Int(buffer.frameLength)))) }
  let w = PCMWorker(models); let old = w.switchSource(); for c in chunks.prefix(25) { _ = w.submit(c,generation:old) }; let current = w.switchSource(); precondition(!w.submit(chunks[0],generation:old))
  for c in chunks { while !w.submit(c,generation:current) { if w.failed() { fatalError("worker failed") }; try await Task.sleep(for:.milliseconds(5)) } }; w.finish(current); let result = w.wait(); precondition(!w.failed())
  if CommandLine.arguments.count > 2 {
   let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
   let root = try JSONSerialization.jsonObject(with:data) as! [String:Any]
   let entries = root["segments"] as! [[String:Any]]
   let expected = entries.map { ($0["speakerIndex"] as! Int, $0["startTimeSeconds"] as! Double, $0["endTimeSeconds"] as! Double) }.sorted { $0.1 < $1.1 }
   let actual = result.0.sorted { $0.1 < $1.1 }
   precondition(expected.count == actual.count)
   for (x,y) in zip(expected,actual) { precondition(x.0 == y.0 && abs(x.1-y.1)<0.01 && abs(x.2-y.2)<0.01) }
  }
  print("segments=\(result.0.count) accepted=\(result.1) discardedOld=\(result.2)")
  for (s,a,b) in result.0.sorted(by:{$0.1 < $1.1}) { print("\(s) \(a) \(b)") }
  let cancelled = PCMWorker(models); let g = cancelled.switchSource(); for c in chunks.prefix(10) { _ = cancelled.submit(c,generation:g) }; cancelled.cancel(); let r = cancelled.wait(); precondition(r.0.isEmpty && !cancelled.submit(chunks[0],generation:g)); print("PASS generation switch, bounded queue, end and cancel")
 }
}
