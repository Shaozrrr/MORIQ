import Foundation

final class FakeVault: SpeakerIdentityVault {
    var data: Data?
    var failWrites = false
    func read() throws -> Data? { data }
    func write(_ newData: Data) throws { if failWrites { throw SpeakerIdentityStoreError.keychain(-1) }; data = newData }
    func delete() throws { if failWrites { throw SpeakerIdentityStoreError.keychain(-1) }; data = nil }
}

@main struct Check {
    static func main() async throws {
        let vault = FakeVault()
        let store = LocalSpeakerIdentityStore(vault: vault)
        let model = SpeakerVoiceModel(identifier: "campplus", version: "sha256:abc", dimension: 3)
        let id = try await store.enroll(name: "  小王  ", model: model, embedding: [0.2, 0.3, 0.4])
        var list = try await store.all()
        precondition(list.count == 1 && list[0].name == "小王" && list[0].model == model)
        try await store.rename(id: id, name: "小李")
        let fresh = LocalSpeakerIdentityStore(vault: vault)
        list = try await fresh.all()
        precondition(list.first?.name == "小李")
        do { _ = try await store.enroll(name: "", model: model, embedding: [1, 0, 0]); fatalError("empty name") } catch SpeakerIdentityStoreError.invalidName { }
        do { _ = try await store.enroll(name: "A", model: model, embedding: [0, 0, 0]); fatalError("zero vector") } catch SpeakerIdentityStoreError.invalidVector { }
        do { _ = try await store.enroll(name: "A", model: model, embedding: [.nan, 0, 1]); fatalError("nonfinite") } catch SpeakerIdentityStoreError.invalidVector { }
        do { _ = try await store.enroll(name: "A", model: SpeakerVoiceModel(identifier: "x", version: "latest", dimension: 3), embedding: [1, 0, 0]); fatalError("unfixed model") } catch SpeakerIdentityStoreError.invalidModel { }
        vault.failWrites = true
        do { try await store.remove(id: id); fatalError("ignored vault failure") } catch SpeakerIdentityStoreError.keychain { }
        list = try await store.all()
        precondition(list.count == 1)
        vault.failWrites = false
        try await store.remove(id: id)
        precondition(vault.data == nil)
        vault.data = Data("broken".utf8)
        do { _ = try await store.all(); fatalError("corruption ignored") } catch SpeakerIdentityStoreError.incompatibleData { }
        print("isolated identity vault checks passed")
    }
}
