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

    @Test func fullLabelPageStillTriesRemoval() {
        let pr = PRBuilder(latest: [("asokolov", "APPROVED", 1)], labels: (1...10).map { "label-\($0)" }).build()
        #expect(ReviewClaims.decide(claim(), pr: pr, viewer: "asokolov", now: at(2)) == .removeLabel)
    }
}
