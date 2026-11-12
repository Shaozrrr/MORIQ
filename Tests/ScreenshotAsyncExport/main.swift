import AppKit
import Foundation

final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Bool, Int)] = []
    func add(_ count: Int) { lock.lock(); samples.append((Thread.isMainThread, count)); lock.unlock() }
    func values() -> [(Bool, Int)] { lock.lock(); defer { lock.unlock() }; return samples }
}

@main struct Run {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let image = context.makeImage()!
        let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.async-export.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-async-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pinned: CGImage?
        let probe = RenderProbe()
        func session() -> ScreenshotEditSession {
            ScreenshotEditSession(image: image, pasteboard: board, renderer: { source, annotations in
                probe.add(annotations.count); Thread.sleep(forTimeInterval: 0.25)
                return ScreenshotAnnotationRenderer.render(source, annotations: annotations)
            }, pinPresenter: { pinned = $0 })
        }
        let cover = ScreenshotAnnotation.redact(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        func blackCenter(_ result: CGImage) -> Bool {
            (NSBitmapImageRep(cgImage: result).colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.01
        }
        for mode in 0..<3 {
            let edit = session(); edit.append(cover)
            let start = ProcessInfo.processInfo.systemUptime
            if mode == 0 { edit.copy() } else if mode == 1 { edit.save(to: directory) } else { edit.pin() }
            precondition(ProcessInfo.processInfo.systemUptime - start < 0.15, "export blocked main thread")
            for _ in 0..<100 {
                if ["已复制图片", "已贴图"].contains(edit.status) || edit.status.hasPrefix("已保存到图片") { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if mode == 0 {
                precondition(edit.status == "已复制图片")
                let copied = NSImage(pasteboard: board)!; var rect = NSRect(origin: .zero, size: copied.size)
                precondition(blackCenter(copied.cgImage(forProposedRect: &rect, context: nil, hints: nil)!))
                precondition(board.data(forType: .png) != nil && board.data(forType: .tiff) != nil)
            } else if mode == 1 {
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                precondition(names.count == 1)
                let loaded = NSImage(contentsOf: directory.appendingPathComponent(names[0]))!; var rect = NSRect(origin: .zero, size: loaded.size)
                precondition(blackCenter(loaded.cgImage(forProposedRect: &rect, context: nil, hints: nil)!))
            } else { precondition(pinned.map(blackCenter) == true) }
            edit.close()
        }
        precondition(probe.values().contains { !$0.0 && $0.1 == 1 })
        // Do not overwrite a newer copy made by another app while rendering.
        let changed = session(); changed.append(cover); changed.copy()
        try await Task.sleep(for: .milliseconds(40))
        board.clearContents(); board.setString("newer user copy", forType: .string)
        try await Task.sleep(for: .milliseconds(500))
        precondition(board.string(forType: .string) == "newer user copy" && changed.status == "剪贴板已更改，请重新复制")
        changed.close()
        // Closing or changing the annotations before rendering completes must
        // cancel a stale copy or pin, including newly added redactions.
        let closed = session(); closed.append(cover); closed.copy(); closed.close()
        try await Task.sleep(for: .milliseconds(400))
        precondition(board.string(forType: .string) == "newer user copy")
        pinned = nil
        let modified = session(); modified.append(cover); modified.pin()
        modified.append(.redact(CGRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        try await Task.sleep(for: .milliseconds(400))
        precondition(pinned == nil)
        modified.close()
        let pendingSaveDirectory = directory.appendingPathComponent("cancelled")
        try FileManager.default.createDirectory(at: pendingSaveDirectory, withIntermediateDirectories: true)
        let closedSave = session(); closedSave.append(cover); closedSave.save(to: pendingSaveDirectory)
        closedSave.close()
        try await Task.sleep(for: .milliseconds(400))
        let cancelledContents = try FileManager.default.contentsOfDirectory(atPath: pendingSaveDirectory.path)
        precondition(cancelledContents.isEmpty)
        let gate = ScreenshotExportGate(); gate.cancel()
        do {
            _ = try ScreenshotExporter.save(image, directory: pendingSaveDirectory, gate: gate)
            fatalError("cancelled save must not publish")
        } catch ScreenshotExportError.cancelled {}
        let gateContents = try FileManager.default.contentsOfDirectory(atPath: pendingSaveDirectory.path)
        precondition(gateContents.isEmpty)
        let changedCopy = session(); changedCopy.append(cover); changedCopy.copy()
        changedCopy.append(.redact(CGRect(x: 0, y: 0, width: 0.1, height: 0.1)))
        try await Task.sleep(for: .milliseconds(400))
        precondition(board.string(forType: .string) == "newer user copy")
        changedCopy.close()
        print("PASS async copy, save and pin preserve redactions; newer clipboard and cancelled exports stay safe")
    }
}
