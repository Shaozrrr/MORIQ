import CoreML
import FluidAudio
import Foundation

// Isolated process: mono 16 kHz Float32 PCM on stdin, line-delimited JSON on
// stdout. It never opens a device, reads credentials, or downloads a model.
// Speaker slots are session-local, not verified names or cross-session IDs.
struct Turn: Encodable {
    let speaker: Int
    let startSample: Int64
    let endSample: Int64
    let final: Bool
}
struct Event: Encodable {
    let type: String
    let turns: [Turn]?
}
func send(_ event: Event) throws {
    let bytes = try JSONEncoder().encode(event)
    FileHandle.standardOutput.write(bytes)
    FileHandle.standardOutput.write(Data([10]))
}
func convert(_ segment: DiarizerSegment, final: Bool) -> Turn {
    Turn(speaker: segment.speakerIndex,
         startSample: Int64((Double(segment.startTime) * 16000).rounded()),
         endSample: Int64((Double(segment.endTime) * 16000).rounded()), final: final)
}
@main struct Main {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        do {
            let path = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: path, configuration: configuration)
            let models = try SortformerModels(config: .default, main: model)
            let engine = SortformerDiarizer(config: .default)
            engine.initialize(models: models)
            try send(Event(type: "ready", turns: nil))
            let input = FileHandle.standardInput
            var pending = Data()
            while true {
                let block = try input.read(upToCount: 6400) ?? Data()
                if block.isEmpty { break }
                pending.append(block)
                let bytes = pending.count - pending.count % MemoryLayout<Float>.size
                guard bytes > 0 else { continue }
                let consumed = pending.prefix(bytes)
                let floats = consumed.withUnsafeBytes { raw -> [Float] in
                    let unaligned = raw.bindMemory(to: UInt8.self)
                    var result = [Float](repeating: 0, count: bytes / 4)
                    result.withUnsafeMutableBytes { $0.copyBytes(from: unaligned) }
                    return result
                }
                pending.removeFirst(bytes)
                if let update = try engine.process(samples: floats, sourceSampleRate: 16000) {
                    let turns = update.finalizedSegments.map { convert($0, final: true) } + update.tentativeSegments.map { convert($0, final: false) }
                    if !turns.isEmpty { try send(Event(type: "turns", turns: turns)) }
                }
            }
            guard pending.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            if let update = try engine.finalizeSession() {
                let turns = update.finalizedSegments.map { convert($0, final: true) }
                if !turns.isEmpty { try send(Event(type: "turns", turns: turns)) }
            }
            try send(Event(type: "finished", turns: nil))
        } catch {
            // No audio, filesystem path, or arbitrary exception enters logs.
            try? send(Event(type: "failed", turns: nil))
            exit(1)
        }
    }
}
