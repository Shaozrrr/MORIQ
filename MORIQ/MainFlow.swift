import AppKit
import SwiftUI
import ApplicationServices
import Speech

@MainActor final class AppFlow: ObservableObject {
    enum Page { case introduction, permissions, settings, demo(Feature), connection, screenshotEditor(CGImage), conversionResults }
    @Published var page: Page = UserDefaults.standard.bool(forKey: "moriq.introComplete") ? .permissions : .introduction
    @Published var notice: String?
    @Published var conversionResults: [ConversionRecord] = []
    @Published var autoEnterWhenReady = UserDefaults.standard.bool(forKey: "moriq.completedFirstEntry")
    var introComplete = UserDefaults.standard.bool(forKey: "moriq.introComplete")
    var onFirstEntry: (() -> Void)?
    private var entered = false
    var mayEnter: Bool { CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && FolderAccessProbe.verifiedThisLaunch && DirectScreenAccessProbe.verifiedThisLaunch && CaptionAudioPermissionProbe.verifiedThisLaunch }
    func enterSettings() {
        guard introComplete else { page = .introduction; return }
        guard mayEnter else { page = .permissions; return }
        UserDefaults.standard.set(true, forKey: "moriq.completedFirstEntry")
        autoEnterWhenReady = false
        page = .settings
        if !entered { entered = true; onFirstEntry?() }
    }
}
struct MainFlowView: View {
    @ObservedObject var flow: AppFlow
    @ObservedObject var store: SettingsStore
    var newNote: () -> Void
    @AppStorage("moriq.permissionDarkMode") private var dark = false
    private var screenshotPasteboard: NSPasteboard {
        #if DEBUG
        if CommandLine.arguments.contains("--preview-screenshot-editor") { return NSPasteboard(name: NSPasteboard.Name("local.moriq.test.screenshot-editor")) }
        #endif
        return .general
    }
    var body: some View {
        VStack(spacing: 0) {
            if let notice = flow.notice {
                HStack { Text(notice).font(.caption); Spacer(); Button("关闭") { flow.notice = nil }.buttonStyle(.borderless) }
                    .padding(.horizontal, 20).padding(.vertical, 9).background(Color.accentColor.opacity(0.12))
            }
            switch flow.page {
            case .introduction:
                FeatureIntroduction { flow.introComplete = true; UserDefaults.standard.set(true, forKey: "moriq.introComplete"); flow.page = .permissions }
            case .permissions:
                PermissionOnboardingView(finish: { flow.enterSettings() }, back: { flow.autoEnterWhenReady = false; flow.page = .introduction }, autoEnterWhenReady: flow.autoEnterWhenReady)
            case .settings:
                SettingsView(store: store, showDemo: { flow.page = .demo($0) }, newNote: newNote)
            case .demo(let feature):
                InlineDemo(feature: feature, back: { flow.enterSettings() })
            case .conversionResults:
                ConversionResultsView(results: flow.conversionResults, back: { flow.enterSettings() })
            case .screenshotEditor(let image):
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button("‹  返回功能设置") { flow.enterSettings() }.buttonStyle(.borderless)
                        Spacer(); MORIQThemeToggle()
                    }.padding(.horizontal, 24).padding(.top, 20)
                    ScreenshotEditorContainer(image: image, pasteboard: screenshotPasteboard)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .connection:
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Button("‹  返回功能设置") { flow.enterSettings() }.buttonStyle(.borderless); Spacer(); MORIQThemeToggle() }.padding(.horizontal, 24).padding(.top, 20)
                    DeepSeekSettingsView()
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 650, minHeight: 560)
        .preferredColorScheme(dark ? .dark : .light)
        .onAppear { applyMORIQAppearance(dark) }
        .onChange(of: dark) { _, value in applyMORIQAppearance(value) }
    }
}
struct ScreenshotEditorContainer: View {
    let image: CGImage
    let pasteboard: NSPasteboard
    var body: some View {
        // Each capture must have its own preview and annotation state.
        ScreenshotResultView(image: image, pasteboard: pasteboard).id(ObjectIdentifier(image))
    }
}
#if DEBUG
struct ScreenshotReplacementFixture: View {
    let images: [CGImage]
    let pasteboard: NSPasteboard
    @State private var index = 0
    var body: some View {
        VStack {
            Button("切换测试截图") { index = 1 - index }
            ScreenshotEditorContainer(image: images[index], pasteboard: pasteboard)
        }.frame(width: 800, height: 700)
    }
}
#endif
@MainActor private func applyMORIQAppearance(_ dark: Bool) {
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
}
struct ConversionResultsView: View {
    let results: [ConversionRecord]
    let back: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Button("‹  返回功能设置", action: back).buttonStyle(.borderless); Spacer(); MORIQThemeToggle() }
            Text("转换记录").font(.system(size: 20, weight: .semibold))
            if results.isEmpty { Spacer(); Text("还没有转换记录").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer() }
            else {
                List(results) { result in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.source.lastPathComponent).lineLimit(1)
                            Text(result.output.map { "\(result.message) · \($0.lastPathComponent)" } ?? result.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let output = result.output { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.controlSize(.small) }
                    }.padding(.vertical, 4)
                }
            }
        }.padding(24)
    }
}
struct MORIQThemeToggle: View {
    @AppStorage("moriq.permissionDarkMode") private var dark = false
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { dark.toggle() } } label: {
            Label(dark ? "浅色" : "深色", systemImage: dark ? "sun.max" : "moon")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.buttonStyle(.plain).accessibilityLabel(dark ? "切换浅色模式" : "切换深色模式")
    }
}
struct MORIQMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image("BrandMark").resizable().scaledToFit()
            .colorInvertIfDark(colorScheme == .dark)
    }
}
private extension View {
    @ViewBuilder func colorInvertIfDark(_ dark: Bool) -> some View {
        if dark { self.colorInvert().hueRotation(.degrees(180)) } else { self }
    }
}
struct FeatureIntroduction: View {
    @State private var index = 0
    @State private var forward = true
    @StateObject private var state = DemoState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let finish: () -> Void
    private var feature: Feature { Feature.allCases[index] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                MORIQMark().frame(width: 28, height: 28).accessibilityHidden(true)
                Text("MORIQ").font(.system(size: 15, weight: .bold)).tracking(1)
                Spacer()
                MORIQThemeToggle().padding(.trailing, 16)
                Text("\(index + 1) / \(Feature.allCases.count)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.bottom, 20)
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(feature.title).font(.system(size: 23, weight: .semibold))
                    Text(feature.detail).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 5)
                    DemoView(feature: feature, state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
                        .padding(.vertical, 20)
                }
                .id(index)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity),
                    removal: .offset(x: forward ? -24 : 24).combined(with: .opacity)))
            }.clipped()
            HStack {
                HStack(spacing: 6) { ForEach(0..<Feature.allCases.count) { i in Capsule().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.2)).frame(width: i == index ? 18 : 6, height: 6) } }
                Spacer()
                HStack(spacing: 9) {
                    if index > 0 {
                        Button { forward = false; withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.26)) { index -= 1 }; state.replay(reduceMotion: reduceMotion) } label: {
                            Image(systemName: "arrow.left").font(.system(size: 14, weight: .semibold)).frame(width: 38, height: 38).contentShape(Circle())
                        }.buttonStyle(.plain).foregroundStyle(.primary).background(.primary.opacity(0.055), in: Circle()).accessibilityLabel("上一个功能")
                    }
                    Button {
                        if index == Feature.allCases.count - 1 { state.stop(); finish() }
                        else { forward = true; withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.26)) { index += 1 }; state.replay(reduceMotion: reduceMotion) }
                    } label: {
                        Image(systemName: index == Feature.allCases.count - 1 ? "arrow.up.right" : "arrow.right").font(.system(size: 14, weight: .semibold)).frame(width: 38, height: 38).contentShape(Circle())
                    }.buttonStyle(.plain).foregroundStyle(.white).background(Color.accentColor, in: Circle())
                        .accessibilityLabel(index == Feature.allCases.count - 1 ? "进入权限设置" : "下一个功能").keyboardShortcut(.defaultAction)
                }
            }
        }.padding(26)
            .onAppear { state.replay(reduceMotion: reduceMotion) }
            .onDisappear { state.stop() }
    }
}
struct InlineDemo: View {
    let feature: Feature
    let back: () -> Void
    @StateObject private var state = DemoState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Button("‹  返回功能设置", action: back).buttonStyle(.borderless); Spacer(); Text(feature.title).font(.headline); Spacer(); MORIQThemeToggle() }
            DemoView(feature: feature, state: state).clipShape(RoundedRectangle(cornerRadius: 14))
        }.padding(24).onAppear { state.replay(reduceMotion: reduceMotion) }.onDisappear { state.stop() }
    }
}
