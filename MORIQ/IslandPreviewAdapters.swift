import Combine
import Foundation

/// Preview-only bridge. Publishers are injected; it does not read or create data sources.
enum IslandPreviewSnapshot: Equatable {
    case unavailable, empty, redacted, ready([String]), failed
}
@MainActor final class IslandPreviewAdapters {
    private weak var model: IslandPreviewContent?
    private var subscriptions: [IslandModule: AnyCancellable] = [:]
    private var selectionSubscription: AnyCancellable?
    init(model: IslandPreviewContent) {
        self.model = model
        selectionSubscription = model.$selection.dropFirst().sink { [weak self] selection in
            self?.removeDisabled(selection.enabled)
        }
    }
    func connect(_ module: IslandModule, publisher: AnyPublisher<IslandPreviewSnapshot, Never>) {
        guard model?.selection.enabled.contains(module) == true else { return }
        subscriptions[module]?.cancel()
        subscriptions[module] = publisher.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.apply(value, module: module)
        }
    }
    func stop() {
        subscriptions.values.forEach { $0.cancel() }; subscriptions.removeAll()
        selectionSubscription?.cancel(); selectionSubscription = nil
        for module in IslandModule.allCases { clear(module) }
    }
    private func removeDisabled(_ enabled: [IslandModule]) {
        for module in Array(subscriptions.keys) where !enabled.contains(module) {
            subscriptions.removeValue(forKey: module)?.cancel(); clear(module)
        }
    }
    private func clear(_ module: IslandModule) {
        model?.contents.removeValue(forKey: module); model?.hidden.remove(module)
        model?.states.removeValue(forKey: module)
    }
    private func apply(_ value: IslandPreviewSnapshot, module: IslandModule) {
        guard let model, model.selection.enabled.contains(module) else { return }
        model.contents.removeValue(forKey: module); model.hidden.remove(module)
        switch value {
        case .unavailable: model.states[module] = .unavailable
        case .empty: model.states[module] = .empty
        case .redacted: model.states[module] = .redacted; model.hidden.insert(module)
        case .ready(let items): model.states[module] = items.isEmpty ? .empty : .ready; model.contents[module] = items
        case .failed: model.states[module] = .failed
        }
    }
}
