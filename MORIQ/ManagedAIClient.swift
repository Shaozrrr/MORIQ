import Foundation
import Security

/// Reference integration for a future account system; no provider secret is stored here.
struct ManagedAIAccountToken {
    let service = "local.moriq.managed-ai.account"
    let account = "session-token"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func load() throws -> String? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else { throw ManagedAIError.keychain }
        return token
    }
    func save(_ token: String) throws {
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }), let data = token.data(using: .utf8) else { throw ManagedAIError.invalidToken }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query; request[kSecValueData as String] = data; request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw ManagedAIError.keychain }
        } else if status != errSecSuccess { throw ManagedAIError.keychain }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagedAIError.keychain }
    }
}
enum ManagedAIError: AIUserFacingError {
    case invalidEndpoint, invalidToken, keychain, notSignedIn, sessionExpired
    var aiMessage: String {
        switch self {
        case .invalidEndpoint: return "AI 服务配置不可用，请联系支持。"
        case .invalidToken, .keychain: return "无法读取账户凭据，请重新登录。"
        case .notSignedIn: return "请先登录 MORIQ 账户。"
        case .sessionExpired: return "登录已过期，请重新登录。"
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
    init(endpoint: URL, tokenLoader: @escaping () throws -> String? = { try ManagedAIAccountToken().load() }, allowLoopbackForTesting: Bool = false) throws {
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
        provider.unauthorizedError = { ManagedAIError.sessionExpired }
        provider.maxMessages = 200
        provider.maxTextBytes = 250_000
        provider.maxImagesPerMessage = 11
        provider.maxImageCount = 22
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
