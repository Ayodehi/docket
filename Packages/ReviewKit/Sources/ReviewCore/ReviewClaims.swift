import Foundation
import GitHubKit

/// A label Docket added when I started reviewing a PR, to remove once my review is posted
/// (docs/design/review-claim.md). Recorded only when Docket added the label; one that was already
/// on the PR (put there by someone else, for example) is left alone.
public struct PendingClaim: Codable, Sendable, Hashable, Identifiable {
    public var prID: String
    /// `owner/name` and number, for logs.
    public var repo: String
    public var number: Int
    public var labelID: String
    public var labelName: String
    /// When my latest submitted review on the PR was, at claim time, by GitHub's clock. A review
    /// submitted after this (or any, when nil) is the one this claim waits for.
    public var priorReviewAt: Date?
    /// Local time the claim was made, to expire claims on PRs Docket no longer sees.
    public var claimedAt: Date
    /// Removal attempts that failed with an error worth retrying.
    public var failures: Int = 0

    public var id: String { prID }

    public init(prID: String, repo: String, number: Int, labelID: String, labelName: String, priorReviewAt: Date?, claimedAt: Date) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.labelID = labelID
        self.labelName = labelName
        self.priorReviewAt = priorReviewAt
        self.claimedAt = claimedAt
    }
}

public enum ReviewClaims {
    /// Claims on PRs Docket has not seen for this long are dropped without removing the label.
    public static let expiry: TimeInterval = 14 * 86400
    /// Removal attempts before a claim is dropped.
    public static let maxFailures = 3

    /// What to do with a claim after a sync.
    public enum Decision: Equatable, Sendable {
        /// My review is not posted yet.
        case wait
        /// My review is posted and the label is still on the PR.
        case removeLabel
        /// Nothing left to do: the PR closed, the label is gone, or the claim expired.
        case drop
    }

    /// When `viewer` last submitted a review on `pr` (pending, unsubmitted reviews do not count).
    public static func latestReview(by viewer: String, on pr: PullRequest) -> Date? {
        (pr.latestReviews.nodes + pr.latestOpinionatedReviews.nodes)
            .filter { $0.author?.login.lowercased() == viewer.lowercased() && $0.state != "PENDING" }
            .compactMap(\.submittedAt)
            .max()
    }

    /// `pr` is the latest detail for the claim's PR, or nil when Docket no longer tracks it.
    public static func decide(_ claim: PendingClaim, pr: PullRequest?, viewer: String, now: Date) -> Decision {
        guard let pr else { return now.timeIntervalSince(claim.claimedAt) > expiry ? .drop : .wait }
        guard pr.state == "OPEN" else { return .drop }
        // The detail query fetches 10 labels; with a full page the label may be past it, so still try.
        let labels = pr.labels.nodes
        let hasLabel = labels.contains { $0.name.lowercased() == claim.labelName.lowercased() } || labels.count >= 10
        guard hasLabel else { return .drop }
        guard let reviewed = latestReview(by: viewer, on: pr) else { return .wait }
        if let prior = claim.priorReviewAt, reviewed <= prior { return .wait }
        return .removeLabel
    }

    /// Who has claimed `pr` for review: its assignees, other than the author, when it also carries
    /// `label` (case-insensitive). Empty when there is no claim label, no such label on the PR, or
    /// no assignee.
    public static func claimants(of pr: PRSnapshot, label: String?) -> [String] {
        guard let label, pr.labels.contains(where: { $0.lowercased() == label.lowercased() }) else { return [] }
        return (pr.assignees ?? []).filter { $0.lowercased() != pr.author.lowercased() }
    }

    /// True when the PR already carries `label` (case-insensitive), so Docket did not add it.
    public static func hasLabel(_ label: String, on pr: PullRequest) -> Bool {
        pr.labels.nodes.contains { $0.name.lowercased() == label.lowercased() }
    }
}
