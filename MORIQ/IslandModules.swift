import Foundation

enum IslandModule: String, Codable, CaseIterable, Identifiable {
    case bento, calendar, system, control, toolkit, aiDev, focus, music, clipboard, shelf, notes, conversion, captions, screenshot, assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bento: "总览"
        case .calendar: "日程"
        case .system: "算力"
        case .control: "控制"
        case .toolkit: "效率"
        case .aiDev: "AI开发"
        case .focus: "专注"
        case .music: "音乐"
        case .clipboard: "剪贴板"
        case .shelf: "暂存"
        case .notes: "便签"
        case .conversion: "转换"
        case .captions: "字幕"
        case .screenshot: "截图"
        case .assistant: "助手"
        }
    }

    var islandSymbolName: String {
        switch self {
        case .bento: "square.grid.2x2"
        case .calendar: "calendar"
        case .system: "cpu"
        case .control: "slider.horizontal.3"
        case .toolkit: "rectangle.split.2x1"
        case .aiDev: "chevron.left.forwardslash.chevron.right"
        case .focus: "timer"
        case .music: "music.note"
        case .clipboard: "list.clipboard"
        case .shelf: "tray"
        case .notes: "note.text"
        case .conversion: "arrow.left.arrow.right"
        case .captions: "captions.bubble"
        case .screenshot: "viewfinder"
        case .assistant: "sparkle"
        }
    }
}

/// Only module choices are persisted; content stays owned by the existing features.
struct IslandModuleSelection: Equatable {
    private(set) var enabled: [IslandModule]
    private(set) var selected: IslandModule?

    init(enabled: [IslandModule], selected: IslandModule? = nil) {
        var seen = Set<IslandModule>()
        self.enabled = enabled.filter { seen.insert($0).inserted }
        self.selected = selected.flatMap { self.enabled.contains($0) ? $0 : nil } ?? self.enabled.first
    }
    mutating func setEnabled(_ module: IslandModule, _ value: Bool) {
        if value {
            if !enabled.contains(module) { enabled.append(module) }
            if selected == nil { selected = module }
        } else {
            guard let index = enabled.firstIndex(of: module) else { return }
            enabled.remove(at: index)
            if selected == module { selected = enabled.indices.contains(index) ? enabled[index] : enabled.last }
        }
    }
    mutating func select(_ module: IslandModule) {
        guard enabled.contains(module) else { return }; selected = module
    }
    mutating func move(_ module: IslandModule, to destination: Int) {
        guard let index = enabled.firstIndex(of: module), destination >= 0, destination < enabled.count else { return }
        enabled.remove(at: index); enabled.insert(module, at: destination)
    }
    var encoded: Data? {
        try? JSONEncoder().encode(Persisted(enabled: enabled.map(\.rawValue), selected: selected?.rawValue))
    }
    static func decode(_ data: Data, fallback: IslandModuleSelection) -> IslandModuleSelection {
        guard let saved = try? JSONDecoder().decode(Persisted.self, from: data) else { return fallback }
        return IslandModuleSelection(enabled: saved.enabled.compactMap(IslandModule.init(rawValue:)), selected: saved.selected.flatMap(IslandModule.init(rawValue:)))
    }
    private struct Persisted: Codable { let enabled: [String]; let selected: String? }
}

enum IslandContentState: Equatable {
    case unavailable, empty, redacted, ready, failed
}
