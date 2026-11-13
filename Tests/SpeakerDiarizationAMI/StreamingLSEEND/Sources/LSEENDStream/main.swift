import CoreML
import FluidAudio
import Foundation

// Research executable using FluidAudio's published stateful stream API.
// A cached model is required: this test must not start an implicit download.
struct Turn: Encodable { let speaker: Int; let startSample: Int64; let endSample: Int64; let final: Bool }
struct Event: Encodable { let type: String; let turns: [Turn]? }
func send(_ event: Event) throws { FileHandle.standardOutput.write(try JSONEncoder().encode(event)); FileHandle.standardOutput.write(Data([10])) }
func turn(_ value: DiarizerSegment, final: Bool) -> Turn {
    Turn(speaker: value.speakerIndex, startSample: Int64((Double(value.startTime)*16000).rounded()), endSample: Int64((Double(value.endTime)*16000).rounded()), final: final)
}
@main struct Main {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        do {
            let modelURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let model = try LSEENDModel(modelURL: modelURL, computeUnits: .cpuOnly)
            let timeline = DiarizerTimelineConfig(onsetThreshold: 0.5, offsetThreshold: 0.5, onsetPadFrames: 0)
            let engine = try LSEENDDiarizer(model: model, timelineConfig: timeline)
            try send(Event(type: "ready", turns: nil))
            var pending = Data()
            while true {
                let block = try FileHandle.standardInput.read(upToCount: 6400) ?? Data()
                if block.isEmpty { break }; pending.append(block)
                let bytes = pending.count - pending.count % 4
                guard bytes > 0 else { continue }
                let data = pending.prefix(bytes)
                let floats: [Float] = data.withUnsafeBytes { raw in
                    var values = [Float](repeating: 0, count: bytes / 4)
                    values.withUnsafeMutableBytes { $0.copyBytes(from: raw) }; return values
                }
                pending.removeFirst(bytes)
                if let update = try engine.process(samples: floats, sourceSampleRate: 16000) {
                    let turns = update.finalizedSegments.map { turn($0, final: true) } + update.tentativeSegments.map { turn($0, final: false) }
                    if !turns.isEmpty { try send(Event(type: "turns", turns: turns)) }
                }
            }
            guard pending.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            if let update = try engine.finalizeSession() {
                let turns = update.finalizedSegments.map { turn($0, final: true) }
                if !turns.isEmpty { try send(Event(type: "turns", turns: turns)) }
            }
            try send(Event(type: "finished", turns: nil))
        } catch { try? send(Event(type: "failed", turns: nil)); exit(1) }
    }
}
