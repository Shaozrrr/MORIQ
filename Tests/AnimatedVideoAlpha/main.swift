import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-animation-alpha-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("transparent.gif")
let gif = CGImageDestinationCreateWithURL(input as CFURL, UTType.gif.identifier as CFString, 2, nil)!
for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
 let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.clear(CGRect(x: 0, y: 0, width: 120, height: 80)); ctx.setFillColor(color); ctx.fill(CGRect(x: 30, y: 20, width: 60, height: 40))
 CGImageDestinationAddImage(gif, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(gif))
let webp = root.appendingPathComponent("transparent.webp")
try Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAdwAATwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAA8AAAoAADsAACcAAJABAAJWUDhMDwAAAC87wAkABxD9j/4HIqL/AQBBTk1GKAAAAA8AAAoAADsAACcAAJABAABWUDhMDwAAAC87wAkABxDR//4HIqL/AQA=")!.write(to: webp)
let apng = root.appendingPathComponent("transparent.png")
try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAHgAAABQCAYAAADSm7GJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAB4AAAAUAAAAAAAAAAAAAIABQAAh2wODAAAAJdJREFUeJzt0UEKgEAMBMGs//+zgi/wIC60VeQemJ4BAAAAAAAAAADgLWs2Oe/7j7Vp62PHU74jcJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAcQLHCRwncJzAAAAAAAAAAAAAMM9cfOQCUKRswdIAAAAaZmNUTAAAAAEAAAA8AAAAKAAAAB4AAAAUAAIABQAAHrtEKQAAAFxmZEFUAAAAAnic5c4xAQAwDIAwhn/PnYv2IAryYIYQiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYrwPbPgpeAk4AWcROAAAAAElFTkSuQmCC")!.write(to: apng)
for source in [input, webp, apng] {
guard (ExternalMediaConverter.animationResultNotice(input: source, outputExtension: "mp4") ?? "").contains("透明") else { fatalError("missing transparency notice for \(source.pathExtension)") }
guard (ExternalMediaConverter.animationResultNotice(input: source, outputExtension: "gif") ?? "").contains("透明") else { fatalError("missing GIF transparency notice for \(source.pathExtension)") }
guard ExternalMediaConverter.animationResultNotice(input: source, outputExtension: "webm") == nil else { fatalError("unexpected WebM transparency notice") }
for ext in ["webm", "gif"] {
 print("CHECK animated \(source.pathExtension) → \(ext)"); fflush(stdout)
 let result = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: ext)!, video: true)
 let p = Process(); p.executableURL = ExternalMediaConverter.executable!
 p.arguments = ["-nostdin", "-v", "error"] + (ext == "webm" ? ["-c:v", "libvpx-vp9"] : []) + ["-i", result.path, "-frames:v", "2", "-fps_mode", "passthrough", "-pix_fmt", "rgba", "-f", "rawvideo", "-"]
 let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
 try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); precondition(p.terminationStatus == 0 && data.count >= 120*80*4*2)
 let bytes = [UInt8](data); let stride = 120 * 80 * 4
 for frame in 0..<2 {
  let corner = bytes[frame * stride + 3], center = bytes[frame * stride + (40 * 120 + 60) * 4 + 3]
  guard corner < 20 && center > 230 else { print("FAIL \(ext) frame \(frame) alpha corner=\(corner) center=\(center)"); exit(1) }
  let position = frame * stride + (40 * 120 + 60) * 4
  let red = Int(bytes[position]), blue = Int(bytes[position + 2])
  guard frame == 0 ? red > blue + 100 : blue > red + 100 else { print("FAIL \(ext) frame \(frame) color red=\(red) blue=\(blue)"); exit(1) }
 }
 print("PASS animated \(source.pathExtension) → \(ext) retains transparency in both frames")
}
}
