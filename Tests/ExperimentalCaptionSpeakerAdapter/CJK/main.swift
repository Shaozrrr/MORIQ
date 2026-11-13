import Foundation
let args=CommandLine.arguments
precondition(args.count==5,"speaker helper, speaker model, whisper helper, public four-speaker Mandarin WAV required")
let speakerHelper=URL(fileURLWithPath:args[1]),speakerModel=URL(fileURLWithPath:args[2]),whisperHelper=URL(fileURLWithPath:args[3])
let whisperModel=URL(fileURLWithPath:"Vendor/SpeechEngine/ggml-base.bin").standardizedFileURL
let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"Vendor/MediaEngine/ffmpeg").standardizedFileURL
p.arguments=["-v","error","-i",args[4],"-ar","16000","-ac","1","-f","f32le","-"];p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
try p.run();let audio=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();precondition(p.terminationStatus==0 && audio.count>0)
final class Results:@unchecked Sendable {
 let lock=NSLock();var updates:[Int64:CaptionAttributedWindow]=[:];var samples:Int64=0;var errors:[String]=[]
 var captureStart:TimeInterval=0;var firstText:TimeInterval?;var firstAssigned:TimeInterval?;var firstAssignedRelativeLatency:Double?;var latestUpdate:TimeInterval=0
 func start(){lock.lock();captureStart=ProcessInfo.processInfo.systemUptime;lock.unlock()}
 func text(_ value:String){guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return};lock.lock();if firstText == nil && captureStart>0 {firstText=ProcessInfo.processInfo.systemUptime-captureStart};lock.unlock()}
 func add(_ value:CaptionAttributedWindow){let now=ProcessInfo.processInfo.systemUptime;lock.lock();updates[value.window.startSample]=value;latestUpdate=now
  if firstAssigned == nil, captureStart>0, let word=value.words.first(where:{$0.speakerID != nil}) { firstAssigned=now-captureStart;firstAssignedRelativeLatency=now-captureStart-Double(word.word.range.end)/16000 }
  lock.unlock()}
 func accepted(_ n:Int64){lock.lock();samples=n;lock.unlock()};func fail(_ e:String){lock.lock();errors.append(e);lock.unlock()}
 func snap()->([CaptionAttributedWindow],Int64,[String],Double?,Double?,Double?,Double){lock.lock();defer{lock.unlock()};return(Array(updates.values),samples,errors,firstText,firstAssigned,firstAssignedRelativeLatency,latestUpdate)}
}
let r=Results()
let adapter=try ExperimentalCaptionSpeakerAdapter.make(environment:["MORIQ_EXPERIMENTAL_SPEAKER":"1"],whisperHelper:whisperHelper,whisperModel:whisperModel,speakerHelper:speakerHelper,speakerModel:speakerModel,language:"zh-CN",minimumCoverage:0.7,maximumCompetition:0.2,onText:{text,_ in r.text(text)},onUpdate:{r.add($0)},onError:{r.fail($0)},onAcceptedSamples:{r.accepted($0)})!
r.start()
// Pace 0.2-second chunks against monotonic time. No audio devices are opened.
let origin=ProcessInfo.processInfo.systemUptime
for offset in stride(from:0,to:audio.count,by:12_800) {
 let deadline=origin+Double(offset/4)/16000
 let delay=deadline-ProcessInfo.processInfo.systemUptime
 if delay>0 {Thread.sleep(forTimeInterval:delay)}
 adapter.appendTestPCM(audio.subdata(in:offset..<min(offset+12_800,audio.count)))
}
let acceptedDeadline=Date().addingTimeInterval(90)
while r.snap().1<Int64(audio.count/4) && r.snap().2.isEmpty && Date()<acceptedDeadline {Thread.sleep(forTimeInterval:0.1)}
precondition(r.snap().1==Int64(audio.count/4) && r.snap().2.isEmpty,"PCM not fully accepted")
adapter.finishSpeakerInput()
let finalDeadline=Date().addingTimeInterval(90)
while Date()<finalDeadline {
 let s=r.snap();let final=s.0.filter{$0.window.isFinal};let assigned=final.flatMap(\.words).filter{$0.speakerID != nil}.count
 if assigned>0 && final.count>=6 && s.6>0 && ProcessInfo.processInfo.systemUptime-s.6>2 {break}
 if !s.2.isEmpty {break};Thread.sleep(forTimeInterval:0.1)
}
let s=r.snap();let final=s.0.filter{$0.window.isFinal};let words=final.flatMap(\.words)
let attributed=words.filter{$0.speakerID != nil},unknown=words.filter{$0.speakerID == nil}
precondition(s.2.isEmpty && !attributed.isEmpty && s.3 != nil && s.4 != nil && s.5 != nil,"missing Chinese text or finalized attribution")
let ids=Set(attributed.compactMap(\.speakerID))
print("PASS real-time-paced public Mandarin: samples=\(s.1), final_windows=\(final.count), spans=\(words.count), attributed=\(attributed.count), unknown=\(unknown.count), IDs=\(ids.count)")
print(String(format:"first_text_from_start=%.2fs first_attribution_from_start=%.2fs first_attributed_span_after_audio_end=%.2fs",s.3!,s.4!,s.5!))
print("NOTE counts are overlapping token candidates, not identity correctness/DER; latency is one paced run, not a benchmark distribution")
adapter.stop()
