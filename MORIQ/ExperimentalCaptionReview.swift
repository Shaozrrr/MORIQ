#if DEBUG && MORIQ_CAPTION_REVIEW_EXPERIMENTAL
import SwiftUI
#if MORIQ_CAPTION_REVIEW_LOCAL_MOCK
import CryptoKit

private final class CaptionReviewRejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// This fixture accepts no real caption text and cannot address a remote host.
struct LocalCaptionReviewFixture {
    static let source = "Synthetic public test sentence."
    static let baseline = "模拟原译文。"
    let endpoint: URL
    init?(port: String) {
        guard let n = UInt16(port), n > 0,
              let url = URL(string: "ws://127.0.0.1:\(n)/review") else { return nil }
        endpoint = url
    }
    func translate(_ key: CaptionReviewKey) async throws -> String {
        struct Candidate: Decodable {
            let type, session, epoch, unit, target, source_sha256, candidate, recipient: String
            let revision: UInt64
            let auto_apply: Bool
        }
        struct Ready: Decodable { let type, recipient: String; let `protocol`: Int }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: CaptionReviewRejectRedirect(), delegateQueue: nil)
        let socket = session.webSocketTask(with: endpoint); socket.maximumMessageSize = 4096; socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        func send(_ data: [String: Any]) async throws {
            let bytes = try JSONSerialization.data(withJSONObject: data)
            try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
        }
        func receive<T: Decodable>(_ type: T.Type) async throws -> T {
            guard case .string(let raw) = try await socket.receive(), raw.utf8.count <= 4096 else { throw URLError(.badServerResponse) }
            return try JSONDecoder().decode(type, from: Data(raw.utf8))
        }
        let s = key.session.uuidString, e = key.epoch.uuidString, u = key.unit.uuidString
        try await send(["type":"start", "session":s, "epoch":e])
        let ready = try await receive(Ready.self)
        guard ready.type == "ready", ready.recipient == "本机模拟服务", ready.protocol == 1 else { throw URLError(.badServerResponse) }
        try await send(["type":"review", "session":s, "epoch":e, "unit":u, "revision":key.revision,
                        "target":key.target, "source":Self.source, "baseline":Self.baseline])
        let value = try await receive(Candidate.self)
        let digest = SHA256.hash(data: Data(Self.source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard value.type == "candidate", value.session == s, value.epoch == e, value.unit == u,
              value.revision == key.revision, value.target == key.target, value.source_sha256 == digest,
              value.recipient == "本机模拟服务", !value.auto_apply,
              value.candidate == "模拟校订候选。" else { throw URLError(.badServerResponse) }
        return value.candidate
    }
}
#endif

/// Diagnostic only: the synthetic provider cannot perform I/O. No candidate
/// is applied to the live caption model or the official transcript.
struct CaptionReviewKey: Hashable {
    let session: UUID
    let epoch: UUID
    let unit: UUID
    let revision: UInt64
    let target: String
}

struct FakeCaptionReviewProvider {
    let response: String
    let delay: Duration
    func translate() async throws -> String {
        try await Task.sleep(for: delay)
        return response
    }
}

@MainActor final class ExperimentalCaptionReview: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let key: CaptionReviewKey
        let baseline: String
        let candidate: String
        let associationVerified: Bool
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var pending = 0
    private var session = UUID()
    private var epoch = UUID()
    private var currentTarget = ""
    private var latest: [UUID: CaptionReviewKey] = [:]
    private var operations: [UUID: (UUID, Task<Void, Never>, Task<Void, Never>)] = [:]

    func begin(session: UUID, epoch: UUID, target: String) {
        cancelAll()
        self.session = session; self.epoch = epoch; currentTarget = target
        latest.removeAll(); entries.removeAll()
    }

