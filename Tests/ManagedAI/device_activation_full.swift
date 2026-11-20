import Foundation
final class MemoryStore: DeviceRenewalStore {
    var state: DeviceRenewalState?
    func load() throws -> DeviceRenewalState? { state }
    func save(_ state: DeviceRenewalState) throws { self.state = state }
}
@main struct Test {
    static func main() async throws {
        let store = MemoryStore()
        let transport = try DeviceRenewalTransport(endpoint: URL(string: CommandLine.arguments[1])!, allowLoopback: true)
        let client = DeviceRenewalCoordinator(store: store)
        try await client.activate(invite: CommandLine.arguments[2], using: transport)
        let result = try await client.renew(using: transport, speechActive: false)
        precondition(result && store.state?.generation == 1 && store.state?.pending == nil)
        // Synthetic test credential is sent only to the local test harness.
        guard let token = store.state?.access, let url = URL(string: CommandLine.arguments[3]) else { fatalError("missing state") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data(token.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 204)
        print("PASS activation and renewal through candidate HTTP server")
    }
}
