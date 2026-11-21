import AppKit
import SwiftUI

struct IslandConversionResults: View {
    @ObservedObject var flow: AppFlow
    @State private var unavailableOutputs: Set<URL> = []

    var body: some View {
        if flow.conversionResults.isEmpty {
            Text("暂无转换记录").foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(flow.conversionResults.prefix(20)) { record in
                        if let output = record.output {
                            outputRow(output)
                        } else {
                            Label(record.source.lastPathComponent, systemImage: "exclamationmark.circle")
                                .lineLimit(1).foregroundStyle(.secondary).help(record.message)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.task(id: flow.conversionResults.prefix(20).compactMap(\.output)) {
                let outputs = flow.conversionResults.prefix(20).compactMap(\.output)
                while !Task.isCancelled {
                    unavailableOutputs = Set(outputs.filter { !FileManager.default.fileExists(atPath: $0.path) })
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    @ViewBuilder private func outputRow(_ output: URL) -> some View {
        if unavailableOutputs.contains(output) || !FileManager.default.fileExists(atPath: output.path) {
            Label("\(output.lastPathComponent) · 文件不可用", systemImage: "questionmark.folder")
                .lineLimit(1).foregroundStyle(.secondary)
        } else {
            Button {
                guard FileManager.default.fileExists(atPath: output.path) else {
                    unavailableOutputs.insert(output)
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } label: {
                Label(output.lastPathComponent, systemImage: "doc").lineLimit(1)
            }.buttonStyle(.plain).help("在访达中显示")
        }
    }
}

struct IslandLiveCaptions: View {
    @ObservedObject var coordinator: LiveCaptionsCoordinator

    var body: some View {
        if let state = coordinator.state {
            IslandCaptionText(state: state).id(ObjectIdentifier(state))
        } else {
            Text("字幕未运行").foregroundStyle(.secondary)
        }
    }
}

private struct IslandCaptionText: View {
    @ObservedObject var state: LiveCaptionState
    @State private var revealed = false

    var body: some View {
        let original = text(translated: false)
        let translation = text(translated: true)
        let mode = CaptionWindowSizing.effectiveMode(mode: state.mode, sameLanguage: CaptionLanguagePair.isSame(state.sourceLanguage, state.targetLanguage))
        VStack(alignment: .leading, spacing: 10) {
            Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if revealed {
                if mode != "zh", !original.isEmpty {
                    Text(String(original.suffix(340))).lineLimit(3)
                }
                if mode != "original", !translation.isEmpty {
                    Text(String(translation.suffix(240))).lineLimit(3)
                }
            } else {
                Button("查看字幕") { revealed = true }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(translated: Bool) -> String {
        #if MORIQ_NATIVE_TRANSLATION_PRODUCT || (DEBUG && MORIQ_NATIVE_TRANSLATION_EXPERIMENTAL)
        if state.nativePresentationSelected {
            return state.nativeDisplayText(translated ? .translation : .original)
        }
        #endif
        return translated ? state.translated : state.original
    }
}

struct IslandScreenshotResult: View {
    @ObservedObject var coordinator: ScreenshotInlineCoordinator
    @ObservedObject var flow: AppFlow

    var body: some View {
        if case .screenshotEditor(let source) = flow.page {
            IslandScreenshotImage(preview: flow.screenshotPreview).id(ObjectIdentifier(source))
        } else if let session = coordinator.activeSession {
            IslandScreenshotPreview(session: session).id(ObjectIdentifier(session))
        } else {
            Text("暂无截图").foregroundStyle(.secondary)
        }
    }
}

private struct IslandScreenshotPreview: View {
    @ObservedObject var session: ScreenshotEditSession
    var body: some View { IslandScreenshotImage(preview: session.currentAnnotatedPreview) }
}

private struct IslandScreenshotImage: View {
    let preview: CGImage?
    @State private var revealed = false

    var body: some View {
        if !revealed {
            Button("查看截图") { revealed = true }
        } else if let preview {
            Image(decorative: preview, scale: 1)
                .resizable().scaledToFit().accessibilityLabel("当前截图")
        } else {
            Text("正在更新截图…").foregroundStyle(.secondary)
        }
    }
}

struct IslandAssistantResult: View {
    @ObservedObject var model: AssistantModel
    @State private var revealedReplyID: UUID?

    var body: some View {
        if model.working {
            Text("回答中…").foregroundStyle(.secondary)
        } else if model.error != nil {
            Text("回答未完成").foregroundStyle(.secondary)
        } else if let reply = model.messages.last, reply.role == "assistant", !reply.content.isEmpty {
            if revealedReplyID == reply.id {
                ScrollView {
                    Text(reply.content).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button("查看回答") { revealedReplyID = reply.id }
            }
        } else {
            Text("暂无回答").foregroundStyle(.secondary)
        }
    }
}
