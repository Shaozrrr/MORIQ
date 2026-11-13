import AppKit
import Foundation

@main struct Test {
 @MainActor static func main() async throws {
  let env=ProcessInfo.processInfo.environment
  guard let audioPath=env["MORIQ_PUBLIC_SPEAKER_AUDIO"], let ffmpeg=env["MORIQ_TEST_FFMPEG"] else { fatalError("public audio and ffmpeg required") }
  let app=NSApplication.shared; app.setActivationPolicy(.accessory)
  let formatter=LiveCaptionState()
  func aligned(_ text:String,_ id:String?,_ start:Int64)->CaptionAlignedWord { .init(word:.init(text:text,range:.init(start:start,end:start+10)),speakerID:id) }
  func result(_ start:Int64,_ words:[CaptionAlignedWord])->CaptionAttributedWindow {
   .init(generation:UUID(),window:.init(startSample:start,endSample:start+100,isFinal:true,words:[]),words:words,diarizationAvailable:true)
  }
  formatter.acceptExperimentalAttribution(result(0,[aligned(" hello","a",0),aligned(" world","a",10)]))
  formatter.acceptExperimentalAttribution(result(100,[aligned(" again","a",100),aligned(" mystery",nil,110),aligned(" yes","b",120)]))
  precondition(formatter.experimentalAttribution == ["说话人 1：hello world again","未知说话人：mystery","说话人 2：yes"],"continuous speaker turns must merge, unknown must stay unknown")
  formatter.clearExperimentalAttribution()
  precondition(formatter.experimentalAttribution.isEmpty)
  let process=Process(), pipe=Pipe()
  process.executableURL=URL(fileURLWithPath:ffmpeg)
  process.arguments=["-v","error","-i",audioPath,"-ar","16000","-ac","1","-f","f32le","-"]
  process.standardOutput=pipe; process.standardError=FileHandle.nullDevice
  try process.run(); let audio=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
  precondition(process.terminationStatus==0 && !audio.isEmpty)
  let coordinator=LiveCaptionsCoordinator()
  precondition(coordinator.debugStartSpeakerWithoutCapture(environment:env),"experimental adapter did not start")
  for offset in stride(from:0,to:audio.count,by:12800) {
   coordinator.debugAppendSpeakerPCM(audio.subdata(in:offset..<min(offset+12800,audio.count)))
   try await Task.sleep(for:.milliseconds(30))
  }
  let acceptDeadline=Date().addingTimeInterval(90)
  while coordinator.debugSpeakerAcceptedSamples < Int64(audio.count/4) && Date() < acceptDeadline { try await Task.sleep(for:.milliseconds(100)) }
  precondition(coordinator.debugSpeakerAcceptedSamples==Int64(audio.count/4),"audio not accepted")
  coordinator.debugFinishSpeakerPCM()
  let deadline=Date().addingTimeInterval(90)
  while Date()<deadline {
   let lines=coordinator.debugSpeakerAttribution
   if lines.contains(where:{$0.contains("说话人 1")}) && lines.contains(where:{$0.contains("说话人 2")}) { break }
   try await Task.sleep(for:.milliseconds(100))
  }
  let lines=coordinator.debugSpeakerAttribution
  precondition(lines.contains(where:{$0.contains("说话人 1")}) && lines.contains(where:{$0.contains("说话人 2")}),"missing real anonymous labels")
  if let path=env["MORIQ_SPEAKER_PREVIEW_PATH"] { try coordinator.debugSaveSpeakerPreview(to:URL(fileURLWithPath:path)) }
  coordinator.stop()
  precondition(coordinator.debugSpeakerAttribution.isEmpty,"stop retained attribution")
  coordinator.debugOpenWithoutCapture(mode:.captions)
  try await Task.sleep(for:.milliseconds(500))
  precondition(coordinator.debugSpeakerAttribution.isEmpty,"stale previous callback leaked to new session")
  coordinator.stop()
  print("PASS opt-in real public audio to offscreen UI model, two anonymous labels and session isolation; no capture")
 }
}
