import Foundation

/// What the main window shows (sidebar). Presentation is separate (toolbar).
public enum Scope: Hashable, Codable, Sendable {
    case inbox, mine, reviewing, snoozed
    case repo(String)

    /// Stable key for per-scope settings.
    public var storageKey: String {
        switch self {
        case .inbox: "inbox"
        case .mine: "mine"
        case .reviewing: "reviewing"
        case .snoozed: "snoozed"
        case .repo(let name): "repo:\(name)"
        }
    }

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .mine: "My PRs"
        case .reviewing: "Reviewing"
        case .snoozed: "Snoozed"
        case .repo(let name): name.split(separator: "/").last.map(String.init) ?? name
        }
    }
}

public enum Presentation: String, Codable, Sendable, CaseIterable {
    case list, board, table
}

public struct PRSection: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var items: [PRSnapshot]

    public init(id: String, title: String, items: [PRSnapshot]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// View settings that decide what counts as "needs me".
public struct InboxRules: Sendable, Equatable {
    public var snoozed: Set<String>
    /// Authored PRs not updated since this date stay out of the Inbox. Review requests always count.
    public var authoredCutoff: Date?

    public init(snoozed: Set<String> = [], authoredCutoff: Date? = nil) {
        self.snoozed = snoozed
        self.authoredCutoff = authoredCutoff
    }

    public func isInInbox(_ pr: PRSnapshot) -> Bool {
        guard pr.primary.isMyMove, !snoozed.contains(pr.id) else { return false }
        if pr.primary == .reviewRequested || pr.primary == .reReviewRequested { return true }
        return pr.updatedAt >= (authoredCutoff ?? .distantPast)
    }
}

public enum Browse {
    public static func inScope(_ pr: PRSnapshot, _ scope: Scope, rules: InboxRules) -> Bool {
        let snoozed = rules.snoozed
        return switch scope {
        case .inbox: rules.isInInbox(pr)
        case .mine: pr.isMine
        case .reviewing: !pr.roles.isDisjoint(with: [.requestedReviewer, .teamRequestedReviewer, .previousReviewer])
        case .snoozed: snoozed.contains(pr.id)
        case .repo(let name): pr.repo == name
        }
    }

    /// Free text and filter tokens; see `SearchQuery`.
    public static func matches(_ pr: PRSnapshot, text: String) -> Bool {
        SearchQuery(text).matches(pr)
    }

    /// Inbox order: urgency, then the PR that has waited longest in its state.
    public static func inboxOrder(_ a: PRSnapshot, _ b: PRSnapshot) -> Bool {
        if a.primary.urgency != b.primary.urgency { return a.primary.urgency > b.primary.urgency }
        if a.stateEnteredAt != b.stateEnteredAt { return a.stateEnteredAt < b.stateEnteredAt }
        return a.id < b.id
    }

    /// Waiting PRs: most recently updated first.
    public static func waitingOrder(_ a: PRSnapshot, _ b: PRSnapshot) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
    }

    public static func visible(_ all: [PRSnapshot], scope: Scope, text: String, rules: InboxRules) -> [PRSnapshot] {
        let query = SearchQuery(text)
        return all.filter { inScope($0, scope, rules: rules) && query.matches($0) }
    }

    /// Table grouping by state: most urgent states first.
    public static func sectionsByState(_ prs: [PRSnapshot]) -> [PRSection] {
        Dictionary(grouping: prs, by: \.primary)
            .sorted { ($0.key.isMyMove ? 0 : 1, $0.key.rawValue) < ($1.key.isMyMove ? 0 : 1, $1.key.rawValue) }
            .map { PRSection(id: "state-\($0.key.rawValue)", title: $0.key.title, items: $0.value.sorted(by: inboxOrder)) }
    }

    public static func sectionsByAuthor(_ prs: [PRSnapshot]) -> [PRSection] {
        Dictionary(grouping: prs, by: \.author)
            .map { PRSection(id: "author-\($0.key)", title: $0.key, items: $0.value.sorted(by: inboxOrder)) }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// List groups (and later Board columns): "Your move" then "Waiting on others".
    public static func sectionsByMove(_ prs: [PRSnapshot]) -> [PRSection] {
        let move = prs.filter(\.primary.isMyMove).sorted(by: inboxOrder)
        let waiting = prs.filter { !$0.primary.isMyMove }.sorted(by: waitingOrder)
        return [PRSection(id: "move", title: "Your move", items: move),
                PRSection(id: "waiting", title: "Waiting on others", items: waiting)]
            .filter { !$0.items.isEmpty }
    }

    /// Board columns, always all present so the board keeps its shape (PRD V8).
    public static func boardColumns(_ prs: [PRSnapshot]) -> [PRSection] {
        let columns: [(String, String, Set<PrimaryState>)] = [
            ("requested", "Review requested", [.reviewRequested, .reReviewRequested]),
            ("feedback", "Changes & comments", [.changesRequested, .newComments]),
            ("ci", "CI failing", [.ciFailing]),
            ("conflicts", "Conflicts & behind", [.conflicts, .behindBase]),
            ("ready", "Ready to merge", [.readyToMerge]),
        ]
        var sections = columns.map { id, title, states in
            PRSection(id: id, title: title, items: prs.filter { states.contains($0.primary) }.sorted(by: inboxOrder))
        }
        sections.append(PRSection(id: "waiting", title: "Waiting on others", items: prs.filter { !$0.primary.isMyMove }.sorted(by: waitingOrder)))
        return sections
    }

    public enum BoardMove: Sendable { case up, down, left, right }

    /// The card selected after an arrow key on the board: up and down within a column, left and
    /// right to the nearest non-empty column at the same row (or its last card). With nothing
    /// selected, the first card.
    public static func boardMove(from selection: String?, _ move: BoardMove, columns: [PRSection]) -> String? {
        let nonEmpty = columns.filter { !$0.items.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        guard let selection,
              let col = nonEmpty.firstIndex(where: { $0.items.contains { $0.id == selection } }),
              let row = nonEmpty[col].items.firstIndex(where: { $0.id == selection }) else {
            return nonEmpty[0].items[0].id
        }
        let target: [PRSnapshot]
        switch move {
        case .up: return nonEmpty[col].items[max(0, row - 1)].id
        case .down: return nonEmpty[col].items[min(nonEmpty[col].items.count - 1, row + 1)].id
        case .left: target = nonEmpty[max(0, col - 1)].items
        case .right: target = nonEmpty[min(nonEmpty.count - 1, col + 1)].items
        }
        return target[min(row, target.count - 1)].id
    }

    public static func sectionsByRepo(_ prs: [PRSnapshot]) -> [PRSection] {
        Dictionary(grouping: prs, by: \.repo)
            .map { PRSection(id: $0.key, title: $0.key, items: $0.value.sorted(by: inboxOrder)) }
            .sorted { $0.title < $1.title }
    }
}
