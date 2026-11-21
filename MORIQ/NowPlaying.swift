import AppKit
import Carbon

/// Playback metadata is requested only while a supported player is running.
struct NowPlayingSnapshot: Equatable {
    enum State: Equatable { case playing, paused, stopped }
    let player: String
    let state: State
    let title: String?
    let artist: String?
}

enum NowPlayingResult: Equatable {
    case unavailable
    case permissionDenied
    case failed
    case available(NowPlayingSnapshot)
}

struct RunningMusicPlayer: Equatable {
    let name: String
    let pid: pid_t
}

enum MusicPlaybackAction { case playPause, previous, next }

protocol NowPlayingTransport {
    func runningPlayer() -> RunningMusicPlayer?
    func playbackState(for player: RunningMusicPlayer) throws -> NowPlayingSnapshot.State
    func trackTitle(for player: RunningMusicPlayer) throws -> String?
    func trackArtist(for player: RunningMusicPlayer) throws -> String?
    func perform(_ action: MusicPlaybackAction, for player: RunningMusicPlayer) throws
}

enum NowPlayingFailure: Error { case permissionDenied, unavailable }

/// Call on demand from a background task, never from a timer while hidden.
struct NowPlayingReader {
    let transport: any NowPlayingTransport
    func perform(_ action: MusicPlaybackAction) -> NowPlayingResult? {
        guard let player = transport.runningPlayer() else { return .unavailable }
        do { try transport.perform(action, for: player); return nil }
        catch NowPlayingFailure.permissionDenied { return .permissionDenied }
        catch { return transport.runningPlayer() == player ? .failed : .unavailable }
    }
    func read() -> NowPlayingResult {
        guard let player = transport.runningPlayer() else { return .unavailable }
        do {
            try Task.checkCancellation()
            let state = try transport.playbackState(for: player)
            try Task.checkCancellation()
            // A stopped player may have a selected track that is not playing.
            guard state != .stopped else {
                return .available(NowPlayingSnapshot(player: player.name, state: .stopped, title: nil, artist: nil))
            }
            let title = try transport.trackTitle(for: player)
            try Task.checkCancellation()
            let artist = try transport.trackArtist(for: player)
            try Task.checkCancellation()
            return .available(NowPlayingSnapshot(player: player.name, state: state, title: title, artist: artist))
        } catch NowPlayingFailure.permissionDenied { return .permissionDenied }
        catch { return transport.runningPlayer() == player ? .failed : .unavailable }
    }
}

/// Uses process-targeted Apple Events. Unlike addressing a bundle ID, this will
/// not launch a player if it exits between discovery and the request.
struct AppleMusicTransport: NowPlayingTransport {
    func runningPlayer() -> RunningMusicPlayer? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first,
              !app.isTerminated else { return nil }
        return RunningMusicPlayer(name: "音乐", pid: app.processIdentifier)
    }
    func playbackState(for player: RunningMusicPlayer) throws -> NowPlayingSnapshot.State {
        let reply = try readProperty("pPlS", ofTrack: false, pid: player.pid)
        switch reply.enumCodeValue {
        case fourCC("kPSP"): return .playing
        case fourCC("kPSp"): return .paused
        case fourCC("kPSS"): return .stopped
        default: throw NowPlayingFailure.unavailable
        }
    }
    func trackTitle(for player: RunningMusicPlayer) throws -> String? { try readProperty("pnam", ofTrack: true, pid: player.pid).stringValue }
    func trackArtist(for player: RunningMusicPlayer) throws -> String? { try readProperty("pArt", ofTrack: true, pid: player.pid).stringValue }

    func perform(_ action: MusicPlaybackAction, for player: RunningMusicPlayer) throws {
        try requireMusicProcess(player.pid)
        let eventID: String
        switch action { case .playPause: eventID = "PlPs"; case .previous: eventID = "Prev"; case .next: eventID = "Next" }
        let event = NSAppleEventDescriptor(eventClass: fourCC("hook"), eventID: fourCC(eventID), targetDescriptor: NSAppleEventDescriptor(processIdentifier: player.pid), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        _ = try send(event)
    }
    private func requireMusicProcess(_ pid: pid_t) throws {
        guard let process = NSRunningApplication(processIdentifier: pid), !process.isTerminated,
              process.bundleIdentifier == "com.apple.Music" else { throw NowPlayingFailure.unavailable }
    }
    private func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do {
            let reply = try event.sendEvent(options: .waitForReply, timeout: 2)
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                if error.int32Value == -1743 { throw NowPlayingFailure.permissionDenied }
                throw NowPlayingFailure.unavailable
            }
            return reply
        } catch let error as NowPlayingFailure { throw error }
        catch let error as NSError {
            if error.code == -1743 { throw NowPlayingFailure.permissionDenied }
            throw error
        }
    }
    private func readProperty(_ name: String, ofTrack: Bool, pid: pid_t) throws -> NSAppleEventDescriptor {
        func property(_ code: String, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
            record.setDescriptor(NSAppleEventDescriptor(enumCode: DescType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
            record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(code)), forKeyword: AEKeyword(keyAEKeyData))
            record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
            guard let value = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw NowPlayingFailure.unavailable }
            return value
        }
        try requireMusicProcess(pid)
        let container = try ofTrack ? property("pTrk", container: .null()) : .null()
        let specifier = try property(name, container: container)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        let reply = try send(event)
        guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { throw NowPlayingFailure.unavailable }
        return result
    }
}

private func fourCC(_ string: String) -> UInt32 {
    precondition(string.utf8.count == 4)
    return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
