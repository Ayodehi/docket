import Foundation
import GitHubKit

/// Inputs beyond the PR itself.
public struct DerivationContext: Sendable {
    public var viewer: String
    /// `org/slug` for each team I am in. `nil` when unknown (token cannot read org membership).
    public var teams: Set<String>?
    /// When I last opened each PR in the app, or when Docket first saw it. Drives "New comments".
    public var lastViewed: [String: Date]
    /// Check name patterns (case-insensitive substring) to leave out of the CI status.
    public var ignoredChecks: [String]
    /// Logins (bots) whose comments and reviews are not new comments and never wait on my reply.
    /// Normalized with `Login.key`.
    public var ignoredAuthors: Set<String>
    public var now: Date

    public init(viewer: String, teams: Set<String>?, lastViewed: [String: Date], ignoredChecks: [String] = [],
                ignoredAuthors: Set<String> = [], now: Date) {
        self.viewer = viewer
        self.teams = teams
        self.lastViewed = lastViewed
        self.ignoredChecks = ignoredChecks
        self.ignoredAuthors = Login.keys(ignoredAuthors)
        self.now = now
    }
}

/// Pure implementation of docs/status-model-and-notifications.md sections 2 and 3.
public enum StatusDeriver {
    /// - Parameters:
    ///   - foundByRequestSearch: the `review-requested:@me` search returned this PR. That search
    ///     includes team requests, so it identifies team requests even when team membership is unknown.
    ///   - previous: the last snapshot, used to keep `stateEnteredAt` while the state is unchanged.
    ///   - watched: the PR's repo is watched; with no other relationship the role is Watcher.
    public static func snapshot(for pr: PullRequest, context: DerivationContext, foundByRequestSearch: Bool, watched: Bool = false, previous: PRSnapshot?) -> PRSnapshot {
        let me = context.viewer.lowercased()
        let isMe: (String?) -> Bool = { $0?.lowercased() == me }

        // Roles
        let userRequested = pr.reviewRequests.nodes.contains { $0.requestedReviewer?.typename == "User" && isMe($0.requestedReviewer?.login) }
        let teamRequested: Bool = {
            guard !userRequested else { return false }
            let requestedTeams = pr.reviewRequests.nodes.compactMap { request -> String? in
                guard let reviewer = request.requestedReviewer, reviewer.typename == "Team",
                      let org = reviewer.organization?.login, let slug = reviewer.slug else { return nil }
                return "\(org)/\(slug)".lowercased()
            }
            if let teams = context.teams {
                let mine = Set(teams.map { $0.lowercased() })
                if requestedTeams.contains(where: mine.contains) { return true }
            }
            return foundByRequestSearch && !requestedTeams.isEmpty
        }()
        let myReviews = pr.latestReviews.nodes.filter { isMe($0.author?.login) }
        let myOpinion = pr.latestOpinionatedReviews.nodes.first { isMe($0.author?.login) }
        var roles = Set<Role>()
        if isMe(pr.author?.login) { roles.insert(.author) }
        if userRequested { roles.insert(.requestedReviewer) }
        if teamRequested { roles.insert(.teamRequestedReviewer) }
        if !myReviews.isEmpty && !userRequested && !teamRequested && !roles.contains(.author) { roles.insert(.previousReviewer) }
        if watched && roles.isEmpty { roles.insert(.watcher) }

        let checks = checks(pr, ignoring: context.ignoredChecks)
        let ci = ciStatus(pr, checks: checks, ignoring: context.ignoredChecks)
        let review = reviewStatus(pr)
        let merge = mergeReadiness(pr)
        let lastViewed = context.lastViewed[pr.id] ?? previous?.stateEnteredAt ?? pr.updatedAt

        // Primary state, first match wins.
        let mine = roles.contains(.author)
        let toReview = userRequested || teamRequested
        // A conversation comment counts as feedback: GitHub keeps the review request open after
        // one, but the reviewer has had their say until the author pushes.
        let myComments = (pr.comments?.nodes ?? []).filter { isMe($0.author?.login) }.map(\.createdAt)
        let reviewedBefore = !myReviews.isEmpty || !myComments.isEmpty
        let lastPush = pr.commits.nodes.first?.commit.committedDate ?? .distantPast
        let myApprovalAt = myReviews.filter { $0.state == "APPROVED" }.compactMap(\.submittedAt).max()
        let myFeedbackAt = (myReviews.filter { $0.state != "APPROVED" }.compactMap(\.submittedAt) + myComments).max()
        let feedbackPending = myFeedbackAt.map { $0 > lastPush && $0 > (myApprovalAt ?? .distantPast) } ?? false
        let pushedAfterMyChangesRequest = myOpinion?.state == "CHANGES_REQUESTED" && myOpinion?.commit?.oid != pr.headRefOid
        let primary: PrimaryState
        if toReview && feedbackPending {
            primary = .pendingRemediation
        } else if toReview && !reviewedBefore {
            primary = .reviewRequested
        } else if toReview || (roles.contains(.previousReviewer) && pushedAfterMyChangesRequest) {
            primary = .reReviewRequested
        } else if mine && review == .changesRequested {
            primary = .changesRequested
        } else if mine && ci == .failing && !pr.isDraft {
            primary = .ciFailing
        } else if mine && merge == .conflicts {
            primary = .conflicts
        } else if mine && review == .approved && (ci == .passing || ci == .none) && merge == .ready {
            primary = .readyToMerge
        } else if mine && (hasNewComments(pr, me: me, since: lastViewed, ignoring: context.ignoredAuthors) || awaitsMyReply(pr, me: me, ignoring: context.ignoredAuthors)) {
            primary = .newComments
        } else if mine && merge == .behind && review == .approved {
            primary = .behindBase
        } else if mine && pr.isDraft {
            primary = .draft
        } else if mine && review != .approved && (ci == .passing || ci == .running) {
            primary = .waitingForReview
        } else if mine && ci == .running {
            primary = .ciRunning
        } else if roles.contains(.previousReviewer) && (myOpinion?.state == "CHANGES_REQUESTED" || feedbackPending) {
            primary = .pendingRemediation
        } else if roles.contains(.previousReviewer) {
            primary = .reviewed
        } else if mine {
            primary = .open
        } else {
            primary = .watching
        }

        let enteredAt: Date
        if let previous, previous.primary == primary {
            enteredAt = previous.stateEnteredAt
        } else if previous != nil {
            enteredAt = context.now
        } else {
            // First sighting: the last update is the best available estimate.
            enteredAt = pr.updatedAt
        }

        return PRSnapshot(
            id: pr.id,
            repo: pr.repository.nameWithOwner,
            number: pr.number,
            title: pr.title,
            url: pr.url,
            author: pr.author?.login ?? "ghost",
            headRef: pr.headRefName,
            headSha: pr.headRefOid,
            baseRef: pr.baseRefName,
            isDraft: pr.isDraft,
            isCrossRepository: pr.isCrossRepository,
            labels: pr.labels.nodes.map(\.name),
            additions: pr.additions,
            deletions: pr.deletions,
            changedFiles: pr.changedFiles,
            createdAt: pr.createdAt,
            updatedAt: pr.updatedAt,
            roles: roles,
            ci: ci,
            checks: checks,
            review: review,
            reviewers: reviewers(pr),
            merge: merge,
            unresolvedThreads: pr.reviewThreads.nodes.filter { !$0.isResolved }.count,
            commentMarks: commentMarks(pr, me: me, ignoring: context.ignoredAuthors),
            primary: primary,
            stateEnteredAt: enteredAt,
            assignees: pr.assignees?.nodes.map(\.login)
        )
    }

