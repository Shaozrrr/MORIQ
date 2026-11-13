import Foundation

final class Results: @unchecked Sendable {
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    var turns: [SpeakerDiarizationTurn] = [], failed = false
    func add(_ value: [SpeakerDiarizationTurn]) { lock.lock(); turns += value.filter(\.final); lock.unlock() }
    func fail() { lock.lock(); failed = true; lock.unlock(); done.signal() }
}
guard CommandLine.arguments.count == 5 else { fatalError("helper model pcm expected-json") }
let result = Results()
let bridge = try SpeakerDiarizationBridge(helper: URL(fileURLWithPath: CommandLine.arguments[1]), model: URL(fileURLWithPath: CommandLine.arguments[2]), onTurns: { result.add($0) }, onFailure: { result.fail() }, onFinished: { result.done.signal() })
let pcm = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
for offset in stride(from: 0, to: pcm.count, by: 6400) {
    let block = pcm.subdata(in: offset..<min(offset + 6400, pcm.count))
    guard bridge.append(block) else { fatalError("unexpected overflow") }
    usleep(20_000)
}
bridge.finish()
guard result.done.wait(timeout: .now() + 60) == .success else { fatalError("timeout") }
result.lock.lock(); let turns = result.turns.sorted { $0.startSample < $1.startSample }; let failed = result.failed; result.lock.unlock()
guard !failed else { fatalError("bridge failed") }
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))) as! [String: Any]
let expected = (json["segments"] as! [[String: Any]]).sorted { ($0["startTimeSeconds"] as! Double) < ($1["startTimeSeconds"] as! Double) }
precondition(expected.count == turns.count)
for (e, a) in zip(expected, turns) {
    precondition((e["speakerIndex"] as! Int) == a.speaker)
    precondition(abs((e["startTimeSeconds"] as! Double) - Double(a.startSample)/16000) < 0.01)
    precondition(abs((e["endTimeSeconds"] as! Double) - Double(a.endSample)/16000) < 0.01)
}
precondition(!bridge.append(Data(repeating: 0, count: 6400)))
bridge.stop()
print("PASS real model bridge output matches official CLI: \(turns.count) turns")
