import AppKit
import SwiftUI

@main struct Test {
 @MainActor static func main() throws {
  let app=NSApplication.shared; app.setActivationPolicy(.accessory)
  let state=LiveCaptionState()
  let view=LiveCaptionView(state:state,close:{},installModel:{},changeLanguage:{_ in},changeAudioSource:{_ in})
  let host=NSHostingView(rootView:view)
  let window=NSWindow(contentRect:NSRect(x:-3000,y:-3000,width:620,height:196),styleMask:[.borderless],backing:.buffered,defer:false)
  window.contentView=host; window.orderFront(nil)
  func tick() { RunLoop.current.run(until:Date().addingTimeInterval(0.2)) }
  tick()
  precondition(CaptionAudioSource.allCases == [.system] && state.audioSource == .system)
  if ProcessInfo.processInfo.environment["MORIQ_TEST_TRANSLATION_PAIRS"] == "1" {
   state.mode="bilingual"; state.accept("The meeting starts tomorrow.",final:true)
   let deadline=Date().addingTimeInterval(30)
   while state.translated.isEmpty && Date()<deadline { tick() }
   precondition(!state.translated.isEmpty && state.translated != state.original,"English to Chinese not translated: \(state.status)")
   state.clearCurrent(); state.sourceLanguage="zh-CN"; state.targetLanguage="en-US"; state.accept("会议明天开始。",final:true)
   let secondDeadline=Date().addingTimeInterval(30)
   while state.translated.isEmpty && Date()<secondDeadline { tick() }
   precondition(!state.translated.isEmpty && state.translated != state.original,"Chinese to English not translated: \(state.status)")
   print("PASS actual offline English/Chinese translation using system-only caption view")
  }
  let longText=String(repeating:"The project meeting continues with important details. ",count:12)
  state.mode="original"; state.clearCurrent(); state.accept(longText); tick(); tick()
  precondition(state.original==longText.trimmingCharacters(in:.whitespacesAndNewlines),"long caption was truncated in state")
  func scrollViews(_ view:NSView)->[NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
  let scrolls=scrollViews(host)
  precondition(scrolls.contains { ($0.documentView?.frame.height ?? 0) > $0.contentView.frame.height },"long caption is not scrollable")
  state.mode="bilingual"; state.sourceLanguage="zh-CN"; state.targetLanguage="zh-Hans"; state.clearCurrent(); state.accept("这是测试")
  tick(); tick(); tick()
  precondition(state.translated.isEmpty && state.status.contains("相同"),"same-language text must not be presented as a translation")
  state.sourceLanguage="en-US"; tick()
  precondition(!state.status.contains("相同"),"changing to a valid language pair must clear stale warning")
  if let path=ProcessInfo.processInfo.environment["MORIQ_CAPTION_PREVIEW_PATH"] {
   state.reset(); state.sourceLanguage="en-US"; state.targetLanguage="zh-Hans"; state.mode="original"
   state.accept("The meeting starts tomorrow.",final:true)
   state.acceptTranslation("会议明天开始。",forOriginal:state.original,segment:state.segmentID)
   precondition(state.history.last?.translated == "会议明天开始。")
   state.accept("Please send the report today.")
   precondition(state.history.contains(where: { $0.original == "The meeting starts tomorrow." && $0.translated == "会议明天开始。" }),"prior history must remain available")
   tick(); tick(); host.layoutSubtreeIfNeeded()
   guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { fatalError("preview bitmap unavailable") }
   host.cacheDisplay(in:host.bounds,to:rep)
   guard let png=rep.representation(using:.png,properties:[:]) else { fatalError("preview encoding failed") }
   try png.write(to:URL(fileURLWithPath:path))
  }
  window.orderOut(nil)
  let coordinator=LiveCaptionsCoordinator(); var closeCount=0
  coordinator.onStop={ closeCount += 1 }
  coordinator.debugOpenWithoutCapture(); tick(); precondition(coordinator.debugHasPanel)
  coordinator.stop(); tick(); precondition(!coordinator.debugHasPanel && closeCount==1)
  coordinator.debugOpenWithoutCapture(); tick(); precondition(coordinator.debugHasPanel)
  coordinator.stop(); tick(); precondition(!coordinator.debugHasPanel && closeCount==2)
  print("PASS system-only presentation, long-text scroll, stop and reopen; no audio capture")
 }
}
