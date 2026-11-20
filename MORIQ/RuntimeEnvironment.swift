import Foundation
import Darwin

/// Values are explicit and do not inspect or read user data while resolving.
struct RuntimeEnvironment: Equatable {
    private static let internalSessionDefaults = "local.moriq.internal.synthetic." + UUID().uuidString.lowercased()
    enum Mode: Equatable { case product, internalIsolated }
    enum Capability: String { case realCredentials, systemClipboard, automaticFeatures, systemPermissions, realNetwork }
    enum ResolutionError: Error { case invalidConfiguration }
    enum ScratchError: Error { case invalidBase, creationFailed }
    let mode: Mode
    let supportDirectoryName: String
    let keychainPrefix: String
    let defaultsDomain: String

    static func resolve(bundleID: String, flavor: String?) throws -> Self {
        if flavor == nil && !bundleID.isEmpty && !bundleID.hasPrefix("local.moriq.internal") {
            return .init(mode: .product, supportDirectoryName: "MORIQ", keychainPrefix: "local.moriq", defaultsDomain: bundleID)
        }
        if flavor == "internal-isolated-v1" && bundleID == "local.moriq.internal" {
            return .init(mode: .internalIsolated, supportDirectoryName: "MORIQ-Internal", keychainPrefix: "local.moriq.internal", defaultsDomain: "local.moriq.internal")
        }
        throw ResolutionError.invalidConfiguration
    }
    func permits(_ capability: Capability, recordRefusal: (String) -> Void) -> Bool {
        if mode == .product { return true }
        recordRefusal("Internal mode refused capability: \(capability.rawValue)")
        return false
    }
    func defaults() -> UserDefaults? {
        switch mode {
        case .product: return .standard
        case .internalIsolated: return UserDefaults(suiteName: Self.internalSessionDefaults)
        }
    }
    func discardSyntheticDefaults() {
        guard mode == .internalIsolated, let defaults = UserDefaults(suiteName: Self.internalSessionDefaults) else { return }
        defaults.removePersistentDomain(forName: Self.internalSessionDefaults)
    }
    func supportDirectory(base: URL) -> URL {
        base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }
    /// Creates a fresh private directory, never follows a symlink at the
    /// supplied base or accepts an existing leaf. Internal tests keep the
    /// directory separate from all persistent product data.
    func createSyntheticDirectory(base: URL) throws -> URL {
        guard mode == .internalIsolated, base.isFileURL else { throw ScratchError.invalidBase }
        let descriptor = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ScratchError.invalidBase }
        defer { close(descriptor) }
        let leaf = "moriq-internal-" + UUID().uuidString.lowercased()
        guard mkdirat(descriptor, leaf, 0o700) == 0 else { throw ScratchError.creationFailed }
        let child = openat(descriptor, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw ScratchError.creationFailed }
        defer { close(child) }
        var statData = stat()
        guard fstat(child, &statData) == 0, (statData.st_mode & S_IFMT) == S_IFDIR,
              (statData.st_mode & 0o077) == 0, statData.st_uid == getuid() else { throw ScratchError.creationFailed }
        return base.appendingPathComponent(leaf, isDirectory: true)
    }
    static let internalScratch: Result<URL, Error> = Result {
        let env = try resolve(bundleID: "local.moriq.internal", flavor: "internal-isolated-v1")
        return try env.createSyntheticDirectory(base: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
    }
    func keychainService(_ suffix: String) -> String { "\(keychainPrefix).\(suffix)" }
    static func permitsCurrent(_ capability: Capability, bundle: Bundle = .main) -> Bool {
        let rawFlavor = bundle.object(forInfoDictionaryKey: "MORIQBuildFlavor")
        guard rawFlavor == nil || rawFlavor is String,
              let environment = try? resolve(bundleID: bundle.bundleIdentifier ?? "", flavor: rawFlavor as? String) else {
            FileHandle.standardError.write(Data("MORIQ runtime refused invalid capability configuration\n".utf8))
            return false
        }
        return environment.permits(capability) { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }
    /// Internal startup is fail-closed until every product dependency actually
    /// consumes this environment. Never silently fall back to product state.
    static func requireSafeProcess(bundle: Bundle = .main, recordRefusal: (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }) -> Self {
        let rawFlavor = bundle.object(forInfoDictionaryKey: "MORIQBuildFlavor")
        guard rawFlavor == nil || rawFlavor is String,
              let env = try? resolve(bundleID: bundle.bundleIdentifier ?? "", flavor: rawFlavor as? String) else {
            recordRefusal("MORIQ runtime refused invalid bundle configuration")
            exit(78)
        }
        #if MORIQ_INTERNAL_SMOKE
        let args = Array(CommandLine.arguments.dropFirst())
        let basic = args == ["--moriq-internal-smoke"]
        let fakeCaption = args.count == 3 && args[0] == "--moriq-internal-smoke"
            && args[1] == "--moriq-fake-caption-port" && UInt16(args[2]).map({ $0 > 0 }) == true
        if env.mode == .internalIsolated && (basic || fakeCaption) { return env }
        #endif
        guard env.mode == .product else {
            recordRefusal("MORIQ Internal startup refused: dependency isolation is incomplete")
            exit(78)
        }
        return env
    }
}
