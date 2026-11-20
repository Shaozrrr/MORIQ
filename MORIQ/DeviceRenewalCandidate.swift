import Foundation
import Security

// Candidate only: not wired to the shipping client.
struct DeviceRenewalState: Codable, Equatable {
    struct Pending: Codable, Equatable {
        let access: String
        let operationID: String
        let generation: Int
    }
    let device: String
    var access: String
    var generation: Int
    var pending: Pending?
    // Non-nil only until the invitation exchange is confirmed. Kept in the
    // same Keychain item so a lost response can be retried after relaunch.
    var pendingInvite: String? = nil
    // Optional preserves decoding of identities created before anonymous setup.
    var pendingAnonymous: Bool? = nil
    var renewAfter: Date? = nil
    var renewedAt: Date? = nil
    func needsRenewal(now: Date) -> Bool {
        guard pending == nil, let renewedAt, let renewAfter, now >= renewedAt, now < renewAfter else { return true }
        return false
    }
}

protocol DeviceRenewalStore {
    func load() throws -> DeviceRenewalState?
    func save(_ state: DeviceRenewalState) throws
}

struct DeviceRenewalKeychain: DeviceRenewalStore {
    var service = "local.moriq.managed-ai.device"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "device-state"] }
    func load() throws -> DeviceRenewalState? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain }
        return try JSONDecoder().decode(DeviceRenewalState.self, from: data)
    }
    func save(_ state: DeviceRenewalState) throws {
        let data = try JSONEncoder().encode(state)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
        } else if status != errSecSuccess { throw Failure.keychain }
    }
    enum Failure: Error { case keychain }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain }
    }
}

