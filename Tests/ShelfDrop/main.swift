import Foundation
import AppKit
@main struct Test {
    static func main() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-drop-\(UUID().uuidString).txt")
        try! Data("temporary".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = NSItemProvider(object: url as NSURL)
        precondition(ShelfDropDecoder.canLoad(provider))
        let decoded: URL? = await withCheckedContinuation { continuation in
            ShelfDropDecoder.load(provider) { continuation.resume(returning: $0) }
        }
        precondition(decoded?.standardizedFileURL == url.standardizedFileURL)
        let web = NSItemProvider(object: URL(string: "https://example.invalid")! as NSURL)
        let rejected: URL? = await withCheckedContinuation { continuation in
            ShelfDropDecoder.load(web) { continuation.resume(returning: $0) }
        }
        precondition(rejected == nil)
        print("PASS: file drop decoding accepts local files and rejects web URLs")
    }
}
