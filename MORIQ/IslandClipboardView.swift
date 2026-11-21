import SwiftUI

/// Displays the existing history only while the user is viewing this module.
/// The parent supplies availability; this view never starts clipboard capture.
struct IslandClipboardView: View {
    @ObservedObject var store: ClipboardStore
    let enabled: Bool
    @State private var copiedID: UUID?
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("剪贴板", systemImage: "doc.on.clipboard").font(.headline)
                Spacer()
            }
            if !enabled {
                Text("请先开启剪贴板功能。") .font(.callout).foregroundStyle(.secondary)
            } else if store.recovering && store.items.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取记录…") }
                    .font(.callout).foregroundStyle(.secondary)
            } else if store.persistenceLocked && store.items.isEmpty {
                Text("历史记录暂时无法读取。") .font(.callout).foregroundStyle(.secondary)
            } else if store.items.isEmpty {
                Text("还没有复制记录。") .font(.callout).foregroundStyle(.secondary)
            } else if !revealed {
                Button("查看剪贴板记录") { revealed = true }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.items.prefix(20))) { entry in
                            Button {
                                copiedID = store.copy(entry, plain: false) ? entry.id : nil
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: symbol(entry)).frame(width: 18).foregroundStyle(.secondary)
                                    Text(entry.summary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if copiedID == entry.id { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                }.padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("复制这条记录")
                        }
                    }
                }.frame(maxHeight: 145)
                if store.persistenceLocked { Text("部分历史记录暂时无法读取。") .font(.caption).foregroundStyle(.secondary) }
            }
            if let error = store.copyError, enabled { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .onChange(of: enabled) { _, value in if !value { resetDisclosure() } }
        .onDisappear { resetDisclosure() }
    }
    private func resetDisclosure() { revealed = false; copiedID = nil }

    private func symbol(_ entry: ClipboardEntry) -> String {
        if !entry.fileNames.isEmpty { return "doc" }
        if entry.imageData != nil { return "photo" }
        return "text.alignleft"
    }
}
