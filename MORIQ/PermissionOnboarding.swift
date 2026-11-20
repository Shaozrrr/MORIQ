import AppKit
import SwiftUI
import Combine
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit
import Darwin

enum FolderAccessProbe {
    @MainActor static let state = PermissionProbeState()
    @MainActor static var verifiedThisLaunch = false
    static func check(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        var allAllowed = true
        for path in paths {
            guard let directory = opendir(path) else { allAllowed = false; continue }
            errno = 0
            let first = readdir(directory)
            if first == nil && errno != 0 { allAllowed = false }
            closedir(directory)
        }
        return allAllowed
    }
    static func standardFolders() -> Bool {
        let manager = FileManager.default
        let paths = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { manager.urls(for: $0, in: .userDomainMask).first?.path }
        return paths.count == 3 && check(paths: paths)
    }
}

enum DirectScreenAccessProbe {
    @MainActor static let state = PermissionProbeState()
    // A previous release checked an app-owned window, which did not reliably
    // exercise the direct display path used by screenshots and the assistant.
    static let verifiedKey = "moriq.directDisplayCaptureVerified.v2"
    // A prior successful probe is not proof that the OS still grants access.
    // Keep the actual gate in memory so it must be checked on every launch.
    @MainActor static var verifiedThisLaunch = false
    static func verify() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "MORIQDirectScreenProbe", code: 1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 1; configuration.height = 1; configuration.showsCursor = false
        configuration.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
        guard image.width == 1, image.height == 1 else { throw NSError(domain: "MORIQDirectScreenProbe", code: 2) }
    }
}

