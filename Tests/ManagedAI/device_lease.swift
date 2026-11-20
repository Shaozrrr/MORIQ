import Foundation
final class MemoryStore: DeviceRenewalStore {
    var state: DeviceRenewalState?
    func load() throws -> DeviceRenewalState? { state }
    func save(_ state: DeviceRenewalState) throws { self.state = state }
}
@main struct Test {
    static func main() async throws {
        let store = MemoryStore()
        let endpoint = URL(string: CommandLine.arguments[1])!
        let coordinator = DeviceRenewalCoordinator(store: store)
        let transport = try DeviceRenewalTransport(endpoint: endpoint, allowLoopback: true)
        try await coordinator.activate(invite: CommandLine.arguments[2], using: transport)
        let first = try await coordinator.acquire(endpoint: endpoint, allowLoopbackForTesting: true)
        let assistant = try await coordinator.acquire(endpoint: endpoint, allowLoopbackForTesting: true)
        precondition(first.token == assistant.token)
        guard var state = store.state else { fatalError("missing state") }
        state.renewAfter = Date().addingTimeInterval(-1); try store.save(state)
        let cancelled = Task { try await coordinator.acquire(endpoint: endpoint, allowLoopbackForTesting: true) }
        let waiting = Task { try await coordinator.acquire(endpoint: endpoint, allowLoopbackForTesting: true) }
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(store.state?.generation == 0)
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled acquire succeeded") } catch is CancellationError {}
        await coordinator.release(first)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(store.state?.generation == 0)
        let waiting2 = Task { try await coordinator.acquire(endpoint: endpoint, allowLoopbackForTesting: true) }
        await coordinator.release(assistant)
        let second = try await waiting.value
        let third = try await waiting2.value
        precondition(store.state?.generation == 1 && second.token != first.token)
        precondition(third.token == second.token)
        await coordinator.release(second)
        await coordinator.release(third)
        print("PASS concurrent leases, cancellation and single renewal")
    }
}
