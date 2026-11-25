import AppKit
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Top-edge Liquid Glass Dynamic Island backed by MORIQ's real feature stores.
@MainActor final class IslandPrototype {
    private var state = IslandInteraction()
    private let content: IslandPreviewContent
    private let focusTimer: FocusTimerStore
    private let bentoStore: IslandBentoStore

    init(content: IslandPreviewContent, focusTimer: FocusTimerStore, bentoStore: IslandBentoStore? = nil) {
        self.content = content
        self.focusTimer = focusTimer
        self.bentoStore = bentoStore ?? .shared
    }

    convenience init(content: IslandPreviewContent) {
        self.init(content: content, focusTimer: FocusTimerStore.shared)
    }

    convenience init() {
        let defaults = UserDefaults(suiteName: "local.moriq.island.test.\(UUID().uuidString)")!
        self.init(content: IslandPreviewContent(defaults: defaults), focusTimer: FocusTimerStore(defaults: defaults))
    }

    private var selectionObserver: AnyCancellable?
    private var bentoObserver: AnyCancellable?
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
    var onOpenStudio: (() -> Void)?

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

        if content === IslandPreviewContent.shared {
            bentoStore.onNavigateModule = { [weak self] target in
                guard let self else { return }
                if !self.content.selection.enabled.contains(target) {
                    if self.content.selection.enabled.count >= IslandModuleSelection.maxEnabledCount,
                       let removable = self.content.selection.enabled.last(where: { $0 != .bento }) {
                        self.content.setEnabled(removable, false)
                    }
                    self.content.setEnabled(target, true)
                }
                self.content.select(target)
                self.refreshExpandedGeometryIfVisible()
            }
            bentoStore.onOpenDIYSettings = { [weak self] in
                self?.onOpenStudio?()
            }
        }

