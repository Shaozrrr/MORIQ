import Foundation
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-moving-alpha-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
try Data(base64Encoded: "R0lGODlheABQAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQJKAAAACwAAAAAeABQAAAI/gABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzhz6tzJs6fPn0CDCh1KFGiAo0iTKl3K9GjRik2jSkX6lOLUq0yrTsTKlarWiF27fgUbFutYiGXNnnWY9upatm2lvm0YV+7chXWj3sWbN+vehH39/j0YeOlghIWVHiac2Otigo0dPxYY2enkgZUDXMZceTPlzp4zewYgOjTozaVRn76cmvXqya1hv34cm/bsxbVx3z6cm/fuwb2B//4bnPjw0ciTK1/OvLnz59CjS59Ovbr169iza9/Ovbt3kQEBACH5BAkoAAAALFAAFAAeACgAgQAAAAAA/wAAAAAAAAg6AAMIHEiwoMGDCBMqXMiwocOHECNKnEixosWLGDNq3Mixo8ePIEOKHEmypMmTKFOqXMmypcuXMDEGBAA7")!.write(to: root.appendingPathComponent("move.gif"))
try Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAdwAATwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAUAAAoAAB0AACcAAJABAANWUDhMDwAAAC8dwAkABxD9j/4HIqL/AQBBTk1GKAAAACgAAAoAAB0AACcAAJABAABWUDhMDwAAAC8dwAkABxDR//4HIqL/AQA=")!.write(to: root.appendingPathComponent("move.webp"))
try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAHgAAABQCAYAAADSm7GJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAB4AAAAUAAAAAAAAAAAAAIABQAAh2wODAAAAJpJREFUeJzt0TEKgEAMAME7//9nBVuvOEEslhlShRSBHQMAAAAAAAAAAICvzN3D857/zRc/8nQsdoQIHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCcwAAAAAAAAAAAAjD0XHeMCUA04e2gAAAAaZmNUTAAAAAEAAABkAAAAKAAAAAoAAAAUAAIABQEATmQIhgAAAH5mZEFUAAAAAnic7dExAQAgDMCwgX/PoICbHomBHl3Dwznzwf4R5c2QGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGEOm5QKuiwJOcr7mVwAAAABJRU5ErkJggg==")!.write(to: root.appendingPathComponent("move.png"))
try Data(base64Encoded: "R0lGODlheABQAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQJAQAAACwAAAAAeABQAAAI/gABCBxIsKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzhz6tzJs6fPn0CDCh1KFGiAo0iTKl3K9GjRik2jSkX6lOLUq0yrTsTKlarWiF27fgUbFutYiGXNnnWY9upatm2lvm0YV+7chXWj3sWbN+vehH39/j0YeOlghIWVHiac2Otigo0dPxYY2enkgZUDXMZceTPlzp4zewYgOjTozaVRn76cmvXqya1hv34cm/bsxbVx3z6cm/fuwb2B//4bnPjw0ciTK1/OvLnz59CjS59Ovbr169iza9/Ovbt3kQEBACH5BAnnAwAALFAAFAAeACgAgQAAAAAA/wAAAAAAAAg6AAMIHEiwoMGDCBMqXMiwocOHECNKnEixosWLGDNq3Mixo8ePIEOKHEmypMmTKFOqXMmypcuXMDEGBAA7")!.write(to: root.appendingPathComponent("long.gif"))
try Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAdwAATwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAUAAAoAAB0AACcAAAoAAANWUDhMDwAAAC8dwAkABxD9j/4HIqL/AQBBTk1GKAAAACgAAAoAAB0AACcAAAYnAABWUDhMDwAAAC8dwAkABxDR//4HIqL/AQA=")!.write(to: root.appendingPathComponent("long.webp"))
try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAHgAAABQCAYAAADSm7GJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAB4AAAAUAAAAAAAAAAAAAEAZAAAidnVywAAAJpJREFUeJzt0TEKgEAMAME7//9nBVuvOEEslhlShRSBHQMAAAAAAAAAAICvzN3D857/zRc/8nQsdoQIHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCdwnMBxAscJHCcwAAAAAAAAAAAAjD0XHeMCUA04e2gAAAAaZmNUTAAAAAEAAABkAAAAKAAAAAoAAAAUA+cAZAEAYdGTkAAAAH5mZEFUAAAAAnic7dExAQAgDMCwgX/PoICbHomBHl3Dwznzwf4R5c2QGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGENiDIkxJMaQGEOm5QKuiwJOcr7mVwAAAABJRU5ErkJggg==")!.write(to: root.appendingPathComponent("long.png"))
let engine = ExternalMediaConverter.executable!
let stride = 120 * 80 * 4
for name in ["move", "long"] {
for inputExt in ["gif", "webp", "png"] {
 for outputExt in ["gif", "webm"] {
  print("CHECK \(name).\(inputExt) → \(outputExt)"); fflush(stdout)
  let source = root.appendingPathComponent("\(name).\(inputExt)")
  let output = try ExternalMediaConverter().convert(input: source, outputDirectory: root, format: UTType(filenameExtension: outputExt)!, video: true)
  let p = Process(); p.executableURL = engine
  p.arguments = ["-nostdin", "-v", "error"] + (outputExt == "webm" ? ["-c:v", "libvpx-vp9"] : ["-min_delay", "0"]) + ["-i", output.path, "-frames:v", "2", "-fps_mode", "passthrough", "-pix_fmt", "rgba", "-f", "rawvideo", "-"]
  let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
  try p.run(); let bytes = [UInt8](pipe.fileHandleForReading.readDataToEndOfFile()); p.waitUntilExit()
  guard p.terminationStatus == 0, bytes.count == 2 * stride else { fatalError("decode failed \(inputExt) to \(outputExt)") }
  func pixel(_ frame: Int, _ x: Int) -> [Int] { let p = frame * stride + (30 * 120 + x) * 4; return (0..<4).map { Int(bytes[p+$0]) } }
  let red = pixel(0, 20), emptyRight = pixel(0, 90), emptyLeft = pixel(1, 20), blue = pixel(1, 90)
  guard red[0] > 200, red[3] > 230, emptyRight[3] < 20, emptyLeft[3] < 20, blue[2] > 200, blue[3] > 230 else {
   fatalError("\(inputExt) to \(outputExt): \(red), \(emptyRight), \(emptyLeft), \(blue)")
  }
  if name == "long" && outputExt == "gif" {
   let decoded = CGImageSourceCreateWithURL(output as CFURL, nil)!
   let delays = (0..<2).map { index -> Double in
    let props = CGImageSourceCopyPropertiesAtIndex(decoded, index, nil) as! [CFString: Any]
    let gif = props[kCGImagePropertyGIFDictionary] as! [CFString: Any]
    return (gif[kCGImagePropertyGIFUnclampedDelayTime] as! NSNumber).doubleValue
   }
   guard abs(delays[0] - 0.01) < 0.001 && abs(delays[1] - 9.99) < 0.011 else { fatalError("wrong GIF timing \(delays)") }
  }
  print("PASS \(name).\(inputExt) → \(outputExt): moving alpha and frame disposal")
 }
}

}
