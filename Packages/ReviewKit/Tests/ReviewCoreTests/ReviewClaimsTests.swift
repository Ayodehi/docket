import Foundation
import Testing
@testable import GitHubKit
@testable import ReviewCore

@Suite struct ReviewClaimsTests {
    private func claim(prior: Double? = nil, claimed: Double = 0) -> PendingClaim {
        PendingClaim(prID: "PR_1", repo: "example-org/web-console", number: 7, labelID: "LA_1", labelName: "In Review",
                     priorReviewAt: prior.map(at), claimedAt: at(claimed))
    }

    @Test func waitsUntilMyReviewIsPosted() {
        let pr = PRBuilder(labels: ["In Review"]).build()
        #expect(ReviewClaims.decide(claim(), pr: pr, viewer: "asokolov", now: at(1)) == .wait)
    }

    @Test func removesAfterMyReview() {
        let pr = PRBuilder(latest: [("asokolov", "COMMENTED", 1)], labels: ["in review"]).build()
        #expect(ReviewClaims.decide(claim(), pr: pr, viewer: "ASokolov", now: at(2)) == .removeLabel)
    }

    @Test func approvalCountsAsPosted() {
        let pr = PRBuilder(opinionated: [("asokolov", "APPROVED", 1, "sha2")], labels: ["In Review"]).build()
        #expect(ReviewClaims.decide(claim(), pr: pr, viewer: "asokolov", now: at(2)) == .removeLabel)
    }

    @Test func earlierReviewDoesNotCount() {
        let pr = PRBuilder(latest: [("asokolov", "CHANGES_REQUESTED", -3)], labels: ["In Review"]).build()
        #expect(ReviewClaims.decide(claim(prior: -3), pr: pr, viewer: "asokolov", now: at(1)) == .wait)
        let newer = PRBuilder(latest: [("asokolov", "APPROVED", 1)], labels: ["In Review"]).build()
        #expect(ReviewClaims.decide(claim(prior: -3), pr: newer, viewer: "asokolov", now: at(2)) == .removeLabel)
    }

    @Test func pendingReviewAndOthersReviewsDoNotCount() {
        let pr = PRBuilder(latest: [("asokolov", "PENDING", 1), ("mchen", "COMMENTED", 1)], labels: ["In Review"]).build()
        #expect(ReviewClaims.decide(claim(), pr: pr, viewer: "asokolov", now: at(2)) == .wait)
    }

    @Test func dropsWhenLabelGoneOrPRClosed() {
        let unlabeled = PRBuilder(latest: [("asokolov", "APPROVED", 1)]).build()
        #expect(ReviewClaims.decide(claim(), pr: unlabeled, viewer: "asokolov", now: at(2)) == .drop)
        let merged = PRBuilder(latest: [("asokolov", "APPROVED", 1)], labels: ["In Review"], state: "MERGED").build()
        #expect(ReviewClaims.decide(claim(), pr: merged, viewer: "asokolov", now: at(2)) == .drop)
    }

    @Test func untrackedPRExpires() {
        #expect(ReviewClaims.decide(claim(), pr: nil, viewer: "asokolov", now: at(24)) == .wait)
        #expect(ReviewClaims.decide(claim(), pr: nil, viewer: "asokolov", now: at(15 * 24)) == .drop)
    }

    @Test func claimantsNeedLabelAndAssignee() {
        func snapshot(_ builder: PRBuilder) -> PRSnapshot {
            StatusDeriver.snapshot(for: builder.build(), context: DerivationContext(viewer: "asokolov", teams: [], lastViewed: [:], now: t0),
                                   foundByRequestSearch: false, previous: nil)
        }
        let claimed = snapshot(PRBuilder(labels: ["in review"], assignees: ["asokolov", "mchen", "jdoe"]))
        #expect(ReviewClaims.claimants(of: claimed, label: "In Review") == ["asokolov", "jdoe"])
        #expect(ReviewClaims.claimants(of: claimed, label: nil).isEmpty)
        #expect(ReviewClaims.claimants(of: claimed, label: "Blocked").isEmpty)
        let unassigned = snapshot(PRBuilder(labels: ["In Review"]))
        #expect(ReviewClaims.claimants(of: unassigned, label: "In Review").isEmpty)
        let unlabeled = snapshot(PRBuilder(assignees: ["asokolov"]))
        #expect(ReviewClaims.claimants(of: unlabeled, label: "In Review").isEmpty)
    }

    @Test func fullLabelPageStillTriesRemoval() {
        let pr = PRBuilder(latest: [("asokolov", "APPROVED", 1)], labels: (1...10).map { "label-\($0)" }).build()
        #expect(ReviewClaims.decide(claim(), pr: pr, viewer: "asokolov", now: at(2)) == .removeLabel)
    }
}
