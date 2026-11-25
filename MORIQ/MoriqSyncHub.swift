import AppKit
import EventKit
import Foundation
import SwiftUI

// MARK: - Non-Destructive Multi-Source Sync Engine (Island Local + Apple EventKit + Google + Reminders + Notes)

enum MoriqDataOrigin: String, Codable, Equatable {
    case moriq
    case appleCalendar
    case googleCalendar
    case appleReminders
    case appleNotes

    var badgeText: String {
        switch self {
        case .moriq: "岛内"
        case .appleCalendar: "本地日历"
        case .googleCalendar: "Google"
        case .appleReminders: "提醒事项"
        case .appleNotes: "备忘录"
        }
    }

    var badgeSymbol: String? {
        switch self {
        case .moriq: nil
        case .appleCalendar, .appleReminders, .appleNotes: "apple.logo"
        case .googleCalendar: "globe"
        }
    }
}

struct MoriqLocalCalendarEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var dateKey: String // yyyy-MM-dd
    var timeText: String // e.g. "14:00"
    var title: String
    var location: String
    var createdAt: Date = Date()
}

struct MergedPlannerEvent: Identifiable, Equatable {
    let id: String
    let externalUID: String?
    let sortKey: String
    let timeDisplay: String
    let title: String
    let location: String
    let joinURL: URL?
    let isAllDay: Bool
    let origin: MoriqDataOrigin
    let localUUID: UUID?
}

struct MoriqLocalTodoItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var done: Bool
    var createdAt: Date = Date()
}

struct MergedTodoEntry: Identifiable, Equatable {
    let id: String
    let text: String
    let done: Bool
    let origin: MoriqDataOrigin
    let localUUID: UUID?
    let reminderIdentifier: String?
}

struct ExternalAppleNoteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let plainBody: String
}

enum CalendarDisplaySpan: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        }
    }
}

@MainActor final class MoriqSyncHub: ObservableObject {
    static let shared = MoriqSyncHub()

    // Independent Optional Connection Toggles (User chooses freely; defaults never force prompts!)
    @Published var appleCalEnabled: Bool {
        didSet { defaults.set(appleCalEnabled, forKey: Keys.appleCal) }
    }
    @Published var googleCalEnabled: Bool {
        didSet { defaults.set(googleCalEnabled, forKey: Keys.googleCal) }
    }
    @Published var googleFeedURLString: String {
        didSet { defaults.set(googleFeedURLString, forKey: Keys.googleFeedURL) }
    }
    @Published var appleRemindersEnabled: Bool {
        didSet { defaults.set(appleRemindersEnabled, forKey: Keys.appleReminders) }
    }
    @Published var appleNotesEnabled: Bool {
        didSet { defaults.set(appleNotesEnabled, forKey: Keys.appleNotes) }
    }

    // Island-Owned Persistent Stores (NEVER overwritten when connecting or disconnecting external sources!)
    @Published private(set) var localEvents: [MoriqLocalCalendarEvent] = []
    @Published private(set) var localTodos: [MoriqLocalTodoItem] = []

    // External Read/Sync Caches
    @Published private(set) var externalEventsByDay: [String: [MergedPlannerEvent]] = [:]
    @Published private(set) var externalReminders: [MergedTodoEntry] = []
    @Published private(set) var externalAppleNotes: [ExternalAppleNoteItem] = []

    @Published private(set) var calendarPermissionDenied = false
    @Published private(set) var remindersPermissionDenied = false
    @Published private(set) var notesAutomationDenied = false
    @Published var showingGoogleConnectSheet = false
    @Published var syncNotice: String? = nil

    private let defaults: UserDefaults
    private let inMemory: Bool
    private let eventStore = EKEventStore()
    private let eventsFileURL: URL?
    private let todosFileURL: URL?
    private var ekObserver: NSObjectProtocol?
    private var noticeTask: Task<Void, Never>?

