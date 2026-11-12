import AppKit
import SwiftUI
import Carbon
import CryptoKit
import Security
import LocalAuthentication
import ImageIO

struct ClipboardEntry: Identifiable, Codable {
    let id: UUID
    let created: Date
    let source: String
    let items: [[String: Data]]
    var text: String? {
        guard let data = items.first?[NSPasteboard.PasteboardType.string.rawValue] else { return nil }
        return String(data: data, encoding: .utf8)
    }
    var fileNames: [String] {
        items.compactMap { item in
            guard let data = item[NSPasteboard.PasteboardType.fileURL.rawValue],
                  let raw = String(data: data, encoding: .utf8), let url = URL(string: raw), url.isFileURL else { return nil }
            return url.lastPathComponent
        }
    }
    var imageData: Data? {
        guard let item = items.first else { return nil }
        for type in [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue, "public.jpeg", "public.heic", "org.webmproject.webp", "com.compuserve.gif"] {
            if let data = item[type] { return data }
        }
        return nil
    }
    var summary: String {
        if !fileNames.isEmpty { return fileNames.joined(separator: "、") }
        if let text, !text.isEmpty { return text }
        if imageData != nil { return "图片" }
        if items.contains(where: { $0["com.adobe.pdf"] != nil }) { return "PDF 内容" }
        return "复制的内容"
    }
}

enum ClipboardCipher {
    static func seal(_ data: Data, using key: SymmetricKey) throws -> Data {
        guard let result = try AES.GCM.seal(data, using: key).combined else { throw CipherError.unavailable }
        return result
    }
    static func open(_ data: Data, using key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
    private enum CipherError: Error { case unavailable }
}

protocol ClipboardBackingStore {
    func load() throws -> [ClipboardEntry]
    func loadSilently() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
    func clear() throws
}
extension ClipboardBackingStore {
    func loadSilently() throws -> [ClipboardEntry] { try load() }
}

private final class ClipboardWriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}
private final class ClipboardLoadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[ClipboardEntry], Error>?
    func set(_ result: Result<[ClipboardEntry], Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<[ClipboardEntry], Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

struct ClipboardVault: ClipboardBackingStore {
    // The macOS legacy Keychain backend can deadlock when several threads
    // concurrently search and create the same item in one process.
    private static let keyAccessLock = NSLock()
    private let service: String
    private let overrideDirectory: URL?
    private let testNoninteractive: Bool
    init() { service = "local.moriq.clipboard-key"; overrideDirectory = nil; testNoninteractive = false }
    #if DEBUG
    init(testService: String, directory: URL) { service = testService; overrideDirectory = directory; testNoninteractive = true }
    #endif
    private var baseQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "history"] }
    private func key(createIfMissing: Bool, interactive: Bool = true) throws -> SymmetricKey {
        Self.keyAccessLock.lock(); defer { Self.keyAccessLock.unlock() }
        var query = baseQuery
        if !interactive || testNoninteractive {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data, data.count == 32 { return SymmetricKey(data: data) }
        // A history file without its key must stay untouched. Creating a new
        // key here would mask the missing original and prevent later recovery.
        guard status == errSecItemNotFound, createIfMissing else { throw VaultError.unavailable }
        let created = SymmetricKey(size: .bits256)
        let bytes = created.withUnsafeBytes { Data($0) }
        var add = baseQuery; add[kSecValueData as String] = bytes; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return created }
        // Another instance may have created the same key between lookup and add.
        if addStatus == errSecDuplicateItem {
            var existing: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess,
               let data = existing as? Data, data.count == 32 { return SymmetricKey(data: data) }
        }
        throw VaultError.unavailable
    }
    private func url() throws -> URL {
        let folder: URL
        if let overrideDirectory { folder = overrideDirectory }
        else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            folder = base.appendingPathComponent("MORIQ", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent("clipboard-history.enc")
    }
    func load() throws -> [ClipboardEntry] {
        try load(interactive: true)
    }
    func loadSilently() throws -> [ClipboardEntry] {
        try load(interactive: false)
    }
    private func load(interactive: Bool) throws -> [ClipboardEntry] {
        let file = try url()
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decrypted = try ClipboardCipher.open(Data(contentsOf: file), using: key(createIfMissing: false, interactive: interactive))
        return try JSONDecoder().decode([ClipboardEntry].self, from: decrypted)
    }
    func save(_ entries: [ClipboardEntry]) throws {
        let file = try url()
        let data = try JSONEncoder().encode(entries)
        let sealed = try ClipboardCipher.seal(data, using: key(createIfMissing: true))
        try sealed.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func clear() throws {
        let file = try url()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private enum VaultError: Error { case unavailable }
}

private struct ClipboardCaptureResult: Sendable {
    let items: [[String: Data]]
    let source: String
    let created: Date
    let warning: String?
    let epoch: UUID
}
private final class ClipboardCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ClipboardCaptureResult] = []
    private var pending = 0
    func reserve() -> Bool { lock.lock(); defer { lock.unlock() }; guard pending < 100 else { return false }; pending += 1; return true }
    func append(_ result: ClipboardCaptureResult) { lock.lock(); pending -= 1; values.append(result); lock.unlock() }
    func drain() -> [ClipboardCaptureResult] { lock.lock(); defer { lock.unlock() }; let result = values; values.removeAll(); return result }
}

