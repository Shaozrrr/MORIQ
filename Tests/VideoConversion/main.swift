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
for frame in 0..<30 {
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
precondition(VideoConverter.targets(for: source).contains(target))
let result = try VideoConverter().convert(input: source, outputDirectory: dir, format: target)
let output = AVURLAsset(url: result)
precondition(output.isPlayable && output.duration.seconds > 0)
precondition(ExternalMediaConverter.executable != nil, "FFmpeg test engine missing")
if let engine = ExternalMediaConverter.executable {
    for target in ExternalMediaConverter.videoTargets() where target.preferredFilenameExtension != "mov" {
        let file = try ExternalMediaConverter().convert(input: source, outputDirectory: dir, format: target, video: true)
        let check = Process(); check.executableURL = engine
        check.arguments = ["-v", "error", "-nostdin", "-i", file.path, "-t", "0.1", "-f", "null", "-"]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        try check.run(); check.waitUntilExit(); precondition(check.terminationStatus == 0)
    }
}
precondition(FileManager.default.fileExists(atPath: source.path))
print("PASS: native and FFmpeg video targets decode successfully with retained source")
