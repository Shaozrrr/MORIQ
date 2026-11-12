import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import Carbon

private struct WheelFormat: Identifiable {
    let type: UTType
    let label: String
    var id: String { type.identifier }
}

@MainActor private final class WheelState: ObservableObject {
    @Published var formats: [WheelFormat] = []
    @Published var selected: Int? = nil
    @Published var visible = false
    @Published var message: String? = nil
    @Published var pdfTextOnly = false
    @Published var sheetSource = false
    @Published var animatedSource = false
    @Published var videoSource = false
    let blue = Color(red: 37/255, green: 99/255, blue: 1)
}

private struct ConverterWheel: View {
    @ObservedObject var state: WheelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let message = state.message {
                Text(message).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 17).padding(.vertical, 11)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
                    .transition(.opacity)
            } else if state.visible {
              ZStack {
                ForEach(Array(state.formats.enumerated()), id: \.element.id) { index, format in
                    let twoRings = state.formats.count > 8
                    let innerCount = WheelGeometry.innerCount(for: state.formats.count)
                    let inner = twoRings && index < innerCount
                    let groupCount = twoRings ? (inner ? innerCount : state.formats.count - innerCount) : state.formats.count
                    let groupIndex = twoRings && !inner ? index - innerCount : index
                    let angle = -Double.pi / 2 + Double(groupIndex) * 2 * .pi / Double(groupCount)
                    let labelRadius: CGFloat = twoRings ? (inner ? 86 : 153) : 120
                    let selected = state.selected == index
                    let shape = WheelSegment(index: groupIndex, count: groupCount, inner: twoRings ? (inner ? 56/184 : 122/184) : 56/184, outer: twoRings && inner ? 116/184 : 1)
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                            .overlay(shape.fill(selected ? state.blue.opacity(0.16) : Color(red: 0.75, green: 0.80, blue: 0.89).opacity(0.19)))
                            .overlay(shape.stroke(selected ? state.blue.opacity(0.58) : Color(red: 0.43, green: 0.50, blue: 0.63).opacity(0.22), lineWidth: selected ? 1.1 : 0.8))
                            .scaleEffect(selected && !reduceMotion ? 1.015 : 1)
                        Text(format.label).font(.system(size: twoRings && inner ? 11 : 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? state.blue : Color.primary.opacity(0.78))
                            .offset(x: CGFloat(cos(angle)) * labelRadius, y: CGFloat(sin(angle)) * labelRadius)
                    }
                    .frame(width: 368, height: 368)
                }
                if let selected = state.selected {
                    let format = state.formats[selected]
                    let sheetHint = ["csv", "tsv"].contains(format.type.preferredFilenameExtension?.lowercased() ?? "") ? "保留计算结果，不保留公式和样式" : "转换后请检查列宽与冻结窗格"
                    let hint = ArchiveConverter.isArchiveTarget(format.type) ? "保留原文件，生成压缩副本" : state.sheetSource ? sheetHint : state.videoSource && format.type == .gif ? "仅首条画面轨；无音频和字幕，颜色量化" : state.videoSource && ["AVI", "FLV"].contains(format.label) ? "不兼容轨道将尝试单独保存" : state.animatedSource ? (format.type == .gif ? "保留动态画面；颜色会量化" : "动图转视频；透明效果因格式而异") : state.pdfTextOnly ? (format.type.conforms(to: .image) ? "每页输出一张图片" : (format.type == .plainText ? "提取文字；扫描页在本机识别" : "扫描页保留为图片；复杂版式可能改变")) : (format.type == .jpeg ? "JPG 不保留透明背景" :
                        (format.type == .gif ? "GIF 将保存为单帧" : (format.label == "M4A" ? "M4A 使用有损 AAC 编码" : "")))
                    if !hint.isEmpty { Text(hint).font(.system(size: 9)).foregroundStyle(.secondary).offset(y: 200) }
                }
              }
              .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .frame(width: WheelGeometry.panelSize, height: WheelGeometry.panelSize)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18), value: state.selected)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.45, dampingFraction: 0.82), value: state.visible)
        .animation(.easeOut(duration: 0.18), value: state.message)
    }
}

