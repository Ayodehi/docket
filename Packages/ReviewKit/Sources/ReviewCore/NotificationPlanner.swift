import Foundation

public enum NotificationStyle: String, Codable, Sendable, CaseIterable {
    case smart, everyEvent, summaryOnly

    public var title: String {
        switch self {
        case .smart: "Smart"
        case .everyEvent: "Every event"
        case .summaryOnly: "Summary only"
        }
    }
}

public struct NotificationPlanOptions: Sendable {
    public var style: NotificationStyle
    public var highUrgency: Set<EventKind>
    /// Sound name per kind. Empty string means no sound, "default" the system sound.
    public var sounds: [EventKind: String]
    public var hideTitles: Bool

    public init(style: NotificationStyle, highUrgency: Set<EventKind>, sounds: [EventKind: String], hideTitles: Bool) {
        self.style = style
        self.highUrgency = highUrgency
        self.sounds = sounds
        self.hideTitles = hideTitles
    }
}

public struct PlannedNotification: Sendable, Hashable {
    public enum Category: String, Sendable { case pr = "PR", ci = "CI", summary = "SUMMARY" }

    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: String?
    /// `owner/repo` so Notification Center groups per repo.
    public var threadID: String
    public var category: Category
    public var prID: String?
    public var url: URL?
    public var kind: EventKind?

    public init(title: String, subtitle: String, body: String, sound: String?, threadID: String, category: Category, prID: String?, url: URL?, kind: EventKind?) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
        self.threadID = threadID
        self.category = category
        self.prID = prID
        self.url = url
        self.kind = kind
    }
}

/// Batches one sync's events into notifications (section 4.2). Pure.
public enum NotificationPlanner {
    public static let maxSoundsPerBatch = 2

    public static func plan(_ events: [PREvent], options: NotificationPlanOptions) -> [PlannedNotification] {
        // Several events on one PR collapse into one, led by the most urgent.
        let perPR = Dictionary(grouping: events, by: \.pr.id).values
            .map { $0.sorted { $0.kind.rank < $1.kind.rank } }
            .sorted { ($0[0].kind.rank, $0[0].pr.repo, $0[0].pr.number) < ($1[0].kind.rank, $1[0].pr.repo, $1[0].pr.number) }
        guard !perPR.isEmpty else { return [] }

        var notifications: [PlannedNotification]
        switch options.style {
        case .everyEvent:
            notifications = perPR.map { individual($0, options) }
        case .summaryOnly:
            notifications = [summaryOfCounts(perPR, options)]
        case .smart:
            if perPR.count == 1 {
                notifications = [individual(perPR[0], options)]
            } else {
                let high = perPR.filter { options.highUrgency.contains($0[0].kind) }
                let rest = perPR.filter { !options.highUrgency.contains($0[0].kind) }
                notifications = high.map { individual($0, options) }
                if rest.count == 1 {
                    notifications.append(individual(rest[0], options))
                } else if !rest.isEmpty {
                    notifications.append(summaryOfUpdates(rest, options))
                }
            }
        }
        // At most one sound per notification and two per batch, kept for the most urgent.
        for index in notifications.indices where index >= maxSoundsPerBatch {
            notifications[index].sound = nil
        }
        return notifications
    }

    static func individual(_ events: [PREvent], _ options: NotificationPlanOptions) -> PlannedNotification {
        let lead = events[0]
        let pr = lead.pr
        let others = events.dropFirst().map(phrase)
        var subtitle = pr.repoName
        if !others.isEmpty { subtitle += " · Also: " + others.joined(separator: ", ") }
        var body = options.hideTitles ? "\(pr.repoName) #\(pr.number)" : "#\(pr.number) \(pr.title)"
        if lead.kind == .ciFailed, !lead.failingChecks.isEmpty {
            body += " · " + lead.failingChecks.prefix(2).joined(separator: ", ") + (lead.failingChecks.count > 2 ? " and \(lead.failingChecks.count - 2) more" : "")
        }
        return PlannedNotification(
            title: headline(lead), subtitle: subtitle, body: body, sound: sound(lead.kind, options),
            threadID: pr.repo, category: lead.kind == .ciFailed ? .ci : .pr, prID: pr.id, url: pr.url, kind: lead.kind)
    }

