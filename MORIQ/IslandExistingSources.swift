import Combine
import Foundation

/// These adapters observe only explicitly supplied stores; they never start a feature.
extension IslandPreviewAdapters {
    func connectShelf(_ store: ShelfStore) {
        connect(.shelf, publisher: store.$items.map { items in
            guard !items.isEmpty else { return .empty }
            return .ready(items.prefix(5).map { $0.available ? $0.name : "\($0.name) · 不可用" })
        }.eraseToAnyPublisher())
    }
    func connectNotes(_ store: StickyNoteStore, reveal: Bool = false) {
        connect(.notes, publisher: store.$notes.map { notes in
            guard !notes.isEmpty else { return .empty }
            guard reveal else { return .redacted }
            return .ready(notes.prefix(5).map { $0.text.isEmpty ? "空便签" : $0.text })
        }.eraseToAnyPublisher())
    }
    func connectClipboard(_ store: ClipboardStore, reveal: Bool = false) {
        connect(.clipboard, publisher: store.$items.map { entries in
            guard !entries.isEmpty else { return .empty }
            guard reveal else { return .redacted }
            return .ready(entries.prefix(5).map(\.summary))
        }.eraseToAnyPublisher())
    }
    func connectConversions(_ flow: AppFlow) {
        connect(.conversion, publisher: flow.$conversionResults.map { records in
            guard !records.isEmpty else { return .empty }
            return .ready(records.prefix(5).map { $0.output?.lastPathComponent ?? "失败" })
        }.eraseToAnyPublisher())
    }
    func connectCaptions(_ state: LiveCaptionState) {
        connect(.captions, publisher: Publishers.CombineLatest(state.$status, state.$isCapturing).map { status, capturing in
            if ["失败", "无法", "断开", "未能"].contains(where: status.contains) { return .failed }
            return capturing ? .ready(["运行中"]) : .unavailable
        }.eraseToAnyPublisher())
    }
}
