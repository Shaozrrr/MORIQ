import SwiftUI
import AppKit
import Carbon

@MainActor final class ShortcutRecorder: ObservableObject {
    @Published var recording: GlobalShortcutFeature?
    @Published var message = ""
    @Published var revision = 0
    private var monitor: Any?

    func begin(_ feature: GlobalShortcutFeature) {
        cancel()
        recording = feature
        message = "请按下新的组合键；按 Delete 清空并恢复默认，点击空白处退出。"
        GlobalShortcutRegistry.shared.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown { self.cancel(); return event }
            if event.keyCode == UInt16(kVK_Escape) { self.cancel(); return nil }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if flags.isEmpty && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
                self.restoreDefault(feature)
                return nil
            }
            guard !event.isARepeat, let shortcut = GlobalShortcut(event: event) else {
                self.message = "请使用 Command、Option 或 Control 配合其他按键。"
                return nil
            }
            let status = GlobalShortcutRegistry.shared.update(feature, to: shortcut)
            if status == noErr {
                self.cancel()
                self.revision += 1
                self.message = "快捷键已更新。"
            } else {
                self.message = status == paramErr ? "这个组合不可使用，请尝试其他组合。" : "快捷键已被占用，请尝试其他组合。"
            }
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        recording = nil
        GlobalShortcutRegistry.shared.isRecording = false
        message = ""
    }

    func restoreDefault(_ feature: GlobalShortcutFeature) {
        cancel()
        let status = GlobalShortcutRegistry.shared.update(feature, to: feature.defaultShortcut)
        if status == noErr {
            revision += 1
            message = "已恢复默认快捷键。"
        } else {
            message = "默认快捷键已被占用，当前设置未更改。"
        }
    }
}

enum Feature: String, CaseIterable, Identifiable {
    case converter, assistant, shelf, clipboard, screenshot, notes, captions
    var id: String { rawValue }
    var title: String { switch self { case .converter: "转换圆盘"; case .assistant: "AI 助手"; case .shelf: "文件暂存架"; case .clipboard: "剪贴板"; case .screenshot: "超级截图"; case .notes: "屏幕便签"; case .captions: "实时字幕" } }
    var detail: String { switch self { case .converter: "拖动文件，快速转换格式"; case .assistant: "随时唤出，理解当前屏幕"; case .shelf: "将文件暂存屏幕边缘，随取随用"; case .clipboard: "保存复制记录，收藏常用内容"; case .screenshot: "框选、识别、翻译与标注"; case .notes: "随手记录，固定显示在桌面"; case .captions: "为电脑声音生成实时字幕" } }
    var symbol: String { switch self { case .converter: "arrow.triangle.2.circlepath"; case .assistant: "sparkle"; case .shelf: "tray.2"; case .clipboard: "doc.on.clipboard"; case .screenshot: "viewfinder"; case .notes: "note.text"; case .captions: "captions.bubble" } }
}

@MainActor final class SettingsStore: ObservableObject {
    @Published private(set) var enabled: [String: Bool]
    var onChange: ((Feature, Bool) -> Bool)?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0.rawValue, defaults.object(forKey: "feature.\($0.rawValue)") as? Bool ?? false) })
    }
    func resetCaptions() { enabled[Feature.captions.rawValue] = false; defaults.set(false, forKey: "feature.captions") }
    func binding(for feature: Feature) -> Binding<Bool> {
        Binding(get: { self.enabled[feature.rawValue] ?? false }, set: { value in
            guard self.onChange?(feature, value) ?? true else { return }
            self.enabled[feature.rawValue] = value
            self.defaults.set(value, forKey: "feature.\(feature.rawValue)")
        })
    }
}

struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case features, shortcuts, general
        var id: String { rawValue }
        var title: String { switch self { case .features: "功能设置"; case .shortcuts: "快捷键"; case .general: "通用设置" } }
        var symbol: String { switch self { case .features: "square.grid.2x2"; case .shortcuts: "keyboard"; case .general: "slider.horizontal.3" } }
    }
    @State private var diagnosticsStopping = false
    @State private var localDiagnosticCounts: [DiagnosticFeature:Int] = [:]
    @State private var localDiagnosticMessage = ""
    @AppStorage("moriq.localDiagnostics.enabled") private var localDiagnosticsEnabled = false
    @AppStorage("moriq.hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("moriq.converterModifier") private var converterModifier = "shift"
    @AppStorage("moriq.permissionDarkMode") private var dark = false
    @AppStorage("moriq.managedSpeechConsent") private var managedSpeechConsent = false
    @AppStorage("moriq.caption.punct.enabled") private var captionPunctEnabled = false
    @State private var managedServiceToken = ""
    @State private var managedServiceMessage = ""
    @State private var invitation = ""
    @State private var activationMessage = ""
    @State private var activationBusy = false
    @State private var activationPending = false
    private let deviceActivation = DeviceRenewalCoordinator.shared
    @State private var section: Section = .features
    @StateObject private var shortcutRecorder = ShortcutRecorder()
    @ObservedObject var store: SettingsStore
    var showDemo: (Feature) -> Void
    var newNote: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    MORIQMark().frame(width: 26, height: 26).accessibilityHidden(true)
                    Text("MORIQ").font(.system(size: 17, weight: .bold)).tracking(0.8)
                }.padding(.horizontal, 10).padding(.bottom, 25)
                ForEach(Section.allCases) { item in
                    Button { if item != .shortcuts { shortcutRecorder.cancel() }; section = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 19)
                            Text(item.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: section == item ? .semibold : .medium))
                        .foregroundStyle(section == item ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(section == item ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 27).padding(.bottom, 20)
            .frame(width: 168).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.system(size: 24, weight: .bold))
                        Text(section == .features ? "选择需要的功能，随时开启或关闭。" : section == .shortcuts ? "将常用操作放在顺手的位置。" : "调整适合你的使用方式。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.bottom, 22)
                switch section {
                case .features: features
                case .shortcuts: shortcuts
                case .general: general
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 650, minHeight: 560, alignment: .topLeading)
        .onDisappear { shortcutRecorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in shortcutRecorder.cancel() }
    }
    private var features: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(Feature.allCases.enumerated()), id: \.element.id) { index, feature in
                    FeatureRow(feature: feature, enabled: store.binding(for: feature), demo: { showDemo(feature) }, newNote: newNote)
                    if index < Feature.allCases.count - 1 { Divider().padding(.leading, 48) }
                }
            }
        }.frame(maxHeight: .infinity)
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("转换圆盘").font(.system(size: 13, weight: .semibold))
                    Text("拖动文件时按住触发键").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("转换圆盘触发键", selection: $converterModifier) {
                    Text("⇧ Shift").tag("shift")
                    Text("⌥ Option").tag("option")
                    Text("⌃ Control").tag("control")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220).controlSize(.small)
            }.frame(minHeight: 70)
            Divider()
            shortcutRow("AI 助手", feature: .assistant)
            Divider()
            shortcutRow("剪贴板", feature: .clipboard)
            Divider()
            shortcutRow("超级截图", feature: .screenshot)
            Divider()
            shortcutRow("打开或收起文件暂存架", feature: .shelf)
            Divider()
            shortcutRow("新建屏幕便签", feature: .notes)
            Divider()
            shortcutRow("开启或停止实时字幕", feature: .captions)
        }
        }.frame(maxHeight: .infinity)
            Text(shortcutRecorder.message.isEmpty ? "点击快捷键输入新组合；清空可恢复默认。" : shortcutRecorder.message)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
                .accessibilityIdentifier("shortcutRecordingMessage")
        }
    }
    private func shortcutRow(_ title: String, feature: GlobalShortcutFeature) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if GlobalShortcutRegistry.shared.current(feature) != feature.defaultShortcut {
                Button("恢复默认") { shortcutRecorder.restoreDefault(feature) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("恢复\(title)默认快捷键")
            }
            Button { shortcutRecorder.begin(feature) } label: {
                Text(shortcutRecorder.recording == feature ? "输入组合键…" : GlobalShortcutRegistry.shared.current(feature).displayText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(shortcutRecorder.recording == feature ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).accessibilityLabel("设置\(title)快捷键")
        }.frame(minHeight: 58)
    }
    private var general: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("外观").font(.system(size: 13, weight: .semibold))
                    Text("应用内所有页面使用相同外观").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("外观", selection: $dark) {
                    Text("浅色").tag(false)
                    Text("深色").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 140).controlSize(.small)
            }
            .frame(minHeight: 70)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("触觉反馈").font(.system(size: 13, weight: .semibold))
                    Text("在支持触感的触控板上轻点提示").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("触觉反馈", isOn: $hapticsEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }.frame(minHeight: 70)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本机诊断记录").font(.system(size: 13, weight: .semibold))
                    Text("仅本机记录结果与耗时分档，不上传。运行时清理 7 天前数据，上限 512 KB；关闭后停止记录并保留旧记录。未知或损坏记录会暂停清理，空间不足时暂停写入，可手动清除。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("本机诊断记录", isOn: $localDiagnosticsEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(diagnosticsStopping)
                    .onChange(of: localDiagnosticsEnabled) { _, enabled in if enabled { LocalDiagnostics.shared.record(.settings, .toggle, .success) } else {
                        diagnosticsStopping = true; localDiagnosticMessage = "正在停止记录…"
                        DispatchQueue.global(qos: .utility).async {
                            LocalDiagnostics.shared.disableAndDrain()
                            DispatchQueue.main.async { diagnosticsStopping = false; localDiagnosticMessage = "已停止记录，旧记录仍保留" }
                        }
                    } }
            }.frame(minHeight: 70)
            HStack {
                Button("查看本机诊断汇总") {
                    LocalDiagnostics.shared.summary { counts in
                        localDiagnosticCounts = counts
                        let health=LocalDiagnostics.shared.health()
                        let base=counts.isEmpty ? "暂无记录" : "共 \(counts.values.reduce(0,+)) 条事件，仅保存在本机"
                        localDiagnosticMessage = base + "；本次队列丢弃 \(health.dropped) 条、写入失败 \(health.writeFailures) 条、容量轮转 \(health.capacityEvictions) 条"
                    }
                }
                Button("清除本机诊断记录") {
                    LocalDiagnostics.shared.clear { ok in localDiagnosticCounts = [:]; localDiagnosticMessage = ok ? "已清除" : "无法清除" }
                }
                Text(localDiagnosticMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }.font(.system(size: 11)).frame(minHeight: 42)
            if !localDiagnosticCounts.isEmpty {
                Text("开始与结束分别计为事件，不等于使用次数；字幕启动成功仅表示采集已启动。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                Text(DiagnosticFeature.allCases.compactMap { feature in localDiagnosticCounts[feature].map { "\(feature.label) \($0)" } }.joined(separator: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
            if Bundle.main.object(forInfoDictionaryKey: "MORIQManagedSpeechEndpoint") != nil {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("在线字幕翻译").font(.system(size: 13, weight: .semibold))
                        Text("使用在线字幕时，系统声音会发送至 MORIQ 及语音服务用于识别；识别出的文字可能发送至翻译服务并自动翻译。关闭字幕或关闭此授权可停止后续发送。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("允许在线字幕翻译", isOn: $managedSpeechConsent).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.frame(minHeight: 70)
                if Bundle.main.object(forInfoDictionaryKey: "MORIQCaptionPunctAvailable") as? Bool == true {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("增强实时翻译").font(.system(size: 13, weight: .semibold))
                            Text("按句更新译文；此模式暂不支持手动校订。使用时发送电脑系统声音，关闭后新会话生效。")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("增强实时翻译", isOn: $captionPunctEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }.frame(minHeight: 70)
                }
                Divider()
                if Bundle.main.object(forInfoDictionaryKey: "MORIQAnonymousDeviceEnabled") as? Bool != true {
                if let configured = Bundle.main.object(forInfoDictionaryKey: "MORIQDeviceActivationEndpoint") as? String,
                   let endpoint = URL(string: configured) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("连接 MORIQ 服务").font(.system(size: 13, weight: .semibold))
                        Text("使用私人邀请码在这台 Mac 上启用在线功能。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            SecureField("私人邀请码", text: $invitation).textFieldStyle(.roundedBorder)
                                .disabled(activationPending || activationBusy)
                            Button(activationPending ? "重试连接" : "连接") {
                                activationBusy = true; activationMessage = "正在连接…"
                                Task {
                                    do {
                                        try RuntimeCredentialPolicy.current.requireAccess()
                                        try RuntimeCredentialPolicy.current.requireNetwork()
                                        let saved = try DeviceRenewalKeychain().load()
                                        let code = saved?.pendingInvite ?? invitation
                                        let transport = try DeviceRenewalTransport(endpoint: endpoint)
                                        try await deviceActivation.activate(invite: code, using: transport)
                                        invitation = ""; activationPending = false; activationMessage = "已连接。"
                                    } catch {
                                        if (try? RuntimeCredentialPolicy.current.requireAccess()) != nil {
                                            activationPending = (try? DeviceRenewalKeychain().load()?.pendingInvite) != nil
                                        }
                                        activationMessage = "连接未完成，请检查网络或邀请码后重试。"
                                    }
                                    activationBusy = false
                                }
                            }.disabled(activationBusy || (!activationPending && invitation.isEmpty))
                            if activationPending {
                                Button("更换邀请码") {
                                    do {
                                        try RuntimeCredentialPolicy.current.requireAccess()
                                        if try DeviceRenewalKeychain().load()?.pendingInvite != nil {
                                            try DeviceRenewalKeychain().delete()
                                            activationPending = false; invitation = ""; activationMessage = "请输入新的邀请码。"
                                        }
                                    } catch { activationMessage = "无法更新钥匙串，请稍后重试。" }
                                }.disabled(activationBusy)
                            }
                        }
                        if !activationMessage.isEmpty { Text(activationMessage).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }.padding(.vertical, 14)
                     .onAppear {
                         if (try? RuntimeCredentialPolicy.current.requireAccess()) != nil {
                             activationPending = (try? DeviceRenewalKeychain().load()?.pendingInvite) != nil
                         }
                     }
                    Divider()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("字幕服务凭证").font(.system(size: 13, weight: .semibold))
                    Text("输入分配给你的服务凭证，保存在这台 Mac 的钥匙串中。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        SecureField("服务凭证", text: $managedServiceToken)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("managedServiceToken")
                        Button("保存") {
                            do {
                                try ManagedAIAccountToken().save(managedServiceToken)
                                managedServiceToken = ""
                                managedServiceMessage = "凭证已保存。"
                            } catch ManagedAIError.deviceAlreadyConnected {
                                managedServiceMessage = "此设备已连接服务，无需再保存服务凭证。"
                            } catch {
                                managedServiceMessage = "保存失败，请检查凭证或钥匙串权限。"
                            }
                        }.disabled(managedServiceToken.isEmpty)
                    }
                    if !managedServiceMessage.isEmpty {
                        Text(managedServiceMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 14)
                }

            }
        }
    }
}
struct FeatureRow: View {
    let feature: Feature
    @Binding var enabled: Bool
    let demo: () -> Void
    let newNote: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feature.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(feature.title).font(.system(size: 13, weight: .semibold))
                Text(feature.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if feature == .notes && enabled { Button("新建", action: newNote).controlSize(.small).accessibilityLabel("新建屏幕便签") }
            Button("演示", action: demo).controlSize(.small).accessibilityLabel("演示\(feature.title)")
            Toggle("启用\(feature.title)", isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("启用\(feature.title)")
        }.frame(minHeight: 69)
    }
}
