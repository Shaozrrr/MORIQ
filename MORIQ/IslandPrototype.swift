import AppKit
import SwiftUI
import Combine

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Top-edge panel backed by the application’s existing feature stores.
@MainActor final class IslandPrototype {
    private var state = IslandInteraction()
    private let content: IslandPreviewContent
    private let focusTimer: FocusTimerStore
    init(content: IslandPreviewContent, focusTimer: FocusTimerStore) { self.content = content; self.focusTimer = focusTimer }
    convenience init(content: IslandPreviewContent) { self.init(content: content, focusTimer: FocusTimerStore.shared) }
    convenience init() {
        let defaults = UserDefaults(suiteName: "local.moriq.island.test.\(UUID().uuidString)")!
        self.init(content: IslandPreviewContent(defaults: defaults), focusTimer: FocusTimerStore(defaults: defaults))
    }
    private var selectionObserver: AnyCancellable?
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pending: DispatchWorkItem?
    private var pointerTimer: Timer?
    private var sampledPointer: NSPoint?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var interactionHeld = false
    private var editingHeld = false
    private var sleeping = false
    private var sessionInactive = false
    private var displayID: UInt32?
    private var lastPhase: IslandInteraction.Phase = .hidden
    var onPhaseChange: ((IslandInteraction.Phase) -> Void)?
    var onSelect: ((String) -> Void)?
    var onModuleView: ((IslandModule) -> AnyView?)?
    func setEditing(_ editing: Bool) {
        editingHeld = editing
        if !editing, panel?.isVisible == true { sample() }
    }
    func diagnosticPanel() -> NSPanel? { panel }
    func diagnosticResourcesReleased() -> Bool {
        globalMonitor == nil && localMonitor == nil && pointerTimer == nil && pending == nil && observers.isEmpty && !(panel?.isVisible ?? false)
    }
    func diagnosticShowExpanded(on screen: NSScreen) {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        displayID = id.uint32Value
        present(.expanded, screen: screen)
    }