        selectionObserver = content.$selection.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.phase == .expanded else { return }
                self.refreshExpandedGeometryIfVisible()
                self.onPhaseChange?(.expanded)
            }
        }

        bentoObserver = Publishers.Merge(
            Publishers.Merge4(
                bentoStore.$gridMaxCells.map { _ in () },
                bentoStore.$activeCanvas.map { _ in () },
                bentoStore.$compactShell.map { _ in () },
                bentoStore.$compactSlots.map { _ in () }
            ),
            bentoStore.$inlineDIYOpen.map { _ in () }
        ).dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshExpandedGeometryIfVisible()
                self?.refreshCompactGeometryIfVisible()
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
        bentoObserver?.cancel(); bentoObserver = nil
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        resetPresentation()
    }

    private func resetPresentation() {
        pending?.cancel(); pending = nil; interactionHeld = false; editingHeld = false
        if bentoStore.inlineDIYOpen { bentoStore.inlineDIYOpen = false; bentoStore.spotlightWidget = nil }
        if lastPhase == .expanded && content === IslandPreviewContent.shared {
            SystemTelemetryStore.shared.releaseSampling()
        }
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
        let depth = max(12, screen.safeAreaInsets.top + 6)
        let topBand = CGRect(x: frame.midX - 165, y: frame.maxY - depth, width: 330, height: depth)
        let isTop = topBand.contains(point)
        let panelBounds = panel?.frame ?? .zero
        let corridor = CGRect(x: frame.midX - 80, y: panelBounds.maxY - 14,
                              width: 160, height: max(0, frame.maxY - panelBounds.maxY + 14))
        let panelArea = (panel?.isVisible == true) && (panelBounds.insetBy(dx: -14, dy: -14).contains(point) || corridor.contains(point))
        let modalHeld = (content === IslandPreviewContent.shared) && (MoriqSyncHub.shared.showingGoogleConnectSheet || bentoStore.inlineDIYOpen)
        let interacting = interactionHeld || editingHeld || modalHeld
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

    private func desiredExpandedSize(visible: CGRect) -> NSSize {
        guard content === IslandPreviewContent.shared else {
            return NSSize(width: min(460, visible.width), height: min(280, visible.height))
        }
        let selected = content.selection.selected ?? .bento
        let isInlineDIY = (selected == .bento && bentoStore.inlineDIYOpen)
        let width = min(isInlineDIY ? 632 : 564, visible.width - 20)
        let height: CGFloat
        switch selected {
        case .bento:
            let packed = BentoGridPacker.pack(entries: bentoStore.activeCanvas, maxCells: bentoStore.gridMaxCells, columns: 4)
            let gridH = CGFloat(packed.totalRows) * 74 + CGFloat(max(0, packed.totalRows - 1)) * 8
            height = min(visible.height - 40, gridH + 78 + (isInlineDIY ? 280 : 0))
        case .calendar:
            height = min(visible.height - 40, 356)
        case .system:
            height = min(visible.height - 40, 294)
        case .control, .toolkit:
            height = min(visible.height - 40, 242)
        case .aiDev:
            height = min(visible.height - 40, 260)
        default:
            height = min(visible.height - 40, 268)
        }
        return NSSize(width: width, height: max(210, height))
    }

    private func refreshExpandedGeometryIfVisible() {
        guard state.phase == .expanded, let panel, panel.isVisible,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = desiredExpandedSize(visible: visible)
        let x = min(max(screen.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let rect = NSRect(x: x, y: visible.maxY - size.height - 4, width: size.width, height: size.height)
        if abs(panel.frame.height - rect.height) > 1 || abs(panel.frame.width - rect.width) > 1 {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.setFrame(rect, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.20
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(rect, display: true)
                }
            }
        }
    }

    private func desiredCompactSize(visible: NSRect, isProductInstance: Bool) -> NSSize {
        guard isProductInstance, bentoStore.compactShell != .hairline else {
            return NSSize(width: min(isProductInstance ? 96 : 84, visible.width), height: isProductInstance ? 8 : 7)
        }
        let slotCount = max(1, bentoStore.compactSlots.count)
        let estW: CGFloat
        switch slotCount {
        case 1: estW = 160
        case 2: estW = 272
        default: estW = 396
        }
        return NSSize(width: min(estW, visible.width), height: 30)
    }

    private func refreshCompactGeometryIfVisible() {
        guard state.phase == .compact, let panel, panel.isVisible,
              let screen = panel.screen ?? NSScreen.main else { return }
        let isProductInstance = (content === IslandPreviewContent.shared)
        let visible = screen.visibleFrame
        let size = desiredCompactSize(visible: visible, isProductInstance: isProductInstance)
        let x = min(max(screen.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let rect = NSRect(x: x, y: visible.maxY - size.height, width: size.width, height: size.height)
        if abs(panel.frame.width - rect.width) > 1 || abs(panel.frame.height - rect.height) > 1 {
            panel.setFrame(rect, display: true)
        }
    }

    private func present(_ phase: IslandInteraction.Phase, screen: NSScreen?) {
        if phase == .hidden {
            if lastPhase == .expanded && content === IslandPreviewContent.shared {
                SystemTelemetryStore.shared.releaseSampling()
            }
            panel?.orderOut(nil); panel?.contentView = nil; displayID = nil; lastPhase = phase; onPhaseChange?(phase)
            return
        }
        guard let screen, let displayID,
              (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID else { return }

        if phase == .expanded && lastPhase != .expanded && content === IslandPreviewContent.shared {
            SystemTelemetryStore.shared.retainSampling()
        }

        if panel == nil {
            let window = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.hidesOnDeactivate = false; window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = window
        }

        let expanded = phase == .expanded
        let isProductInstance = (content === IslandPreviewContent.shared)
        let visible = screen.visibleFrame
        let size: NSSize
        if expanded {
            size = desiredExpandedSize(visible: visible)
        } else {
            size = desiredCompactSize(visible: visible, isProductInstance: isProductInstance)
        }
        let topInset: CGFloat = isProductInstance && expanded ? 4 : 0
        let x = min(max(screen.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let rect = NSRect(x: x, y: visible.maxY - size.height - topInset, width: size.width, height: size.height)

        panel?.contentView = NSHostingView(
            rootView: IslandPrototypeView(
                expanded: expanded,
                model: content,
                focusTimer: focusTimer,
                bentoStore: bentoStore,
                isProductShell: isProductInstance,
                enableSystemData: true,
                customView: onModuleView,
                openStudio: onOpenStudio,
                expand: { [weak self] in
                    guard let self else { return }
                    self.state.click()
                    self.present(self.state.phase, screen: screen)
                },
                select: { [weak self] id in self?.onSelect?(id) }
            )
        )
        if panel?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel?.animator().setFrame(rect, display: true)
            }
        } else {
            panel?.setFrame(rect, display: true)
        }
        panel?.orderFrontRegardless(); lastPhase = phase; onPhaseChange?(phase)
    }
}

/// Module selection state. Isolated test instances keep the compact 5-module default;
/// the product singleton defaults to the full Liquid Glass Bento + Productivity suite.
@MainActor final class IslandPreviewContent: ObservableObject {
    static let shared = IslandPreviewContent(
        defaults: .standard,
        defaultModules: [.bento, .calendar, .system, .control, .toolkit, .aiDev, .focus, .music]
    )

    @Published private(set) var selection: IslandModuleSelection
    @Published var contents: [IslandModule: [String]] = [:]
    @Published var states: [IslandModule: IslandContentState] = [:]
    @Published var hidden: Set<IslandModule> = []
    private let defaults: UserDefaults
    private let key = "island.preview.selection"

    init(
        defaults: UserDefaults = UserDefaults(suiteName: "local.moriq.island.preview.\(UUID().uuidString)")!,
        defaultModules: [IslandModule] = [.calendar, .focus, .music, .notes, .shelf]
    ) {
        self.defaults = defaults
        let fallback = IslandModuleSelection(enabled: defaultModules)
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
        if model === IslandPreviewContent.shared {
            IslandStudioSettingsView(tabModel: model)
        } else {
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
}

private struct IslandPrototypeView: View {
    let expanded: Bool
    @ObservedObject var model: IslandPreviewContent
    @ObservedObject var focusTimer: FocusTimerStore
    @ObservedObject var bentoStore: IslandBentoStore
    @ObservedObject private var telemetry = SystemTelemetryStore.shared
    var isProductShell = false
    var enableSystemData = true
    var customView: ((IslandModule) -> AnyView?)? = nil
    var openStudio: (() -> Void)? = nil
    let expand: () -> Void
    let select: (String) -> Void

    @AppStorage("moriq.permissionDarkMode") private var darkMode = false
    @State private var aiDevSubTab: String = "quota"

    private var effectiveScheme: ColorScheme {
        isProductShell ? (darkMode ? .dark : .light) : .dark
    }

    var body: some View {
        Group {
            if expanded {
                expandedBody
                    .environment(\.colorScheme, effectiveScheme)
                    .tint(LiquidGlassPalette.sapphire)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .liquidGlassPanel(cornerRadius: isProductShell ? 24 : 18, strong: true)
            } else {
                compactBody
                    .environment(\.colorScheme, effectiveScheme)
            }
        }
    }

    private var compactBody: some View {
        Button(action: expand) {
            if isProductShell {
                LiveCompactCapsulePreviewView(bentoStore: bentoStore)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.32))
                    .frame(width: 32, height: 3)
                    .frame(width: 84, height: 7)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开内容")
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Navigation Rail
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: isProductShell ? 2 : 0) {
                        ForEach(model.selection.enabled) { module in
                            let isSelected = model.selection.selected == module
                            let showLabel = isProductShell && isSelected
                            Button {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                    if module != .bento && bentoStore.inlineDIYOpen {
                                        bentoStore.inlineDIYOpen = false
                                        bentoStore.spotlightWidget = nil
                                    }
                                    model.select(module)
                                }
                                select(module.rawValue)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: module.islandSymbolName)
                                        .font(.system(size: isProductShell ? 12.5 : 15, weight: isSelected ? .semibold : .medium))
                                    if showLabel {
                                        Text(module.title)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(IslandLiquidTabStyle(selected: isSelected, compactFixedCell: !isProductShell || !showLabel, scheme: effectiveScheme))
                            .help(module.title)
                            .accessibilityLabel(module.title)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                }

                if isProductShell {
                    HStack(spacing: 5) {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                let next = !bentoStore.inlineDIYOpen
                                bentoStore.inlineDIYOpen = next
                                if next {
                                    model.select(.bento)
                                } else {
                                    bentoStore.spotlightWidget = nil
                                }
                            }
                        } label: {
                            if bentoStore.inlineDIYOpen {
                                Text("✓ 完成 DIY")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
                                    .background(LiquidGlassPalette.sapphire, in: Capsule())
                            } else {
                                Text("✦ DIY (\(bentoStore.usedCells)/\(bentoStore.gridMaxCells)格)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(LiquidGlassPalette.sapphire)
                                    .padding(.horizontal, 8)
                                    .frame(height: 24)
                                    .liquidGlassPill(selected: false)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(bentoStore.inlineDIYOpen ? "完成画布编辑并收起下方抽屉" : "在灵动岛下方直接弹出组件库，对着上方实时修改")

                        Button {
                            openStudio?()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LiquidGlassPalette.inkSecondary(effectiveScheme))
                                .frame(width: 26, height: 26)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("灵动岛与同步源设置")
                    }
                    .padding(.trailing, 12)
                }
            }
            .frame(height: isProductShell ? 44 : 48)

            Rectangle()
                .fill(LiquidGlassPalette.divider(effectiveScheme))
                .frame(height: 0.7)
                .padding(.horizontal, 14)

            // Active Module Stage
            ZStack(alignment: .bottom) {
                moduleStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if isProductShell, let toast = telemetry.statusToast {
                    HStack(spacing: 6) {
                        Circle().fill(LiquidGlassPalette.sapphire).frame(width: 6, height: 6)
                        Text(toast)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .liquidGlassPill(selected: true)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: telemetry.statusToast)
        }
    }

    @ViewBuilder private var moduleStage: some View {
        if let module = model.selection.selected {
            switch module {
            case .bento:
                VStack(spacing: 0) {
                    BentoDenseCanvasGridView(bentoStore: bentoStore, editable: bentoStore.inlineDIYOpen, rowHeight: 74, spacing: 8)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)

                    if bentoStore.inlineDIYOpen {
                        Rectangle()
                            .fill(LiquidGlassPalette.divider(effectiveScheme))
                            .frame(height: 0.7)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)

                        InlineIslandDIYDrawerView(bentoStore: bentoStore)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

            case .system:
                SystemDeepTelemetryStageView(telemetry: telemetry)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)

            case .control:
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .brightVol, variantKey: "capsule_2x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .appMixer, variantKey: "horiz_2x1"))
                    }
                    .frame(height: 78)
                    HStack(spacing: 8) {
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .hideDock, variantKey: "tile_1x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .micMute, variantKey: "tile_1x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .caffeinate, variantKey: "tile_1x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .cleanKeyboard, variantKey: "tile_1x1"))
                    }
                    .frame(height: 78)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)

            case .toolkit:
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .winSnap, variantKey: "grid_2x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .trash, variantKey: "pill_2x1"))
                    }
                    .frame(height: 78)
                    HStack(spacing: 8) {
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .colorPick, variantKey: "tile_1x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .pasteClean, variantKey: "tile_1x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .hideDesktop, variantKey: "tile_1x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .shelf, variantKey: "mini_1x1"))
                    }
                    .frame(height: 78)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)

            case .aiDev:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 3) {
                            Button("AI 配额余量") { aiDevSubTab = "quota" }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: aiDevSubTab == "quota" ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(aiDevSubTab == "quota" ? Color.white.opacity(effectiveScheme == .dark ? 0.16 : 0.92) : .clear, in: Capsule())
                            Button("本机监听端口 (\(telemetry.devPorts.count))") { aiDevSubTab = "ports" }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: aiDevSubTab == "ports" ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(aiDevSubTab == "ports" ? Color.white.opacity(effectiveScheme == .dark ? 0.16 : 0.92) : .clear, in: Capsule())
                        }
                        .padding(2)
                        .liquidGlassWell(cornerRadius: 12)
                        Spacer()
                        Button { telemetry.refreshSlowMetricsAsync() } label: {
                            Label("刷新", systemImage: "arrow.clockwise").font(.system(size: 10.5))
                        }.buttonStyle(.plain).foregroundStyle(LiquidGlassPalette.sapphire)
                    }

                    if aiDevSubTab == "quota" {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(telemetry.aiProviders) { p in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("\(p.name) · \(p.plan)").font(.system(size: 11.5, weight: .semibold))
                                        Spacer()
                                        Text("\(p.percent)%").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                                    }
                                    MultiSegmentTelemetryBar(primaryFraction: Double(p.percent) / 100.0, secondaryFraction: 0)
                                    HStack {
                                        Text(p.badge).font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkSecondary(effectiveScheme))
                                        Spacer()
                                        Text(p.windowText).font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkTertiary(effectiveScheme))
                                    }
                                }
                                .padding(10)
                                .liquidGlassTile(cornerRadius: 15)
                            }
                        }
                    } else {
                        if telemetry.devPorts.isEmpty {
                            Text("当前未检测到活跃开发监听端口（Node / Vite / Python / Go 等启动后自动显示）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(LiquidGlassPalette.inkSecondary(effectiveScheme))
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .liquidGlassWell(cornerRadius: 14)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(telemetry.devPorts) { port in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(":\(port.port)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(LiquidGlassPalette.sapphire)
                                            Text(port.processName).font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkSecondary(effectiveScheme)).lineLimit(1)
                                        }
                                        Spacer()
                                        Button("释放") { telemetry.terminateDevPort(port) }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .liquidGlassPill(selected: true)
                                    }
                                    .padding(10)
                                    .liquidGlassTile(cornerRadius: 14)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)

            default:
                if let custom = customView?(module) {
                    custom.padding(14)
                } else if module == .calendar && enableSystemData {
                    AgendaView().padding(14)
                } else if module == .focus {
                    FocusTimerView(store: focusTimer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if module == .music && enableSystemData {
                    NowPlayingView().padding(16)
                } else if model.hidden.contains(module) {
                    Text("已隐藏").foregroundStyle(.secondary).padding(20)
                } else if let entries = model.contents[module], !entries.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                Text(entry).font(.system(size: 13)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(18)
                    }
                } else {
                    Text(model.states[module] == .failed ? "暂不可用" : (model.states[module] == .unavailable ? "未运行" : "暂无记录"))
                        .foregroundStyle(.secondary).padding(20)
                }
            }
        }
    }
}

