import AppKit
import Foundation
let name = "local.moriq.shutdown.\(UUID().uuidString)"
let board = NSPasteboard(name: NSPasteboard.Name(name)); defer { board.releaseGlobally() }
let type = NSPasteboard.PasteboardType("local.moriq.in-process")
final class Provider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(Data("in-process payload".utf8), forType: type)
    }
}
MainActor.assumeIsolated {
    let provider = Provider()
    let store = ClipboardStore(board: board, persistent: false)
    store.start()
    let item = NSPasteboardItem(); item.setDataProvider(provider, forTypes: [type])
    board.clearContents(); precondition(board.writeObjects([item]))
    var result: Bool?; store.prepareShutdown(timeout: 3) { result = $0 }
    let deadline = Date().addingTimeInterval(4)
    while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(result == true, "in-process promise shutdown failed or timed out")
    precondition(store.items.first?.items.first?[type.rawValue] == Data("in-process payload".utf8))
    withExtendedLifetime(provider) {}
    print("PASS shutdown drains in-process promised data without blocking main run loop")
}
