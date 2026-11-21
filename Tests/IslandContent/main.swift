import AppKit
import SwiftUI

import Foundation
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let suite = "local.moriq.island.fixture.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = IslandPreviewContent(defaults: defaults)
    model.contents[.shelf] = ["fixture-file.pdf"]
    model.contents[.clipboard] = ["fixture clipboard"]
    model.contents[.notes] = ["fixture note"]
    model.select(.notes)
    precondition(model.selection.selected == .notes && model.contents[.notes] == ["fixture note"])
    model.setEnabled(.notes, false)
    precondition(model.selection.selected != .notes && model.contents[.notes] == ["fixture note"])
    let data = defaults.data(forKey: "island.preview.selection")!
    precondition(!String(decoding: data, as: UTF8.self).contains("fixture"))
    let restored = IslandPreviewContent(defaults: defaults)
    precondition(restored.selection == model.selection && restored.contents.isEmpty)
    let view = IslandModuleSettingsView(model: restored)
    let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    host.layoutSubtreeIfNeeded()
    print("Island preview selection persists without fixture content; disabled module data retained")
}
