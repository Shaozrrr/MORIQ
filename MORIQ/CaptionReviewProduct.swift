import Foundation
import SwiftUI

/// A source reference is issued by the authenticated caption gateway. It is
/// never constructed from user-provided text or an inferred bilingual pairing.
struct CaptionReviewSourceUnit: Equatable {
    let session: UUID, epoch: UUID, unit: UUID
    let revision: UInt64
    let sourceSHA256: String
    fileprivate init(session: UUID, epoch: UUID, unit: UUID, revision: UInt64, sourceSHA256: String) {
        self.session = session; self.epoch = epoch; self.unit = unit; self.revision = revision; self.sourceSHA256 = sourceSHA256
    }
    static func fromValidated(_ marker: SourceMarker) -> Self {
        .init(session: marker.session, epoch: marker.epoch, unit: marker.unit, revision: marker.revision, sourceSHA256: marker.source_sha256)
    }
    #if DEBUG
    static func fixture(session: UUID, epoch: UUID, unit: UUID, revision: UInt64, sourceSHA256: String) -> Self {
        .init(session: session, epoch: epoch, unit: unit, revision: revision, sourceSHA256: sourceSHA256)
    }
    #endif
}

private final class CaptionReviewNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum CaptionReviewClientError: Error { case unavailable, invalidEndpoint, invalidResponse }

struct CaptionReviewClient {
    let endpoint: URL
    private let tokenLoader: () throws -> String?
    private static func validate(_ url: URL, loopbackTesting: Bool) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path == "/v1/caption/review", let host = c.host?.lowercased(), !host.isEmpty else { return false }
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") ||
                    ["::1", "[::1]", "::", "[::]", "0.0.0.0"].contains(host) || host.contains("::ffff:")
        return (c.scheme == "wss" && !local) || (loopbackTesting && c.scheme == "ws" && host == "127.0.0.1")
    }
    init(endpoint: URL, tokenLoader: @escaping () throws -> String?) throws {
        guard Self.validate(endpoint, loopbackTesting: false) else { throw CaptionReviewClientError.invalidEndpoint }
        self.endpoint = endpoint; self.tokenLoader = tokenLoader
    }
    static func configured(_ value: Any?, enabled: Bool = false, tokenLoader: @escaping () throws -> String?) -> CaptionReviewClient? {
        guard enabled, let text = value as? String, let url = URL(string: text) else { return nil }
        return try? CaptionReviewClient(endpoint: url, tokenLoader: tokenLoader)
    }
    #if DEBUG
    init(testEndpoint: URL, tokenLoader: @escaping () throws -> String?) throws {
        guard Self.validate(testEndpoint, loopbackTesting: true) else { throw CaptionReviewClientError.invalidEndpoint }
        endpoint = testEndpoint; self.tokenLoader = tokenLoader
    }
    #endif

    func request(_ ref: CaptionReviewSourceUnit, target: String) async throws -> String {
        guard !(Bundle.main.bundleIdentifier ?? "").hasPrefix("local.moriq.internal"), Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor") == nil else {
            FileHandle.standardError.write(Data("MORIQ runtime refused caption review network\n".utf8))
            throw CaptionReviewClientError.unavailable
        }
        struct Reply: Decodable {
            let status: String, session: String, epoch: String, unit: String, target: String
            let revision: UInt64
            let candidate: String, source_sha256: String
            let association_verified: Bool, auto_apply: Bool
        }
        guard ["zh-Hans", "en-US"].contains(target), ref.revision > 0, ref.revision <= 9_007_199_254_740_991,
              ref.sourceSHA256.count == 64, ref.sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let token = try tokenLoader(), (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CaptionReviewClientError.unavailable }
        var req = URLRequest(url: endpoint); req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let cfg = URLSessionConfiguration.ephemeral; cfg.urlCache = nil; cfg.httpShouldSetCookies = false; cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 5; cfg.timeoutIntervalForResource = 5
        let session = URLSession(configuration: cfg, delegate: CaptionReviewNoRedirect(), delegateQueue: nil)
        let socket = session.webSocketTask(with: req); socket.maximumMessageSize = 16_384; socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let s = ref.session.uuidString.lowercased(), e = ref.epoch.uuidString.lowercased(), u = ref.unit.uuidString.lowercased()
            let payload: [String: Any] = ["session":s, "epoch":e, "unit":u, "revision":ref.revision, "target":target]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            guard case .string(let raw) = try await socket.receive(), raw.utf8.count <= 16_384 else { throw CaptionReviewClientError.invalidResponse }
            let result = try JSONDecoder().decode(Reply.self, from: Data(raw.utf8))
            guard result.status == "candidate", result.session == s, result.epoch == e, result.unit == u,
                  result.revision == ref.revision, result.target == target, result.source_sha256 == ref.sourceSHA256,
                  !result.association_verified, !result.auto_apply,
                  !result.candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.candidate.unicodeScalars.count <= 4000 else { throw CaptionReviewClientError.invalidResponse }
            return result.candidate
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        }
    }
}

