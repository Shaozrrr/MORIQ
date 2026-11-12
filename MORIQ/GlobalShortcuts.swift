import AppKit
import Carbon

struct GlobalShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    init?(event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        let result = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard result.isValid else { return nil }
        self = result
    }
    var isValid: Bool {
        let allowed = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        let significant = UInt32(cmdKey | optionKey | controlKey)
        guard keyCode <= 127, modifiers & ~allowed == 0, modifiers & significant != 0 else { return false }
        let systemCaptures: Set<UInt32> = [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5)]
        return !(systemCaptures.contains(keyCode) && modifiers & UInt32(cmdKey | shiftKey) == UInt32(cmdKey | shiftKey))
    }
    func matches(_ event: NSEvent) -> Bool {
        guard !event.isARepeat, UInt32(event.keyCode) == keyCode else { return false }
        return GlobalShortcut(event: event)?.modifiers == modifiers
    }
    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
    var displayText: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        let labels: [UInt32:String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",
            18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",24:"=",27:"−",30:"]",33:"[",39:"'",41:";",42:"\\",43:",",44:"/",47:".",50:"`",
            36:"↩",48:"⇥",49:"Space",51:"⌫",53:"Esc",76:"⌅",115:"Home",116:"Page Up",117:"⌦",119:"End",121:"Page Down",123:"←",124:"→",125:"↓",126:"↑",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"
        ]
        return parts + (labels[keyCode] ?? "键位 \(keyCode)")
    }
}

enum GlobalShortcutFeature: String, CaseIterable {
    case assistant, clipboard, screenshot, shelf, notes, captions
    fileprivate var id: UInt32 { switch self { case .assistant: 1; case .clipboard: 2; case .screenshot: 3; case .shelf: 4; case .notes: 5; case .captions: 6 } }
    var defaultShortcut: GlobalShortcut {
        let key: Int
        switch self { case .assistant: key = kVK_Space; case .clipboard: key = kVK_ANSI_V; case .screenshot: key = kVK_ANSI_X; case .shelf: key = kVK_ANSI_S; case .notes: key = kVK_ANSI_N; case .captions: key = kVK_ANSI_C }
        let modifiers = self == .shelf || self == .notes || self == .captions ? cmdKey | optionKey : cmdKey | shiftKey
        return GlobalShortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers))
    }
    fileprivate var storageKey: String { "moriq.hotkey.\(rawValue)" }
}

/// Atomic Carbon registration. A failed change keeps the prior registration and preference.
@MainActor final class GlobalShortcutRegistry {
    static let shared = GlobalShortcutRegistry()
    var isRecording = false
    private let defaults: UserDefaults
    private var handler: EventHandlerRef?
    private var registered: [GlobalShortcutFeature: EventHotKeyRef] = [:]
    private var actions: [GlobalShortcutFeature: () -> Void] = [:]
    private var awaitingShortcut: Set<GlobalShortcutFeature> = []
    private let signature: OSType = 0x4D524851
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    deinit {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
    func current(_ feature: GlobalShortcutFeature) -> GlobalShortcut {
        guard let saved = defaults.dictionary(forKey: feature.storageKey),
              let code = saved["keyCode"] as? NSNumber, let flags = saved["modifiers"] as? NSNumber,
              code.int64Value >= 0, flags.int64Value >= 0, code.uint64Value <= UInt64(UInt32.max), flags.uint64Value <= UInt64(UInt32.max) else { return feature.defaultShortcut }
        let shortcut = GlobalShortcut(keyCode: code.uint32Value, modifiers: flags.uint32Value)
        return shortcut.isValid ? shortcut : feature.defaultShortcut
    }
    func isEnabled(_ feature: GlobalShortcutFeature) -> Bool { registered[feature] != nil }
    func enable(_ feature: GlobalShortcutFeature, retryOnUpdate: Bool = false, action: @escaping () -> Void) -> OSStatus {
        if isEnabled(feature) { actions[feature] = action; return noErr }
        let handlerStatus = installHandler()
        guard handlerStatus == noErr else {
            if retryOnUpdate { actions[feature] = action; awaitingShortcut.insert(feature) }
            return handlerStatus
        }
        var ref: EventHotKeyRef?
        let status = register(current(feature), for: feature, into: &ref)
        guard status == noErr, let ref else {
            if retryOnUpdate { actions[feature] = action; awaitingShortcut.insert(feature) }
            return status == noErr ? OSStatus(eventInternalErr) : status
        }
        registered[feature] = ref; actions[feature] = action; awaitingShortcut.remove(feature)
        return noErr
    }
    func disable(_ feature: GlobalShortcutFeature) {
        if let old = registered.removeValue(forKey: feature) { UnregisterEventHotKey(old) }
        actions.removeValue(forKey: feature)
        awaitingShortcut.remove(feature)
    }
    @discardableResult func update(_ feature: GlobalShortcutFeature, to shortcut: GlobalShortcut) -> OSStatus {
        guard shortcut.isValid else { return OSStatus(paramErr) }
        if shortcut == current(feature) {
            if awaitingShortcut.contains(feature), !isEnabled(feature), let action = actions[feature] { return enable(feature, retryOnUpdate: true, action: action) }
            return noErr
        }
        guard !GlobalShortcutFeature.allCases.contains(where: { $0 != feature && current($0) == shortcut }) else { return OSStatus(eventHotKeyExistsErr) }
        if awaitingShortcut.contains(feature) {
            let handlerStatus = installHandler()
            guard handlerStatus == noErr else { return handlerStatus }
        }
        var replacement: EventHotKeyRef?
        let status = register(shortcut, for: feature, into: &replacement)
        guard status == noErr, let replacement else { return status == noErr ? OSStatus(eventInternalErr) : status }
        if let old = registered[feature] { registered[feature] = replacement; UnregisterEventHotKey(old) }
        else if awaitingShortcut.contains(feature) { registered[feature] = replacement; awaitingShortcut.remove(feature) }
        else { UnregisterEventHotKey(replacement) }
        defaults.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers)], forKey: feature.storageKey)
        return noErr
    }
    private func register(_ shortcut: GlobalShortcut, for feature: GlobalShortcutFeature, into ref: inout EventHotKeyRef?) -> OSStatus {
        guard shortcut.isValid else { return OSStatus(paramErr) }
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: feature.id), GetApplicationEventTarget(), 0, &ref)
    }
    private func installHandler() -> OSStatus {
        guard handler == nil else { return noErr }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x4D524851 else { return OSStatus(eventNotHandledErr) }
            let registry = Unmanaged<GlobalShortcutRegistry>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak registry] in
                guard let registry, !registry.isRecording, let feature = GlobalShortcutFeature.allCases.first(where: { $0.id == identifier.id }) else { return }
                registry.actions[feature]?()
            }
            return noErr
        }
        return InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
