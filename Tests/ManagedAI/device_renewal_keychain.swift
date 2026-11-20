import Foundation

@main struct Test {
    static func main() async throws {
        let name = "local.moriq.test.renewal." + UUID().uuidString
        let store = DeviceRenewalKeychain(service: name)
        defer { try? store.delete() }
        let identity = DeviceRenewalState(device: String(repeating: "d", count: 64), access: String(repeating: "a", count: 64), generation: 0)
        try store.save(identity)
        let first = DeviceRenewalCoordinator(store: store)
        guard let pending = try await first.prepare(speechActive: false) else { fatalError("missing pending") }
        let restoredStore = DeviceRenewalKeychain(service: name)
        let restarted = DeviceRenewalCoordinator(store: restoredStore)
        let recovered = try await restarted.prepare(speechActive: false)
        precondition(recovered == pending)
        try await restarted.committed(pending)
        let updated = try restoredStore.load()
        precondition(updated?.access == pending.access && updated?.generation == 1 && updated?.pending == nil)
        try store.delete()
        let deleted = try store.load()
        precondition(deleted == nil)
        print("PASS isolated real keychain persistence and cleanup")
    }
}