    private enum Keys {
        static let appleCal = "moriq.sync.appleCal.v1"
        static let googleCal = "moriq.sync.googleCal.v1"
        static let googleFeedURL = "moriq.sync.googleFeedURL.v1"
        static let appleReminders = "moriq.sync.appleReminders.v1"
        static let appleNotes = "moriq.sync.appleNotes.v1"
    }

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil, inMemory: Bool? = nil) {
        let isProductBundle = (try? RuntimeEnvironment.resolve(
            bundleID: Bundle.main.bundleIdentifier ?? "",
            flavor: Bundle.main.object(forInfoDictionaryKey: "MORIQBuildFlavor") as? String
        ))?.mode == .product
        let isolated = inMemory ?? (storageDirectory == nil && !isProductBundle)
        let resolvedDefaults: UserDefaults = (defaults === UserDefaults.standard && !isProductBundle && storageDirectory == nil)
            ? (UserDefaults(suiteName: "local.moriq.sync.ephemeral.\(UUID().uuidString)") ?? defaults)
            : defaults
        self.defaults = resolvedDefaults
        self.inMemory = isolated

        if resolvedDefaults.object(forKey: Keys.appleCal) == nil {
            // Auto-enable if EventKit calendar permission was already granted previously; never prompt uninvited.
            let alreadyAuthorized = !isolated && storageDirectory == nil && EKEventStore.authorizationStatus(for: .event) == .fullAccess
            self.appleCalEnabled = alreadyAuthorized
        } else {
            self.appleCalEnabled = resolvedDefaults.bool(forKey: Keys.appleCal)
        }
        self.googleCalEnabled = resolvedDefaults.bool(forKey: Keys.googleCal)
        self.googleFeedURLString = resolvedDefaults.string(forKey: Keys.googleFeedURL) ?? ""
        self.appleRemindersEnabled = resolvedDefaults.bool(forKey: Keys.appleReminders)
        self.appleNotesEnabled = resolvedDefaults.bool(forKey: Keys.appleNotes)

        if isolated {
            self.eventsFileURL = nil
            self.todosFileURL = nil
        } else {
            let base = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MORIQ", isDirectory: true)
            self.eventsFileURL = base.appendingPathComponent("island-events.json")
            self.todosFileURL = base.appendingPathComponent("island-todos.json")
            loadLocalDiskData()
        }

        if !isolated && storageDirectory == nil {
            ekObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshEnabledSources(interactiveRequest: false)
                }
            }
        }
    }

    deinit {
        if let ekObserver { NotificationCenter.default.removeObserver(ekObserver) }
    }

    func postNotice(_ message: String) {
        syncNotice = message
        SystemTelemetryStore.shared.showToast(message)
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            self?.syncNotice = nil
        }
    }

    // MARK: - Non-Destructive Island Local CRUD

    func addLocalEvent(dateKey: String, timeText: String, title: String, location: String = "岛内自建") {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let cleanTime = Self.normalizeTimeString(timeText)
        let item = MoriqLocalCalendarEvent(
            dateKey: dateKey,
            timeText: cleanTime,
            title: cleanTitle,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "岛内自建" : location
        )
        localEvents.append(item)
        saveLocalEvents()
        postNotice("已保存在岛内日程（连接本地或 Google 日历不会覆盖）")
    }

    func deleteLocalEvent(id: UUID) {
        localEvents.removeAll { $0.id == id }
        saveLocalEvents()
    }

    func addLocalTodo(text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        localTodos.insert(MoriqLocalTodoItem(text: clean, done: false), at: 0)
        saveLocalTodos()
        postNotice("已添加岛内待办（连接提醒事项后双份保留）")
    }

    func toggleTodo(_ entry: MergedTodoEntry) {
        if let uuid = entry.localUUID, let idx = localTodos.firstIndex(where: { $0.id == uuid }) {
            localTodos[idx].done.toggle()
            saveLocalTodos()
            return
        }
        if let remID = entry.reminderIdentifier, !inMemory,
           let item = eventStore.calendarItem(withIdentifier: remID) as? EKReminder {
            item.isCompleted.toggle()
            try? eventStore.save(item, commit: true)
            Task { await refreshReminders(interactive: false) }
        }
    }

    func deleteLocalTodo(id: UUID) {
        localTodos.removeAll { $0.id == id }
        saveLocalTodos()
    }

    // MARK: - Merged Non-Destructive Views

    func mergedEvents(for dateKey: String) -> [MergedPlannerEvent] {
        var combined: [MergedPlannerEvent] = localEvents
            .filter { $0.dateKey == dateKey }
            .map { ev in
                MergedPlannerEvent(
                    id: "moriq_\(ev.id.uuidString)",
                    externalUID: nil,
                    sortKey: ev.timeText,
                    timeDisplay: ev.timeText,
                    title: ev.title,
                    location: ev.location,
                    joinURL: Self.extractMeetingURL(from: [ev.location, ev.title]),
                    isAllDay: false,
                    origin: .moriq,
                    localUUID: ev.id
                )
            }

        var seenUIDs = Set<String>()
        for ext in (externalEventsByDay[dateKey] ?? []) {
            if ext.origin == .appleCalendar && !appleCalEnabled { continue }
            if ext.origin == .googleCalendar && !googleCalEnabled && !appleCalEnabled { continue }
            if ext.origin == .googleCalendar && !googleCalEnabled {
                // Only include EventKit-backed Google calendars if appleCalEnabled is on; skip direct Google feed if googleCalEnabled is off.
                if ext.id.hasPrefix("gfeed_") { continue }
            }
            if let uid = ext.externalUID, !uid.isEmpty {
                guard seenUIDs.insert(uid).inserted else { continue }
            }
            combined.append(ext)
        }

        return combined.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay && !b.isAllDay }
            if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
            return a.title < b.title
        }
    }

    var mergedTodos: [MergedTodoEntry] {
        var result: [MergedTodoEntry] = localTodos.map { t in
            MergedTodoEntry(
                id: "moriq_todo_\(t.id.uuidString)",
                text: t.text,
                done: t.done,
                origin: .moriq,
                localUUID: t.id,
                reminderIdentifier: nil
            )
        }
        if appleRemindersEnabled {
            result.append(contentsOf: externalReminders)
        }
        return result
    }

    // MARK: - Toggle Connectors (With Explicit Non-Destructive Coexistence)

    func toggleAppleCalendar() {
        if appleCalEnabled {
            appleCalEnabled = false
            postNotice("已断开本地日历 · 岛内自建日程完整保留")
        } else {
            appleCalEnabled = true
            Task { await refreshCalendars(interactive: true) }
        }
    }

    func toggleGoogleCalendar() {
        if googleCalEnabled {
            googleCalEnabled = false
            postNotice("已暂停 Google 日历同步 · 已有日程完整保留")
        } else if !googleFeedURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasEventKitGoogleAccount() {
            googleCalEnabled = true
            Task {
                await refreshCalendars(interactive: !hasEventKitGoogleAccount() ? false : true)
                postNotice("已连接 Google 日历 · 原有岛内与本地日程保留并合并")
            }
        } else {
            showingGoogleConnectSheet = true
        }
    }

    func saveGoogleFeedAndConnect(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        googleFeedURLString = trimmed
        googleCalEnabled = true
        showingGoogleConnectSheet = false
        Task {
            await refreshCalendars(interactive: false)
            postNotice("Google 日历已合并连接 · 岛内已有排期绝不覆盖")
        }
    }

    func openSystemInternetAccountsForGoogle() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        appleCalEnabled = true
        googleCalEnabled = true
        showingGoogleConnectSheet = false
        Task { await refreshCalendars(interactive: true) }
    }

    func toggleAppleReminders() {
        if appleRemindersEnabled {
            appleRemindersEnabled = false
            postNotice("已切回「仅岛内待办」· 岛内已设待办完整保留")
        } else {
            appleRemindersEnabled = true
            Task { await refreshReminders(interactive: true) }
        }
    }

    func toggleAppleNotes() {
        if appleNotesEnabled {
            appleNotesEnabled = false
            externalAppleNotes = []
            postNotice("已切回「仅岛内便签」· 岛内便签完整保留")
        } else {
            appleNotesEnabled = true
            Task { await refreshAppleNotes() }
        }
    }

    func refreshEnabledSources(interactiveRequest: Bool) async {
        guard !inMemory else { return }
        if appleCalEnabled || googleCalEnabled {
            await refreshCalendars(interactive: interactiveRequest)
        }
        if appleRemindersEnabled {
            await refreshReminders(interactive: interactiveRequest)
        }
        if appleNotesEnabled {
            await refreshAppleNotes()
        }
    }

    // MARK: - EventKit + Google ICS Synchronization

    private func hasEventKitGoogleAccount() -> Bool {
        guard !inMemory, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return false }
        return eventStore.calendars(for: .event).contains { cal in
            let s = (cal.source.title + " " + cal.title).lowercased()
            return s.contains("google") || s.contains("gmail")
        }
    }

    func refreshCalendars(interactive: Bool) async {
        guard !inMemory else { return }
        var grouped: [String: [MergedPlannerEvent]] = [:]

        // 1. Apple EventKit Calendars (including mounted iCloud, Local, Exchange, and Google CalDAV accounts)
        if appleCalEnabled || (googleCalEnabled && googleFeedURLString.isEmpty) {
            let status = EKEventStore.authorizationStatus(for: .event)
            var permitted = status == .fullAccess
            if status == .notDetermined && interactive {
                permitted = (try? await eventStore.requestFullAccessToEvents()) ?? false
            }
            calendarPermissionDenied = (status == .denied || status == .restricted || (interactive && !permitted))
            if permitted {
                let cal = Calendar.current
                let anchor = cal.startOfDay(for: Date())
                let start = cal.date(byAdding: .day, value: -15, to: anchor) ?? anchor
                let end = cal.date(byAdding: .day, value: 45, to: anchor) ?? anchor
                let pred = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
                let ekEvents = eventStore.events(matching: pred)
                for ev in ekEvents {
                    let sourceTitle = (ev.calendar.source.title + " " + ev.calendar.title).lowercased()
                    let isGoogle = sourceTitle.contains("google") || sourceTitle.contains("gmail")
                    let origin: MoriqDataOrigin = isGoogle ? .googleCalendar : .appleCalendar
                    let key = Self.dateKey(from: ev.startDate)
                    let timeDisplay = ev.isAllDay ? "全天" : "\(Self.hhmm(ev.startDate)) – \(Self.hhmm(ev.endDate))"
                    let sortKey = ev.isAllDay ? "00:00" : Self.hhmm(ev.startDate)
                    let loc = (ev.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let urlCandidates = [ev.url?.absoluteString ?? "", loc, ev.notes ?? ""]
                    let joinURL = ev.url.flatMap { Self.isMeetingLink($0) ? $0 : nil } ?? Self.extractMeetingURL(from: urlCandidates)
                    let cleanTitle = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let entry = MergedPlannerEvent(
                        id: "ek_\(ev.eventIdentifier ?? UUID().uuidString)_\(key)",
                        externalUID: ev.calendarItemExternalIdentifier,
                        sortKey: sortKey,
                        timeDisplay: timeDisplay,
                        title: cleanTitle.isEmpty ? "无标题日程" : cleanTitle,
                        location: loc.isEmpty ? ev.calendar.title : loc,
                        joinURL: joinURL,
                        isAllDay: ev.isAllDay,
                        origin: origin,
                        localUUID: nil
                    )
                    grouped[key, default: []].append(entry)
                }
                if interactive {
                    postNotice("已连接本地日历 · 原有岛内日程完整保留并合并显示")
                }
            }
        }

        // 2. Direct Google Calendar ICS Feed (for browser-only Google Calendar users)
        let feedRaw = googleFeedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if googleCalEnabled, let feedURL = URL(string: feedRaw),
           let scheme = feedURL.scheme?.lowercased(), (scheme == "https" || scheme == "webcal") {
            let httpsURL = scheme == "webcal"
                ? URL(string: "https" + feedRaw.dropFirst(6)) ?? feedURL
                : feedURL
            if let (data, _) = try? await URLSession.shared.data(from: httpsURL),
               let text = String(data: data, encoding: .utf8) {
                let parsed = Self.parseICSFeed(text)
                for ev in parsed {
                    let key = ev.id.components(separatedBy: "::").last ?? Self.dateKey(from: Date())
                    grouped[key, default: []].append(ev)
                }
            }
        }

        externalEventsByDay = grouped
    }

    func refreshReminders(interactive: Bool) async {
        guard !inMemory, appleRemindersEnabled else { return }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        var permitted = status == .fullAccess
        if status == .notDetermined && interactive {
            permitted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        }
        remindersPermissionDenied = (status == .denied || status == .restricted || (interactive && !permitted))
        guard permitted else {
            if remindersPermissionDenied && interactive {
                postNotice("未授予提醒事项权限，当前保持仅岛内待办")
            }
            return
        }

        let predicate = eventStore.predicateForReminders(in: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { cont in
            eventStore.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }
        let sorted = fetched
            .filter { !$0.isCompleted || ($0.completionDate.map { Date().timeIntervalSince($0) < 86400 } ?? false) }
            .sorted { a, b in
                if a.isCompleted != b.isCompleted { return !a.isCompleted && b.isCompleted }
                return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }
            .prefix(25)

        externalReminders = sorted.map { rem in
            let title = (rem.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return MergedTodoEntry(
                id: "ekrem_\(rem.calendarItemIdentifier)",
                text: title.isEmpty ? "无标题提醒" : title,
                done: rem.isCompleted,
                origin: .appleReminders,
                localUUID: nil,
                reminderIdentifier: rem.calendarItemIdentifier
            )
        }
        if interactive {
            postNotice("已连接本地提醒事项 · 岛内已有待办保留并合并显示")
        }
    }

    func refreshAppleNotes() async {
        guard !inMemory, appleNotesEnabled else { return }
        let result: (denied: Bool, items: [ExternalAppleNoteItem]) = await Task.detached(priority: .utility) {
            let source = """
            tell application "Notes"
                set outList to {}
                set noteCount to count of notes
                if noteCount > 8 then set noteCount to 8
                repeat with i from 1 to noteCount
                    set n to note i
                    set end of outList to (id of n) & "|||" & (name of n) & "|||" & (plaintext of n)
                end repeat
                return outList
            end tell
            """
            var err: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return (false, []) }
            let desc = script.executeAndReturnError(&err)
            if err != nil { return (true, []) }
            var parsed: [ExternalAppleNoteItem] = []
            if desc.numberOfItems > 0 {
                for idx in 1...desc.numberOfItems {
                    guard let raw = desc.atIndex(idx)?.stringValue else { continue }
                    let parts = raw.components(separatedBy: "|||")
                    guard parts.count >= 3 else { continue }
                    let id = parts[0]
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = parts.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    parsed.append(ExternalAppleNoteItem(
                        id: id,
                        title: title.isEmpty ? "备忘录" : String(title.prefix(24)),
                        plainBody: String(body.prefix(2000))
                    ))
                }
            }
            return (false, parsed)
        }.value

        notesAutomationDenied = result.denied
        externalAppleNotes = result.items
        if result.denied {
            postNotice("未授予备忘录自动化权限，岛内便签不受影响")
        } else {
            postNotice("已并存载入本地备忘录 · 岛内便签独立保留绝不覆盖")
        }
    }

    // MARK: - Persistence & Parsing Helpers

    private func loadLocalDiskData() {
        if let url = eventsFileURL, FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([MoriqLocalCalendarEvent].self, from: data) {
            localEvents = decoded
        }
        if let url = todosFileURL, FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([MoriqLocalTodoItem].self, from: data) {
            localTodos = decoded
        }
    }

    private func saveLocalEvents() {
        guard let url = eventsFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(localEvents)
            try data.write(to: url, options: .atomic)
        } catch { }
    }

    private func saveLocalTodos() {
        guard let url = todosFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(localTodos)
            try data.write(to: url, options: .atomic)
        } catch { }
    }

    static func dateKey(from date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    static func date(fromKey key: String, calendar: Calendar = .current) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    static func normalizeTimeString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "14:00" }
        let parts = trimmed.split(separator: ":")
        if parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)) {
            return String(format: "%02d:%02d", min(23, max(0, h)), min(59, max(0, m)))
        }
        return String(trimmed.prefix(11))
    }

    static func isMeetingLink(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let scheme = (url.scheme ?? "").lowercased()
        if ["zoommtg", "wemeet", "feishu", "msteams"].contains(scheme) { return true }
        let domains = ["zoom.us", "meet.google.com", "meeting.tencent.com", "voovmeeting.com", "feishu.cn", "larksuite.com", "teams.microsoft.com", "webex.com"]
        return domains.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    static func extractMeetingURL(from texts: [String]) -> URL? {
        let combined = texts.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(combined.startIndex..<combined.endIndex, in: combined)
        for match in detector.matches(in: combined, options: [], range: range) {
            if let url = match.url, isMeetingLink(url) { return url }
        }
        return nil
    }

    static func parseICSFeed(_ raw: String) -> [MergedPlannerEvent] {
        let unfolded = raw.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
        var events: [MergedPlannerEvent] = []
        let blocks = unfolded.components(separatedBy: "BEGIN:VEVENT").dropFirst()
        let isoBasic = DateFormatter()
        isoBasic.locale = Locale(identifier: "en_US_POSIX")
        isoBasic.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        isoBasic.timeZone = TimeZone(secondsFromGMT: 0)

        let localFmt = DateFormatter()
        localFmt.locale = Locale(identifier: "en_US_POSIX")
        localFmt.dateFormat = "yyyyMMdd'T'HHmmss"

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyyMMdd"

        var seenKeys = Set<String>()
        for block in blocks.prefix(120) {
            guard let body = block.components(separatedBy: "END:VEVENT").first else { continue }
            var summary = ""
            var location = ""
            var description = ""
            var uid = UUID().uuidString
            var dtStartRaw = ""
            var allDay = false

            for line in body.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let keyPart = parts[0].uppercased()
                let val = parts[1].replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\,", with: ",")
                if keyPart.hasPrefix("SUMMARY") { summary = val }
                else if keyPart.hasPrefix("LOCATION") { location = val }
                else if keyPart.hasPrefix("DESCRIPTION") { description = val }
                else if keyPart.hasPrefix("UID") { uid = val }
                else if keyPart.hasPrefix("DTSTART") {
                    dtStartRaw = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if keyPart.contains("VALUE=DATE") || dtStartRaw.count == 8 { allDay = true }
                }
            }
            guard !dtStartRaw.isEmpty else { continue }
            let startDate = isoBasic.date(from: dtStartRaw) ?? localFmt.date(from: dtStartRaw) ?? dayFmt.date(from: String(dtStartRaw.prefix(8)))
            guard let start = startDate else { continue }
            let key = dateKey(from: start)
            let dedupKey = "\(uid)::\(key)"
            guard seenKeys.insert(dedupKey).inserted else { continue }
            let sort = allDay ? "00:00" : hhmm(start)
            let join = extractMeetingURL(from: [location, description])
            events.append(MergedPlannerEvent(
                id: "gfeed_\(uid)::\(key)",
                externalUID: uid,
                sortKey: sort,
                timeDisplay: allDay ? "全天" : sort,
                title: summary.isEmpty ? "Google 日程" : summary,
                location: location.isEmpty ? "Google 日历" : location,
                joinURL: join,
                isAllDay: allDay,
                origin: .googleCalendar,
                localUUID: nil
            ))
        }
        return events
    }
}
