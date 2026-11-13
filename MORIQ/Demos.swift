import AppKit
import SwiftUI

@MainActor final class DemoState: ObservableObject {
    @Published var stage = 0
    @Published var startedAt = Date()
    private var task: Task<Void, Never>?
    func replay(reduceMotion: Bool) {
        task?.cancel(); stage = 0; startedAt = Date()
        task = Task { @MainActor in
            for next in 1...5 {
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 650 : 850)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: next == 3 ? 0.55 : 0.25)) { stage = next }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

final class DemoWindow: NSWindow {
    var onClose: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() { onClose?(); super.close() }
}
@MainActor final class DemoCoordinator: NSObject, NSWindowDelegate {
    private var windows: [Feature: DemoWindow] = [:]
    private var states: [Feature: DemoState] = [:]
    func show(_ feature: Feature) {
        if let window = windows[feature] { window.makeKeyAndOrderFront(nil); states[feature]?.replay(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); return }
        let state = DemoState()
        let window = DemoWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = feature.title + " · 演示"; window.minSize = NSSize(width: 640, height: 390); window.isReleasedWhenClosed = false; window.delegate = self
        window.onClose = { [weak self] in self?.remove(feature) }
        window.contentView = NSHostingView(rootView: DemoView(feature: feature, state: state))
        window.center(); windows[feature] = window; states[feature] = state
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        state.replay(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func windowWillClose(_ notification: Notification) { if let window = notification.object as? NSWindow, let feature = windows.first(where: { $0.value === window })?.key { remove(feature) } }
    private func remove(_ feature: Feature) { states[feature]?.stop(); states.removeValue(forKey: feature); windows.removeValue(forKey: feature) }
    func closeAll() { for window in Array(windows.values) { window.close() }; states.values.forEach { $0.stop() }; states.removeAll(); windows.removeAll() }
}
struct DemoView: View {
    let feature: Feature
    @ObservedObject var state: DemoState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage("moriq.converterModifier") private var converterModifier = "shift"
    private let blue = Color(red: 37/255, green: 99/255, blue: 1)
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing)
                desktop.frame(width: geo.size.width * 0.74, height: geo.size.height * 0.68).position(x: geo.size.width * 0.48, y: geo.size.height * 0.49)
                scene.frame(maxWidth: .infinity, maxHeight: .infinity)
                Button { state.replay(reduceMotion: reduceMotion) } label: { Label("重新播放", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.borderless).foregroundStyle(blue).padding(16)
            }.clipped()
        }
    }
    private var desktop: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) { ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.3)).frame(width: 7, height: 7) }; Spacer(); Text(feature == .assistant ? "浏览器 · 示例" : feature == .screenshot ? "浏览器" : "访达").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary); Spacer() }
                .padding(.horizontal, 14).frame(height: 30).background(.primary.opacity(0.035))
            Rectangle().fill(.background.opacity(0.8))
        }.clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.09))).shadow(color: .black.opacity(0.09), radius: 18, y: 7)
    }
    @ViewBuilder private var scene: some View {
        switch feature {
        case .converter: converter
        case .assistant: assistant
        case .shelf: shelf
        case .clipboard: clipboard
        case .screenshot: screenshot
        case .notes: notes
        case .captions: captions
        }
    }
    private var captions: some View {
        VStack(spacing: 10) {
            Text("系统声音 · 可切换麦克风").font(.system(size: 11)).foregroundStyle(.secondary)
            Image(systemName: "play.rectangle.fill").font(.system(size: 50)).foregroundStyle(blue.opacity(0.7))
            Spacer().frame(height: 18)
            VStack(spacing: 5) {
                Text(state.stage >= 2 ? "Let's make everyday work feel effortless." : "正在聆听…")
                if state.stage >= 3 { Text("让每一天的操作都更轻松。 ").foregroundStyle(.secondary) }
            }.font(.system(size: 14, weight: .medium)).padding(14)
             .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }.frame(width: 400, height: 220).opacity(state.stage == 0 ? 0.45 : 1)
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("便签").font(.system(size: 12, weight: .semibold)); Spacer(); Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(blue) }
            Text(state.stage >= 2 ? "周五前确认设计稿" : "随手记下灵感")
                .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Text("固定在桌面 · 自动保存").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 235, height: 170, alignment: .topLeading)
         .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
         .overlay(RoundedRectangle(cornerRadius: 15).stroke(.primary.opacity(0.08)))
         .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
         .offset(x: state.stage == 0 ? 15 : 0, y: state.stage == 0 ? 8 : 0)
         .opacity(state.stage == 0 ? 0.5 : 1)
    }
    private var converter: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || state.stage == 0 || state.stage >= 5)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(state.startedAt)
            let cursor = demoCursor(elapsed)
            let dx = cursor.x - 70, dy = cursor.y
            let hovered = WheelGeometry.index(point: CGPoint(x: dx * 1.84, y: -dy * 1.84), center: .zero, count: 12)
            ZStack {
                file("照片.heic", "photo").offset(x: -175, y: -8)
                    .opacity(state.stage >= 1 && state.stage < 5 ? 0.35 : 1)
                if state.stage >= 5 { file("照片.png", "photo.fill").offset(x: -102, y: -8).transition(.opacity) }
                if state.stage >= 2 && state.stage < 5 {
                    ZStack {
                        ForEach(Array(["HEIC", "JP2", "ZIP", "TAR", "PNG", "JPG", "TIFF", "PDF", "GIF", "BMP", "AVIF", "WEBP"].enumerated()), id: \.offset) { index, label in
                            let inner = index < 4
                            let local = inner ? index : index - 4
                            let count = inner ? 4 : 8
                            let angle = -Double.pi / 2 + Double(local) * 2 * .pi / Double(count)
                            let radius: CGFloat = inner ? 46.7 : 83.2
                            let selected = hovered == index
                            let segment = RingSector(index: local, count: count, inner: inner ? 56/184 : 122/184, outer: inner ? 116/184 : 1)
                            segment.fill(.ultraThinMaterial)
                                .overlay(segment.fill(selected ? blue.opacity(0.16) : Color(red: 0.75, green: 0.80, blue: 0.89).opacity(0.19)))
                                .overlay(segment.stroke(selected ? blue.opacity(0.58) : Color(red: 0.43, green: 0.50, blue: 0.63).opacity(0.22), lineWidth: selected ? 1 : 0.7))
                                .scaleEffect(selected && !reduceMotion ? 1.015 : 1)
                            Text(label).font(.system(size: 8.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? blue : Color.black.opacity(0.78))
                                .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
                        }
                    }.frame(width: 200, height: 200)
                        .environment(\.colorScheme, .light)
                        .shadow(color: .black.opacity(0.045), radius: 10, y: 3).offset(x: 70)
                        .animation(.easeOut(duration: 0.16), value: hovered)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.88)))
                }
                if state.stage >= 1 && state.stage < 5 {
                    HStack(alignment: .bottom, spacing: 2) {
                        Image(systemName: "photo").font(.system(size: 23)).foregroundStyle(blue)
                        Image(systemName: "cursorarrow").font(.system(size: 16)).foregroundStyle(.primary)
                    }.offset(x: cursor.x, y: cursor.y)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
                if state.stage == 1 { keyHint("按住 \(converterModifier == "option" ? "⌥ Option" : converterModifier == "control" ? "⌃ Control" : "⇧ Shift") 拖动文件").offset(y: 135) }
            }
        }
    }
    private func demoCursor(_ time: TimeInterval) -> CGPoint {
        // The pointer passes PDF, TIFF and JPG before settling on PNG.
        let steps: [(Double, CGPoint)] = [
            (0.85, CGPoint(x: -165, y: -8)), (1.7, CGPoint(x: 70, y: 0)),
            (2.20, CGPoint(x: 98, y: 69)), (2.55, CGPoint(x: 139, y: 28)),
            (2.90, CGPoint(x: 129, y: -59)), (3.3, CGPoint(x: 70, y: -83)),
            (4.25, CGPoint(x: 70, y: -83))
        ]
        guard let last = steps.last else { return .zero }
        for i in 1..<steps.count where time <= steps[i].0 {
            let previous = steps[i - 1], next = steps[i]
            let p = max(0, min(1, (time - previous.0) / (next.0 - previous.0)))
            let eased = p * p * (3 - 2 * p)
            return CGPoint(x: previous.1.x + (next.1.x - previous.1.x) * eased,
                           y: previous.1.y + (next.1.y - previous.1.y) * eased)
        }
        return last.1
    }
    private var assistant: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("项目周会纪要").font(.system(size: 14, weight: .semibold))
                Text("产品更新 · 会议记录").font(.system(size: 10)).foregroundStyle(.secondary)
                Divider().padding(.vertical, 3)
                Text("新版页面本周五前完成初稿，交由设计团队评审。\n下周一汇总反馈，周三确认最终方案。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                Text("待办：小林整理页面，小周收集评审意见。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 3)
            }.frame(width: 330, alignment: .leading).offset(x: -30, y: -58)
            if state.stage == 1 { keyHint("⌘ ⇧ Space").offset(y: 45).transition(.opacity) }
            if state.stage >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    if state.stage >= 4 {
                        Text("关键时间与待办").font(.system(size: 11, weight: .semibold))
                        Text("周五：完成页面初稿并评审\n周一：汇总反馈 · 周三：确认方案\n小林负责页面，小周收集意见。")
                            .font(.system(size: 10)).lineSpacing(3).foregroundStyle(.primary)
                            .transition(.opacity)
                    }
                    HStack {
                        Text(state.stage >= 3 && state.stage < 5 ? "帮我整理时间节点和负责人" : "问问当前屏幕…").foregroundStyle(.secondary)
                        Spacer(); Image(systemName: "arrow.up.circle.fill").foregroundStyle(blue)
                    }.font(.system(size: 11))
                }.padding(.horizontal, 16).padding(.vertical, 13)
                    .frame(width: 330, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(blue.opacity(0.28)))
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 4).offset(y: 108)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
            }
        }
    }
    private var shelf: some View {
        ZStack {
            HStack(spacing: 28) { file("方案.pdf", "doc.fill"); file("图片.png", "photo.fill") }
                .offset(x: -100)
                .opacity(state.stage >= 1 && state.stage <= 3 ? 0.35 : 1)
            if state.stage >= 1 && state.stage <= 3 {
                HStack(spacing: 28) { file("方案.pdf", "doc.fill"); file("图片.png", "photo.fill") }
                    .offset(x: state.stage == 1 ? -100 : state.stage == 2 ? 100 : 205)
                    .opacity(state.stage == 3 ? 0 : 1)
                    .transition(.opacity)
            }
            if state.stage >= 2 {
                ShelfStardust(proximity: state.stage >= 3 ? 0.8 : 0.35, visible: true, pointer: CGPoint(x: 150, y: 115), expanded: false)
                    .frame(width: 160, height: 232).offset(x: 200)
                    .transition(.opacity)
            }
            if state.stage >= 3 && state.stage < 5 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂存架").font(.system(size: 12, weight: .semibold))
                    Text("文件保留在原来的位置").font(.system(size: 8)).foregroundStyle(.secondary)
                    HStack { Text("全选").foregroundStyle(blue); Spacer(); Text("2 个文件").foregroundStyle(.secondary) }.font(.system(size: 9)).padding(.vertical, 3)
                    Label("方案.pdf", systemImage: "doc.fill").padding(5).frame(maxWidth: .infinity, alignment: .leading)
                        .background(blue.opacity(state.stage >= 4 ? 0.13 : 0), in: RoundedRectangle(cornerRadius: 5))
                    Label("图片.png", systemImage: "photo.fill").padding(5).frame(maxWidth: .infinity, alignment: .leading)
                        .background(blue.opacity(state.stage >= 4 ? 0.13 : 0), in: RoundedRectangle(cornerRadius: 5))
                }
                .font(.system(size: 10)).padding(14).frame(width: 170, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .offset(x: 176)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 8)))
            }
        }
    }
    private var clipboard: some View {
        ZStack {
            Text(state.stage < 2 ? "复制常用内容，随时找回" : "历史和收藏，一点即用")
                .font(.system(size: 15)).offset(x: -65, y: -105)
            if state.stage == 2 { keyHint("⌘ ⇧ V").offset(y: 110) }
            if state.stage >= 3 {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 18) {
                        Text("历史").foregroundStyle(state.stage < 5 ? blue : .secondary)
                        Text("收藏").foregroundStyle(state.stage >= 5 ? blue : .secondary)
                        Spacer(); Text("点击即可复制").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Label("搜索剪贴板", systemImage: "magnifyingglass").foregroundStyle(.secondary)
                    HStack { Text("常用回复 · 今天"); Spacer(); Image(systemName: state.stage >= 4 ? "star.fill" : "star").foregroundStyle(blue) }
                        .padding(8).background(blue.opacity(state.stage >= 4 ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
                    if state.stage < 5 { Text("项目清单 · 今天").padding(.horizontal, 8) }
                }.font(.system(size: 11)).padding(14).frame(width: 285).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.13), radius: 12, y: 5)
            }
        }
    }
    private var screenshot: some View {
        ScreenshotFeatureScene(startedAt: state.startedAt, reduceMotion: reduceMotion)
    }
    private func file(_ title: String, _ symbol: String) -> some View { VStack(spacing: 7) { Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(blue); Text(title).font(.system(size: 10)).fixedSize(horizontal: true, vertical: false) } }
    private func keyHint(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule()) }
}

