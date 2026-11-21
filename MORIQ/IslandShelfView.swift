import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reuses the existing shelf; adding a file stores a reference and never moves it.
@MainActor enum IslandShelfDrop {
    @discardableResult static func accept(
        _ providers: [NSItemProvider], into store: ShelfStore,
        completion: @escaping @MainActor (_ added: Int, _ failed: Int) -> Void = { _, _ in }
    ) -> Bool {
        let supported = providers.filter { ShelfDropDecoder.canLoad($0) }
        guard !supported.isEmpty else { return false }
        let unsupported = providers.count - supported.count
        let batch = OrderedDropBatch(count: supported.count) { [weak store] urls, failed in
            Task { @MainActor in
                guard let store else { return }
                let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                let count = store.items.count
                store.add(valid)
                completion(store.items.count - count, failed + unsupported + urls.count - valid.count)
            }
        }
        for (index, provider) in supported.enumerated() {
            ShelfDropDecoder.load(provider) { batch.submit($0, at: index) }
        }
        return true
    }
}

struct IslandShelfView: View {
    @ObservedObject var store: ShelfStore
    @State private var targeted = false
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件暂存").font(.headline)
                Spacer()
            }
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 20)).foregroundStyle(.secondary)
                    Text(targeted ? "松开添加文件" : "拖入文件")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.items) { entry in
                            HStack(spacing: 9) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                                    .resizable().frame(width: 24, height: 24)
                                Button {
                                    guard entry.available, NSWorkspace.shared.open(entry.url) else {
                                        openError = "无法打开文件，请检查文件是否仍在原处。"; return
                                    }
                                    openError = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).lineLimit(1)
                                        if !entry.available { Text("文件不可用").font(.caption2).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("打开文件")
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 6)
                            .onDrag { entry.available ? NSItemProvider(object: entry.url as NSURL) : NSItemProvider() }
                        }
                    }
                }
            }
            if let openError { Text(openError).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .overlay { if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 1).allowsHitTesting(false) } }
        .task { await store.refreshMovedFiles() }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            openError = nil
            return IslandShelfDrop.accept(providers, into: store) { added, failed in
                if failed > 0 { openError = "有 \(failed) 个文件未能添加。" }
                else if added == 0 { openError = "所选文件已在暂存架中。" }
            }
        }
    }
}
