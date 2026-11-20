import Foundation

final class MemoryStore: DeviceRenewalStore {
    var state: DeviceRenewalState?
    init(_ state: DeviceRenewalState? = nil) { self.state = state }
    func load() throws -> DeviceRenewalState? { state }
    func save(_ state: DeviceRenewalState) throws { self.state = state }
}

@main struct Test {
    static func main() async throws {
        let empty = MemoryStore()
        let activate = DeviceRenewalCoordinator(store: empty)
        let invitation = String(repeating: "i", count: 43)
        let prepared = try await activate.prepareActivation(invite: invitation)
        let reopened = DeviceRenewalCoordinator(store: empty)
        let retry = try await reopened.prepareActivation(invite: invitation)
        precondition(prepared == retry && prepared.device != prepared.access)
        do { _ = try await reopened.prepare(speechActive: false); fatalError("unconfirmed activation allowed renewal") } catch {}
        try await reopened.activationCommitted()
        precondition(empty.state?.pendingInvite == nil)
        let store = MemoryStore(DeviceRenewalState(device: String(repeating: "d", count: 64), access: String(repeating: "a", count: 64), generation: 0))
        let first = DeviceRenewalCoordinator(store: store)
        let deferred = try await first.prepare(speechActive: true)
        precondition(deferred == nil)
        guard let pending = try await first.prepare(speechActive: false) else { fatalError("missing pending") }
        precondition(store.state?.access == String(repeating: "a", count: 64))
        let restarted = DeviceRenewalCoordinator(store: store)
        let recovered = try await restarted.prepare(speechActive: false)
        let active = try await restarted.prepare(speechActive: true)
        precondition(recovered == pending)
        precondition(active == nil)
        try await restarted.committed(pending)
        precondition(store.state?.access == pending.access && store.state?.generation == 1 && store.state?.pending == nil)
        guard let state = store.state, let renewedAt = state.renewedAt, let renewAfter = state.renewAfter else { fatalError("missing timestamps") }
        precondition(!state.needsRenewal(now: renewedAt))
        precondition(state.needsRenewal(now: renewedAt.addingTimeInterval(-1)))
        precondition(state.needsRenewal(now: renewAfter))
        print("PASS pending recovery and active speech deferral")
    }
}