private struct ScreenshotFeatureScene: View {
    let startedAt: Date
    let reduceMotion: Bool
    @State private var step = -1
    @State private var editPhase = 0
    @State private var translationReady = false
    private let blue = Color(red: 37/255, green: 99/255, blue: 1)
    private let icons = ["doc.on.doc", "text.viewfinder", "character.bubble", "pencil", "pin", "sparkle"]
    private let titles = ["复制截图", "提取文字", "翻译文字", "编辑标注", "贴图置顶", "询问截图"]
    private let details = ["框选后直接复制到剪贴板", "将图片里的文字变成可复制文本", "快速理解截图中的外文", "添加文字与边框，再复制成图", "把重要内容留在屏幕上", "围绕截图内容继续提问"]
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 7) {
                Text("A better way to focus.")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .overlay {
                        if step == 3 {
                            RoundedRectangle(cornerRadius: 3).trim(from: 0, to: editPhase >= 1 ? 1 : 0)
                                .stroke(blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if step == 3 && editPhase >= 2 {
                            Text("重点").font(.system(size: 10, weight: .semibold)).foregroundStyle(blue)
                                .fixedSize().offset(x: 29).transition(.opacity)
                        }
                    }
                Text("Keep the important details close.\nMove between ideas with ease.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 5)
            }.offset(x: -75, y: -50)
            if step >= 0 {
                RoundedRectangle(cornerRadius: 2).stroke(blue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: 240, height: 105).offset(x: -60, y: -34).transition(.opacity)
                HStack(spacing: 13) {
                    ForEach(icons.indices, id: \.self) { i in
                        Image(systemName: icons[i]).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(step == i ? blue : Color.primary.opacity(0.7))
                            .frame(width: 19, height: 19)
                            .background(step == i ? blue.opacity(0.10) : .clear, in: Circle())
                            .scaleEffect(step == i && !reduceMotion ? 1.08 : 1)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).offset(y: 65)
                VStack(spacing: 4) {
                    Text(titles[step]).font(.system(size: 11, weight: .semibold)).foregroundStyle(blue)
                    Text((step == 3 && editPhase == 3 ? "标注完成，直接复制图片" : details[step]) + " · 效果示意")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.id(step).offset(y: 112).transition(.opacity)
                if step == 0 {
                    exampleResult("已复制截图", "可直接粘贴到聊天或文档", symbol: "checkmark")
                }
                if step == 1 {
                    exampleResult("提取的文字", "A better way to focus.\nKeep the important details close.", symbol: "text.viewfinder")
                }
                if step == 2 {
                    exampleResult("英文 → 中文", translationReady ? "更专注的方式。\n让重要细节近在手边。\n在不同想法间轻松切换。" : "正在翻译…", symbol: "character.bubble")
                }
                if step == 3 {
                    if editPhase >= 3 { exampleResult("已复制标注图片", "边框和文字一起复制", symbol: "checkmark") }
                }
                if step == 4 {
                    exampleResult("贴在屏幕上", "重要内容随时可见", symbol: "pin.fill")
                }
                if step == 5 {
                    exampleResult("问问这张截图", "帮我解释这段内容", symbol: "sparkle")
                }
            } else {
                Text("⌘ ⇧ X").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: Capsule()).offset(y: 110)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.3), value: step)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .easeInOut(duration: 0.55), value: editPhase)
        .animation(.easeOut(duration: 0.25), value: translationReady)
        .task(id: startedAt) {
            step = -1; editPhase = 0; translationReady = false
            do {
                try await Task.sleep(for: .milliseconds(1200))
                for i in icons.indices {
                    step = i
                    if i == 2 {
                        try await Task.sleep(for: .milliseconds(650)); translationReady = true
                        try await Task.sleep(for: .milliseconds(2600))
                    } else if i == 3 {
                        try await Task.sleep(for: .milliseconds(500)); editPhase = 1
                        try await Task.sleep(for: .milliseconds(800)); editPhase = 2
                        try await Task.sleep(for: .milliseconds(900)); editPhase = 3
                        try await Task.sleep(for: .milliseconds(1500))
                    } else {
                        try await Task.sleep(for: .milliseconds(2300))
                    }
                }
            } catch { return }
        }
    }
    private func exampleResult(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .padding(11).frame(width: 150, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .offset(x: 152, y: -25).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
    }
}

/// A separated annular sector; the transparent centre is intentionally empty.
struct RingSector: Shape {
    let index: Int
    let count: Int
    var inner: CGFloat = 0.56
    var outer: CGFloat = 1
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let sweep = 360.0 / Double(count)
        let start = -90.0 + Double(index) * sweep - sweep / 2 + 1.5
        let end = -90.0 + Double(index) * sweep + sweep / 2 - 1.5
        var p = Path()
        p.addArc(center: centre, radius: radius * outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        p.addArc(center: centre, radius: radius * inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}
