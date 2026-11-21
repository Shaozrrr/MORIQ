import Foundation
import EventKit

@MainActor final class StubAgenda: AgendaSource {
    var status: AgendaAuthorization = .notDetermined
    var granted = false
    var reads = 0
    var requests = 0
    var items: [AgendaEvent] = []
    var fail = false
    var delayedAccess: (() async -> Bool)?
    func authorization() -> AgendaAuthorization { status }
    func requestAccess() async throws -> Bool {
        requests += 1
        if fail { throw NSError(domain: "test", code: 1) }
        if let delayedAccess { return await delayedAccess() }
        return granted
    }
    func events(from: Date, to: Date) throws -> [AgendaEvent] { reads += 1; if fail { throw NSError(domain: "test", code: 2) }; return items }
}
@main struct TestAgenda {
    @MainActor static func main() async {
        let source = StubAgenda(), controller = AgendaController(source: source)
        let start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 3600)
        await controller.refresh(from: start, to: end)
        precondition(controller.state == .idle && source.requests == 0 && source.reads == 0)
        await controller.refresh(from: start, to: end, requestIfNeeded: true)
        precondition(controller.state == .denied && source.requests == 1 && source.reads == 0)
        source.status = .restricted
        await controller.refresh(from: start, to: end, requestIfNeeded: true)
        precondition(controller.state == .restricted && source.requests == 1)
        source.status = .allowed
        await controller.refresh(from: start, to: end)
        precondition(controller.state == .ready([]) && source.reads == 1)
        let event = AgendaEvent(id: "fixture", title: "Test", start: start, end: end, isAllDay: false)
        source.items = [event]
        await controller.refresh(from: start, to: end)
        precondition(controller.state == .ready([event]))
        source.fail = true
        await controller.refresh(from: start, to: end)
        precondition(controller.state == .failed)
        controller.clear()
        precondition(controller.state == .idle)
        source.fail = false
        source.status = .notDetermined
        var response: CheckedContinuation<Bool, Never>?
        source.delayedAccess = { await withCheckedContinuation { response = $0 } }
        let request = Task { await controller.refresh(from: start, to: end, requestIfNeeded: true) }
        while response == nil { await Task.yield() }
        await controller.refresh(from: start, to: end)
        await controller.refresh(from: start, to: end, requestIfNeeded: true)
        precondition(controller.state == .loading && source.requests == 2)
        let readsBeforeRevocation = source.reads
        source.status = .denied
        response?.resume(returning: true)
        await request.value
        precondition(controller.state == .denied && source.reads == readsBeforeRevocation)
        print("PASS calendar prompt coalescing, permission revocation, event refresh and clear")
    }
}
