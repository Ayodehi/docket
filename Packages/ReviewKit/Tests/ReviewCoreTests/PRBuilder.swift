import Foundation
@testable import GitHubKit

let t0 = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

/// Builds fictional PullRequest values for status tests. Times are hours relative to `t0`.
struct PRBuilder {
    var id = "PR_1"
    var author = "mchen"
    var requestedUsers: [String] = []
    var requestedTeams: [String] = []
    /// (login, state, submitted hour, commit oid)
    var opinionated: [(String, String, Double, String)] = []
    /// (login, state, submitted hour)
    var latest: [(String, String, Double)] = []
    var decision: String? = "REVIEW_REQUIRED"
    var rollup: String? = "SUCCESS"
    var contexts: [CheckContext] = []
    var mergeable = "MERGEABLE"
    var mergeState = "BLOCKED"
    var draft = false
    var head = "sha2"
    var pushedAt: Double = -2
    /// (resolved, last comment author, hour)
    var threads: [(Bool, String, Double)] = []
    var updated: Double = -1
    /// Conversation comments: (author, hour)
    var conversation: [(String, Double)] = []
    var labels: [String] = []
    var state = "OPEN"

    func build() -> PullRequest {
        PullRequest(
            id: id, number: 7, title: "Fictional change", url: URL(string: "https://github.com/example-org/web-console/pull/7")!,
            state: state, isDraft: draft, createdAt: at(-48), updatedAt: at(updated), additions: 10, deletions: 2, changedFiles: 1,
            author: Account(login: author, avatarUrl: nil),
            repository: RepositoryRef(nameWithOwner: "example-org/web-console", isArchived: false),
            headRefName: "\(author)/change", headRefOid: head, baseRefName: "main", headRepository: nil, isCrossRepository: false,
            reviewDecision: decision, mergeable: mergeable, mergeStateStatus: mergeState,
            labels: Connection(nodes: labels.map { Label(name: $0, color: "ededed") }),
            reviewRequests: Connection(nodes:
                requestedUsers.map { ReviewRequest(requestedReviewer: RequestedReviewer(typename: "User", login: $0, slug: nil, organization: nil)) } +
                requestedTeams.map {
                    let parts = $0.split(separator: "/").map(String.init)
                    return ReviewRequest(requestedReviewer: RequestedReviewer(typename: "Team", login: nil, slug: parts[1], organization: .init(login: parts[0])))
                }),
            latestOpinionatedReviews: Connection(nodes: opinionated.map {
                Review(author: Account(login: $0.0, avatarUrl: nil), state: $0.1, submittedAt: at($0.2), commit: .init(oid: $0.3))
            }),
            latestReviews: Connection(nodes: (latest.isEmpty ? opinionated.map { ($0.0, $0.1, $0.2) } : latest).map {
                Review(author: Account(login: $0.0, avatarUrl: nil), state: $0.1, submittedAt: at($0.2), commit: nil)
            }),
            reviewThreads: ReviewThreads(totalCount: threads.count, nodes: threads.map {
                ReviewThread(isResolved: $0.0, comments: Connection(nodes: [ThreadComment(author: Account(login: $0.1, avatarUrl: nil), createdAt: at($0.2))]))
            }),
            commits: Connection(nodes: [CommitNode(commit: Commit(oid: head, committedDate: at(pushedAt),
                statusCheckRollup: rollup.map { StatusCheckRollup(state: $0, contexts: Connection(nodes: contexts)) }))]),
            comments: Connection(nodes: conversation.map { ThreadComment(author: Account(login: $0.0, avatarUrl: nil), createdAt: at($0.1)) })
        )
    }
}
