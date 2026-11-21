import Foundation
var state = IslandInteraction()
func tick(_ t: Double, _ screen: UInt32? = 1, _ trigger: Bool = false, _ inside: Bool = false, _ interacting: Bool = false) {
    state.sample(now: t, screen: screen, inTrigger: trigger, inPanelOrCorridor: inside, interacting: interacting)
}
tick(0, 1, true); tick(0.1, 1, true); precondition(state.phase == .hidden)
tick(0.17, 1, true); precondition(state.phase == .expanded)
tick(0.6, 1, false, false); tick(0.9, 1, false, true); tick(1.0, 1, false, false)
tick(1.46, 1, false, false); precondition(state.phase == .hidden)
tick(2, 1, true); tick(2.17, 1, true); precondition(state.phase == .expanded)
tick(2.3, 2, false, false, true); tick(3, 2, false, false, true); precondition(state.phase == .expanded)
state.reset(); tick(4, 1, true); tick(4.12, 2, true); tick(4.18, 2, true); precondition(state.phase == .hidden)
tick(4.3, 2, true); precondition(state.phase == .expanded)
print("Island direct content reveal, delay and screen isolation passed")
