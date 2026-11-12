import AppKit
import Foundation

final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Bool, Int)] = []
    func record(_ count: Int) { lock.lock(); calls.append((Thread.isMainThread, count)); lock.unlock() }
    func values() -> [(Bool, Int)] { lock.lock(); defer { lock.unlock() }; return calls }
}

@main struct Run {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let image = context.makeImage()!
        for operation in 0..<3 {
            let probe = Probe()
            let session = ScreenshotEditSession(image: image, renderer: { source, annotations in
                probe.record(annotations.count)
                Thread.sleep(forTimeInterval: 0.25)
                return ScreenshotAnnotationRenderer.render(source, annotations: annotations)
            })
            session.append(.redact(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
            let start = ProcessInfo.processInfo.systemUptime
            switch operation {
            case 0: session.recognize()
            case 1: session.translateLocally(to: "zh-Hans")
            default: session.question = "描述图片"; session.sendQuestion()
            }
            precondition(ProcessInfo.processInfo.systemUptime - start < 0.15, "operation blocked main thread")
            precondition(session.busy)
            try? await Task.sleep(for: .milliseconds(60))
            precondition(probe.values().contains { !$0.0 && $0.1 == 1 }, "expected off-main render of exact redaction snapshot")
            session.close()
            let status = session.status
            try? await Task.sleep(for: .milliseconds(350))
            precondition(!session.busy && session.status == status && session.result.isEmpty, "closed operation must not update or send")
        }
        let changed = ScreenshotEditSession(image: image, renderer: { source, annotations in
            Thread.sleep(forTimeInterval: 0.2)
            return ScreenshotAnnotationRenderer.render(source, annotations: annotations)
        })
        changed.append(.redact(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        changed.recognize()
        try? await Task.sleep(for: .milliseconds(40))
        changed.append(.redact(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)))
        try? await Task.sleep(for: .milliseconds(350))
        precondition(!changed.busy && changed.result.isEmpty && changed.status.isEmpty, "old recognition must not replace newer annotations")
        changed.close()
        print("PASS recognition, translation and question render exact snapshot off main thread; closing cancels stale work")
    }
}
