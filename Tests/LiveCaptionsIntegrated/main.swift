import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwiftUI

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let state: LiveCaptionState
    var engine: LocalWhisperCaptionEngine?
    private let lock = NSLock()
    private var audioBuffers = 0
    private var errorMessage: String?
    @MainActor init(state: LiveCaptionState) { self.state = state }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lock.lock(); audioBuffers += 1; lock.unlock()
        engine?.append(sample)
    }
    func text(_ text: String, _ final: Bool) {
        Task { @MainActor in state.accept(text, final: final) }
    }
    func fail(_ message: String) { lock.lock(); errorMessage = message; lock.unlock() }
    func counts() -> (Int, String?) { lock.lock(); defer { lock.unlock() }; return (audioBuffers, errorMessage) }
}

@MainActor final class Runner: NSObject, NSApplicationDelegate {
    let state = LiveCaptionState()
    var sink: Sink?
    var stream: SCStream?
    var player: AVAudioPlayer?
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func run() async {
        guard CGPreflightScreenCaptureAccess() else { print("BLOCKED screen permission"); exit(2) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MORIQ synthetic subtitle test"
        window.contentView = NSHostingView(rootView: LiveCaptionView(state: state, close: {}, installModel: {}, changeLanguage: { _ in }, changeAudioSource: { _ in }))
        window.orderFront(nil); self.window = window
        let sink = Sink(state: state); self.sink = sink
        do {
            try await Task.sleep(for: .seconds(1))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first, let app = content.applications.first(where: { $0.processID == getpid() }) else { print("BLOCKED test app unavailable"); exit(2) }
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            sink.engine = try LocalWhisperCaptionEngine(helper: base.appendingPathComponent("Vendor/SpeechEngine/moriq-speech"), model: base.appendingPathComponent("Vendor/SpeechEngine/ggml-base.bin"), language: "en", onText: { [sink] text, final in sink.text(text, final) }, onError: { [sink] error in sink.fail(error) })
            let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = false; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            if #available(macOS 15, *) { config.captureMicrophone = false }
            let stream = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []), configuration: config, delegate: sink)
            self.stream = stream
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "moriq.integrated-test.audio"))
            try await stream.startCapture()
            let player = try AVAudioPlayer(contentsOf: base.appendingPathComponent("Tests/LiveCaptionsSystemAudio/synthetic.wav"))
            self.player = player; player.numberOfLoops = -1; player.volume = 0.03; player.play()
            var bilingualUpdates = 0
            var previousTranslation = ""
            var lastUpdate = ProcessInfo.processInfo.systemUptime
            let duration = max(20, min(3600, Int(ProcessInfo.processInfo.environment["MORIQ_CAPTION_TEST_SECONDS"] ?? "50") ?? 50))
            for _ in 0..<duration {
                try await Task.sleep(for: .seconds(1))
                if !state.original.isEmpty && !state.translated.isEmpty && state.translated != state.original && state.translated != previousTranslation {
                    bilingualUpdates += 1
                    previousTranslation = state.translated
                    lastUpdate = ProcessInfo.processInfo.systemUptime
                }
            }
            player.stop(); try await stream.stopCapture(); sink.engine?.stop()
            let (buffers, error) = sink.counts()
            let updateAge = Int(ProcessInfo.processInfo.systemUptime - lastUpdate)
            print("RESULT duration=\(duration)s buffers=\(buffers) bilingual_updates=\(bilingualUpdates) last_update_age=\(updateAge)s history=\(state.history.count) error=\(error ?? "none")")
            fflush(stdout)
            exit(buffers > 0 && bilingualUpdates >= 2 && updateAge < 15 && error == nil ? 0 : 1)
        } catch { print("BLOCKED \(error.localizedDescription)"); fflush(stdout); exit(2) }
    }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = Runner(); application.delegate = delegate; application.setActivationPolicy(.regular); application.run()
}
