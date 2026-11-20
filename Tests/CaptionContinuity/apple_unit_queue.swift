import Foundation
import CryptoKit

@main struct AppleUnitQueueTests {
    static func main() {
        let session = UUID(), epoch = UUID(), stream = UUID(), first = UUID(), second = UUID()
        let source = "Hello. Next."
        func marker(_ id: UUID, _ start: Int, _ end: Int) -> SourceMarker {
            let bytes = Array(source.utf8)[start..<end]
            let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            return SourceMarker(type: "source_unit_v2", session: session, epoch: epoch, unit: id,
                                original_stream_id: stream, revision: 1, batch_seq: 1,
                                confirmed_through_byte: source.utf8.count, start_byte: start,
                                end_byte: end, source_sha256: digest, boundary_reason: "endpoint")
        }
        var queue = CaptionLocalTranslationQueue(session: session, epoch: epoch, target: "zh-Hans")
        let a = marker(first, 0, 6), b = marker(second, 7, 12)
        var verifier = SourceV2Verifier(session: session, epoch: epoch, stream: stream)
        verifier.commitBatch(1, confirmed: source)
        for marker in [a, b] {
            let payload: [String: Any] = [
                "type": marker.type, "session": session.uuidString, "epoch": epoch.uuidString,
                "unit": marker.unit.uuidString, "original_stream_id": stream.uuidString,
                "revision": marker.revision, "batch_seq": marker.batch_seq,
                "confirmed_through_byte": marker.confirmed_through_byte,
                "start_byte": marker.start_byte, "end_byte": marker.end_byte,
                "source_sha256": marker.source_sha256, "boundary_reason": marker.boundary_reason
            ]
            verifier.marker(try! JSONSerialization.data(withJSONObject: payload))
        }
        precondition(verifier.reviewEnabled && verifier.acceptedMarkers.count == 2)
        precondition(queue.enqueue(verifier.acceptedMarkers[0], confirmed: source))
        precondition(!queue.enqueue(a, confirmed: source))
        precondition(queue.enqueue(verifier.acceptedMarkers[1], confirmed: source))
        let firstWork = queue.pending[0], secondWork = queue.pending[1]
        precondition(queue.complete(secondWork, text: "下一句。"))
        precondition(queue.visible.isEmpty)
        precondition(queue.complete(firstWork, text: "歡迎。"))
        precondition(queue.visible == "欢迎。 下一句。")
        precondition(!queue.complete(firstWork, text: "旧结果"))
        var next = CaptionLocalTranslationQueue(session: session, epoch: UUID(), target: "zh-Hans")
        precondition(!next.enqueue(a, confirmed: source))
        precondition(!next.complete(firstWork, text: "过期结果"))
        var invalid = CaptionLocalTranslationQueue(session: session, epoch: epoch, target: "zh-Hans")
        precondition(!invalid.enqueue(a, confirmed: "Changed source"))
        var failed = CaptionLocalTranslationQueue(session: session, epoch: epoch, target: "zh-Hans")
        precondition(failed.enqueue(a, confirmed: source))
        let failingWork = failed.pending[0]
        precondition(failed.fail(failingWork) && failed.hasFailure)
        precondition(!failed.complete(failingWork, text: "迟到"))
        precondition(!failed.enqueue(b, confirmed: source))
        print("PASS local translation unit ordering, fencing and simplified output")
    }
}
