import AppKit
import SwiftUI

@main struct Test {
 @MainActor static func main() throws {
  let app=NSApplication.shared
  app.setActivationPolicy(.accessory)
  let main=LiveCaptionState(), mic=LiveCaptionState(), tracks=CaptionTrackModels()
  mic.sourceLanguage="zh-CN"; mic.targetLanguage="en-US"
  func view(_ state:LiveCaptionState, secondary:Bool)->LiveCaptionView {
   LiveCaptionView(state:state,close:{},installModel:{},changeLanguage:{_ in},changeAudioSource:{_ in},changeSessionMode:{_ in},selectedSessionMode:.interpretation,secondaryTrack:secondary,embeddedTrack:true)
  }
  let stack=CaptionTrackStack(tracks:tracks,mainState:main,combined:true,main:view(main,secondary:false),microphone:{ view($0,secondary:true) })
  let host=NSHostingView(rootView:stack)
  let window=NSWindow(contentRect:NSRect(x:-3000,y:-3000,width:620,height:292),styleMask:[.borderless],backing:.buffered,defer:false)
  window.contentView=host
  window.orderFront(nil)
  func tick() { RunLoop.current.run(until:Date().addingTimeInterval(0.2)) }
  tick()
  main.mode="original"; main.fontSize=27; tracks.microphone=mic; tick()
  precondition(mic.mode=="original" && mic.fontSize==27,"initial track display mismatch")
  precondition(main.sourceLanguage=="en-US" && main.targetLanguage=="zh-Hans" && mic.sourceLanguage=="zh-CN" && mic.targetLanguage=="en-US","track languages are not independent")
  main.mode="bilingual"; main.fontSize=21; tick()
  precondition(mic.mode=="bilingual" && mic.fontSize==21,"track settings did not follow")
  if ProcessInfo.processInfo.environment["MORIQ_TEST_TRANSLATION_PAIRS"] == "1" {
   main.accept("The meeting starts tomorrow.",final:true)
   mic.accept("会议明天开始。",final:true)
   let deadline=Date().addingTimeInterval(30)
   while (main.translated.isEmpty || mic.translated.isEmpty) && Date()<deadline { tick() }
   precondition(!main.translated.isEmpty && main.translated != main.original,"English to Chinese not translated: \(main.status)")
   precondition(!mic.translated.isEmpty && mic.translated != mic.original,"Chinese to English not translated: \(mic.status)")
   precondition(main.history.last?.translated==main.translated && mic.history.last?.translated==mic.translated,"translation history did not match each track")
   print("PASS actual offline English/Chinese translation in two independent tracks")
  }
  tracks.microphone=nil; tick()
  main.fontSize=25; tick()
  precondition(mic.fontSize==21,"retired track received settings")
  let second=LiveCaptionState(); second.sourceLanguage="zh-CN"; second.targetLanguage="en-US"; tracks.microphone=second; tick()
  precondition(second.mode=="bilingual" && second.fontSize==25,"reopened track did not inherit settings")
  if let path=ProcessInfo.processInfo.environment["MORIQ_DUAL_PREVIEW_PATH"] {
   main.mode="original"; main.accept("The meeting begins at nine.")
   second.accept("你好，我准备好了。"); tick()
   host.layoutSubtreeIfNeeded()
   guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { fatalError("preview bitmap unavailable") }
   host.cacheDisplay(in:host.bounds,to:rep)
   guard let png=rep.representation(using:.png,properties:[:]) else { fatalError("preview encoding failed") }
   try png.write(to:URL(fileURLWithPath:path))
  }
  let longText=String(repeating:"The project meeting continues with important details. ",count:12)
  main.mode="original"; main.accept(longText); tick(); tick()
  precondition(main.original==longText.trimmingCharacters(in:.whitespacesAndNewlines),"long caption was truncated in state")
  func scrollViews(_ view:NSView)->[NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
  let scrolls=scrollViews(host)
  precondition(scrolls.count >= 2 && scrolls.contains { ($0.documentView?.frame.height ?? 0) > $0.contentView.frame.height },"long caption is not scrollable")
  main.mode="bilingual"; second.sourceLanguage="zh-CN"; second.targetLanguage="zh-Hans"; second.accept("这是测试")
  tick(); tick(); tick()
  precondition(second.translated.isEmpty && second.status.contains("相同"),"same-language text must not be presented as a translation")
  window.orderOut(nil)
  let coordinator=LiveCaptionsCoordinator()
  var closeCount=0
  coordinator.onStop={ closeCount += 1 }
  coordinator.debugOpenWithoutCapture(mode:.interpretation); tick()
  precondition(coordinator.debugHasPanel && coordinator.debugHasMicrophoneTrack && coordinator.debugSessionMode == .interpretation)
  precondition(coordinator.debugMicrophoneLanguages?.0 == "zh-CN" && coordinator.debugMicrophoneLanguages?.1 == "en-US","microphone default pair should be Chinese to English")
  coordinator.debugAcceptMicrophone("synthetic microphone history")
  coordinator.debugOpenWithoutCapture(mode:.captions,preserveSession:true); tick()
  precondition(coordinator.debugHasPanel && !coordinator.debugHasMicrophoneTrack)
  coordinator.debugOpenWithoutCapture(mode:.interpretation,preserveSession:true); tick()
  precondition(coordinator.debugMicrophoneHistory.last?.original == "synthetic microphone history","mode switch lost microphone history")
  coordinator.stop(); tick()
  precondition(!coordinator.debugHasPanel && !coordinator.debugHasMicrophoneTrack && closeCount==1,"close failed to clear both tracks")
  coordinator.debugOpenWithoutCapture(mode:.captions); tick()
  precondition(coordinator.debugHasPanel && !coordinator.debugHasMicrophoneTrack && coordinator.debugSessionMode == .captions)
  coordinator.stop(); tick()
  precondition(closeCount==2 && !coordinator.debugHasPanel,"reopened panel failed to close")
  print("PASS dual track presentation, settings sync, removal and reopen; no audio capture")
 }
}
