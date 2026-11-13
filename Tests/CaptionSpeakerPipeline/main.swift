import Foundation
let root=FileManager.default.temporaryDirectory.appendingPathComponent("moriq-pipeline-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
func helper(_ source:String)throws->URL { let url=root.appendingPathComponent(UUID().uuidString);try source.write(to:url,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url }
let script = """
#!/usr/bin/python3
import sys, time
sys.stdin.buffer.read(4)
print('{"type":"turns","turns":[{"speaker":1,"startSample":0,"endSample":16000,"final":false}]}',flush=True)
time.sleep(.12)
print('{"type":"turns","turns":[{"speaker":1,"startSample":0,"endSample":16000,"final":true}]}',flush=True)
time.sleep(1.8)
print('{"type":"failed"}',flush=True)
"""
final class Results: @unchecked Sendable { let lock=NSLock(); var list:[CaptionAttributedWindow]=[]; func add(_ item:CaptionAttributedWindow){lock.lock();list.append(item);lock.unlock()}; func snapshot()->[CaptionAttributedWindow]{lock.lock();defer{lock.unlock()};return list} }
let results=Results(), generation=UUID()
let pipeline=try CaptionSpeakerPipeline(helper:helper(script),model:root,generation:generation,minimumCoverage:0.7,maximumCompetition:0.2,onUpdate:{results.add($0)})
let word=WhisperTimedWord(text:" hello",startSample:0,endSample:1600)
let win=WhisperTimedWindow(startSample:0,endSample:16000,isFinal:true,words:[word])
precondition(pipeline.appendPCM(Data(count:64_000),offset:0)); pipeline.accept(win)
let deadline=Date().addingTimeInterval(4)
while Date()<deadline {let x=results.snapshot(); if x.contains(where:{$0.words.first?.speakerID == "1"}) && x.contains(where:{!$0.diarizationAvailable}) {break};Thread.sleep(forTimeInterval:0.01)}
let events=results.snapshot()
precondition(events.allSatisfy{$0.generation==generation})
precondition(events.contains(where:{$0.diarizationAvailable && $0.words.first?.speakerID == nil}),"pending must be unknown")
precondition(events.contains(where:{$0.words.first?.speakerID == "1"}),"late final turn must update")
precondition(events.last?.diarizationAvailable == false && events.last?.words.first?.speakerID == nil,"failure must clear assignments")
pipeline.stop()
let before=results.snapshot().count;pipeline.accept(win);Thread.sleep(forTimeInterval:0.15);precondition(results.snapshot().count == before,"stopped generation emitted")
let other=Results()
let gapPipeline=try CaptionSpeakerPipeline(helper:helper(script),model:root,minimumCoverage:0.7,maximumCompetition:0.2,onUpdate:{other.add($0)})
precondition(gapPipeline.appendPCM(Data(count:64_000),offset:0)); gapPipeline.accept(win); precondition(!gapPipeline.appendPCM(Data(count:4),offset:16020));Thread.sleep(forTimeInterval:0.15)
precondition(other.snapshot().last?.diarizationAvailable == false,"gap must invalidate stream")
gapPipeline.stop()
print("PASS tentative/late final attribution, failed model fallback, generation stop and clock discontinuity")
