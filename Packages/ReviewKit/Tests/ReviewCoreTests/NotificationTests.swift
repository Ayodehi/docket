import Foundation
import Testing
@testable import GitHubKit
@testable import ReviewCore

private let me = "you"

private func snap(_ builder: PRBuilder, previous: PRSnapshot? = nil, lastViewed: Double = -1000) -> PRSnapshot {
    StatusDeriver.snapshot(for: builder.build(), context: DerivationContext(viewer: me, teams: [], lastViewed: [builder.id: at(lastViewed)], now: t0),
                           foundByRequestSearch: false, previous: previous)
}

private func pr(_ edit: (inout PRBuilder) -> Void) -> PRBuilder {
    var builder = PRBuilder()
    edit(&builder)
    return builder
}

private func kinds(_ old: PRSnapshot?, _ new: PRSnapshot, now: Date = t0) -> [EventKind] {
    RulesEngine.diff(previous: old.map { [$0.id: $0] } ?? [:], current: [new], now: now).map(\.kind)
}

@Suite struct RulesEngineTests {
    // Examples from docs/status-model-and-notifications.md section 5.

    @Test func example1ReviewRequested() {
        let before = snap(pr { $0.author = "mchen" })
        let after = snap(pr { $0.author = "mchen"; $0.requestedUsers = [me] }, previous: before)
        let events = RulesEngine.diff(previous: [before.id: before], current: [after], now: t0)
        #expect(events.map(\.kind) == [.reviewRequested])
        #expect(events[0].actors == ["mchen"])
    }

    @Test func example2And3ChangesRequestedThenPushIsReReview() {
        let requested = snap(pr { $0.requestedUsers = [me] })
        let reviewed = snap(pr { $0.opinionated = [(me, "CHANGES_REQUESTED", -1, "sha2")] }, previous: requested)
        #expect(reviewed.primary == .pendingRemediation)
        #expect(kinds(requested, reviewed).isEmpty)
        let pushed = snap(pr { $0.opinionated = [(me, "CHANGES_REQUESTED", -1, "sha2")]; $0.head = "sha3" }, previous: reviewed)
        #expect(kinds(reviewed, pushed) == [.reReviewRequested])
    }

    @Test func example4CIFailedAndApprovedTogether() {
        let before = snap(pr { $0.author = me; $0.rollup = "PENDING" })
        let after = snap(pr { $0.author = me; $0.rollup = "FAILURE"; $0.opinionated = [("ppatel", "APPROVED", -0.1, "sha2")]; $0.decision = "APPROVED" }, previous: before)
        #expect(Set(kinds(before, after)) == [.ciFailed, .approved])
    }

    @Test func example5GreenAgainIsReadyToMergeNotApproved() {
        let failing = snap(pr { $0.author = me; $0.rollup = "FAILURE"; $0.decision = "APPROVED"; $0.mergeState = "UNSTABLE"; $0.opinionated = [("ppatel", "APPROVED", -1, "sha2")] })
        let green = snap(pr { $0.author = me; $0.rollup = "SUCCESS"; $0.decision = "APPROVED"; $0.mergeState = "CLEAN"; $0.opinionated = [("ppatel", "APPROVED", -1, "sha2")] }, previous: failing)
        #expect(Set(kinds(failing, green)) == [.ciRecovered, .readyToMerge])
    }

    @Test func approvedAndReadyInOneCycleSendsOnlyReady() {
        let before = snap(pr { $0.author = me; $0.mergeState = "BLOCKED" })
        let after = snap(pr { $0.author = me; $0.decision = "APPROVED"; $0.mergeState = "CLEAN"; $0.opinionated = [("ppatel", "APPROVED", -0.1, "sha2")] }, previous: before)
        #expect(kinds(before, after) == [.readyToMerge])
    }

    @Test func steadyStateIsSilent() {
        let one = snap(pr { $0.author = me; $0.rollup = "FAILURE"; $0.requestedUsers = [] })
        let two = snap(pr { $0.author = me; $0.rollup = "FAILURE"; $0.updated = -0.5 }, previous: one)
        #expect(kinds(one, two).isEmpty)
    }

    @Test func newChangesRequestWhileAlreadyInState() {
        let one = snap(pr { $0.author = me; $0.decision = "CHANGES_REQUESTED"; $0.opinionated = [("ppatel", "CHANGES_REQUESTED", -5, "sha1")] })
        let two = snap(pr { $0.author = me; $0.decision = "CHANGES_REQUESTED"; $0.opinionated = [("ppatel", "CHANGES_REQUESTED", -5, "sha1"), ("mchen", "CHANGES_REQUESTED", -0.2, "sha2")] }, previous: one)
        let events = RulesEngine.diff(previous: [one.id: one], current: [two], now: t0)
        #expect(events.map(\.kind) == [.changesRequested])
        #expect(events[0].actors == ["mchen"])
    }

