import Foundation
import UniformTypeIdentifiers
import AVFoundation
import Darwin

enum AudioConversionError: Error { case unsupported, failed, invalidOutput, precisionUnsupported, filesystem(Int32) }
struct AudioConverter {
    #if DEBUG
    var debugExecutable: URL? = nil
    var debugAfterLaunch: (@Sendable () -> Void)? = nil
    var debugBeforePublish: (@Sendable () -> Void)? = nil
    #endif
    static let inputs: Set<String> = ["wav", "aif", "aiff", "aifc", "m4a", "aac", "mp3", "flac", "caf", "alac"]
    static func floatingPointBits(_ url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let description = file.fileFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatLinearPCM, description.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }
        return Int(description.mBitsPerChannel)
    }
    static func supports(_ url: URL) -> Bool { inputs.contains(url.pathExtension.lowercased()) }
    static var targets: [UTType] { ["wav", "aiff", "m4a", "flac", "caf"].compactMap { UTType(filenameExtension: $0) } }
    func convert(input: URL, outputDirectory: URL, format: UTType) throws -> URL {
        try Task.checkCancellation()
        guard Self.supports(input), Self.targets.contains(format), let ext = format.preferredFilenameExtension?.lowercased() else { throw AudioConversionError.unsupported }
        let floating = Self.floatingPointBits(input)
        let floatFormat = floating.map { $0 > 32 ? "64" : "32" }
        let spec: (String, String)
        switch ext {
        case "wav": spec = ("WAVE", floatFormat.map { "LEF" + $0 } ?? "LEI32")
        case "aiff", "aif": spec = floatFormat.map { ("AIFC", "BEF" + $0) } ?? ("AIFF", "BEI32")
        case "m4a": spec = ("m4af", "aac")
        case "flac": spec = ("flac", "flac")
        case "caf": spec = ("caff", floatFormat.map { "LEF" + $0 } ?? "LEI32")
        default: throw AudioConversionError.unsupported
        }
        if ext == "flac", let file = try? AVAudioFile(forReading: input),
           file.fileFormat.streamDescription.pointee.mBitsPerChannel > 24 {
            // The system FLAC encoder truncates higher precision silently.
            throw AudioConversionError.precisionUnsupported
        }
        let temporary = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        #if DEBUG
        process.executableURL = debugExecutable ?? URL(fileURLWithPath: "/usr/bin/afconvert")
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        #endif
        process.arguments = ["-f", spec.0, "-d", spec.1, input.path, temporary.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AudioConversionError.failed }
        #if DEBUG
        debugAfterLaunch?()
        #endif
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                let cancelled = Task.isCancelled
                process.terminate()
                let grace = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancelled { throw CancellationError() }
                throw AudioConversionError.failed
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw AudioConversionError.failed }
        guard let file = try? AVAudioFile(forReading: temporary), file.length > 0 else { throw AudioConversionError.invalidOutput }
        #if DEBUG
        debugBeforePublish?()
        #endif
        try Task.checkCancellation()
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).\(ext)")
            let result = temporary.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw AudioConversionError.filesystem(errno) }
        }
        throw AudioConversionError.failed
    }
}
