import Foundation

/// Live-provider smoke client. Arguments contain only a local test address,
/// a random test token, and a path to generated synthetic PCM; never a key.
@main struct LiveSpeechCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 4,
              let endpoint = URL(string: CommandLine.arguments[1]) else { throw ManagedSpeechError.invalidEndpoint }
        let stream = try ManagedSpeechStream(endpoint: endpoint, token: CommandLine.arguments[2], allowLoopbackForTesting: true)
        let pcm = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let events = try await stream.start(source: "en", target: "zh")
        var accumulator = ManagedSpeechAccumulator()
        var sourcePartial = 0, translationPartial = 0, sourceFinal = "", translationFinal = ""
        var sender: Task<Void, Error>?
        for try await event in events {
            if event.type == "ready" {
                sender = Task {
                    var offset = 0
                    while offset < pcm.count {
                        let end = min(offset + 2560, pcm.count)
                        try await stream.sendPCM(pcm.subdata(in: offset..<end)); offset = end
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    try await stream.finish()
                }
            }
            if let assembled = accumulator.accept(event) {
                if event.type == "source" {
                    if assembled.final { sourceFinal += assembled.text } else { sourcePartial += 1 }
                } else if event.type == "translation" {
                    if assembled.final { translationFinal += assembled.text } else { translationPartial += 1 }
                }
            }
            if event.type == "finished" { break }
        }
        if let sender { try await sender.value }
        await stream.cancel()
        guard sourcePartial > 0, translationPartial > 0,
              sourceFinal.localizedCaseInsensitiveContains("meeting"),
              sourceFinal.localizedCaseInsensitiveContains("report"),
              translationFinal.contains("会议"), translationFinal.contains("中午") else { throw ManagedSpeechError.invalidResponse }
        print("PASS Swift live source partials=\(sourcePartial), translation partials=\(translationPartial)")
        print("SOURCE: \(sourceFinal)")
        print("TRANSLATION: \(translationFinal)")
    }
}
