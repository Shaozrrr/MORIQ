import Foundation
import UniformTypeIdentifiers
#if DEBUG
fatalError("compile this test without DEBUG")
#endif
precondition(DocumentConverter.officeEngine == nil,"expected no bundled or system office engine in isolated test")
let dir=FileManager.default.temporaryDirectory.appendingPathComponent("moriq-no-office-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:dir)}
let source=dir.appendingPathComponent("source.txt");try Data("hello".utf8).write(to:source)
do { _ = try DocumentConverter().convert(input:source,outputDirectory:dir,format:.pdf); fatalError("missing engine unexpectedly succeeded") }
catch DocumentConversionError.engineMissing { print("PASS release does not fall back to Codex cache and clearly reports missing office") }
