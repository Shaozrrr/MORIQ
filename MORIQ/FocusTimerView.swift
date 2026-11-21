import AppKit
import Combine
import Darwin
import os
import SwiftUI
import UserNotifications

/// Uses a sleep-inclusive clock and a boot timestamp so a saved timer can be
/// restored after the application restarts without trusting wall-clock jumps.
enum FocusTimerSystemClock {
    static let bootID: String = {
        var value = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "unknown-\(UUID().uuidString)" }
        return "\(value.tv_sec).\(value.tv_usec)"
    }()
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
    }()
    static func now() -> FocusTimerInstant {
        let seconds = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return FocusTimerInstant(wall: Date(), continuous: seconds, bootID: bootID)
    }
}

/// Only schedules a system notification when the user has explicitly enabled it.
final class FocusTimerSystemNotifications: FocusTimerNotifications {
    static let identifier = "local.moriq.focus.finished"
    var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    func cancel() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier]) }
    func schedule(after seconds: TimeInterval, phase: FocusTimerPhase) {
        cancel()
        guard enabled, seconds > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = phase == .focus ? "专注时间结束" : "休息时间结束"
        content.body = phase == .focus ? "休息一下吧。" : "准备好时，开始下一段专注。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
    }
}

@MainActor final class FocusTimerStore: ObservableObject {
    static let shared = FocusTimerStore()
    @Published private(set) var snapshot: FocusTimerSnapshot
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var notificationMessage: String?
    private var timer: FocusTimerCore
    private let notifier: FocusTimerSystemNotifications
    private let defaults: UserDefaults
    private var tick: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?
    private var lastPersist: TimeInterval = 0
    private var notificationRequestID = UUID()
    private static let notificationLog = Logger(subsystem: "local.moriq.app", category: "FocusNotifications")
    private static let snapshotKey = "focus.timer.snapshot.v1"
    private static let notificationKey = "focus.timer.notifications.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.notificationKey)
        notificationsEnabled = enabled
        let notifier = FocusTimerSystemNotifications(enabled: enabled)
        self.notifier = notifier
        let saved = defaults.data(forKey: Self.snapshotKey).flatMap { try? JSONDecoder().decode(FocusTimerSnapshot.self, from: $0) }
        let core = FocusTimerCore(now: FocusTimerSystemClock.now(), notifications: notifier, restored: saved)
        self.timer = core
        self.snapshot = core.snapshot
        tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(forceSave: true) }
        }
        persist()
    }
    deinit {
        tick?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    var displayTime: String {
        let seconds = Int(ceil(max(0, snapshot.remainingAtAnchor)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    func start(_ phase: FocusTimerPhase) { timer.start(phase: phase, now: FocusTimerSystemClock.now()); sync() }
    func pause() { timer.pause(now: FocusTimerSystemClock.now()); sync() }
    func resume() { timer.resume(now: FocusTimerSystemClock.now()); sync() }
    func end() { timer.end(now: FocusTimerSystemClock.now()); sync() }
    func refresh(forceSave: Bool = false) {
        guard timer.snapshot.status == .running else { return }
        let now = FocusTimerSystemClock.now()
        let finished = timer.refresh(now: now)
        snapshot = timer.snapshot
        if forceSave || finished || now.continuous - lastPersist >= 5 { persist(); lastPersist = now.continuous }
    }
    private func sync() { snapshot = timer.snapshot; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(timer.snapshot) { defaults.set(data, forKey: Self.snapshotKey) } }

    func refreshNotificationPermission() async {
        guard notificationsEnabled else { return }
        let requestID = notificationRequestID
        let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard !Task.isCancelled, requestID == notificationRequestID, authorization == .denied else { return }
        applyNotificationsEnabled(false)
        notificationMessage = "系统通知已关闭"
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        let requestID = UUID(); notificationRequestID = requestID
        if !enabled { applyNotificationsEnabled(false); notificationMessage = nil; return }
        Task { [self] in
            let center = UNUserNotificationCenter.current()
            let authorization = await center.notificationSettings().authorizationStatus
            guard self.notificationRequestID == requestID else { return }
            if authorization == .denied {
                self.applyNotificationsEnabled(false)
                self.notificationMessage = "系统通知已关闭"
                return
            }
            do {
                let permitted = try await center.requestAuthorization(options: [.alert, .sound])
                guard self.notificationRequestID == requestID else { return }
                self.applyNotificationsEnabled(permitted)
                self.notificationMessage = permitted ? nil : "系统通知已关闭"
            } catch {
                guard self.notificationRequestID == requestID else { return }
                let failure = error as NSError
                self.applyNotificationsEnabled(false)
                self.notificationMessage = "无法开启系统通知"
                let status = await center.notificationSettings().authorizationStatus.rawValue
                let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                Self.notificationLog.error("Notification authorization failed: \(failure.domain, privacy: .public) (\(failure.code, privacy: .public)), authorization status \(status, privacy: .public), underlying \(underlying?.domain ?? "-", privacy: .public) (\(underlying?.code ?? 0, privacy: .public))")
            }
        }
    }
    private func applyNotificationsEnabled(_ enabled: Bool) {
        notifier.enabled = enabled; notificationsEnabled = enabled; defaults.set(enabled, forKey: Self.notificationKey)
        notifier.cancel()
        if enabled, snapshot.status == .running { refresh(forceSave: true); if snapshot.status == .running { notifier.schedule(after: snapshot.remainingAtAnchor, phase: snapshot.phase) } }
    }
}

struct FocusTimerView: View {
    @ObservedObject var store: FocusTimerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("专注计时").font(.headline)
                Spacer()
                Text(store.snapshot.phase == .focus ? "专注" : "休息").font(.caption).foregroundStyle(.secondary)
            }
            Text(store.displayTime).font(.system(size: 44, weight: .medium, design: .rounded).monospacedDigit()).frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                if store.snapshot.status == .running {
                    Button("暂停") { store.pause() }
                    Button("结束") { store.end() }
                } else if store.snapshot.status == .paused {
                    Button("继续") { store.resume() }
                    Button("结束") { store.end() }
                } else {
                    Button("开始专注 · 25 分钟") { store.start(.focus) }
                    Button("休息 · 5 分钟") { store.start(.rest) }
                }
            }.frame(maxWidth: .infinity)
            Divider()
            Toggle("结束时提醒我", isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotificationsEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small)
            if let message = store.notificationMessage {
                HStack {
                    Text(message).foregroundStyle(.secondary)
                    Spacer()
                    if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        Link("通知设置", destination: settingsURL)
                    }
                }.font(.caption)
            }
        }.padding(18).frame(width: 310)
            .task { await store.refreshNotificationPermission() }
    }
}
