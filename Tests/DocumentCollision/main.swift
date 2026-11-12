import Foundation
import UniformTypeIdentifiers

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-collision-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("sample.txt")
let original = Data("原始文本 MORIQ 4826".utf8)
try original.write(to: source)
let occupied = root.appendingPathComponent("sample.docx")
let sentinel = Data("existing unrelated file".utf8)
try sentinel.write(to: occupied)
let type = UTType(filenameExtension: "docx")!
let lock = NSLock()
var results: [URL] = [], failures = 0
DispatchQueue.concurrentPerform(iterations: 2) { _ in
    do {
        let result = try DocumentConverter().convert(input: source, outputDirectory: root, format: type)
        lock.lock(); results.append(result); lock.unlock()
    } catch { lock.lock(); failures += 1; lock.unlock() }
}
precondition(failures == 0 && results.count == 2 && Set(results).count == 2)
let sourceAfter = try Data(contentsOf: source), occupiedAfter = try Data(contentsOf: occupied)
precondition(sourceAfter == original && occupiedAfter == sentinel)
for result in results { let data = try Data(contentsOf: result); precondition(data.prefix(2) == Data([0x50, 0x4b])) }
let invalid = root.appendingPathComponent("broken.docx")
try Data("not a document".utf8).write(to: invalid)
do { _ = try DocumentConverter().convert(input: invalid, outputDirectory: root, format: .pdf); fatalError("invalid input accepted") }
catch DocumentConversionError.invalidInput { precondition(!fm.fileExists(atPath: root.appendingPathComponent("broken.pdf").path)) }
let fake = root.appendingPathComponent("fake.docx")
let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
zip.arguments = ["-c", "-k", source.path, fake.path]; try zip.run(); zip.waitUntilExit(); precondition(zip.terminationStatus == 0)
do { _ = try DocumentConverter().convert(input: fake, outputDirectory: root, format: .pdf); fatalError("unrelated ZIP accepted as DOCX") }
catch DocumentConversionError.invalidInput { precondition(!fm.fileExists(atPath: root.appendingPathComponent("fake.pdf").path)) }
let names = try fm.contentsOfDirectory(atPath: root.path)
precondition(!names.contains { $0.hasPrefix(".moriq-") })
print("PASS concurrent conversions preserve originals and existing outputs; invalid inputs leave no result or scratch")
