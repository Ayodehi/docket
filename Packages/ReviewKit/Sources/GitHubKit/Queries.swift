import Foundation

/// GraphQL documents. Field names were checked against the live schema on 2026-10-13.
///
/// Sync is two-phase (see docs/github-integration.md): cheap discovery searches every poll,
/// then full detail by node ID only for PRs that are new, changed, or due for refresh.
/// `mergeable` and `mergeStateStatus` are computed lazily by GitHub and make search-sized
/// detail queries time out, so they only appear in the detail query.
enum Queries {
    static let viewer = "query { viewer { login } }"

    /// Results per search page.
    static let pageSize = 50

    static let summaryFragment = """
    fragment PRSummaryFields on PullRequest {
      id updatedAt headRefOid isDraft reviewDecision title
      author { login }
      repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    static let detailFragment = """
    fragment PRFields on PullRequest {
      id number title url state isDraft createdAt updatedAt additions deletions changedFiles
      author { login avatarUrl }
      repository { nameWithOwner isArchived }
      headRefName headRefOid baseRefName
      headRepository { nameWithOwner }
      isCrossRepository reviewDecision mergeable mergeStateStatus
      labels(first: 10) { nodes { name color } }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug organization { login } } } } }
      latestOpinionatedReviews(first: 20) { nodes { id author { login ... on User { id } } state submittedAt commit { oid } } }
      latestReviews(first: 20) { nodes { id author { login ... on User { id } } state submittedAt } }
      comments(last: 20) { nodes { author { login } createdAt } }
      reviewThreads(first: 100) { totalCount nodes { isResolved comments(last: 1) { nodes { author { login } createdAt } } } }
      commits(last: 1) { nodes { commit { oid committedDate statusCheckRollup { state contexts(first: 50) { nodes { __typename ... on CheckRun { name status conclusion detailsUrl startedAt completedAt } ... on StatusContext { context state targetUrl createdAt } } } } } } }
    }
    """

    static let rateLimitFields = "rateLimit { cost remaining resetAt limit }"

    /// One request running `count` searches as aliases `s0...`, with variables `$q0, $a0, ...`.
    static func discovery(count: Int) -> String {
        let variables = (0..<count).map { "$q\($0): String!, $a\($0): String" }.joined(separator: ", ")
        let searches = (0..<count).map { index in
            "  s\(index): search(query: $q\(index), type: ISSUE, first: \(pageSize), after: $a\(index)) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { ...PRSummaryFields } } }"
        }.joined(separator: "\n")
        return """
        query Discover(\(variables)) {
          viewer { login }
          \(rateLimitFields)
        \(searches)
        }
        \(summaryFragment)
        """
    }

    /// Teams I belong to, per organization. Needs `read:org` (classic) or Members: read (fine-grained).
    static let teams = """
    query Teams($login: String!) {
      viewer { organizations(first: 50) { nodes { login teams(first: 100, userLogins: [$login]) { nodes { slug } } } } }
    }
    """

    static let detail = """
    query Detail($ids: [ID!]!) {
      \(rateLimitFields)
      nodes(ids: $ids) { ... on PullRequest { ...PRFields } }
    }
    \(detailFragment)
    """

    // MARK: Review actions (docs/design/review-actions.md)
    //
    // Every user value is a variable. `union: true` is literal so a request can never replace
    // the PR's existing reviewers. Each mutation returns the updated PR so Docket can show the
    // result without waiting for the next sync.

    static let requestReviews = """
    mutation RequestReviews($pr: ID!, $users: [String!], $teams: [String!]) {
      requestReviewsByLogin(input: { pullRequestId: $pr, userLogins: $users, teamSlugs: $teams, union: true }) { pullRequest { ...PRFields } }
    }
    \(detailFragment)
    """

    static let rerequestReviews = """
    mutation RerequestReviews($pr: ID!, $users: [ID!]) {
      rerequestReviews(input: { pullRequestId: $pr, userIds: $users }) { pullRequest { ...PRFields } }
    }
    \(detailFragment)
    """

    static let dismissReview = """
    mutation DismissReview($review: ID!, $message: String!) {
      dismissPullRequestReview(input: { pullRequestReviewId: $review, message: $message }) { pullRequestReview { pullRequest { ...PRFields } } }
    }
    \(detailFragment)
    """

    /// People GitHub suggests as reviewers. Fetched only when the picker opens.
    static let suggestedReviewers = """
    query SuggestedReviewers($pr: ID!) {
      node(id: $pr) { ... on PullRequest { suggestedReviewerActors(first: 20) { nodes { isAuthor reviewer { __typename login } } } } }
    }
    """
}
