import Foundation
import UniformTypeIdentifiers
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-archive-batch-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let a = root.appendingPathComponent("一.txt"); let folder = root.appendingPathComponent("资料", isDirectory: true)
try fm.createDirectory(at: folder, withIntermediateDirectories: false)
try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: folder.appendingPathComponent("二.txt"))
try Data("hidden".utf8).write(to: folder.appendingPathComponent(".隐藏"))
try fm.createSymbolicLink(atPath: folder.appendingPathComponent("链接").path, withDestinationPath: "二.txt")
for type in [UTType.zip, ArchiveConverter.tarType, ArchiveConverter.tarGzipType] {
 let archive = try ArchiveConverter().batch(inputs: [a, folder], outputDirectory: root, format: type)
 let another = try ArchiveConverter().batch(inputs: [a, folder], outputDirectory: root, format: type)
 precondition(archive != another && fm.fileExists(atPath: a.path))
 let target = root.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: target, withIntermediateDirectories: false)
 let p = Process()
 if type == .zip { p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", archive.path, target.path] }
 else { p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = ["-xf", archive.path, "-C", target.path] }
 p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
 let first = try Data(contentsOf: target.appendingPathComponent("一.txt"))
 precondition(first == Data("first".utf8))
 let second = try Data(contentsOf: target.appendingPathComponent("资料/二.txt"))
 precondition(second == Data("second".utf8))
 let hidden = try Data(contentsOf: target.appendingPathComponent("资料/.隐藏")); precondition(hidden == Data("hidden".utf8))
 let link = try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("资料/链接").path); precondition(link == "二.txt")
 print("PASS batch archive with hidden file and relative symlink \(archive.pathExtension)")
}
let other = root.appendingPathComponent("other", isDirectory: true); try fm.createDirectory(at: other, withIntermediateDirectories: false)
let duplicate = other.appendingPathComponent("一.txt"); try Data("different".utf8).write(to: duplicate)
do { _ = try ArchiveConverter().batch(inputs: [a, duplicate], outputDirectory: root, format: .zip); fatalError("duplicate names accepted") }
catch ArchiveConversionError.duplicateNames { print("PASS duplicate name rejected") }

let nested = folder.appendingPathComponent("二.txt")
let nestedArchive = try ArchiveConverter().batch(inputs: [nested, folder], outputDirectory: folder, format: .zip)
precondition(nestedArchive.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
let check = root.appendingPathComponent("nested-unpack"); try fm.createDirectory(at: check, withIntermediateDirectories: false)
let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); extract.arguments = ["-x", "-k", nestedArchive.path, check.path]
extract.standardOutput = FileHandle.nullDevice; extract.standardError = FileHandle.nullDevice; try extract.run(); extract.waitUntilExit(); precondition(extract.terminationStatus == 0)
let nestedFiles = try fm.contentsOfDirectory(atPath: check.appendingPathComponent("资料").path)
precondition(!nestedFiles.contains { $0.hasPrefix(".moriq-") })
print("PASS archive stays outside selected parent folder")