    /// Call only with a manually assembled synthetic fixture. A caller may mark
    /// a pair verified only when association is independently established.
    func submit(_ key: CaptionReviewKey, baseline: String, associationVerified: Bool,
                provider: FakeCaptionReviewProvider, timeout: Duration = .seconds(3)) {
        submit(key, baseline: baseline, associationVerified: associationVerified, timeout: timeout) { try await provider.translate() }
    }
    #if MORIQ_CAPTION_REVIEW_LOCAL_MOCK
    func submitLocalFixture(_ key: CaptionReviewKey, provider: LocalCaptionReviewFixture, timeout: Duration = .seconds(3)) {
        guard key.target == "zh-Hans" else { return }
        submit(key, baseline: LocalCaptionReviewFixture.baseline, associationVerified: false, timeout: timeout) {
            try await provider.translate(key)
        }
    }
    #endif
    private func submit(_ key: CaptionReviewKey, baseline: String, associationVerified: Bool,
                        timeout: Duration, translate: @escaping () async throws -> String) {
        guard key.session == session, key.epoch == epoch, key.target == currentTarget,
              !key.target.isEmpty, !baseline.isEmpty,
              key.revision > (latest[key.unit]?.revision ?? 0) else { return }
        cancel(key.unit)
        latest[key.unit] = key
        entries.removeAll { $0.key.unit == key.unit }
        let operation = UUID()
        let work = Task { [weak self] in
            guard let result = try? await translate(), !Task.isCancelled else { return }
            self?.finish(key, operation: operation, baseline: baseline, candidate: result,
                         associationVerified: associationVerified)
        }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.expire(key, operation: operation)
        }
        operations[key.unit] = (operation, work, timer)
        pending = operations.count
    }

    private func finish(_ key: CaptionReviewKey, operation: UUID, baseline: String,
                        candidate: String, associationVerified: Bool) {
        guard key.session == session, key.epoch == epoch, key.target == currentTarget,
              latest[key.unit] == key, operations[key.unit]?.0 == operation else { return }
        cancel(key.unit)
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.append(Entry(key: key, baseline: baseline, candidate: candidate,
                             associationVerified: associationVerified))
    }
    private func expire(_ key: CaptionReviewKey, operation: UUID) {
        guard latest[key.unit] == key, operations[key.unit]?.0 == operation else { return }
        cancel(key.unit)
    }
    private func cancel(_ unit: UUID) {
        if let op = operations.removeValue(forKey: unit) { op.1.cancel(); op.2.cancel() }
        pending = operations.count
    }
    private func cancelAll() {
        for (_, op) in operations { op.1.cancel(); op.2.cancel() }
        operations.removeAll(); pending = 0
    }
}

struct ExperimentalCaptionReviewView: View {
    @ObservedObject var review: ExperimentalCaptionReview
    var body: some View {
        List(review.entries) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.associationVerified ? "校订候选 · 已核对关联" : "独立校订记录 · 未关联字幕")
                    .font(.caption).foregroundStyle(.secondary)
                Text(entry.baseline)
                Text(entry.candidate).foregroundStyle(.blue)
            }
        }.accessibilityIdentifier("caption-review-diagnostic")
    }
}

/// Explicitly synthetic. Entered from the debug subtitle toolbar; it never
/// receives real live captions and offers no provider or credential settings.
struct ExperimentalCaptionReviewPanel: View {
    @StateObject private var review = ExperimentalCaptionReview()
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("译文校订实验 · 模拟数据").font(.headline)
                Spacer()
                Button("返回字幕", action: close).accessibilityIdentifier("caption-review-close")
            }
            #if MORIQ_CAPTION_REVIEW_LOCAL_MOCK
            Text("仅发送固定合成文本至本机模拟服务，不会修改字幕。")
                .font(.caption).foregroundStyle(.secondary)
            #else
            Text("仅演示候选结果，不连接网络，也不会修改字幕。")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            HStack {
                Button("运行模拟") {
                    let session = UUID(), epoch = UUID()
                    #if MORIQ_CAPTION_REVIEW_LOCAL_MOCK
                    review.begin(session: session, epoch: epoch, target: "zh-Hans")
                    if let port = ProcessInfo.processInfo.environment["MORIQ_REVIEW_FAKE_PORT"], let provider = LocalCaptionReviewFixture(port: port) {
                        review.submitLocalFixture(.init(session: session, epoch: epoch, unit: UUID(), revision: 1, target: "zh-Hans"), provider: provider)
                    }
                    #else
                    review.begin(session: session, epoch: epoch, target: "zh")
                    review.submit(.init(session: session, epoch: epoch, unit: UUID(), revision: 1, target: "zh"),
                                  baseline: "这是一条原始译文。", associationVerified: false,
                                  provider: .init(response: "这是一条模拟校订结果。", delay: .milliseconds(150)))
                    #endif
                }.accessibilityIdentifier("caption-review-run")
                if review.pending > 0 { Text("模拟中").font(.caption).foregroundStyle(.secondary) }
            }
            ExperimentalCaptionReviewView(review: review)
        }.accessibilityIdentifier("caption-review-panel")
    }
}
#endif
