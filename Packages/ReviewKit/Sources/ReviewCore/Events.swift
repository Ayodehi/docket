import Foundation

/// Notification event types (docs/status-model-and-notifications.md section 4).
/// `mentioned`, `prMerged`, and `reviewDismissed` are off by default and need data v1 does not
/// collect yet, so they are not emitted.
public enum EventKind: String, Codable, Sendable, CaseIterable {
    case reviewRequested, reReviewRequested, changesRequested, ciFailed, ciRecovered
    case approved, readyToMerge, conflicts, newComment

    public var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .reReviewRequested: "Re-review requested"
        case .changesRequested: "Changes requested"
        case .ciFailed: "CI failed"
        case .ciRecovered: "CI recovered"
        case .approved: "Approved"
        case .readyToMerge: "Ready to merge"
        case .conflicts: "Merge conflicts"
        case .newComment: "New comments"
        }
    }

    public var enabledByDefault: Bool { self != .ciRecovered }

    public var highUrgencyByDefault: Bool {
        self == .reviewRequested || self == .reReviewRequested || self == .changesRequested
    }

    public var defaultSound: String {
        switch self {
        case .reviewRequested, .reReviewRequested: "Request"
        case .changesRequested, .conflicts: "Attention"
        case .ciFailed: "Failure"
        case .approved, .readyToMerge: "Success"
        case .ciRecovered, .newComment: "Soft"
        }
    }

    /// Lower leads when several events on one PR collapse into one notification.
    var rank: Int {
        switch self {
        case .reviewRequested: 0
        case .reReviewRequested: 1
        case .changesRequested: 2
        case .ciFailed: 3
        case .conflicts: 4
        case .readyToMerge: 5
        case .approved: 6
        case .newComment: 7
        case .ciRecovered: 8
        }
    }

    /// Events about someone asking for my review. Ignored-bot and age rules do not apply.
    var isRequest: Bool { self == .reviewRequested || self == .reReviewRequested }
}

public struct PREvent: Sendable, Hashable {
    public var kind: EventKind
    public var pr: PRSnapshot
    /// Who caused it, when known (reviewers, commenters).
    public var actors: [String]
    /// New comments, or failing checks for `ciFailed`.
    public var count: Int
    public var failingChecks: [String]
    /// The new comments behind a `newComment` event.
    public var marks: [CommentMark]

    public init(kind: EventKind, pr: PRSnapshot, actors: [String] = [], count: Int = 0, failingChecks: [String] = [], marks: [CommentMark] = []) {
        self.kind = kind
        self.pr = pr
        self.actors = actors
        self.count = count
        self.failingChecks = failingChecks
        self.marks = marks
    }

    /// Deduplication key stored in the ledger.
    public var ledgerKey: String {
        switch kind {
        case .changesRequested, .approved:
            "\(pr.id):\(kind.rawValue):\(pr.headSha):\(actors.map { $0.lowercased() }.sorted().joined(separator: ","))"
        case .newComment:
            "\(pr.id):\(kind.rawValue):\(Int(pr.commentMarks.first?.at.timeIntervalSince1970 ?? 0))"
        default:
            "\(pr.id):\(kind.rawValue):\(pr.headSha)"
        }
    }
}

/// Turns two snapshot sets into events. Pure; fires on transitions, never on steady state.
public enum RulesEngine {
    /// A PR seen for the first time only produces review-request events, or author events when it
    /// was opened recently. This keeps PRs that become visible later (unhidden repos, slow tiers,
    /// detail arriving over several cycles) from notifying about old state.
    public static let newPRWindow: TimeInterval = 24 * 3600

    public static func diff(previous: [String: PRSnapshot], current: [PRSnapshot], now: Date) -> [PREvent] {
        current.flatMap { pr in events(previous: previous[pr.id], current: pr, now: now) }
    }

    static func events(previous old: PRSnapshot?, current pr: PRSnapshot, now: Date) -> [PREvent] {
        var events: [PREvent] = []
        let entered: (PrimaryState) -> Bool = { state in pr.primary == state && old?.primary != state }

        if entered(.reviewRequested) { events.append(PREvent(kind: .reviewRequested, pr: pr, actors: [pr.author])) }
        if entered(.reReviewRequested) { events.append(PREvent(kind: .reReviewRequested, pr: pr, actors: [pr.author])) }

        guard pr.isMine else { return events }
        if old == nil && now.timeIntervalSince(pr.createdAt) > newPRWindow { return events }

        let newVerdicts: (ReviewerVerdict) -> [String] = { verdict in
            pr.reviewers.filter { reviewer in
                guard reviewer.verdict == verdict, !reviewer.isTeam else { return false }
                guard let before = old?.reviewers.first(where: { $0.name.lowercased() == reviewer.name.lowercased() }) else { return true }
                return before.verdict != verdict || (reviewer.at ?? .distantPast) > (before.at ?? .distantPast)
            }.map(\.name)
        }

        let changesBy = newVerdicts(.changesRequested)
        if entered(.changesRequested) || (pr.primary == .changesRequested && !changesBy.isEmpty) {
            events.append(PREvent(kind: .changesRequested, pr: pr, actors: changesBy))
        }
        if let old, (old.ci == .running || old.ci == .passing), pr.ci == .failing {
            let failing = pr.checks.filter { $0.state == .failing && !$0.isIgnored }.map(\.name)
            events.append(PREvent(kind: .ciFailed, pr: pr, count: failing.count, failingChecks: failing))
        }
        if let old, old.ci == .failing, pr.ci == .passing {
            events.append(PREvent(kind: .ciRecovered, pr: pr))
        }
        if entered(.conflicts) { events.append(PREvent(kind: .conflicts, pr: pr)) }
        if entered(.readyToMerge) {
            events.append(PREvent(kind: .readyToMerge, pr: pr))
        } else {
            let approvedBy = newVerdicts(.approved)
            if !approvedBy.isEmpty { events.append(PREvent(kind: .approved, pr: pr, actors: approvedBy)) }
        }
        let since = old?.commentMarks.first?.at ?? (old == nil ? pr.createdAt : .distantFuture)
        let fresh = pr.commentMarks.filter { $0.at > since }
        if !fresh.isEmpty {
            var authors: [String] = []
            for mark in fresh where !authors.contains(mark.author) { authors.append(mark.author) }
            events.append(PREvent(kind: .newComment, pr: pr, actors: authors, count: fresh.count, marks: fresh))
        }
        return events
    }
}
