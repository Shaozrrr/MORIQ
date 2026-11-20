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
        let invite = CommandLine.arguments[2]
        let first = DeviceRenewalCoordinator(store: store)
        do { try await first.activate(invite: invite, using: transport); fatalError("expected disconnect") } catch {}
        guard let saved = store.state, saved.pendingInvite != nil else { fatalError("activation not persisted") }
        let restarted = DeviceRenewalCoordinator(store: store)
        try await restarted.activate(invite: invite, using: transport)
        precondition(store.state?.pendingInvite == nil && store.state?.device == saved.device && store.state?.access == saved.access)
        print("PASS activation lost-response retry")
    }
}
