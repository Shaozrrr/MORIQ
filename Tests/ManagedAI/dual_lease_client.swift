import Foundation
final class MemoryStore: DeviceRenewalStore {
    var state: DeviceRenewalState?
    func load() throws -> DeviceRenewalState? { state }
    func save(_ state: DeviceRenewalState) throws { self.state = state }
}
@main struct Test {
    static func main() async throws {
        let renew = URL(string: CommandLine.arguments[1])!
        let store = MemoryStore(), coordinator = DeviceRenewalCoordinator(store: store)
        let transport = try DeviceRenewalTransport(endpoint: renew, allowLoopback: true)
        try await coordinator.activate(invite: CommandLine.arguments[2], using: transport)
        let speechLease = try await coordinator.acquire(endpoint: renew, allowLoopbackForTesting: true)
        let speech = try ManagedSpeechStream(endpoint: URL(string: CommandLine.arguments[3])!, token: speechLease.token, allowLoopbackForTesting: true)
        await speech.attachCredentialRelease { await coordinator.release(speechLease) }
        let events = try await speech.start(source: "en", target: "zh")
        var iterator = events.makeAsyncIterator()
        guard let ready = try await iterator.next(), ready.type == "ready" else { fatalError("speech not ready") }
        var provider = DeepSeekProvider(endpoint: URL(string: CommandLine.arguments[4])!)
        provider.managedLease = {
            let lease = try await coordinator.acquire(endpoint: renew, allowLoopbackForTesting: true)
            return (lease.token, { await coordinator.release(lease) })
        }
        guard var state = store.state else { fatalError("missing state") }
        state.renewAfter = Date().addingTimeInterval(-1); try store.save(state)
        let answer = Task { @MainActor in
            var text = ""
            try await provider.stream(messages: [ChatMessage(role: "user", content: "test")]) { text += $0 }
            return text
        }
        try await Task.sleep(for: .milliseconds(400))
        precondition(store.state?.generation == 0)
        await speech.cancel()
        let text = try await answer.value
        precondition(text == "hello" && store.state?.generation == 1)
        print("PASS Swift speech and assistant share active session")
    }
}
