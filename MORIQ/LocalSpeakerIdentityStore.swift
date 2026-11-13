import Foundation
import Security

/// Explicitly enrolled identities only. This storage layer performs no matching.
/// Keep one owner per Keychain item: actor isolation does not coordinate processes.
protocol SpeakerIdentityVault {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

enum SpeakerIdentityStoreError: Error, Equatable {
    case invalidName, invalidModel, invalidVector, duplicateID, missingIdentity, incompatibleData
    case keychain(OSStatus)
}

/// A dedicated generic-password item. No existing Keychain entries are enumerated.
struct KeychainSpeakerIdentityVault: SpeakerIdentityVault {
    let service: String
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SpeakerIdentityStoreError.keychain(status) }
        guard let data = result as? Data else { throw SpeakerIdentityStoreError.incompatibleData }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SpeakerIdentityStoreError.keychain(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SpeakerIdentityStoreError.keychain(added) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpeakerIdentityStoreError.keychain(status)
        }
    }
}

struct SpeakerVoiceModel: Codable, Equatable {
    let identifier: String
    /// A fixed model artifact hash/version, not a moving alias such as latest.
    let version: String
    let dimension: Int
}

struct EnrolledSpeaker: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let model: SpeakerVoiceModel
    let embedding: [Float]
}

private struct SpeakerIdentityArchive: Codable {
    let schema: Int
    var identities: [EnrolledSpeaker]
}

actor LocalSpeakerIdentityStore {
    private let vault: any SpeakerIdentityVault
    private static let maxIdentities = 500
    init(vault: any SpeakerIdentityVault) { self.vault = vault }

    func all() throws -> [EnrolledSpeaker] { try load().identities }

    /// Registration requires an explicit name and externally generated model embedding.
    func enroll(name: String, model: SpeakerVoiceModel, embedding: [Float]) throws -> UUID {
        let clean = try Self.validateName(name)
        try Self.validateModelAndEmbedding(model, embedding)
        var archive = try load()
        guard archive.identities.count < Self.maxIdentities else { throw SpeakerIdentityStoreError.incompatibleData }
        let id = UUID()
        archive.identities.append(EnrolledSpeaker(id: id, name: clean, model: model, embedding: embedding))
        try save(archive)
        return id
    }

    func rename(id: UUID, name: String) throws {
        let clean = try Self.validateName(name)
        var archive = try load()
        guard let index = archive.identities.firstIndex(where: { $0.id == id }) else { throw SpeakerIdentityStoreError.missingIdentity }
        archive.identities[index].name = clean
        try save(archive)
    }

    func remove(id: UUID) throws {
        var archive = try load()
        guard let index = archive.identities.firstIndex(where: { $0.id == id }) else { throw SpeakerIdentityStoreError.missingIdentity }
        archive.identities.remove(at: index)
        if archive.identities.isEmpty { try vault.delete() } else { try save(archive) }
    }

    func removeAll() throws { try vault.delete() }

    private func load() throws -> SpeakerIdentityArchive {
        guard let data = try vault.read() else { return SpeakerIdentityArchive(schema: 1, identities: []) }
        guard data.count <= 16_000_000, let archive = try? JSONDecoder().decode(SpeakerIdentityArchive.self, from: data),
              archive.schema == 1, archive.identities.count <= Self.maxIdentities else { throw SpeakerIdentityStoreError.incompatibleData }
        var ids = Set<UUID>()
        for item in archive.identities {
            guard ids.insert(item.id).inserted else { throw SpeakerIdentityStoreError.duplicateID }
            guard (try? Self.validateName(item.name)) == item.name else { throw SpeakerIdentityStoreError.incompatibleData }
            do { try Self.validateModelAndEmbedding(item.model, item.embedding) }
            catch { throw SpeakerIdentityStoreError.incompatibleData }
        }
        return archive
    }

    private func save(_ archive: SpeakerIdentityArchive) throws {
        try vault.write(JSONEncoder().encode(archive))
    }

    private static func validateName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw SpeakerIdentityStoreError.invalidName }
        return value
    }

    private static func validateModelAndEmbedding(_ model: SpeakerVoiceModel, _ vector: [Float]) throws {
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 128 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard valid(model.identifier), valid(model.version), model.version.lowercased() != "latest",
              (1...4096).contains(model.dimension) else { throw SpeakerIdentityStoreError.invalidModel }
        guard vector.count == model.dimension, vector.allSatisfy({ $0.isFinite }),
              vector.contains(where: { $0 != 0 }) else { throw SpeakerIdentityStoreError.invalidVector }
    }
}