    /// The rollup counts every run on the head commit, so a check that failed and then passed on a
    /// rerun keeps it failing. GitHub's web UI shows only the latest run, so CI status comes from the
    /// deduplicated checks. The rollup is used when there are no checks (older caches) or the page
    /// of checks may be cut off, unless checks are ignored.
    static func ciStatus(_ pr: PullRequest, checks: [CheckSummary], ignoring patterns: [String]) -> CIStatus {
        let contexts = pr.commits.nodes.first?.commit.statusCheckRollup?.contexts?.nodes ?? []
        if patterns.isEmpty && (contexts.isEmpty || contexts.count >= CheckContext.fetchLimit) { return ciStatus(pr.ciRollup) }
        return ciStatus(checks.filter { !$0.isIgnored })
    }

    static func ciStatus(_ rollup: String?) -> CIStatus {
        switch rollup {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .running
        default: .none
        }
    }

    /// Uses `reviewDecision` when branch protection sets it. When it is null (no required reviews),
    /// falls back to the latest opinionated reviews so repos without protection still reach
    /// "Approved" and "Changes requested".
    /// CI status from individual checks, used when some checks are ignored.
    static func ciStatus(_ checks: [CheckSummary]) -> CIStatus {
        if checks.contains(where: { $0.state == .failing }) { return .failing }
        if checks.contains(where: { $0.state == .running }) { return .running }
        if checks.contains(where: { $0.state == .passing }) { return .passing }
        return .none
    }

