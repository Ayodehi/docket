import Foundation

// Codable types that mirror the GraphQL response shape in `Queries`. They are also the
// on-disk cache format, so keep them plain data. Enum-like GitHub values stay strings here;
// ReviewCore interprets them.

public struct RateLimitInfo: Codable, Sendable, Hashable {
    public var cost: Int
    public var remaining: Int
    public var resetAt: Date
    public var limit: Int?

    public init(cost: Int, remaining: Int, resetAt: Date, limit: Int? = nil) {
        self.cost = cost
        self.remaining = remaining
        self.resetAt = resetAt
        self.limit = limit
    }
}

public struct TokenInfo: Sendable, Hashable {
    public let login: String
    /// Classic token scopes from `X-OAuth-Scopes`. `nil` when the header is absent (fine-grained tokens).
    public let scopes: [String]?

    public init(login: String, scopes: [String]?) {
        self.login = login
        self.scopes = scopes
    }
}

/// A GraphQL connection's `nodes`. Null entries (deleted or inaccessible objects) are dropped.
public struct Connection<Node: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var nodes: [Node]

    public init(nodes: [Node]) { self.nodes = nodes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([Node?].self, forKey: .nodes).compactMap { $0 }
    }
}

public struct Account: Codable, Sendable, Hashable {
    public var login: String
    public var avatarUrl: String?
    /// Node ID, present for users in review authors (needed to re-request a review).
    public var id: String? = nil
}

public struct RepositoryRef: Codable, Sendable, Hashable {
    public var nameWithOwner: String
    public var isArchived: Bool?
}

public struct Label: Codable, Sendable, Hashable {
    public var name: String
    public var color: String
}

public struct ReviewRequest: Codable, Sendable, Hashable {
    public var requestedReviewer: RequestedReviewer?
}

public struct RequestedReviewer: Codable, Sendable, Hashable {
    public struct Organization: Codable, Sendable, Hashable { public var login: String }

    public var typename: String
    public var login: String?
    public var slug: String?
    public var organization: Organization?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", login, slug, organization
    }
}

public struct Review: Codable, Sendable, Hashable {
    public struct CommitRef: Codable, Sendable, Hashable { public var oid: String }

    public var author: Account?
    public var state: String
    public var submittedAt: Date?
    public var commit: CommitRef?
    /// Node ID, needed to dismiss the review. `nil` in caches from before review actions.
    public var id: String? = nil
}

public struct ReviewThreads: Codable, Sendable, Hashable {
    public var totalCount: Int
    public var nodes: [ReviewThread]

    public init(totalCount: Int, nodes: [ReviewThread]) {
        self.totalCount = totalCount
        self.nodes = nodes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        nodes = try container.decode([ReviewThread?].self, forKey: .nodes).compactMap { $0 }
    }
}

public struct ReviewThread: Codable, Sendable, Hashable {
    public var isResolved: Bool
    public var comments: Connection<ThreadComment>
}

public struct ThreadComment: Codable, Sendable, Hashable {
    public var author: Account?
    public var createdAt: Date
}

public struct CommitNode: Codable, Sendable, Hashable {
    public var commit: Commit
}

public struct Commit: Codable, Sendable, Hashable {
    public var oid: String?
    public var committedDate: Date?
    public var statusCheckRollup: StatusCheckRollup?
}

public struct StatusCheckRollup: Codable, Sendable, Hashable {
    public var state: String
    public var contexts: Connection<CheckContext>?
}

/// A `CheckRun` or a `StatusContext`, flattened.
public struct CheckContext: Codable, Sendable, Hashable {
    /// `contexts(first:)` in the detail query. A full page may be missing checks.
    public static let fetchLimit = 50

    public var typename: String
    // CheckRun
    public var name: String?
    public var status: String?
    public var conclusion: String?
    public var detailsUrl: String?
    public var startedAt: Date?
    public var completedAt: Date?
    // StatusContext
    public var context: String?
    public var state: String?
    public var targetUrl: String?
    public var createdAt: Date?
    /// The Actions workflow behind a check run. `nil` for other apps and in older caches.
    public var checkSuite: CheckSuite? = nil