@MainActor final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardEntry] = []
    @Published private(set) var encryptedStorage = false
    @Published private(set) var persistenceLocked = false
    @Published private(set) var recovering = false
    @Published private(set) var favorites: Set<UUID> = []
    @Published private(set) var copyError: String?
    @Published private(set) var captureWarning: String?
    private var timer: Timer?
    private var lastCount: Int
    private let board: NSPasteboard
    private let persistent: Bool
    private let captureQueue = DispatchQueue(label: "local.moriq.clipboard.capture", qos: .utility)
    private let captureBuffer = ClipboardCaptureBuffer()
    private var captureEpoch = UUID()
    private var shutdownEpoch = UUID()
    private let vault: any ClipboardBackingStore
    private let defaults: UserDefaults
    private let writeQueue = DispatchQueue(label: "local.moriq.clipboard.storage", qos: .utility)
    private var pendingSnapshot: [ClipboardEntry]?
    private var writeScheduled = false
    private var writeInFlight = false
    private var writeID = UUID()
    private var writeOutcome: ClipboardWriteOutcome?
    private var activeSnapshot: [ClipboardEntry]?
    private var scheduleEpoch = UUID()
    private var retryDelay: TimeInterval = 0.5
    private var loaded = false
    private var recoveryEpoch = UUID()
    private var recoveryOutcome: ClipboardLoadOutcome?
    private var nextAutomaticRecovery = Date.distantFuture
    private var recoveryDelay: TimeInterval = 5
    private var clearedHistoryWhileLocked = false
    private var removedWhileLocked: [[[String: Data]]] = []
    private let favoritesKey = "moriq.clipboard.favoriteIDs"
    init(board: NSPasteboard = .general, persistent: Bool = true, vault: any ClipboardBackingStore = ClipboardVault(), defaults: UserDefaults = .standard) {
        self.board = board; self.persistent = persistent; self.vault = vault; self.defaults = defaults; self.lastCount = board.changeCount
    }
    func start(initialLoadSynchronously: Bool = false) {
        guard timer == nil else { return }
        captureWarning = nil
        if !loaded && persistent {
            favorites = Set((defaults.stringArray(forKey: favoritesKey) ?? []).compactMap(UUID.init(uuidString:)))
            loaded = true
            if initialLoadSynchronously {
                do { items = try vault.load(); encryptedStorage = true; persistenceLocked = false }
                catch { encryptedStorage = false; persistenceLocked = true; nextAutomaticRecovery = Date().addingTimeInterval(recoveryDelay) }
            } else {
            // Treat startup as a recovery so fresh clipboard changes cannot
            // overwrite the encrypted history while it is being read.
                persistenceLocked = true
                recover()
            }
        }
        lastCount = board.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.poll()
            if self.persistenceLocked && !self.recovering && Date() >= self.nextAutomaticRecovery { self.recover(silent: true) }
        } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; captureEpoch = UUID(); captureWarning = nil }
    func dismissCaptureWarning() { captureWarning = nil }
    /// Used only when the process is about to exit: let queued encrypted writes finish.
    func flushPendingWrites() {
        guard persistent else { return }
        scheduleEpoch = UUID(); writeScheduled = false
        let snapshot = pendingSnapshot, outcome = writeOutcome, active = activeSnapshot
        pendingSnapshot = nil; writeID = UUID(); writeInFlight = false; writeOutcome = nil; activeSnapshot = nil
        if let snapshot {
            let vault = self.vault
            let success = writeQueue.sync { (try? vault.save(snapshot)) != nil }
            encryptedStorage = success
            if success { retryDelay = 0.5 }
            else { pendingSnapshot = snapshot; scheduleRetry() }
        } else {
            writeQueue.sync {}
            if let result = outcome?.get() {
                encryptedStorage = result
                if result { retryDelay = 0.5 }
                else if let active { pendingSnapshot = active; scheduleRetry() }
            }
        }
    }
    /// Defers process termination without blocking the main run loop, which
    /// may be needed by an in-process pasteboard data provider.
    func prepareShutdown(timeout: TimeInterval = 5, completion: @escaping (Bool) -> Void) {
        let epoch = UUID(); shutdownEpoch = epoch
        let wasRunning = timer != nil
        if wasRunning { poll() }
        timer?.invalidate(); timer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.shutdownEpoch == epoch else { return }
            self.shutdownEpoch = UUID()
            if wasRunning { self.start() }
            self.captureWarning = "剪贴板保存超时，已取消退出，请重试。"
            completion(false)
        }
        captureQueue.async { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.shutdownEpoch == epoch else { return }
                self.drainCaptures()
                guard !self.persistenceLocked else {
                    self.shutdownEpoch = UUID(); if wasRunning { self.start() }; self.captureWarning = "剪贴板记录暂时无法保存，已取消退出。"; completion(false); return
                }
                guard self.persistent && self.loaded else { self.shutdownEpoch = UUID(); completion(true); return }
                self.scheduleEpoch = UUID(); self.writeScheduled = false
                self.pendingSnapshot = nil; self.writeID = UUID(); self.writeInFlight = false
                self.writeOutcome = nil; self.activeSnapshot = nil
                let snapshot = self.items, vault = self.vault
                self.writeQueue.async {
                    let saved = (try? vault.save(snapshot)) != nil
                    DispatchQueue.main.async {
                        guard self.shutdownEpoch == epoch else { return }
                        self.shutdownEpoch = UUID()
                        self.encryptedStorage = saved
                        if !saved { self.pendingSnapshot = snapshot; self.scheduleRetry(); if wasRunning { self.start() }; self.captureWarning = "剪贴板保存失败，已取消退出，请重试。" }
                        completion(saved)
                    }
                }
            }
        }
    }
    func shutdown() {
        if timer != nil { poll() }
        // Never wait for a promised pasteboard representation here: its
        // provider may require the main thread to finish the request.
        drainCaptures()
        stop()
        if recovering, let outcome = recoveryOutcome {
            let epoch = recoveryEpoch
            writeQueue.sync {}
            if let result = outcome.get() { finishRecovery(result, epoch: epoch) }
        }
        flushPendingWrites()
    }
    func clear() {
        captureWarning = nil
        captureEpoch = UUID()
        scheduleEpoch = UUID(); pendingSnapshot = nil; writeScheduled = false; writeID = UUID(); writeInFlight = false; writeOutcome = nil; activeSnapshot = nil; retryDelay = 0.5
        recoveryEpoch = UUID(); recovering = false; recoveryOutcome = nil; nextAutomaticRecovery = .distantFuture; recoveryDelay = 5; clearedHistoryWhileLocked = false; removedWhileLocked.removeAll()
        items.removeAll(); favorites.removeAll()
        if persistent { defaults.removeObject(forKey: favoritesKey) }
        guard persistent else { return }
        let vault = self.vault
        writeQueue.async {
            do {
                try vault.clear()
                Task { @MainActor in self.persistenceLocked = false; self.encryptedStorage = true; self.persist() }
            } catch { Task { @MainActor in self.encryptedStorage = false } }
        }
    }
    func clearHistory() {
        captureWarning = nil
        captureEpoch = UUID()
        if persistenceLocked { clearedHistoryWhileLocked = true }
        items.removeAll { !favorites.contains($0.id) }
        persist()
    }
    func remove(_ item: ClipboardEntry) {
        if persistenceLocked { removedWhileLocked.append(item.items) }
        items.removeAll { $0.id == item.id }; favorites.remove(item.id); saveFavorites(); persist()
    }
    func toggleFavorite(_ item: ClipboardEntry) {
        if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }
        saveFavorites()
    }
    private func saveFavorites() { if persistent { defaults.set(favorites.map(\.uuidString), forKey: favoritesKey) } }
    private func persist() {
        guard persistent else { return }
        guard !persistenceLocked else { encryptedStorage = false; return }
        pendingSnapshot = items
        schedulePendingWrite()
    }
    private func schedulePendingWrite(after delay: TimeInterval = 0.2) {
        guard pendingSnapshot != nil, !writeScheduled, !writeInFlight else { return }
        writeScheduled = true
        let epoch = scheduleEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.scheduleEpoch == epoch else { return }
            self.flushScheduledWrite()
        }
    }
    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        schedulePendingWrite(after: delay)
    }
    private func flushScheduledWrite() {
        writeScheduled = false
        guard !writeInFlight else { return }
        guard let snapshot = pendingSnapshot else { writeScheduled = false; return }
        pendingSnapshot = nil; writeInFlight = true; activeSnapshot = snapshot
        let id = UUID(); writeID = id
        let outcome = ClipboardWriteOutcome(); writeOutcome = outcome
        let vault = self.vault
        writeQueue.async {
            let success = (try? vault.save(snapshot)) != nil
            outcome.set(success)
            Task { @MainActor in
                guard self.writeID == id else { return }
                self.writeInFlight = false; self.writeOutcome = nil; self.activeSnapshot = nil; self.encryptedStorage = success
                if success {
                    self.retryDelay = 0.5; self.schedulePendingWrite()
                } else {
                    if self.pendingSnapshot == nil { self.pendingSnapshot = snapshot }
                    self.scheduleRetry()
                }
            }
        }
    }
    /// Merge memory-only copies with existing encrypted data after access returns.
    /// Failed loads never overwrite the existing file.
    func recover(silent: Bool = false) {
        guard persistent, persistenceLocked, !recovering else { return }
        recovering = true
        let epoch = recoveryEpoch, vault = self.vault
        let outcome = ClipboardLoadOutcome(); recoveryOutcome = outcome
        writeQueue.async {
            let result = Result { try silent ? vault.loadSilently() : vault.load() }
            outcome.set(result)
            Task { @MainActor in
                self.finishRecovery(result, epoch: epoch)
            }
        }
    }
    private func finishRecovery(_ result: Result<[ClipboardEntry], Error>, epoch: UUID) {
                guard self.recoveryEpoch == epoch, self.persistenceLocked, self.recovering else { return }
                self.recovering = false
                self.recoveryOutcome = nil
                guard case .success(let saved) = result else {
                    self.nextAutomaticRecovery = Date().addingTimeInterval(self.recoveryDelay)
                    self.recoveryDelay = min(60, self.recoveryDelay * 2)
                    return
                }
                let eligible = saved.filter { entry in
                    (!self.clearedHistoryWhileLocked || self.favorites.contains(entry.id)) &&
                    !self.removedWhileLocked.contains(where: { $0 == entry.items })
                }
                self.favorites.subtract(saved.filter { entry in self.removedWhileLocked.contains(where: { $0 == entry.items }) }.map(\.id))
                var merged: [ClipboardEntry] = []
                for current in self.items {
                    if let old = eligible.first(where: { $0.items == current.items }) {
                        if self.favorites.remove(current.id) != nil { self.favorites.insert(old.id) }
                        merged.append(ClipboardEntry(id: old.id, created: current.created, source: current.source, items: current.items))
                    } else { merged.append(current) }
                }
                merged.append(contentsOf: eligible.filter { old in !merged.contains(where: { $0.items == old.items }) })
                self.items = merged; self.trimHistory()
                self.clearedHistoryWhileLocked = false; self.removedWhileLocked.removeAll()
                self.persistenceLocked = false; self.encryptedStorage = true; self.nextAutomaticRecovery = .distantFuture; self.recoveryDelay = 5
                self.saveFavorites(); self.persist()
    }
    func poll(force: Bool = false) {
        guard force || board.changeCount != lastCount else { return }
        let change = board.changeCount; lastCount = change
        guard captureBuffer.reserve() else {
            captureWarning = "复制过快，部分内容未保存到历史，请重新复制。"
            return
        }
        let name = board.name.rawValue
        let app = NSWorkspace.shared.frontmostApplication
        let source = app?.localizedName ?? ""
        let bundle = app?.bundleIdentifier ?? ""
        let epoch = captureEpoch, buffer = captureBuffer
        captureQueue.async { [weak self] in
            let result = autoreleasepool { () -> ClipboardCaptureResult in
                let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
                var warning: String?
                var captured: [[String: Data]] = []
                func result(_ warning: String? = nil) -> ClipboardCaptureResult {
                    ClipboardCaptureResult(items: captured, source: source, created: Date(), warning: warning, epoch: epoch)
                }
                guard pasteboard.changeCount == change else { return result("复制内容已变化，部分记录未保存，请重新复制。") }
                let policy = ClipboardPolicy()
                guard policy.permits(types: pasteboard.types?.map(\.rawValue) ?? [], sourceBundle: bundle),
                      let sourceItems = pasteboard.pasteboardItems, !sourceItems.isEmpty else { return result() }
                guard sourceItems.count <= 50 else { return result("复制项目超过 50 项，未保存到历史。") }
                var total = 0
                for item in sourceItems {
                    guard policy.permits(types: item.types.map(\.rawValue), sourceBundle: bundle) else { captured.removeAll(); return result() }
                    var representations: [String: Data] = [:]
                    for type in item.types {
                        guard let data = item.data(forType: type) else {
                            if type.rawValue != "public.utf16-external-plain-text" || !item.types.contains(.string) {
                                warning = "部分复制格式暂时无法读取，已保存可读取的内容。"
                            }
                            continue
                        }
                        total += data.count
                        guard total <= 8_000_000 else { captured.removeAll(); return result("复制内容超过 8 MB，未保存到历史。") }
                        representations[type.rawValue] = data
                    }
                    if !representations.isEmpty { captured.append(representations) }
                }
                guard pasteboard.changeCount == change else { captured.removeAll(); return result("复制内容已变化，部分记录未保存，请重新复制。") }
                return result(warning)
            }
            buffer.append(result)
            DispatchQueue.main.async { self?.drainCaptures() }
        }
    }
    private func drainCaptures() {
        for result in captureBuffer.drain() where result.epoch == captureEpoch {
            if let warning = result.warning { captureWarning = warning }
            let captured = result.items
            guard !captured.isEmpty else { continue }
            if persistenceLocked { removedWhileLocked.removeAll { $0 == captured } }
            let existing = items.first { $0.items == captured }
            items.removeAll { $0.items == captured }
            items.insert(ClipboardEntry(id: existing?.id ?? UUID(), created: result.created, source: result.source, items: captured), at: 0)
            trimHistory(); persist()
        }
    }
    // Isolated tests only; normal polling and shutdown never wait for providers.
    func waitForCaptures() { captureQueue.sync {}; drainCaptures() }
    private func trimHistory() {
        // Favorites are permanent entries and do not consume the rolling history quota.
        while items.lazy.filter({ !self.favorites.contains($0.id) }).count > 100 {
            guard let index = items.indices.reversed().first(where: { !favorites.contains(items[$0].id) }) else { break }
            items.remove(at: index)
        }
        var historyBytes = items.filter { !favorites.contains($0.id) }.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }
        while historyBytes > 32_000_000 {
            guard let index = items.indices.reversed().first(where: { !favorites.contains(items[$0].id) }) else { break }
            let removed = items.remove(at: index)
            historyBytes -= removed.items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        }
    }
    @discardableResult func copy(_ item: ClipboardEntry, plain: Bool = false) -> Bool {
        let output: [NSPasteboardItem] = item.items.compactMap { values in
            let pasteboardItem = NSPasteboardItem()
            let filtered = plain ? values.filter { $0.key == NSPasteboard.PasteboardType.string.rawValue } :
                values
            guard !filtered.isEmpty else { return nil }
            for (type, data) in filtered { pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return pasteboardItem
        }
        guard !output.isEmpty else { copyError = "这条记录没有可复制的内容。"; return false }
        board.clearContents()
        let success = board.writeObjects(output)
        lastCount = board.changeCount
        copyError = success ? nil : "复制失败，请重试。"
        return success
    }
}
@MainActor final class ClipboardCoordinator {
    private let store: ClipboardStore
    init() { self.store = ClipboardStore() }
    init(store: ClipboardStore) { self.store = store }
    private var panel: ClipboardPanel?
    private var previousApp: NSRunningApplication?
    func enable() -> OSStatus {
        guard !GlobalShortcutRegistry.shared.isEnabled(.clipboard) else { return noErr }
        let result = GlobalShortcutRegistry.shared.enable(.clipboard) { [weak self] in self?.show() }
        if result == noErr { store.start() }
        return result
    }
    func disable() {
        store.stop(); panel?.orderOut(nil)
        GlobalShortcutRegistry.shared.disable(.clipboard)
    }
    func prepareShutdown(completion: @escaping (Bool) -> Void) { store.prepareShutdown(completion: completion) }
    func shutdown() { store.shutdown(); disable() }
    private func show() {
        guard GlobalShortcutRegistry.shared.isEnabled(.clipboard) else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if panel == nil {
            let window = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true; window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.dismiss = { [weak self] in self?.previousApp?.activate(options: []) }
            window.contentView = NSHostingView(rootView: ClipboardView(store: store, choose: { [weak window, weak self] entry, plain in
                guard let self, self.store.copy(entry, plain: plain) else { return }
                window?.orderOut(nil); self.previousApp?.activate(options: [])
            }))
            panel = window
        }
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let f = screen.visibleFrame; panel?.setFrameOrigin(NSPoint(x: min(max(point.x - 200, f.minX), f.maxX - 400), y: min(max(point.y - 170, f.minY), f.maxY - 340)))
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}
final class ClipboardPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil); dismiss?() }
}
struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    let choose: (ClipboardEntry, Bool) -> Void
    @State private var search = ""
    @State private var selected = 0
    @State private var showFavorites = false
    @FocusState private var focused: Bool
    var filtered: [ClipboardEntry] {
        let matches = search.isEmpty ? store.items : store.items.filter { $0.summary.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
        return showFavorites ? matches.filter { store.favorites.contains($0.id) } : matches
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Button("历史") { showFavorites = false; selected = 0 }
                    .foregroundStyle(showFavorites ? Color.secondary : Color.accentColor)
                Button("收藏") { showFavorites = true; selected = 0 }
                    .foregroundStyle(showFavorites ? Color.accentColor : Color.secondary)
                Spacer()
                Text("点击即可复制").font(.system(size: 10)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            TextField("搜索剪贴板", text: $search).textFieldStyle(.roundedBorder).focused($focused)
                .onChange(of: search) { _, _ in selected = 0 }
                .onSubmit { if filtered.indices.contains(selected) { choose(filtered[selected], false) } }
                .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, filtered.count - 1)); return .handled }
                .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            if filtered.isEmpty { Spacer(); Text(showFavorites ? "还没有收藏，点击记录旁的星标保存" : "没有匹配的复制记录").font(.caption).foregroundStyle(.secondary); Spacer() }
            else {
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(spacing: 3) { ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 2) {
                          Button { choose(item, false) } label: {
                            HStack(spacing: 9) {
                                if let imageData = item.imageData { ClipboardThumbnail(id: item.id, data: imageData) }
                                else { Image(systemName: item.fileNames.isEmpty ? "text.alignleft" : "doc").frame(width: 30) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.summary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.source.isEmpty ? item.created.formatted(date: .omitted, time: .shortened) : "\(item.source) · \(item.created.formatted(date: .omitted, time: .shortened))")
                                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(8).contentShape(Rectangle())
                                .background(index == selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                          }.buttonStyle(.plain)
                          Button { store.toggleFavorite(item) } label: {
                              Image(systemName: store.favorites.contains(item.id) ? "star.fill" : "star")
                                  .font(.system(size: 12)).foregroundStyle(store.favorites.contains(item.id) ? Color.accentColor : Color.secondary)
                                  .frame(width: 30, height: 30).contentShape(Rectangle())
                          }.buttonStyle(.plain).accessibilityLabel(store.favorites.contains(item.id) ? "取消收藏" : "收藏")
                        }.id(item.id)
                            .onHover { inside in if inside { selected = index } }
                            .contextMenu {
                                Button(store.favorites.contains(item.id) ? "取消收藏" : "收藏") { store.toggleFavorite(item) }
                                if item.text != nil { Button("复制纯文本") { choose(item, true) } }
                                Button("删除此记录") { store.remove(item) }
                            }
                    } } }
                    .onChange(of: selected) { _, value in if filtered.indices.contains(value) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(filtered[value].id) } } }
                }
            }
            HStack {
                Text(store.persistenceLocked ? "已保存记录暂时无法读取 · 新记录仅在内存" : (store.encryptedStorage ? "本机加密保存 · 收藏长期保留" : "仅保存在内存"))
                    .font(.caption2).foregroundStyle(.secondary)
                if store.persistenceLocked { Button(store.recovering ? "恢复中…" : "恢复记录") { store.recover() }.disabled(store.recovering).controlSize(.small) }
                Spacer(); Button("清空历史") { store.clearHistory(); selected = 0 }.controlSize(.small)
            }
            if let error = store.copyError { Text(error).font(.caption2).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            if let warning = store.captureWarning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(warning).font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.dismissCaptureWarning() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("关闭提示").accessibilityLabel("关闭提示")
                }
            }
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .onAppear { focused = true; selected = 0 }
            .onChange(of: filtered.map(\.id)) { _, ids in
                selected = min(selected, max(0, ids.count - 1))
            }
    }
}

private struct ClipboardThumbnail: View {
    let id: UUID
    let data: Data
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: id) {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            if let image, !Task.isCancelled { thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        }
    }
}
