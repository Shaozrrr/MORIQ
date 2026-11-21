import AppKit
import Combine
import Foundation
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let suite = "local.moriq.island.adapters.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = IslandPreviewContent(defaults: defaults)
    let bridge = IslandPreviewAdapters(model: model)
    let source = PassthroughSubject<IslandPreviewSnapshot, Never>()
    bridge.connect(.shelf, publisher: source.eraseToAnyPublisher())
    source.send(.ready(["fixture.pdf"]))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(model.contents[.shelf] == ["fixture.pdf"] && model.states[.shelf] == .ready)
    source.send(.redacted)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(model.contents[.shelf] == nil && model.hidden.contains(.shelf))
    model.setEnabled(.shelf, false)
    source.send(.ready(["late.pdf"]))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(model.contents[.shelf] == nil && !model.hidden.contains(.shelf) && model.states[.shelf] == nil)
    bridge.stop()
    print("Island preview adapter updates, redaction, disabled subscription and cleanup passed")
}
