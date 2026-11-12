import Foundation
import ImageIO
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-unusual-animation-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let input = root.appendingPathComponent("unusual.png")
try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAFAAAAA8CAIAAAB+RarbAAAACGFjVEwAAAADAAAAAM7tusAAAAAaZmNUTAAAAAAAAABQAAAAPAAAAAAAAAAAAAEHzwAA6c3YZQAAAHVJREFUeJzlzjEBADAMgDCGf8+di/YgCvKGFomRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGImRGK8D2z68HAF3TH9TeQAAABpmY1RMAAAAAQAAAFAAAAA8AAAAAAAAAAAAAQfQAABlxNb8AAAAeWZkQVQAAAACeJzlzjEBADAMgDCGf8+di/YgCvIYUiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYiRGYrwObPu7HQF3rBzRkgAAABpmY1RMAAAAAwAAAFAAAAA8AAAAAAAAAAAAAQfPAACfKOFYAAAAemZkQVQAAAAEeJzlzjEBADAMgDCGf8+di/YgCvJgKJEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYiZEYifE6sO0Duh4Bd0LblqsAAAAASUVORK5CYII=")!.write(to: input)
precondition(ExternalMediaConverter.isAnimatedImage(input))
var failures = 0
for target in ExternalMediaConverter.videoTargets() where target != .gif {
 do {
  _ = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: target, video: true)
  print("FAIL: conversion unexpectedly succeeded: \(target)"); failures += 1
 } catch ExternalMediaError.timingUnsupported {
  print("PASS: unusual frame timing rejected for \(target)")
 } catch {
  print("FAIL: unexpected error \(error)"); failures += 1
 }
}
let remaining = try fm.contentsOfDirectory(atPath: root.path)
if remaining != ["unusual.png"] { print("FAIL: unexpected outputs \(remaining)"); failures += 1 }
exit(failures == 0 ? 0 : 1)