    func start() {
        guard pointerTimer == nil else { return }
        selectionObserver = content.$selection.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.phase == .expanded else { return }
                self.onPhaseChange?(.expanded)
            }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(eventType: event.type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask.union(.keyDown)) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53, self?.panel?.isKeyWindow == true {
                self?.resetPresentation()
                return nil
            }
            Task { @MainActor in self?.handle(eventType: event.type) }
            return event
        }
        let appCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (appCenter, NSApplication.didChangeScreenParametersNotification),
            (workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (workspaceCenter, NSWorkspace.willSleepNotification),
            (workspaceCenter, NSWorkspace.didWakeNotification),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification { self.sleeping = true }
                    if name == NSWorkspace.didWakeNotification { self.sleeping = false }
                    if name == NSWorkspace.sessionDidResignActiveNotification { self.sessionInactive = true }
                    if name == NSWorkspace.sessionDidBecomeActiveNotification { self.sessionInactive = false }
                    self.resetPresentation()
                }
            }
            observers.append((center, token))
        }
        // The menu bar or a foreground app can consume a mouse-moved event.
        // Sample the current pointer so hover and leave still follow its position.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.sleeping, !self.sessionInactive else { return }
                let released = self.interactionHeld && NSEvent.pressedMouseButtons & 1 == 0
                if released { self.interactionHeld = false }
                guard released || self.sampledPointer != NSEvent.mouseLocation else { return }
                self.sample()
            }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        pointerTimer?.invalidate(); pointerTimer = nil; sampledPointer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        selectionObserver?.cancel(); selectionObserver = nil
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        resetPresentation()
    }

    private func resetPresentation() {
        pending?.cancel(); pending = nil; interactionHeld = false; editingHeld = false
        panel?.orderOut(nil); panel?.contentView = nil; state.reset(); lastPhase = .hidden; displayID = nil; onPhaseChange?(.hidden)
    }

    private func handle(eventType: NSEvent.EventType) {
        guard pointerTimer != nil else { return }
        if eventType == .leftMouseDown, panel?.frame.contains(NSEvent.mouseLocation) == true { interactionHeld = true }
        if eventType == .leftMouseUp { interactionHeld = false }
        sample()
    }

    private func sample() {
        guard !sleeping, !sessionInactive else { return }
        let point = NSEvent.mouseLocation
        sampledPointer = point
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            resetPresentation(); return
        }
        let id = number.uint32Value
        let frame = screen.frame
        // On notched displays, include the reachable strip below the camera housing.
        let depth = max(12, screen.safeAreaInsets.top + 6)
        let topBand = CGRect(x: frame.midX - 150, y: frame.maxY - depth, width: 300, height: depth)
        let isTop = topBand.contains(point)
        let panelBounds = panel?.frame ?? .zero
        let corridor = CGRect(x: frame.midX - 60, y: panelBounds.maxY - 14,
                              width: 120, height: max(0, frame.maxY - panelBounds.maxY + 14))
        let panelArea = (panel?.isVisible == true) && (panelBounds.insetBy(dx: -12, dy: -14).contains(point) || corridor.contains(point))
        let interacting = interactionHeld || editingHeld
        let old = state.phase
        state.sample(now: ProcessInfo.processInfo.systemUptime, screen: id, inTrigger: isTop, inPanelOrCorridor: panelArea, interacting: interacting)
        if old == .hidden && state.phase != .hidden { displayID = id }
        if state.phase != old { present(state.phase, screen: screen) }
        pending?.cancel(); pending = nil
        let delay: TimeInterval?
        switch state.phase {
        case .hidden: delay = isTop ? 0.16 : nil
        case .compact: delay = (isTop || panelArea || interacting) ? (panelArea ? 0.30 : nil) : 0.45
        case .expanded: delay = (isTop || panelArea || interacting) ? nil : 0.45
        }
        if let delay {
            let work = DispatchWorkItem { [weak self] in self?.sample() }
            pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func present(_ phase: IslandInteraction.Phase, screen: NSScreen?) {
        if phase == .hidden { panel?.orderOut(nil); panel?.contentView = nil; displayID = nil; lastPhase = phase; onPhaseChange?(phase); return }
        guard let screen, let displayID,
              (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID else { return }
        if panel == nil {
            let window = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.hidesOnDeactivate = false; window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = window
        }
        let expanded = phase == .expanded
        let visible = screen.visibleFrame
        let expandedWidth = min(460, visible.width)
        let size = NSSize(width: expanded ? expandedWidth : min(84, visible.width), height: expanded ? min(280, visible.height) : 7)
        let x = min(max(screen.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let rect = NSRect(x: x, y: visible.maxY - size.height, width: size.width, height: size.height)
        panel?.contentView = NSHostingView(rootView: IslandPrototypeView(expanded: expanded, model: content, focusTimer: focusTimer, customView: onModuleView, expand: { [weak self] in
            guard let self else { return }; self.state.click(); self.present(self.state.phase, screen: screen)
        }, select: { [weak self] id in self?.onSelect?(id) }))
        if panel?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel?.animator().setFrame(rect, display: true)
            }
        } else { panel?.setFrame(rect, display: true) }
        panel?.orderFrontRegardless(); lastPhase = phase; onPhaseChange?(phase)
    }
}

private struct IslandMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow
        view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
/// Isolated preview state. Real adapters will supply data only after GUI acceptance.
@MainActor final class IslandPreviewContent: ObservableObject {
    static let shared = IslandPreviewContent(defaults: .standard)
    @Published private(set) var selection: IslandModuleSelection
    @Published var contents: [IslandModule: [String]] = [:]
    @Published var states: [IslandModule: IslandContentState] = [:]
    @Published var hidden: Set<IslandModule> = []
    private let defaults: UserDefaults
    private let key = "island.preview.selection"
    init(defaults: UserDefaults = UserDefaults(suiteName: "local.moriq.island.preview.\(UUID().uuidString)")!) {
        self.defaults = defaults
        let fallback = IslandModuleSelection(enabled: [.calendar, .focus, .music, .notes, .shelf])
        self.selection = defaults.data(forKey: key).map { IslandModuleSelection.decode($0, fallback: fallback) } ?? fallback
    }
    func select(_ module: IslandModule) { var next = selection; next.select(module); update(next) }
    func setEnabled(_ module: IslandModule, _ enabled: Bool) { var next = selection; next.setEnabled(module, enabled); update(next) }
    func move(_ module: IslandModule, to index: Int) { var next = selection; next.move(module, to: index); update(next) }
    private func update(_ next: IslandModuleSelection) {
        selection = next
        if let data = next.encoded { defaults.set(data, forKey: key) }
    }
}
struct IslandModuleSettingsView: View {
    @ObservedObject var model: IslandPreviewContent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("展示内容").font(.headline)
            ForEach([IslandModule.calendar, .focus, .music, .notes, .shelf, .clipboard, .conversion, .captions, .screenshot, .assistant]) { module in
                HStack {
                    Toggle(module.title, isOn: Binding(get: { model.selection.enabled.contains(module) }, set: { model.setEnabled(module, $0) }))
                    Spacer()
                    if let index = model.selection.enabled.firstIndex(of: module) {
                        Button { model.move(module, to: index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel("上移\(module.title)")
                        Button { model.move(module, to: index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == model.selection.enabled.count - 1).accessibilityLabel("下移\(module.title)")
                    }
                }
            }
        }.padding(20)
    }
}
private struct IslandPrototypeView: View {
    let expanded: Bool
    @ObservedObject var model: IslandPreviewContent
    @ObservedObject var focusTimer: FocusTimerStore
    var enableSystemData = true
    var customView: ((IslandModule) -> AnyView?)? = nil
    let expand: () -> Void
    let select: (String) -> Void
    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(model.selection.enabled) { module in
                                Button {
                                    model.select(module); select(module.rawValue)
                                } label: {
                                    VStack(spacing: 7) {
                                        Text(module.title).font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(model.selection.selected == module ? Color.white : Color.white.opacity(0.55))
                                        Capsule().fill(model.selection.selected == module ? Color.blue : .clear).frame(height: 2)
                                    }.fixedSize(horizontal: true, vertical: false)
                                }.buttonStyle(.plain).accessibilityLabel(module.title)
                            }
                        }.padding(.horizontal, 20)
                    }.frame(height: 42)
                    if let module = model.selection.selected {
                        if let custom = customView?(module) {
                            custom.padding(20)
                        } else if module == .calendar && enableSystemData {
                            AgendaView().padding(20)
                        } else if module == .focus {
                            FocusTimerView(store: focusTimer).padding(20)
                        } else if module == .music && enableSystemData {
                            NowPlayingView().padding(20)
                        } else if model.hidden.contains(module) {
                            Text("已隐藏").foregroundStyle(.secondary).padding(20)
                        } else if let entries = model.contents[module], !entries.isEmpty {
                            ScrollView { VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                    Text(entry).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(20) }
                        } else {
                            Text(model.states[module] == .failed ? "暂不可用" : (model.states[module] == .unavailable ? "未运行" : "暂无记录"))
                                .foregroundStyle(.secondary).padding(20)
                        }
                    }
                    Spacer(minLength: 0)
                }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background { IslandMaterial().overlay(Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.68)) }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                Button(action: expand) { Capsule().fill(Color(red: 0.09, green: 0.11, blue: 0.16)).frame(width: 84, height: 7).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("展开内容")
            }
        }
    }
}
@MainActor func makeIslandContentSnapshotView(model: IslandPreviewContent) -> NSView {
    NSHostingView(rootView: IslandPrototypeView(expanded: true, model: model, focusTimer: FocusTimerStore(defaults: UserDefaults(suiteName: "local.moriq.island.snapshot.\(UUID().uuidString)")!), enableSystemData: false, expand: {}, select: { _ in }))
}
@MainActor func makeIslandSnapshotView(expanded: Bool, columns: Int) -> NSView {
    NSHostingView(rootView: IslandPrototypeView(expanded: expanded, model: IslandPreviewContent(), focusTimer: FocusTimerStore(defaults: UserDefaults(suiteName: "local.moriq.island.snapshot.\(UUID().uuidString)")!), enableSystemData: false, expand: {}, select: { _ in }))
}