    /// GitHub keeps `CHANGES_REQUESTED` after the author re-requests review from the reviewer who asked
    /// for changes. A changes request whose author has a pending review request again is treated as
    /// handed back, so once every one is, the status is Review required.
    static func reviewStatus(_ pr: PullRequest) -> ReviewStatus {
        let requested = Set(pr.reviewRequests.nodes.compactMap { request -> String? in
            guard let reviewer = request.requestedReviewer, reviewer.typename == "User" else { return nil }
            return reviewer.login?.lowercased()
        })
        let opinions = pr.latestOpinionatedReviews.nodes
        let changesRequests = opinions.filter { $0.state == "CHANGES_REQUESTED" }
        let reRequested = !changesRequests.isEmpty
            && changesRequests.allSatisfy { requested.contains($0.author?.login.lowercased() ?? "") }
        switch pr.reviewDecision {
        case "CHANGES_REQUESTED":
            if !reRequested { return .changesRequested }
        case "APPROVED": return .approved
        case nil:
            if !changesRequests.isEmpty && !reRequested { return .changesRequested }
            if opinions.contains(where: { $0.state == "APPROVED" }) { return .approved }
        default:
            break
        }
        let lastPush = pr.commits.nodes.first?.commit.committedDate ?? .distantPast
        if pr.latestReviews.nodes.contains(where: { $0.state == "COMMENTED" && ($0.submittedAt ?? .distantPast) > lastPush }) {
            return .commented
        }
        return pr.reviewDecision == "REVIEW_REQUIRED" || reRequested ? .reviewRequired : .noReviews
    }

    static func mergeReadiness(_ pr: PullRequest) -> MergeReadiness {
        if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" { return .conflicts }
        if pr.isDraft || pr.mergeStateStatus == "DRAFT" { return .draft }
        switch pr.mergeStateStatus {
        case "BEHIND": return .behind
        case "BLOCKED": return .blocked
        case "CLEAN", "UNSTABLE", "HAS_HOOKS": return .ready
        default: return .unknown
        }
    }

    /// A review thread whose last comment, or a Commented review, by someone other than me or an
    /// ignored author after `since`.
    static func hasNewComments(_ pr: PullRequest, me: String, since: Date, ignoring ignored: Set<String> = []) -> Bool {
        func counts(_ login: String?) -> Bool {
            guard let login else { return true }
            return login.lowercased() != me && !ignored.contains(Login.key(login))
        }
        let threadActivity = pr.reviewThreads.nodes.contains { thread in
            guard let last = thread.comments.nodes.last else { return false }
            return counts(last.author?.login) && last.createdAt > since
        }
        let commentedReview = pr.latestReviews.nodes.contains { review in
            review.state == "COMMENTED" && counts(review.author?.login) && (review.submittedAt ?? .distantPast) > since
        }
        return threadActivity || commentedReview
    }

    /// Someone else's review, conversation comment, or open thread came after my last push and my last
    /// reply. Unlike `hasNewComments`, opening the PR does not clear it.
    static func awaitsMyReply(_ pr: PullRequest, me: String, ignoring ignored: Set<String>) -> Bool {
        func isMe(_ login: String?) -> Bool { login?.lowercased() == me }
        func isOther(_ login: String?) -> Bool {
            guard let login else { return false }
            return login.lowercased() != me && !ignored.contains(Login.key(login))
        }
        let conversation = pr.comments?.nodes ?? []
        let reviews = pr.latestReviews.nodes
        let threads = pr.reviewThreads.nodes.filter { $0.comments.nodes.last != nil }

        var mine: [Date] = [pr.commits.nodes.first?.commit.committedDate ?? .distantPast]
        mine += conversation.filter { isMe($0.author?.login) }.map(\.createdAt)
        mine += reviews.filter { isMe($0.author?.login) }.compactMap(\.submittedAt)
        mine += threads.compactMap(\.comments.nodes.last).filter { isMe($0.author?.login) }.map(\.createdAt)
        let myLast = mine.max() ?? .distantPast

        var feedback: [Date] = conversation.filter { isOther($0.author?.login) }.map(\.createdAt)
        feedback += reviews.filter { isOther($0.author?.login) && ($0.state == "COMMENTED" || $0.state == "CHANGES_REQUESTED") }
            .compactMap(\.submittedAt)
        feedback += threads.filter { !$0.isResolved }.compactMap(\.comments.nodes.last).filter { isOther($0.author?.login) }.map(\.createdAt)
        return feedback.contains { $0 > myLast }
    }

    static func commentMarks(_ pr: PullRequest, me: String, ignoring ignored: Set<String> = []) -> [CommentMark] {
        let threadMarks = pr.reviewThreads.nodes.compactMap { thread -> CommentMark? in
            guard let last = thread.comments.nodes.last, let login = last.author?.login else { return nil }
            return CommentMark(author: login, at: last.createdAt)
        }
        let reviewMarks = pr.latestReviews.nodes.compactMap { review -> CommentMark? in
            guard review.state == "COMMENTED", let login = review.author?.login, let at = review.submittedAt else { return nil }
            return CommentMark(author: login, at: at)
        }
        return (threadMarks + reviewMarks)
            .filter { $0.author.lowercased() != me && !ignored.contains(Login.key($0.author)) }
            .sorted { $0.at > $1.at }
            .prefix(30)
            .map { $0 }
    }

