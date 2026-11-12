import AppKit
import SwiftUI
import Vortex
import UniformTypeIdentifiers

struct ShelfEntry: Identifiable {
    let id: UUID
    let url: URL
    var available: Bool { FileManager.default.fileExists(atPath: url.path) }
    var name: String { url.lastPathComponent }
}

enum ShelfTransfer {
    enum Result { case copied, unavailable, failed }
    static func copy(_ items: [ShelfEntry], to pasteboard: NSPasteboard) -> Result {
        guard !items.isEmpty, items.allSatisfy(\.available) else { return .unavailable }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items.map { $0.url as NSURL }) ? .copied : .failed
    }
}

@MainActor final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfEntry] = []
    private let defaults: UserDefaults
    private let key = "moriq.shelf.bookmarks"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; restore() }
    func add(_ urls: [URL]) {
        var known = Set(items.map(\.url))
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            let clean = url.standardizedFileURL
            guard known.insert(clean).inserted else { continue }
            items.append(ShelfEntry(id: UUID(), url: clean))
        }
        persist()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; persist() }
    func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) }; persist() }
    func refreshMovedFiles() async {
        guard let records = defaults.array(forKey: key) as? [[String: Any]], records.count == items.count else { return }
        let snapshot = zip(items, records).compactMap { item, record -> (UUID, URL, Data)? in
            guard let bookmark = record["bookmark"] as? Data else { return nil }
            return (item.id, item.url, bookmark)
        }
        let resolved = await Task.detached(priority: .utility) {
            snapshot.compactMap { id, oldURL, bookmark -> (UUID, URL, URL, Data?)? in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
                      url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                let newURL = url.standardizedFileURL
                guard newURL != oldURL || stale else { return nil }
                let renewed = try? newURL.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
                return (id, oldURL, newURL, renewed)
            }
        }.value
        guard var currentRecords = defaults.array(forKey: key) as? [[String: Any]], currentRecords.count == items.count else { return }
        var updated = items, needsPersist = false, changed = false
        for (id, oldURL, newURL, renewed) in resolved {
            guard let index = updated.firstIndex(where: { $0.id == id && $0.url == oldURL }) else { continue }
            if oldURL != newURL { updated[index] = ShelfEntry(id: id, url: newURL); changed = true }
            currentRecords[index]["path"] = newURL.path
            if let renewed { currentRecords[index]["bookmark"] = renewed }
            needsPersist = true
        }
        if changed { items = updated }
        if needsPersist { defaults.set(currentRecords, forKey: key) }
    }
    private func persist() {
        let previous = defaults.array(forKey: key) as? [[String: Any]] ?? []
        let oldBookmarks = Dictionary(previous.compactMap { record -> (String, Data)? in
            guard let path = record["path"] as? String, let bookmark = record["bookmark"] as? Data else { return nil }
            return (path, bookmark)
        }, uniquingKeysWith: { first, _ in first })
        let bookmarks: [[String: Any]] = items.map { item in
            var record: [String: Any] = ["path": item.url.path]
            if let bookmark = try? item.url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) { record["bookmark"] = bookmark }
            else if let bookmark = oldBookmarks[item.url.path] { record["bookmark"] = bookmark }
            return record
        }
        defaults.set(bookmarks, forKey: key)
    }
    private func restore() {
        guard let records = defaults.array(forKey: key) as? [[String: Any]] else { return }
        items = records.compactMap { record in
            var stale = false
            let restored = (record["bookmark"] as? Data).flatMap { try? URL(resolvingBookmarkData: $0, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
            let fallback = (record["path"] as? String).map { URL(fileURLWithPath: $0) }
            guard let url = restored ?? fallback, url.isFileURL else { return nil }
            return ShelfEntry(id: UUID(), url: url.standardizedFileURL)
        }
    }
}

enum ShelfDropDecoder {
    static func canLoad(_ provider: NSItemProvider) -> Bool { provider.canLoadObject(ofClass: NSURL.self) }
    static func load(_ provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        guard canLoad(provider) else { completion(nil); return }
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let url = object as? URL, url.isFileURL else { completion(nil); return }
            completion(url)
        }
    }
}

