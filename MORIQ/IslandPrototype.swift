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

        bentoObserver = Publishers.Merge4(
            bentoStore.$gridMaxCells.map { _ in () },
            bentoStore.$activeCanvas.map { _ in () },
            bentoStore.$compactShell.map { _ in () },
            bentoStore.$compactSlots.map { _ in () }
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
        let modalHeld = (content === IslandPreviewContent.shared) && MoriqSyncHub.shared.showingGoogleConnectSheet
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
        let width = min(564, visible.width - 20)
        let selected = content.selection.selected ?? .bento
        let height: CGFloat
        switch selected {
        case .bento:
            let packed = BentoGridPacker.pack(entries: bentoStore.activeCanvas, maxCells: bentoStore.gridMaxCells, columns: 4)
            let gridH = CGFloat(packed.totalRows) * 74 + CGFloat(max(0, packed.totalRows - 1)) * 8
            height = min(visible.height - 40, gridH + 78)
        case .calendar:
            height = min(visible.height - 40, 356)
        case .system, .control, .toolkit:
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
        defaultModules: [.bento, .calendar, .system, .control, .toolkit, .aiDev, .focus, .music, .shelf]
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
                            let showLabel = isProductShell && (
                                bentoStore.tabLabelMode == .allLabels ||
                                (bentoStore.tabLabelMode == .activeOnly && isSelected)
                            )
                            Button {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
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
                            openStudio?()
                        } label: {
                            Text("✦ DIY (\(bentoStore.usedCells)/\(bentoStore.gridMaxCells))")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LiquidGlassPalette.sapphire)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .liquidGlassPill(selected: false)
                        }
                        .buttonStyle(.plain)
                        .help("打开置顶画布与多样式组件库")

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
                BentoDenseCanvasGridView(bentoStore: bentoStore, editable: false, rowHeight: 74, spacing: 8)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)

            case .system:
                VStack(spacing: 8) {
                    BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .realMac, variantKey: "banner_4x1"))
                        .frame(height: 78)
                    HStack(spacing: 8) {
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .cpuGpu, variantKey: "wave_2x1"))
                        BentoWidgetTileView(entry: BentoCanvasEntry(widgetID: .bluetooth, variantKey: "rings_2x1"))
                    }
                    .frame(height: 78)
                }
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
