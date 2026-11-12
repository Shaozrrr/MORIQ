import Foundation
import CoreGraphics
import ImageIO
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-export-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: folder) }
let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
let image = context.makeImage()!
let protected = folder.appendingPathComponent("MORIQ 截图.png")
try Data("existing file".utf8).write(to: protected)
let first = try ScreenshotExporter.save(image, directory: folder)
let second = try ScreenshotExporter.save(image, directory: folder)
precondition(first.lastPathComponent == "MORIQ 截图 (2).png" && second.lastPathComponent == "MORIQ 截图 (3).png")
let protectedData = try Data(contentsOf: protected)
precondition(protectedData == Data("existing file".utf8))
let reopened = CGImageSourceCreateWithURL(first as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
precondition(reopened?.width == 100 && reopened?.height == 60)
let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
precondition(names.allSatisfy { !$0.hasSuffix(".tmp") })
do { _ = try ScreenshotExporter.save(image, directory: folder.appendingPathComponent("missing")); fatalError("expected error") } catch ScreenshotExportError.invalidDirectory {}
print("PASS: PNG export, collision avoidance, intact existing files, temp cleanup and invalid directory")
