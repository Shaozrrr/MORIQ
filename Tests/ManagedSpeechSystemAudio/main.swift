import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let bridge: ManagedSpeechAudioBridge
    private let lock = NSLock()
    private var count = 0
    init(bridge: ManagedSpeechAudioBridge) { self.bridge = bridge }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lock.lock(); count += 1; lock.unlock(); bridge.append(sample)
    }
    func buffers() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
@MainActor final class Runner: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var player: AVAudioPlayer?
    private var capture: SCStream?
    private var sink: Sink?
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func run() async {
        guard CGPreflightScreenCaptureAccess() else { print("BLOCKED ScreenCaptureKit permission"); exit(2) }
        let window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 300,height: 100),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "MORIQ synthetic audio test"; window.orderFront(nil); self.window = window
        do {
            let port = CommandLine.arguments[1]
            let remote = try ManagedSpeechStream(endpoint: URL(string:"ws://127.0.0.1:\(port)/v1/speech/stream")!, token:String(repeating:"a",count:32),allowLoopbackForTesting:true)
            let events = try await remote.start(source:"en",target:"zh")
            var iterator = events.makeAsyncIterator()
            guard try await iterator.next()?.type == "ready" else { fatalError("remote not ready") }
            let bridge = ManagedSpeechAudioBridge(stream:remote,onError:{ print("FAIL audio bridge"); fflush(stdout); exit(1) })
            let sink = Sink(bridge:bridge); self.sink = sink
            let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let display = content.displays.first, let ownApp = content.applications.first(where:{$0.processID == getpid()}) else { print("BLOCKED own app unavailable"); exit(2) }
            let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = false; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value:1,timescale:1)
            if #available(macOS 15, *) { config.captureMicrophone = false }
            let capture = SCStream(filter:SCContentFilter(display:display,including:[ownApp],exceptingWindows:[]),configuration:config,delegate:sink)
            self.capture = capture
            try capture.addStreamOutput(sink,type:.audio,sampleHandlerQueue:DispatchQueue(label:"local.moriq.synthetic-audio"))
            try await capture.startCapture()
            let path = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/LiveCaptionsSystemAudio/synthetic.wav")
            let player = try AVAudioPlayer(contentsOf:path); self.player = player; player.volume = 0.03; player.play()
            var seenSource = false, seenTranslation = false
            while let event = try await iterator.next() {
                if event.type == "source" && event.final == true { seenSource = true }
                if event.type == "translation" && event.final == true { seenTranslation = true; break }
            }
            player.stop(); try await capture.stopCapture(); bridge.stop(); await remote.cancel()
            guard sink.buffers() > 0, seenSource, seenTranslation else { fatalError("missing capture or events") }
            print("PASS filtered synthetic app audio through ScreenCaptureKit, PCM bridge, gateway and simulated bilingual provider; buffers=\(sink.buffers())")
            fflush(stdout); exit(0)
        } catch { print("BLOCKED \(error.localizedDescription)"); fflush(stdout); exit(2) }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared; let delegate = Runner(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
}
