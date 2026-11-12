import Foundation
import AVFoundation
import UniformTypeIdentifiers
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-audio-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let input = dir.appendingPathComponent("tone.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
buffer.frameLength = 44100
for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.15) }
var file: AVAudioFile? = try AVAudioFile(forWriting: input, settings: format.settings)
try file!.write(from: buffer)
file = nil
let converter = AudioConverter()
for target in AudioConverter.targets where target.preferredFilenameExtension != "wav" {
    print("Testing \(target.identifier)")
    let output = try converter.convert(input: input, outputDirectory: dir, format: target)
    let result = try AVAudioFile(forReading: output)
    precondition(result.length > 0)
}
precondition(ExternalMediaConverter.executable != nil, "FFmpeg test engine missing")
if let engine = ExternalMediaConverter.executable {
    for target in ExternalMediaConverter.audioTargets() where target.preferredFilenameExtension != "wav" {
        let output = try ExternalMediaConverter().convert(input: input, outputDirectory: dir, format: target, video: false)
        let check = Process(); check.executableURL = engine
        check.arguments = ["-v", "error", "-nostdin", "-i", output.path, "-t", "0.1", "-f", "null", "-"]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        try check.run(); check.waitUntilExit(); precondition(check.terminationStatus == 0)
    }
}
precondition(FileManager.default.fileExists(atPath: input.path))
print("PASS: native and FFmpeg audio targets decode successfully with retained source")
