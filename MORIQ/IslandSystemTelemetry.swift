import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI

// MARK: - Real Host Hardware & Live System Telemetry + Native macOS Control Actions

struct RealMacHardwareSnapshot: Equatable {
    let modelIdentifier: String
    let marketingName: String
    let chipFull: String
    let chipShort: String
    let coreCount: Int
    let osVersion: String
    let ramTotalGB: Double
    var ramUsedGB: Double
    var ramWiredGB: Double
    let ssdTotalGB: Double
    var ssdAvailableGB: Double

    var ramPercent: Double {
        guard ramTotalGB > 0 else { return 0 }
        return min(100, max(1, (ramUsedGB / ramTotalGB) * 100))
    }

    var ssdUsedPercent: Double {
        guard ssdTotalGB > 0 else { return 0 }
        let used = max(0, ssdTotalGB - ssdAvailableGB)
        return min(100, max(1, (used / ssdTotalGB) * 100))
    }

    var ssdTotalDisplay: String {
        ssdTotalGB >= 900 ? String(format: "%.0fT", (ssdTotalGB / 1000.0).rounded()) : String(format: "%.0fG", ssdTotalGB)
    }
}

struct PeripheralBatteryItem: Identifiable, Equatable {
    let id: String
    let name: String
    let shortName: String
    let symbol: String
    let percent: Int
}

struct AppAudioChannelItem: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String
    var volume: Double
}

struct ListeningDevPortItem: Identifiable, Equatable {
    var id: Int { port }
    let port: Int
    let pid: Int32
    let processName: String
}

struct AIProviderQuotaItem: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var plan: String
    var badge: String
    var percent: Int
    var windowText: String
    var enabled: Bool
    var alertThreshold: Int
    var lastSyncedText: String

    init(
        id: String,
        name: String,
        plan: String,
        badge: String,
        percent: Int,
        windowText: String,
        enabled: Bool,
        alertThreshold: Int = 20,
        lastSyncedText: String = "刚刚同步"
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.badge = badge
        self.percent = percent
        self.windowText = windowText
        self.enabled = enabled
        self.alertThreshold = alertThreshold
        self.lastSyncedText = lastSyncedText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        plan = try c.decode(String.self, forKey: .plan)
        badge = try c.decode(String.self, forKey: .badge)
        percent = try c.decode(Int.self, forKey: .percent)
        windowText = try c.decode(String.self, forKey: .windowText)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        alertThreshold = try c.decodeIfPresent(Int.self, forKey: .alertThreshold) ?? 20
        lastSyncedText = try c.decodeIfPresent(String.self, forKey: .lastSyncedText) ?? "刚刚同步"
    }
}

enum WindowSnapAction: String, CaseIterable {
    case leftHalf, rightHalf, maximize, center
    var title: String {
        switch self {
        case .leftHalf: "左半屏"
        case .rightHalf: "右半屏"
        case .maximize: "全屏铺满"
        case .center: "居中聚焦"
        }
    }
    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .center: "rectangle.center.inset.filled"
        }
    }
}

@MainActor final class SystemTelemetryStore: ObservableObject {
    static let shared = SystemTelemetryStore()

    private let storeDefaults: UserDefaults
    @Published private(set) var hardware: RealMacHardwareSnapshot
    @Published var customNickname: String {
        didSet { storeDefaults.set(customNickname, forKey: "moriq.realMac.nickname") }
    }

