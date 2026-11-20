import Foundation

final class MemoryStore: DeviceRenewalStore {
    var state = DeviceRenewalState(device: String(repeating: "d", count: 64), access: String(repeating: "a", count: 64), generation: 0)
    func load() throws -> DeviceRenewalState? { state }
    func save(_ state: DeviceRenewalState) throws { self.state = state }
}

@main struct Test {
    static func main() async throws {
        let store = MemoryStore()
        let transport = try DeviceRenewalTransport(endpoint: URL(string: CommandLine.arguments[1])!, allowLoopback: true)
        let first = DeviceRenewalCoordinator(store: store)
        do { _ = try await first.renew(using: transport, speechActive: false); fatalError("expected failure") } catch {}
        guard let pending = store.state.pending else { fatalError("pending lost") }
        precondition(store.state.generation == 0)
        let restarted = DeviceRenewalCoordinator(store: store)
        let success = try await restarted.renew(using: transport, speechActive: false)
        precondition(success && store.state.pending == nil && store.state.access == pending.access && store.state.generation == 1)
        print("PASS HTTP retry after failed response")
    }
}
