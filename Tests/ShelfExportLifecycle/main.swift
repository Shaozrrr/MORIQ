import AppKit
import Foundation

@main struct Run {
    @MainActor static func main() {
        let state = ShelfState()
        precondition(!state.mayCollapse)
        state.expanded = true
        precondition(state.mayCollapse)
        // An already-scheduled close must be rejected after export starts.
        state.exporting = true
        precondition(!state.mayCollapse)
        state.exporting = false
        precondition(state.mayCollapse)
        state.pendingDrops = 1
        precondition(!state.mayCollapse)
        state.pendingDrops = 0
        state.dropError = "not available"
        precondition(!state.mayCollapse)
        state.dropError = nil
        precondition(state.mayCollapse)
        print("PASS shelf remains open during outgoing drag and pending or failed incoming drops")
    }
}