private struct IslandLiquidTabStyle: ButtonStyle {
    let selected: Bool
    let compactFixedCell: Bool
    let scheme: ColorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        if compactFixedCell {
            configuration.label
                .foregroundStyle(selected ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                .frame(width: 34, height: 28)
                .background {
                    if selected || hovering || configuration.isPressed {
                        Capsule()
                            .fill(selected
                                  ? (scheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.92))
                                  : Color.primary.opacity(0.06))
                    }
                }
                .frame(width: 44, height: 42)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        } else {
            configuration.label
                .foregroundStyle(selected ? LiquidGlassPalette.inkPrimary(scheme) : LiquidGlassPalette.inkSecondary(scheme))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .liquidGlassPill(selected: selected)
                .frame(height: 40)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

@MainActor func makeIslandContentSnapshotView(model: IslandPreviewContent) -> NSView {
    let dummyDefaults = UserDefaults(suiteName: "local.moriq.island.snapshot.\(UUID().uuidString)")!
    return NSHostingView(
        rootView: IslandPrototypeView(
            expanded: true,
            model: model,
            focusTimer: FocusTimerStore(defaults: dummyDefaults),
            bentoStore: IslandBentoStore(defaults: dummyDefaults),
            isProductShell: false,
            enableSystemData: false,
            expand: {},
            select: { _ in }
        )
    )
}

@MainActor func makeIslandSnapshotView(expanded: Bool, columns: Int) -> NSView {
    let dummyDefaults = UserDefaults(suiteName: "local.moriq.island.snapshot.\(UUID().uuidString)")!
    return NSHostingView(
        rootView: IslandPrototypeView(
            expanded: expanded,
            model: IslandPreviewContent(),
            focusTimer: FocusTimerStore(defaults: dummyDefaults),
            bentoStore: IslandBentoStore(defaults: dummyDefaults),
            isProductShell: false,
            enableSystemData: false,
            expand: {},
            select: { _ in }
        )
    )
}

/// Original MORIQ Liquid Glass 4-Tab Deep Hardware & Power Stage
struct SystemDeepTelemetryStageView: View {
    @ObservedObject var telemetry: SystemTelemetryStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(SystemDetailTab.allCases) { tab in
                        let selected = telemetry.activeSystemDetailTab == tab
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                telemetry.activeSystemDetailTab = tab
                            }
                            if tab == .cpu || tab == .network {
                                telemetry.refreshProcessTelemetryAsync()
                            }
                        } label: {
                            Text(tab.title)
                                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? LiquidGlassPalette.inkPrimary(scheme) : LiquidGlassPalette.inkSecondary(scheme))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(selected ? Color.white.opacity(scheme == .dark ? 0.16 : 0.94) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .liquidGlassWell(cornerRadius: 13)

                Spacer()

                HStack(spacing: 5) {
                    Text("\(telemetry.thermalCelsius)°C")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                    Text("·").opacity(0.35)
                    Text(String(format: "%.1fW", telemetry.systemTotalWatts))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .liquidGlassPill()
            }

            switch telemetry.activeSystemDetailTab {
            case .overview:
                VStack(spacing: 8) {
                    BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .realMac, variantKey: "banner_4x1"))
                        .frame(height: 76)
                    HStack(spacing: 8) {
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .cpuGpu, variantKey: "wave_2x1"))
                            .onTapGesture { telemetry.activeSystemDetailTab = .cpu }
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .bluetooth, variantKey: "rings_2x1"))
                    }
                    .frame(height: 76)
                }

            case .cpu:
                cpuDeepView

            case .network:
                networkDeepView

            case .power:
                powerAndAwakeView
            }
        }
    }

    private var cpuDeepView: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("总负载").font(.system(size: 10, weight: .medium)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                    Text("\(Int(telemetry.cpuPercent.rounded()))%")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.sapphire)
                    Spacer()
                    Text("\(telemetry.perfCoreCount)P + \(telemetry.effCoreCount)E · \(telemetry.hardware.coreCount)核")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                }

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("性能核 P").font(.system(size: 9.5, weight: .medium)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer()
                            Text("\(telemetry.perfCoreCount)核").font(.system(size: 9, design: .monospaced)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                        }
                        Text("\(Int(telemetry.perfCorePercent.rounded()))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassWell(cornerRadius: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("能效核 E").font(.system(size: 9.5, weight: .medium)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                            Spacer()
                            Text("\(telemetry.effCoreCount)核").font(.system(size: 9, design: .monospaced)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                        }
                        Text("\(Int(telemetry.effCorePercent.rounded()))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassWell(cornerRadius: 10)
                }

                VStack(alignment: .leading, spacing: 3) {
                    MultiSegmentTelemetryBar(
                        primaryFraction: telemetry.cpuUserPercent / 100.0,
                        secondaryFraction: telemetry.cpuSystemPercent / 100.0,
                        primaryColor: LiquidGlassPalette.sapphire,
                        secondaryColor: LiquidGlassPalette.cpuStroke(scheme)
                    )
                    HStack {
                        Text("用户 \(Int(telemetry.cpuUserPercent.rounded()))%").foregroundStyle(LiquidGlassPalette.sapphire)
                        Spacer()
                        Text("系统 \(Int(telemetry.cpuSystemPercent.rounded()))%").foregroundStyle(LiquidGlassPalette.inkPrimary(scheme))
                        Spacer()
                        Text("空闲 \(Int(telemetry.cpuIdlePercent.rounded()))%").foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                }

                SparklineWaveformView(
                    primary: telemetry.cpuHistory,
                    secondary: nil,
                    primaryColor: LiquidGlassPalette.sapphire,
                    secondaryColor: .clear
                )
                .frame(height: 36)
                .liquidGlassWell(cornerRadius: 10)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("高占用应用").font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Button { telemetry.refreshProcessTelemetryAsync() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LiquidGlassPalette.sapphire)
                }
                if telemetry.topCPUProcesses.isEmpty {
                    Spacer()
                    Text("正在采集进程负载…").font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    Spacer()
                } else {
                    VStack(spacing: 4) {
                        ForEach(telemetry.topCPUProcesses.prefix(5)) { item in
                            HStack(spacing: 6) {
                                ProcessAppIconView(pid: item.pid)
                                Text(item.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(item.metricText)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(item.ratio > 0.35 ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkSecondary(scheme))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3.5)
                            .liquidGlassWell(cornerRadius: 8)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 16)
        }
        .frame(height: 186)
    }

    private var networkDeepView: some View {
        let downTxt = telemetry.netDownMBps >= 1.0 ? String(format: "%.1f MB/s", telemetry.netDownMBps) : String(format: "%.0f KB/s", telemetry.netDownMBps * 1024)
        let upTxt = telemetry.netUpMBps >= 1.0 ? String(format: "%.1f MB/s", telemetry.netUpMBps) : String(format: "%.0f KB/s", telemetry.netUpMBps * 1024)

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("实时下载").font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Text("↓ \(downTxt)")
                            .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassWell(cornerRadius: 10)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("实时上传").font(.system(size: 9.5)).foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Text("↑ \(upTxt)")
                            .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassWell(cornerRadius: 10)
                }

                SparklineWaveformView(
                    primary: telemetry.netDownHistory,
                    secondary: telemetry.netUpHistory,
                    primaryColor: LiquidGlassPalette.sapphire,
                    secondaryColor: LiquidGlassPalette.cpuStroke(scheme).opacity(0.65)
                )
                .frame(height: 46)
                .liquidGlassWell(cornerRadius: 10)

                VStack(spacing: 3) {
                    HStack {
                        Text("活跃网卡").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Spacer()
                        Text(telemetry.activeNetInterfaces.prefix(5).joined(separator: ", "))
                            .font(.system(size: 9.5, design: .monospaced))
                            .lineLimit(1)
                    }
                    HStack {
                        Text("本次会话累计").foregroundStyle(LiquidGlassPalette.inkSecondary(scheme))
                        Spacer()
                        Text("↓ \(SystemTelemetryStore.formatByteCount(telemetry.sessionDownBytes))  ·  ↑ \(SystemTelemetryStore.formatByteCount(telemetry.sessionUpBytes))")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LiquidGlassPalette.sapphire)
                    }
                }
                .font(.system(size: 10))
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("活跃网络应用").font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Button { telemetry.refreshProcessTelemetryAsync() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LiquidGlassPalette.sapphire)
                }
                if telemetry.topNetProcesses.isEmpty {
                    Spacer()
                    Text("当前无活跃 TCP 外联进程").font(.system(size: 10)).foregroundStyle(LiquidGlassPalette.inkTertiary(scheme))
                    Spacer()
                } else {
                    VStack(spacing: 4) {
                        ForEach(telemetry.topNetProcesses.prefix(5)) { item in
                            HStack(spacing: 6) {
                                ProcessAppIconView(pid: item.pid)
                                Text(item.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(item.metricText)
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(LiquidGlassPalette.sapphire)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3.5)
                            .liquidGlassWell(cornerRadius: 8)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .liquidGlassTile(cornerRadius: 16)
        }
        .frame(height: 186)
    }

    private var powerAndAwakeView: some View {
        let batStateLabel: String = {
            if telemetry.isCharging { return "充电中" }
            if telemetry.externalPowerConnected { return "电源直供" }
            return "电池放电"
        }()

        return VStack(spacing: 8) {
            HStack(spacing: 7) {
                powerMetricPod(
                    symbol: "powerplug.fill",
                    title: "适配器输入",
                    value: String(format: "%.1f W", telemetry.adapterInputWatts),
                    caption: telemetry.externalPowerConnected ? "已接通外接电源" : "未接电源",
                    accent: false
                )
                powerMetricPod(
                    symbol: telemetry.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                    title: "电池 \(telemetry.batteryPercent)%",
                    value: String(format: "%.1f W", abs(telemetry.batteryNetWatts)),
                    caption: "\(batStateLabel) · 健康 \(telemetry.batteryHealthPercent)%",
                    accent: false
                )
                powerMetricPod(
                    symbol: "laptopcomputer",
                    title: "整机系统功耗",
                    value: String(format: "%.1f W", telemetry.systemTotalWatts),
                    caption: "循环 \(telemetry.batteryCycles) 次 · \(telemetry.thermalCelsius)°C",
                    accent: true
                )
            }
            .frame(height: 68)

            VStack(spacing: 6) {
                timedAwakeRow(
                    symbol: "sun.max.fill",
                    title: "保持屏幕常亮",
                    status: telemetry.awakeRemainingLabel(active: telemetry.caffeinateActive, expiresAt: telemetry.displayAwakeExpiresAt, preset: telemetry.displayAwakeDuration),
                    active: telemetry.caffeinateActive,
                    selectedPreset: telemetry.displayAwakeDuration,
                    onToggle: {
                        telemetry.setDisplayAwake(enabled: !telemetry.caffeinateActive, duration: telemetry.displayAwakeDuration)
                    },
                    onSelectPreset: { preset in
                        telemetry.setDisplayAwake(enabled: true, duration: preset)
                    }
                )
                timedAwakeRow(
                    symbol: "moon.zzz.fill",
                    title: "合盖 / 系统不休眠",
                    status: telemetry.awakeRemainingLabel(active: telemetry.clamshellAwakeActive, expiresAt: telemetry.clamshellAwakeExpiresAt, preset: telemetry.clamshellAwakeDuration),
                    active: telemetry.clamshellAwakeActive,
                    selectedPreset: telemetry.clamshellAwakeDuration,
                    onToggle: {
                        telemetry.setClamshellAwake(enabled: !telemetry.clamshellAwakeActive, duration: telemetry.clamshellAwakeDuration)
                    },
                    onSelectPreset: { preset in
                        telemetry.setClamshellAwake(enabled: true, duration: preset)
                    }
                )
            }
        }
        .frame(height: 186)
    }

    private func powerMetricPod(symbol: String, title: String, value: String, caption: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent ? .white : LiquidGlassPalette.sapphire)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent ? .white.opacity(0.90) : LiquidGlassPalette.inkSecondary(scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(accent ? .white : LiquidGlassPalette.inkPrimary(scheme))
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(accent ? .white.opacity(0.78) : LiquidGlassPalette.inkTertiary(scheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .liquidGlassTile(cornerRadius: 15, active: accent)
    }

    private func timedAwakeRow(
        symbol: String,
        title: String,
        status: String,
        active: Bool,
        selectedPreset: AwakeDurationPreset,
        onToggle: @escaping () -> Void,
        onSelectPreset: @escaping (AwakeDurationPreset) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(active ? LiquidGlassPalette.sapphire : LiquidGlassPalette.sapphireSoft(scheme))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(active ? .white : LiquidGlassPalette.sapphire)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 11.5, weight: .semibold))
                        Text(status)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(active ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkTertiary(scheme))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                ForEach(AwakeDurationPreset.allCases) { preset in
                    let isChosen = active && selectedPreset == preset
                    Button {
                        onSelectPreset(preset)
                    } label: {
                        Text(preset.shortTitle)
                            .font(.system(size: 9.5, weight: isChosen ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(isChosen ? .white : LiquidGlassPalette.inkSecondary(scheme))
                            .padding(.horizontal, 6.5).padding(.vertical, 3)
                            .background(isChosen ? LiquidGlassPalette.sapphire : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .liquidGlassWell(cornerRadius: 12)

            Toggle("", isOn: Binding(get: { active }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .liquidGlassTile(cornerRadius: 14)
    }
}

private struct ProcessAppIconView: View {
    let pid: Int32
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 10))
                .foregroundStyle(LiquidGlassPalette.sapphire)
                .frame(width: 14, height: 14)
        }
    }
}

private struct SparklineWaveformView: View {
    let primary: [Double]
    let secondary: [Double]?
    let primaryColor: Color
    let secondaryColor: Color

    var body: some View {
        GeometryReader { geo in
            let allVals = primary + (secondary ?? [])
            let maxVal = max(1.0, (allVals.max() ?? 1.0) * 1.15)
            ZStack {
                if let sec = secondary, sec.count > 1 {
                    waveformPath(sec, size: geo.size, maxVal: maxVal, closeArea: false)
                        .stroke(secondaryColor, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
                if primary.count > 1 {
                    waveformPath(primary, size: geo.size, maxVal: maxVal, closeArea: true)
                        .fill(
                            LinearGradient(
                                colors: [primaryColor.opacity(0.24), primaryColor.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    waveformPath(primary, size: geo.size, maxVal: maxVal, closeArea: false)
                        .stroke(primaryColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private func waveformPath(_ data: [Double], size: CGSize, maxVal: Double, closeArea: Bool) -> Path {
        var path = Path()
        let w = max(1, size.width - 8)
        let h = max(1, size.height - 8)
        let stepX = w / CGFloat(max(1, data.count - 1))
        for (i, val) in data.enumerated() {
            let x = CGFloat(i) * stepX
            let norm = min(1.0, max(0.0, val / maxVal))
            let y = h - CGFloat(norm) * h
            if i == 0 {
                if closeArea {
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: x, y: y))
                } else {
                    path.move(to: CGPoint(x: x, y: y))
                }
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if closeArea {
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
        }
        return path
    }
}