#if DEBUG
private struct WheelInteractionFixture: View {
    @ObservedObject var state: WheelState
    var body: some View {
        VStack(spacing: 8) {
            Text(state.selected.map { "当前：\(state.formats[$0].label)" } ?? "拖动经过不同格式")
            ConverterWheel(state: state)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let point = CGPoint(x: value.location.x, y: WheelGeometry.panelSize - value.location.y)
                    state.selected = WheelGeometry.index(point: point, center: CGPoint(x: 210, y: 210), count: state.formats.count)
                })
        }.frame(width: 440, height: 460)
    }
}
#endif

private struct WheelSegment: Shape {
    let index: Int
    let count: Int
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let sweep = 360.0 / Double(count)
        let start = -90.0 + Double(index) * sweep - sweep / 2 + 1.5
        let end = -90.0 + Double(index) * sweep + sweep / 2 - 1.5
        var path = Path()
        path.addArc(center: center, radius: radius * outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        path.addArc(center: center, radius: radius * inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

@MainActor private final class WheelDropView: NSView {
    weak var owner: ConversionCoordinator?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.dragging(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { owner?.dragging(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { owner?.dragExited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { owner?.drop(sender) ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) { owner?.dragEnded() }
}

struct ConversionRecord: Identifiable {
    let id = UUID()
    let source: URL
    let output: URL?
    let message: String
    static func completionNotice(_ records: [ConversionRecord], requestedCount: Int, archive: Bool) -> String {
        if records.count == 1, let record = records.first { return record.message }
        let succeeded = records.filter { $0.output != nil }.count
        let failed = records.count - succeeded
        if archive && requestedCount > 1 && failed == 0 { return "已打包 \(requestedCount) 项 · 原文件已保留" }
        if failed == 0 { return "已处理 \(succeeded) 项 · 详情见菜单栏转换记录" }
        return "完成 \(succeeded) 项，失败 \(failed) 项 · 详情见菜单栏转换记录"
    }
}

@MainActor final class ConversionCoordinator {
    private let state = WheelState()
    private var panel: NSPanel?
    private var dragMonitor: DragActivityMonitor?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var urls: [URL] = []
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var noticeTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var inspectionID = UUID()
    private let presentsNotices: Bool
    private var queue: [([URL], UTType)] = []
    var onResults: (([ConversionRecord]) -> Void)?
    private var presentationID = UUID()
    private var releaseTime: Date?
    #if DEBUG
    private(set) var debugWheelPresentationCount = 0
    private var interactionFixtureWindow: NSWindow?
    #endif
    private var suppressedUntilMouseUp = false
    private var screenshotShortcutAt: Date?
    private var screenshotSelectionWasDown = false
    private var modifierBeganAt: TimeInterval?
    private var systemCaptureWasActive = false
    private var idleDragChangeCount = NSPasteboard(name: .drag).changeCount
    private let formats: [WheelFormat] = [WheelFormat(type: .png, label: "PNG"), WheelFormat(type: .jpeg, label: "JPG"), WheelFormat(type: .tiff, label: "TIFF"), WheelFormat(type: .heic, label: "HEIC"), WheelFormat(type: .pdf, label: "PDF"), WheelFormat(type: .gif, label: "GIF"), WheelFormat(type: UTType("com.microsoft.bmp")!, label: "BMP"), WheelFormat(type: UTType("public.avif")!, label: "AVIF"), WheelFormat(type: UTType("public.jpeg-2000")!, label: "JP2"), WheelFormat(type: UTType("org.webmproject.webp")!, label: "WEBP")]

    init(presentsNotices: Bool = true) { self.presentsNotices = presentsNotices }
    func enable() {
        guard dragMonitor == nil else { return }
        let monitor = DragActivityMonitor(tick: { [weak self] in self?.poll() }, onMouseDown: { [weak self] in
            self?.idleDragChangeCount = NSPasteboard(name: .drag).changeCount
        })
        dragMonitor = monitor; monitor.start()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            Task { @MainActor in self?.handleKey(e) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e)
            return e
        }
    }
    func disable() {
        dragMonitor?.stop(); dragMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
        cancelInspection()
        dismiss(suppress: false)
    }
    func cancel() { disable(); queue.removeAll(); workerID = UUID(); worker?.cancel(); worker = nil; noticeTask?.cancel() }
    #if DEBUG
    func verifySystemCaptureSuppression() -> Bool {
        guard InteractionArbiter.systemScreenshotActive else { return false }
        state.visible = true; poll(testDown: true)
        return !state.visible && systemCaptureWasActive && suppressedUntilMouseUp
    }
    func verifySystemCaptureRecovery() -> Bool {
        guard !InteractionArbiter.systemScreenshotActive else { return false }
        poll(testDown: false)
        return !systemCaptureWasActive && !suppressedUntilMouseUp && screenshotShortcutAt == nil
    }
    func verifyCaptureGuard() -> Bool {
        state.visible = true
        InteractionArbiter.selectingScreenshot = true
        poll()
        let blockedDuringSelection = !state.visible
        InteractionArbiter.selectingScreenshot = false
        screenshotShortcutAt = nil; screenshotSelectionWasDown = false
        for keyCode in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            screenshotShortcutAt = nil
            state.visible = true
            guard let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode)) else { return false }
            handleKey(shortcut)
            guard !state.visible, keyCode == kVK_ANSI_3 || screenshotShortcutAt != nil else { return false }
        }
        let configured = GlobalShortcutRegistry.shared.current(.screenshot)
        screenshotShortcutAt = nil; state.visible = true
        guard let configuredEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: configured.eventModifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(configured.keyCode)) else { return false }
        handleKey(configuredEvent)
        guard !state.visible, screenshotShortcutAt != nil else { return false }
        screenshotShortcutAt = nil; screenshotSelectionWasDown = false; suppressedUntilMouseUp = false
        return blockedDuringSelection
    }
    #endif
    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 { screenshotShortcutAt = nil; screenshotSelectionWasDown = false; dismiss(suppress: true); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let systemScreenshot = flags.contains(.command) && flags.contains(.shift) &&
            [UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5)].contains(event.keyCode)
        let moriqScreenshot = !GlobalShortcutRegistry.shared.isRecording && GlobalShortcutRegistry.shared.current(.screenshot).matches(event)
        if systemScreenshot || moriqScreenshot {
            // Full-screen capture is immediate; the other shortcuts may open a selector.
            screenshotShortcutAt = systemScreenshot && event.keyCode == UInt16(kVK_ANSI_3) ? nil : Date()
            screenshotSelectionWasDown = false
            cancelInspection(); dismiss(suppress: true)
        }
    }
    private var triggerHeld: Bool {
        return ConversionTrigger.isHeld(NSEvent.modifierFlags)
    }
    private func poll(testDown: Bool? = nil) {
        let down = testDown ?? (NSEvent.pressedMouseButtons & 1 != 0)
        let systemCaptureActive = InteractionArbiter.systemScreenshotActive
        if systemCaptureActive {
            systemCaptureWasActive = true; modifierBeganAt = nil
            if down { suppressedUntilMouseUp = true }
            cancelInspection(); if state.visible { dismiss(suppress: true) }
            return
        }
        if systemCaptureWasActive {
            systemCaptureWasActive = false; screenshotShortcutAt = nil; screenshotSelectionWasDown = false
            if down { suppressedUntilMouseUp = true }
        }
        if InteractionArbiter.selectingScreenshot {
            screenshotShortcutAt = Date(); screenshotSelectionWasDown = screenshotSelectionWasDown || down
            modifierBeganAt = nil; if down { suppressedUntilMouseUp = true }
            cancelInspection(); if state.visible { dismiss(suppress: true) }
            return
        }
        if let started = screenshotShortcutAt {
            if down { screenshotSelectionWasDown = true }
            if (!down && screenshotSelectionWasDown) || Date().timeIntervalSince(started) > 60 {
                screenshotShortcutAt = nil; screenshotSelectionWasDown = false
            } else {
                cancelInspection(); if state.visible { dismiss(suppress: true) }
                return
            }
        }
        if !down { suppressedUntilMouseUp = false; modifierBeganAt = nil; idleDragChangeCount = NSPasteboard(name: .drag).changeCount }
        guard down else {
            cancelInspection()
            if state.visible {
                if releaseTime == nil { releaseTime = Date() }
                if let releaseTime, Date().timeIntervalSince(releaseTime) > 0.25 { dismiss(suppress: false) }
            }
            return
        }
        releaseTime = nil
        guard triggerHeld, !suppressedUntilMouseUp else {
            modifierBeganAt = nil
            cancelInspection()
            if state.visible { dismiss(suppress: false) }; return
        }
        if state.visible { return }
        let now = ProcessInfo.processInfo.systemUptime
        if modifierBeganAt == nil { modifierBeganAt = now; return }
        guard now - (modifierBeganAt ?? now) >= 0.15 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != idleDragChangeCount else { return }
        guard let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty else { return }
        guard inspectionTask == nil else { return }
        let generation = UUID(); inspectionID = generation
        let dragChangeCount = pasteboard.changeCount
        inspectionTask = Task { @MainActor [weak self] in
            let inspection = await Task.detached(priority: .userInitiated) { () -> (document: DocumentConverter.Kind?, audio: Bool, video: [UTType], types: [UTType], animated: Bool, multipage: Bool) in
                let animated = ExternalMediaConverter.executable != nil && files.contains(where: ExternalMediaConverter.isAnimatedImage)
                let kinds = files.compactMap { DocumentConverter.kind($0) }
                if kinds.count == files.count, let first = kinds.first, kinds.allSatisfy({ $0 == first }) {
                    return (first, false, [], [], false, false)
                }
                if files.allSatisfy({ AudioConverter.supports($0) || (ExternalMediaConverter.executable != nil && ExternalMediaConverter.audioInputs.contains($0.pathExtension.lowercased())) }) { return (nil, true, ExternalMediaConverter.audioTargets(for: files), [], false, false) }
                if files.allSatisfy({ VideoConverter.supports($0) || (ExternalMediaConverter.executable != nil && (ExternalMediaConverter.videoInputs.contains($0.pathExtension.lowercased()) || ExternalMediaConverter.isAnimatedImage($0))) }), let first = files.first {
                    if ExternalMediaConverter.executable != nil { return (nil, false, ExternalMediaConverter.videoTargets(for: files), [], animated, false) }
                    var targets = VideoConverter.targets(for: first)
                    for file in files.dropFirst() { let eligible = VideoConverter.targets(for: file); targets.removeAll { !eligible.contains($0) } }
                    return (nil, false, targets, [], false, false)
                }
                let types = files.compactMap { file -> UTType? in
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), (CGImageSourceGetCount(source) == 1 || ImageConverter.isMultipageTIFF(file)),
                          let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
                          type.conforms(to: .image), (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).contains(identifier) else { return nil }
                    return type
                }
                return (nil, false, [], types, false, files.contains(where: ImageConverter.isMultipageTIFF))
            }.value
            guard let self, self.inspectionID == generation else { return }
            self.inspectionTask = nil
            guard !Task.isCancelled, !InteractionArbiter.screenshotActive, self.dragMonitor != nil, NSEvent.pressedMouseButtons & 1 != 0,
                  self.triggerHeld, !self.suppressedUntilMouseUp, NSPasteboard(name: .drag).changeCount == dragChangeCount else { return }
            var validTargets: [WheelFormat]
            if let kind = inspection.document {
                let sources = Set(files.map { $0.pathExtension.lowercased() })
                validTargets = DocumentConverter.targets(for: kind).filter { target in
                    !(sources.count == 1 && sources.contains(target.preferredFilenameExtension?.lowercased() ?? ""))
                }.map { WheelFormat(type: $0, label: ($0.preferredFilenameExtension ?? "文件").uppercased()) }
            } else if inspection.audio {
                let sources = Set(files.map { $0.pathExtension.lowercased() })
                validTargets = inspection.video.filter { !(sources.count == 1 && sources.contains(ExternalMediaConverter.fileExtension(for: $0) ?? "")) }
                    .map { WheelFormat(type: $0, label: (ExternalMediaConverter.fileExtension(for: $0) ?? "音频").uppercased()) }
            } else if !inspection.video.isEmpty {
                let sources = Set(files.map { $0.pathExtension.lowercased() })
                validTargets = inspection.video.filter { !(sources.count == 1 && sources.contains(ExternalMediaConverter.fileExtension(for: $0) ?? "")) }
                    .map { WheelFormat(type: $0, label: (ExternalMediaConverter.fileExtension(for: $0) ?? "文件").uppercased()) }
            } else {
                if inspection.types.count == files.count {
                    let available = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
                    validTargets = self.formats.filter { target in (target.type == .pdf || available.contains(target.type.identifier) || (target.label == "WEBP" && ExternalMediaConverter.executable != nil)) && !inspection.types.allSatisfy({ $0.conforms(to: target.type) }) }
                    if inspection.multipage { validTargets.removeAll { $0.type != .pdf && !(ImageConverter.allowed + ImageConverter.additionalOutputs).contains($0.type) && !($0.type.identifier == "org.webmproject.webp" && ExternalMediaConverter.executable != nil) } }
                } else { validTargets = [] }
            }
            if files.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }) {
                validTargets.append(WheelFormat(type: .zip, label: "ZIP"))
                validTargets.append(WheelFormat(type: ArchiveConverter.tarType, label: "TAR"))
                validTargets.append(WheelFormat(type: ArchiveConverter.tarGzipType, label: "TAR.GZ"))
            }
            guard !validTargets.isEmpty else {
                self.suppressedUntilMouseUp = true; self.showNotice("没有可用的目标格式")
                return
            }
            self.noticeTask?.cancel(); self.noticeTask = nil
            self.urls = files; self.state.formats = validTargets; self.state.selected = nil; self.state.message = nil
            self.state.pdfTextOnly = inspection.document == .pdf
            self.state.sheetSource = inspection.document == .sheet
            self.state.animatedSource = inspection.animated
            self.state.videoSource = !inspection.audio && !inspection.video.isEmpty && !inspection.animated
            self.show(at: NSEvent.mouseLocation)
        }
    }
    private func cancelInspection() {
        guard inspectionTask != nil else { return }
        inspectionID = UUID(); inspectionTask?.cancel(); inspectionTask = nil
    }

    private func show(at point: NSPoint) {
        #if DEBUG
        debugWheelPresentationCount += 1
        #endif
        let panel = self.panel ?? makePanel()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let side = WheelGeometry.panelSize
        let bounds = screen?.visibleFrame ?? NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let frame = WheelGeometry.frame(center: point, size: CGSize(width: side, height: side), visible: bounds)
        panel.setFrameOrigin(frame.origin)
        panel.ignoresMouseEvents = false
        let presentation = UUID(); presentationID = presentation
        panel.orderFrontRegardless()
        // Start after the panel is on-screen so the opening transition is visible.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, self.presentationID == presentation else { return }
            #if DEBUG
            let preview = CommandLine.arguments.contains("--preview-wheel")
            #else
            let preview = false
            #endif
            guard preview || (NSEvent.pressedMouseButtons & 1 != 0 && self.triggerHeld && !InteractionArbiter.screenshotActive) else {
                panel.orderOut(nil)
                return
            }
            self.state.visible = true
        }
    }
    #if DEBUG
    func verifyWheelExit() -> Bool {
        state.visible = true; state.selected = 0
        dragExited()
        let passed = state.visible && state.selected == nil
        state.visible = false
        return passed
    }
    func previewWheel() {
        let names = CommandLine.arguments.contains("--wheel-video-targets") ? ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "gif", "mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "caf", "zip", "tar", "tar.gz"] : ["heic", "jp2", "zip", "tar", "png", "jpg", "tiff", "pdf", "gif", "bmp", "avif", "webp"]
        state.formats = names.compactMap { name in
            let type: UTType?
            if name == "tar" { type = ArchiveConverter.tarType }
            else if name == "tar.gz" { type = ArchiveConverter.tarGzipType }
            else if name == "opus" { type = ExternalMediaConverter.opusType }
            else { type = UTType(filenameExtension: name) }
            return type.map { WheelFormat(type: $0, label: name.uppercased()) }
        }
        state.selected = 7
        state.videoSource = CommandLine.arguments.contains("--wheel-video-targets")
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        show(at: NSPoint(x: area.midX, y: area.midY))
    }
    func previewWheelInteraction() {
        NSApp.setActivationPolicy(.regular)
        let names = ["png", "jpg", "tiff", "heic", "pdf", "gif", "bmp", "webp"]
        state.formats = names.compactMap { name in UTType(filenameExtension: name).map { WheelFormat(type: $0, label: name.uppercased()) } }
        state.visible = true; state.selected = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 440, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "轮盘交互测试"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WheelInteractionFixture(state: state))
        interactionFixtureWindow = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    #endif
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: WheelGeometry.panelSize, height: WheelGeometry.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = WheelDropView(frame: NSRect(x: 0, y: 0, width: WheelGeometry.panelSize, height: WheelGeometry.panelSize)); view.owner = self
        let host = NSHostingView(rootView: ConverterWheel(state: state)); host.frame = view.bounds; host.autoresizingMask = [.width, .height]
        view.addSubview(host); panel.contentView = view; self.panel = panel
        return panel
    }
    private func index(for point: NSPoint) -> Int? {
        guard let panel, !state.formats.isEmpty else { return nil }
        let local = panel.convertPoint(fromScreen: point)
        return WheelGeometry.index(point: local, center: CGPoint(x: WheelGeometry.panelSize / 2, y: WheelGeometry.panelSize / 2), count: state.formats.count)
    }
    func dragging(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !InteractionArbiter.screenshotActive, state.visible, triggerHeld else { state.selected = nil; return [] }
        let next = index(for: NSEvent.mouseLocation)
        if next != state.selected, next != nil { InteractionFeedback.selection() }
        state.selected = next
        return state.selected == nil ? [] : .copy
    }
    func drop(_ sender: NSDraggingInfo) -> Bool {
        guard !InteractionArbiter.screenshotActive, state.visible, triggerHeld, let selected = index(for: NSEvent.mouseLocation), state.formats.indices.contains(selected) else { dismiss(suppress: true); return false }
        let format = state.formats[selected].type
        InteractionFeedback.confirmation()
        let files = urls
        dismiss(suppress: true)
        enqueueConversion(files, to: format)
        return true
    }
    func dragEnded() { if state.visible { dismiss(suppress: true) } }
    func dragExited() { state.selected = nil }
    private func dismiss(suppress: Bool) {
        presentationID = UUID()
        if suppress { suppressedUntilMouseUp = true }
        state.visible = false; state.selected = nil; urls = []; releaseTime = nil
        panel?.orderOut(nil)
    }
    func enqueueConversion(_ files: [URL], to format: UTType) {
        queue.append((files, format))
        guard worker == nil else { return }
        let id = UUID(); workerID = id
        worker = Task { @MainActor in
            while !queue.isEmpty && !Task.isCancelled {
                let (files, format) = queue.removeFirst()
                var records: [ConversionRecord] = []
                if files.count > 1, ArchiveConverter.isArchiveTarget(format), let first = files.first {
                    let child = Task.detached(priority: .userInitiated) { () -> ConversionRecord in
                        do {
                            let output = try ArchiveConverter().batch(inputs: files, outputDirectory: first.deletingLastPathComponent(), format: format)
                            return ConversionRecord(source: first, output: output, message: "已将 \(files.count) 项打包")
                        } catch ArchiveConversionError.duplicateNames {
                            return ConversionRecord(source: first, output: nil, message: "所选项目有同名文件，请先改名后打包")
                        } catch ArchiveConversionError.filesystem(let code) {
                            return ConversionRecord(source: first, output: nil, message: code == ENOSPC ? "磁盘空间不足" : "无法写入目标文件夹")
                        } catch {
                            return ConversionRecord(source: first, output: nil, message: "打包失败，请检查文件和磁盘空间")
                        }
                    }
                    let record = await withTaskCancellationHandler { await child.value } onCancel: { child.cancel() }
                    records.append(record)
                } else {
                for file in files {
                    guard !Task.isCancelled else { break }
                    let child = Task.detached(priority: .userInitiated) { () -> ConversionRecord in
                        do {
                            let directory = file.deletingLastPathComponent()
                            let existingExtension = file.pathExtension.lowercased()
                            let targetExtension = ExternalMediaConverter.fileExtension(for: format) ?? ""
                            let sameType = existingExtension == targetExtension || (format != ExternalMediaConverter.opusType && UTType(filenameExtension: existingExtension) == format)
                            let videoToAudio = ExternalMediaConverter.videoInputs.contains(existingExtension) && ExternalMediaConverter.audioTargets().contains(format)
                            let validImage = !format.conforms(to: .image) || CGImageSourceCreateWithURL(file as CFURL, nil) != nil
                            if files.count > 1 && sameType && validImage && !ArchiveConverter.isArchiveTarget(format) {
                                return ConversionRecord(source: file, output: file, message: "已是目标格式，保留原文件")
                            }
                            let output: URL
                            if format == .zip { output = try ArchiveConverter().zip(input: file, outputDirectory: directory) }
                            else if format == ArchiveConverter.tarType || format == ArchiveConverter.tarGzipType { output = try ArchiveConverter().tar(input: file, outputDirectory: directory, gzip: format == ArchiveConverter.tarGzipType) }
                            else if DocumentConverter.kind(file) != nil { output = try DocumentConverter().convert(input: file, outputDirectory: directory, format: format) }
                            else if ExternalMediaConverter.executable != nil && ExternalMediaConverter.audioInputs.contains(file.pathExtension.lowercased()) { output = try ExternalMediaConverter().convert(input: file, outputDirectory: directory, format: format, video: false) }
                            else if ExternalMediaConverter.executable != nil && (ExternalMediaConverter.videoInputs.contains(file.pathExtension.lowercased()) || ExternalMediaConverter.isAnimatedImage(file)) {
                                output = try ExternalMediaConverter().convert(input: file, outputDirectory: directory, format: format, video: !videoToAudio)
                            }
                            else if format.identifier == "org.webmproject.webp" && ExternalMediaConverter.executable != nil { output = try ExternalMediaConverter().convertImage(input: file, outputDirectory: directory) }
                            else if AudioConverter.supports(file) { output = try AudioConverter().convert(input: file, outputDirectory: directory, format: format) }
                            else if VideoConverter.supports(file) { output = try VideoConverter().convert(input: file, outputDirectory: directory, format: format) }
                            else { output = try ImageConverter().convert(input: file, outputDirectory: directory, format: format) }
                            let folder = (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                            let isSheet = DocumentConverter.kind(file) == .sheet
                            let sheetText = ["csv", "tsv"].contains(targetExtension)
                            let imageNotice: String?
                            if folder && ImageConverter.isMultipageTIFF(file) {
                                if format == .jpeg { imageNotice = "已逐页导出；JPG 使用有损压缩且不保留透明背景" }
                                else if format == .gif { imageNotice = "已逐页导出；GIF 颜色已量化，半透明将变化" }
                                else if format.identifier == "com.microsoft.bmp" { imageNotice = "已逐页导出；请检查透明背景" }
                                else if format.identifier == "public.avif" { imageNotice = "已逐页导出；方向已校正，部分元数据未保留" }
                                else if format.identifier == "org.webmproject.webp" { imageNotice = "已逐页导出；方向已校正，部分元数据未保留" }
                                else { imageNotice = "已逐页导出到文件夹" }
                            } else {
                                imageNotice = format.conforms(to: .image) ? ImageConverter.resultNotice(input: file, output: output) : nil
                            }
                            let animationNotice = ExternalMediaConverter.animationResultNotice(input: file, outputExtension: targetExtension)
                            let videoToGIF = ExternalMediaConverter.videoInputs.contains(existingExtension) && format == .gif
                            let videoSidecars = folder && ExternalMediaConverter.videoInputs.contains(existingExtension) && ["avi", "flv"].contains(targetExtension) && !videoToAudio
                            let message = videoToGIF ? "已转换首条画面轨；不包含音频和字幕，颜色已量化" : (DocumentConverter.pdfResultNotice(input: file, targetExtension: targetExtension) ?? animationNotice ?? imageNotice ?? (videoSidecars ? "已将主视频与独立轨道保存到文件夹" : (isSheet && sheetText ? (folder ? "已导出所有工作表；不保留公式和样式" : "已导出计算结果；不保留公式和样式") : (isSheet && ["ods", "xlsx"].contains(targetExtension) ? "已转换；请检查列宽和冻结窗格" : (folder && (ExternalMediaConverter.audioInputs.contains(existingExtension) || videoToAudio) ? "已将音频及附加数据保存到文件夹" : (videoToAudio ? "已提取音频" : (folder ? "已导出到文件夹" : "已完成")))))))
                            return ConversionRecord(source: file, output: output, message: message)
                        } catch ArchiveConversionError.filesystem(let code) {
                            return ConversionRecord(source: file, output: nil, message: code == ENOSPC ? "磁盘空间不足" : "无法写入目标文件夹")
                        } catch is ArchiveConversionError {
                            return ConversionRecord(source: file, output: nil, message: "压缩失败，请检查文件和磁盘空间")
                        } catch ExternalMediaError.filesystem(let code) {
                            return ConversionRecord(source: file, output: nil, message: code == ENOSPC ? "磁盘空间不足" : "无法写入目标文件夹")
                        } catch ExternalMediaError.timingUnsupported {
                            return ConversionRecord(source: file, output: nil, message: "该动画的帧时长过于特殊，暂无法准确转换为视频")
                        } catch ExternalMediaError.unsupportedTracks {
                            return ConversionRecord(source: file, output: nil, message: "文件含暂无法保留的附件或数据轨道，未进行转换")
                        } catch ExternalMediaError.failed {
                            return ConversionRecord(source: file, output: nil, message: "音视频转换失败，请检查文件、编码和磁盘空间")
                        } catch VideoConversionError.filesystem(let code) {
                            return ConversionRecord(source: file, output: nil, message: code == ENOSPC ? "磁盘空间不足" : "无法写入目标文件夹")
                        } catch VideoConversionError.failed {
                            return ConversionRecord(source: file, output: nil, message: "视频无法转换，请检查文件及编码")
                        } catch AudioConversionError.filesystem(let code) {
                            return ConversionRecord(source: file, output: nil, message: code == ENOSPC ? "磁盘空间不足" : "无法写入目标文件夹")
                        } catch AudioConversionError.precisionUnsupported {
                            return ConversionRecord(source: file, output: nil, message: "当前编码方式无法无损保留音频精度，请选择 WAV 或 CAF")
                        } catch AudioConversionError.invalidOutput {
                            return ConversionRecord(source: file, output: nil, message: "音频输出无法读取")
                        } catch AudioConversionError.failed {
                            return ConversionRecord(source: file, output: nil, message: "音频无法转换，请检查文件及编码")
                        } catch DocumentConversionError.noText {
                            return ConversionRecord(source: file, output: nil, message: "PDF 页面未识别出文字，无法完成该格式转换")
                        } catch DocumentConversionError.invalidInput {
                            return ConversionRecord(source: file, output: nil, message: "文件格式不符或文件已损坏，请检查原文件")
                        } catch DocumentConversionError.resourceUnavailable {
                            return ConversionRecord(source: file, output: nil, message: "文档引用的图片或资源无法读取，未生成缺失内容的文件")
                        } catch DocumentConversionError.engineMissing {
                            return ConversionRecord(source: file, output: nil, message: "未找到 LibreOffice 文档转换引擎")
                        } catch DocumentConversionError.packagedEngineMissing {
                            return ConversionRecord(source: file, output: nil, message: "转换组件缺失，请重新安装 MORIQ")
                        } catch DocumentConversionError.filesystem(let code) {
                            return ConversionRecord(source: file, output: nil, message: code == ENOSPC ? "磁盘空间不足" : "无法写入目标文件夹")
                        } catch ImageConversionError.filesystem(let code) {
                            let message = code == ENOSPC ? "磁盘空间不足" : (code == EACCES || code == EPERM ? "没有写入目标文件夹的权限" : "无法写入目标文件夹")
                            return ConversionRecord(source: file, output: nil, message: message)
                        } catch ImageConversionError.invalidInput {
                            return ConversionRecord(source: file, output: nil, message: "图片已损坏、不可读取或包含多帧")
                        } catch ImageConversionError.unsupportedOutput {
                            return ConversionRecord(source: file, output: nil, message: "当前系统不支持这种输出格式")
                        } catch {
                            return ConversionRecord(source: file, output: nil, message: "转换未完成，请检查文件和目标文件夹")
                        }
                    }
                    let record = await withTaskCancellationHandler { await child.value } onCancel: { child.cancel() }
                    records.append(record)
                }
                }
                guard !Task.isCancelled else { break }
                onResults?(records)
                let summary = ConversionRecord.completionNotice(records, requestedCount: files.count, archive: ArchiveConverter.isArchiveTarget(format))
                showNotice(summary)
            }
            if workerID == id { worker = nil }
        }
    }
    private func showNotice(_ text: String) {
        guard presentsNotices, !state.visible else { return }
        noticeTask?.cancel(); state.message = text
        showMessage(at: NSEvent.mouseLocation)
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !state.visible else { return }
            state.message = nil; panel?.orderOut(nil); noticeTask = nil
        }
    }
    private func showMessage(at point: NSPoint) {
        let panel = self.panel ?? makePanel()
        let bounds = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let side = WheelGeometry.panelSize
        panel.setFrameOrigin(NSPoint(x: min(max(point.x - side / 2, bounds.minX), bounds.maxX - side), y: min(max(point.y - side / 2, bounds.minY), bounds.maxY - side)))
        panel.ignoresMouseEvents = true; panel.orderFrontRegardless()
    }
}