    static func checks(_ pr: PullRequest, ignoring patterns: [String] = []) -> [CheckSummary] {
        let contexts = latestRuns(pr.commits.nodes.first?.commit.statusCheckRollup?.contexts?.nodes ?? [])
        let lowered = patterns.map { $0.lowercased() }.filter { !$0.isEmpty }
        return contexts.map { context -> CheckSummary in
            if context.typename == "StatusContext" {
                let state: CheckState = switch context.state {
                case "SUCCESS": .passing
                case "FAILURE", "ERROR": .failing
                case "PENDING", "EXPECTED": .running
                default: .neutral
                }
                return CheckSummary(name: context.context ?? "status", state: state, url: webURL(context.targetUrl),
                                    startedAt: context.createdAt, completedAt: nil)
            }
            let state: CheckState
            if context.status != "COMPLETED" {
                state = .running
            } else {
                switch context.conclusion {
                case "SUCCESS": state = .passing
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": state = .failing
                default: state = .neutral
                }
            }
            return CheckSummary(name: context.name ?? "check", state: state, url: webURL(context.detailsUrl),
                                startedAt: context.startedAt, completedAt: context.completedAt)
        }
        .map { check in
            var check = check
            let name = check.name.lowercased()
            check.isIgnored = lowered.contains { name.contains($0) }
            return check
        }
        .sorted { ($0.isIgnored ? 1 : 0, $0.state.sortRank, $0.name) < ($1.isIgnored ? 1 : 0, $1.state.sortRank, $1.name) }
    }

    /// The newest run of each check, keyed by workflow and name. Reruns and repeated `pull_request`
    /// events leave older runs on the commit. Commit statuses already hold only the latest state.
    static func latestRuns(_ contexts: [CheckContext]) -> [CheckContext] {
        var newest: [String: Int] = [:]
        for (index, context) in contexts.enumerated() where context.typename == "CheckRun" {
            let key = "\(context.workflowName ?? "")\u{1F}\(context.name ?? "")"
            if let kept = newest[key], (contexts[kept].startedAt ?? .distantPast) > (context.startedAt ?? .distantPast) { continue }
            newest[key] = index
        }
        let kept = Set(newest.values)
        return contexts.enumerated().filter { $0.element.typename != "CheckRun" || kept.contains($0.offset) }.map(\.element)
    }

    /// Check links come from CI providers and anyone who can post commit statuses, so only
    /// http and https URLs are kept. Other schemes (file, custom app schemes) are dropped.
    static func webURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// Pending requests first, then each reviewer's latest review. The author's own comments are left out.
    /// Each user also carries their latest approving or changes-requested review, which can be dismissed
    /// even while a new review is pending.
    static func reviewers(_ pr: PullRequest) -> [ReviewerState] {
        func opinion(of login: String) -> Review? {
            pr.latestOpinionatedReviews.nodes.first {
                $0.author?.login.lowercased() == login.lowercased() && ($0.state == "APPROVED" || $0.state == "CHANGES_REQUESTED")
            }
        }
        func user(_ login: String, verdict: ReviewerVerdict, at: Date?, id: String?) -> ReviewerState {
            let opinion = opinion(of: login)
            return ReviewerState(name: login, isTeam: false, verdict: verdict, at: at, userID: id ?? opinion?.author?.id,
                                 opinion: opinion.map { $0.state == "APPROVED" ? .approved : .changesRequested },
                                 opinionReviewID: opinion?.id)
        }
        var result: [ReviewerState] = []
        var seen = Set<String>()
        for request in pr.reviewRequests.nodes {
            guard let reviewer = request.requestedReviewer else { continue }
            if reviewer.typename == "Team", let org = reviewer.organization?.login, let slug = reviewer.slug {
                result.append(ReviewerState(name: "\(org)/\(slug)", isTeam: true, verdict: .requested, at: nil))
            } else if let login = reviewer.login {
                result.append(user(login, verdict: .requested, at: nil, id: nil))
                seen.insert(login.lowercased())
            }
        }
        let author = pr.author?.login.lowercased()
        for review in pr.latestReviews.nodes {
            guard let login = review.author?.login, login.lowercased() != author, !seen.contains(login.lowercased()) else { continue }
            seen.insert(login.lowercased())
            let verdict: ReviewerVerdict = switch review.state {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "DISMISSED": .dismissed
            default: .commented
            }
            result.append(user(login, verdict: verdict, at: review.submittedAt, id: review.author?.id))
        }
        return result
    }
}

private extension CheckState {
    var sortRank: Int {
        switch self {
        case .failing: 0
        case .running: 1
        case .passing: 2
        case .neutral: 3
        }
    }
}
