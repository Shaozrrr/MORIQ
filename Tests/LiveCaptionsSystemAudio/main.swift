import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Foundation
final class State: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
 var engine: LocalWhisperCaptionEngine?
 let lock = NSLock(); var count = 0; var updates = 0; var finals = 0; var lastUpdate = 0.0; var found = false; var failure: String?
 func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) { if type == .audio { lock.lock(); count += 1; lock.unlock(); engine?.append(sample) } }
 func text(_ value: String, _ final: Bool) { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; lock.lock(); updates += 1; lastUpdate = ProcessInfo.processInfo.systemUptime; if final { finals += 1 }; if value.lowercased().contains("meeting") { found = true }; lock.unlock() }
 func fail(_ message: String) { lock.lock(); failure = message; lock.unlock() }
 func snapshot() -> (Int,Int,Int,Double,Bool,String?) { lock.lock(); defer {lock.unlock()}; return (count,updates,finals,lastUpdate,found,failure) }
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
 var window: NSWindow?; var player: AVAudioPlayer?; var stream: SCStream?; var state = State()
 func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
 func run() async {
  guard CGPreflightScreenCaptureAccess() else { print("BLOCKED screen permission"); exit(2) }
  let w = NSWindow(contentRect: NSRect(x:0,y:0,width:80,height:40),styleMask:[.titled],backing:.buffered,defer:false); w.title = "Caption test"; w.orderFront(nil); window=w
  do {
   try await Task.sleep(for:.seconds(1))
   let c = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
   guard let display = c.displays.first, let app = c.applications.first(where: { $0.processID == getpid() }) else { print("BLOCKED app missing from shareable list"); exit(2) }
   state.engine = try LocalWhisperCaptionEngine(helper: URL(fileURLWithPath:FileManager.default.currentDirectoryPath + "/Vendor/SpeechEngine/moriq-speech"), model: URL(fileURLWithPath:FileManager.default.currentDirectoryPath + "/Vendor/SpeechEngine/ggml-base.bin"), language:"en", onText: { [state] s,f in state.text(s,f) }, onError: { [state] e in state.fail(e) })
   let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = false; config.width=2; config.height=2; config.minimumFrameInterval=CMTime(value:1,timescale:1); if #available(macOS 15, *) { config.captureMicrophone = false }
   let filter = SCContentFilter(display:display,including:[app],exceptingWindows:[])
   let s = SCStream(filter:filter,configuration:config,delegate:state); stream=s
   try s.addStreamOutput(state,type:.audio,sampleHandlerQueue:DispatchQueue(label:"synthetic.audio")); try await s.startCapture()
   let player = try AVAudioPlayer(contentsOf:URL(fileURLWithPath:FileManager.default.currentDirectoryPath + "/Tests/LiveCaptionsSystemAudio/synthetic.wav")); self.player=player; player.numberOfLoops = -1; player.volume = 0.03; player.play()
   let seconds = Double(ProcessInfo.processInfo.environment["MORIQ_CAPTION_TEST_SECONDS"] ?? "20") ?? 20
   try await Task.sleep(for:.seconds(seconds)); player.stop(); try await s.stopCapture(); state.engine?.stop()
   let (n,updates,finals,lastUpdate,match,error)=state.snapshot()
   let age = ProcessInfo.processInfo.systemUptime - lastUpdate
   print("RESULT buffers=\(n) updates=\(updates) finals=\(finals) last_update_age=\(Int(age))s expected_phrase=\(match) error=\(error ?? "none")")
   if n == 0 || updates < 2 || age > 15 || !match || error != nil { exit(1) }
  } catch { print("BLOCKED \(error.localizedDescription)"); exit(2) }
  NSApp.terminate(nil)
 }
}
MainActor.assumeIsolated {
 let application = NSApplication.shared
 let delegate=Delegate(); application.delegate=delegate; application.setActivationPolicy(.regular); application.run()
}
