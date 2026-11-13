import Foundation
final class State: @unchecked Sendable {
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    var count = 0
    func fail() { lock.lock(); count += 1; lock.unlock(); done.signal() }
}
@main struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 4)
        let state = State()
        let value = try ExperimentalCaptionSpeakerAdapter.make(environment: ["MORIQ_EXPERIMENTAL_SPEAKER":"1"],
            whisperHelper: URL(fileURLWithPath: args[1]), whisperModel: URL(fileURLWithPath: args[2]),
            speakerHelper: URL(fileURLWithPath: args[3]), speakerModel: URL(fileURLWithPath: args[2]),
            language: "en", minimumCoverage: 0.7, maximumCompetition: 0.2,
            onText: {_,_ in}, onUpdate: {_ in}, onError: {_ in state.fail()})
        precondition(value != nil && state.done.wait(timeout: .now() + 10) == .success)
        usleep(200_000)
        state.lock.lock(); let count = state.count; state.lock.unlock()
        precondition(count == 1, "failure must be reported exactly once")
        value?.stop()
        print("PASS speaker process failure surfaces without any caption window")
    }
}
