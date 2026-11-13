import Foundation
let args=CommandLine.arguments
precondition(args.count==6,"speaker helper, model, whisper helper, public wav, reference JSON required")
let speakerHelper=URL(fileURLWithPath:args[1]), speakerModel=URL(fileURLWithPath:args[2]), whisperHelper=URL(fileURLWithPath:args[3])
let p=Process(), pipe=Pipe();p.executableURL=URL(fileURLWithPath:"Vendor/MediaEngine/ffmpeg").standardizedFileURL
p.arguments=["-v","error","-i",args[4],"-ar","16000","-ac","1","-f","f32le","-"];p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
try p.run();let audio=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();precondition(p.terminationStatus==0 && !audio.isEmpty)
final class Results:@unchecked Sendable {let lock=NSLock();var updates:[Int64:CaptionAttributedWindow]=[:];var accepted:Int64=0;var errors:[String]=[];func add(_ x:CaptionAttributedWindow){lock.lock();updates[x.window.startSample]=x;lock.unlock()};func pcm(_ n:Int64){lock.lock();accepted=n;lock.unlock()};func fail(_ x:String){lock.lock();errors.append(x);lock.unlock()};func snap()->([CaptionAttributedWindow],Int64,[String]){lock.lock();defer{lock.unlock()};return(Array(updates.values),accepted,errors)}}
let result=Results()
let pipeline=try CaptionSpeakerPipeline(helper:speakerHelper,model:speakerModel,minimumCoverage:0.7,maximumCompetition:0.2,onUpdate:{result.add($0)})
let engine=try LocalWhisperCaptionEngine(helper:whisperHelper,model:URL(fileURLWithPath:"Vendor/SpeechEngine/ggml-base.bin").standardizedFileURL,language:"en",onText:{_,_ in},onError:{result.fail($0)},onTimedWords:{pipeline.accept($0)},onAcceptedPCM:{data,offset,_ in if pipeline.appendPCM(data,offset:offset){result.pcm(offset+Int64(data.count/4))}else{result.fail("pipeline rejected PCM")}})
var sent=0
while sent<audio.count {let end=min(sent+12800,audio.count);engine.appendSyntheticPCM(audio.subdata(in:sent..<end));sent=end;Thread.sleep(forTimeInterval:0.03)}
let acceptedDeadline=Date().addingTimeInterval(90)
while result.snap().1<Int64(audio.count/4) && result.snap().2.isEmpty && Date()<acceptedDeadline {Thread.sleep(forTimeInterval:0.1)}
let accepted=result.snap().1;precondition(result.snap().2.isEmpty && accepted==Int64(audio.count/4),"all audio must be accepted")
pipeline.finish()
let deadline=Date().addingTimeInterval(80)
while Date()<deadline {let x=result.snap(); let speakers=Set(x.0.flatMap{$0.words.compactMap(\.speakerID)});if speakers.count>=2 && x.0.contains(where:{$0.window.isFinal}) {break};Thread.sleep(forTimeInterval:0.1)}
let (updates,_,errors)=result.snap();let final=updates.filter{$0.window.isFinal};let speakers=Set(final.flatMap{$0.words.compactMap(\.speakerID)});let assigned=final.flatMap(\.words).filter{$0.speakerID != nil}.count
precondition(errors.isEmpty && speakers.count>=2 && assigned>0,"real diarizer/ASR did not align two speakers")
print("PASS public two-speaker bridge: accepted_samples=\(accepted) final_windows=\(final.count) assigned_words=\(assigned) distinct_anonymous_speakers=\(speakers.count)")
struct Reference: Decodable { let speaker:String; let start:Double; let end:Double }
let refs=try JSONDecoder().decode([Reference].self,from:Data(contentsOf:URL(fileURLWithPath:args[5])))
var counts:[String:[String:Int]]=[:];var unmatched=0
for word in final.flatMap(\.words) { let midpoint=Double(word.word.range.start+word.word.range.end)/32000
 guard let ref=refs.first(where:{midpoint >= $0.start && midpoint < $0.end}) else {continue}
 guard let speaker=word.speakerID else {unmatched+=1;continue}
 counts[speaker,default:[:]][ref.speaker,default:0]+=1
}
print("SPEAKER_COUNTS \(counts) unknown_words=\(unmatched)")
print("NOTE counts reflect clip-level reference and overlapping-window candidates, not word-level truth, DER, or name accuracy")
engine.stop();pipeline.stop()