struct PermissionOnboardingView: View {
    let finish: () -> Void
    let back: () -> Void
    var autoEnterWhenReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("moriq.permissionDarkMode") private var dark = false
    @AppStorage("moriq.foldersVerified") private var foldersPreviouslyVerified = false
    @State private var audioGranted = CaptionAudioPermissionProbe.verifiedThisLaunch
    @State private var audioChecking = false
    @State private var audioAutoCheckStarted = false
    @State private var audioStatus = ""
    @State private var screenGranted = RuntimeEnvironment.permitsCurrent(.systemPermissions) && CGPreflightScreenCaptureAccess()
    @State private var accessibilityGranted = RuntimeEnvironment.permitsCurrent(.systemPermissions) && AXIsProcessTrusted()
    @State private var foldersGranted = FolderAccessProbe.verifiedThisLaunch
    @State private var directCaptureGranted = DirectScreenAccessProbe.verifiedThisLaunch
    @State private var foldersChecking = false
    @State private var captureChecking = false
    @State private var folderCheckGeneration = UUID()
    @State private var captureCheckGeneration = UUID()
    @State private var accessMessage = ""
    @State private var screenRequested = false
    @State private var accessibilityRequested = false
    @State private var initialPermissionSnapshotRecorded = false
    @State private var foldersRequested = false
    @State private var firstLine = ""
    @State private var secondLine = ""
    @State private var subtitle = ""
    @State private var showPeriod = false
    @State private var typingLine = 0
    @State private var enteringHover = false
    @State private var selectedPermission: String?
    @State private var permissionWidth: CGFloat = 300
    @State private var showRecognitionHelp = false
    private let permissionRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let probeFinished = NotificationCenter.default.publisher(for: Notification.Name("MORIQPermissionProbeFinished"))
    private let blue = Color(red: 37/255, green: 99/255, blue: 1)
    private var ready: Bool { screenGranted && accessibilityGranted && foldersGranted && !foldersChecking && directCaptureGranted && audioGranted && !audioChecking }
    var body: some View {
        ZStack {
            (dark ? Color.black : Color.white).ignoresSafeArea()
            WhaleBackground().allowsHitTesting(false).accessibilityHidden(true).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        brandMark.frame(width: 32, height: 32).accessibilityHidden(true)
                        Text("MORIQ").font(.system(size: 20, weight: .bold)).tracking(-0.7)
                    }
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.25)) { dark.toggle() } } label: {
                        Label(dark ? "浅色" : "深色", systemImage: dark ? "sun.max" : "moon")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 20)
                HStack(alignment: .top, spacing: 44) {
                    titleBlock.frame(maxWidth: .infinity, alignment: .leading)
                    permissionsBlock.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 16)
                Button("‹ 返回介绍", action: back).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 48).padding(.top, 20).padding(.bottom, 30)
        }
        .foregroundStyle(dark ? .white : .black)
        .preferredColorScheme(dark ? .dark : .light)
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("--preview-permission-animation") {
                if CommandLine.arguments.contains("--preview-permission-errors") {
                    accessMessage = "检查未完成，请在系统设置中确认权限后返回；如果仍未生效，请重新打开 MORIQ。"
                    audioStatus = "系统音频检查未完成，请确认权限后重新检查。"
                }
                screenGranted = false; accessibilityGranted = false
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.22)) { screenGranted = true }
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.easeOut(duration: 0.22)) { accessibilityGranted = true }
                }
            } else {
                if foldersPreviouslyVerified && !foldersChecking { recheckFolders() }
                refresh(); if screenGranted && !directCaptureGranted && !captureChecking { requestDirectCapture() }
            }
            #else
            if foldersPreviouslyVerified && !foldersChecking { recheckFolders() }
            refresh()
            if screenGranted && !directCaptureGranted && !captureChecking { requestDirectCapture() }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if RuntimeEnvironment.permitsCurrent(.systemPermissions) { LocalDiagnostics.shared.record(.permissions,.foreground,.started,stage:.permissionForeground) }
            refresh()
            if (foldersRequested || foldersPreviouslyVerified) && !foldersChecking { recheckFolders() }
        }
        .onReceive(permissionRefresh) { _ in refresh() }
        .onDisappear {
            FolderAccessProbe.state.invalidate(); DirectScreenAccessProbe.state.invalidate(); CaptionAudioPermissionProbe.state.invalidate()
            foldersChecking = false; captureChecking = false; audioChecking = false; audioAutoCheckStarted = false
        }
        .onReceive(probeFinished) { notification in
            guard let raw = notification.object as? String, let kind = PermissionProbeKind(rawValue: raw) else { return }
            switch kind {
            case .folders:
                if PermissionProbeRetry.shouldRetry(kind, granted: foldersGranted, previouslyRequested: foldersPreviouslyVerified || foldersRequested, screenAllowed: screenGranted) && !foldersChecking { recheckFolders() }
            case .screen:
                if PermissionProbeRetry.shouldRetry(kind, granted: directCaptureGranted, previouslyRequested: true, screenAllowed: screenGranted && CGPreflightScreenCaptureAccess()) && !captureChecking { requestDirectCapture() }
            case .audio:
                if PermissionProbeRetry.shouldRetry(kind, granted: audioGranted, previouslyRequested: CaptionAudioPermissionProbe.previouslyVerified, screenAllowed: screenGranted && CGPreflightScreenCaptureAccess()) && !audioChecking {
                    audioAutoCheckStarted = true; requestCaptionAudio(automatic: true)
                }
            }
        }
        .onChange(of: ready, initial: true) { _, isReady in
            if isReady { LocalDiagnostics.shared.record(.onboarding, .complete, .success) }
            if isReady && autoEnterWhenReady { finish() }
        }
        .task { await typeIntroduction() }
    }
    @ViewBuilder private var brandMark: some View {
        if dark { Image("BrandMark").resizable().scaledToFit().colorInvert().hueRotation(.degrees(180)) }
        else { Image("BrandMark").resizable().scaledToFit() }
    }
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                typedLine(firstLine, caret: typingLine == 1)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(secondLine)
                    Text(".").foregroundStyle(blue).opacity(showPeriod ? 1 : 0)
                    if typingLine == 2 { TypeCaret() }
                }.frame(height: 58, alignment: .leading)
            }
            .font(.system(size: 44, weight: .bold)).tracking(-2)
            .accessibilityElement(children: .ignore).accessibilityLabel("让每一步都更顺手")
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(height: 24, alignment: .leading).padding(.top, 18)
                .accessibilityLabel("完成授权，常用功能随时待命")
        }
    }
    private func typedLine(_ text: String, caret: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(text); if caret { TypeCaret() }
        }.frame(height: 58, alignment: .leading)
    }
    private var permissionsBlock: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { geometry in
                        let columns = geometry.size.width >= 275 ? 2 : 1
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 0) {
                            permissionRow(title: "屏幕录制", granted: screenGranted, action: requestScreen)
                            permissionRow(title: "辅助功能", granted: accessibilityGranted, action: requestAccessibility)
                            permissionRow(title: "文件与文件夹", granted: foldersGranted, action: requestFolders)
                            permissionRow(title: "直接屏幕读取", granted: directCaptureGranted, action: requestDirectCapture)
                            permissionRow(title: "系统音频", granted: audioGranted, action: { requestCaptionAudio() })
                        }
                        .onAppear { permissionWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in permissionWidth = width }
                    }.frame(height: permissionWidth >= 275 ? 204 : 340)
                    Text(permissionDetail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                        .padding(.top, 12)
                        .accessibilityIdentifier("permissionDetail")
                    if !screenGranted || !accessibilityGranted {
                        PermissionRecognitionHelp(expanded: $showRecognitionHelp)
                            .padding(.top, 5)
                    }
                    if !accessMessage.isEmpty && !["系统音频检查完成。", "文件夹访问已就绪。", "屏幕读取检查已完成；系统可能定期再次提醒。"].contains(accessMessage) {
                        Text(accessMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                }.frame(maxWidth: .infinity)
            }.frame(height: permissionWidth >= 275 ? 270 : 360)
            HStack {
                Spacer()
                Button(action: finish) {
                    HStack(alignment: .center, spacing: 18) {
                        Text("开始使用 MORIQ").font(.system(size: 15, weight: .semibold)).tracking(0.3)
                        Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .regular))
                            .foregroundStyle(ready ? blue : Color.secondary.opacity(0.6))
                            .offset(x: ready && enteringHover && !reduceMotion ? 5 : 0)
                    }
                    .fixedSize()
                    .foregroundStyle(ready ? (enteringHover ? blue : (dark ? Color.white : Color.black)) : (dark ? Color.white.opacity(0.8) : Color.black.opacity(0.5)))
                    .padding(.horizontal, 1).padding(.top, 10).padding(.bottom, 13)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(blue).frame(height: 2)
                            .scaleEffect(x: ready ? 1 : 0, y: 1, anchor: .trailing)
                            .padding(.bottom, 2)
                    }
                    .offset(y: ready || reduceMotion ? 0 : 5)
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.7), value: ready)
                    .animation(.easeOut(duration: 0.3), value: enteringHover)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!ready)
                .onHover { enteringHover = $0 }
                .padding(.top, 20)
            }
        }
    }
    private var permissionDetail: String {
        if audioChecking { return "正在检查系统音频权限…" }
        if foldersChecking || captureChecking { return "正在等待系统确认…" }
        if !audioGranted && !audioStatus.isEmpty { return audioStatus }
        switch selectedPermission {
        case "屏幕录制": return "用于截图和屏幕理解。"
        case "辅助功能": return "用于桌面交互与快捷操作。"
        case "文件与文件夹": return "用于处理桌面、文稿和下载中的文件。"
        case "直接屏幕读取": return "用于读取屏幕，系统可能再次提醒。"
        case "系统音频": return "用于实时字幕，只处理电脑播放的声音。"
        default: return "点击权限名称，了解用途。"
        }
    }
    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button { selectedPermission = title } label: {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看\(title)用途")
            PermissionAction(granted: granted, title: title, compact: true) { selectedPermission = title; action() }
        }
        .frame(minHeight: 68)
        .overlay(alignment: .bottom) { Divider().opacity(dark ? 0.35 : 0.7) }
    }
    private func refresh() {
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        #if DEBUG
        if CommandLine.arguments.contains("--preview-permission-animation") { return }
        #endif
        if audioGranted && !CaptionAudioPermissionProbe.verifiedThisLaunch {
            audioGranted = false; audioStatus = "系统音频已停止，请重新检查。"
        }
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        // Record the same values used for the UI once per view lifetime.
        // LocalDiagnostics is opt-in and stores no screen or audio content.
        if !initialPermissionSnapshotRecorded {
            initialPermissionSnapshotRecorded = true
            LocalDiagnostics.shared.record(.permissions, .check, screen ? .success : .failure, stage: .permissionScreen)
            LocalDiagnostics.shared.record(.permissions, .check, accessibility ? .success : .failure, stage: .permissionAccessibility)
        }
        if !screen {
            CaptionAudioPermissionProbe.state.invalidate()
            audioChecking = false; audioAutoCheckStarted = false
        }
        if !screen && (audioGranted || CaptionAudioPermissionProbe.previouslyVerified) {
            audioGranted = false; CaptionAudioPermissionProbe.verifiedThisLaunch = false
            CaptionAudioPermissionProbe.previouslyVerified = false; audioAutoCheckStarted = false
            audioStatus = "屏幕权限已撤销，请重新检查系统音频。"
        }
        if screen && CaptionAudioPermissionProbe.previouslyVerified && !audioAutoCheckStarted && !audioChecking && !audioGranted {
            audioAutoCheckStarted = true
            DispatchQueue.main.async { requestCaptionAudio(automatic: true) }
        }
        if !screen {
            DirectScreenAccessProbe.state.invalidate()
            captureChecking = false
        }
        if !screen && directCaptureGranted {
            directCaptureGranted = false
            DirectScreenAccessProbe.verifiedThisLaunch = false
            DirectScreenAccessProbe.state.invalidate()
            UserDefaults.standard.set(false, forKey: DirectScreenAccessProbe.verifiedKey)
        }
        if screen { PermissionRelaunch.shared.granted("screen") }
        if accessibility { PermissionRelaunch.shared.granted("accessibility") }
        if screen != screenGranted { LocalDiagnostics.shared.record(.permissions,.complete,screen ? .success : .failure,stage:.permissionScreen) }
        if accessibility != accessibilityGranted { LocalDiagnostics.shared.record(.permissions,.complete,accessibility ? .success : .failure,stage:.permissionAccessibility) }
        guard screen != screenGranted || accessibility != accessibilityGranted else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            screenGranted = screen
            accessibilityGranted = accessibility
        }
        if screen && !directCaptureGranted && !captureChecking { requestDirectCapture() }
    }
    private func requestCaptionAudio(automatic: Bool = false) {
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        guard CGPreflightScreenCaptureAccess() else { accessMessage = "请先授权屏幕录制，再检查系统音频。"; return }
        guard let generation = CaptionAudioPermissionProbe.state.begin() else {
            accessMessage = "系统音频检查仍在等待系统响应，请稍候。"; return
        }
        let previous = CaptionAudioPermissionProbe.previouslyVerified
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        LocalDiagnostics.shared.record(.permissions, .start, .started, operationID: generation, stage:.permissionAudio)
        audioChecking = true; audioGranted = false; CaptionAudioPermissionProbe.verifiedThisLaunch = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard audioChecking, CaptionAudioPermissionProbe.state.isCurrent(generation) else { return }
            LocalDiagnostics.shared.record(.permissions,.waiting,.started,duration:8,operationID:generation,stage:.permissionAudio)
            audioStatus = "系统音频检查等待较久，请检查是否有系统提示。"
            accessMessage = audioStatus
        }
        Task { @MainActor in
            let result: CaptionAudioProbeResult
            do { result = try await CaptionAudioPermissionProbe.verify(timeout: automatic ? 1 : 4) }
            catch { result = .failed }
            guard CaptionAudioPermissionProbe.state.finish(generation) else {
                LocalDiagnostics.shared.record(.permissions, .complete, .cancelled, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: generation, stage:.permissionAudio)
                NotificationCenter.default.post(name: Notification.Name("MORIQPermissionProbeFinished"), object: PermissionProbeKind.audio.rawValue); return
            }
            let decision = CaptionAudioAuthorizationPolicy.decide(previouslyVerified: previous, screenAllowed: CGPreflightScreenCaptureAccess(), result: result)
            switch decision {
            case .confirmed:
                CaptionAudioPermissionProbe.previouslyVerified = true; CaptionAudioPermissionProbe.verifiedThisLaunch = true; audioGranted = true
                audioStatus = "本次已确认系统音频。"; accessMessage = "系统音频检查完成。"
            case .previouslyVerifiedSilent:
                CaptionAudioPermissionProbe.verifiedThisLaunch = false; audioGranted = false
                audioStatus = "暂无声音，无法确认。"; accessMessage = "请播放声音后再次检查，系统音频不会保存。"
            case .needsAudio:
                CaptionAudioPermissionProbe.verifiedThisLaunch = false; audioGranted = false
                audioStatus = "暂无声音，无法确认。"; accessMessage = "请播放声音后再次检查，系统音频不会保存。"
            case .unavailable:
                CaptionAudioPermissionProbe.previouslyVerified = false; CaptionAudioPermissionProbe.verifiedThisLaunch = false; audioGranted = false
                audioStatus = "无法启动系统音频。"; accessMessage = "请检查系统音频及屏幕录制权限后重试。"
            }
            LocalDiagnostics.shared.record(.permissions, .complete, audioGranted ? .success : .failure, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: generation, stage:.permissionAudio)
            audioChecking = false
        }
    }
    private func startFolderTimeout(_ generation: UUID) {
        folderCheckGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard foldersChecking, folderCheckGeneration == generation, FolderAccessProbe.state.isCurrent(generation) else { return }
            LocalDiagnostics.shared.record(.permissions,.waiting,.started,duration:8,operationID:generation,stage:.permissionFolder)
            accessMessage = "文件夹检查等待较久，请检查是否有系统提示。"
        }
    }
    private func recheckFolders() {
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        guard let generation = FolderAccessProbe.state.begin() else { return }
        let diagnosticStart=ProcessInfo.processInfo.systemUptime
        LocalDiagnostics.shared.record(.permissions,.start,.started,operationID:generation,stage:.permissionFolder)
        foldersChecking = true; foldersGranted = false
        FolderAccessProbe.verifiedThisLaunch = false
        startFolderTimeout(generation)
        Task { @MainActor in
            let ok = await Task.detached(priority: .userInitiated) { FolderAccessProbe.standardFolders() }.value
            guard FolderAccessProbe.state.finish(generation) else {
                LocalDiagnostics.shared.record(.permissions,.complete,.cancelled,duration:ProcessInfo.processInfo.systemUptime-diagnosticStart,operationID:generation,stage:.permissionFolder)
                NotificationCenter.default.post(name: Notification.Name("MORIQPermissionProbeFinished"), object: PermissionProbeKind.folders.rawValue); return
            }
            LocalDiagnostics.shared.record(.permissions,.complete,ok ? .success : .failure,duration:ProcessInfo.processInfo.systemUptime-diagnosticStart,operationID:generation,stage:.permissionFolder)
            foldersChecking = false
            foldersGranted = ok; FolderAccessProbe.verifiedThisLaunch = ok
            foldersPreviouslyVerified = ok
            if !ok {
                accessMessage = "文件夹访问已变化，请在系统设置中检查后重新授权。"
            } else if accessMessage == "文件夹访问已变化，请在系统设置中检查后重新授权。" { accessMessage = "" }
        }
    }
    private func requestFolders() {
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        guard let generation = FolderAccessProbe.state.begin() else {
            accessMessage = "文件夹检查仍在等待系统响应，请稍候或重新打开 MORIQ。"; return
        }
        foldersGranted = false; FolderAccessProbe.verifiedThisLaunch = false
        foldersRequested = true
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        LocalDiagnostics.shared.record(.permissions, .start, .started, operationID: generation, stage:.permissionFolder)
        foldersChecking = true; accessMessage = "请依次在系统提示中允许访问。"
        startFolderTimeout(generation)
        Task { @MainActor in
            let ok = await Task.detached(priority: .userInitiated) { FolderAccessProbe.standardFolders() }.value
            guard FolderAccessProbe.state.finish(generation) else {
                LocalDiagnostics.shared.record(.permissions, .complete, .cancelled, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: generation, stage:.permissionFolder)
                NotificationCenter.default.post(name: Notification.Name("MORIQPermissionProbeFinished"), object: PermissionProbeKind.folders.rawValue); return
            }
            LocalDiagnostics.shared.record(.permissions, .complete, ok ? .success : .failure, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: generation, stage:.permissionFolder)
            foldersChecking = false; foldersGranted = ok
            FolderAccessProbe.verifiedThisLaunch = ok
            foldersPreviouslyVerified = ok
            accessMessage = ok ? "文件夹访问已就绪。" : "请在系统设置的“隐私与安全性 → 文件与文件夹”中允许 MORIQ，然后重试。"
        }
    }
    private func requestDirectCapture() {
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        guard screenGranted else { accessMessage = "请先完成屏幕录制授权。"; return }
        guard let generation = DirectScreenAccessProbe.state.begin() else {
            accessMessage = "屏幕读取检查仍在等待系统响应，请稍候或重新打开 MORIQ。"; return
        }
        directCaptureGranted = false; DirectScreenAccessProbe.verifiedThisLaunch = false
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        LocalDiagnostics.shared.record(.permissions, .start, .started, operationID: generation, stage:.permissionScreen)
        captureChecking = true; accessMessage = "正在检查直接读取权限，若系统询问请确认。"
        captureCheckGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard captureChecking, captureCheckGeneration == generation, DirectScreenAccessProbe.state.isCurrent(generation) else { return }
            LocalDiagnostics.shared.record(.permissions,.waiting,.started,duration:8,operationID:generation,stage:.permissionScreen)
            accessMessage = "屏幕读取检查等待较久，请检查是否有系统提示。"
        }
        Task { @MainActor in
            defer {
                if DirectScreenAccessProbe.state.finish(generation) {
                    LocalDiagnostics.shared.record(.permissions, .complete, directCaptureGranted ? .success : .failure, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: generation, stage:.permissionScreen)
                    captureChecking = false
                } else {
                    LocalDiagnostics.shared.record(.permissions, .complete, .cancelled, duration: ProcessInfo.processInfo.systemUptime - diagnosticStart, operationID: generation, stage:.permissionScreen)
                    NotificationCenter.default.post(name: Notification.Name("MORIQPermissionProbeFinished"), object: PermissionProbeKind.screen.rawValue)
                }
            }
            do {
                try await DirectScreenAccessProbe.verify()
                guard DirectScreenAccessProbe.state.isCurrent(generation) else { return }
                guard CGPreflightScreenCaptureAccess() else { throw NSError(domain: "MORIQDirectScreenProbe", code: 3) }
                directCaptureGranted = true; DirectScreenAccessProbe.verifiedThisLaunch = true
                UserDefaults.standard.set(true, forKey: DirectScreenAccessProbe.verifiedKey); accessMessage = "屏幕读取检查已完成；系统可能定期再次提醒。"
            } catch {
                guard DirectScreenAccessProbe.state.isCurrent(generation) else { return }
                directCaptureGranted = false; DirectScreenAccessProbe.verifiedThisLaunch = false
                UserDefaults.standard.set(false, forKey: DirectScreenAccessProbe.verifiedKey)
                accessMessage = "尚未确认直接读取权限，请检查系统设置后重试。"
            }
        }
    }
    private func requestScreen() {
        LocalDiagnostics.shared.record(.permissions, .check, .started, stage:.permissionScreen)
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        PermissionRelaunch.shared.arm(for: "screen")
        if screenRequested { openSettings("Privacy_ScreenCapture") }
        else { screenRequested = true; screenGranted = CGRequestScreenCaptureAccess() }
    }
    private func requestAccessibility() {
        LocalDiagnostics.shared.record(.permissions, .check, .started, stage:.permissionAccessibility)
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        PermissionRelaunch.shared.arm(for: "accessibility")
        if accessibilityRequested { openSettings("Privacy_Accessibility") }
        else {
            accessibilityRequested = true
            accessibilityGranted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }
    private func openSettings(_ anchor: String) {
        guard RuntimeEnvironment.permitsCurrent(.systemPermissions) else { accessMessage = "内部测试已禁用系统权限。"; return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    private func typeIntroduction() async {
        if reduceMotion { firstLine = "让每一步"; secondLine = "都更顺手"; subtitle = "完成授权，常用功能随时待命"; showPeriod = true; return }
        do {
            firstLine = ""; secondLine = ""; subtitle = ""; showPeriod = false
            try await Task.sleep(for: .milliseconds(350)); typingLine = 1
            for ch in "让每一步" { firstLine.append(ch); try await Task.sleep(for: .milliseconds(175)) }
            try await Task.sleep(for: .milliseconds(200)); typingLine = 2
            for ch in "都更顺首" { secondLine.append(ch); try await Task.sleep(for: .milliseconds(185)) }
            try await Task.sleep(for: .milliseconds(600)); secondLine = "都更顺"
            try await Task.sleep(for: .milliseconds(300)); secondLine = "都更顺手"
            withAnimation(.easeIn(duration: 0.25)) { showPeriod = true }
            typingLine = 0
            for ch in "完成授权，常用功能随时待命" { subtitle.append(ch); try await Task.sleep(for: .milliseconds(65)) }
        } catch { typingLine = 0 }
    }
}
private struct PermissionAction: View {
    let granted: Bool
    let title: String
    var compact = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var checkProgress: CGFloat = 0
    private let blue = Color(red: 37/255, green: 99/255, blue: 1)
    var body: some View {
        Button { if !granted { action() } } label: {
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    Text("授权").font(.system(size: compact ? 11 : 14, weight: .medium)).tracking(0.2)
                        .opacity(granted ? 0 : 1)
                        .scaleEffect(granted && !reduceMotion ? 0.7 : 1)
                    Spacer(minLength: 0)
                    Circle().fill(blue).frame(width: 8, height: 8)
                        .scaleEffect(granted ? 0 : (breathing ? 1.12 : 0.78))
                        .opacity(granted ? 0 : (breathing ? 1 : 0.62))
                        .overlay {
                            Circle().stroke(blue.opacity(breathing ? 0.09 : 0), lineWidth: 4)
                                .scaleEffect(breathing ? 1.5 : 1).opacity(granted ? 0 : 1)
                        }
                }
                .padding(.leading, 4).padding(.trailing, 6)
                .frame(width: compact ? 52 : 94, height: 38)
                CheckStroke().trim(from: 0, to: checkProgress)
                    .stroke(blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .frame(width: 38, height: 38)
                    .opacity(granted ? 1 : 0)
                    .scaleEffect(granted || reduceMotion ? 1 : 0.75, anchor: .center)
            }
            .frame(width: compact ? 52 : 94, height: 38, alignment: .trailing)
            .foregroundStyle(blue).contentShape(Rectangle())
        }
        .buttonStyle(.plain).allowsHitTesting(!granted)
        .accessibilityLabel(granted ? "\(title)已授权" : "授权\(title)")
        .onAppear {
            checkProgress = granted ? 1 : 0
            if !reduceMotion { withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { breathing = true } }
        }
        .onChange(of: granted) { _, value in
            if value {
                checkProgress = 0
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.45).delay(0.12)) { checkProgress = 1 }
            } else { checkProgress = 0 }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.22), value: granted)
    }
}
private struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.77))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.22))
        return path
    }
}
private struct TypeCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    var body: some View {
        Rectangle().fill(Color(red: 37/255, green: 99/255, blue: 1)).frame(width: 2, height: 36)
            .opacity(visible ? 1 : 0).padding(.leading, 3)
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false } } }
            .accessibilityHidden(true)
    }
}

// Inline recovery guidance. Authorization remains determined by system APIs.
struct PermissionRecognitionHelp: View {
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Text("已开启但未识别？")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("permissionRecognitionHelp")
            if expanded {
                Text("可能存在旧版本权限记录。打开系统设置 → 隐私与安全性 → 对应权限；确认是旧版本的 MORIQ 条目后，选中并点“−”移除，再点“+”选择当前正在运行的 MORIQ 应用（通常位于“应用程序”），开启后重新打开 MORIQ。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("permissionRecognitionInstructions")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
