import Foundation
let recognizer = BoundedTextRecognizer()
precondition(recognizer.recognize(timeout:1) { "文字" } == "文字")
let blocker = DispatchSemaphore(value:0)
let start = Date()
precondition(recognizer.recognize(timeout:0.05) { blocker.wait(); return "late" }.isEmpty)
precondition(Date().timeIntervalSince(start) < 1)
let start2 = Date()
precondition(recognizer.recognize(timeout:1) { "duplicate" }.isEmpty)
precondition(Date().timeIntervalSince(start2) < 0.2)
blocker.signal()
var recovered = false
for _ in 0..<100 {
 if recognizer.recognize(timeout:0.2,work:{"fresh"}) == "fresh" { recovered = true; break }
 Thread.sleep(forTimeInterval:0.01)
}
precondition(recovered)
print("PASS: stalled OCR times out, remains single-flight and recovers")