    public struct CheckSuite: Codable, Sendable, Hashable {
        public struct WorkflowRun: Codable, Sendable, Hashable {
            public struct Workflow: Codable, Sendable, Hashable { public var name: String }
            public var workflow: Workflow
        }
        public var workflowRun: WorkflowRun?
    }

    public var workflowName: String? { checkSuite?.workflowRun?.workflow.name }

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, detailsUrl, startedAt, completedAt
        case context, state, targetUrl, createdAt, checkSuite
    }
}

/// Full PR detail, fetched by node ID in small batches.
public struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: URL
    public var state: String
    public var isDraft: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var author: Account?
    public var repository: RepositoryRef
    public var headRefName: String
    public var headRefOid: String
    public var baseRefName: String
    public var headRepository: RepositoryRef?
    public var isCrossRepository: Bool
    public var reviewDecision: String?
    public var mergeable: String
    public var mergeStateStatus: String
    public var labels: Connection<Label>
    public var reviewRequests: Connection<ReviewRequest>
    public var latestOpinionatedReviews: Connection<Review>
    public var latestReviews: Connection<Review>
    public var reviewThreads: ReviewThreads
    public var commits: Connection<CommitNode>
    /// Conversation comments, newest last. Only authors and times are fetched. `nil` in caches from
    /// before they were collected.
    public var comments: Connection<ThreadComment>? = nil
    /// Assignee logins. `nil` in caches from before they were collected.
    public var assignees: Connection<Account>? = nil

    public var ciRollup: String? { commits.nodes.first?.commit.statusCheckRollup?.state }
}

/// The cheap per-PR fields returned by discovery searches. Changes here trigger a detail fetch.
public struct PRSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var updatedAt: Date
    public var headRefOid: String
    public var isDraft: Bool
    public var reviewDecision: String?
    public var ciRollup: String?
    /// `owner/name`. Optional because summaries cached before hidden repos existed lack it.
    public var repo: String?
    /// Title and author, used only to match ignore rules locally. Optional for older caches.
    public var title: String?
    public var author: String?

    public init(id: String, updatedAt: Date, headRefOid: String, isDraft: Bool, reviewDecision: String?, ciRollup: String?,
                repo: String? = nil, title: String? = nil, author: String? = nil) {
        self.id = id
        self.repo = repo
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
        self.headRefOid = headRefOid
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.ciRollup = ciRollup
    }

    public init(_ pr: PullRequest) {
        self.init(id: pr.id, updatedAt: pr.updatedAt, headRefOid: pr.headRefOid, isDraft: pr.isDraft,
                  reviewDecision: pr.reviewDecision, ciRollup: pr.ciRollup, repo: pr.repository.nameWithOwner,
                  title: pr.title, author: pr.author?.login)
    }
}

/// API shape of a discovery search node.
struct SummaryNode: Decodable {
    struct CommitNode: Codable, Sendable, Hashable {
        struct Commit: Codable, Sendable, Hashable {
            struct Rollup: Codable, Sendable, Hashable { var state: String }
            var statusCheckRollup: Rollup?
        }
        var commit: Commit
    }

    var id: String
    var updatedAt: Date
    var headRefOid: String
    var isDraft: Bool
    var reviewDecision: String?
    var title: String?
    var author: Account?
    var repository: RepositoryRef?
    var commits: Connection<CommitNode>

    var summary: PRSummary {
        PRSummary(id: id, updatedAt: updatedAt, headRefOid: headRefOid, isDraft: isDraft,
                  reviewDecision: reviewDecision, ciRollup: commits.nodes.first?.commit.statusCheckRollup?.state,
                  repo: repository?.nameWithOwner, title: title, author: author?.login)
    }
}

public enum GitHubJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