    @Test func newCommentsCountsOnlyNewOnes() {
        let one = snap(pr { $0.author = me; $0.threads = [(false, "ppatel", -5)] })
        let two = snap(pr { $0.author = me; $0.threads = [(false, "ppatel", -5), (false, "mchen", -0.5), (false, me, -0.4)]; $0.latest = [("ppatel", "COMMENTED", -0.3)] }, previous: one)
        let event = RulesEngine.diff(previous: [one.id: one], current: [two], now: t0).first { $0.kind == .newComment }
        #expect(event?.count == 2)
        #expect(event?.actors == ["ppatel", "mchen"])
    }

    @Test func conflictsOnEntry() {
        let one = snap(pr { $0.author = me })
        let two = snap(pr { $0.author = me; $0.mergeable = "CONFLICTING" }, previous: one)
        #expect(kinds(one, two) == [.conflicts])
    }

    @Test func firstSightingOfOldAuthoredPRIsSilentButRequestsStillFire() {
        let oldMine = snap(pr { $0.author = me; $0.rollup = "FAILURE"; $0.threads = [(false, "ppatel", -1)] })
        #expect(kinds(nil, oldMine).isEmpty)
        let request = snap(pr { $0.requestedUsers = [me] })
        #expect(kinds(nil, request) == [.reviewRequested])
        // A PR opened within the last day reports its comments.
        let fresh = snap(pr { $0.author = me; $0.threads = [(false, "ppatel", -1)] })
        #expect(kinds(nil, fresh, now: at(-47)) == [.newComment])
    }
}

@Suite struct SuppressionTests {
    private func context(_ edit: (inout SuppressionContext) -> Void = { _ in }) -> SuppressionContext {
        var context = SuppressionContext(enabled: Set(EventKind.allCases), ignoredBots: ["dependabot[bot]"], snoozed: [], mutedRepos: [], paused: false, authoredCutoff: nil)
        edit(&context)
        return context
    }

    private let request = PREvent(kind: .reviewRequested, pr: snap(pr { $0.requestedUsers = [me] }), actors: ["mchen"])
    private let ciFailure = PREvent(kind: .ciFailed, pr: snap(pr { $0.author = me; $0.rollup = "FAILURE" }))

    @Test func reasons() {
        let ledger = NotificationLedger()
        #expect(EventFilter.reason(request, context: context(), ledger: ledger) == nil)
        #expect(EventFilter.reason(request, context: context { $0.paused = true }, ledger: ledger) == .paused)
        #expect(EventFilter.reason(request, context: context { $0.enabled = [] }, ledger: ledger) == .disabled)
        #expect(EventFilter.reason(request, context: context { $0.snoozed = ["PR_1"] }, ledger: ledger) == .snoozed)
        #expect(EventFilter.reason(request, context: context { $0.mutedRepos = ["example-org/web-console"] }, ledger: ledger) == .muted)
        var delivered = NotificationLedger()
        delivered.record([request], at: t0)
        #expect(EventFilter.reason(request, context: context(), ledger: delivered) == .alreadyDelivered)
    }

    @Test func ageCutoffAppliesToAuthoredEventsOnly() {
        let cutoff = context { $0.authoredCutoff = at(1) }
        #expect(EventFilter.reason(ciFailure, context: cutoff, ledger: NotificationLedger()) == .tooOld)
        #expect(EventFilter.reason(request, context: cutoff, ledger: NotificationLedger()) == nil)
    }

    @Test func draftsOnlyNotifyForReviewRequests() {
        let draftCI = PREvent(kind: .ciFailed, pr: snap(pr { $0.author = me; $0.draft = true }))
        #expect(EventFilter.reason(draftCI, context: context(), ledger: NotificationLedger()) == .draft)
        let draftRequest = PREvent(kind: .reviewRequested, pr: snap(pr { $0.requestedUsers = [me]; $0.draft = true }))
        #expect(EventFilter.reason(draftRequest, context: context(), ledger: NotificationLedger()) == nil)
    }

    @Test func bots() {
        let botApproval = PREvent(kind: .approved, pr: ciFailure.pr, actors: ["Dependabot[bot]"])
        #expect(EventFilter.reason(botApproval, context: context(), ledger: NotificationLedger()) == .bot)
        // A bot's PR that requests my review directly still notifies; through a team it does not.
        let direct = PREvent(kind: .reviewRequested, pr: snap(pr { $0.author = "dependabot[bot]"; $0.requestedUsers = [me] }))
        #expect(EventFilter.reason(direct, context: context(), ledger: NotificationLedger()) == nil)
        let viaTeam = StatusDeriver.snapshot(for: pr { $0.author = "dependabot[bot]"; $0.requestedTeams = ["example-org/web"] }.build(),
                                             context: DerivationContext(viewer: me, teams: ["example-org/web"], lastViewed: [:], now: t0),
                                             foundByRequestSearch: true, previous: nil)
        #expect(EventFilter.reason(PREvent(kind: .reviewRequested, pr: viaTeam), context: context(), ledger: NotificationLedger()) == .bot)
        // Bot comments are removed; an event with only bot comments is dropped.
        let mixed = PREvent(kind: .newComment, pr: ciFailure.pr, actors: ["dependabot[bot]", "mchen"], count: 2,
                            marks: [CommentMark(author: "dependabot[bot]", at: t0), CommentMark(author: "mchen", at: t0)])
        #expect(EventFilter.withoutBotComments(mixed, context: context())?.count == 1)
        let onlyBot = PREvent(kind: .newComment, pr: ciFailure.pr, actors: ["dependabot[bot]"], count: 1, marks: [CommentMark(author: "dependabot[bot]", at: t0)])
        #expect(EventFilter.withoutBotComments(onlyBot, context: context()) == nil)
    }

