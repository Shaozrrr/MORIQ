import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-image-cancel-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("fixture.tiff")
let context = CGContext(data: nil, width: 1000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
let image = context.makeImage()!, dest = CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 60, nil)!
for _ in 0..<60 { CGImageDestinationAddImage(dest, image, nil) }
precondition(CGImageDestinationFinalize(dest))
let existing = root.appendingPathComponent("fixture 页面")
try fm.createDirectory(at: existing, withIntermediateDirectories: false)
try Data("keep".utf8).write(to: existing.appendingPathComponent("sentinel"))
for format in [UTType.png, UTType.pdf] {
    let done = DispatchSemaphore(value: 0)
    let task = Task.detached {
        do { _ = try ImageConverter().convert(input: input, outputDirectory: root, format: format); fatalError("cancelled conversion published") }
        catch is CancellationError {} catch { fatalError("unexpected \(error)") }
        done.signal()
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if (try! fm.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".moriq-") }) { break }
        Thread.sleep(forTimeInterval: 0.005)
    }
    let startedFiles = try fm.contentsOfDirectory(atPath: root.path)
    precondition(startedFiles.contains { $0.hasPrefix(".moriq-") })
    task.cancel(); precondition(done.wait(timeout: .now() + 10) == .success)
    let files = try fm.contentsOfDirectory(atPath: root.path)
    precondition(!files.contains { $0.hasPrefix(".moriq-") || $0 == "fixture.pdf" || $0 == "fixture 页面 (2)" })
    let sentinel = try Data(contentsOf: existing.appendingPathComponent("sentinel"))
    precondition(sentinel == Data("keep".utf8))
}
let single = root.appendingPathComponent("single.tiff")
let large = CGContext(data: nil, width: 4000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
large.setFillColor(NSColor.systemRed.cgColor); large.fill(CGRect(x: 0, y: 0, width: 4000, height: 4000))
let singleDest = CGImageDestinationCreateWithURL(single as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(singleDest, large.makeImage()!, nil); precondition(CGImageDestinationFinalize(singleDest))
let done = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
let singleTask = Task.detached {
    let converter = ImageConverter(debugBeforePublish: { ready.signal(); resume.wait() })
    do { _ = try converter.convert(input: single, outputDirectory: root, format: .png); fatalError("single image published after cancellation") }
    catch is CancellationError {} catch { fatalError("unexpected \(error)") }
    done.signal()
}
precondition(ready.wait(timeout: .now() + 10) == .success, "encoding did not reach pre-publish checkpoint")
precondition(!fm.fileExists(atPath: root.appendingPathComponent("single.png").path))
singleTask.cancel(); resume.signal()
precondition(done.wait(timeout: .now() + 10) == .success)
precondition(!(try! fm.contentsOfDirectory(atPath: root.path)).contains { $0 == "single.png" || $0.hasPrefix(".moriq-") })
let result = try ImageConverter().convert(input: input, outputDirectory: root, format: .png)
let pages = try fm.contentsOfDirectory(atPath: result.path)
precondition(result.lastPathComponent == "fixture 页面 (2)" && pages.count == 60)
print("PASS in-progress multipage image/PDF cancellation, atomic publishing and normal conversion")
