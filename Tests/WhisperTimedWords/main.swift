import Foundation
let helper = URL(fileURLWithPath: CommandLine.arguments[1])
let model = URL(fileURLWithPath: "Vendor/SpeechEngine/ggml-base.bin").standardizedFileURL
let ffmpeg = URL(fileURLWithPath: "Vendor/MediaEngine/ffmpeg").standardizedFileURL
let p = Process(), pipe = Pipe(); p.executableURL = ffmpeg
p.arguments = ["-v", "error", "-i", "/tmp/moriq-human-benchmark/0.wav", "-ar", "16000", "-ac", "1", "-f", "f32le", "-"]
p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
try p.run(); let audio = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); precondition(p.terminationStatus == 0 && !audio.isEmpty)
final class Results: @unchecked Sendable {
 let lock = NSLock(); var windows:[WhisperTimedWindow] = []; var offsets:[(Int64,Int)] = []; var error:String?
 func add(_ value:WhisperTimedWindow) { lock.lock(); windows.append(value); lock.unlock() }
 func pcm(_ data:Data,_ at:Int64,_ pts:Double?) { lock.lock(); precondition(pts == nil); offsets.append((at,data.count/4)); lock.unlock() }
 func fail(_ text:String) { lock.lock(); error=text; lock.unlock() }
 func snapshot()->([WhisperTimedWindow],[(Int64,Int)],String?) { lock.lock(); defer { lock.unlock() }; return(windows,offsets,error) }
}
let result=Results()
let engine=try LocalWhisperCaptionEngine(helper:helper,model:model,language:"en",onText:{_,_ in},onError:{result.fail($0)},onTimedWords:{result.add($0)},onAcceptedPCM:{result.pcm($0,$1,$2)})
var sent=0
while sent<audio.count { let end=min(sent+16_000,audio.count); engine.appendSyntheticPCM(audio.subdata(in:sent..<end)); sent=end; Thread.sleep(forTimeInterval:0.005) }
let deadline=Date().addingTimeInterval(25)
while result.snapshot().0.filter({ !$0.words.isEmpty }).count<2 && result.snapshot().2 == nil && Date()<deadline { Thread.sleep(forTimeInterval:0.05) }
let (windows,offsets,error)=result.snapshot(); precondition(error == nil && windows.filter({ !$0.words.isEmpty }).count>=2,"real timing output missing")
var cursor:Int64=0
for (offset,count) in offsets { precondition(offset == cursor,"PCM clock gap"); cursor += Int64(count) }
for window in windows { precondition(window.startSample>=0 && window.endSample<=Int64(audio.count/4)); for word in window.words { precondition(word.startSample>=window.startSample && word.endSample<=window.endSample && word.endSample>word.startSample) } }
engine.stop()
let overflow=Results()
let overflowEngine=try LocalWhisperCaptionEngine(helper:helper,model:model,language:"en",onText:{_,_ in},onError:{overflow.fail($0)},onTimedWords:{overflow.add($0)},onAcceptedPCM:{overflow.pcm($0,$1,$2)})
overflowEngine.appendSyntheticPCM(Data(count:1_048_580))
let overflowDeadline=Date().addingTimeInterval(3)
while overflow.snapshot().2 == nil && Date()<overflowDeadline { Thread.sleep(forTimeInterval:0.01) }
precondition(overflow.snapshot().2 != nil && overflow.snapshot().1.isEmpty,"overflow must stop without forwarding unmatched PCM")
overflowEngine.stop()
print("PASS public speech timing callbacks, contiguous PCM clock and bounded word windows")