@MainActor final class ShelfCoordinator {
    private let injectedStore: ShelfStore?
    private lazy var store: ShelfStore = injectedStore ?? ShelfStore()
    private let state = ShelfState()
    private var panel: NSPanel?
    private var dragMonitor: DragActivityMonitor?
    private var closeTask: Task<Void, Never>?
    private var idleChangeCount = NSPasteboard(name: .drag).changeCount
    private var edgeSince: Date?
    private var mouseWasInside = false
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var dropEpoch = UUID()
    #if DEBUG
    private var lastReportedProximity: Int = -1
    #endif

    init(store: ShelfStore? = nil) { self.injectedStore = store }
    func enable() {
        guard dragMonitor == nil else { return }
        let monitor = DragActivityMonitor(tick: { [weak self] in self?.poll() }, onMouseDown: { [weak self] in
            self?.idleChangeCount = NSPasteboard(name: .drag).changeCount
        })
        dragMonitor = monitor; monitor.start()
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updatePointer() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updatePointer(); return event
        }
        if !store.items.isEmpty { position(expanded: false, at: NSEvent.mouseLocation); panel?.orderFrontRegardless(); state.visible = true; updatePointer() }
    }
    func disable() {
        dropEpoch = UUID(); dragMonitor?.stop(); dragMonitor = nil; closeTask?.cancel(); state.visible = false; state.pendingDrops = 0; state.dropError = nil; panel?.orderOut(nil)
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor); self.globalPointerMonitor = nil }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor); self.localPointerMonitor = nil }
    }
    private func updatePointer() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation, bounds = panel.frame
        state.pointer = CGPoint(x: point.x - bounds.minX, y: bounds.maxY - point.y)
        let dx = max(0, bounds.maxX - point.x)
        let dy = abs(point.y - bounds.midY) * 0.65
        let distance = hypot(dx, dy)
        let target = min(1, max(0, 1 - distance / 190))
        if abs(state.proximity - target) > 0.015 {
            withAnimation(.easeOut(duration: 0.18)) { state.proximity = target }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--verify-pointer-proximity") {
            let step = Int((target * 10).rounded())
            if step != lastReportedProximity { lastReportedProximity = step; print("TEST_PROXIMITY=\(step)"); fflush(stdout) }
        }
        #endif
        // Transparent particles never block other apps; only the last 24 points accept clicks.
        if !state.expanded { panel.ignoresMouseEvents = !(dx <= 24 && bounds.minY <= point.y && point.y <= bounds.maxY) }
    }
    private func poll() {
        // An outgoing drag uses the same system drag pasteboard as incoming
        // files. Do not reopen or schedule collapse for our own drag.
        guard !state.exporting else { edgeSince = nil; closeTask?.cancel(); return }
        guard !InteractionArbiter.screenshotActive else { edgeSince = nil; return }
        let board = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            idleChangeCount = board.changeCount
            if edgeSince != nil, state.expanded {
                closeTask?.cancel()
                closeTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled else { return }
                    self.collapse()
                }
            }
            edgeSince = nil
            return
        }
        guard !ConversionTrigger.isHeld(NSEvent.modifierFlags), board.changeCount != idleChangeCount else { edgeSince = nil; return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }), point.x >= screen.frame.maxX - 14 else { edgeSince = nil; return }
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        if edgeSince == nil { edgeSince = Date(); position(expanded: false, at: point); panel?.orderFrontRegardless(); state.visible = true; updatePointer() }
        if let edgeSince, Date().timeIntervalSince(edgeSince) >= 0.1, !state.expanded {
            position(expanded: true, at: point); panel?.orderFrontRegardless(); state.visible = true
        }
    }
    private func makePanel() -> NSPanel {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 250), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.level = .floating
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = ShelfView(store: store, state: state,
                             toggle: { [weak self] in self?.toggle() },
                             drop: { [weak self] providers in self?.receive(providers) ?? false },
                             hover: { [weak self] inside in self?.hover(inside) })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
    private func position(expanded: Bool, at point: NSPoint) {
        if expanded && !state.expanded { Task { await store.refreshMovedFiles() } }
        let panel = self.panel ?? makePanel()
        let screenUnderPointer = NSScreen.screens.first(where: { $0.frame.contains(point) })
        let isDragging = NSEvent.pressedMouseButtons & 1 != 0
        guard let screen = (panel.isVisible && !isDragging ? panel.screen : screenUnderPointer) ?? screenUnderPointer ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        let width: CGFloat = 346
        let height: CGFloat = min(480, bounds.height - 16)
        // Keep the handle anchored in place while its surface grows out from the edge.
        let anchorY = panel.isVisible ? panel.frame.midY : point.y
        let y = min(max(anchorY - height / 2, bounds.minY + 8), bounds.maxY - height - 8)
        let target = NSRect(x: screen.frame.maxX - width, y: y, width: width, height: height)
        panel.ignoresMouseEvents = !expanded
        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            state.expanded = expanded; panel.setFrame(target, display: true)
        } else if expanded {
            // Give the content its final layout before revealing it. Animating the
            // window width itself squeezes text and icons during the first frames.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.setFrame(target, display: true, animate: false)
            }
            withAnimation(.easeOut(duration: 0.24)) { state.expanded = true }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { state.expanded = false }
            Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .milliseconds(190))
                guard let self, let panel, !self.state.expanded else { return }
                panel.setFrame(target, display: true)
                self.updatePointer()
            }
        }
    }
    private func toggle() {
        closeTask?.cancel(); mouseWasInside = false
        position(expanded: !state.expanded, at: NSEvent.mouseLocation)
        panel?.orderFrontRegardless(); state.visible = true; updatePointer()
    }
    /// Keyboard access is available only while the shelf feature is enabled.
    func toggleFromShortcut() {
        guard dragMonitor != nil else { return }
        if state.expanded { collapse() }
        else { toggle() }
    }
    private func hover(_ inside: Bool) {
        if inside { mouseWasInside = true; closeTask?.cancel(); return }
        guard state.expanded, mouseWasInside, !state.exporting else { return }
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !self.state.exporting else { return }
            self.collapse()
        }
    }
    private func collapse() {
        guard state.mayCollapse else { return }
        if store.items.isEmpty { state.expanded = false; state.visible = false; panel?.orderOut(nil) }
        else { position(expanded: false, at: NSEvent.mouseLocation) }
    }
    #if DEBUG
    func verifyMotion() async -> Bool {
        enable()
        guard let panel, panel.isVisible else { return false }
        let rightEdge = panel.frame.maxX
        toggle()
        var widths: [CGFloat] = []
        var maxDrift: CGFloat = 0
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(20))
            widths.append(panel.frame.width)
            maxDrift = max(maxDrift, abs(panel.frame.maxX - rightEdge))
        }
        let expanded = panel.frame.width > 340 && state.expanded
        toggle()
        for _ in 0..<18 {
            try? await Task.sleep(for: .milliseconds(20))
            maxDrift = max(maxDrift, abs(panel.frame.maxX - rightEdge))
        }
        let collapsed = panel.frame.width > 340 && !state.expanded
        let frames = Set(widths.map { Int($0.rounded()) }).count
        print("TEST_SHELF_MOTION frames=\(frames) edgeDrift=\(Int(maxDrift.rounded()))")
        disable()
        return expanded && collapsed && maxDrift < 2
    }
    func verifyDropBatch() async -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-shelf-batch-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) } catch { return false }
        defer { disable(); try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("first.txt"), b = directory.appendingPathComponent("second.txt"), missing = directory.appendingPathComponent("missing.txt")
        do { try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: b) } catch { return false }
        enable()
        guard receive([a, missing, b].map { NSItemProvider(object: $0 as NSURL) }) else { return false }
        for _ in 0..<250 where state.pendingDrops > 0 { try? await Task.sleep(for: .milliseconds(20)) }
        let passed = state.pendingDrops == 0 && store.items.map(\.url) == [a, b].map(\.standardizedFileURL)
            && state.dropError?.contains("1") == true && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path)
        return passed
    }
    #endif
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter { ShelfDropDecoder.canLoad($0) }
        guard !supported.isEmpty else { return false }
        closeTask?.cancel()
        state.dropError = nil
        state.pendingDrops += 1
        let unsupported = providers.count - supported.count
        let epoch = dropEpoch
        let batch = OrderedDropBatch(count: supported.count) { [weak self] urls, failed in
            Task { @MainActor in
                guard let self, self.dragMonitor != nil, self.dropEpoch == epoch else { return }
                self.state.pendingDrops = max(0, self.state.pendingDrops - 1)
                let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                let failures = failed + unsupported + urls.count - valid.count
                let count = self.store.items.count
                self.store.add(valid)
                let added = self.store.items.count - count
                if added > 0 { InteractionFeedback.confirmation() }
                self.closeTask?.cancel()
                if failures > 0 {
                    self.state.dropError = "有 \(failures) 个文件未能添加，请检查后重试。"
                } else if added == 0 {
                    self.state.dropError = "所选文件已在暂存架中。"
                } else {
                    self.state.dropError = nil
                    self.closeTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        guard !Task.isCancelled else { return }
                        self.collapse()
                    }
                }
            }
        }
        for (index, provider) in supported.enumerated() {
            ShelfDropDecoder.load(provider) { url in batch.submit(url, at: index) }
        }
        return true
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ShelfState: ObservableObject {
    @Published var expanded = false
    @Published var visible = false
    @Published var proximity: CGFloat = 0
    @Published var pointer: CGPoint = .zero
    // This is a coordinator guard, not visual state. Publishing it can
    // rebuild the SwiftUI drag source as a native dragging session begins.
    var exporting = false
    @Published var dropError: String?
    @Published var pendingDrops = 0
    var mayCollapse: Bool { expanded && !exporting && pendingDrops == 0 && dropError == nil }
}
private struct ShelfRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var state: ShelfState
    let toggle: () -> Void
    let drop: ([NSItemProvider]) -> Bool
    let hover: (Bool) -> Void
    var pasteboard: NSPasteboard = .general
    @State private var targeted = false
    @State private var selected: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var selectionFocus: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var selectionRect: CGRect?
    @State private var marqueeRejected = false
    @State private var copied = false
    @State private var transferError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue = Color(red: 37/255, green: 99/255, blue: 1)
    private func moveSelection(from fallback: UUID, direction: Int, extend: Bool) {
        let ids = store.items.map(\.id)
        guard !ids.isEmpty, let current = ids.firstIndex(of: selectionFocus ?? fallback) else { return }
        let next = min(max(current + direction, 0), ids.count - 1)
        let nextID = ids[next]
        if extend {
            let anchor = selectionAnchor.flatMap { ids.firstIndex(of: $0) } ?? current
            if selectionAnchor == nil { selectionAnchor = ids[anchor] }
            selected = Set(ids[min(anchor, next)...max(anchor, next)])
        } else {
            selected = [nextID]; selectionAnchor = nextID
        }
        selectionFocus = nextID; transferError = nil
    }
    private func copySelection() {
        let items = store.items.filter { selected.contains($0.id) }
        guard !items.isEmpty else { return }
        switch ShelfTransfer.copy(items, to: pasteboard) {
        case .unavailable: transferError = "部分文件不可用，请先取消选择"; return
        case .failed: transferError = "复制失败，请重试"; return
        case .copied: break
        }
        transferError = nil
        #if DEBUG
        if CommandLine.arguments.contains("--preview-shelf-selection") { print("TEST_SHELF_COPIED=\(pasteboard.pasteboardItems?.count ?? 0)"); fflush(stdout) }
        #endif
        copied = true; InteractionFeedback.confirmation()
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
    var body: some View {
        HStack(spacing: 0) {
            if state.expanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("暂存架").font(.system(size: 16, weight: .semibold))
                            Text("文件保留在原来的位置").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: toggle) { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("收起暂存架")
                    }.padding(.bottom, 14)
                    if state.pendingDrops > 0 || state.dropError != nil {
                        Text(state.pendingDrops > 0 ? "正在添加文件…" : (state.dropError ?? ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                    }
                    if store.items.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundStyle(.secondary)
                            Text("拖入文件，随时取用").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        HStack {
                            Button("全选") {
                                selected = Set(store.items.map(\.id))
                            }.buttonStyle(.plain).keyboardShortcut("a", modifiers: .command).foregroundStyle(blue).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(selected.isEmpty ? "\(store.items.count) 个文件" : "已选 \(selected.count) 个")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.bottom, 9)
                        ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(store.items) { item in
                                    ShelfItemRow(item: item, selected: selected.contains(item.id), dragURLs: store.items.filter { selected.contains($0.id) }.map(\.url), select: { flags in
                                        transferError = nil
                                        selectionFocus = item.id
                                        if flags.contains(.shift), let anchor = selectionAnchor,
                                           let start = store.items.firstIndex(where: { $0.id == anchor }),
                                           let end = store.items.firstIndex(where: { $0.id == item.id }) {
                                            let range = min(start, end)...max(start, end)
                                            let ids = Set(store.items[range].map(\.id))
                                            selected = flags.contains(.command) ? selected.union(ids) : ids
                                        } else {
                                            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                                            selectionAnchor = item.id
                                        }
                                    }, selectForDrag: {
                                        selected = [item.id]; selectionAnchor = item.id; selectionFocus = item.id; transferError = nil
                                    }, selectAll: { selected = Set(store.items.map(\.id)) }, moveSelection: { direction, extend in moveSelection(from: item.id, direction: direction, extend: extend) }, copySelection: copySelection, dragState: { state.exporting = $0 }, transferFailure: { transferError = "部分文件不可用，请先取消选择" }, remove: { selected.remove(item.id); store.remove(item.id) })
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: ShelfRowFrames.self, value: [item.id: geometry.frame(in: .named("shelf-selection"))])
                                    })
                                }
                            }.frame(maxWidth: .infinity, alignment: .top)
                        }
                        .coordinateSpace(name: "shelf-selection")
                        .onPreferenceChange(ShelfRowFrames.self) { rowFrames = $0 }
                        .overlay(alignment: .topLeading) {
                            if let rect = selectionRect {
                                Rectangle().fill(blue.opacity(0.12)).overlay(Rectangle().stroke(blue.opacity(0.75), lineWidth: 1))
                                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
                            }
                        }
                        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("shelf-selection"))
                            .onChanged { value in
                                if selectionRect == nil && !marqueeRejected {
                                    marqueeRejected = rowFrames.values.contains { $0.contains(value.startLocation) }
                                }
                                guard !marqueeRejected else { return }
                                let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y), width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                                selectionRect = rect
                                selected = Set(rowFrames.filter { rect.intersects($0.value) }.map(\.key))
                            }
                            .onEnded { _ in selectionRect = nil; marqueeRejected = false })
                        .onChange(of: selectionFocus) { _, focus in
                            if let focus { proxy.scrollTo(focus, anchor: nil) }
                        }
                        }
                        Divider().padding(.top, 8)
                        HStack(spacing: 10) {
                            Button(copied ? "已复制" : "复制已选", action: copySelection).disabled(selected.isEmpty)
                            Button("移除已选") { store.remove(selected); selected.removeAll() }.disabled(selected.isEmpty)
                            Spacer(minLength: 0)

                        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                         .foregroundStyle(selected.isEmpty ? Color.secondary : blue).padding(.top, 11)
                        if let transferError { Text(transferError).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5) }
                    }
                }
                .padding(20).frame(width: 316, height: min(460, max(260, 160 + CGFloat(store.items.count) * 48)), alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .allowsHitTesting(false)
                }
                .padding(.vertical, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
            Button(action: toggle) {
                ShelfStardust(proximity: state.proximity, visible: state.visible, pointer: state.pointer, expanded: state.expanded)
                    .frame(width: state.expanded ? 30 : 160, height: 232)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(state.expanded ? "收起文件暂存架" : "打开文件暂存架")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipped()
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted, perform: drop)
        .onChange(of: targeted) { _, value in if value { InteractionFeedback.selection() } }
        .onChange(of: store.items.map(\.id)) { _, ids in
            selected.formIntersection(ids)
            if let anchor = selectionAnchor, !ids.contains(anchor) { selectionAnchor = nil }
            if let focus = selectionFocus, !ids.contains(focus) { selectionFocus = nil }
            transferError = nil
        }
    }
}