    /// Smart style: everything that is not high urgency, in one banner that opens the Inbox.
    static func summaryOfUpdates(_ groups: [[PREvent]], _ options: NotificationPlanOptions) -> PlannedNotification {
        let parts = groups.map { "\(phrase($0[0])) on \($0[0].pr.repoName) #\($0[0].pr.number)" }
        let body = parts.prefix(3).joined(separator: " · ") + (parts.count > 3 ? " · and \(parts.count - 3) more" : "")
        let lead = groups[0][0]
        return PlannedNotification(
            title: "\(groups.count) more updates", subtitle: "", body: body, sound: sound(lead.kind, options),
            threadID: "summary", category: .summary, prID: nil, url: nil, kind: nil)
    }

    /// Summary-only style: one banner with counts by type.
    static func summaryOfCounts(_ groups: [[PREvent]], _ options: NotificationPlanOptions) -> PlannedNotification {
        var counts: [EventKind: Int] = [:]
        for event in groups.flatMap({ $0 }) { counts[event.kind, default: 0] += event.kind == .newComment ? max(1, event.count) : 1 }
        let body = EventKind.allCases.compactMap { kind in counts[kind].map { countPhrase(kind, $0) } }.joined(separator: " · ")
        let lead = groups[0][0]
        return PlannedNotification(
            title: "\(groups.count) PR\(groups.count == 1 ? "" : "s") need you", subtitle: "", body: body, sound: sound(lead.kind, options),
            threadID: "summary", category: .summary, prID: nil, url: nil, kind: nil)
    }

    static func headline(_ event: PREvent) -> String {
        let by = event.actors.isEmpty ? "" : " by " + names(event.actors)
        switch event.kind {
        case .reviewRequested: return "Review requested" + by
        case .reReviewRequested: return "Re-review requested" + by
        case .changesRequested: return "Changes requested" + by
        case .ciFailed: return "CI failed on your PR"
        case .ciRecovered: return "CI passing again"
        case .approved: return "Approved" + by
        case .readyToMerge: return "Ready to merge"
        case .conflicts: return "Merge conflicts on your PR"
        case .newComment:
            let count = max(1, event.count)
            return "\(count) new comment\(count == 1 ? "" : "s")" + (event.actors.isEmpty ? "" : " from " + names(event.actors))
        }
    }

    static func phrase(_ event: PREvent) -> String {
        switch event.kind {
        case .newComment:
            let count = max(1, event.count)
            return "\(count) comment\(count == 1 ? "" : "s")"
        case .approved, .changesRequested:
            return event.kind.title.lowercased() + (event.actors.isEmpty ? "" : " by " + names(event.actors))
        case .ciFailed:
            return "CI failed"
        default:
            return event.kind.title.lowercased()
        }
    }

    static func countPhrase(_ kind: EventKind, _ count: Int) -> String {
        let noun: String = switch kind {
        case .reviewRequested: "review request"
        case .reReviewRequested: "re-review request"
        case .changesRequested: "changes request"
        case .ciFailed: "CI failure"
        case .ciRecovered: "CI recovery"
        case .approved: "approval"
        case .readyToMerge: "ready to merge"
        case .conflicts: "conflict"
        case .newComment: "new comment"
        }
        return kind == .readyToMerge ? "\(count) ready to merge" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func names(_ actors: [String]) -> String {
        actors.count <= 2 ? actors.joined(separator: " and ") : "\(actors[0]) and \(actors.count - 1) others"
    }

    static func sound(_ kind: EventKind, _ options: NotificationPlanOptions) -> String? {
        let name = options.sounds[kind] ?? kind.defaultSound
        return name.isEmpty ? nil : name
    }
}
