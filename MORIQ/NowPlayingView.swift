import SwiftUI

/// Embed only while the music panel is visible. The task is cancelled by
/// SwiftUI when the view disappears; no background monitoring is installed.
struct NowPlayingView: View {
    @State private var result: NowPlayingResult = .unavailable
    @State private var busy = false
    @State private var visible = false
    @State private var generation = 0
    @AppStorage("moriq.island.music.connected") private var connected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                Text("音乐").font(.headline)
                Spacer()
            }
            if !connected {
                Button("连接音乐") { connected = true }
            } else {
            switch result {
            case .unavailable:
                Text("音乐未运行")
                    .font(.callout).foregroundStyle(.secondary)
            case .permissionDenied:
                Text("未授权")
                    .font(.callout).foregroundStyle(.secondary)
            case .failed:
                Text("暂不可用")
                    .font(.callout).foregroundStyle(.secondary)
            case .available(let snapshot):
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.title?.isEmpty == false ? snapshot.title! : (snapshot.state == .stopped ? "未播放" : "未知曲目"))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let artist = snapshot.artist, !artist.isEmpty {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 20) {
                    control("backward.end.fill", label: "上一首", action: .previous)
                    control(snapshot.state == .playing ? "pause.fill" : "play.fill", label: snapshot.state == .playing ? "暂停" : "播放", action: .playPause)
                    control("forward.end.fill", label: "下一首", action: .next)
                }.padding(.top, 2)
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            generation += 1
            busy = false
            result = .unavailable
        }
        .task(id: connected) {
            guard connected else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
    }

    private func control(_ symbol: String, label: String, action: MusicPlaybackAction) -> some View {
        Button { perform(action) } label: { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(busy).help(label).accessibilityLabel(label)
    }
    private func refresh() async {
        guard visible, connected else { return }
        let startedGeneration = generation
        let worker = Task.detached(priority: .utility) { NowPlayingReader(transport: AppleMusicTransport()).read() }
        let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, visible, connected, !busy, generation == startedGeneration else { return }
        result = next
    }
    private func perform(_ action: MusicPlaybackAction) {
        guard visible, connected, !busy else { return }
        busy = true
        generation += 1
        let startedGeneration = generation
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { NowPlayingReader(transport: AppleMusicTransport()).perform(action) }.value
            guard visible, connected, generation == startedGeneration else { return }
            busy = false
            if let outcome { result = outcome }
            if outcome == nil { await refresh() }
        }
    }
}
