import Foundation

struct FakeTransport: NowPlayingTransport {
    var player: RunningMusicPlayer? = RunningMusicPlayer(name: "音乐", pid: 42)
    var state: NowPlayingSnapshot.State = .playing
    var denied = false
    var title: String? = "Synthetic track"
    var artist: String? = "Synthetic artist"
    func runningPlayer() -> RunningMusicPlayer? { player }
    func playbackState(for player: RunningMusicPlayer) throws -> NowPlayingSnapshot.State {
        if denied { throw NowPlayingFailure.permissionDenied }; return state
    }
    func trackTitle(for player: RunningMusicPlayer) throws -> String? { title }
    func trackArtist(for player: RunningMusicPlayer) throws -> String? { artist }
    func perform(_ action: MusicPlaybackAction, for player: RunningMusicPlayer) throws { if denied { throw NowPlayingFailure.permissionDenied } }
}

final class ExitingTransport: NowPlayingTransport {
    var reads = 0
    func runningPlayer() -> RunningMusicPlayer? { reads += 1; return reads == 1 ? RunningMusicPlayer(name: "音乐", pid: 42) : nil }
    func playbackState(for player: RunningMusicPlayer) throws -> NowPlayingSnapshot.State { throw NowPlayingFailure.unavailable }
    func trackTitle(for player: RunningMusicPlayer) throws -> String? { nil }
    func trackArtist(for player: RunningMusicPlayer) throws -> String? { nil }
    func perform(_ action: MusicPlaybackAction, for player: RunningMusicPlayer) throws { throw NowPlayingFailure.unavailable }
}

@main struct Check {
    static func main() {
        precondition(NowPlayingReader(transport: FakeTransport(player: nil)).read() == .unavailable)
        precondition(NowPlayingReader(transport: FakeTransport(denied: true)).read() == .permissionDenied)
        precondition(NowPlayingReader(transport: FakeTransport()).read() == .available(.init(player: "音乐", state: .playing, title: "Synthetic track", artist: "Synthetic artist")))
        precondition(NowPlayingReader(transport: FakeTransport(state: .paused)).read() == .available(.init(player: "音乐", state: .paused, title: "Synthetic track", artist: "Synthetic artist")))
        precondition(NowPlayingReader(transport: FakeTransport(state: .stopped)).read() == .available(.init(player: "音乐", state: .stopped, title: nil, artist: nil)))
        precondition(NowPlayingReader(transport: FakeTransport(player: nil)).perform(.next) == .unavailable)
        precondition(NowPlayingReader(transport: FakeTransport(denied: true)).perform(.previous) == .permissionDenied)
        precondition(NowPlayingReader(transport: FakeTransport()).perform(.playPause) == nil)
        precondition(NowPlayingReader(transport: ExitingTransport()).read() == .unavailable)
        precondition(NowPlayingReader(transport: ExitingTransport()).perform(.next) == .unavailable)
        let live = AppleMusicTransport().runningPlayer()
        print("PASS fake: absent, denied, playing, paused, stopped; actual running player: \(live == nil ? "no" : "yes")")
    }
}
