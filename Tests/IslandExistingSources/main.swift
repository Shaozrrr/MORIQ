import AppKit
import Combine
import Foundation
struct ShelfEntry { let name: String; let available: Bool }
@MainActor final class ShelfStore: ObservableObject { @Published var items: [ShelfEntry] = [] }
struct StickyNote { let text: String }
@MainActor final class StickyNoteStore: ObservableObject { @Published var notes: [StickyNote] = [] }
struct ClipboardEntry { let summary: String }
@MainActor final class ClipboardStore: ObservableObject { @Published var items: [ClipboardEntry] = [] }
struct ConversionRecord { let output: URL? }
@MainActor final class AppFlow: ObservableObject { @Published var conversionResults: [ConversionRecord] = [] }
@MainActor final class LiveCaptionState: ObservableObject { @Published var status = "准备中"; @Published var isCapturing = false }
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let suite = "local.moriq.island.sources.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = IslandPreviewContent(defaults: defaults)
    model.setEnabled(.conversion, true); model.setEnabled(.captions, true)
    let bridge = IslandPreviewAdapters(model: model)
    let shelf = ShelfStore(), notes = StickyNoteStore(), clipboard = ClipboardStore()
    let flow = AppFlow(), captions = LiveCaptionState()
    bridge.connectShelf(shelf); bridge.connectNotes(notes); bridge.connectClipboard(clipboard)
    bridge.connectConversions(flow); bridge.connectCaptions(captions)
    shelf.items = [ShelfEntry(name:"fixture.pdf",available:true), ShelfEntry(name:"missing.png",available:false)]
    notes.notes = [StickyNote(text:"private fixture")]; clipboard.items = [ClipboardEntry(summary:"private clipboard")]
    flow.conversionResults = [ConversionRecord(output:URL(fileURLWithPath:"/tmp/output.png")), ConversionRecord(output:nil)]
    captions.isCapturing = true; captions.status = "语音服务未能连接"
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(model.contents[.shelf] == ["fixture.pdf", "missing.png · 不可用"])
    precondition(model.hidden.contains(.notes) && model.hidden.contains(.clipboard))
    precondition(model.contents[.notes] == nil && model.contents[.clipboard] == nil)
    precondition(model.contents[.conversion] == ["output.png", "失败"])
    precondition(model.states[.captions] == .failed)
    bridge.connectNotes(notes, reveal:true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(model.contents[.notes] == ["private fixture"] && !model.hidden.contains(.notes))
    model.setEnabled(.notes, false); notes.notes = [StickyNote(text:"new value")]
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(model.contents[.notes] == nil && notes.notes.count == 1)
    bridge.stop()
    print("Existing-source adapter fixture mapping, privacy, failure and cancellation passed")
}