    @Test func ledgerKeysAndPruning() {
        let a = PREvent(kind: .approved, pr: ciFailure.pr, actors: ["b", "A"])
        let b = PREvent(kind: .approved, pr: ciFailure.pr, actors: ["a", "B"])
        #expect(a.ledgerKey == b.ledgerKey)
        var ledger = NotificationLedger()
        ledger.record([a], at: at(-24 * 31))
        ledger.record([request], at: t0)
        ledger.prune(now: t0)
        #expect(!ledger.contains(a))
        #expect(ledger.contains(request))
    }

    @Test func snoozeUntilTimeAndUntilChange() {
        let base = snap(pr { $0.author = me })
        #expect(Snooze(until: at(1), fingerprint: nil).isActive(for: base, now: t0))
        #expect(!Snooze(until: at(-1), fingerprint: nil).isActive(for: base, now: t0))
        let untilChange = Snooze.untilChange(base)
        #expect(untilChange.isActive(for: base, now: t0))
        #expect(!untilChange.isActive(for: snap(pr { $0.author = me; $0.head = "sha9" }), now: t0))
        #expect(!untilChange.isActive(for: snap(pr { $0.author = me; $0.rollup = "FAILURE" }), now: t0))
    }
}

@Suite struct NotificationPlannerTests {
    private func options(_ style: NotificationStyle, hideTitles: Bool = false) -> NotificationPlanOptions {
        NotificationPlanOptions(style: style, highUrgency: Set(EventKind.allCases.filter(\.highUrgencyByDefault)), sounds: [:], hideTitles: hideTitles)
    }

    private func event(_ kind: EventKind, id: String, number: Int = 7, actors: [String] = [], count: Int = 0) -> PREvent {
        var builder = PRBuilder()
        builder.id = id
        builder.author = kind == .reviewRequested ? "mchen" : me
        var snapshot = snap(builder)
        snapshot.number = number
        return PREvent(kind: kind, pr: snapshot, actors: actors, count: count)
    }

    /// The scenario from the UX options page: a review request, a CI failure, and two comments.
    private var morning: [PREvent] {
        [event(.reviewRequested, id: "A", number: 482, actors: ["mchen"]),
         event(.ciFailed, id: "B", number: 341),
         event(.newComment, id: "C", number: 1203, actors: ["ppatel"], count: 2)]
    }

    @Test func smartSendsHighUrgencyAloneAndSummarizesTheRest() {
        let plan = NotificationPlanner.plan(morning, options: options(.smart))
        #expect(plan.count == 2)
        #expect(plan[0].title == "Review requested by mchen")
        #expect(plan[0].body == "#482 Fictional change")
        #expect(plan[0].threadID == "example-org/web-console")
        #expect(plan[1].title == "2 more updates")
        #expect(plan[1].body == "CI failed on web-console #341 · 2 comments on web-console #1203")
        #expect(plan[1].category == .summary)
    }

    @Test func smartSingleEventIsIndividual() {
        let plan = NotificationPlanner.plan([event(.ciFailed, id: "B", number: 341)], options: options(.smart))
        #expect(plan.map(\.title) == ["CI failed on your PR"])
        #expect(plan[0].category == .ci)
    }

    @Test func everyEventAndSummaryOnly() {
        #expect(NotificationPlanner.plan(morning, options: options(.everyEvent)).count == 3)
        let summary = NotificationPlanner.plan(morning, options: options(.summaryOnly))
        #expect(summary.count == 1)
        #expect(summary[0].title == "3 PRs need you")
        #expect(summary[0].body == "1 review request · 1 CI failure · 2 new comments")
    }

    @Test func eventsOnOnePRCollapseLedByMostUrgent() {
        let plan = NotificationPlanner.plan([event(.approved, id: "B", actors: ["ppatel"]), event(.ciFailed, id: "B")], options: options(.everyEvent))
        #expect(plan.count == 1)
        #expect(plan[0].title == "CI failed on your PR")
        #expect(plan[0].subtitle == "web-console · Also: approved by ppatel")
    }

    @Test func atMostTwoSoundsPerBatch() {
        let events = (0..<4).map { event(.reviewRequested, id: "P\($0)", number: $0, actors: ["mchen"]) }
        let plan = NotificationPlanner.plan(events, options: options(.everyEvent))
        #expect(plan.compactMap(\.sound).count == 2)
    }

    @Test func hiddenTitles() {
        let plan = NotificationPlanner.plan([event(.ciFailed, id: "B", number: 341)], options: options(.smart, hideTitles: true))
        #expect(plan[0].body == "web-console #341")
    }
}
