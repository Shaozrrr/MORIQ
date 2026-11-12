import Foundation

/// Product-gateway events; the client never receives the upstream provider key.
struct ManagedSpeechEvent: Decodable, Sendable {
    let type: String
    let text: String?
    let final: Bool?
    let segment: Int?
    let message: String?
}

enum ManagedSpeechError: Error {
    case invalidEndpoint, invalidToken, notStarted, invalidAudio, invalidResponse, connectionClosed
}

private final class SpeechRejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One short-lived duplex session. PCM is signed 16-bit little-endian, 16 kHz mono.
/// Consumer must wait for `ready` before sending audio, and cancel when capture stops.
actor ManagedSpeechStream {
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var receiver: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ManagedSpeechEvent, Error>.Continuation?
    private var started = false
    private var closed = false

    init(endpoint: URL, token: String, allowLoopbackForTesting: Bool = false) throws {
        guard let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let host = c.host, !host.isEmpty, c.path == "/v1/speech/stream" else { throw ManagedSpeechError.invalidEndpoint }
        #if !DEBUG
        guard !allowLoopbackForTesting else { throw ManagedSpeechError.invalidEndpoint }
        #endif
        let loopback = host == "127.0.0.1" || host == "::1"
        guard c.scheme == "wss" || (allowLoopbackForTesting && c.scheme == "ws" && loopback) else { throw ManagedSpeechError.invalidEndpoint }
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ManagedSpeechError.invalidToken }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: SpeechRejectRedirects(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 32_768
    }

    func start(source: String, target: String) async throws -> AsyncThrowingStream<ManagedSpeechEvent, Error> {
        guard !started, !closed else { throw ManagedSpeechError.notStarted }
        started = true
        let pair = AsyncThrowingStream<ManagedSpeechEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation = pair.continuation
        socket.resume()
        do {
            let data = try JSONSerialization.data(withJSONObject: ["type":"start", "source":source, "target":target], options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else { throw ManagedSpeechError.invalidResponse }
            try await socket.send(.string(json))
        } catch { close(); throw error }
        receiver = Task { [weak self] in await self?.receiveLoop() }
        return pair.stream
    }

    func sendPCM(_ data: Data) async throws {
        guard started, !closed else { throw ManagedSpeechError.notStarted }
        guard !data.isEmpty, data.count <= 6400, data.count % 2 == 0 else { throw ManagedSpeechError.invalidAudio }
        try await socket.send(.data(data))
    }
    func finish() async throws {
        guard started, !closed else { throw ManagedSpeechError.notStarted }
        try await socket.send(.string("{\"type\":\"finish\"}"))
    }
    func cancel() { close() }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled && !closed {
                let message = try await socket.receive()
                guard case .string(let raw) = message, raw.utf8.count <= 32_768, let data = raw.data(using: .utf8) else { throw ManagedSpeechError.invalidResponse }
                let event = try JSONDecoder().decode(ManagedSpeechEvent.self, from: data)
                guard ["ready", "source", "translation", "finished", "error"].contains(event.type) else { throw ManagedSpeechError.invalidResponse }
                if event.type == "source" || event.type == "translation" {
                    guard let text = event.text, text.utf8.count <= 16000, let segment = event.segment, segment >= 0, event.final != nil else { throw ManagedSpeechError.invalidResponse }
                }
                if let continuation {
                    if case .dropped = continuation.yield(event) { throw ManagedSpeechError.invalidResponse }
                }
                if event.type == "finished" { close(); return }
                if event.type == "error" { throw ManagedSpeechError.connectionClosed }
            }
        } catch {
            if !closed { continuation?.finish(throwing: error); continuation = nil }
            close()
        }
    }
    private func close() {
        guard !closed else { return }
        closed = true; receiver?.cancel(); receiver = nil
        continuation?.finish(); continuation = nil
        socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
    }
}
