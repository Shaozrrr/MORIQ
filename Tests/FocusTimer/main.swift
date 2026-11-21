import Foundation
final class Notifications: FocusTimerNotifications {
    var scheduled: [(TimeInterval, FocusTimerPhase)] = []
    var cancels = 0
    func schedule(after seconds: TimeInterval, phase: FocusTimerPhase) { scheduled.append((seconds, phase)) }
    func cancel() { cancels += 1 }
}
func at(_ wall: Double, _ mono: Double, _ boot: String = "one") -> FocusTimerInstant {
    FocusTimerInstant(wall: Date(timeIntervalSince1970: wall), continuous: mono, bootID: boot)
}
let notification = Notifications()
var timer = FocusTimerCore(now: at(10_000, 100), notifications: notification)
timer.start(phase: .focus, now: at(10_000, 100))
precondition(timer.snapshot.remainingAtAnchor == 1500 && notification.scheduled.last!.0 == 1500)
timer.pause(now: at(10_020, 120))
precondition(timer.snapshot.status == .paused && timer.snapshot.remainingAtAnchor == 1480)
timer.resume(now: at(11_000, 1100))
timer.refresh(now: at(1_000, 1110)) // wall clock moved backward; monotonic prevails
precondition(timer.snapshot.remainingAtAnchor == 1470)
timer.refresh(now: at(999_000, 1120)) // wall clock moved forward; monotonic prevails
precondition(timer.snapshot.remainingAtAnchor == 1460)
let encoded = try! JSONEncoder().encode(timer.snapshot)
let restored = try! JSONDecoder().decode(FocusTimerSnapshot.self, from: encoded)
var afterRestart = FocusTimerCore(now: at(999_010, 1130), notifications: notification, restored: restored)
precondition(afterRestart.snapshot.remainingAtAnchor == 1450 && notification.scheduled.last!.0 == 1450)
precondition(afterRestart.refresh(now: at(1_000_460, 2580)))
precondition(afterRestart.snapshot.status == .finished && !afterRestart.refresh(now: at(1_000_461, 2581)))
afterRestart.start(phase: .rest, now: at(100, 100, "new"))
precondition(afterRestart.snapshot.remainingAtAnchor == 300)
let rebooted = FocusTimerCore(now: at(160, 10, "another"), notifications: notification, restored: afterRestart.snapshot)
precondition(rebooted.snapshot.remainingAtAnchor == 240)
afterRestart.end(now: at(101, 101, "new"))
precondition(afterRestart.snapshot.status == .idle && afterRestart.snapshot.remainingAtAnchor == 300)
let invalid = FocusTimerSnapshot(phase: .focus, status: .running, remainingAtAnchor: 1e200, wallAnchor: Date(), continuousAnchor: 1, bootID: "one")
let recovered = FocusTimerCore(now: at(100, 100), notifications: notification, restored: invalid)
precondition(recovered.snapshot.status == .idle && recovered.snapshot.remainingAtAnchor == 1500)
print("FocusTimerCore tests passed")
