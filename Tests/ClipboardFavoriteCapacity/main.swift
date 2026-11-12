import AppKit
import Foundation
let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.capacity.\(UUID().uuidString)"))
MainActor.assumeIsolated {
 let store = ClipboardStore(board: board, persistent: false)
 @MainActor func put(_ value: String) {
  board.clearContents(); board.setString(value, forType: .string); store.poll(); store.waitForCaptures()
 }
 for i in 0..<105 { put("Favorite sample \(i)"); store.toggleFavorite(store.items[0]) }
 precondition(store.favorites.count == 105 && store.items.count == 105)
 for i in 0..<101 { put("History sample \(i)") }
 precondition(store.items.count == 205)
 precondition(store.items.filter { store.favorites.contains($0.id) }.count == 105)
 precondition(store.items.filter { !store.favorites.contains($0.id) }.count == 100)
 precondition(store.items.first?.text == "History sample 100")
 store.clearHistory()
 precondition(store.items.count == 105 && store.items.allSatisfy { store.favorites.contains($0.id) })
 print("PASS 105 favorites coexist with 100 rolling history entries")
}
