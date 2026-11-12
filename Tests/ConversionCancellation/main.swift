import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin
@main struct Test {
 static func main() async {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("moriq-queue-cancel-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
    guard let engine = ExternalMediaConverter.executable else { fatalError("no ffmpeg") }
    let first = root.appendingPathComponent("first.mka"), second = root.appendingPathComponent("second.mka"), third = root.appendingPathComponent("third.mka")
    let generator = Process(); generator.executableURL = engine
    generator.arguments = ["-nostdin","-v","error","-f","lavfi","-i","sine=frequency=440","-t","0.2","-c:a","pcm_s16le",first.path]
    generator.standardError = FileHandle.nullDevice; try! generator.run(); generator.waitUntilExit(); precondition(generator.terminationStatus == 0)
    try! fm.copyItem(at: first, to: second); try! fm.copyItem(at: first, to: third)
    let wrapper = root.appendingPathComponent("ffmpeg-test"), escaped = engine.path.replacingOccurrences(of: "'", with: "'\\''")
    try! Data("#!/bin/sh\nsleep 1\nexec '\(escaped)' \"$@\"\n".utf8).write(to: wrapper)
    try! fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path); setenv("MORIQ_TEST_FFMPEG", wrapper.path, 1)
    let state = await MainActor.run { State() }
    await MainActor.run { state.coordinator.onResults = { state.reports.append($0) }; state.coordinator.enqueueConversion([first], to: UTType(filenameExtension:"m4a")!) }
    try? await Task.sleep(for: .milliseconds(200))
    await MainActor.run { state.coordinator.cancel(); state.coordinator.enqueueConversion([second], to: UTType(filenameExtension:"m4a")!) }
    try? await Task.sleep(for: .milliseconds(1500))
    await MainActor.run { state.coordinator.enqueueConversion([third], to: UTType(filenameExtension:"m4a")!) }
    for _ in 0..<400 { if await MainActor.run(body: { state.reports.count == 2 }) { break }; try? await Task.sleep(for: .milliseconds(25)) }
    await MainActor.run {
      precondition(state.reports.count == 2, "new worker or queued request lost")
      precondition(state.reports.map { $0[0].source.lastPathComponent } == ["second.mka", "third.mka"])
      precondition(state.reports.allSatisfy { $0[0].output != nil })
      precondition(!fm.fileExists(atPath: root.appendingPathComponent("first.m4a").path), "cancelled conversion published output")
      state.coordinator.cancel()
    }
    unsetenv("MORIQ_TEST_FFMPEG")
    print("PASS cancel propagates into audio converter and old worker cannot strand new queue")
 }
 @MainActor final class State { let coordinator = ConversionCoordinator(presentsNotices: false); var reports: [[ConversionRecord]] = [] }
}
