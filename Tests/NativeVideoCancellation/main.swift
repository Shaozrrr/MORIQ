import Foundation
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-video-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let source = dir.appendingPathComponent("sample.mov")
let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
for frame in 0..<120 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var pixel: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
    CVPixelBufferLockBaseAddress(pixel!, [])
    memset(CVPixelBufferGetBaseAddress(pixel!), Int32(frame * 5), CVPixelBufferGetDataSize(pixel!))
    CVPixelBufferUnlockBaseAddress(pixel!, [])
    precondition(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
precondition(writer.status == .completed)
let target = UTType(filenameExtension: "mp4")!
let worker = Task.detached { try VideoConverter().convert(input: source, outputDirectory: dir, format: target) }
let deadline = Date().addingTimeInterval(8)
var staged = false
while Date() < deadline {
    if (try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains(where: { $0.hasPrefix(".moriq-") }) { staged = true; break }
    Thread.sleep(forTimeInterval: 0.002)
}
precondition(staged, "export never started")
worker.cancel()
let doneCancel = DispatchSemaphore(value: 0)
Task.detached {
    defer { doneCancel.signal() }
    do { _ = try await worker.value; preconditionFailure("cancelled export published output") }
    catch is CancellationError { }
    catch { preconditionFailure("unexpected failure: \(error)") }
}
precondition(doneCancel.wait(timeout: .now() + 8) == .success)
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
precondition(!files.contains(where: { $0.hasPrefix(".moriq-") || $0.hasSuffix(".mp4") }))
precondition(FileManager.default.fileExists(atPath: source.path))
let result = try VideoConverter().convert(input: source, outputDirectory: dir, format: target)
precondition(AVURLAsset(url: result).isPlayable)
print("PASS native video export cancellation leaves no output; normal export remains playable")
