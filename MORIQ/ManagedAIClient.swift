import Foundation
import Security

/// Reference integration for a future account system; no provider secret is stored here.
struct ManagedAIAccountToken {
    let service = "local.moriq.managed-ai.account"
    let account = "session-token"
    var policy: RuntimeCredentialPolicy = .current
    private func requireCredentialAccess() throws {
        do { try policy.requireAccess() } catch { throw ManagedAIError.keychain }
    }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func load() throws -> String? {
        try requireCredentialAccess()
        if let device = try DeviceRenewalKeychain().load() {
            guard device.pendingInvite == nil, device.pendingAnonymous != true else { throw ManagedAIError.notSignedIn }
            return device.access
        }
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else { throw ManagedAIError.keychain }
        return token
    }
    func save(_ token: String) throws {
        try requireCredentialAccess()
        // A device session takes precedence. Do not claim that a legacy token
        // has been applied while it would be ignored by load().
        guard try DeviceRenewalKeychain().load() == nil else { throw ManagedAIError.deviceAlreadyConnected }
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }), let data = token.data(using: .utf8) else { throw ManagedAIError.invalidToken }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query; request[kSecValueData as String] = data; request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw ManagedAIError.keychain }
        } else if status != errSecSuccess { throw ManagedAIError.keychain }
    }
    func delete() throws {
        try requireCredentialAccess()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagedAIError.keychain }
    }
}
enum ManagedAIError: AIUserFacingError {
    case invalidEndpoint, invalidToken, keychain, notSignedIn, sessionExpired, deviceAlreadyConnected
    var aiMessage: String {
        switch self {
        case .invalidEndpoint: return "AI 服务配置不可用，请联系支持。"
        case .invalidToken, .keychain: return "无法读取服务连接信息，请检查钥匙串权限。"
        case .notSignedIn: return "服务连接尚未完成，请检查网络后重试。"
        case .sessionExpired: return "服务连接已失效，请稍后重试。"
        case .deviceAlreadyConnected: return "此设备已连接服务，无需再保存服务凭证。"
        }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ManagedAIClient {
    let endpoint: URL
    let session: URLSession
    let tokenLoader: () throws -> String?
    init(endpoint: URL, tokenLoader: @escaping () throws -> String? = { try ManagedAIAccountToken().load() }, allowLoopbackForTesting: Bool = false, networkPolicy: RuntimeCredentialPolicy = .current) throws {
        do { try networkPolicy.requireNetwork() } catch { throw ManagedAIError.invalidEndpoint }
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), components.user == nil, components.password == nil, components.fragment == nil, components.query == nil, let host = components.host, !host.isEmpty else { throw ManagedAIError.invalidEndpoint }
        let loopback = host == "127.0.0.1" || host == "::1"
        #if !DEBUG
        guard !allowLoopbackForTesting else { throw ManagedAIError.invalidEndpoint }
        #endif
        guard components.scheme == "https" || (allowLoopbackForTesting && components.scheme == "http" && loopback) else { throw ManagedAIError.invalidEndpoint }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        self.endpoint = endpoint
        self.session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        self.tokenLoader = tokenLoader
    }
    func provider() -> DeepSeekProvider {
        var provider = DeepSeekProvider(session: session, endpoint: endpoint, keyLoader: {
            guard let token = try tokenLoader(), !token.isEmpty else { throw ManagedAIError.notSignedIn }
            return token
        })
        if Bundle.main.object(forInfoDictionaryKey: "MORIQSharedSessionLeasesEnabled") as? Bool == true,
           let value = Bundle.main.object(forInfoDictionaryKey: "MORIQDeviceActivationEndpoint") as? String,
           let renewalEndpoint = URL(string: value) {
            provider.managedLease = {
                try RuntimeCredentialPolicy.current.requireAccess()
                let anonymousEnabled = Bundle.main.object(forInfoDictionaryKey: "MORIQAnonymousDeviceEnabled") as? Bool == true
                if try DeviceRenewalKeychain().load() == nil && !anonymousEnabled {
                    guard let token = try tokenLoader(), !token.isEmpty else { throw ManagedAIError.notSignedIn }
                    return (token, {})
                }
                let lease = try await DeviceRenewalCoordinator.shared.acquire(endpoint: renewalEndpoint, autoActivateAnonymous: anonymousEnabled)
                return (lease.token, { await DeviceRenewalCoordinator.shared.release(lease) })
            }
        }
        provider.unauthorizedError = { ManagedAIError.sessionExpired }
        provider.maxMessages = 200
        provider.maxTextBytes = 250_000
        provider.maxImagesPerMessage = 11
        provider.maxImageCount = 22
        provider.sendsOperationID = true
        return provider
    }
}

/// Service routing is explicit at build time. A broken configured service never
/// silently falls back to a different provider or transmits to a guessed URL.
enum AIServiceRouter {
    static func provider() -> DeepSeekProvider {
        provider(configuredValue: Bundle.main.object(forInfoDictionaryKey: "MORIQManagedAIEndpoint"))
    }
    static func provider(configuredValue: Any?, tokenLoader: @escaping () throws -> String? = { try ManagedAIAccountToken().load() }, allowLoopbackForTesting: Bool = false) -> DeepSeekProvider {
        guard let configuredValue else { return DeepSeekProvider() }
        guard let value = configuredValue as? String, let endpoint = URL(string: value),
              let client = try? ManagedAIClient(endpoint: endpoint, tokenLoader: tokenLoader, allowLoopbackForTesting: allowLoopbackForTesting) else {
            return DeepSeekProvider(endpoint: URL(string: "https://invalid.invalid")!, keyLoader: { throw ManagedAIError.invalidEndpoint })
        }
        return client.provider()
    }
}
