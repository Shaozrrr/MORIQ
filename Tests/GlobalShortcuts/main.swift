import AppKit
import Carbon
import Foundation
@main struct Test {
 @MainActor static func main() {
  _ = NSApplication.shared
  let suite="local.moriq.hotkey-test.\(UUID().uuidString)"
  let defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X))!
  precondition(GlobalShortcut(event: event) == GlobalShortcutFeature.screenshot.defaultShortcut)
  precondition(GlobalShortcutFeature.screenshot.defaultShortcut.matches(event))
  let flags=UInt32(controlKey | optionKey)
  let first=GlobalShortcut(keyCode:UInt32(kVK_F6),modifiers:flags)
  let second=GlobalShortcut(keyCode:UInt32(kVK_F8),modifiers:flags)
  let occupied=GlobalShortcut(keyCode:UInt32(kVK_F7),modifiers:flags)
  let registry=GlobalShortcutRegistry(defaults:defaults)
  precondition(registry.current(.assistant) == .assistantDefault)
  precondition(registry.update(.assistant,to:first) == noErr)
  precondition(!registry.isEnabled(.assistant) && registry.current(.assistant) == first)
  var hits = 0
  precondition(registry.enable(.assistant,action:{ hits += 1 }) == noErr)
  func emit(_ id: UInt32 = 1) {
   var event: EventRef?
   precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0, &event) == noErr)
   guard let event else { fatalError("event") }
   var identifier = EventHotKeyID(signature: 0x4D524851, id: id)
   precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
   precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
   ReleaseEvent(event)
   RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }
  emit(); precondition(hits == 1)
  registry.isRecording = true; emit(); precondition(hits == 1); registry.isRecording = false
  var other:EventHotKeyRef?
  precondition(RegisterEventHotKey(occupied.keyCode,occupied.modifiers,EventHotKeyID(signature:0x54535431,id:71),GetApplicationEventTarget(),0,&other) == noErr)
  precondition(registry.update(.assistant,to:occupied) != noErr && registry.current(.assistant) == first && registry.isEnabled(.assistant))
  var duplicate:EventHotKeyRef?
  precondition(RegisterEventHotKey(first.keyCode,first.modifiers,EventHotKeyID(signature:0x54535432,id:72),GetApplicationEventTarget(),0,&duplicate) != noErr)
  precondition(registry.update(.assistant,to:second) == noErr && registry.current(.assistant) == second)
  precondition(RegisterEventHotKey(first.keyCode,first.modifiers,EventHotKeyID(signature:0x54535432,id:72),GetApplicationEventTarget(),0,&duplicate) == noErr)
  if let duplicate { UnregisterEventHotKey(duplicate) }
  precondition(registry.update(.clipboard,to:second) == OSStatus(eventHotKeyExistsErr))
  precondition(registry.update(.clipboard,to:GlobalShortcut(keyCode:UInt32(kVK_ANSI_5),modifiers:UInt32(cmdKey | shiftKey))) == OSStatus(paramErr))
  precondition(registry.update(.clipboard,to:GlobalShortcut(keyCode:UInt32(kVK_ANSI_A),modifiers:UInt32(shiftKey))) == OSStatus(paramErr))
  if let other { UnregisterEventHotKey(other) }
  registry.disable(.assistant)
  let reopened=GlobalShortcutRegistry(defaults:UserDefaults(suiteName:suite)!)
  precondition(reopened.current(.assistant) == second)
  precondition(reopened.enable(.assistant,action:{}) == noErr)
  reopened.disable(.assistant)
  var shelfHits = 0, noteHits = 0, captionState = false
  for feature in [GlobalShortcutFeature.shelf, .notes, .captions] {
   precondition(reopened.current(feature).modifiers == UInt32(optionKey | cmdKey))
  }
  precondition(Set(GlobalShortcutFeature.allCases.map { "\($0.defaultShortcut.keyCode):\($0.defaultShortcut.modifiers)" }).count == GlobalShortcutFeature.allCases.count)
  precondition(reopened.enable(.shelf, action: { shelfHits += 1 }) == noErr)
  precondition(reopened.enable(.notes, action: { noteHits += 1 }) == noErr)
  precondition(reopened.enable(.captions, action: { captionState.toggle() }) == noErr)
  // emit sends through Carbon to the active registry; all registries use the same
  // signature, so the prior one must no longer have active actions.
  emit(4); emit(5); emit(6)
  precondition(shelfHits == 1 && noteHits == 1 && captionState)
  emit(6); precondition(!captionState)
  reopened.isRecording = true; emit(4); emit(5); emit(6); reopened.isRecording = false
  precondition(shelfHits == 1 && noteHits == 1 && !captionState)
  precondition(reopened.update(.notes, to: reopened.current(.shelf)) == OSStatus(eventHotKeyExistsErr))
  reopened.disable(.shelf); reopened.disable(.notes); reopened.disable(.captions)
  emit(4); emit(5); emit(6)
  precondition(shelfHits == 1 && noteHits == 1 && !captionState)
  let captionBlocked = GlobalShortcut(keyCode: UInt32(kVK_F9), modifiers: flags)
  let captionRecovery = GlobalShortcut(keyCode: UInt32(kVK_F10), modifiers: flags)
  precondition(reopened.update(.captions, to: captionBlocked) == noErr)
  var outside: EventHotKeyRef?
  precondition(RegisterEventHotKey(captionBlocked.keyCode, captionBlocked.modifiers, EventHotKeyID(signature: 0x54535433,id: 73), GetApplicationEventTarget(),0,&outside) == noErr)
  precondition(reopened.enable(.captions, retryOnUpdate: true, action: { captionState.toggle() }) != noErr)
  precondition(!reopened.isEnabled(.captions))
  precondition(reopened.update(.captions, to: captionRecovery) == noErr && reopened.isEnabled(.captions))
  emit(6); precondition(captionState)
  reopened.disable(.captions)
  if let outside { UnregisterEventHotKey(outside) }
  for (feature, blockedKey, replacementKey, eventID) in [
      (GlobalShortcutFeature.shelf, kVK_F11, kVK_F12, UInt32(4)),
      (GlobalShortcutFeature.notes, kVK_F14, kVK_F15, UInt32(5))
  ] {
   let blocked = GlobalShortcut(keyCode: UInt32(blockedKey), modifiers: flags)
   let replacement = GlobalShortcut(keyCode: UInt32(replacementKey), modifiers: flags)
   precondition(reopened.update(feature, to: blocked) == noErr)
   var external: EventHotKeyRef?
   precondition(RegisterEventHotKey(blocked.keyCode, blocked.modifiers, EventHotKeyID(signature: 0x54535434,id: eventID), GetApplicationEventTarget(),0,&external) == noErr)
   var featureRemainsAvailable = true, called = false
   precondition(reopened.enable(feature, retryOnUpdate: true, action: { called = featureRemainsAvailable }) != noErr)
   precondition(featureRemainsAvailable && !reopened.isEnabled(feature) && reopened.current(feature) == blocked)
   precondition(reopened.update(feature, to: replacement) == noErr && reopened.isEnabled(feature))
   emit(eventID); precondition(called)
   reopened.disable(feature); featureRemainsAvailable = false
   if let external { UnregisterEventHotKey(external) }
  }
  defaults.set(["keyCode": -1,"modifiers":-1],forKey:"moriq.hotkey.screenshot")
  precondition(reopened.current(.screenshot) == GlobalShortcutFeature.screenshot.defaultShortcut)
  print("PASS Carbon registration, change, conflict rollback, disabled change, persistence and invalid values")
 }
}
private extension GlobalShortcut { static var assistantDefault: GlobalShortcut { GlobalShortcutFeature.assistant.defaultShortcut } }
