import Foundation
import AVFoundation
import UniformTypeIdentifiers
import Darwin

private final class VideoExportCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func markCancelled() { lock.lock(); cancelled = true; lock.unlock() }
    func removeIfCancelled(_ url: URL) {
        lock.lock(); let shouldRemove = cancelled; lock.unlock()
        if shouldRemove { try? FileManager.default.removeItem(at: url) }
    }
}

enum VideoConversionError: Error { case unsupported, failed, invalidOutput, filesystem(Int32) }
struct VideoConverter {
    static let inputs: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2", "avi", "mpeg", "mpg"]
    static func supports(_ url: URL) -> Bool { inputs.contains(url.pathExtension.lowercased()) }
    static func targets(for url: URL) -> [UTType] {
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return [] }
        let possible: [(AVFileType, String)] = [(.mov, "mov"), (.mp4, "mp4"), (.m4v, "m4v")]
        return possible.compactMap { exporter.supportedFileTypes.contains($0.0) ? UTType(filenameExtension: $0.1) : nil }
    }
    func convert(input: URL, outputDirectory: URL, format: UTType) throws -> URL {
        try Task.checkCancellation()
        guard Self.supports(input), let ext = format.preferredFilenameExtension?.lowercased(),
              let type = ["mov": AVFileType.mov, "mp4": .mp4, "m4v": .m4v][ext] else { throw VideoConversionError.unsupported }
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality), exporter.supportedFileTypes.contains(type) else { throw VideoConversionError.unsupported }
        let temporary = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary; exporter.outputFileType = type; exporter.shouldOptimizeForNetworkUse = false
        let complete = DispatchSemaphore(value: 0)
        let cleanup = VideoExportCleanup()
        exporter.exportAsynchronously { cleanup.removeIfCancelled(temporary); complete.signal() }
        let deadline = Date().addingTimeInterval(300)
        while complete.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if Task.isCancelled || Date() >= deadline {
                let cancelled = Task.isCancelled
                cleanup.markCancelled()
                exporter.cancelExport()
                // Wait for AVFoundation to release its staged output before cleanup.
                _ = complete.wait(timeout: .now() + 5)
                if cancelled { throw CancellationError() }
                throw VideoConversionError.failed
            }
        }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw VideoConversionError.failed }
        let check = AVURLAsset(url: temporary)
        guard check.isPlayable, check.duration.isNumeric, check.duration.seconds > 0 else { throw VideoConversionError.invalidOutput }
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).\(ext)")
            let result = temporary.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw VideoConversionError.filesystem(errno) }
        }
        throw VideoConversionError.failed
    }
}
