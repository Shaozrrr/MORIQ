import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import CoreText
import ImageIO
import Security
import UniformTypeIdentifiers
import Speech
#if DEBUG
import CryptoKit
#endif

#if DEBUG
private final class QuitFixtureVault: ClipboardBackingStore {
    let file: URL
    private let key = SymmetricKey(data: Data(repeating: 0x45, count: 32))
    init(file: URL) { self.file = file }
    func load() throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ClipboardEntry].self, from: ClipboardCipher.open(Data(contentsOf: file), using: key))
    }
    func save(_ entries: [ClipboardEntry]) throws { try ClipboardCipher.seal(JSONEncoder().encode(entries), using: key).write(to: file) }
    func clear() throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
}
private enum QuitFixture {
    static var board: NSPasteboard?
    static var store: ClipboardStore?
    static var vault: QuitFixtureVault?
}
private final class ClipboardRecoveryFixtureVault: ClipboardBackingStore {
    private var attempts = 0
    private var entries = [ClipboardEntry(id: UUID(), created: Date(), source: "测试", items: [[NSPasteboard.PasteboardType.string.rawValue: Data("恢复的测试记录".utf8)]])]
    func load() throws -> [ClipboardEntry] { attempts += 1; if attempts == 1 { throw NSError(domain: "fixture", code: 1) }; return entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func clear() throws { entries = [] }
}
#endif

@main
struct MORIQApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) var coordinator
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let flow = AppFlow()
    private let assistant = AssistantCoordinator()
    private let converter = ConversionCoordinator()
    private let shelf: ShelfCoordinator = {
        #if DEBUG
        if (CommandLine.arguments.contains("--preview-shelf") || CommandLine.arguments.contains("--preview-shelf-only")), let isolated = UserDefaults(suiteName: "local.moriq.tests.shelf") {
            return ShelfCoordinator(store: ShelfStore(defaults: isolated))
        }
        #endif
        return ShelfCoordinator()
    }()
    private lazy var clipboard: ClipboardCoordinator = {
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--verify-app-clipboard-quit"), args.count > index + 1 {
            let directory = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            precondition(directory.path.hasPrefix(NSTemporaryDirectory()))
            let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.quit-fixture.\(UUID().uuidString)"))
            let vault = QuitFixtureVault(file: directory.appendingPathComponent("fixture.enc"))
            let defaults = UserDefaults(suiteName: "local.moriq.quit-fixture.\(UUID().uuidString)")!
            let store = ClipboardStore(board: board, vault: vault, defaults: defaults)
            QuitFixture.board = board; QuitFixture.store = store; QuitFixture.vault = vault
            return ClipboardCoordinator(store: store)
        }
        #endif
        return ClipboardCoordinator()
    }()
    private let captions = LiveCaptionsCoordinator()
    private let screenshot = ScreenshotCoordinator()
    private let inlineScreenshot = ScreenshotInlineCoordinator()
    private let stickyNotes = StickyNotesCoordinator()
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    #if DEBUG
    @objc private func repeatInlineCapture(_ sender: Any?) { screenshot.beginTestSelection() }
    private func verifySignedClipboard() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--verify-signed-clipboard"), args.count > index + 4 else { exit(2) }
        let phase = args[index + 1], service = args[index + 2], directory = URL(fileURLWithPath: args[index + 3]), suite = args[index + 4]
        guard service.hasPrefix("local.moriq.test.signed."), suite == service, directory.path.hasPrefix(NSTemporaryDirectory()) else { exit(2) }
        let vault = ClipboardVault(testService: service, directory: directory)
        let defaults = UserDefaults(suiteName: suite)!
        if phase == "cleanup" {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "history"]
            let status = SecItemDelete(query as CFDictionary)
            defaults.removePersistentDomain(forName: suite)
            if status != errSecSuccess && status != errSecItemNotFound { exit(3) }
            exit(0)
        }
        let external = phase == "captureExternal" || phase == "restoreExternal"
        if external {
            guard args.count > index + 6, args[index + 5].hasPrefix("local.moriq.external.test."),
                  URL(fileURLWithPath: args[index + 6]).standardizedFileURL.path.hasPrefix(NSTemporaryDirectory()) else { exit(2) }
        }
        let board = NSPasteboard(name: NSPasteboard.Name(external ? args[index + 5] : "local.moriq.signed.test.\(UUID().uuidString)"))
        let store = ClipboardStore(board: board, vault: vault, defaults: defaults)
        store.start(initialLoadSynchronously: true)
        guard !store.persistenceLocked else { exit(8) }
        if external {
            let child = Process(); child.executableURL = URL(fileURLWithPath: args[index + 6]); child.arguments = [phase == "captureExternal" ? "write" : "read", args[index + 5]]
            if phase == "captureExternal" {
                do { try child.run(); child.waitUntilExit() } catch { exit(9) }
                guard child.terminationStatus == 0 else { exit(9) }
                store.poll(); store.waitForCaptures()
                guard let item = store.items.first, item.text == "模拟富文本 ✓" else { exit(10) }
                store.toggleFavorite(item)
                store.prepareShutdown { success in
                    _ = store
                    defaults.synchronize(); guard success else { exit(11) }
                    print("PASS app captured external clipboard and saved favorite"); fflush(stdout); exit(0)
                }
            } else {
                guard let item = store.items.first(where: { $0.text == "模拟富文本 ✓" }), store.favorites.contains(item.id), store.copy(item) else { exit(12) }
                do { try child.run(); child.waitUntilExit() } catch { exit(13) }
                guard child.terminationStatus == 0 else { exit(13) }
                store.prepareShutdown { success in
                    _ = store
                    guard success else { exit(14) }
                    print("PASS app restored favorite and copied to external receiver"); fflush(stdout); exit(0)
                }
            }
            return
        }
        if phase == "write" {
            board.clearContents(); board.setString("signed favorite example", forType: .string)
            store.prepareShutdown { success in
                guard success, let entry = store.items.first else { exit(4) }
                store.toggleFavorite(entry); store.start()
                board.clearContents(); board.setString("signed final example", forType: .string)
                store.prepareShutdown { success in
                    defaults.synchronize()
                    guard success, (try? vault.load().count) == 2 else { exit(5) }
                    board.releaseGlobally(); print("PASS signed app stored favorite and final copy"); fflush(stdout); exit(0)
                }
            }
            return
        }
        guard phase == "read", store.items.count == 2,
              store.items.first?.text == "signed final example",
              let favorite = store.items.first(where: { $0.text == "signed favorite example" }), store.favorites.contains(favorite.id) else { exit(6) }
        store.clearHistory()
        store.prepareShutdown { success in
            defaults.synchronize()
            guard success, (try? vault.load().count) == 1 else { exit(7) }
            board.releaseGlobally(); print("PASS signed app restored favorite after restart"); fflush(stdout); exit(0)
        }
    }
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--verify-app-clipboard-quit") {
            _ = clipboard
            guard let board = QuitFixture.board, let store = QuitFixture.store else { exit(2) }
            store.start(initialLoadSynchronously: true)
            board.clearContents(); board.setString("isolated final copy", forType: .string)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in MainActor.assumeIsolated { _ = NSApp.sendAction(#selector(self.quit), to: self, from: nil) } }
            return
        }
        if CommandLine.arguments.contains("--verify-signed-clipboard") {
            verifySignedClipboard()
            return
        }
        if CommandLine.arguments.contains("--verify-bundled-media") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-bundled-media-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                guard let engine = ExternalMediaConverter.executable, engine.path == Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path else { throw NSError(domain: "media fixture", code: 1) }
                let input = root.appendingPathComponent("sample.wav")
                let generator = Process(); generator.executableURL = engine
                generator.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", input.path]
                generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
                try generator.run(); generator.waitUntilExit()
                guard generator.terminationStatus == 0, let mp3 = UTType(filenameExtension: "mp3") else { throw NSError(domain: "media fixture", code: 2) }
                let output = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: mp3, video: false)
                let decoder = Process(); decoder.executableURL = engine
                decoder.arguments = ["-nostdin", "-v", "error", "-i", output.path, "-f", "null", "-"]
                decoder.standardOutput = FileHandle.nullDevice; decoder.standardError = FileHandle.nullDevice
                try decoder.run(); decoder.waitUntilExit()
                guard decoder.terminationStatus == 0 else { throw NSError(domain: "media fixture", code: 3) }
                print("PASS: app uses bundled engine for real conversion and decode"); fflush(stdout); exit(0)
            } catch { print("FAIL: bundled media conversion"); fflush(stdout); exit(1) }
        }
        if CommandLine.arguments.contains("--preview-wheel") {
            converter.previewWheel()
            return
        }
        if CommandLine.arguments.contains("--preview-wheel-interaction") {
            converter.previewWheelInteraction()
            return
        }
        if CommandLine.arguments.contains("--preview-screenshot-replacement") {
            func fixture(_ label: String) -> CGImage {
                let context = CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 44)]))
                context.setFillColor(CGColor(gray: 0, alpha: 1)); context.textPosition = CGPoint(x: 60, y: 150); CTLineDraw(line, context)
                return context.makeImage()!
            }
            let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.screenshot-replacement.\(UUID().uuidString)"))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "截图切换测试"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScreenshotReplacementFixture(images: [fixture("FIRST CAPTURE"), fixture("SECOND CAPTURE")], pasteboard: board))
            mainWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
            return
        }
        if CommandLine.arguments.contains("--preview-inline-floating") {
            guard let display = NSScreen.main,
                  let context = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MORIQ SCREENSHOT TEST", attributes: [.font: NSFont.systemFont(ofSize: 38)]))
            context.textPosition = CGPoint(x: 50, y: 200); CTLineDraw(line, context)
            guard let image = context.makeImage() else { exit(2) }
            let area = display.visibleFrame
            let selected = CGRect(x: area.midX - 300, y: area.midY - 150, width: 600, height: 300)
            let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.inline.floating.\(UUID().uuidString)"))
            guard inlineScreenshot.present(image: image, selection: selected, screen: display.frame, visible: area, pasteboard: board) else { exit(3) }
            return
        }
        if CommandLine.arguments.contains("--verify-inline-suspension") {
            Task { @MainActor in
                let passed = await inlineScreenshot.verifySuspension()
                print(passed ? "TEST_PASS_INLINE_SUSPENSION" : "TEST_FAIL_INLINE_SUSPENSION"); fflush(stdout)
                exit(passed ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--verify-inline-flow") {
            guard let display = NSScreen.main else { exit(2) }
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .white
            let right = NSView(frame: CGRect(x: display.frame.width / 2, y: 0, width: display.frame.width / 2, height: display.frame.height))
            right.wantsLayer = true; right.layer?.backgroundColor = NSColor.systemBlue.cgColor
            window.contentView?.addSubview(right)
            let label = NSTextField(labelWithString: "MORIQ 截图测试画面")
            label.font = NSFont.systemFont(ofSize: 36, weight: .medium); label.textColor = .black
            label.frame = CGRect(x: 100, y: display.frame.height / 2, width: 700, height: 60)
            window.contentView?.addSubview(label); mainWindow = window
            let repeatButton = NSButton(title: "再次框选测试", target: self, action: #selector(repeatInlineCapture(_:)))
            repeatButton.frame = CGRect(x: 80, y: display.frame.height - 100, width: 150, height: 40)
            window.contentView?.addSubview(repeatButton)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.inline.flow.\(UUID().uuidString)"))
            var captureCount = 0
            var regionsPassed = true
            screenshot.onSelectionStarted = { [weak self] in self?.inlineScreenshot.suspend() }
            screenshot.onSelectionCancelled = { [weak self] in self?.inlineScreenshot.resume() }
            screenshot.onCaptureWithSelection = { [weak self] image, selection, screen, visible in
                guard let self else { return }
                let shown = self.inlineScreenshot.present(image: image, selection: selection, screen: screen, visible: visible, pasteboard: board)
                captureCount += 1
                regionsPassed = regionsPassed && shown
                print(shown ? "TEST_PASS_INLINE_CAPTURE" : "TEST_FAIL_INLINE_CAPTURE"); fflush(stdout)
                if let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB) {
                    if CommandLine.arguments.contains("--verify-automatic-regions") {
                        let expected = captureCount == 1 ? (color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9) : (color.blueComponent > color.redComponent + 0.1)
                        regionsPassed = regionsPassed && expected
                    }
                    print(color.blueComponent > color.redComponent + 0.1 ? "TEST_PASS_RIGHT_REGION" : "TEST_NOT_RIGHT_REGION"); fflush(stdout)
                    if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 {
                        print("TEST_PASS_LEFT_REGION"); fflush(stdout)
                    }
                } else { regionsPassed = false }
                if captureCount == 1 && CommandLine.arguments.contains("--verify-automatic-regions") {
                    let overlap = CommandLine.arguments.contains("--verify-previous-overlay-hidden")
                    if overlap { right.frame = window.contentView?.bounds ?? right.frame }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.screenshot.captureTestSelection(CGRect(x: display.frame.width * (overlap ? 0.1 : 0.7), y: display.frame.height * 0.5, width: 200, height: 150), on: display)
                    }
                } else if captureCount == 2 && CommandLine.arguments.contains("--verify-automatic-regions") {
                    let passed = regionsPassed
                    print(passed ? "TEST_PASS_REGION_SEQUENCE" : "TEST_FAIL_REGION_SEQUENCE"); fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(passed ? 0 : 1) }
                } else if captureCount == 1 && CommandLine.arguments.contains("--verify-repeat-selection") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.screenshot.beginTestSelection() }
                }
            }
            screenshot.onError = { _ in print("TEST_FAIL_INLINE_CAPTURE"); fflush(stdout) }
            if CommandLine.arguments.contains("--verify-automatic-regions") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.screenshot.captureTestSelection(CGRect(x: display.frame.width * 0.1, y: display.frame.height * 0.5, width: 200, height: 150), on: display)
                }
            } else { DispatchQueue.main.async { [weak self] in self?.screenshot.beginTestSelection() } }
            return
        }
        if CommandLine.arguments.contains("--preview-inline-screenshot") {
            let context = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MORIQ SCREENSHOT TEST", attributes: [.font: NSFont.systemFont(ofSize: 38, weight: .medium)]))
            context.textPosition = CGPoint(x: 50, y: 200); CTLineDraw(line, context)
            let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.inline.preview.\(UUID().uuidString)"))
            let session = ScreenshotEditSession(image: context.makeImage()!, pasteboard: board)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MORIQ 截图工具测试"; window.isReleasedWhenClosed = false
            let content = ScreenshotInlinePreview(session: session, close: { session.close(); window.close() })
            window.contentView = NSHostingView(rootView: content); mainWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
            return
        }
        if CommandLine.arguments.contains("--preview-native-drag") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-native-drag-test", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let first = root.appendingPathComponent("one.txt"), second = root.appendingPathComponent("two.txt")
            try? Data("one".utf8).write(to: first); try? Data("two".utf8).write(to: second)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MORIQ 拖放测试"; window.isReleasedWhenClosed = false
            let source = ShelfFileDragView(frame: NSRect(x: 40, y: 100, width: 220, height: 100))
            source.urls = [first, second]; source.isSelected = true
            let sourceLabel = NSTextField(labelWithString: "从这里拖动两个文件")
            sourceLabel.frame = NSRect(x: 20, y: 30, width: 200, height: 30); source.addSubview(sourceLabel)
            let destination = NativeDragTestDestination(frame: NSRect(x: 430, y: 100, width: 220, height: 100))
            let destLabel = NSTextField(labelWithString: "拖放到这里")
            destLabel.frame = NSRect(x: 20, y: 30, width: 180, height: 30); destination.addSubview(destLabel)
            window.contentView?.addSubview(source); window.contentView?.addSubview(destination)
            mainWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
            return
        }
        if CommandLine.arguments.contains("--preview-clipboard-recovery") {
            let suite = "local.moriq.recovery-ui.\(UUID().uuidString)"
            let board = NSPasteboard(name: NSPasteboard.Name(suite))
            let store = ClipboardStore(board: board, vault: ClipboardRecoveryFixtureVault(), defaults: UserDefaults(suiteName: suite)!)
            store.start()
            let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 520, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "剪贴板恢复测试"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ClipboardView(store: store, choose: { item, plain in store.copy(item, plain: plain) }))
            mainWindow = window; window.center(); window.makeKeyAndOrderFront(nil); return
        }
        if CommandLine.arguments.contains("--preview-clipboard-isolated") {
            let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.test.clipboard.\(UUID().uuidString)"))
            let store = ClipboardStore(board: board, persistent: false)
            for text in ["项目时间表：周五交付", "常用回复：收到，谢谢！"] {
                board.clearContents(); board.setString(text, forType: .string); store.poll(); store.waitForCaptures()
            }
            let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "MORIQ 测试剪贴板"; window.isReleasedWhenClosed = false
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 340))
            let result = NSTextField(labelWithString: "等待复制")
            result.frame = NSRect(x: 16, y: 4, width: 368, height: 20)
            let host = NSHostingView(rootView: ClipboardView(store: store, choose: { item, plain in
                store.copy(item, plain: plain)
                result.stringValue = "已复制：\(board.string(forType: .string) ?? "")"
            }))
            host.frame = NSRect(x: 0, y: 25, width: 400, height: 315)
            container.addSubview(host); container.addSubview(result); window.contentView = container
            mainWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
            return
        }
        if CommandLine.arguments.contains("--preview-synthetic-background") {
            guard let screen = NSScreen.main else { exit(1) }
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = NSColor(white: 0.1, alpha: 1)
            let label = NSTextField(labelWithString: "MORIQ 安全测试画面")
            label.textColor = .white; label.font = NSFont.systemFont(ofSize: 28); label.frame = NSRect(x: 80, y: screen.frame.height / 2, width: 600, height: 50)
            window.contentView?.addSubview(label); mainWindow = window
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            print("TEST_BACKGROUND_READY"); fflush(stdout); return
        }
        if CommandLine.arguments.contains("--preview-shelf-selection") || CommandLine.arguments.contains("--preview-shelf-drag") {
            let suite = "local.moriq.selection-test.\(UUID().uuidString)"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = ["测试一.txt", "测试二.txt"].map { root.appendingPathComponent($0) }
            for file in files { try? Data("fixture".utf8).write(to: file) }
            let store = ShelfStore(defaults: UserDefaults(suiteName: suite)!)
            store.add(files)
            print("TEST_SHELF_ITEMS=\(store.items.count)"); fflush(stdout)
            let state = ShelfState(); state.expanded = true; state.visible = true
            let board = NSPasteboard(name: NSPasteboard.Name(suite))
            let dragTest = CommandLine.arguments.contains("--preview-shelf-drag")
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: dragTest ? 700 : 420, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "暂存架选择测试"; window.isReleasedWhenClosed = false
            let shelfView = NSHostingView(rootView: ShelfView(store: store, state: state, toggle: {}, drop: { _ in false }, hover: { _ in }, pasteboard: board))
            if dragTest {
                shelfView.frame = NSRect(x: 0, y: 0, width: 420, height: 380)
                let destination = NativeDragTestDestination(frame: NSRect(x: 455, y: 110, width: 200, height: 140))
                let label = NSTextField(labelWithString: "拖放到这里"); label.frame = NSRect(x: 20, y: 50, width: 160, height: 30)
                destination.addSubview(label); window.contentView?.addSubview(shelfView); window.contentView?.addSubview(destination)
            } else { window.contentView = shelfView }
            mainWindow = window; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            print("TEST_SHELF_FIXTURE=\(root.path)"); fflush(stdout)
            return
        }
        if CommandLine.arguments.contains("--verify-shelf-motion") {
            Task { @MainActor in
                let suite = "local.moriq.motion-test.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-motion-test-\(UUID().uuidString).txt")
                do { try Data("MORIQ test".utf8).write(to: file) } catch { print("TEST_SHELF_SETUP_FAILED"); fflush(stdout); exit(2) }
                let store = ShelfStore(defaults: defaults); store.add([file])
                let coordinator = ShelfCoordinator(store: store)
                let passed = await coordinator.verifyMotion()
                defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file)
                print(passed ? "TEST_PASS_SHELF_MOTION" : "TEST_FAIL_SHELF_MOTION")
                fflush(stdout); exit(passed ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--verify-wheel-exit") {
            let passed = converter.verifyWheelExit()
            print(passed ? "PASS: wheel exit clears the active target" : "FAIL: wheel exit retains target")
            fflush(stdout); exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--verify-shelf-batch") {
            Task { @MainActor in
                let suite = "local.moriq.shelf-batch-test.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                let coordinator = ShelfCoordinator(store: ShelfStore(defaults: defaults))
                let passed = await coordinator.verifyDropBatch()
                defaults.removePersistentDomain(forName: suite)
                print(passed ? "PASS: ordered file drops and partial failure feedback" : "FAIL: shelf batch drop")
                fflush(stdout); exit(passed ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--verify-interactive-capture") || CommandLine.arguments.contains("--verify-system-capture") {
            verifyInteractiveCapture(); return
        }
        if CommandLine.arguments.contains("--verify-capture-wheel-guard") {
            let passed = converter.verifyCaptureGuard()
            print(passed ? "PASS: capture selection and macOS screenshot shortcut suppress converter" : "FAIL: capture wheel guard")
            fflush(stdout); exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check-conversion-engines") {
            print("document=\(DocumentConverter.officeEngine != nil) media=\(ExternalMediaConverter.executable != nil)")
            fflush(stdout); exit(0)
        }
        if CommandLine.arguments.contains("--verify-folder-probe") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-folder-check-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let passed = FolderAccessProbe.check(paths: [dir.path]) && !FolderAccessProbe.check(paths: [dir.appendingPathComponent("missing").path])
                try? FileManager.default.removeItem(at: dir)
                print(passed ? "PASS: folder access probe detects available and missing folders" : "FAIL: folder access probe")
                fflush(stdout); exit(passed ? 0 : 1)
            } catch { print("FAIL: folder access test setup"); fflush(stdout); exit(1) }
        }
        if CommandLine.arguments.contains("--verify-direct-screen-probe") {
            Task { @MainActor in
                do {
                    try await DirectScreenAccessProbe.verify()
                    print("PASS: direct display probe captured one pixel")
                    fflush(stdout); exit(0)
                } catch {
                    print("FAIL: direct display probe unavailable")
                    fflush(stdout); exit(1)
                }
            }; return
        }
        if CommandLine.arguments.contains("--verify-permission-session-gate") {
            let wasVerified = UserDefaults.standard.bool(forKey: DirectScreenAccessProbe.verifiedKey)
            DirectScreenAccessProbe.verifiedThisLaunch = false
            FolderAccessProbe.verifiedThisLaunch = false
            CaptionAudioPermissionProbe.verifiedThisLaunch = false
            let flow = AppFlow()
            let blocksUnverified = !flow.mayEnter
            DirectScreenAccessProbe.verifiedThisLaunch = true
            let blocksUnverifiedFolders = !flow.mayEnter
            FolderAccessProbe.verifiedThisLaunch = true
            let blocksUnverifiedAudio = !flow.mayEnter
            CaptionAudioPermissionProbe.verifiedThisLaunch = true
            let expected = CGPreflightScreenCaptureAccess() && AXIsProcessTrusted()
            let matchesCurrentGrants = flow.mayEnter == expected
            DirectScreenAccessProbe.verifiedThisLaunch = false
            FolderAccessProbe.verifiedThisLaunch = false
            CaptionAudioPermissionProbe.verifiedThisLaunch = false
            let passed = blocksUnverified && blocksUnverifiedFolders && blocksUnverifiedAudio && matchesCurrentGrants && !flow.mayEnter && wasVerified == UserDefaults.standard.bool(forKey: DirectScreenAccessProbe.verifiedKey)
            print(passed ? "PASS: permission gate requires a current-session probe" : "FAIL: permission session gate")
            fflush(stdout); exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--verify-full-display") {
            Task { @MainActor in
                let passed = await assistant.verifyFullDisplayCapture()
                print(passed ? "PASS: actual display capture dimensions" : "FAIL: display capture")
                fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-live-screen") {
            Task { @MainActor in
                let passed = await assistant.verifyLiveCapture()
                print(passed ? "PASS: live capture starts and stops" : "FAIL: live capture")
                fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-live-soak") {
            Task { @MainActor in
                let passed = await assistant.verifyLiveSoak()
                print(passed ? "PASS: live stream remains bounded and clears on stop" : "FAIL: live stream soak"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-live-dynamic-soak") {
            Task { @MainActor in
                let passed = await assistant.verifyLiveDynamicSoak()
                print(passed ? "PASS: live stream handles changing content and clears on stop" : "FAIL: live stream dynamic soak"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-missing-screen-frame") {
            Task { @MainActor in
                let passed = await assistant.verifyMissingFrameRejected()
                print(passed ? "PASS: missing screen image stops request" : "FAIL: missing screen image"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-screen-history-display") {
            Task { @MainActor in
                let passed = await assistant.verifyScreenHistoryDisplayIsolation()
                print(passed ? "PASS: screen history is isolated by display" : "FAIL: screen history display isolation"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-live-restart-isolation") {
            Task { @MainActor in
                let passed = await assistant.verifyLiveRestartIsolation()
                print(passed ? "PASS: cancelled live capture cannot erase a new session" : "FAIL: live restart isolation"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-live-stream-recovery") {
            Task { @MainActor in
                let passed = await assistant.verifyLiveStreamRecovery()
                print(passed ? "PASS: screen stream recovers after interruption" : "FAIL: screen stream recovery"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-live-frame-changes") {
            Task { @MainActor in
                let passed = await assistant.verifyStreamFrameChanges()
                print(passed ? "PASS: live stream observes two changing test frames" : "FAIL: live stream changing frames"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-superseded-screenshot") {
            Task { @MainActor in
                let passed = await screenshot.verifySupersededCapture()
                print(passed ? "PASS: stale screenshot cannot replace a newer selection" : "FAIL: superseded screenshot")
                fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-synthetic-screen-answers") {
            func fixture(_ number: String) -> CGImage {
                let context = CGContext(data: nil, width: 1000, height: 320, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 320))
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PROJECT CODE \(number)", attributes: [.font: NSFont.systemFont(ofSize: 60, weight: .bold)]))
                context.setFillColor(CGColor(gray: 0, alpha: 1)); context.textPosition = CGPoint(x: 40, y: 130); CTLineDraw(line, context)
                return context.makeImage()!
            }
            Task { @MainActor in
                let passed = await assistant.verifyContinuousAnswers([fixture("7392"), fixture("4826"), fixture("2764")])
                print(passed ? "PASS: successive answers reflect current synthetic frame" : "FAIL: synthetic screen answers"); fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-fresh-screen") {
            Task { @MainActor in
                let passed = await assistant.verifyFreshCapture()
                print(passed ? "PASS: fresh screen capture ignores stale sample" : "FAIL: fresh screen capture")
                fflush(stdout); exit(passed ? 0 : 1)
            }; return
        }
        if CommandLine.arguments.contains("--verify-screen-answer") {
            verifyScreenAnswer(); return
        }
        if CommandLine.arguments.contains("--verify-own-window-capture") {
            verifyOwnWindowCapture(); return
        }
        if CommandLine.arguments.contains("--verify-assistant-request") {
            Task { @MainActor in
                let model = AssistantModel(); model.input = "Reply exactly MORIQ_OK."; model.send()
                for _ in 0..<300 where model.working { try? await Task.sleep(for: .milliseconds(100)) }
                let passed = !model.working && model.error == nil && model.messages.last?.role == "assistant" && !(model.messages.last?.content.isEmpty ?? true)
                print(passed ? "PASS: actual assistant model request returned a response" : "FAIL: assistant model request did not complete")
                fflush(stdout); exit(passed ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--verify-assistant-panel") {
            Task { @MainActor in
                let passed = await assistant.verifyPanelLifecycle()
                print(passed ? "PASS: assistant remains anchored during repeated expansion and closes" : "FAIL: assistant panel lifecycle")
                fflush(stdout); exit(passed ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--check-permissions") {
            print("screen=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())")
            fflush(stdout); exit(0)
        }
        #endif
        if CommandLine.arguments.contains("--test-deepseek") {
            Task {
                var answer = ""
                do {
                    try await DeepSeekProvider().stream(messages: [ChatMessage(role: "user", content: "Reply exactly MORIQ_OK.")]) { answer += $0 }
                    print("DeepSeek test: completed, output received: \(!answer.isEmpty)"); fflush(stdout); exit(answer.isEmpty ? 1 : 0)
                } catch {
                    if case DeepSeekError.http(let code) = error { print("DeepSeek test failed: HTTP \(code)") }
                    else if case DeepSeekError.noKey = error { print("DeepSeek test failed: no key") }
                    else { print("DeepSeek test failed: connection or local keychain error") }
                    fflush(stdout); exit(1)
                }
            }
            return
        }
        NSApp.appearance = NSAppearance(named: UserDefaults.standard.bool(forKey: "moriq.permissionDarkMode") ? .darkAqua : .aqua)
        NSApp.setActivationPolicy(.accessory)
        settings.resetCaptions() // Never resume system-audio capture silently after relaunch.
        captions.onStop = { [weak self] in self?.settings.resetCaptions() }
        settings.onChange = { [weak self] feature, enabled in
            guard let self else { return false }
            if enabled && !self.flow.mayEnter { self.flow.page = .permissions; self.openMain(); return false }
            var result: OSStatus = noErr
            switch feature {
            case .shelf: result = self.setShelfEnabled(enabled)
            case .converter: if enabled { self.converter.enable() } else { self.converter.disable() }
            case .assistant: if enabled { result = self.assistant.enable() } else { self.assistant.disable() }
            case .clipboard: if enabled { result = self.clipboard.enable() } else { self.clipboard.disable() }
            case .screenshot: if enabled { result = self.screenshot.enable() } else { self.screenshot.disable(); self.inlineScreenshot.close() }
            case .notes: result = self.setNotesEnabled(enabled)
            case .captions: if enabled { self.captions.start() } else { self.captions.stop() }
            }
            if result != noErr { self.flow.notice = "\(feature.title)的快捷键注册失败（\(result)），请检查冲突。"; return false }
            return true
        }
        flow.onFirstEntry = { [weak self] in self?.startEnabledFeatures() }
        converter.onResults = { [weak self] records in
            guard let self else { return }
            self.flow.conversionResults.insert(contentsOf: records.reversed(), at: 0)
            if self.flow.conversionResults.count > 200 { self.flow.conversionResults.removeLast(self.flow.conversionResults.count - 200) }
        }
        screenshot.onCapture = { [weak self] image in
            guard let self else { return }
            self.flow.page = .screenshotEditor(image)
            self.openMain()
        }
        screenshot.onSelectionStarted = { [weak self] in self?.inlineScreenshot.suspend() }
        screenshot.onSelectionCancelled = { [weak self] in self?.inlineScreenshot.resume() }
        screenshot.onCaptureWithSelection = { [weak self] image, selection, screen, visible in
            guard let self else { return }
            if !self.inlineScreenshot.present(image: image, selection: selection, screen: screen, visible: visible) {
                self.inlineScreenshot.resume()
                self.flow.notice = "无法在当前屏幕显示截图工具，请重试。"
                self.openMain()
            }
        }
        screenshot.onError = { [weak self] message in
            guard let self else { return }
            self.flow.notice = message
            if !self.flow.mayEnter { self.flow.page = .permissions }
            self.openMain()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarMark"); icon?.isTemplate = true; icon?.size = NSSize(width: 18, height: 18)
        item.button?.image = icon; item.button?.toolTip = "MORIQ"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 MORIQ", action: #selector(openMain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "权限设置", action: #selector(openPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "AI 连接", action: #selector(openConnection), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "转换记录", action: #selector(openConversionResults), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "开启或停止实时字幕", action: #selector(toggleLiveCaptions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "新建屏幕便签", action: #selector(newStickyNote), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "显示屏幕便签", action: #selector(showStickyNotes), keyEquivalent: ""))
        menu.addItem(.separator()); menu.addItem(NSMenuItem(title: "退出 MORIQ", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }; item.menu = menu; statusItem = item
        #if DEBUG
        if CommandLine.arguments.contains("--preview-permissions") { flow.page = .permissions }
        if CommandLine.arguments.contains("--preview-settings") { flow.page = .settings }
        if CommandLine.arguments.contains("--preview-connection") { flow.page = .connection }
        if CommandLine.arguments.contains("--preview-shelf") { shelf.enable(); flow.page = .settings }
        if CommandLine.arguments.contains("--preview-shelf-only") { shelf.enable(); return }
        if CommandLine.arguments.contains("--preview-assistant") { assistant.showPreview(expanded: true); return }
        if CommandLine.arguments.contains("--preview-screenshot-editor"),
           let context = CGContext(data: nil, width: 900, height: 520, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 520))
            let color = CGColor(gray: 0.12, alpha: 1)
            func drawSample(_ text: String, y: CGFloat, size: CGFloat) {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                context.textPosition = CGPoint(x: 60, y: y); CTLineDraw(line, context)
            }
            drawSample("MORIQ TEST 2026", y: 390, size: 42)
            drawSample("Please review the proposal by Friday.", y: 300, size: 30)
            drawSample("Keep the important details close.", y: 245, size: 30)
            if let image = context.makeImage() { flow.page = .screenshotEditor(image) }
        }
        #endif
        openMain()
    }
    #if DEBUG
    private func verifyInteractiveCapture() {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else { print("TEST_FAIL_SCREEN_PERMISSION"); fflush(stdout); exit(2) }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .normal; window.backgroundColor = .white
        let label = NSTextField(labelWithString: "MORIQ 本地截图验收 · 安全测试画面")
        label.font = NSFont.systemFont(ofSize: 32, weight: .medium); label.textColor = .black
        label.frame = NSRect(x: 80, y: screen.frame.height / 2, width: min(screen.frame.width - 160, 800), height: 50)
        window.contentView?.addSubview(label); mainWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            print("TEST_KEY code=\(event.keyCode) flags=\(event.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue)"); fflush(stdout)
            return event
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-test-drag-\(UUID().uuidString).png")
        if let canvas = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let image = canvas.makeImage(), let destination = CGImageDestinationCreateWithURL(fixture as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil); _ = CGImageDestinationFinalize(destination)
            let board = NSPasteboard(name: .drag); board.clearContents(); _ = board.writeObjects([fixture as NSURL])
        }
        let converterStatus = { converter.enable(); return true }()
        let screenshotStatus = screenshot.enable()
        guard converterStatus, screenshotStatus == noErr else { print("TEST_FAIL_HOTKEY_REGISTER"); fflush(stdout); exit(3) }
        screenshot.onCapture = { [weak self] image in
            guard let self else { return }
            let passed = image.width > 0 && image.height > 0 && self.converter.debugWheelPresentationCount == 0
            print(passed ? "TEST_PASS_CAPTURE_WITHOUT_WHEEL" : "TEST_FAIL_UNEXPECTED_WHEEL")
            fflush(stdout); self.screenshot.disable(); self.converter.disable(); window.close()
            NSPasteboard(name: .drag).clearContents(); try? FileManager.default.removeItem(at: fixture)
            exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.contains("--verify-system-capture") {
            var observed = false
            var observedShiftDrag = false
            var observedShift = false
            var observedMouse = false
            var barrierPassed = false
            let started = Date()
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let active = InteractionArbiter.systemScreenshotActive
                    if active && !observed {
                        observed = true; barrierPassed = self.converter.verifySystemCaptureSuppression()
                        print("TEST_SYSTEM_CAPTURE_ACTIVE"); fflush(stdout)
                    }
                    if active && NSEvent.pressedMouseButtons & 1 != 0 { observedMouse = true }
                    if active && NSEvent.modifierFlags.contains(.shift) { observedShift = true }
                    if active && NSEvent.pressedMouseButtons & 1 != 0 && NSEvent.modifierFlags.contains(.shift) { observedShiftDrag = true }
                    if observed && !active {
                        timer.invalidate()
                        let recovered = self.converter.verifySystemCaptureRecovery()
                        let passed = self.converter.debugWheelPresentationCount == 0 && barrierPassed && recovered
                        print("TEST_INPUT shift=\(observedShift) mouse=\(observedMouse) simultaneous=\(observedShiftDrag)")
                        print(passed ? "TEST_PASS_SYSTEM_CAPTURE_BARRIER_AND_RECOVERY" : "TEST_FAIL_SYSTEM_CAPTURE_BARRIER")
                        fflush(stdout); self.screenshot.disable(); self.converter.disable(); window.close()
                        NSPasteboard(name: .drag).clearContents(); try? FileManager.default.removeItem(at: fixture)
                        exit(passed ? 0 : 1)
                    }
                    if Date().timeIntervalSince(started) > 180 { timer.invalidate(); print("TEST_FAIL_SYSTEM_CAPTURE_TIMEOUT"); fflush(stdout); exit(4) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        print("TEST_READY"); fflush(stdout)
    }
    private func verifyScreenAnswer() {
        guard CGPreflightScreenCaptureAccess() else { print("FAIL: screen permission"); fflush(stdout); exit(2) }
        let window = NSPanel(contentRect: NSRect(x: 30, y: 60, width: 500, height: 160), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "MORIQ 本地验收"; window.isReleasedWhenClosed = false; window.backgroundColor = .white
        let label = NSTextField(labelWithString: "PROJECT CODE 7392")
        label.font = NSFont.systemFont(ofSize: 32, weight: .bold); label.textColor = .black
        label.frame = NSRect(x: 30, y: 50, width: 440, height: 48); window.contentView?.addSubview(label); window.orderFrontRegardless()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "ScreenAnswer", code: 1) }
                let config = SCStreamConfiguration(); config.width = 1000; config.height = 320; config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                label.stringValue = "PROJECT CODE 4826"
                try await Task.sleep(for: .milliseconds(350))
                let latest = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                let recognized = try await Task.detached(priority: .userInitiated) { try OCREngine().recognize(latest) }.value
                guard recognized.contains("4826") else { throw NSError(domain: "ScreenAnswerOCR", code: 2) }
                label.stringValue = "PROJECT CODE 2764"
                try await Task.sleep(for: .milliseconds(350))
                let updated = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                guard await assistant.verifyContinuousAnswers([image, latest, updated]) else { throw NSError(domain: "ScreenAnswerCoordinator", code: 3) }
                print("PASS: consecutive screen questions answered using latest frames"); window.close(); fflush(stdout); exit(0)
            } catch { print("FAIL: screen-to-answer test (\(error.localizedDescription))"); window.close(); fflush(stdout); exit(1) }
        }
    }
    private func verifyOwnWindowCapture() {
        guard CGPreflightScreenCaptureAccess() else { print("FAIL: screen capture permission unavailable for test"); fflush(stdout); exit(2) }
        let window = NSPanel(contentRect: NSRect(x: 30, y: 60, width: 480, height: 150), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "MORIQ 本地验收"; window.isReleasedWhenClosed = false; window.backgroundColor = .white
        let label = NSTextField(labelWithString: "MORIQ TEST 2026")
        label.font = NSFont.systemFont(ofSize: 32, weight: .bold); label.textColor = .black
        label.frame = NSRect(x: 30, y: 50, width: 420, height: 48); window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "OwnWindowTest", code: 1) }
                let config = SCStreamConfiguration(); config.width = 960; config.height = 300; config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                let recognized = try await Task.detached(priority: .userInitiated) { try OCREngine().recognize(image) }.value
                guard recognized.uppercased().contains("MORIQ") else { throw NSError(domain: "OwnWindowTest", code: 2) }
                print("PASS: real own-window capture and OCR")
                window.close(); fflush(stdout); exit(0)
            } catch {
                print("FAIL: own-window capture or OCR unavailable (\(error.localizedDescription))")
                window.close(); fflush(stdout); exit(1)
            }
        }
    }
    #endif
    private func startEnabledFeatures() {
        let captionsStatus = GlobalShortcutRegistry.shared.enable(.captions, retryOnUpdate: true) { [weak self] in self?.toggleLiveCaptions() }
        if captionsStatus != noErr { flow.notice = "实时字幕的快捷键注册失败（\(captionsStatus)），请检查冲突。" }
        for feature in [Feature.converter, .assistant, .shelf, .clipboard, .screenshot, .notes] where settings.enabled[feature.rawValue] == true {
            let status: OSStatus
            switch feature { case .shelf: status = setShelfEnabled(true); case .converter: converter.enable(); status = noErr; case .assistant: status = assistant.enable(); case .clipboard: status = clipboard.enable(); case .screenshot: status = screenshot.enable(); case .notes: status = setNotesEnabled(true); case .captions: status = noErr }
            if status != noErr { settings.binding(for: feature).wrappedValue = false; flow.notice = "\(feature.title)快捷键注册失败（\(status)）。" }
        }
    }
    private func setShelfEnabled(_ enabled: Bool) -> OSStatus {
        if !enabled { GlobalShortcutRegistry.shared.disable(.shelf); shelf.disable(); return noErr }
        let status = GlobalShortcutRegistry.shared.enable(.shelf, retryOnUpdate: true) { [weak self] in
            guard let self, self.settings.enabled[Feature.shelf.rawValue] == true else { return }
            guard self.flow.mayEnter else { self.openPermissions(); return }
            self.shelf.toggleFromShortcut()
        }
        shelf.enable()
        if status != noErr { flow.notice = "文件暂存架已启用；快捷键被占用，请在设置中更换。" }
        return noErr
    }
    private func setNotesEnabled(_ enabled: Bool) -> OSStatus {
        if !enabled { GlobalShortcutRegistry.shared.disable(.notes); stickyNotes.disable(); return noErr }
        let status = GlobalShortcutRegistry.shared.enable(.notes, retryOnUpdate: true) { [weak self] in
            guard let self, self.settings.enabled[Feature.notes.rawValue] == true else { return }
            self.newStickyNote()
        }
        stickyNotes.enable()
        if status != noErr { flow.notice = "屏幕便签已启用；快捷键被占用，请在设置中更换。" }
        return noErr
    }
    @objc func openMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "MORIQ"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 650, height: 560)
            window.contentView = NSHostingView(rootView: MainFlowView(flow: flow, store: settings, newNote: { [weak self] in self?.newStickyNote() })); window.center(); mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); mainWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openPermissions() { if flow.introComplete { flow.autoEnterWhenReady = false; flow.page = .permissions }; openMain() }
    @objc func openConversionResults() {
        guard flow.introComplete && flow.mayEnter else { if flow.introComplete { flow.page = .permissions }; openMain(); return }
        flow.page = .conversionResults; openMain()
    }
    @objc func openConnection() {
        guard flow.introComplete && flow.mayEnter else { if flow.introComplete { flow.page = .permissions }; openMain(); return }
        flow.page = .connection; openMain()
    }
    private func prepareStickyNotes() -> Bool {
        guard flow.introComplete && flow.mayEnter else { if flow.introComplete { flow.page = .permissions }; openMain(); return false }
        guard stickyNotes.store.canWrite else { flow.notice = stickyNotes.store.error; openMain(); return false }
        if settings.enabled[Feature.notes.rawValue] != true { settings.binding(for: .notes).wrappedValue = true }
        return stickyNotes.enabled
    }
    @objc func newStickyNote() { if prepareStickyNotes() { stickyNotes.create() } }
    @objc func showStickyNotes() { if prepareStickyNotes() { stickyNotes.showAll() } }
    @objc func toggleLiveCaptions() { settings.binding(for: .captions).wrappedValue.toggle() }
    @objc func quit() { PermissionRelaunch.shared.cancel(); NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard stickyNotes.store.flush() else { flow.notice = stickyNotes.store.error; openMain(); return .terminateCancel }
        clipboard.prepareShutdown { success in
            if !success {
                let alert = NSAlert(); alert.messageText = "剪贴板记录尚未保存"; alert.informativeText = "保存超时或失败，MORIQ 仍在运行。请稍后重试退出。"; alert.addButton(withTitle: "好"); alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--verify-app-clipboard-quit") {
            guard let vault = QuitFixture.vault, let entries = try? vault.load(), entries.first?.text == "isolated final copy", let bytes = try? Data(contentsOf: vault.file), !bytes.contains(Data("isolated final copy".utf8)) else { exit(9) }
            print("PASS actual menu quit preserved encrypted isolated final copy"); fflush(stdout)
            QuitFixture.board?.releaseGlobally()
            return
        }
        #endif
        stickyNotes.shutdown(); assistant.disable(); clipboard.shutdown(); screenshot.disable(); inlineScreenshot.close(); converter.cancel(); shelf.disable(); if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

/// Keeps a short-lived, one-shot watcher only while a system permission is being granted.
/// macOS may terminate MORIQ immediately after screen-recording access changes.
@MainActor final class PermissionRelaunch {
    static let shared = PermissionRelaunch()
    private var watcher: Process?
    private var cleanup: Task<Void, Never>?
    private(set) var waitingFor: String?

    func arm(for permission: String) {
        cancel()
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", """
        parent="$1"
        app="$2"
        for i in $(/usr/bin/jot 600); do
            if ! /bin/kill -0 "$parent" 2>/dev/null; then
                for attempt in $(/usr/bin/jot 10); do
                    /usr/bin/open "$app" && exit 0
                    /bin/sleep 0.5
                done
                exit 1
            fi
            /bin/sleep 0.5
        done
        """, "moriq-permission-reopen", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do { try watcher.run(); self.watcher = watcher; waitingFor = permission }
        catch { self.watcher = nil; waitingFor = nil }
    }
    func granted(_ permission: String) {
        guard waitingFor == permission, cleanup == nil else { return }
        cleanup = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            cancel()
        }
    }
    func cancel() {
        cleanup?.cancel(); cleanup = nil
        if let watcher, watcher.isRunning { watcher.terminate() }
        watcher = nil; waitingFor = nil
    }
}

#if DEBUG
final class NativeDragTestDestination: NSView {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let names = Set(urls.map(\.lastPathComponent))
        let good = names == Set(["one.txt", "two.txt"]) || names == Set(["测试一.txt", "测试二.txt"])
        print(good ? "TEST_PASS_NATIVE_MULTI_DROP" : "TEST_FAIL_NATIVE_MULTI_DROP count=\(urls.count)")
        fflush(stdout); return good
    }
}
#endif
