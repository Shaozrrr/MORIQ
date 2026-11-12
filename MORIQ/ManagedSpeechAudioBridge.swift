import Foundation
import AVFoundation
import CoreMedia

/// Serial callback converts captured system audio; only bounded transient PCM is retained.
final class ManagedSpeechAudioBridge: @unchecked Sendable {
    private let stream: ManagedSpeechStream
    private let onError: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending = Data()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private let input: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var writer: Task<Void, Never>?

    init(stream: ManagedSpeechStream, onError: @escaping @Sendable () -> Void) {
        self.stream = stream; self.onError = onError
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(50))
        input = pair.stream; continuation = pair.continuation
        writer = Task { [stream, input, onError] in
            do {
                for await data in input { try Task.checkCancellation(); try await stream.sendPCM(data) }
            } catch is CancellationError { }
            catch { onError() }
        }
    }
    /// Called on the single serial ScreenCaptureKit audio output queue.
    func append(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, sample.isValid,
              let desc = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let source = AVAudioFormat(streamDescription: basic) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max), let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames)) else { failLocked(); return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { failLocked(); return }
        if inputFormat != source { converter = AVAudioConverter(from: source, to: target); inputFormat = source }
        guard let converter else { failLocked(); return }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * target.sampleRate / source.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { failLocked(); return }
        var supplied = false, conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return buffer
        }
        guard status != .error, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else {
            if status == .error { failLocked() }; return
        }
        pending.append(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        while pending.count >= 2560 {
            let packet = Data(pending.prefix(2560)); pending.removeFirst(2560)
            if case .dropped = continuation.yield(packet) { failLocked(); return }
        }
    }
    private func failLocked() {
        guard !stopped else { return }
        stopped = true; pending.removeAll(keepingCapacity: false); continuation.finish(); writer?.cancel()
        onError()
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true; pending.removeAll(keepingCapacity: false); continuation.finish(); writer?.cancel(); writer = nil
    }
    deinit { stop() }
}

/// Observes revocation from settings during an active or connecting session.
@MainActor final class ManagedSpeechConsentMonitor {
    static let key = "moriq.managedSpeechConsent"
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    init(defaults: UserDefaults = .standard, onRevoke: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self, !self.defaults.bool(forKey: Self.key) { onRevoke() } }
        }
    }
    func stop() { if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil } }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
