/// Isolated caption tests do not read the user's account or keychain.
struct ManagedAIAccountToken { func load() throws -> String? { nil } }
