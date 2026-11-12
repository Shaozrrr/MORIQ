import AppKit
import Foundation
import ImageIO

@main struct Run {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let width = 3840, height = 2160
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let board = NSPasteboard(name: NSPasteboard.Name("local.moriq.large-export.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let edit = ScreenshotEditSession(image: image, pasteboard: board)
        edit.append(.redact(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        let start = ProcessInfo.processInfo.systemUptime
        edit.copy()
        let callTime = ProcessInfo.processInfo.systemUptime - start
        guard callTime < 0.15 else { fatalError("copy invocation blocked main thread \(callTime)") }
        for _ in 0..<500 {
            if edit.status == "已复制图片" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard edit.status == "已复制图片", let data = board.data(forType: .png),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let result = CGImageSourceCreateImageAtIndex(source, 0, nil), result.width == width, result.height == height else { fatalError("large copy failed") }
        let pixel = NSBitmapImageRep(cgImage: result).colorAt(x: width / 2, y: height / 2)!.usingColorSpace(.deviceRGB)!
        precondition(pixel.redComponent < 0.01 && pixel.greenComponent < 0.01 && pixel.blueComponent < 0.01)
        print("PASS 4K redacted copy: call \(String(format: "%.3f", callTime))s, completed \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))s")
        edit.close()
    }
}