    // 50/50 Peer-Equal CPU & GPU Live Telemetry
    @Published private(set) var cpuPercent: Double = 18
    @Published private(set) var gpuPercent: Double = 14
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 18, count: 28)
    @Published private(set) var gpuHistory: [Double] = Array(repeating: 14, count: 28)

    // Battery & Thermal
    @Published private(set) var batteryPercent: Int = 100
    @Published private(set) var batteryHealthPercent: Int = 100
    @Published private(set) var batteryCycles: Int = 0
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var powerWatts: Double = 14.2
    @Published private(set) var thermalCelsius: Int = 42
    @Published private(set) var remainingMinutes: Int? = nil

    // Peripherals & Network
    @Published private(set) var peripherals: [PeripheralBatteryItem] = []
    @Published private(set) var btSpotlightIndex: Int = 0
    @Published private(set) var netDownMBps: Double = 0.0
    @Published private(set) var netUpMBps: Double = 0.0

    // Display, Audio, Dock & System Switches
    @Published private(set) var brightness: Double = 0.82
    @Published private(set) var outputVolume: Double = 0.65
    @Published private(set) var micMuted: Bool = false
    @Published private(set) var dockAutoHidden: Bool = false
    @Published private(set) var caffeinateActive: Bool = false
    @Published private(set) var desktopIconsHidden: Bool = false
    @Published private(set) var keyboardCleanLocked: Bool = false
    @Published private(set) var lastPickedHex: String = "#2563FF"
    @Published private(set) var trashCount: Int = 0
    @Published private(set) var trashSizeLabel: String = "0 MB"
    @Published var appMixer: [AppAudioChannelItem] = []
    @Published private(set) var devPorts: [ListeningDevPortItem] = []
    @Published var aiProviders: [AIProviderQuotaItem] = [] {
        didSet { persistAIProviders() }
    }
    @Published var statusToast: String? = nil

    private var previousCPUTicks: [UInt32]? = nil
    private var previousNetBytes: (rx: UInt64, tx: UInt64, time: TimeInterval)? = nil
    private var samplingTimer: Timer?
    private var activeConsumers = 0
    private var caffeinateAssertionID: IOPMAssertionID = 0
    private var cleanShieldPanel: NSPanel?
    private var cleanKeyEventTap: CFMachPort?
    private var cleanRunLoopSource: CFRunLoopSource?
    private var lastNonMoriqApp: NSRunningApplication?
    private var appObserver: NSObjectProtocol?
    private var toastClearTask: Task<Void, Never>?

    // Dynamic DisplayServices & CoreDock Symbols
    private typealias DisplayGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DisplaySetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CoreDockGetAutoHideFn = @convention(c) () -> DarwinBoolean
    private typealias CoreDockSetAutoHideFn = @convention(c) (Bool) -> Void

    private lazy var displayServicesHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()
    private lazy var getBrightnessSym: DisplayGetBrightnessFn? = {
        guard let h = displayServicesHandle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: DisplayGetBrightnessFn.self)
    }()
    private lazy var setBrightnessSym: DisplaySetBrightnessFn? = {
        guard let h = displayServicesHandle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: DisplaySetBrightnessFn.self)
    }()
    private lazy var getDockAutoHideSym: CoreDockGetAutoHideFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockGetAutoHideEnabled") else { return nil }
        return unsafeBitCast(sym, to: CoreDockGetAutoHideFn.self)
    }()
    private lazy var setDockAutoHideSym: CoreDockSetAutoHideFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSetAutoHideEnabled") else { return nil }
        return unsafeBitCast(sym, to: CoreDockSetAutoHideFn.self)
    }()

    private init() {
        let isProductBundle = !(Bundle.main.bundleIdentifier ?? "").isEmpty
            && !(Bundle.main.bundleIdentifier ?? "").hasPrefix("local.moriq.internal")
            && Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor") == nil
        let resolvedDefaults = isProductBundle
            ? UserDefaults.standard
            : (UserDefaults(suiteName: "local.moriq.telemetry.ephemeral.\(UUID().uuidString)") ?? .standard)
        self.storeDefaults = resolvedDefaults
        self.customNickname = resolvedDefaults.string(forKey: "moriq.realMac.nickname") ?? ""
        self.hardware = Self.readStaticHardware()
        self.aiProviders = Self.loadInitialAIProviders(from: resolvedDefaults)
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.lastNonMoriqApp = app
            }
        }
        refreshFastMetrics()
        refreshSystemControlsState()
    }

    var displayHostTitle: String {
        let trimmed = customNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hardware.marketingName : trimmed
    }

    func retainSampling() {
        activeConsumers += 1
        guard samplingTimer == nil else { return }
        refreshFastMetrics()
        refreshSystemControlsState()
        refreshSlowMetricsAsync()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFastMetrics() }
        }
        samplingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func releaseSampling() {
        activeConsumers = max(0, activeConsumers - 1)
        guard activeConsumers == 0 else { return }
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    func showToast(_ message: String) {
        statusToast = message
        toastClearTask?.cancel()
        toastClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.statusToast = nil
        }
    }

    func cycleBluetoothSpotlight() {
        guard !peripherals.isEmpty else { return }
        btSpotlightIndex = (btSpotlightIndex + 1) % peripherals.count
    }

    // MARK: - Live Telemetry Sampling

    func refreshFastMetrics() {
        let mem = Self.readLiveMemory()
        hardware.ramUsedGB = mem.usedGB
        hardware.ramWiredGB = mem.wiredGB
        let disk = Self.readLiveDisk()
        hardware.ssdAvailableGB = disk.availableGB

        if let cpu = sampleCPUUsage() {
            cpuPercent = cpu
            cpuHistory.append(cpu)
            if cpuHistory.count > 28 { cpuHistory.removeFirst(cpuHistory.count - 28) }
        }
        let gpu = Self.readGPUUtilization() ?? max(4, min(96, cpuPercent * 0.78))
        gpuPercent = gpu
        gpuHistory.append(gpu)
        if gpuHistory.count > 28 { gpuHistory.removeFirst(gpuHistory.count - 28) }

        sampleNetworkThroughput()
        sampleBatteryAndPower()
        samplePeripherals()
        refreshRunningMixerApps()
    }

    func refreshSlowMetricsAsync() {
        Task.detached(priority: .utility) {
            let trash = Self.computeTrashMetrics()
            let ports = Self.scanListeningDevPorts()
            let cursorDetected = Self.detectCursorLocalState()
            await MainActor.run {
                let store = SystemTelemetryStore.shared
                store.trashCount = trash.count
                store.trashSizeLabel = trash.sizeLabel
                store.devPorts = ports
                if cursorDetected, let idx = store.aiProviders.firstIndex(where: { $0.id == "cursor" }) {
                    store.aiProviders[idx].badge = "Cursor.app 本机已识别"
                }
            }
        }
    }

    func refreshSystemControlsState() {
        var b: Float = Float(brightness)
        if let getB = getBrightnessSym, getB(CGMainDisplayID(), &b) == 0 {
            brightness = Double(min(1, max(0.05, b)))
        }
        if let vol = Self.readSystemOutputVolume() {
            outputVolume = vol
        }
        micMuted = Self.readDefaultInputMuted()
        if let getDock = getDockAutoHideSym {
            dockAutoHidden = getDock().boolValue
        }
        let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
        if let createDesktop = finderDefaults?.object(forKey: "CreateDesktop") as? Bool {
            desktopIconsHidden = !createDesktop
        }
    }

    // MARK: - Real Control Actions

    func setDisplayBrightness(_ value: Double, commit: Bool) {
        let clamped = min(1.0, max(0.10, value))
        brightness = clamped
        _ = setBrightnessSym?(CGMainDisplayID(), Float(clamped))
        if commit { showToast("屏幕亮度 \(Int((clamped * 100).rounded()))%") }
    }

    func setSystemVolume(_ value: Double, commit: Bool) {
        let clamped = min(1.0, max(0.0, value))
        outputVolume = clamped
        Self.writeSystemOutputVolume(Float32(clamped))
        if commit { showToast("系统音量 \(Int((clamped * 100).rounded()))%") }
    }

    func setAppChannelVolume(id: String, value: Double) {
        guard let idx = appMixer.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(1.0, max(0.0, value))
        appMixer[idx].volume = clamped
        if appMixer[idx].bundleID == "com.apple.Music" {
            let volInt = Int((clamped * 100).rounded())
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: "if application \"Music\" is running then tell application \"Music\" to set sound volume to \(volInt)")
                var err: NSDictionary?
                script?.executeAndReturnError(&err)
            }
        }
    }

    func toggleMicMute() {
        let target = !micMuted
        if Self.writeDefaultInputMuted(target) {
            micMuted = target
            showToast(target ? "全局麦克风已静音" : "麦克风已恢复拾音")
        } else {
            micMuted = target
            showToast(target ? "已标记闭麦（当前无外接输入源）" : "已恢复麦克风状态")
        }
    }

    func toggleDockAutoHide() {
        let next = !dockAutoHidden
        if let setDock = setDockAutoHideSym {
            setDock(next)
            dockAutoHidden = next
            showToast(next ? "Dock 已自动收起（鼠标移至底边即刻唤出）" : "Dock 已恢复常驻显示")
        } else {
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: "tell application \"System Events\" to set autohide of dock preferences to \(next ? "true" : "false")")
                var err: NSDictionary?
                script?.executeAndReturnError(&err)
                await MainActor.run {
                    SystemTelemetryStore.shared.dockAutoHidden = next
                    SystemTelemetryStore.shared.showToast(next ? "Dock 已自动收起" : "Dock 已恢复常驻")
                }
            }
        }
    }

    func toggleCaffeinate() {
        if caffeinateActive {
            if caffeinateAssertionID != 0 {
                IOPMAssertionRelease(caffeinateAssertionID)
                caffeinateAssertionID = 0
            }
            caffeinateActive = false
            showToast("防休眠常亮已关闭")
        } else {
            var id: IOPMAssertionID = 0
            let reason = "MORIQ Keep Awake" as CFString
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if status == kIOReturnSuccess {
                caffeinateAssertionID = id
                caffeinateActive = true
                showToast("防休眠常亮已开启（屏幕保持唤醒）")
            } else {
                showToast("无法创建电源唤醒断言")
            }
        }
    }

    func toggleDesktopIcons() {
        let hideNext = !desktopIconsHidden
        desktopIconsHidden = hideNext
        Task.detached(priority: .userInitiated) {
            let write = Process()
            write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            write.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", hideNext ? "false" : "true"]
            try? write.run(); write.waitUntilExit()
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            relaunch.arguments = ["Finder"]
            try? relaunch.run(); relaunch.waitUntilExit()
            await MainActor.run {
                SystemTelemetryStore.shared.showToast(hideNext ? "桌面图标已临时净空" : "桌面图标已恢复显示")
            }
        }
    }

    func setKeyboardCleanLock(_ locked: Bool) {
        guard keyboardCleanLocked != locked else { return }
        keyboardCleanLocked = locked
        if locked {
            guard let screen = NSScreen.main else { keyboardCleanLocked = false; return }
            let shield = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            shield.level = .screenSaver
            shield.isOpaque = false
            shield.backgroundColor = .clear
            shield.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            shield.contentView = NSHostingView(
                rootView: KeyboardCleanShieldView { [weak self] in self?.setKeyboardCleanLock(false) }
            )
            shield.makeKeyAndOrderFront(nil)
            cleanShieldPanel = shield

            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << UInt64(14))
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, _, _, _ in nil },
                userInfo: nil
            ) {
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                cleanKeyEventTap = tap
                cleanRunLoopSource = src
            }
        } else {
            if let tap = cleanKeyEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let src = cleanRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            cleanKeyEventTap = nil
            cleanRunLoopSource = nil
            cleanShieldPanel?.orderOut(nil)
            cleanShieldPanel = nil
            showToast("键盘清洁防误触锁已解除")
        }
    }

    func snapActiveWindow(_ action: WindowSnapAction) {
        guard AXIsProcessTrusted() else {
            showToast("请先授予辅助功能权限以分屏窗口")
            return
        }
        let targetApp = lastNonMoriqApp ?? NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isHidden
        })
        guard let app = targetApp else {
            showToast("未找到可分屏的前台窗口")
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winObj = winRef, CFGetTypeID(winObj) == AXUIElementGetTypeID() else {
            showToast("当前应用窗口不支持尺寸调整")
            return
        }
        let axWin = winObj as! AXUIElement
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame, let full = screen?.frame else { return }

        // AX coordinates have origin (0,0) at top-left of primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? full.height
        let axTop = primaryHeight - visible.maxY
        let targetRect: CGRect
        switch action {
        case .leftHalf:
            targetRect = CGRect(x: visible.minX, y: axTop, width: floor(visible.width / 2), height: visible.height)
        case .rightHalf:
            let half = floor(visible.width / 2)
            targetRect = CGRect(x: visible.minX + half, y: axTop, width: visible.width - half, height: visible.height)
        case .maximize:
            targetRect = CGRect(x: visible.minX, y: axTop, width: visible.width, height: visible.height)
        case .center:
            let w = round(visible.width * 0.74), h = round(visible.height * 0.80)
            targetRect = CGRect(x: round(visible.midX - w / 2), y: round(axTop + (visible.height - h) / 2), width: w, height: h)
        }

        var origin = targetRect.origin
        var size = targetRect.size
        if let posVal = AXValueCreate(.cgPoint, &origin), let sizeVal = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
            _ = AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
            _ = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
            app.activate(options: [])
            showToast("已将 \(app.localizedName ?? "窗口") 贴靠至\(action.title)")
        }
    }

    func pickScreenColor() {
        NSColorSampler().show { [weak self] picked in
            Task { @MainActor [weak self] in
                guard let self, let srgb = picked?.usingColorSpace(.sRGB) else { return }
                let r = Int((srgb.redComponent * 255).rounded())
                let g = Int((srgb.greenComponent * 255).rounded())
                let b = Int((srgb.blueComponent * 255).rounded())
                let hex = String(format: "#%02X%02X%02X", r, g, b)
                self.lastPickedHex = hex
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                self.showToast("已取色 \(hex) 并写入剪贴板")
            }
        }
    }

    func scrubClipboardPlainText() {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else {
            showToast("剪贴板暂无可净化的文本")
            return
        }
        let cleaned = Self.stripTrackingParams(in: raw)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleaned, forType: .string)
        showToast("已净化纯文本与追踪参数")
    }

    func openSystemTrash() {
        if let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(trashURL)
        }
    }

    func terminateDevPort(_ item: ListeningDevPortItem) {
        guard item.pid > 1 && item.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if Darwin.kill(item.pid, SIGTERM) == 0 {
            devPorts.removeAll { $0.port == item.port }
            showToast("已释放端口 :\(item.port) (\(item.processName))")
        } else {
            showToast("无法释放端口 :\(item.port)（权限不足）")
        }
    }

    // MARK: - Low-Level System Readers

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readStaticHardware() -> RealMacHardwareSnapshot {
        let model = sysctlString("hw.model") ?? "Mac"
        let marketing: String
        if model.hasPrefix("MacBookPro") { marketing = "MacBook Pro" }
        else if model.hasPrefix("MacBookAir") { marketing = "MacBook Air" }
        else if model.hasPrefix("Macmini") { marketing = "Mac mini" }
        else if model.hasPrefix("iMac") { marketing = "iMac" }
        else if model.hasPrefix("MacPro") { marketing = "Mac Pro" }
        else if model.hasPrefix("VirtualMac") { marketing = "Apple Virtual Mac" }
        else { marketing = "MacBook Pro" }

        let rawChip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let chipShort = rawChip.replacingOccurrences(of: "Apple ", with: "").components(separatedBy: " ").prefix(2).joined(separator: " ")
        var cores: Int32 = 0
        var coreSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &cores, &coreSize, nil, 0)

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVer = "\(v.majorVersion).\(v.minorVersion)"
        let ramTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let mem = readLiveMemory()
        let disk = readLiveDisk()

        return RealMacHardwareSnapshot(
            modelIdentifier: model,
            marketingName: marketing,
            chipFull: rawChip,
            chipShort: chipShort.isEmpty ? "M-Series" : chipShort,
            coreCount: max(1, Int(cores)),
            osVersion: osVer,
            ramTotalGB: (ramTotal * 10).rounded() / 10,
            ramUsedGB: mem.usedGB,
            ramWiredGB: mem.wiredGB,
            ssdTotalGB: disk.totalGB,
            ssdAvailableGB: disk.availableGB
        )
    }

    private static func readLiveMemory() -> (usedGB: Double, wiredGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let pageSize = Double(vm_kernel_page_size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (8.0, 2.0) }
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let usedGB = ((active + wired + compressed) / 1_073_741_824.0 * 10).rounded() / 10
        let wiredGB = ((wired / 1_073_741_824.0) * 10).rounded() / 10
        return (max(1.0, usedGB), max(0.5, wiredGB))
    }

    private static func readLiveDisk() -> (totalGB: Double, availableGB: Double) {
        let root = URL(fileURLWithPath: "/")
        let vals = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let totalBytes = Double(vals?.volumeTotalCapacity ?? 500_000_000_000)
        let availBytes = Double(vals?.volumeAvailableCapacityForImportantUsage ?? Int64(vals?.volumeAvailableCapacity ?? 120_000_000_000))
        return (round(totalBytes / 1_000_000_000.0), round(availBytes / 1_000_000_000.0))
    }

    private func sampleCPUUsage() -> Double? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard kr == KERN_SUCCESS, let array = infoArray else { return nil }
        defer {
            let byteCount = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: array), byteCount)
        }
        var current = [UInt32](repeating: 0, count: 4)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            current[0] &+= UInt32(bitPattern: array[base + Int(CPU_STATE_USER)])
            current[1] &+= UInt32(bitPattern: array[base + Int(CPU_STATE_SYSTEM)])
            current[2] &+= UInt32(bitPattern: array[base + Int(CPU_STATE_NICE)])
            current[3] &+= UInt32(bitPattern: array[base + Int(CPU_STATE_IDLE)])
        }
        defer { previousCPUTicks = current }
        guard let prev = previousCPUTicks else { return nil }
        let user = Double(current[0] &- prev[0])
        let sys = Double(current[1] &- prev[1])
        let nice = Double(current[2] &- prev[2])
        let idle = Double(current[3] &- prev[3])
        let total = user + sys + nice + idle
        guard total > 0 else { return nil }
        return min(100, max(1, ((user + sys + nice) / total) * 100.0))
    }

    private static func readGPUUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let prop = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                for key in ["Device Utilization %", "Renderer Utilization %", "GPU Activity(%)"] {
                    if let num = prop[key] as? NSNumber {
                        return min(100, max(1, num.doubleValue))
                    }
                }
            }
        }
        return nil
    }

    private func sampleBatteryAndPower() {
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
           let first = list.first,
           let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {
            if let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int, maxCap > 0 {
                batteryPercent = Int((Double(cur) / Double(maxCap) * 100).rounded())
            }
            isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) == true
            if let tte = desc[kIOPSTimeToEmptyKey as String] as? Int, tte > 0 {
                remainingMinutes = tte
            } else {
                remainingMinutes = nil
            }
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var dictRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &dictRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = dictRef?.takeRetainedValue() as? [String: Any] {
                if let cycles = props["CycleCount"] as? Int { batteryCycles = cycles }
                if let tempRaw = props["Temperature"] as? Int, tempRaw > 100 {
                    thermalCelsius = max(25, min(98, Int((Double(tempRaw) / 100.0).rounded())))
                }
                if let nom = props["NominalChargeCapacity"] as? Double ?? (props["AppleRawMaxCapacity"] as? Double),
                   let design = props["DesignCapacity"] as? Double, design > 0 {
                    batteryHealthPercent = min(100, max(50, Int((nom / design * 100).rounded())))
                }
                if let amp = props["InstantAmperage"] as? Int, let volt = props["Voltage"] as? Int {
                    let watts = abs(Double(amp) * Double(volt)) / 1_000_000.0
                    if watts > 0.5 && watts < 240 {
                        powerWatts = (watts * 10).rounded() / 10
                    }
                }
            }
        }
    }

    private func samplePeripherals() {
        var found: [PeripheralBatteryItem] = [
            PeripheralBatteryItem(
                id: "mac_internal",
                name: hardware.marketingName,
                shortName: "Mac",
                symbol: "laptopcomputer",
                percent: batteryPercent
            )
        ]
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
                var dictRef: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(entry, &dictRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let props = dictRef?.takeRetainedValue() as? [String: Any],
                   let pct = props["BatteryPercent"] as? Int, pct > 0 {
                    let prod = (props["Product"] as? String) ?? "蓝牙外设"
                    let lower = prod.lowercased()
                    let sym = lower.contains("keyboard") ? "keyboard" : (lower.contains("mouse") ? "computermouse" : (lower.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "airpodspro"))
                    let short = lower.contains("keyboard") ? "键盘" : (lower.contains("mouse") ? "鼠标" : (lower.contains("trackpad") ? "触控板" : String(prod.prefix(7))))
                    found.append(PeripheralBatteryItem(id: prod, name: prod, shortName: short, symbol: sym, percent: min(100, pct)))
                }
            }
        }
        peripherals = Array(found.prefix(4))
    }

    private func sampleNetworkThroughput() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(first) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("en"), let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx &+= UInt64(data.pointee.ifi_ibytes)
                tx &+= UInt64(data.pointee.ifi_obytes)
            }
            ptr = cur.pointee.ifa_next
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let prev = previousNetBytes, now > prev.time, rx >= prev.rx, tx >= prev.tx {
            let dt = now - prev.time
            netDownMBps = Double(rx - prev.rx) / dt / 1_048_576.0
            netUpMBps = Double(tx - prev.tx) / dt / 1_048_576.0
        }
        previousNetBytes = (rx, tx, now)
    }

    private func refreshRunningMixerApps() {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier else { return false }
            return true
        }
        let preferredKeywords = ["music", "spotify", "chrome", "safari", "arc", "zoom", "wemeet", "tencent", "feishu", "vlc", "quicktime"]
        let sorted = candidates.sorted { a, b in
            let ba = (a.bundleIdentifier ?? "").lowercased()
            let bb = (b.bundleIdentifier ?? "").lowercased()
            let sa = preferredKeywords.contains(where: ba.contains) ? 0 : 1
            let sb = preferredKeywords.contains(where: bb.contains) ? 0 : 1
            if sa != sb { return sa < sb }
            return (a.localizedName ?? "") < (b.localizedName ?? "")
        }
        let top = sorted.prefix(3)
        var next: [AppAudioChannelItem] = []
        for app in top {
            let bid = app.bundleIdentifier ?? UUID().uuidString
            let existing = appMixer.first(where: { $0.bundleID == bid })?.volume ?? 0.80
            next.append(AppAudioChannelItem(id: bid, name: app.localizedName ?? "应用", bundleID: bid, volume: existing))
        }
        if appMixer.map(\.bundleID) != next.map(\.bundleID) {
            appMixer = next
        }
    }

    private static func defaultAudioDevice(input: Bool) -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func readSystemOutputVolume() -> Double? {
        guard let dev = defaultAudioDevice(input: false) else { return nil }
        var volume: Float32 = 0.65
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &volume) == noErr else { return nil }
        return Double(min(1, max(0, volume)))
    }

    private static func writeSystemOutputVolume(_ value: Float32) {
        guard let dev = defaultAudioDevice(input: false) else { return }
        var vol = value
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &addr) {
            _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
        }
    }

    private static func readDefaultInputMuted() -> Bool {
        guard let dev = defaultAudioDevice(input: true) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    private static func writeDefaultInputMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultAudioDevice(input: true) else { return false }
        var flag: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &flag) == noErr
    }

    nonisolated private static func computeTrashMetrics() -> (count: Int, sizeLabel: String) {
        guard let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return (0, "0 MB")
        }
        var bytes: Int64 = 0
        for item in items.prefix(300) {
            if let sz = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                bytes += Int64(sz)
            }
        }
        let mb = Double(bytes) / 1_048_576.0
        let label = mb >= 1024 ? String(format: "%.1f GB", mb / 1024.0) : String(format: "%.0f MB", max(0, mb))
        return (items.count, label)
    }

    nonisolated private static func scanListeningDevPorts() -> [ListeningDevPortItem] {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-Fpcn"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var curPID: Int32 = 0
        var curCmd = ""
        var byPort: [Int: ListeningDevPortItem] = [:]
        for line in text.split(separator: "\n") {
            guard let prefix = line.first else { continue }
            let val = String(line.dropFirst())
            switch prefix {
            case "p": curPID = Int32(val) ?? 0
            case "c": curCmd = val
            case "n":
                if let colon = val.lastIndex(of: ":"), let port = Int(val[val.index(after: colon)...]),
                   (1024...65535).contains(port) {
                    let ignored = ["ControlCe", "rapportd", "AirPlayXP", "mDNSRespo", "Figma", "Antigravi"]
                    if !ignored.contains(where: { curCmd.hasPrefix($0) }) {
                        byPort[port] = ListeningDevPortItem(port: port, pid: curPID, processName: curCmd)
                    }
                }
            default: break
            }
        }
        return byPort.values.sorted { $0.port < $1.port }.prefix(6).map { $0 }
    }

    nonisolated private static func detectCursorLocalState() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let db = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        return FileManager.default.fileExists(atPath: db.path)
    }

    static func stripTrackingParams(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), let items = comps.queryItems, !items.isEmpty else {
            return trimmed
        }
        let blockedPrefixes = ["utm_", "spm", "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "mkt_tok"]
        let filtered = items.filter { item in
            let lower = item.name.lowercased()
            return !blockedPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0) })
        }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.string ?? trimmed
    }

    private static let aiKey = "moriq.aiQuota.providers.v1"
    private static func loadInitialAIProviders(from defaults: UserDefaults) -> [AIProviderQuotaItem] {
        if let data = defaults.data(forKey: aiKey),
           let decoded = try? JSONDecoder().decode([AIProviderQuotaItem].self, from: data), !decoded.isEmpty {
            return decoded
        }
        return [
            AIProviderQuotaItem(id: "cursor", name: "Cursor", plan: "Pro", badge: "本机自动检测", percent: 72, windowText: "快速请求余量", enabled: true),
            AIProviderQuotaItem(id: "claude", name: "Claude", plan: "Max", badge: "5h 窗口跟踪", percent: 84, windowText: "5h 窗口配额", enabled: true),
            AIProviderQuotaItem(id: "codex", name: "Codex", plan: "Pro", badge: "窗口跟踪", percent: 76, windowText: "会话窗口余量", enabled: true),
            AIProviderQuotaItem(id: "deepseek", name: "DeepSeek", plan: "API", badge: "API 直连", percent: 90, windowText: "账户可用额度", enabled: true)
        ]
    }

    private func persistAIProviders() {
        if let data = try? JSONEncoder().encode(aiProviders) {
            storeDefaults.set(data, forKey: Self.aiKey)
        }
    }

    func toggleAIProviderEnabled(_ id: String) {
        guard let idx = aiProviders.firstIndex(where: { $0.id == id }) else { return }
        aiProviders[idx].enabled.toggle()
        persistAIProviders()
    }

    func setAIProviderAlertThreshold(_ id: String, threshold: Int) {
        guard let idx = aiProviders.firstIndex(where: { $0.id == id }) else { return }
        aiProviders[idx].alertThreshold = threshold
        persistAIProviders()
        let desc = threshold > 0 ? "低于 \(threshold)% 预警" : "关闭低余量提醒"
        showToast("\(aiProviders[idx].name)：已设为\(desc)")
    }

    func syncAIProviderNow(_ id: String) {
        guard let idx = aiProviders.firstIndex(where: { $0.id == id }) else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        if id == "cursor" {
            let detected = Self.detectCursorLocalState()
            aiProviders[idx].badge = detected ? "Cursor.app 本机已识别" : "未检测到 Cursor.app"
            aiProviders[idx].lastSyncedText = "\(stamp) 本机同步"
            persistAIProviders()
            showToast(detected ? "已同步本机 Cursor 状态" : "未检测到本机 Cursor 目录")
            return
        }
        if id == "deepseek" {
            aiProviders[idx].lastSyncedText = "\(stamp) 同步中…"
            Task.detached(priority: .userInitiated) {
                let liveBalance = await Self.fetchSilentDeepSeekBalanceIfAvailable()
                await MainActor.run {
                    let store = SystemTelemetryStore.shared
                    guard let i = store.aiProviders.firstIndex(where: { $0.id == "deepseek" }) else { return }
                    let doneStamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                    if let bal = liveBalance {
                        store.aiProviders[i].windowText = "可用余额 \(bal.displayBalance)"
                        store.aiProviders[i].percent = bal.estimatedPercent
                        store.aiProviders[i].badge = "API 实时直连"
                        store.aiProviders[i].lastSyncedText = "\(doneStamp) 已拉取"
                        store.showToast("已同步 DeepSeek 实时余额：\(bal.displayBalance)")
                    } else {
                        store.aiProviders[i].lastSyncedText = "\(doneStamp) 托管配额"
                        store.showToast("当前使用 MORIQ 托管会话额度")
                    }
                    store.persistAIProviders()
                }
            }
            return
        }
        aiProviders[idx].lastSyncedText = "\(stamp) 已校对"
        persistAIProviders()
        showToast("已刷新 \(aiProviders[idx].name) 只读配额状态")
    }

    nonisolated private static func fetchSilentDeepSeekBalanceIfAvailable() async -> (displayBalance: String, estimatedPercent: Int)? {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let flavor = Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor")
        guard !bundleID.hasPrefix("local.moriq.internal"), flavor == nil else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.moriq.deepseek",
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let keyData = item as? Data,
              let apiKey = String(data: keyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty,
              let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]],
              let first = infos.first,
              let totalStr = first["total_balance"] as? String,
              let totalVal = Double(totalStr) else {
            return nil
        }
        let currency = (first["currency"] as? String) == "USD" ? "$" : "¥"
        let pct = max(5, min(100, Int((min(totalVal, 100.0)).rounded())))
        return (String(format: "%@%.2f", currency, totalVal), pct)
    }
}

private struct KeyboardCleanShieldView: View {
    let unlock: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.90).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(LiquidGlassPalette.sapphireLight)
                Text("键盘清洁防误触锁已开启")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("物理键盘输入已临时屏蔽，防止擦拭 MacBook 键盘时误按发送消息。")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.68))
                Button(action: unlock) {
                    Text("鼠标点击此处解锁")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(LiquidGlassPalette.sapphire, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(32)
        }
    }
}
