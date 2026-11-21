import SwiftUI

/// Reuses the application's shared note store. The host creates notes through
/// the normal coordinator so a new desktop note gets its usual window.
struct IslandNotesView: View {
    @ObservedObject var store: StickyNoteStore
    let createNote: () -> Void
    var onEditingChange: (Bool) -> Void = { _ in }
    @State private var selectedID: UUID?
    @State private var creationFailed = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("便签", systemImage: "note.text").font(.headline)
                Spacer()
                if !store.notes.isEmpty {
                    Menu {
                        ForEach(store.notes) { note in
                            Button(noteTitle(note)) { selectedID = note.id; editing = true }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedNote.map(noteTitle) ?? "选择便签").lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2)
                        }.frame(maxWidth: 120)
                    }.menuStyle(.borderlessButton).help("选择便签")
                }
                Button {
                    let before = Set(store.notes.map(\.id))
                    createNote()
                    if let created = store.notes.first(where: { !before.contains($0.id) }) {
                        selectedID = created.id; creationFailed = false; editing = true
                    } else { creationFailed = true }
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(!store.canWrite).help("新建便签").accessibilityLabel("新建便签")
            }
            if let note = selectedNote {
                TextEditor(text: Binding(get: { store.text(for: note.id) }, set: { store.updateText($0, id: note.id) }))
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .disabled(!store.canWrite).focused($editing)
                    .accessibilityLabel("便签内容")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(store.canWrite ? "还没有便签" : "便签暂不可编辑")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if creationFailed {
                Text("无法新建，请先开启屏幕便签。") .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: store.notes.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: editing) { _, value in onEditingChange(value) }
        .onDisappear { editing = false; onEditingChange(false); store.flush() }
    }

    private var selectedNote: StickyNote? {
        if let selectedID, let note = store.notes.first(where: { $0.id == selectedID }) { return note }
        return store.notes.first
    }
    private func reconcileSelection() {
        if let selectedID, store.notes.contains(where: { $0.id == selectedID }) { return }
        selectedID = store.notes.first?.id
    }
    private func noteTitle(_ note: StickyNote) -> String {
        let first = note.text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? "无标题便签" : String(first.prefix(30))
    }
}
