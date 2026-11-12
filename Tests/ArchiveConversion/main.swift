import Foundation
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-archive-test-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let folder = root.appendingPathComponent("示例资料", isDirectory: true)
try fm.createDirectory(at: folder, withIntermediateDirectories: true)
let file = folder.appendingPathComponent("note.txt")
try Data("MORIQ archive 4826".utf8).write(to: file)
let archive = try ArchiveConverter().zip(input: folder, outputDirectory: root)
let second = try ArchiveConverter().zip(input: folder, outputDirectory: root)
precondition(archive != second && fm.fileExists(atPath: file.path))
let destination = root.appendingPathComponent("unpacked", isDirectory: true)
try fm.createDirectory(at: destination, withIntermediateDirectories: true)
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
process.arguments = ["-x", "-k", archive.path, destination.path]
try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
let extracted = destination.appendingPathComponent("示例资料/note.txt")
let extractedData = try Data(contentsOf: extracted)
precondition(extractedData == Data("MORIQ archive 4826".utf8))
for gzip in [false, true] {
    let first = try ArchiveConverter().tar(input: folder, outputDirectory: root, gzip: gzip)
    let second = try ArchiveConverter().tar(input: folder, outputDirectory: root, gzip: gzip)
    precondition(first != second && fm.fileExists(atPath: file.path))
    let unpack = root.appendingPathComponent(gzip ? "untar-gzip" : "untar", isDirectory: true)
    try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
    let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    extract.arguments = [gzip ? "-xzf" : "-xf", first.path, "-C", unpack.path]
    try extract.run(); extract.waitUntilExit(); precondition(extract.terminationStatus == 0)
    let contents = try Data(contentsOf: unpack.appendingPathComponent("示例资料/note.txt"))
    precondition(contents == Data("MORIQ archive 4826".utf8))
}
let names = try fm.contentsOfDirectory(atPath: root.path)
precondition(!names.contains { $0.hasPrefix(".moriq-") })
print("PASS: folder to ZIP, TAR and TAR.GZ with extraction, unicode names, collision avoidance, originals retained")
