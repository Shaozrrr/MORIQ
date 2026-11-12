import Foundation
import UniformTypeIdentifiers
import Darwin
import ImageIO

enum ExternalMediaError: Error { case unavailable, unsupported, unsupportedTracks, failed, timingUnsupported, filesystem(Int32) }
struct ExternalMediaConverter {
    private static func wait(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                let cancelled = Task.isCancelled
                process.terminate()
                let grace = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancelled { throw CancellationError() }
                throw ExternalMediaError.failed
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
    }
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    private static func readOutput(_ pipe: Pipe, process: Process, timeout: TimeInterval) throws -> Data {
        let buffer = OutputBuffer(), done = DispatchGroup(); done.enter()
        DispatchQueue.global(qos: .utility).async { buffer.set(pipe.fileHandleForReading.readDataToEndOfFile()); done.leave() }
        do { try wait(process, timeout: timeout) } catch { done.wait(); throw error }
        done.wait()
        return buffer.get()
    }
    private struct TrackCounts { var video = 0; var audio = 0; var subtitle = 0; var unsupported = 0 }
    private func tracks(_ input: URL, engine: URL) -> TrackCounts? {
        let p = Process(); p.executableURL = engine
        p.arguments = ["-nostdin", "-hide_banner", "-protocol_whitelist", "file,pipe", "-i", input.path]
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        guard let data = try? Self.readOutput(pipe, process: p, timeout: 30) else { return nil }
        guard let description = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"(?m)^\s*Stream #0:\d+(?:\[[^\]]*\])?(?:\([^\)]*\))?:\s*(Video|Audio|Subtitle|Data|Attachment):"#) else { return nil }
        var result = TrackCounts()
        for match in expression.matches(in: description, range: NSRange(description.startIndex..., in: description)) {
            guard let range = Range(match.range(at: 1), in: description) else { return nil }
            switch description[range] { case "Video": result.video += 1; case "Audio": result.audio += 1; case "Subtitle": result.subtitle += 1; default: result.unsupported += 1 }
        }
        return result.video > 0 ? result : nil
    }
    /// When the requested container cannot carry every source track, place the
    /// transcoded main video and losslessly copied side tracks in one folder.
    /// Abort the entire staged result if any source stream cannot be retained.
    private func splitVideoTracks(input: URL, outputDirectory: URL, ext: String, codecs: [String], engine: URL) throws -> URL {
        guard let counts = tracks(input, engine: engine), counts.unsupported == 0,
              counts.subtitle > 0 || counts.audio > 1 || counts.video > 1 else { throw ExternalMediaError.failed }
        let fm = FileManager.default
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        func export(_ args: [String], to output: URL) throws {
            let p = Process(); p.executableURL = engine
            p.arguments = ["-nostdin", "-v", "error", "-xerror", "-n", "-protocol_whitelist", "file,pipe", "-i", input.path] + args + [output.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { throw ExternalMediaError.failed }
            try Self.wait(p, timeout: 600)
            guard p.terminationStatus == 0, let size = (try? fm.attributesOfItem(atPath: output.path)[.size]) as? NSNumber, size.intValue > 0 else { throw ExternalMediaError.failed }
        }
        try export(["-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "0"] + codecs, to: scratch.appendingPathComponent("视频.\(ext)"))
        if counts.video > 1 { for i in 1..<counts.video {
            try export(["-map", "0:v:\(i)", "-c", "copy", "-f", "matroska"], to: scratch.appendingPathComponent("画面 \(i + 1).mkv"))
        }}
        if counts.audio > 1 { for i in 1..<counts.audio {
            try export(["-map", "0:a:\(i)", "-c", "copy", "-f", "matroska"], to: scratch.appendingPathComponent("音轨 \(i + 1).mka"))
        }}
        if counts.subtitle > 0 { for i in 0..<counts.subtitle {
            try export(["-map", "0:s:\(i)", "-c", "copy", "-f", "matroska"], to: scratch.appendingPathComponent("字幕 \(i + 1).mks"))
        }}
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            let suffix = number == 1 ? "" : " (\(number))"
            let destination = outputDirectory.appendingPathComponent("\(name) 转换结果\(suffix)", isDirectory: true)
            let result = scratch.withUnsafeFileSystemRepresentation { src in destination.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
            if result == 0 { return destination }
            if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
        }
        throw ExternalMediaError.failed
    }
    private func audioStreamInfo(_ input: URL, engine: URL) -> (count: Int, floatBits: Int?)? {
        let process = Process(); process.executableURL = engine
        process.arguments = ["-nostdin", "-hide_banner", "-protocol_whitelist", "file,pipe", "-i", input.path]
        let output = Pipe(); process.standardError = output; process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        guard let data = try? Self.readOutput(output, process: process, timeout: 30) else { return nil }
        guard let description = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?m)^\s*Stream #0:\d+(?:\[[^\]]*\])?(?:\([^\)]*\))?: Audio:\s*([a-zA-Z0-9_]+)"#) else { return nil }
        let range = NSRange(description.startIndex..., in: description)
        let matches = regex.matches(in: description, range: range)
        guard !matches.isEmpty else { return nil }
        let codecs = matches.compactMap { match in Range(match.range(at: 1), in: description).map { String(description[$0]).lowercased() } }
        let floatBits: Int? = codecs.contains(where: { $0.hasPrefix("pcm_f64") }) ? 64 : (codecs.contains(where: { $0.hasPrefix("pcm_f32") }) ? 32 : nil)
        return (matches.count, floatBits)
    }

    /// Save original per-stream tags when a target container cannot represent
    /// them. FFmpeg's ffmetadata muxer handles escaping and Unicode values.
    // FFmetadata escapes a literal newline as a backslash followed by a
    // newline. Compare complete records and preserve duplicate occurrences;
    // comparing a set of physical lines can falsely report data as preserved.
    static func metadataEntries(_ text: String) -> [String: Int] {
        var records: [String: Int] = [:], current = ""
        func add(_ record: String) {
            let lower = record.lowercased()
            guard !record.isEmpty, !record.hasPrefix(";"), !lower.hasPrefix("encoder="), !lower.hasPrefix("duration=") else { return }
            records[record, default: 0] += 1
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let part = String(line)
            current += part
            let slashes = part.reversed().prefix { $0 == "\\" }.count
            if slashes % 2 == 1 { current += "\n"; continue }
            add(current); current = ""
        }
        if !current.isEmpty { add(current) }
        return records
    }
    private func streamMetadata(input: URL, index: Int, engine: URL, destination: URL) throws -> [String: Int] {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = engine
        process.arguments = ["-nostdin", "-v", "error", "-xerror", "-n", "-protocol_whitelist", "file,pipe", "-i", input.path, "-map_metadata", "0:s:a:\(index)", "-map_chapters", "-1", "-f", "ffmetadata", destination.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ExternalMediaError.failed }
        try Self.wait(process, timeout: 30)
        try Task.checkCancellation()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: destination),
              let text = String(data: data, encoding: .utf8) else { throw ExternalMediaError.failed }
        return Self.metadataEntries(text)
    }
    private func publishAudioWithMetadata(input: URL, output: URL, outputDirectory: URL, engine: URL, count: Int) throws -> URL? {
        let fm = FileManager.default
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        var missing = false
        for index in 0..<count {
            try Task.checkCancellation()
            let source = scratch.appendingPathComponent("音轨 \(index + 1) 元数据.ffmetadata")
            let target = scratch.appendingPathComponent(".output-\(index).ffmetadata")
            let expected = try streamMetadata(input: input, index: index, engine: engine, destination: source)
            let actual = try streamMetadata(input: output, index: index, engine: engine, destination: target)
            try fm.removeItem(at: target)
            if expected.contains(where: { actual[$0.key, default: 0] < $0.value }) { missing = true }
        }
        try Task.checkCancellation()
        guard missing else { return nil }
        let name = input.deletingPathExtension().lastPathComponent
        try fm.moveItem(at: output, to: scratch.appendingPathComponent(name).appendingPathExtension(output.pathExtension))
        for number in 1...10000 {
            let suffix = number == 1 ? "" : " (\(number))"
            let destination = outputDirectory.appendingPathComponent("\(name) 转换结果\(suffix)", isDirectory: true)
            let result = scratch.withUnsafeFileSystemRepresentation { src in destination.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
            if result == 0 { return destination }
            if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
        }
        throw ExternalMediaError.failed
    }
    private func splitAudio(input: URL, outputDirectory: URL, ext: String, codecs: [String], engine: URL, count: Int) throws -> URL {
        let fm = FileManager.default
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        for index in 0..<count {
            try Task.checkCancellation()
            let output = scratch.appendingPathComponent("音轨 \(index + 1).\(ext)")
            let process = Process(); process.executableURL = engine
            process.arguments = ["-nostdin", "-v", "error", "-xerror", "-n", "-protocol_whitelist", "file,pipe", "-i", input.path, "-map", "0:a:\(index)"] + codecs + [output.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw ExternalMediaError.failed }
            try Self.wait(process, timeout: 600)
            guard process.terminationStatus == 0, let size = (try? fm.attributesOfItem(atPath: output.path)[.size]) as? NSNumber, size.intValue > 0 else { throw ExternalMediaError.failed }
            let metadata = scratch.appendingPathComponent("音轨 \(index + 1) 元数据.ffmetadata")
            let sourceTags = try streamMetadata(input: input, index: index, engine: engine, destination: metadata)
            if sourceTags.isEmpty { try fm.removeItem(at: metadata) }
        }
        try Task.checkCancellation()
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            let suffix = number == 1 ? "" : " (\(number))"
            let destination = outputDirectory.appendingPathComponent("\(name) 音轨\(suffix)", isDirectory: true)
            let result = scratch.withUnsafeFileSystemRepresentation { src in destination.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
            if result == 0 { return destination }
            if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
        }
        throw ExternalMediaError.failed
    }
    static var executable: URL? {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["MORIQ_TEST_FFMPEG"], FileManager.default.isExecutableFile(atPath: test) { return URL(fileURLWithPath: test) }
        #endif
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("ffmpeg"), URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), URL(fileURLWithPath: "/usr/local/bin/ffmpeg")].compactMap { $0 }
        #if DEBUG
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(project.appendingPathComponent("Tools/imageio-ffmpeg/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v9.0"))
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func h264Encoder(engine: URL) -> String? {
        let process = Process(); process.executableURL = engine; process.arguments = ["-hide_banner", "-encoders"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        guard let data = try? Self.readOutput(output, process: process, timeout: 5) else { return nil }
        guard process.terminationStatus == 0, let list = String(data: data, encoding: .utf8) else { return nil }
        let names = Set(list.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count > 1 ? String(fields[1]) : nil
        })
        return ["libx264", "h264_videotoolbox"].first { names.contains($0) }
    }
    // macOS resolves .opus to the Ogg UTI, which otherwise collapses two
    // distinct codecs and output extensions into one wheel target.
    static let opusType = UTType(importedAs: "local.moriq.audio.opus", conformingTo: .audio)
    static func fileExtension(for format: UTType) -> String? {
        format == opusType ? "opus" : format.preferredFilenameExtension?.lowercased()
    }
    static func isAnimatedImage(_ url: URL) -> Bool {
        guard ["gif", "png", "apng", "webp"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
    private static func webpMayHaveTransparency(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 12,
              Array(data[0..<4]) == Array("RIFF".utf8), Array(data[8..<12]) == Array("WEBP".utf8) else { return false }
        func le24(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 }
        var offset = 12, width = 0, height = 0
        var transparentCanvas = false, partialFrame = false, hasFrame = false
        while offset <= data.count - 8 {
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            guard size <= data.count - offset - 8 else { return false }
            let name = Array(data[(offset + 0)..<(offset + 4)])
            if name == Array("VP8X".utf8), size >= 10 {
                if data[offset + 8] & 0x10 != 0 { return true }
                width = le24(offset + 12) + 1; height = le24(offset + 15) + 1
            }
            // Frames can cover only part of a transparent animation canvas even
            // when no frame carries an alpha channel of its own.
            if name == Array("ANIM".utf8), size >= 4 { transparentCanvas = data[offset + 11] < 255 }
            if name == Array("ANMF".utf8), size >= 16 {
                hasFrame = true
                let x = le24(offset + 8) * 2, y = le24(offset + 11) * 2
                let frameWidth = le24(offset + 14) + 1, frameHeight = le24(offset + 17) + 1
                if x != 0 || y != 0 || frameWidth != width || frameHeight != height { partialFrame = true }
            }
            offset += 8 + size + (size & 1)
        }
        return transparentCanvas && partialFrame && hasFrame
    }
    static func animationResultNotice(input: URL, outputExtension: String) -> String? {
        guard ["gif", "mp4", "mov", "m4v", "mkv", "avi", "flv"].contains(outputExtension),
              isAnimatedImage(input), let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return nil }
        let alpha = (input.pathExtension.lowercased() == "webp" && webpMayHaveTransparency(input)) || (0..<CGImageSourceGetCount(source)).contains { index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return false }
            return (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue == true
        }
        if outputExtension == "gif" {
            return alpha ? "已转换；颜色已量化，透明度仅保留透明或不透明" : "已转换；颜色已量化"
        }
        if alpha && ["mp4", "mov", "m4v", "mkv", "avi", "flv"].contains(outputExtension) {
            return "已转换；目标格式不支持透明，透明区域将被填充"
        }
        return nil
    }
    // APNG records each delay as an exact rational number in its fcTL chunks.
    // Read those values rather than rounding, e.g. 1/60 second, to milliseconds.
    private static func apngFrameRate(_ url: URL, frameCount: Int) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 8, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return nil }
        func be16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
        func be32(_ offset: Int) -> Int { Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3]) }
        func gcd(_ first: Int, _ second: Int) -> Int {
            var a = first, b = second
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        var offset = 8, rate = 1
        var delays: [(numerator: Int, denominator: Int)] = []
        while offset <= data.count - 12 {
            let size = be32(offset)
            guard size <= data.count - offset - 12 else { return nil }
            if data[offset + 4] == 102, data[offset + 5] == 99, data[offset + 6] == 84, data[offset + 7] == 76 {
                guard size == 26 else { return nil }
                let numerator = be16(offset + 28), rawDenominator = be16(offset + 30)
                guard numerator > 0 else { return nil }
                let denominator = rawDenominator == 0 ? 100 : rawDenominator
                let reduced = denominator / gcd(numerator, denominator)
                rate = rate / gcd(rate, reduced) * reduced
                // A pathological LCM can otherwise expand a short input into an
                // enormous video. The caller must not silently change its timing.
                guard rate <= 2000 else { return nil }
                delays.append((numerator, denominator))
            }
            offset += size + 12
        }
        guard delays.count == frameCount else { return nil }
        var ticksGCD = 0
        for delay in delays {
            let divisor = gcd(delay.numerator, delay.denominator)
            let numerator = delay.numerator / divisor, denominator = delay.denominator / divisor
            ticksGCD = gcd(ticksGCD, numerator * (rate / denominator))
        }
        return ticksGCD > 0 ? "\(rate)/\(ticksGCD)" : nil
    }
    // GIF uses centiseconds; WebP delays use milliseconds.
    // The greatest common divisor preserves the timeline with the fewest frames.
    static func animationFrameRate(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ["gif", "webp", "png", "apng"].contains(ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1 else { return nil }
        if ext == "png" || ext == "apng" { return apngFrameRate(url, frameCount: CGImageSourceGetCount(source)) }
        let scale = ext == "gif" ? 100 : 1000
        let dictionaryKey: CFString = ext == "gif" ? kCGImagePropertyGIFDictionary : (ext == "webp" ? "{WebP}" as CFString : kCGImagePropertyPNGDictionary)
        var divisor = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let metadata = properties[dictionaryKey] as? [CFString: Any],
                  let delay = (metadata["UnclampedDelayTime" as CFString] as? NSNumber)?.doubleValue,
                  delay.isFinite, delay >= (ext == "gif" ? 0.01 : 0.001), delay <= 655.35 else { return nil }
            let ticks = Int((delay * Double(scale)).rounded())
            guard ticks > 0, abs(delay * Double(scale) - Double(ticks)) < 0.01 else { return nil }
            var a = divisor, b = ticks
            while b != 0 { (a, b) = (b, a % b) }
            divisor = a
        }
        return divisor > 0 ? "\(scale)/\(divisor)" : nil
    }
    // When a small number of frames have very different durations, a constant
    // frame rate can otherwise encode thousands of identical copies. Retain
    // each change and a final timing marker, with variable presentation times.
    static func sparseAnimationFilter(_ url: URL, frameRate: String) -> (filter: String, timeBase: String)? {
        let parts = frameRate.split(separator: "/").compactMap { Int($0) }
        guard (1...2).contains(parts.count), let numerator = parts.first, numerator > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let denominator = parts.count == 2 ? parts[1] : 1
        guard denominator > 0 else { return nil }
        let count = CGImageSourceGetCount(source)
        guard (2...64).contains(count) else { return nil }
        let ext = url.pathExtension.lowercased()
        let key: CFString = ext == "gif" ? kCGImagePropertyGIFDictionary : (ext == "webp" ? "{WebP}" as CFString : kCGImagePropertyPNGDictionary)
        var indices: [Int] = [], total = 0
        for index in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let metadata = props[key] as? [CFString: Any],
                  let delay = (metadata["UnclampedDelayTime" as CFString] as? NSNumber)?.doubleValue else { return nil }
            let exact = delay * Double(numerator) / Double(denominator)
            guard exact.isFinite, exact >= 1, exact <= 10_000_000 else { return nil }
            let ticks = Int(exact.rounded())
            guard abs(exact - Double(ticks)) < 0.001, total <= 10_000_000 - ticks else { return nil }
            indices.append(total); total += ticks
        }
        guard total > count * 4 else { return nil }
        if indices.last != total - 1 { indices.append(total - 1) }
        let expression = indices.map { "eq(n,\($0))" }.joined(separator: "+")
        return ("fps=\(frameRate),select='\(expression)'", "1:\(numerator)")
    }
    static let audioInputs: Set<String> = AudioConverter.inputs.union(["ogg", "oga", "opus", "wma", "ac3", "mka"])
    static let videoInputs: Set<String> = VideoConverter.inputs.union(["mkv", "webm", "wmv", "flv", "ts", "mts", "m2ts"])
    static func audioTargets() -> [UTType] {
        guard executable != nil else { return AudioConverter.targets }
        return ["mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "caf"].compactMap { $0 == "opus" ? opusType : UTType(filenameExtension: $0) }
    }
    static func audioTargets(for inputs: [URL]) -> [UTType] {
        var targets = audioTargets()
        let engine = executable
        let hasFloatingPoint = inputs.contains { input in
            let detected = engine.flatMap { ExternalMediaConverter().audioStreamInfo(input, engine: $0)?.floatBits }
            return (detected ?? AudioConverter.floatingPointBits(input)) != nil
        }
        if hasFloatingPoint { targets.removeAll { fileExtension(for: $0) == "flac" } }
        return targets
    }
    static func videoTargets() -> [UTType] {
        guard executable != nil else { return [] }
        return ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "gif"].compactMap { UTType(filenameExtension: $0) }
    }
    static func videoTargets(for inputs: [URL]) -> [UTType] {
        guard let engine = executable, !inputs.isEmpty else { return [] }
        let videos = videoTargets()
        // Do not offer audio extraction for silent videos or animations.
        guard inputs.allSatisfy({ !isAnimatedImage($0) && ExternalMediaConverter().audioStreamInfo($0, engine: engine) != nil }) else { return videos }
        return videos + audioTargets()
    }
    func convertImage(input: URL, outputDirectory: URL) throws -> URL {
        try Task.checkCancellation()
        guard let engine = Self.executable else { throw ExternalMediaError.unavailable }
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let png = try ImageConverter().convert(input: input, outputDirectory: scratch, format: .png)
        try Task.checkCancellation()
        if ImageConverter.isMultipageTIFF(input) {
            let pages = try FileManager.default.contentsOfDirectory(at: png, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !pages.isEmpty, pages.allSatisfy({ $0.pathExtension.lowercased() == "png" }) else { throw ExternalMediaError.failed }
            let staging = scratch.appendingPathComponent("webp-pages", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            for page in pages {
                try Task.checkCancellation()
                _ = try convertImage(input: page, outputDirectory: staging)
            }
            let name = input.deletingPathExtension().lastPathComponent
            for number in 1...10000 {
                try Task.checkCancellation()
                let suffix = number == 1 ? "" : " (\(number))"
                let output = outputDirectory.appendingPathComponent("\(name) 页面\(suffix)", isDirectory: true)
                let result = staging.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
                if result == 0 { return output }
                if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
            }
            throw ExternalMediaError.failed
        }
        let temporary = scratch.appendingPathComponent("result.webp")
        let process = Process(); process.executableURL = engine
        process.arguments = ["-nostdin", "-v", "error", "-xerror", "-n", "-protocol_whitelist", "file,pipe", "-i", png.path, "-frames:v", "1", "-c:v", "libwebp", "-lossless", "1", temporary.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        do { try process.run() } catch { throw ExternalMediaError.failed }
        try Self.wait(process, timeout: 120)
        guard process.terminationStatus == 0, let source = CGImageSourceCreateWithURL(temporary as CFURL, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw ExternalMediaError.failed }
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).webp")
            let result = temporary.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
        }
        throw ExternalMediaError.failed
    }
    func convertPDFPages(input: URL, outputDirectory: URL) throws -> URL {
        try Task.checkCancellation()
        guard Self.executable != nil else { throw ExternalMediaError.unavailable }
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rendered = try PDFPageExporter().convert(input: input, outputDirectory: scratch, format: .png)
        try Task.checkCancellation()
        let isDirectory = (try? rendered.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let name = input.deletingPathExtension().lastPathComponent
        if !isDirectory {
            let page = try convertImage(input: rendered, outputDirectory: scratch)
            for number in 1...10000 {
                try Task.checkCancellation()
                let suffix = number == 1 ? "" : " (\(number))"
                let output = outputDirectory.appendingPathComponent("\(name)\(suffix).webp")
                let result = page.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
                if result == 0 { return output }
                if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
            }
        } else {
            let pages = try FileManager.default.contentsOfDirectory(at: rendered, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !pages.isEmpty, pages.allSatisfy({ $0.pathExtension.lowercased() == "png" }) else { throw ExternalMediaError.failed }
            let staging = scratch.appendingPathComponent("webp-pages", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            for page in pages {
                try Task.checkCancellation()
                _ = try convertImage(input: page, outputDirectory: staging)
            }
            for number in 1...10000 {
                try Task.checkCancellation()
                let suffix = number == 1 ? "" : " (\(number))"
                let output = outputDirectory.appendingPathComponent("\(name) 页面\(suffix)", isDirectory: true)
                let result = staging.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
                if result == 0 { return output }
                if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
            }
        }
        throw ExternalMediaError.failed
    }
    func convert(input: URL, outputDirectory: URL, format: UTType, video: Bool) throws -> URL {
        try Task.checkCancellation()
        guard let engine = Self.executable else { throw ExternalMediaError.unavailable }
        guard let ext = Self.fileExtension(for: format) else { throw ExternalMediaError.unsupported }
        if video && ext != "gif" {
            let sourceTracks = tracks(input, engine: engine)
            try Task.checkCancellation()
            guard let sourceTracks else { throw ExternalMediaError.failed }
            guard sourceTracks.unsupported == 0 else { throw ExternalMediaError.unsupportedTracks }
        }
        // AVAudioFile cannot inspect every supported container (notably MKA),
        // and a later track may have higher precision than the first one.
        let audioInfo = video ? nil : audioStreamInfo(input, engine: engine)
        try Task.checkCancellation()
        let floating = audioInfo?.floatBits ?? (video ? nil : AudioConverter.floatingPointBits(input))
        // Mixed streams may contain 32-bit integers alongside float32; using
        // float64 for a multi-track split preserves both representations.
        let floatBits = floating.map { $0 > 32 || (audioInfo?.count ?? 0) > 1 ? "64" : "32" }
        if !video && ext == "flac" && floating != nil { throw AudioConversionError.precisionUnsupported }
        var codecs: [String]
        if video {
            let h264: String
            if ["mp4", "mov", "m4v", "mkv"].contains(ext) {
                let supported = Self.h264Encoder(engine: engine)
            try Task.checkCancellation()
            guard let supported else { throw ExternalMediaError.unsupported }
                h264 = supported
            } else { h264 = "" }
            switch ext {
            case "mp4", "mov", "m4v": codecs = ["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "mov_text"]
            case "mkv": codecs = ["-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", h264, "-pix_fmt", "yuv420p", "-c:a", "aac", "-c:s", "srt"]
            case "webm": codecs = ["-c:v", "libvpx-vp9"] + (Self.isAnimatedImage(input) ? ["-pix_fmt", "yuva420p"] : []) + ["-c:a", "libopus", "-c:s", "webvtt"]
            case "avi": codecs = ["-c:v", "mpeg4", "-c:a", "libmp3lame"]
            case "flv": codecs = ["-c:v", "flv", "-c:a", "aac"]
            case "gif": codecs = ["-loop", "0"]
            default: throw ExternalMediaError.unsupported
            }
        } else {
            switch ext {
            case "mp3": codecs = ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
            case "m4a": codecs = ["-vn", "-c:a", "aac", "-b:a", "192k"]
            case "wav": codecs = ["-vn", "-c:a", floatBits.map { "pcm_f" + $0 + "le" } ?? "pcm_s32le"]
            case "aiff", "aif": codecs = ["-vn", "-c:a", floatBits.map { "pcm_f" + $0 + "be" } ?? "pcm_s32be"]
            case "flac": codecs = ["-vn", "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "32", "-strict", "-2"]
            case "ogg": codecs = ["-vn", "-c:a", "libvorbis"]
            case "opus": codecs = ["-vn", "-c:a", "libopus"]
            case "caf": codecs = ["-vn", "-c:a", floatBits.map { "pcm_f" + $0 + "le" } ?? "pcm_s32le"]
            default: throw ExternalMediaError.unsupported
            }
        }
        let temporary = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process(); process.executableURL = engine
        // Explicitly include every audio track. FFmpeg's default stream selection
        // silently keeps only one; containers that cannot carry all tracks must
        // fail instead of producing an apparently successful but incomplete file.
        let gif = video && ext == "gif"
        let animationFPS = video && !gif ? Self.animationFrameRate(input) : nil
        if video && !gif && ["png", "apng"].contains(input.pathExtension.lowercased()) && Self.isAnimatedImage(input) && animationFPS == nil {
            throw ExternalMediaError.timingUnsupported
        }
        // These AVI and FLV encoders do not preserve sparse presentation times.
        let sparse = ["avi", "flv"].contains(ext) ? nil : animationFPS.flatMap { Self.sparseAnimationFilter(input, frameRate: $0) }
        if let fps = animationFPS {
            let animationFilter = sparse?.filter ?? "fps=\(fps)"
            if let filter = codecs.firstIndex(of: "-vf") {
                codecs[filter + 1] = animationFilter + "," + codecs[filter + 1]
            } else {
                codecs = ["-vf", animationFilter] + codecs
            }
        }
        let streams = gif ? ["-filter_complex", "[0:v:0]split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a[out]", "-map", "[out]"] : (video ? ["-map", "0:v", "-map", "0:a?", "-map", "0:s?"] : ["-map", "0:a"])
        let timing = gif ? ["-enc_time_base", "1:100", "-fps_mode", "vfr"] : (sparse.map { ["-enc_time_base", $0.timeBase, "-fps_mode", "vfr"] } ?? (video && animationFPS == nil && Self.isAnimatedImage(input) ? ["-fps_mode", "vfr"] : []))
        // The animated WebP demuxer otherwise replaces very short delays with
        // 100 ms, so the output no longer matches the file's own frame timing.
        let inputTiming = video && Self.isAnimatedImage(input) && ["gif", "webp"].contains(input.pathExtension.lowercased()) ? ["-min_delay", "0"] : []
        process.arguments = ["-nostdin", "-v", "error", "-xerror", "-n", "-protocol_whitelist", "file,pipe"] + inputTiming + ["-i", input.path] + streams + codecs + timing + [temporary.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ExternalMediaError.failed }
        try Self.wait(process, timeout: 600)
        try Task.checkCancellation()
        if process.terminationStatus != 0, !video, ["mp3", "wav", "flac", "aiff", "aif", "caf"].contains(ext),
           let count = audioInfo?.count, count > 1 {
            return try splitAudio(input: input, outputDirectory: outputDirectory, ext: ext, codecs: codecs, engine: engine, count: count)
        }
        if process.terminationStatus != 0, video, ["avi", "flv"].contains(ext) {
            return try splitVideoTracks(input: input, outputDirectory: outputDirectory, ext: ext, codecs: codecs, engine: engine)
        }
        guard process.terminationStatus == 0, let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber, size.intValue > 0 else { throw ExternalMediaError.failed }
        if !video, let count = audioInfo?.count, count > 1,
           let package = try publishAudioWithMetadata(input: input, output: temporary, outputDirectory: outputDirectory, engine: engine, count: count) { return package }
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).\(ext)")
            let result = temporary.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw ExternalMediaError.filesystem(errno) }
        }
        throw ExternalMediaError.failed
    }
}
