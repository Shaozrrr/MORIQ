import Foundation
import Security
import CoreFoundation

/// Deliberately contains no vendor credentials. Guest issuance reserves limited
/// server quota; no failure, timeout or expiry may trigger an automatic retry.
enum ManagedGuestTrialError: Error, Equatable {
    case notUserInitiated, alreadyConfigured, alreadyAttempted, invalidEndpoint
    case unavailable, invalidResponse, credentialStorage, expired
}

protocol ManagedGuestTrialStore {
    func existingToken() throws -> Bool
    /// Atomically persists a permanent attempt marker before contacting server.
    func claimAttempt() throws -> Bool
    func storeToken(_ value: String) throws
}

struct ManagedGuestTrialKeychainStore: ManagedGuestTrialStore {
    private let markerService: String
    private let accountService: String
    init() {
        markerService = "local.moriq.managed-ai.guest-trial"
        accountService = "local.moriq.managed-ai.account"
    }
    #if DEBUG
    init(testNamespace: String) {
        precondition(testNamespace.hasPrefix("local.moriq.test.guest.") && UUID(uuidString: String(testNamespace.dropFirst("local.moriq.test.guest.".count))) != nil)
        markerService = testNamespace + ".marker"; accountService = testNamespace + ".account"
    }
    #endif
    private var markerQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: markerService, kSecAttrAccount as String: "attempted-v1"]
    }
    func existingToken() throws -> Bool {
        do { try RuntimeCredentialPolicy.current.requireAccess() } catch { throw ManagedGuestTrialError.credentialStorage }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accountService, kSecAttrAccount as String: "session-token"]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw ManagedGuestTrialError.credentialStorage }
        return true
    }
    func claimAttempt() throws -> Bool {
        do { try RuntimeCredentialPolicy.current.requireAccess() } catch { throw ManagedGuestTrialError.credentialStorage }
        var request = markerQuery
        request[kSecValueData as String] = Data("attempted".utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw ManagedGuestTrialError.credentialStorage }
        return true
    }
    func storeToken(_ value: String) throws {
        do { try RuntimeCredentialPolicy.current.requireAccess() } catch { throw ManagedGuestTrialError.credentialStorage }
        // Do not overwrite an account that was signed in concurrently.
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accountService, kSecAttrAccount as String: "session-token",
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw ManagedGuestTrialError.credentialStorage }
    }
}

private final class GuestTrialNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// A single completion without waiting for a cancelled socket receive task.
private final class GuestTrialCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var finished = false
    func install(_ value: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { self.result = nil; lock.unlock(); value.resume(with: result); return }
        continuation = value; lock.unlock()
    }
    func finish(_ value: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let pending = continuation; continuation = nil
        if pending == nil { result = value }
        lock.unlock(); pending?.resume(with: value)
    }
}

struct GuestTrialReply {
    let token: String
    let expiresAt: Int64
    let remainingSeconds: Int
    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 4096, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ManagedGuestTrialError.invalidResponse }
        if object["type"] as? String == "error" {
            guard Set(object.keys) == ["type", "code"], object["code"] as? String == "trial_unavailable" else { throw ManagedGuestTrialError.invalidResponse }
            throw ManagedGuestTrialError.unavailable
        }
        guard Set(object.keys) == ["type", "token", "expires_at", "remaining_seconds"], object["type"] as? String == "guest_session",
              let token = object["token"] as? String, token.utf8.count == 43,
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let expiry = integer(object["expires_at"]), let remaining = integer(object["remaining_seconds"]),
              expiry > Int64(now.timeIntervalSince1970), expiry <= Int64(now.timeIntervalSince1970) + 86_700,
              (1...86_400).contains(remaining) else { throw ManagedGuestTrialError.invalidResponse }
        return .init(token: token, expiresAt: expiry, remainingSeconds: Int(remaining))
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, d >= 0, d <= 9_007_199_254_740_991 else { return nil }
        return Int64(d)
    }
}

actor ManagedGuestTrialClient {
    private let endpoint: URL
    private let store: any ManagedGuestTrialStore
    private var inProgress = false
    private static func validEndpoint(_ url: URL, allowLoopback: Bool) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path == "/v1/guest/session", let host = c.host?.lowercased(), !host.isEmpty else { return false }
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "0.0.0.0" || host.contains(":")
        return (c.scheme == "wss" && !local) || (allowLoopback && c.scheme == "ws" && host == "127.0.0.1")
    }
    init(endpoint: URL, store: any ManagedGuestTrialStore = ManagedGuestTrialKeychainStore(), allowLoopbackForTesting: Bool = false) throws {
        #if !DEBUG
        guard !allowLoopbackForTesting else { throw ManagedGuestTrialError.invalidEndpoint }
        #endif
        guard Self.validEndpoint(endpoint, allowLoopback: allowLoopbackForTesting) else { throw ManagedGuestTrialError.invalidEndpoint }
        self.endpoint = endpoint; self.store = store
    }
    /// The call site must require a deliberate user action and disclose that a
    /// successful request reserves the limited trial. No caller may auto-retry.
    func issue(userInitiated: Bool) async throws -> Int {
        guard userInitiated else { throw ManagedGuestTrialError.notUserInitiated }
        guard !inProgress else { throw ManagedGuestTrialError.alreadyAttempted }
        inProgress = true; defer { inProgress = false }
        // Reject an unsupported execution environment before marking an attempt.
        do { try RuntimeCredentialPolicy.current.requireNetwork() } catch { throw ManagedGuestTrialError.invalidEndpoint }
        guard try !store.existingToken() else { throw ManagedGuestTrialError.alreadyConfigured }
        guard try store.claimAttempt() else { throw ManagedGuestTrialError.alreadyAttempted }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil; cfg.httpShouldSetCookies = false; cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 8; cfg.timeoutIntervalForResource = 8
        let session = URLSession(configuration: cfg, delegate: GuestTrialNoRedirect(), delegateQueue: nil)
        let socket = session.webSocketTask(with: endpoint); socket.maximumMessageSize = 4096
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        let completion = GuestTrialCompletion()
        return try await withTaskCancellationHandler {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                Task {
                    do {
                        try await socket.send(.string("{\"type\":\"issue\"}"))
                        guard case .string(let raw) = try await socket.receive(), let data = raw.data(using: .utf8), data.count <= 4096 else { throw ManagedGuestTrialError.invalidResponse }
                        completion.finish(.success(data))
                    } catch { completion.finish(.failure(error)) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                    completion.finish(.failure(ManagedGuestTrialError.unavailable))
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            let result = try GuestTrialReply.parse(data)
            try store.storeToken(result.token)
            return result.remainingSeconds
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        }
    }
}