struct ShelfStardust: View {
    let proximity: CGFloat
    let visible: Bool
    let pointer: CGPoint
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blue = Color(red: 0.16, green: 0.39, blue: 1)
    @State private var particles = VortexSystem(
        tags: ["dust"], position: [0.96, 0.5], shape: .box(width: 0.12, height: 0.60),
        birthRate: 20, lifespan: 3.2, lifespanVariation: 1.2,
        speed: 0.025, speedVariation: 0.045, angle: .degrees(270), angleRange: .degrees(150),
        attractionStrength: 0.10, dampingFactor: 0.25,
        colors: .ramp(.init(red: 0.30, green: 0.54, blue: 1, opacity: 0),
                      .init(red: 0.25, green: 0.52, blue: 1, opacity: 0.8),
                      .init(red: 0.44, green: 0.68, blue: 1, opacity: 0)),
        size: 0.40, sizeVariation: 0.22, sizeMultiplierAtDeath: 0.55)
    var body: some View {
        GeometryReader { geo in
            let q = min(1, max(0, proximity))
            ZStack(alignment: .trailing) {
                // The glow fades to transparent well before the panel's bounds. No
                // blurred layer or vertical beam is allowed to end at a hard edge.
                Ellipse()
                    .fill(RadialGradient(colors: [blue.opacity(0.22 + q * 0.16), blue.opacity(0.08 + q * 0.09), .clear], center: .center, startRadius: 0, endRadius: 57))
                    .frame(width: 114, height: 114)
                    .scaleEffect(x: 0.70 + q * 0.10, y: 1.30)
                    .offset(x: 57)
                Ellipse()
                    .fill(RadialGradient(colors: [blue.opacity(0.55 + q * 0.2), blue.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 40))
                    .frame(width: 80, height: 80)
                    .scaleEffect(x: 0.22, y: 1.05)
                    .offset(x: 40)
                if visible && !reduceMotion {
                    VortexViewReader { proxy in
                        VortexView(particles, targetFrameRate: 30) {
                            Circle().fill(.white).frame(width: 6, height: 6).blur(radius: 0.5).tag("dust")
                        }
                        .opacity(0.78 + q * 0.22)
                        .onChange(of: pointer) { _, point in
                            let localX = point.x - (expanded ? 316 : 186)
                            proxy.attractTo(q > 0.15 ? CGPoint(x: localX, y: point.y) : nil)
                        }
                    }.allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
             .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                .init(color: .black, location: 0.8), .init(color: .clear, location: 1)
             ], startPoint: .top, endPoint: .bottom))
        }.allowsHitTesting(false)
    }
}

