import AppKit
import Foundation
let arguments = CommandLine.arguments
let name = arguments.count > 2 ? arguments[2] : "local.moriq.provider.\(UUID().uuidString)"
let board = NSPasteboard(name: NSPasteboard.Name(name))
let type = NSPasteboard.PasteboardType("local.moriq.lazy-fixture")
final class Provider: NSObject, NSPasteboardItemDataProvider {
    let size: Int
    init(_ size: Int) { self.size = size }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: 0.3)
        item.setData(Data(repeating: 0x63, count: size), forType: type)
    }
}
if arguments.count > 1 {
    let provider = Provider(Int(arguments[3])!)
    let item = NSPasteboardItem(); item.setDataProvider(provider, forTypes: [type])
    board.clearContents(); precondition(board.writeObjects([item]))
    print("READY"); fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(8))
    withExtendedLifetime(provider) {}
} else {
    defer { board.releaseGlobally() }
    MainActor.assumeIsolated {
        let store = ClipboardStore(board: board, persistent: false)
        @MainActor func run(_ size: Int) {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: arguments[0]); process.arguments = ["provider", name, String(size)]
            process.standardOutput = pipe; try! process.run()
            var ready = Data()
            while !ready.contains(10) { ready.append(pipe.fileHandleForReading.readData(ofLength: 1)) }
            let before = Date(); store.poll(); let elapsed = Date().timeIntervalSince(before)
            precondition(elapsed < 0.15, "poll blocked on the provider")
            store.waitForCaptures()
            if size > 8_000_000 {
                precondition(store.captureWarning?.contains("8 MB") == true)
                print("PASS oversized deferred provider rejected, elapsed \(elapsed)")
            } else {
                precondition(store.items.first?.items.first?[type.rawValue] == Data(repeating: 0x63, count: size))
                precondition(store.copy(store.items[0])); precondition(board.data(forType: type) == Data(repeating: 0x63, count: size))
                print("PASS deferred provider copied exactly, elapsed \(elapsed)")
            }
            process.terminate(); process.waitUntilExit()
        }
        run(3); run(8_000_001)
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: arguments[0]); process.arguments = ["provider", name, "3"]
        process.standardOutput = pipe; try! process.run()
        var ready = Data(); while !ready.contains(10) { ready.append(pipe.fileHandleForReading.readData(ofLength: 1)) }
        store.poll(); Thread.sleep(forTimeInterval: 0.05)
        board.clearContents(); board.setString("latest copy", forType: .string); store.poll()
        store.waitForCaptures()
        precondition(store.captureWarning?.contains("变化") == true)
        precondition(store.items.first?.text == "latest copy")
        process.terminate(); process.waitUntilExit()
        print("PASS clipboard change warns and latest captured in order")
        for action in ["clear", "stop", "shutdown"] {
            let pending = Process(); let output = Pipe()
            pending.executableURL = URL(fileURLWithPath: arguments[0]); pending.arguments = ["provider", name, "3"]
            pending.standardOutput = output; try! pending.run()
            var ready = Data(); while !ready.contains(10) { ready.append(output.fileHandleForReading.readData(ofLength: 1)) }
            store.poll(); Thread.sleep(forTimeInterval: 0.05)
            if action == "clear" { store.clearHistory() } else if action == "stop" { store.stop() } else { store.shutdown() }
            let count = store.items.count; store.waitForCaptures()
            precondition(store.items.count == count, "stale capture after \(action)")
            pending.terminate(); pending.waitUntilExit()
        }
        print("PASS clear, stop and shutdown discard stale captures")
        let slow = Process(); let out = Pipe()
        slow.executableURL = URL(fileURLWithPath: arguments[0]); slow.arguments = ["provider", name, "3"]
        slow.standardOutput = out; try! slow.run()
        var slowReady = Data(); while !slowReady.contains(10) { slowReady.append(out.fileHandleForReading.readData(ofLength: 1)) }
        store.start(); store.poll(force: true)
        var exitResult: Bool?
        store.prepareShutdown(timeout: 0.05) { exitResult = $0 }
        let deadline = Date().addingTimeInterval(2)
        while exitResult == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(exitResult == false && store.captureWarning?.contains("超时") == true)
        store.waitForCaptures(); slow.terminate(); slow.waitUntilExit(); store.stop()
        print("PASS slow provider cancels quit on timeout with warning")
    }
}
