import Foundation

/// UI-only task metadata. It intentionally excludes user content, paths and text.
struct IslandActivity: Equatable {
    enum Kind: Int { case caption, screenshot, conversion, timer }
    enum Status: Int { case running, completed, failed, cancelled }
    let id: UUID
    let revision: Int
    let kind: Kind
    let status: Status
    let updatedAt: TimeInterval
    let expiresAt: TimeInterval?
}

struct IslandActivityReducer {
    private(set) var activities: [UUID: IslandActivity] = [:]
    private var retired: Set<UUID> = []
    private var retirementOrder: [UUID] = []
    mutating func accept(_ activity: IslandActivity) {
        guard !retired.contains(activity.id), activity.revision >= 0,
              activity.updatedAt.isFinite,
              activity.expiresAt.map({ $0.isFinite && $0 >= activity.updatedAt }) ?? true else { return }
        if let previous = activities[activity.id] {
            guard activity.revision > previous.revision, activity.kind == previous.kind,
                  activity.updatedAt >= previous.updatedAt else { return }
            // Finished operations cannot be revived by a late callback.
            guard previous.status == .running else { return }
        }
        activities[activity.id] = activity
    }
    mutating func expire(at now: TimeInterval) {
        guard now.isFinite else { return }
        let expired = activities.values.filter { $0.expiresAt.map { $0 <= now } ?? false }
        for item in expired {
            activities.removeValue(forKey: item.id)
            if item.status != .running, retired.insert(item.id).inserted { retirementOrder.append(item.id) }
        }
        while retirementOrder.count > 1024 { retired.remove(retirementOrder.removeFirst()) }
    }
    var primary: IslandActivity? {
        activities.values.sorted {
            func priority(_ item: IslandActivity) -> Int {
                switch item.status { case .failed: 3; case .completed: 2; case .running: 1; case .cancelled: 0 }
            }
            let left = priority($0), right = priority($1)
            if left != right { return left > right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }
}
