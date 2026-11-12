import AppKit
import SwiftUI

/// A local note; closing its window hides it without discarding the contents.
struct StickyNote: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var frame: CGRect
    var isOpen: Bool
}

enum StickyNoteGeometry {
    /// Preserve location where possible; clamp a partially visible note to the
    /// current display, or return nil when its display is no longer present.
    static func restoreFrame(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= 220, frame.height >= 160 else { return nil }
        let candidates = visibleFrames.filter { $0.width >= 220 && $0.height >= 160 && !$0.intersection(frame).isNull && !$0.intersection(frame).isEmpty }
        guard let bounds = candidates.max(by: { a, b in
            let x = a.intersection(frame), y = b.intersection(frame)
            return x.width * x.height < y.width * y.height
        }) else { return nil }
        let width = min(frame.width, bounds.width), height = min(frame.height, bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }
}

@MainActor final class StickyNoteStore: ObservableObject {
    @Published private(set) var notes: [StickyNote] = []
    @Published private(set) var error: String?
    private let file: URL
    private var pending: Task<Void, Never>?
    private var dirty = false
    private(set) var canWrite = true

    init(file: URL) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { notes = try JSONDecoder().decode([StickyNote].self, from: Data(contentsOf: file)) }
        catch { canWrite = false; self.error = "便签无法读取，原数据未覆盖。" }
    }
    func create() -> UUID? {
        guard canWrite else { return nil }
        let id = UUID()
        notes.append(StickyNote(id: id, text: "", frame: .zero, isOpen: true)); scheduleSave(); return id
    }
    func text(for id: UUID) -> String { notes.first(where: { $0.id == id })?.text ?? "" }
    func updateText(_ text: String, id: UUID) {
        guard canWrite, let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text; scheduleSave()
    }
    func updateWindow(_ frame: CGRect, open: Bool, id: UUID) {
        guard canWrite, let i = notes.firstIndex(where: { $0.id == id }),
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else { return }
        notes[i].frame = frame; notes[i].isOpen = open; scheduleSave()
    }
    @discardableResult func delete(_ id: UUID) -> Bool {
        guard canWrite, notes.contains(where: { $0.id == id }) else { return false }
        let previous = notes
        notes.removeAll { $0.id == id }; dirty = true
        if flush() { return true }
        // Keep the note in memory if committing the deletion fails.
        notes = previous; dirty = true; return false
    }
    private func scheduleSave() {
        dirty = true
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }
    @discardableResult func flush() -> Bool {
        pending?.cancel(); pending = nil
        guard dirty else { return true }
        guard canWrite else { return false }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoded = try JSONEncoder().encode(notes)
            try encoded.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            dirty = false; error = nil; return true
        } catch { self.error = "便签保存失败，请检查磁盘空间和访问权限。"; return false }
    }
}

@MainActor final class StickyNotesCoordinator: NSObject, NSWindowDelegate {
    let store: StickyNoteStore
    private var windows: [UUID: NSPanel] = [:]
    private var closingForShutdown = false
    private(set) var enabled = false
    init(file: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = StickyNoteStore(file: file ?? base.appendingPathComponent("MORIQ/sticky-notes.json"))
        super.init()
    }
    func enable() {
        guard !enabled else { return }; enabled = true
        for note in store.notes where note.isOpen { show(note.id, activate: false) }
    }
    func disable() {
        guard enabled else { return }; enabled = false; closingForShutdown = true
        for panel in Array(windows.values) { panel.close() }; windows.removeAll(); closingForShutdown = false
        store.flush()
    }
    func create() {
        guard enabled, let id = store.create() else { return }
        show(id, activate: true)
    }
    func showAll() {
        guard enabled else { return }
        if store.notes.isEmpty { create(); return }
        for note in store.notes { show(note.id, activate: false) }
        NSApp.activate(ignoringOtherApps: true); windows.values.first?.makeKeyAndOrderFront(nil)
    }
    private func show(_ id: UUID, activate: Bool) {
        if let window = windows[id] { window.orderFrontRegardless(); if activate { window.makeKeyAndOrderFront(nil) }; return }
        guard let note = store.notes.first(where: { $0.id == id }) else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 270), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "屏幕便签"; panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 220, height: 160)
        // Keep notes above Finder's desktop icons but below normal app windows.
        // They follow ordinary Spaces, never covering a full-screen app.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        panel.hidesOnDeactivate = false; panel.delegate = self
        panel.contentView = NSHostingView(rootView: StickyNoteView(store: store, id: id, newNote: { [weak self] in self?.create() }, deleteNote: { [weak self] in self?.delete(id) ?? false }))
        if let frame = StickyNoteGeometry.restoreFrame(note.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)) { panel.setFrame(frame, display: false) }
        else {
            panel.center()
            if let screen = panel.screen ?? NSScreen.main {
                let offset = CGFloat(windows.count % 6) * 22
                let bounds = screen.visibleFrame
                let x = min(max(panel.frame.minX + offset, bounds.minX), bounds.maxX - panel.frame.width)
                let y = min(max(panel.frame.minY - offset, bounds.minY), bounds.maxY - panel.frame.height)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        windows[id] = panel; store.updateWindow(panel.frame, open: true, id: id)
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }
    private func delete(_ id: UUID) -> Bool {
        guard store.delete(id) else { return false }
        windows[id]?.close(); return true
    }
    func windowDidMove(_ notification: Notification) { saveFrame(notification) }
    func windowDidResize(_ notification: Notification) { saveFrame(notification) }
    private func saveFrame(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, let id = windows.first(where: { $0.value === panel })?.key else { return }
        store.updateWindow(panel.frame, open: true, id: id)
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, let id = windows.first(where: { $0.value === panel })?.key else { return }
        if !closingForShutdown { store.updateWindow(panel.frame, open: false, id: id); store.flush() }
        windows.removeValue(forKey: id)
    }
    func shutdown() { closingForShutdown = true; store.flush(); for panel in Array(windows.values) { panel.close() }; windows.removeAll() }
}

private struct StickyNoteView: View {
    @ObservedObject var store: StickyNoteStore
    let id: UUID
    let newNote: () -> Void
    let deleteNote: () -> Bool
    @State private var confirmingDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("便签").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { confirmingDelete = true } label: { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).accessibilityLabel("删除便签")
                Button(action: newNote) { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).accessibilityLabel("新建便签")
            }.padding(.horizontal, 16).padding(.top, 10)
            if confirmingDelete {
                HStack {
                    Text("删除这条便签？").font(.caption)
                    Spacer()
                    Button("取消") { confirmingDelete = false }.buttonStyle(.plain)
                    Button("删除") { if deleteNote() { confirmingDelete = false } }.buttonStyle(.plain).foregroundStyle(.red)
                }.padding(.horizontal, 16).padding(.top, 8)
            }
            TextEditor(text: Binding(get: { store.text(for: id) }, set: { store.updateText($0, id: id) }))
                .font(.system(size: 15)).scrollContentBackground(.hidden).padding(.horizontal, 10).padding(.vertical, 6)
                .accessibilityLabel("便签内容")
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).padding([.horizontal, .bottom], 12) }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}
