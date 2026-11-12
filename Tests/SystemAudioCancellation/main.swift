import Foundation
import AVFoundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-system-audio-cancel-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("input.wav")
let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
do {
let audio = try AVAudioFile(forWriting: input, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!; buffer.frameLength = 44100
for i in 0..<44100 { buffer.int16ChannelData![0][i] = Int16(sin(Double(i) * 0.04) * 12000) }
try audio.write(from: buffer)
}
let marker = root.appendingPathComponent("input.m4a"); try Data("preserve".utf8).write(to: marker)
let ready = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
let actual = Task.detached {
    let converter = AudioConverter(debugBeforePublish: { ready.signal(); resume.wait() })
    do { _ = try converter.convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "m4a")!); fatalError("cancelled audio published") }
    catch is CancellationError {} catch { fatalError("unexpected \(error)") }
    done.signal()
}
precondition(ready.wait(timeout: .now() + 15) == .success, "real encoding did not finish")
actual.cancel(); resume.signal(); precondition(done.wait(timeout: .now() + 5) == .success)
let preserved = try Data(contentsOf: marker); precondition(preserved == Data("preserve".utf8))
let afterCancel = try fm.contentsOfDirectory(atPath: root.path)
precondition(!afterCancel.contains { $0.hasPrefix(".moriq-") || $0 == "input (2).m4a" })
let wrapper = root.appendingPathComponent("slow-afconvert")
try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: wrapper); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
let launched = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
let slow = Task.detached {
    let converter = AudioConverter(debugExecutable: wrapper, debugAfterLaunch: { launched.signal() })
    do { _ = try converter.convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "m4a")!); fatalError("slow process returned") }
    catch is CancellationError {} catch { fatalError("unexpected \(error)") }
    finished.signal()
}
precondition(launched.wait(timeout: .now() + 3) == .success); let start = Date(); slow.cancel()
precondition(finished.wait(timeout: .now() + 2) == .success && Date().timeIntervalSince(start) < 1.5)
let output = try AudioConverter().convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "m4a")!)
let decoded = try AVAudioFile(forReading: output)
precondition(output.lastPathComponent == "input (2).m4a" && decoded.length > 0)
print("PASS actual audio cancellation, child termination and normal protected output")