actor DeviceRenewalCoordinator {
    static let shared = DeviceRenewalCoordinator(store: DeviceRenewalKeychain())
    enum Failure: Error { case missingIdentity, random, conflict }
    private let store: any DeviceRenewalStore
    private var renewalInFlight = false
    private var activeLeases: Set<UUID> = []
    init(store: any DeviceRenewalStore) { self.store = store }

    private func randomHex(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.random }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func prepareActivation(invite: String) throws -> DeviceRenewalState {
        if let existing = try store.load() {
            guard existing.pendingInvite == invite else { throw Failure.conflict }
            return existing
        }
        guard (32...256).contains(invite.utf8.count), invite.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.conflict }
        let state = DeviceRenewalState(device: try randomHex(32), access: try randomHex(32), generation: 0, pendingInvite: invite)
        try store.save(state)
        return state
    }

    func activationCommitted(expiresIn: Int = 604800) throws {
        guard var state = try store.load(), state.pendingInvite != nil else { throw Failure.conflict }
        state.pendingInvite = nil
        let now = Date(); state.renewedAt = now
        state.renewAfter = now.addingTimeInterval(TimeInterval(max(0, expiresIn - 86400)))
        try store.save(state)
    }

    func activate(invite: String, using transport: DeviceRenewalTransport) async throws {
        guard !renewalInFlight else { throw Failure.conflict }
        let state = try prepareActivation(invite: invite)
        renewalInFlight = true
        defer { renewalInFlight = false }
        let expiresIn = try await transport.activate(state)
        try activationCommitted(expiresIn: expiresIn)
    }

    // Persist the same random identity before any network I/O so a dropped
    // activation reply can be retried without issuing a different device.
    func activateAnonymous(using transport: DeviceRenewalTransport) async throws {
        guard !renewalInFlight else { throw Failure.conflict }
        var state: DeviceRenewalState
        if let existing = try store.load() {
            guard existing.pendingInvite == nil else { throw Failure.conflict }
            if existing.pendingAnonymous != true { return }
            state = existing
        } else {
            state = DeviceRenewalState(device: try randomHex(32), access: try randomHex(32), generation: 0, pendingAnonymous: true)
            try store.save(state)
        }
        renewalInFlight = true
        defer { renewalInFlight = false }
        let expiresIn = try await transport.activateAnonymous(state)
        guard var current = try store.load(), current == state, current.pendingAnonymous == true else { throw Failure.conflict }
        current.pendingAnonymous = nil
        let now = Date(); current.renewedAt = now
        current.renewAfter = now.addingTimeInterval(TimeInterval(max(0, expiresIn - 86400)))
        try store.save(current)
    }

    // nil means defer while a speech stream is active. Repeated calls return
    // the persisted request, including after a process restart.
    func prepare(speechActive: Bool) throws -> DeviceRenewalState.Pending? {
        guard var state = try store.load() else { throw Failure.missingIdentity }
        guard state.pendingInvite == nil, state.pendingAnonymous != true else { throw Failure.conflict }
        if let pending = state.pending { return speechActive ? nil : pending }
        guard !speechActive else { return nil }
        let pending = DeviceRenewalState.Pending(access: try randomHex(32), operationID: try randomHex(16), generation: state.generation)
        state.pending = pending
        try store.save(state)
        return pending
    }
    func committed(_ pending: DeviceRenewalState.Pending, expiresIn: Int = 604800) throws {
        guard var state = try store.load(), state.pending == pending, state.generation == pending.generation else { throw Failure.conflict }
        state.access = pending.access; state.generation += 1; state.pending = nil
        let now = Date(); state.renewedAt = now
        state.renewAfter = now.addingTimeInterval(TimeInterval(max(0, expiresIn - 86400)))
        try store.save(state)
    }

    func renew(using transport: DeviceRenewalTransport, speechActive: Bool) async throws -> Bool {
        guard !renewalInFlight, activeLeases.isEmpty else { return false }
        guard let pending = try prepare(speechActive: speechActive) else { return false }
        guard let state = try store.load(), state.pending == pending else { throw Failure.conflict }
        renewalInFlight = true
        defer { renewalInFlight = false }
        let expiresIn = try await transport.renew(device: state.device, pending: pending)
        try committed(pending, expiresIn: expiresIn)
        return true
    }

    func prepareNewSpeechSession(endpoint: URL) async throws {
        guard let state = try store.load() else { return } // legacy credentials
        guard state.pendingInvite == nil, state.pendingAnonymous != true else { throw Failure.conflict }
        if !state.needsRenewal(now: Date()) { return }
        let transport = try DeviceRenewalTransport(endpoint: endpoint)
        guard try await renew(using: transport, speechActive: false) else { throw Failure.conflict }
    }

    struct Lease: Sendable { let id: UUID; let token: String }

    // This is process-local coordination. All consumers must use it before
    // enabling automatic rotation; it is not a cross-process lock.
    func acquire(endpoint: URL, allowLoopbackForTesting: Bool = false, autoActivateAnonymous: Bool = false) async throws -> Lease {
        while true {
            try Task.checkCancellation()
            if renewalInFlight {
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let stored = try store.load()
            if autoActivateAnonymous && (stored == nil || stored?.pendingAnonymous == true) {
                let transport = try DeviceRenewalTransport(endpoint: endpoint, allowLoopback: allowLoopbackForTesting)
                try await activateAnonymous(using: transport)
                continue
            }
            guard let state = stored, state.pendingInvite == nil, state.pendingAnonymous != true else { throw Failure.missingIdentity }
            if state.needsRenewal(now: Date()) {
                if !activeLeases.isEmpty {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                let transport = try DeviceRenewalTransport(endpoint: endpoint, allowLoopback: allowLoopbackForTesting)
                guard try await renew(using: transport, speechActive: false) else { continue }
                continue
            }
            let id = UUID(); activeLeases.insert(id)
            return Lease(id: id, token: state.access)
        }
    }
    func release(_ lease: Lease) { activeLeases.remove(lease.id) }
}

private final class DeviceRenewalNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct DeviceRenewalTransport {
    enum Failure: Error { case endpoint, rejected }
    let endpoint: URL
    let session: URLSession
    init(endpoint: URL, allowLoopback: Bool = false) throws {
        #if !DEBUG
        guard !allowLoopback else { throw Failure.endpoint }
        #endif
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path == "/v1/devices/renew", let host = parts.host,
              (parts.scheme == "https" || (allowLoopback && parts.scheme == "http" && host == "127.0.0.1"))
        else { throw Failure.endpoint }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.endpoint = endpoint; self.session = URLSession(configuration: config, delegate: DeviceRenewalNoRedirect(), delegateQueue: nil)
    }
    func renew(device: String, pending: DeviceRenewalState.Pending) async throws -> Int {
        try await send(endpoint, body: ["device": device, "access": pending.access,
            "operation_id": pending.operationID, "generation": pending.generation])
    }
    func activate(_ state: DeviceRenewalState) async throws -> Int {
        guard let invite = state.pendingInvite else { throw Failure.rejected }
        let activationURL = endpoint.deletingLastPathComponent().appendingPathComponent("activate")
        return try await send(activationURL, body: ["invite": invite, "device": state.device, "access": state.access])
    }
    func activateAnonymous(_ state: DeviceRenewalState) async throws -> Int {
        guard state.pendingAnonymous == true else { throw Failure.rejected }
        let activationURL = endpoint.deletingLastPathComponent().appendingPathComponent("anonymous")
        return try await send(activationURL, body: ["device": state.device, "access": state.access])
    }
    private func send(_ url: URL, body: [String: Any]) async throws -> Int {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true,
              let remaining = object["expires_in"] as? Int, (1...604800).contains(remaining)
        else { throw Failure.rejected }
        return remaining
    }
}
