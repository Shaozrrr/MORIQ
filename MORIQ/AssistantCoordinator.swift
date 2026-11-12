import AppKit
import SwiftUI
import Carbon
import ScreenCaptureKit
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

private let screenTextRecognizer = BoundedTextRecognizer()
private func encodeScreenFrame(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
private func prepareScreenFrame(_ image: CGImage) -> (text: String, jpeg: Data?) {
    guard let data = encodeScreenFrame(image) else { return ("", nil) }
    let text = screenTextRecognizer.recognize(timeout: 0.8) { (try? OCREngine().recognize(image)) ?? "" }
    return (text, data)
}

/// Receives a bounded stream of screen frames on its own serial queue. It never
/// writes them to disk or sends them; a user question controls network sending.
private final class LiveScreenOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let onFrame: (CGImage, Data, Date) -> Void
    let onStop: () -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    init(onFrame: @escaping (CGImage, Data, Date) -> Void, onStop: @escaping () -> Void) {
        self.onFrame = onFrame; self.onStop = onStop
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let receivedAt = Date()
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(frame, from: frame.extent), let jpeg = encodeScreenFrame(image) else { return }
        onFrame(image, jpeg, receivedAt)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop() }
}

@MainActor final class AssistantCoordinator {
    private var previousApp: NSRunningApplication?
    private var panel: AssistantPanel?
    private let model = AssistantModel()
    private var captureTask: Task<Void, Never>?
    private var captureID = UUID()
    private var liveTask: Task<Void, Never>?
    private var liveStream: SCStream?
    private var liveOutput: LiveScreenOutput?
    private var liveStreamDisplayID: UInt32?
    private var liveStreamID = UUID()
    private var liveGeneration = UUID()
    private var liveStreamFailed = false
    private var liveReading = false
    private var latestLive: (NSImage, String, String)?
    private var recentFrames = ScreenFrameBuffer(capacity: 12)
    private var lastLiveCaptureAt: Date?
    private var panelAnchor: NSPoint?
    private var panelExpanded = false
    #if DEBUG
    private var verifyPrepared: (() -> Void)?
    private var verifyCaptureOverride: (() async throws -> CGImage)?
    private var verifyCaptureDisplayID: UInt32 = .max
    private var verifyMissingImage = false
    private var verifyIncludeOwnApp = false
    private var verifyLiveFrameCount = 0
    #endif
    func enable() -> OSStatus {
        GlobalShortcutRegistry.shared.enable(.assistant) { [weak self] in self?.show() }
    }
    func disable() {
        GlobalShortcutRegistry.shared.disable(.assistant)
        stopLive(); captureTask?.cancel(); captureTask = nil; model.stop(); model.clearScreen(); model.panelVisible = false; panel?.orderOut(nil)
    }
    #if DEBUG
    func verifyFullDisplayCapture() async -> Bool {
        guard let (image, _) = try? await captureDisplay(), let screen = NSScreen.main else { return false }
        let expected = screen.frame.width / screen.frame.height
        let actual = CGFloat(image.width) / CGFloat(image.height)
        return image.width >= 800 && abs(expected - actual) < 0.03
    }
    func verifyLiveCapture() async -> Bool {
        previousApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        startLive()
        for _ in 0..<80 where latestLive == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let captured = model.liveScreen && liveStream != nil && !liveStreamFailed && latestLive != nil && !recentFrames.isEmpty
        stopLive()
        return captured && !model.liveScreen && latestLive == nil && recentFrames.isEmpty
    }
    func verifyLiveSoak() async -> Bool {
        startLive()
        for _ in 0..<80 where latestLive == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard model.liveScreen, liveStream != nil, !liveStreamFailed, latestLive != nil else { stopLive(); return false }
        var largestHistory = recentFrames.byteCount
        for _ in 0..<35 {
            try? await Task.sleep(for: .seconds(1))
            guard model.liveScreen, liveStream != nil, !liveStreamFailed else { stopLive(); return false }
            largestHistory = max(largestHistory, recentFrames.byteCount)
            guard largestHistory <= 12 * 1024 * 1024 else { stopLive(); return false }
        }
        stopLive()
        print("TEST_SOAK_MAX_HISTORY_BYTES=\(largestHistory)")
        return !model.liveScreen && latestLive == nil && recentFrames.isEmpty && recentFrames.byteCount == 0
    }
    func verifyLiveDynamicSoak() async -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        let window = NSPanel(contentRect: NSRect(x: 40, y: 80, width: 120, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .red; window.orderFrontRegardless()
        verifyIncludeOwnApp = true; verifyLiveFrameCount = 0
        defer { stopLive(); verifyIncludeOwnApp = false; window.close() }
        startLive()
        for _ in 0..<80 where latestLive == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard liveStream != nil, !liveStreamFailed, latestLive != nil else { return false }
        var largestHistory = recentFrames.byteCount
        for tick in 0..<20 {
            window.backgroundColor = tick.isMultiple(of: 2) ? .blue : .red
            try? await Task.sleep(for: .seconds(1))
            guard model.liveScreen, liveStream != nil, !liveStreamFailed else { return false }
            largestHistory = max(largestHistory, recentFrames.byteCount)
            guard largestHistory <= 12 * 1024 * 1024 else { return false }
        }
        let received = verifyLiveFrameCount
        stopLive()
        print("TEST_DYNAMIC_FRAMES=\(received) TEST_MAX_HISTORY_BYTES=\(largestHistory)")
        return received >= 15 && recentFrames.isEmpty && recentFrames.byteCount == 0 && !model.liveScreen
    }
    func verifyFreshCapture() async -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        startLive()
        for _ in 0..<100 where latestLive == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard model.liveScreen, latestLive != nil else { stopLive(); return false }
        // An intentionally stale sample must not be reused in the next request.
        recentFrames.removeAll(); recentFrames.append(Data("stale test frame".utf8), capturedAt: Date(timeIntervalSinceNow: -60)); lastLiveCaptureAt = Date(timeIntervalSinceNow: -60)
        var prepared = false
        verifyPrepared = { prepared = true }
        model.onRequireScreen = { [weak self] in self?.captureForeground(sendAfterCapture: true) }
        model.input = "测试当前画面"; model.send()
        for _ in 0..<100 where !prepared { try? await Task.sleep(for: .milliseconds(100)) }
        let decoded = model.screenFrames.first.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let passed = prepared && model.screenFrames.count == 1 && decoded != nil && model.screenFrames.first != Data("stale test frame".utf8)
        verifyPrepared = nil; model.onRequireScreen = nil; stopLive(); invalidateCapture(); model.clearScreen()
        return passed
    }
    func verifyMissingFrameRejected() async -> Bool {
        guard CGPreflightScreenCaptureAccess(), let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { return false }
        verifyCaptureOverride = { image }; verifyMissingImage = true
        model.onRequireScreen = { [weak self] in self?.captureForeground(sendAfterCapture: true) }
        model.input = "描述屏幕"; model.send()
        // Vision may initialize its recognition models on the first request.
        for _ in 0..<500 where model.screenLoading { try? await Task.sleep(for: .milliseconds(20)) }
        let passed = model.error == "屏幕图像处理失败，请重试。" && model.messages.isEmpty && !model.working && model.screenFrames.isEmpty
        if !passed { print("missing-frame diagnostic: loading=\(model.screenLoading), working=\(model.working), messages=\(model.messages.count), frames=\(model.screenFrames.count), error=\(model.error ?? "none")") }
        verifyMissingImage = false; verifyCaptureOverride = nil; model.onRequireScreen = nil; invalidateCapture(); model.clearScreen(); model.error = nil
        return passed
    }
    func verifyScreenHistoryDisplayIsolation() async -> Bool {
        guard CGPreflightScreenCaptureAccess(), let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { return false }
        verifyCaptureDisplayID = 22; verifyCaptureOverride = { image }; model.liveScreen = true
        recentFrames.removeAll()
        recentFrames.append(Data("different display".utf8), capturedAt: Date(), displayID: 11)
        recentFrames.append(Data("same display".utf8), capturedAt: Date(), displayID: 22)
        lastLiveCaptureAt = Date()
        var prepared = false
        verifyPrepared = { prepared = true }
        captureForeground(sendAfterCapture: true)
        for _ in 0..<500 where model.screenLoading { try? await Task.sleep(for: .milliseconds(20)) }
        let passed = prepared && model.screenFrames.count == 2 && model.screenFrames.first == Data("same display".utf8)
        verifyPrepared = nil; verifyCaptureOverride = nil; verifyCaptureDisplayID = .max
        stopLive(); invalidateCapture(); model.clearScreen(); model.error = nil
        return passed
    }
    func verifyLiveRestartIsolation() async -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        var held: CheckedContinuation<CGImage, Error>?
        verifyCaptureOverride = { try await withCheckedThrowingContinuation { held = $0 } }
        startLive()
        for _ in 0..<100 where held == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard let pending = held else { stopLive(); verifyCaptureOverride = nil; return false }
        stopLive(); startLive()
        recentFrames.append(Data("new session".utf8), capturedAt: Date(), displayID: 22)
        pending.resume(throwing: ContextCaptureError.noWindow)
        try? await Task.sleep(for: .milliseconds(100))
        let passed = model.liveScreen && recentFrames.recent(at: Date(), limit: 5, displayID: 22) == [Data("new session".utf8)]
        stopLive(); verifyCaptureOverride = nil
        return passed
    }
    func verifyLiveStreamRecovery() async -> Bool {
        startLive()
        for _ in 0..<80 where liveStream == nil || latestLive == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard liveStream != nil, latestLive != nil, !liveStreamFailed else { stopLive(); return false }
        let firstID = liveStreamID, oldOutput = liveOutput
        liveStreamFailed = true
        var recovered = false
        for _ in 0..<150 {
            if liveStreamID != firstID, liveStream != nil, !liveStreamFailed {
                recovered = true; break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let framesBefore = verifyLiveFrameCount
        for _ in 0..<80 where recovered && verifyLiveFrameCount == framesBefore { try? await Task.sleep(for: .milliseconds(100)) }
        if let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() {
            oldOutput?.onStop()
            oldOutput?.onFrame(image, Data("obsolete frame".utf8), Date())
            try? await Task.sleep(for: .milliseconds(100))
        } else { stopLive(); return false }
        let staleFrames = recentFrames.recent(at: Date(), limit: 12).contains(Data("obsolete frame".utf8))
        let passed = recovered && verifyLiveFrameCount > framesBefore && model.liveScreen && !liveStreamFailed && !staleFrames
        stopLive()
        return passed
    }
    func verifyStreamFrameChanges() async -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        let window = NSPanel(contentRect: NSRect(x: 40, y: 80, width: 320, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .red; window.orderFrontRegardless()
        defer { window.close() }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return false }
            let config = SCStreamConfiguration(); config.width = 320; config.height = 180
            config.minimumFrameInterval = CMTime(value: 1, timescale: 4); config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
            var colors: Set<String> = []
            let output = LiveScreenOutput(onFrame: { image, jpeg, _ in
                guard !jpeg.isEmpty else { return }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let color = bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB) else { return }
                let label = color.redComponent > color.blueComponent + 0.3 ? "red" : (color.blueComponent > color.redComponent + 0.3 ? "blue" : "other")
                Task { @MainActor in colors.insert(label) }
            }, onStop: {})
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "local.moriq.verify-stream"))
            try await stream.startCapture()
            for _ in 0..<80 where !colors.contains("red") { try? await Task.sleep(for: .milliseconds(50)) }
            window.backgroundColor = .blue
            for _ in 0..<80 where !colors.contains("blue") { try? await Task.sleep(for: .milliseconds(50)) }
            try? await stream.stopCapture()
            return colors.contains("red") && colors.contains("blue")
        } catch { return false }
    }
    func verifyContinuousAnswers(_ frames: [CGImage]) async -> Bool {
        guard frames.count == 3 else { return false }
        var current = frames[1]
        verifyCaptureOverride = { current }
        model.liveScreen = true
        model.onRequireScreen = { [weak self] in self?.captureForeground(sendAfterCapture: true) }
        func setPrior(_ image: CGImage) {
            recentFrames.removeAll()
            if let jpeg = prepareScreenFrame(image).jpeg { recentFrames.append(jpeg, capturedAt: Date(), displayID: UInt32.max) }
            lastLiveCaptureAt = Date()
        }
        defer {
            verifyCaptureOverride = nil; model.onRequireScreen = nil; stopLive(); invalidateCapture(); model.stop(); model.clearScreen()
        }
        setPrior(frames[0]); model.input = "现在屏幕上的项目代码是什么？只回答数字。"; model.send()
        for _ in 0..<300 {
            if !model.screenLoading && !model.working { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !model.screenLoading, !model.working, model.error == nil,
              let first = model.messages.last?.content, first.contains("4826"), !first.contains("7392") else { return false }
        current = frames[2]; setPrior(frames[1])
        model.input = "现在的项目代码是多少？只回答数字。"; model.send()
        for _ in 0..<300 {
            if !model.screenLoading && !model.working { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !model.screenLoading, !model.working, model.error == nil,
              let second = model.messages.last?.content else { return false }
        return second.contains("2764") && !second.contains("4826")
    }
    func showPreview(expanded: Bool) {
        show(preview: true)
        if expanded { model.messages = [ChatMessage(role: "assistant", content: "这是**本地界面测试**。\n```swift\nprint(\"MORIQ\")\n```")]; model.onExpand?(true) }
    }
    func verifyPanelLifecycle() async -> Bool {
        show(preview: true)
        guard let panel, panel.isVisible else { return false }
        let anchor = panel.frame.minY
        model.onExpand?(true)
        try? await Task.sleep(for: .milliseconds(350))
        let expandedY = panel.frame.minY
        for _ in 0..<5 { model.onExpand?(true) }
        try? await Task.sleep(for: .milliseconds(350))
        let stable = abs(panel.frame.minY - expandedY) < 1 && abs(expandedY - anchor) < 1
        dismissPanel()
        return stable && !panel.isVisible
    }
    #endif
    private func show(preview: Bool = false) {
        guard GlobalShortcutRegistry.shared.isEnabled(.assistant) || preview else { return }
        if panel?.isVisible == true { dismissPanel(); return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if panel == nil {
            let next = AssistantPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            next.isOpaque = false; next.backgroundColor = .clear; next.hasShadow = true
            next.level = .floating; next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            model.onClearScreen = { [weak self] in self?.invalidateCapture() }
            model.onRequireScreen = { [weak self] in
                guard let self else { return }
                // A previous sample can be many seconds old after a long answer.
                // Capture a fresh frame for every submitted question.
                self.captureForeground(sendAfterCapture: true)
            }
            next.contentView = NSHostingView(rootView: AssistantInput(model: model, capture: { [weak self] in self?.captureForeground() }, close: { [weak self] in self?.dismissPanel() }))
            model.onExpand = { [weak self, weak next] expanded in
                guard let self, let next, self.panelExpanded != expanded else { return }
                self.panelExpanded = expanded
                let old = next.frame
                let desired = expanded ? NSSize(width: 400, height: 320) : NSSize(width: 360, height: 48)
                let bounds = next.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? old
                let size = NSSize(width: min(desired.width, bounds.width), height: min(desired.height, bounds.height))
                let anchor = self.panelAnchor ?? NSPoint(x: old.midX, y: old.minY)
                let target = NSRect(x: min(max(anchor.x - size.width / 2, bounds.minX), bounds.maxX - size.width),
                                    y: min(max(anchor.y, bounds.minY), bounds.maxY - size.height),
                                    width: size.width, height: size.height)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { next.setFrame(target, display: true) }
                else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; next.animator().setFrame(target, display: true) } }
            }
            next.dismiss = { [weak self] in self?.dismissPanel() }
            panel = next
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panelAnchor = NSPoint(x: frame.midX, y: frame.minY + 20)
        panel?.setFrameOrigin(NSPoint(x: frame.midX - (panel?.frame.width ?? 360) / 2, y: frame.minY + 20))
        model.panelVisible = true
        panel?.makeKeyAndOrderFront(nil)
        if !preview { startLive() }
    }
    private func dismissPanel() {
        stopLive(); invalidateCapture(); model.stop(); model.clearScreen(); model.panelVisible = false
        panel?.orderOut(nil); previousApp?.activate(options: [])
    }
    private func stopLive() {
        liveGeneration = UUID(); liveTask?.cancel(); liveTask = nil; model.liveScreen = false
        liveStreamID = UUID()
        let stream = liveStream; liveStream = nil; liveOutput = nil; liveStreamDisplayID = nil
        if let stream { Task { try? await stream.stopCapture() } }
        latestLive = nil; recentFrames.removeAll(); lastLiveCaptureAt = nil
    }
    private func startLive() {
        guard !model.liveScreen else { return }
        guard CGPreflightScreenCaptureAccess() else { model.error = "请先完成屏幕录制授权。"; model.onExpand?(true); return }
        model.liveScreen = true; liveStreamFailed = false
        let generation = UUID(); liveGeneration = generation
        liveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.model.liveScreen && self.liveGeneration == generation {
                var displayChanged = false
                self.liveStreamFailed = false
                do {
                    #if DEBUG
                    if self.verifyCaptureOverride != nil { throw ContextCaptureError.noWindow }
                    #endif
                    try await self.startLiveStream(generation: generation)
                    while !Task.isCancelled && self.model.liveScreen && self.liveGeneration == generation && !self.liveStreamFailed {
                        try await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, self.liveGeneration == generation else { return }
                        self.recentFrames.prune(at: Date())
                        if ScreenDisplaySelection.shouldRestart(active: self.liveStreamDisplayID, target: self.currentDisplayID()) {
                            displayChanged = true; break
                        }
                    }
                } catch { }
                guard !Task.isCancelled, self.model.liveScreen, self.liveGeneration == generation else { return }
                self.liveStreamID = UUID()
                let oldStream = self.liveStream
                self.liveStream = nil; self.liveOutput = nil; self.liveStreamDisplayID = nil
                if let oldStream { try? await oldStream.stopCapture() }
                guard !Task.isCancelled, self.model.liveScreen, self.liveGeneration == generation else { return }
                if displayChanged { continue }
                // Keep snapshots available while periodically retrying a failed stream.
                for _ in 0..<3 {
                    guard !Task.isCancelled, self.model.liveScreen, self.liveGeneration == generation else { return }
                    await self.readLiveScreen()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
    private func currentDisplayID() -> UInt32? {
        let screen = panel?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func startLiveStream(generation: UUID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = currentDisplayID()
        guard let index = ScreenDisplaySelection.index(target: target, candidates: content.displays.map(\.displayID)),
              liveGeneration == generation, model.liveScreen else { throw ContextCaptureError.noWindow }
        let display = content.displays[index]
        var ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        #if DEBUG
        if verifyIncludeOwnApp { ownApps = [] }
        #endif
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1.0, 2400.0 / Double(max(display.width, display.height)))
        config.width = max(1, Int(Double(display.width) * scale)); config.height = max(1, Int(Double(display.height) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
        let streamID = UUID(); liveStreamID = streamID
        let output = LiveScreenOutput(onFrame: { [weak self] image, jpeg, date in
            Task { @MainActor [weak self] in
                guard let self, self.model.liveScreen, self.liveGeneration == generation, self.liveStreamID == streamID else { return }
                self.recentFrames.append(jpeg, capturedAt: date, displayID: display.displayID)
                #if DEBUG
                self.verifyLiveFrameCount += 1
                #endif
                self.latestLive = (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), "", "整个屏幕")
                self.lastLiveCaptureAt = date
            }
        }, onStop: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.liveGeneration == generation, self.liveStreamID == streamID else { return }
                self.liveStreamFailed = true
            }
        })
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "local.moriq.screen-stream", qos: .utility))
        liveOutput = output; liveStream = stream; liveStreamDisplayID = display.displayID
        try await stream.startCapture()
        guard !Task.isCancelled, liveGeneration == generation, model.liveScreen else {
            try? await stream.stopCapture(); throw CancellationError()
        }
    }
    private func captureDisplay() async throws -> (CGImage, UInt32) {
        #if DEBUG
        if let verifyCaptureOverride { return (try await verifyCaptureOverride(), verifyCaptureDisplayID) }
        #endif
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = currentDisplayID()
        guard let index = ScreenDisplaySelection.index(target: displayID, candidates: content.displays.map(\.displayID)) else {
            // Never silently substitute a different monitor when displays change.
            throw ContextCaptureError.noWindow
        }
        let display = content.displays[index]
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1.0, 2400.0 / Double(max(display.width, display.height)))
        config.width = max(1, Int(Double(display.width) * scale)); config.height = max(1, Int(Double(display.height) * scale)); config.showsCursor = false
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), display.displayID)
    }
    private func readLiveScreen() async {
        guard !liveReading else { return }
        liveReading = true; defer { liveReading = false }
        do {
            let (image, displayID) = try await captureDisplay()
            let capturedAt = Date()
            let prepared = await Task.detached(priority: .utility) { prepareScreenFrame(image) }.value
            guard !Task.isCancelled, model.liveScreen else { return }
            if let jpeg = prepared.jpeg {
                recentFrames.append(jpeg, capturedAt: capturedAt, displayID: displayID)
            }
            latestLive = (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), String(prepared.text.prefix(12_000)), "整个屏幕")
            lastLiveCaptureAt = capturedAt
        } catch {
            guard !Task.isCancelled, model.liveScreen else { return }
            latestLive = nil; recentFrames.removeAll(); lastLiveCaptureAt = nil
        }
    }
    private func invalidateCapture() {
        captureID = UUID(); captureTask?.cancel(); captureTask = nil
    }
    private func captureForeground(sendAfterCapture: Bool = false) {
        guard !model.screenLoading else { return }
        guard CGPreflightScreenCaptureAccess() else { model.error = "请先完成屏幕录制授权。"; model.onExpand?(true); return }
        model.clearScreen(); model.error = nil; model.screenLoading = true; model.onExpand?(true)
        let history = recentFrames
        let lastHistoryCapture = sendAfterCapture && model.liveScreen ? lastLiveCaptureAt : nil
        let id = UUID(); captureID = id
        captureTask = Task { @MainActor in
            do {
                let (image, displayID) = try await captureDisplay()
                try Task.checkCancellation()
                let prepared = await Task.detached(priority: .userInitiated) { prepareScreenFrame(image) }.value
                try Task.checkCancellation()
                guard captureID == id else { return }
                model.screenPreview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                model.screenText = String(prepared.text.prefix(12_000))
                // Do not silently fall back to OCR: the user asked about the
                // screen itself, and text alone cannot describe its visuals.
                #if DEBUG
                let imageData = verifyMissingImage ? nil : prepared.jpeg
                #else
                let imageData = prepared.jpeg
                #endif
                guard let jpeg = imageData else {
                    model.screenPreview = nil; model.screenText = ""; model.screenFrames = []
                    model.error = "屏幕图像处理失败，请重试。"
                    model.screenLoading = false; captureTask = nil
                    return
                }
                let now = Date()
                let recentEnough = lastHistoryCapture.map { let age = now.timeIntervalSince($0); return age >= 0 && age < 5 } ?? false
                let priorFrames = recentEnough ? history.recent(at: now, limit: 10, displayID: displayID) : []
                model.screenFrames = priorFrames + [jpeg]
                model.screenSource = "整个屏幕"
            } catch is CancellationError { } catch ContextCaptureError.noWindow {
                if captureID == id { model.error = "无法读取当前显示器，请重新唤出助手后重试。" }
            } catch {
                if captureID == id { model.error = "无法读取整个屏幕，请确认已获得屏幕录制权限。" }
            }
            guard captureID == id else { return }
            model.screenLoading = false; captureTask = nil
            if sendAfterCapture, model.error == nil, model.screenPreview != nil {
                #if DEBUG
                if let verifyPrepared { verifyPrepared(); return }
                #endif
                model.send()
            }
        }
    }
    private enum ContextCaptureError: Error { case noWindow }

}
final class AssistantPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil); dismiss?() }
}
struct AssistantInput: View {
    @ObservedObject var model: AssistantModel
    let capture: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            if !model.messages.isEmpty || model.error != nil {
                HStack {
                    Text("MORIQ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("新对话") { model.reset() }.buttonStyle(.borderless).controlSize(.small)
                }.padding(.horizontal, 16).padding(.top, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.messages) { message in
                                Group {
                                    if message.role == "assistant" { ChatResponseView(content: message.content.isEmpty ? "正在思考…" : message.content) }
                                    else { Text(message.displayContent ?? message.content).textSelection(.enabled) }
                                }
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                    .id(message.id)
                                    .contextMenu { if message.role == "assistant" && !message.content.isEmpty { Button("复制回复") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) } } }
                            }
                            if let error = model.error {
                                HStack { Text(error).font(.caption).foregroundStyle(.secondary); Spacer(); Button("重试") { model.retry() }.buttonStyle(.borderless).controlSize(.small).disabled(model.working) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(16)
                    }.onChange(of: model.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider().padding(.horizontal, 16)
            }
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭助手").accessibilityLabel("关闭助手")
                Button(action: capture) { Image(systemName: "text.viewfinder") }.buttonStyle(.plain)
                    .disabled(model.screenLoading || model.working).help("读取整个屏幕文字")
                    .accessibilityLabel("读取整个屏幕文字")
                TextField("问问当前屏幕…", text: $model.input).textFieldStyle(.plain).focused($focused).onSubmit { model.send() }
                if model.working { Button { model.stop() } label: { Image(systemName: "stop.circle.fill") }.buttonStyle(.plain) }
                else { Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.plain).disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(.horizontal, 18).frame(height: 48)
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
             .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !model.panelVisible)) { timeline in
                    let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5 * 360
                    RoundedRectangle(cornerRadius: 24).strokeBorder(
                        AngularGradient(colors: [.clear, .blue.opacity(0.22), .cyan.opacity(0.9), .blue, .purple.opacity(0.65), .clear, .clear],
                                        center: .center, angle: .degrees(angle)), lineWidth: model.working || model.screenLoading ? 2 : 1.3)
                        .opacity(model.working || model.screenLoading ? 0.95 : 0.6)
                }.allowsHitTesting(false)
            }
            .onAppear { focused = true }
    }
}
