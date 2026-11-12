import AppKit
import Foundation
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--read-isolated-pasteboard" {
    let board = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[2]))
    let urls = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let expected = [directory.appendingPathComponent("一.txt"), directory.appendingPathComponent("二.txt")]
    guard urls.map(\.standardizedFileURL) == expected.map(\.standardizedFileURL),
          (try? String(contentsOf: urls[0], encoding: .utf8)) == "one",
          (try? String(contentsOf: urls[1], encoding: .utf8)) == "two" else { exit(1) }
    print("PASS separate process read both file URLs and contents")
    exit(0)
}
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent("moriq-shelf-transfer-\(UUID().uuidString)")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
let one = dir.appendingPathComponent("一.txt"), two = dir.appendingPathComponent("二.txt")
try Data("one".utf8).write(to: one); try Data("two".utf8).write(to: two)
let items = [ShelfEntry(id: UUID(), url: one), ShelfEntry(id: UUID(), url: two)]
let boardName = "local.moriq.shelf-test.\(UUID().uuidString)"
let board = NSPasteboard(name: NSPasteboard.Name(boardName))
defer { board.releaseGlobally() }
precondition(ShelfTransfer.copy(items, to: board) == .copied)
let urls = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
precondition(urls.map(\.standardizedFileURL) == [one, two].map(\.standardizedFileURL))
let reader = Process()
reader.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
reader.arguments = ["--read-isolated-pasteboard", boardName, dir.path]
try reader.run()
reader.waitUntilExit()
precondition(reader.terminationStatus == 0)
try fm.removeItem(at: two)
let before = board.changeCount
precondition(ShelfTransfer.copy(items, to: board) == .unavailable)
precondition(board.changeCount == before)
precondition(fm.fileExists(atPath: one.path))
print("PASS multiple file URLs copied; missing item blocks partial copy and preserves pasteboard")
