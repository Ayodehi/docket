import Foundation

/// My relationship to a PR. Lower rank wins for display (docs/status-model-and-notifications.md 2.1).
public enum Role: Int, Codable, Sendable, CaseIterable, Comparable {
    case author = 1
    case requestedReviewer = 2
    case teamRequestedReviewer = 3
    case previousReviewer = 4
    case watcher = 5

    public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum CIStatus: String, Codable, Sendable {
    case passing, failing, running, none
}

public enum ReviewStatus: String, Codable, Sendable {
    case changesRequested, approved, reviewRequired, commented, noReviews
}

public enum MergeReadiness: String, Codable, Sendable {
    case conflicts, behind, blocked, ready, draft, unknown
}

public enum Urgency: Int, Codable, Sendable, Comparable {
    case none = 0, low, medium, high

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Exactly one per open PR, evaluated in declaration order (status model section 3).
public enum PrimaryState: Int, Codable, Sendable, CaseIterable {
    case reviewRequested = 1
    case reReviewRequested
    case changesRequested
    case ciFailing
    case conflicts
    case readyToMerge
    case newComments
    case behindBase
    case draft
    case waitingForReview
    case ciRunning
    /// I gave feedback without approving (a review or a conversation comment) and the author has not pushed since.
    case pendingRemediation
    case reviewed
    case watching
    /// Mine, but none of the rules above apply (for example approved and blocked by a required check).
    case open

    public var isMyMove: Bool {
        switch self {
        case .reviewRequested, .reReviewRequested, .changesRequested, .ciFailing, .conflicts,
             .readyToMerge, .newComments, .behindBase: true
        default: false
        }
    }

    public var urgency: Urgency {
        switch self {
        case .reviewRequested, .reReviewRequested, .changesRequested, .ciFailing: .high
        case .conflicts, .readyToMerge, .newComments: .medium
        case .behindBase: .low
        default: .none
        }
    }

    public var title: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .reReviewRequested: "Re-review"
        case .changesRequested: "Changes requested"
        case .ciFailing: "CI failing"
        case .conflicts: "Conflicts"
        case .readyToMerge: "Ready to merge"
        case .newComments: "New comments"
        case .behindBase: "Behind base"
        case .draft: "Draft"
        case .waitingForReview: "Waiting for review"
        case .ciRunning: "CI running"
        case .pendingRemediation: "Pending remediation"
        case .reviewed: "Reviewed"
        case .watching: "Watching"
        case .open: "Open"
        }
    }

    /// Token used by `state:` search filters, for example `state:ci-failing`.
    public var token: String { title.lowercased().replacingOccurrences(of: " ", with: "-") }
}

public enum CheckState: String, Codable, Sendable {
    case passing, failing, running, neutral
}

public struct CheckSummary: Codable, Sendable, Hashable {
    public var name: String
    public var state: CheckState
    public var url: URL?
    public var startedAt: Date?
    public var completedAt: Date?
    /// Matches an ignored-check pattern from Settings; left out of the CI status.
    public var isIgnored = false

    public init(name: String, state: CheckState, url: URL?, startedAt: Date?, completedAt: Date?, isIgnored: Bool = false) {
        self.name = name
        self.state = state
        self.url = url
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.isIgnored = isIgnored
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(CheckState.self, forKey: .state)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        // Snapshots cached before ignored checks existed lack this key.
        isIgnored = try container.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false
    }

    public var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
}

public enum ReviewerVerdict: String, Codable, Sendable {
    case requested, approved, changesRequested, commented, dismissed
}

public struct ReviewerState: Codable, Sendable, Hashable {
    /// A login, or `org/slug` for a team.
    public var name: String
    public var isTeam: Bool
    public var verdict: ReviewerVerdict
    public var at: Date?
    /// User node ID, for re-requesting a review. `nil` for teams, bots, and older caches.
    public var userID: String? = nil
    /// The reviewer's latest approving or changes-requested review, which can be dismissed.
    public var opinion: ReviewerVerdict? = nil
    public var opinionReviewID: String? = nil

    /// Has reviewed, so a new request shows on GitHub as a re-request.
    public var canBeReRequested: Bool { !isTeam && verdict != .requested && userID != nil }
    public var canBeDismissed: Bool { opinionReviewID != nil }
}

/// A review comment or Commented review by someone other than me.
public struct CommentMark: Codable, Sendable, Hashable {
    public var author: String
    public var at: Date
}

public struct PRSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var repo: String
    public var number: Int
    public var title: String
    public var url: URL
    public var author: String
    public var headRef: String
    public var headSha: String
    public var baseRef: String
    public var isDraft: Bool
    public var isCrossRepository: Bool
    public var labels: [String]
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var roles: Set<Role>
    public var ci: CIStatus
    public var checks: [CheckSummary]
    public var review: ReviewStatus
    public var reviewers: [ReviewerState]
    public var merge: MergeReadiness
    public var unresolvedThreads: Int
    /// Others' latest comment activity, newest first: the last comment of each review thread
    /// and Commented reviews. Drives the `newComment` notification.
    public var commentMarks: [CommentMark]
    public var primary: PrimaryState
    public var stateEnteredAt: Date
    /// Assignee logins. `nil` in snapshots cached before they were collected.
    public var assignees: [String]? = nil

    public var role: Role? { roles.min() }
    public var isMine: Bool { roles.contains(.author) }
    /// `name` part of `owner/name`.
    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}
