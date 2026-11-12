import AppKit
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

/// Official fixed model, verified before use. No captured audio is uploaded.
enum LocalWhisperModel {
    static let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
    static let expectedSize: UInt64 = 147_951_465
    static let expectedHash = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    static var helper: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let binary = root.appendingPathComponent("SpeechEngine/moriq-speech")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }
    static func valid(_ file: URL) -> Bool { valid(file, size: expectedSize, hash: expectedHash) }
    private static func valid(_ file: URL, size: UInt64, hash expected: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.uint64Value == size,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data: Data
            do { data = try handle.read(upToCount: 1_048_576) ?? Data() } catch { return false }
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
    static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("SpeechEngine/ggml-base.bin"),
           await Task.detached(priority: .utility, operation: { valid(bundled) }).value {
            return bundled
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MORIQ/Models", isDirectory: true)
        return try await prepare(root: root, source: url, size: expectedSize, hash: expectedHash, progress: progress)
    }
    #if DEBUG
    static func prepareTest(root: URL, source: URL, size: UInt64, hash: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await prepare(root: root, source: source, size: size, hash: hash, progress: progress)
    }
    #endif
    private static func prepare(root: URL, source: URL, size: UInt64, hash: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = root.appendingPathComponent("ggml-base.bin")
        if await Task.detached(priority: .utility, operation: { valid(destination, size: size, hash: hash) }).value { return destination }
        let partial = root.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }
        let downloader = DownloadHolder()
        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: source) { temporary, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let temporary, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { continuation.resume(throwing: ModelError.download); return }
                    do { try FileManager.default.moveItem(at: temporary, to: partial); continuation.resume(returning: partial) }
                    catch { continuation.resume(throwing: error) }
                }
                downloader.set(task)
                task.resume()
                Task {
                    while task.state == .running {
                        progress(task.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
        } onCancel: { downloader.cancel() }
        try Task.checkCancellation()
        guard await Task.detached(priority: .utility, operation: { valid(downloaded, size: size, hash: hash) }).value else { throw ModelError.integrity }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: downloaded) }
        else { try fm.moveItem(at: downloaded, to: destination) }
        progress(1)
        return destination
    }
    private enum ModelError: Error { case download, integrity }
    private final class DownloadHolder: @unchecked Sendable {
        private let lock = NSLock(); private var task: URLSessionDownloadTask?; private var cancelled = false
        func set(_ task: URLSessionDownloadTask) { lock.lock(); self.task = task; let stop = cancelled; lock.unlock(); if stop { task.cancel() } }
        func cancel() { lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel() }
    }
}

/// The helper consumes only PCM via its stdin pipe. Pending writes are bounded;
/// stop closes the pipe and terminates only this session's child process.
final class LocalWhisperCaptionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "local.moriq.captions.whisper-writer", qos: .userInitiated)
    private var pending = 0, stopped = false
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let process = Process(), input = Pipe(), output = Pipe()
    private let onText: @Sendable (String, Bool) -> Void
    private let onError: @Sendable (String) -> Void
    init(helper: URL, model: URL, language: String, onText: @escaping @Sendable (String, Bool) -> Void, onError: @escaping @Sendable (String) -> Void) throws {
        self.onText = onText; self.onError = onError
        process.executableURL = helper; process.arguments = [model.path, language]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let child = process
        DispatchQueue.global(qos: .utility).async { child.waitUntilExit() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readOutput() }
    }
    func append(_ sample: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sample), let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc), let source = AVAudioFormat(streamDescription: basic) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max), let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        if inputFormat != source { converter = AVAudioConverter(from: source, to: target); inputFormat = source }
        guard let converter else { onError("系统音频格式无法转换。"); return }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * target.sampleRate / source.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false, conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return buffer
        }
        guard status != .error, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { if status == .error { onError("系统音频转换失败。") }; return }
        let data = Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Float>.size)
        enqueue(data)
    }
    #if DEBUG
    func appendSyntheticPCM(_ data: Data) { enqueue(data) }
    var debugIsRunning: Bool { process.isRunning }
    #endif
    private func enqueue(_ data: Data) {
        lock.lock(); if stopped { lock.unlock(); return }; guard pending + data.count <= 1_048_576 else { lock.unlock(); onError("字幕处理跟不上播放速度，部分声音未处理。" ); return }; pending += data.count; lock.unlock()
        writer.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let active = !self.stopped; self.lock.unlock()
            if active { do { try self.input.fileHandleForWriting.write(contentsOf: data) } catch { self.onError("字幕处理已停止。"); self.stop() } }
            self.lock.lock(); self.pending -= data.count; self.lock.unlock()
        }
    }
    private func readOutput() {
        var pendingText = Data()
        while true {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            pendingText.append(data)
            if pendingText.count > 65_536 { onError("字幕输出异常，已停止。"); stop(); return }
            while let newline = pendingText.firstIndex(of: 10) {
                let line = pendingText.prefix(upTo: newline); pendingText.removeSubrange(...newline)
                guard let text = String(data: line, encoding: .utf8), text.count >= 2, text.dropFirst().first == "\t" else { continue }
                let prefix = text.first; guard prefix == "P" || prefix == "F" else { continue }
                lock.lock(); let active = !stopped; lock.unlock()
                if active { onText(String(text.dropFirst(2)), prefix == "F") }
            }
        }
        lock.lock(); let wasStopped = stopped; lock.unlock()
        if !wasStopped { onError("本机字幕引擎意外退出。"); stop() }
    }
    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        let handle = input.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async { try? handle.close() }
    }
    deinit { stop() }
}
