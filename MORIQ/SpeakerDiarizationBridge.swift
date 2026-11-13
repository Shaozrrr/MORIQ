import Foundation

struct SpeakerDiarizationTurn: Decodable, Sendable {
    let speaker: Int
    let startSample: Int64
    let endSample: Int64
    let final: Bool
}
private struct SpeakerDiarizationEvent: Decodable {
    let type: String
    let turns: [SpeakerDiarizationTurn]?
}

/// A single source and a single session own each instance. Callers must use the
/// same continuous 16 kHz clock for ASR and diarization. No missing block may
/// be silently skipped: that would shift every later speaker attribution.
final class SpeakerDiarizationBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "local.moriq.speaker.writer", qos: .userInitiated)
    private let process = Process(), input = Pipe(), output = Pipe()
    private let onTurns: @Sendable ([SpeakerDiarizationTurn]) -> Void
    private let onFailure: @Sendable () -> Void
    private let onFinished: @Sendable () -> Void
    private var pending = 0, stopped = false, failed = false, finishing = false, finished = false
    private let maxPendingBytes = 512_000

    init(helper: URL, model: URL,
         onTurns: @escaping @Sendable ([SpeakerDiarizationTurn]) -> Void,
         onFailure: @escaping @Sendable () -> Void,
         onFinished: @escaping @Sendable () -> Void = {}) throws {
        self.onTurns = onTurns; self.onFailure = onFailure; self.onFinished = onFinished
        process.executableURL = helper; process.arguments = [model.path]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let child = process
        DispatchQueue.global(qos: .utility).async { child.waitUntilExit() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readEvents() }
    }
    /// The caller owns conversion and must send 16 kHz mono Float32 PCM.
    /// False means the session is invalid and must not produce speaker labels.
    @discardableResult func append(_ pcm: Data) -> Bool {
        guard !pcm.isEmpty, pcm.count % 4 == 0 else { fail(); return false }
        lock.lock()
        guard !stopped, !failed, !finishing else { lock.unlock(); return false }
        guard pcm.count <= maxPendingBytes - pending else { lock.unlock(); fail(); return false }
        pending += pcm.count; lock.unlock()
        writer.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let active = !self.stopped && !self.failed; self.lock.unlock()
            if active {
                do { try self.input.fileHandleForWriting.write(contentsOf: pcm) }
                catch { self.fail() }
            }
            self.lock.lock(); self.pending = max(0, self.pending - pcm.count); self.lock.unlock()
        }
        return true
    }
    /// Graceful EOF follows all already-enqueued audio. Only final session
    /// output is accepted afterwards; no more audio can be submitted.
    func finish() {
        lock.lock(); guard !stopped, !failed, !finishing else { lock.unlock(); return }
        finishing = true; lock.unlock()
        writer.async { [weak self] in try? self?.input.fileHandleForWriting.close() }
    }
    func stop() {
        lock.lock(); let shouldStop = !stopped; stopped = true; lock.unlock()
        guard shouldStop else { return }
        // Terminating the owned child unblocks a writer blocked on a full pipe.
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }
    private func fail() {
        lock.lock(); let notify = !failed && !stopped; failed = true; lock.unlock()
        guard notify else { return }
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        onFailure()
    }
    private func readEvents() {
        var buffer = Data()
        do {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                guard buffer.count <= 131_072 else { fail(); return }
                while let index = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                    let event = try JSONDecoder().decode(SpeakerDiarizationEvent.self, from: line)
                    if event.type == "failed" { fail(); return }
                    if event.type == "finished" {
                        lock.lock(); let active = !stopped && !failed && finishing; finished = active; lock.unlock()
                        if active { onFinished() }
                        else { fail(); return }
                    }
                    if event.type == "turns", let turns = event.turns {
                        guard turns.allSatisfy({ $0.speaker >= 0 && $0.startSample >= 0 && $0.endSample > $0.startSample }) else { fail(); return }
                        lock.lock(); let active = !stopped && !failed; lock.unlock()
                        if active { onTurns(turns) }
                    }
                }
            }
            lock.lock(); let expected = stopped || (finishing && finished); lock.unlock()
            if !expected { fail() }
        } catch { fail() }
    }
    deinit { stop() }
}
