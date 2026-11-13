import Foundation
let args=CommandLine.arguments
precondition(args.count==3,"provide helper and public Mandarin wav")
let helper=URL(fileURLWithPath:args[1]), model=URL(fileURLWithPath:"Vendor/SpeechEngine/ggml-base.bin").standardizedFileURL
let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"Vendor/MediaEngine/ffmpeg").standardizedFileURL
p.arguments=["-v","error","-i",args[2],"-t","10","-ar","16000","-ac","1","-f","f32le","-"]
p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
try p.run();let audio=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();precondition(p.terminationStatus==0 && audio.count>0)
final class Results:@unchecked Sendable {let lock=NSLock();var windows:[WhisperTimedWindow]=[];var texts:[String]=[];var error:String?;func add(_ w:WhisperTimedWindow){lock.lock();windows.append(w);lock.unlock()};func addText(_ text:String){lock.lock();texts.append(text);lock.unlock()};func fail(_ e:String){lock.lock();error=e;lock.unlock()};func snap()->([WhisperTimedWindow],[String],String?){lock.lock();defer{lock.unlock()};return(windows,texts,error)}}
let results=Results()
let engine=try LocalWhisperCaptionEngine(helper:helper,model:model,language:"zh",onText:{t,_ in results.addText(t)},onError:{results.fail($0)},onTimedWords:{results.add($0)})
var sent=0
while sent<audio.count {let end=min(sent+16_000,audio.count);engine.appendSyntheticPCM(audio.subdata(in:sent..<end));sent=end;Thread.sleep(forTimeInterval:0.005)}
let deadline=Date().addingTimeInterval(30)
while Date()<deadline {let x=results.snap();if x.0.contains(where:{!$0.words.isEmpty}) && !x.1.isEmpty {break};if x.2 != nil {break};Thread.sleep(forTimeInterval:0.05)}
let (windows,texts,error)=results.snap();precondition(error == nil && !texts.isEmpty && windows.contains(where:{!$0.words.isEmpty}),"missing Mandarin text or timing records")
let words=windows.flatMap(\.words)
precondition(words.contains(where:{$0.text.unicodeScalars.contains(where:{(0x4E00...0x9FFF).contains($0.value)})}),"no CJK text span")
for w in windows {precondition(w.startSample>=0 && w.endSample<=Int64(audio.count/4));for x in w.words {precondition(x.startSample>=w.startSample && x.endSample<=w.endSample && x.endSample>x.startSample)}}
engine.stop()
print("PASS public Mandarin audio through helper + Swift bridge: \(windows.count) windows, \(words.count) measured token spans")
print("Not a word segmentation or timing accuracy evaluation")
