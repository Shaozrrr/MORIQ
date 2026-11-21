import Foundation
import EventKit

/// A small, display-ready summary. No attendee, notes, location or calendar ID is retained.
struct AgendaEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

enum AgendaAuthorization: Equatable, Sendable {
    case notDetermined, allowed, denied, restricted
}

enum AgendaState: Equatable, Sendable {
    case idle
    case loading
    case ready([AgendaEvent])
    case denied
    case restricted
    case failed
}

@MainActor protocol AgendaSource {
    func authorization() -> AgendaAuthorization
    func requestAccess() async throws -> Bool
    func events(from start: Date, to end: Date) throws -> [AgendaEvent]
}

@MainActor final class EventKitAgendaSource: AgendaSource {
    private let store: EKEventStore
    init(store: EKEventStore = EKEventStore()) { self.store = store }

    func authorization() -> AgendaAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .allowed
        case .writeOnly, .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }
    func events(from start: Date, to end: Date) throws -> [AgendaEvent] {
        guard start < end else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            AgendaEvent(id: event.eventIdentifier ?? UUID().uuidString,
                        title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无标题日程" : event.title,
                        start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
        }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }
}

/// The caller chooses when to request access; initial construction performs no access.
@MainActor final class AgendaController: ObservableObject {
    @Published private(set) var state: AgendaState = .idle
    private let source: any AgendaSource
    private var generation = 0
    private var requestingAccess = false
    init(source: any AgendaSource) { self.source = source }

    func refresh(from start: Date, to end: Date, requestIfNeeded: Bool = false) async {
        guard !Task.isCancelled else { return }
        let authorization = source.authorization()
        // A system refresh during the permission dialog must not replace the
        // active request with an idle state or start a second prompt.
        if authorization == .notDetermined && requestingAccess { return }
        generation += 1
        let current = generation
        guard start < end else { state = .ready([]); return }
        switch authorization {
        case .denied: state = .denied; return
        case .restricted: state = .restricted; return
        case .notDetermined:
            guard requestIfNeeded else { state = .idle; return }
            state = .loading
            requestingAccess = true
            defer { requestingAccess = false }
            do {
                let granted = try await source.requestAccess()
                guard generation == current, !Task.isCancelled else { return }
                switch source.authorization() {
                case .restricted: state = .restricted; return
                case .denied: state = .denied; return
                case .notDetermined where !granted: state = .denied; return
                default: break
                }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                state = .failed; return
            }
        case .allowed: break
        }
        guard generation == current else { return }
        state = .loading
        do { state = .ready(try source.events(from: start, to: end)) }
        catch { state = .failed }
    }
    func clear() { generation += 1; state = .idle }
}
