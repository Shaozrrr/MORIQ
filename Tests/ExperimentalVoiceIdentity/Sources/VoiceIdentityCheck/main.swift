import AVFoundation
import FluidAudio
import Foundation

// Research-only. The caller supplies explicit thresholds; none is a validated
// production operating point. Stored embeddings are sensitive biometric data.
struct Voice: Codable {
    let name: String
    let model: String
    let embedding: [Float]
}
struct Registry: Codable {
    let model: String
    private(set) var voices: [Voice] = []
    mutating func enroll(name: String, embedding: [Float]) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80, !voices.contains(where: { $0.name == clean }), valid(embedding) else { throw TestError.invalid }
        voices.append(Voice(name: clean, model: model, embedding: embedding))
    }
    mutating func remove(name: String) { voices.removeAll { $0.name == name } }
    func match(_ embedding: [Float], threshold: Float, margin: Float) -> String? {
        guard valid(embedding), threshold.isFinite, (-1...1).contains(threshold), margin.isFinite, (0...2).contains(margin) else { return nil }
        let ranked = voices.filter { $0.model == model && valid($0.embedding) }
            .map { ($0.name, CampPlusEmbedder.cosine($0.embedding, embedding)) }
            .sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= threshold else { return nil }
        if ranked.count > 1 && top.1 - ranked[1].1 < margin { return nil }
        return top.0
    }
    private func valid(_ value: [Float]) -> Bool {
        guard value.count == CampPlusEmbedder.embeddingDim, value.allSatisfy(\.isFinite) else { return false }
        let norm = sqrt(value.reduce(Float.zero) { $0 + $1 * $1 })
        return norm.isFinite && abs(norm - 1) < 0.01
    }
}
enum TestError: Error { case invalid, shortAudio }

@main struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let threshold = Float(args[3]), let margin = Float(args[4]) else { fatalError("model-directory public-clips-directory threshold margin") }
        // Only load a model from a caller-specified local path. Never download.
        let models = try CampPlusModels.load(from: URL(fileURLWithPath: args[1], isDirectory: true))
        let embedder = CampPlusEmbedder(models: models)
        let clips = URL(fileURLWithPath: args[2], isDirectory: true)
        func embeddingFile(_ url: URL) async throws -> [Float] {
            let file = try AVAudioFile(forReading: url)
            // Explicit research floor, not a calibrated production requirement.
            guard Double(file.length) / file.processingFormat.sampleRate >= 2 else { throw TestError.shortAudio }
            return try await embedder.embed(audioURL: url)
        }
        func embedding(_ index: Int) async throws -> [Float] { try await embeddingFile(clips.appendingPathComponent("\(index).wav")) }
        let a = try await embedding(0), b = try await embedding(1)
        let aLater = try await embedding(2), bLater = try await embedding(3)
        var registry = Registry(model: "fluid-campplus-v2")
        try registry.enroll(name: "用户命名 A", embedding: a)
        precondition(registry.match(aLater, threshold: threshold, margin: margin) == "用户命名 A")
        precondition(registry.match(bLater, threshold: threshold, margin: margin) == nil, "unknown voice must remain unknown")
        try registry.enroll(name: "用户命名 B", embedding: b)
        precondition(registry.match(aLater, threshold: threshold, margin: margin) == "用户命名 A")
        precondition(registry.match(bLater, threshold: threshold, margin: margin) == "用户命名 B")
        // Equal competing voiceprints must not resolve to an arbitrary person.
        try registry.enroll(name: "重复样例", embedding: a)
        precondition(registry.match(aLater, threshold: threshold, margin: margin) == nil)
        registry.remove(name: "重复样例")
        // Persistence uses only a private temporary fixture, no actual user data.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-voice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let shortURL = temporary.appendingPathComponent("short.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        do {
            let output = try AVAudioFile(forWriting: shortURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            try output.write(from: buffer)
        }
        do { _ = try await embeddingFile(shortURL); fatalError("short sample accepted") }
        catch TestError.shortAudio { }
        let file = temporary.appendingPathComponent("registry.json")
        try JSONEncoder().encode(registry).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var restored = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
        precondition(restored.match(bLater, threshold: threshold, margin: margin) == "用户命名 B")
        restored.remove(name: "用户命名 B")
        try JSONEncoder().encode(restored).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let reloaded = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: file))
        precondition(reloaded.match(bLater, threshold: threshold, margin: margin) == nil)
        // Untrusted, malformed vectors and models from another version never match.
        precondition(reloaded.match([Float](repeating: 0, count: 192), threshold: threshold, margin: margin) == nil)
        var wrongData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded)) as! [String: Any]
        wrongData["model"] = "another-model"
        let wrongModel = try JSONDecoder().decode(Registry.self, from: JSONSerialization.data(withJSONObject: wrongData))
        precondition(wrongModel.match(aLater, threshold: threshold, margin: margin) == nil)
        print("PASS real model registration, two speakers, short input, unknown, ambiguity, persistence and deletion")
    }
}
