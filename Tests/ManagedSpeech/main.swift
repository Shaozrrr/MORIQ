import Foundation
import CoreMedia
import AVFoundation
func makeSample() throws -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    var asbd = format.streamDescription.pointee
    var desc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault, asbd:&asbd, layoutSize:0, layout:nil, magicCookieSize:0, magicCookie:nil, extensions:nil, formatDescriptionOut:&desc) == noErr, let desc else { fatalError("format") }
    let samples = [Float](repeating:0.2,count:4800)
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault, memoryBlock:nil, blockLength:samples.count*4, blockAllocator:kCFAllocatorDefault, customBlockSource:nil, offsetToData:0, dataLength:samples.count*4, flags:0, blockBufferOut:&block) == noErr, let block else { fatalError("block") }
    let s = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!, blockBuffer:block, offsetIntoDestination:0, dataLength:$0.count) }; guard s == noErr else {fatalError("copy")}
    var result: CMSampleBuffer?
    let rc = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault, dataBuffer:block, formatDescription:desc, sampleCount:samples.count, presentationTimeStamp:CMTime.zero, packetDescriptions:nil, sampleBufferOut:&result)
    guard rc == noErr, let result else { fatalError("sample \(rc)") }; return result
}

import Foundation
@MainActor final class ConsentExpectation { var revoked = false }
@main struct Check {
    static func main() async throws {
        let port = CommandLine.arguments[1]
        let stream = try ManagedSpeechStream(endpoint: URL(string:"ws://127.0.0.1:\(port)/v1/speech/stream")!, token: String(repeating:"a",count:32), allowLoopbackForTesting:true)
        let events = try await stream.start(source:"en", target:"zh")
        var gotSource = false, gotTranslation = false, finished = false
        var bridge: ManagedSpeechAudioBridge?
        for try await event in events {
            if event.type == "ready" {
                let active = ManagedSpeechAudioBridge(stream: stream, onError: { fatalError("audio bridge failure") }); bridge = active
                active.append(try makeSample())
                try await Task.sleep(for: .milliseconds(500))
                active.stop(); try await stream.finish()
            }
            if event.type == "source" && event.final == true && event.text == "Hello world." { gotSource = true }
            if event.type == "translation" && event.final == true && event.text == "你好，世界。" { gotTranslation = true }
            if event.type == "finished" { finished = true; break }
        }
        bridge?.stop()
        guard gotSource && gotTranslation && finished else { fatalError("stream events missing") }
        let suite = "local.moriq.consent-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ManagedSpeechConsentMonitor.key)
        let expectation = ConsentExpectation()
        let monitor = await MainActor.run { ManagedSpeechConsentMonitor(defaults: defaults) { expectation.revoked = true } }
        defaults.set(false, forKey: ManagedSpeechConsentMonitor.key)
        try await Task.sleep(for: .milliseconds(250))
        let seen = await MainActor.run { expectation.revoked }
        guard seen else { fatalError("consent revocation was not observed") }
        await MainActor.run { monitor.stop() }
        defaults.removePersistentDomain(forName: suite)
        print("PASS Swift client → audio conversion → gateway → upstream streaming and finish")
        print("PASS live consent revocation notification")
    }
}
