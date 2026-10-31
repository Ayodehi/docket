import Foundation

/// A snoozed PR. Ends at `until`, or when the PR changes if `fingerprint` is set.
public struct Snooze: Codable, Sendable, Hashable {
    public var until: Date?
    public var fingerprint: String?

    public init(until: Date?, fingerprint: String?) {
        self.until = until
        self.fingerprint = fingerprint
    }

    public static func untilChange(_ pr: PRSnapshot) -> Snooze {
        Snooze(until: nil, fingerprint: fingerprint(pr))
    }

    /// Head commit, review decision, and CI status (status model 4.4).
    public static func fingerprint(_ pr: PRSnapshot) -> String {
        "\(pr.headSha)|\(pr.review.rawValue)|\(pr.ci.rawValue)"
    }

    public func isActive(for pr: PRSnapshot?, now: Date) -> Bool {
        if let until, until <= now { return false }
        if let fingerprint, let pr, Self.fingerprint(pr) != fingerprint { return false }
        return true
    }
}

/// Delivered notifications keyed by `PREvent.ledgerKey`, so restarts and repeats do not re-alert.
public struct NotificationLedger: Codable, Sendable {
    public var entries: [String: Date] = [:]

    public init() {}

    public func contains(_ event: PREvent) -> Bool { entries[event.ledgerKey] != nil }

    public mutating func record(_ events: [PREvent], at now: Date) {
        for event in events { entries[event.ledgerKey] = now }
    }

    public mutating func prune(now: Date, keep: TimeInterval = 30 * 86_400) {
        entries = entries.filter { now.timeIntervalSince($0.value) < keep }
    }
}

public struct SuppressionContext: Sendable {
    public var enabled: Set<EventKind>
    public var ignoredBots: Set<String>
    public var snoozed: Set<String>
    public var mutedRepos: Set<String>
    public var paused: Bool
    /// My PRs not updated since this date do not notify, matching the Inbox age rule.
    public var authoredCutoff: Date?

    public init(enabled: Set<EventKind>, ignoredBots: Set<String>, snoozed: Set<String>, mutedRepos: Set<String>, paused: Bool, authoredCutoff: Date?) {
        self.enabled = enabled
        self.ignoredBots = Set(ignoredBots.map { $0.lowercased() })
        self.snoozed = snoozed
        self.mutedRepos = mutedRepos
        self.paused = paused
        self.authoredCutoff = authoredCutoff
    }
}

public enum Suppression: String, Sendable {
    case paused, disabled, snoozed, muted, bot, draft, tooOld, alreadyDelivered
}

public enum EventFilter {
    /// Returns the reason an event should not be delivered, or nil to deliver it (section 4.1).
    public static func reason(_ event: PREvent, context: SuppressionContext, ledger: NotificationLedger) -> Suppression? {
        let pr = event.pr
        if context.paused { return .paused }
        if !context.enabled.contains(event.kind) { return .disabled }
        if context.snoozed.contains(pr.id) { return .snoozed }
        if context.mutedRepos.contains(pr.repo) { return .muted }
        let directlyRequested = pr.roles.contains(.requestedReviewer)
        if event.kind.isRequest {
            if !directlyRequested && context.ignoredBots.contains(pr.author.lowercased()) { return .bot }
        } else if !event.actors.isEmpty && event.actors.allSatisfy({ context.ignoredBots.contains($0.lowercased()) }) {
            return .bot
        }
        if pr.isDraft && event.kind != .reviewRequested { return .draft }
        if !event.kind.isRequest, let cutoff = context.authoredCutoff, pr.updatedAt < cutoff { return .tooOld }
        if ledger.contains(event) { return .alreadyDelivered }
        return nil
    }

    /// Removes ignored bots from comment authors so "2 comments from dependabot" never appears,
    /// and drops comment events left with no human comments.
    public static func withoutBotComments(_ event: PREvent, context: SuppressionContext) -> PREvent? {
        guard event.kind == .newComment else { return event }
        var copy = event
        copy.marks = event.marks.filter { !context.ignoredBots.contains($0.author.lowercased()) }
        copy.actors = event.actors.filter { !context.ignoredBots.contains($0.lowercased()) }
        copy.count = copy.marks.count
        return copy.marks.isEmpty ? nil : copy
    }
}
