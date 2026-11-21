import SwiftUI
import AppKit
import EventKit

/// Real calendar content. Creating the view or reopening it never prompts for access.
struct AgendaView: View {
    @StateObject private var controller: AgendaController
    @State private var now = Date()
    private let maxEvents = 5

    @MainActor init(source: (any AgendaSource)? = nil) {
        _controller = StateObject(wrappedValue: AgendaController(source: source ?? EventKitAgendaSource()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("日程", systemImage: "calendar").font(.headline)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新日程").accessibilityLabel("刷新日程")
            }
            content
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await reload() } }
        .onDisappear { controller.clear() }
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("未连接") .foregroundStyle(.secondary)
                Button("允许访问日历") { Task { await reload(request: true) } }
            }.font(.callout)
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("加载中…").foregroundStyle(.secondary) }
                .font(.callout)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("未授权") .foregroundStyle(.secondary)
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
                }
            }.font(.callout)
        case .restricted:
            Text("访问受限") .font(.callout).foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("暂不可用") .foregroundStyle(.secondary)
                Button("重试") { Task { await reload() } }
            }.font(.callout)
        case .ready(let events):
            let upcoming = events.filter { $0.end > now }
            if upcoming.isEmpty {
                Text("暂无日程") .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(upcoming.prefix(maxEvents))) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(event.start, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                                if event.isAllDay { Text("全天").font(.caption).foregroundStyle(.secondary) }
                                else { Text(event.start, style: .time).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 7)
                    }
                }
                }.frame(maxHeight: 150)
            }
        }
    }

    @MainActor private func reload(request: Bool = false) async {
        now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400)
        await controller.refresh(from: start, to: end, requestIfNeeded: request)
    }
}
