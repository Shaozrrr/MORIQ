import Foundation
import UniformTypeIdentifiers
import Darwin
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-meta-cancel-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
guard let engine = ExternalMediaConverter.executable else { fatalError("no ffmpeg") }
let input = root.appendingPathComponent("in.mka")
let generator = Process(); generator.executableURL = engine
generator.arguments = ["-nostdin","-v","error","-f","lavfi","-i","sine=frequency=440","-f","lavfi","-i","sine=frequency=880","-t","0.2","-map","0:a","-map","1:a","-metadata:s:a:0","title=sample","-c:a","pcm_s16le",input.path]
generator.standardError = FileHandle.nullDevice; try generator.run(); generator.waitUntilExit(); precondition(generator.terminationStatus == 0)
let wrapper = root.appendingPathComponent("ffmpeg-test")
try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: wrapper)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
setenv("MORIQ_TEST_FFMPEG", wrapper.path, 1)
let done = DispatchSemaphore(value: 0)
let task = Task.detached {
    do {
        _ = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "m4a")!, video: false)
        fatalError("cancelled conversion published output")
    } catch is CancellationError { print("PASS cancellation avoids publishing partial output") }
    catch { fatalError("unexpected error \(error)") }
    done.signal()
}
Thread.sleep(forTimeInterval: 0.2); let cancelledAt = Date(); task.cancel()
precondition(done.wait(timeout: .now() + 2) == .success)
precondition(Date().timeIntervalSince(cancelledAt) < 1.5, "child was not stopped promptly")
let files = try fm.contentsOfDirectory(atPath: root.path)
precondition(!files.contains { $0.hasSuffix(".m4a") || $0.contains("转换结果") || $0.hasPrefix(".moriq-") })
let marker = root.appendingPathComponent("metadata-started")
let escapedEngine = engine.path.replacingOccurrences(of: "'", with: "'\\''")
let escapedMarker = marker.path.replacingOccurrences(of: "'", with: "'\\''")
let script = "#!/bin/sh\ncase \" $* \" in *\" -f ffmetadata \"*) touch '" + escapedMarker + "'; exec /bin/sleep 10;; esac\nexec '" + escapedEngine + "' \"$@\"\n"
try Data(script.utf8).write(to: wrapper)
let secondDone = DispatchSemaphore(value: 0)
let second = Task.detached {
    do { _ = try ExternalMediaConverter().convert(input: input, outputDirectory: root, format: UTType(filenameExtension: "m4a")!, video: false); fatalError("cancelled metadata published output") }
    catch is CancellationError { print("PASS metadata process stopped promptly") }
    catch { fatalError("unexpected error \(error)") }
    secondDone.signal()
}
let until = Date().addingTimeInterval(8)
while !fm.fileExists(atPath: marker.path) && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
precondition(fm.fileExists(atPath: marker.path), "metadata export did not start")
let stoppedAt = Date(); second.cancel()
precondition(secondDone.wait(timeout: .now() + 2) == .success && Date().timeIntervalSince(stoppedAt) < 1.5)
let remaining = try fm.contentsOfDirectory(atPath: root.path)
precondition(!remaining.contains { $0.hasSuffix(".m4a") || $0.contains("转换结果") || $0.hasPrefix(".moriq-") })
unsetenv("MORIQ_TEST_FFMPEG")
