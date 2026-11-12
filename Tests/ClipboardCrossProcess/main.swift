import AppKit
import Foundation
let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "local.moriq.cross-process.\(UUID().uuidString)"
let board = NSPasteboard(name: NSPasteboard.Name(name))
let values: [(NSPasteboard.PasteboardType, Data)] = [
    (.string, Data("模拟多格式文本 • 密钥 sk-abcdefghijklmnopqr".utf8)),
    (.html, Data("<b>模拟多格式文本</b><a href='https://example.invalid'>链接</a>".utf8)),
    (.rtf, Data(#"{\rtf1\ansi \b test\b0}"#.utf8)),
    (NSPasteboard.PasteboardType("public.url"), Data("https://example.invalid/".utf8)),
    (NSPasteboard.PasteboardType("local.moriq.fixture-custom"), Data([7, 8, 9])),
    (NSPasteboard.PasteboardType("public.svg-image"), Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8)),
    (NSPasteboard.PasteboardType("com.apple.webarchive"), Data([0, 1, 2, 255]))
]
if CommandLine.arguments.count > 1 {
    if CommandLine.arguments[1] == "write" {
        let item = NSPasteboardItem()
        for (type, data) in values { precondition(item.setData(data, forType: type)) }
        board.clearContents(); precondition(board.writeObjects([item]))
    } else {
        let item = board.pasteboardItems!.first!
        for (type, data) in values { precondition(item.data(forType: type) == data, "lost \(type.rawValue)") }
        precondition(board.string(forType: .string) == String(data: values[0].1, encoding: .utf8))
    }
} else {
    defer { board.releaseGlobally() }
    func run(_ mode: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = [mode, name]
        try! process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
    }
    MainActor.assumeIsolated {
        let store = ClipboardStore(board: board, persistent: false)
        run("write"); store.poll(); store.waitForCaptures()
        precondition(store.items.count == 1)
        let entry = store.items[0]
        for (type, data) in values { precondition(entry.items[0][type.rawValue] == data, "capture lost \(type.rawValue)") }
        board.clearContents(); precondition(store.copy(entry)); run("read")
    }
    print("PASS cross-process multi-representation roundtrip")
}
