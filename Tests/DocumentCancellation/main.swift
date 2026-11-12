import Foundation
import Darwin
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-doc-cancel-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("source.bin")
fm.createFile(atPath: source.path, contents: Data("SOURCE 4812".utf8))
let normal = try ArchiveConverter().tar(input: source, outputDirectory: root, gzip: true)
precondition(fm.fileExists(atPath: normal.path)); try fm.removeItem(at: normal)
precondition(try! Data(contentsOf: source) == Data("SOURCE 4812".utf8))
let large = root.appendingPathComponent("large.bin")
fm.createFile(atPath: large.path, contents: nil)
let handle = try FileHandle(forWritingTo: large)
let random = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
let block = try random.read(upToCount: 1024 * 1024)!
try random.close()
for _ in 0..<128 { try handle.write(contentsOf: block) }
try handle.close()
let worker = Task.detached { try ArchiveConverter().tar(input: large, outputDirectory: root, gzip: true) }
func childTarPID() -> pid_t? {
 let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,ppid=,comm="]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
  let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
  if words.count >= 3, words[1] == "\(getpid())", words[2].hasSuffix("tar"), let pid = Int32(words[0]) { return pid }
 }
 return nil
}
let deadline = Date().addingTimeInterval(10)
var tarPID: pid_t?
while Date() < deadline {
 if (try fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".moriq-") }), let pid = childTarPID() { tarPID = pid; break }
 Thread.sleep(forTimeInterval: 0.01)
}
precondition(tarPID != nil, "tar process not observed")
worker.cancel()
let done = DispatchSemaphore(value: 0)
let result = Task.detached { () -> Bool in
 defer { done.signal() }
 do { _ = try await worker.value; return false } catch { return true }
}
precondition(done.wait(timeout: .now() + 10) == .success, "cancelled subprocess did not stop")
let finish = DispatchSemaphore(value: 0)
Task.detached { let cancelled = await result.value; precondition(cancelled, "published after cancellation"); finish.signal() }
precondition(finish.wait(timeout: .now() + 2) == .success)
precondition(kill(tarPID!, 0) == -1 && errno == ESRCH, "tar process still running")
let remaining = try fm.contentsOfDirectory(atPath: root.path)
precondition(!remaining.contains(where: { $0.hasPrefix(".moriq-") || $0.hasPrefix("large.tar") }), "temporary or result remains")
let sourceSize = try fm.attributesOfItem(atPath: large.path)[.size] as! NSNumber
precondition(sourceSize.intValue == 128 * 1024 * 1024)
let html = root.appendingPathComponent("document.html")
let htmlData = Data(("<html><body>" + String(repeating: "<p>Test paragraph 4812</p>", count: 30000) + "</body></html>").utf8)
try htmlData.write(to: html)
let document = Task.detached { try DocumentConverter().convert(input: html, outputDirectory: root, format: .pdf) }
let documentDeadline = Date().addingTimeInterval(10)
while Date() < documentDeadline {
 if (try fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".moriq-") }) { break }
 Thread.sleep(forTimeInterval: 0.01)
}
document.cancel()
let documentDone = DispatchSemaphore(value: 0)
Task.detached {
 defer { documentDone.signal() }
 do { _ = try await document.value; preconditionFailure("document published after cancellation") } catch { }
}
precondition(documentDone.wait(timeout: .now() + 10) == .success, "document process failed to stop")
let documentFiles = try fm.contentsOfDirectory(atPath: root.path)
precondition(!documentFiles.contains(where: { $0.hasPrefix(".moriq-") || $0 == "document.pdf" }))
precondition(try! Data(contentsOf: html) == htmlData)
let marker = root.appendingPathComponent("ready")
let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/sh")
shell.arguments = ["-c", "trap '' TERM; printf ready > \"$1\"; while :; do printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n'; done", "moriq-test", marker.path]
let diagnostics = Pipe(); shell.standardError = diagnostics; shell.standardOutput = FileHandle.nullDevice
// Write diagnostics to stderr so pipe-draining is exercised under pressure.
shell.arguments![1] += " 1>&2"
let resistant = Task.detached { try shell.run(); return try testWaitDocumentProcess(shell, pipe: diagnostics) }
let shellDeadline = Date().addingTimeInterval(5)
while Date() < shellDeadline && !fm.fileExists(atPath: marker.path) { Thread.sleep(forTimeInterval: 0.01) }
precondition(fm.fileExists(atPath: marker.path), "resistant child did not start")
let shellPID = shell.processIdentifier
resistant.cancel()
let shellDone = DispatchSemaphore(value: 0)
Task.detached { defer { shellDone.signal() }; do { _ = try await resistant.value; preconditionFailure("expected cancellation") } catch { } }
precondition(shellDone.wait(timeout: .now() + 8) == .success, "resistant child or diagnostics pipe deadlocked")
precondition(kill(shellPID, 0) == -1 && errno == ESRCH, "resistant child still alive")
print("PASS tar PID and TERM-resistant PID terminated; diagnostics drained; cancellation leaves no outputs")