@MainActor final class CaptionReviewProductState: ObservableObject {
    struct Result: Identifiable { let id = UUID(); let source: CaptionReviewSourceUnit; let target: String; let candidate: String }
    @Published private(set) var result: Result?
    @Published private(set) var pending = false
    @Published private(set) var message = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    func invalidate() { generation = UUID(); task?.cancel(); task = nil; pending = false; result = nil; message = "" }
    /// Call only after the user sees and accepts this request's recipient and
    /// data disclosure. It never mutates a caption or translation model.
    func request(source: CaptionReviewSourceUnit, target: String, disclosedAndRequested: Bool, client: CaptionReviewClient) {
        guard disclosedAndRequested else { return }
        invalidate(); let id = generation; pending = true
        task = Task { [weak self] in
            do {
                let answer = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await client.request(source, target: target) }
                    group.addTask { try await Task.sleep(for: .seconds(5)); throw CaptionReviewClientError.unavailable }
                    defer { group.cancelAll() }; return try await group.next()!
                }
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.pending = false; self.result = Result(source: source, target: target, candidate: answer)
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.pending = false; self.message = "校订暂不可用，原字幕不受影响。"
            }
        }
    }
}

struct CaptionReviewCandidateView: View {
    @ObservedObject var state: CaptionReviewProductState
    var body: some View {
        VStack(alignment: .leading) {
            if let result = state.result { Text("独立校订候选 · 未关联字幕").font(.caption).foregroundStyle(.secondary); Text(result.candidate).textSelection(.enabled) }
            if !state.message.isEmpty { Text(state.message).foregroundStyle(.secondary) }
        }
    }
}

/// The calling UI must provide a real gateway-issued unit and explicit,
/// product-configured recipient description; absent either there is no action.
struct CaptionReviewUserAction: View {
    let source: CaptionReviewSourceUnit?
    let target: String
    let client: CaptionReviewClient?
    let recipientDisclosure: String?
    @StateObject private var state = CaptionReviewProductState()
    @State private var disclosed = false
    var body: some View {
        VStack(alignment: .leading) {
            if let source, let client, let recipient = recipientDisclosure, !recipient.isEmpty {
                Text("校订会将此段已确认原文发送至：\(recipient)。可能产生费用；结果不会覆盖字幕。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("我已了解并同意本次发送", isOn: $disclosed)
                Button("校订这段原文") {
                    state.request(source: source, target: target, disclosedAndRequested: disclosed, client: client)
                    disclosed = false
                }.disabled(!disclosed || state.pending)
            }
            CaptionReviewCandidateView(state: state)
        }
        .onChange(of: source) { _, _ in disclosed = false; state.invalidate() }
        .onChange(of: target) { _, _ in disclosed = false; state.invalidate() }
        .onDisappear { state.invalidate() }
    }
}
