import Foundation
import CryptoKit
@main struct Test {
 static func main() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("moriq-model-test-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
    let server = Process(), pipe = Pipe(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["Tests/LocalWhisperModel/server.py"]; server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run(); defer { server.terminate(); server.waitUntilExit() }
    var portData = Data(); while !portData.contains(10) { portData.append(pipe.fileHandleForReading.readData(ofLength: 1)) }
    let port = String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let source = URL(string: "http://127.0.0.1:\(port)/valid")!
    let bytes = Data(repeating: 97, count: 1024 * 1024)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let good = root.appendingPathComponent("good")
    let downloaded = try await LocalWhisperModel.prepareTest(root: good, source: source, size: UInt64(bytes.count), hash: digest, progress: { _ in })
    let data = try Data(contentsOf: downloaded); precondition(data == bytes)
    try Data("damaged".utf8).write(to: downloaded)
    let repaired = try await LocalWhisperModel.prepareTest(root: good, source: source, size: UInt64(bytes.count), hash: digest, progress: { _ in })
    let repairedData = try Data(contentsOf: repaired); precondition(repairedData == bytes)
    let bad = root.appendingPathComponent("bad")
    do { _ = try await LocalWhisperModel.prepareTest(root: bad, source: URL(string: "http://127.0.0.1:\(port)/bad")!, size: UInt64(bytes.count), hash: digest, progress: { _ in }); fatalError("bad hash accepted") } catch {}
    let afterBad = try fm.contentsOfDirectory(atPath: bad.path); precondition(afterBad.isEmpty)
    let retry = try await LocalWhisperModel.prepareTest(root: bad, source: source, size: UInt64(bytes.count), hash: digest, progress: { _ in }); precondition(fm.fileExists(atPath: retry.path))
    let cancelledRoot = root.appendingPathComponent("cancelled")
    let task = Task { try await LocalWhisperModel.prepareTest(root: cancelledRoot, source: URL(string: "http://127.0.0.1:\(port)/slow")!, size: UInt64(bytes.count), hash: digest, progress: { _ in }) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    do { _ = try await task.value; fatalError("cancelled download accepted") } catch {}
    let contents = try fm.contentsOfDirectory(atPath: cancelledRoot.path); precondition(contents.isEmpty)
    print("PASS model download, hash rejection, retry and cancellation cleanup")
 }
}