private struct ShelfItemRow: View {
    let item: ShelfEntry
    let selected: Bool
    let dragURLs: [URL]
    let select: (NSEvent.ModifierFlags) -> Void
    let selectForDrag: () -> Void
    let selectAll: () -> Void
    let moveSelection: (Int, Bool) -> Void
    let copySelection: () -> Void
    let dragState: (Bool) -> Void
    let transferFailure: () -> Void
    let remove: () -> Void
    @State private var available: Bool?
    @State private var icon: NSImage?
    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Group {
                    if let icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary) }
                }.frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if available == false { Text("文件不可用").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
            .overlay(ShelfFileInteraction(name: item.name, urls: selected ? dragURLs : [item.url], select: select, selectForDrag: selectForDrag, isSelected: selected, selectAll: selectAll, moveSelection: moveSelection, copySelection: copySelection, dragState: dragState, transferFailure: transferFailure))
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("从暂存架移除 \(item.name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .task(id: item.url) {
            let path = item.url.path
            let result = await Task.detached(priority: .utility) {
                let exists = FileManager.default.fileExists(atPath: path)
                return (exists, exists ? NSWorkspace.shared.icon(forFile: path) : nil)
            }.value
            guard !Task.isCancelled else { return }
            available = result.0; icon = result.1
        }
    }
}


/// AppKit supplies one native pasteboard item per selected file.
private struct ShelfFileInteraction: NSViewRepresentable {
    let name: String
    let urls: [URL]
    let select: (NSEvent.ModifierFlags) -> Void
    let selectForDrag: () -> Void
    let isSelected: Bool
    let selectAll: () -> Void
    let moveSelection: (Int, Bool) -> Void
    let copySelection: () -> Void
    let dragState: (Bool) -> Void
    let transferFailure: () -> Void
    func makeNSView(context: Context) -> ShelfFileDragView { ShelfFileDragView() }
    func updateNSView(_ view: ShelfFileDragView, context: Context) {
        view.name = name; view.urls = urls; view.select = select; view.selectForDrag = selectForDrag; view.isSelected = isSelected; view.selectAll = selectAll; view.moveSelection = moveSelection; view.copySelection = copySelection; view.dragState = dragState; view.transferFailure = transferFailure
    }
}
final class ShelfFileDragView: NSView, NSDraggingSource {
    var name = ""
    var urls: [URL] = []
    var select: ((NSEvent.ModifierFlags) -> Void)?
    var selectForDrag: (() -> Void)?
    var isSelected = false
    var selectAll: (() -> Void)?
    var moveSelection: ((Int, Bool) -> Void)?
    var copySelection: (() -> Void)?
    var dragState: ((Bool) -> Void)?
    var transferFailure: (() -> Void)?
    private var downEvent: NSEvent?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 125 || event.keyCode == 126) && flags.intersection([.command, .control, .option]).isEmpty {
            moveSelection?(event.keyCode == 125 ? 1 : -1, flags.contains(.shift)); return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll?(); return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers?.lowercased() == "c" {
            copySelection?(); return
        }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        downEvent = event
        #if DEBUG
        if CommandLine.arguments.contains("--preview-shelf-only") || CommandLine.arguments.contains("--preview-shelf-drag") { print("TEST_DRAG_DOWN"); fflush(stdout) }
        #endif
    }
    override func mouseUp(with event: NSEvent) {
        guard let downEvent else { return }
        self.downEvent = nil
        select?(downEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downEvent, !urls.isEmpty else { return }
        // AppKit may deliver a dragged event for normal hand jitter during a
        // click. Keep the click pending until the pointer has visibly moved.
        let start = downEvent.locationInWindow, current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }
        #if DEBUG
        if CommandLine.arguments.contains("--preview-shelf-only") || CommandLine.arguments.contains("--preview-shelf-drag") { print("TEST_DRAG_BEGIN count=\(urls.count)"); fflush(stdout) }
        #endif
        self.downEvent = nil
        if !isSelected { selectForDrag?() }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { transferFailure?(); return }
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 3)) * 3
            item.setDraggingFrame(NSRect(x: 8 + offset, y: offset, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        dragState?(true)
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragState?(false)
        #if DEBUG
        if CommandLine.arguments.contains("--preview-shelf-only") || CommandLine.arguments.contains("--preview-shelf-drag") { print("TEST_DRAG_END operation=\(operation.rawValue)"); fflush(stdout) }
        #endif
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityPerformPress() -> Bool { select?([]); return true }
}
