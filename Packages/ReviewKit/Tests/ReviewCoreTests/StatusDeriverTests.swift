import Foundation
import Testing
@testable import GitHubKit
@testable import ReviewCore

private let me = "you"

private func derive(_ builder: PRBuilder, teams: Set<String>? = [], bySearch: Bool = false, lastViewed: Double? = nil, ignored: [String] = [], previous: PRSnapshot? = nil) -> PRSnapshot {
    var viewed: [String: Date] = [:]
    if let lastViewed { viewed[builder.id] = at(lastViewed) }
    return StatusDeriver.snapshot(for: builder.build(), context: DerivationContext(viewer: me, teams: teams, lastViewed: viewed, ignoredChecks: ignored, now: t0),
                                  foundByRequestSearch: bySearch, previous: previous)
}

private func mine(_ edit: (inout PRBuilder) -> Void) -> PRBuilder {
    var builder = PRBuilder()
    builder.author = me
    edit(&builder)
    return builder
}

private func theirs(_ edit: (inout PRBuilder) -> Void) -> PRBuilder {
    var builder = PRBuilder()
    edit(&builder)
    return builder
}

struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    let builder: PRBuilder
    var teams: Set<String>? = []
    var bySearch = false
    var lastViewed: Double? = nil
    let expected: PrimaryState
    var testDescription: String { name }
}

extension PRBuilder: @unchecked Sendable {}

@Suite struct PrimaryStateTests {
    static let cases: [Case] = [
        Case(name: "1 direct review request", builder: theirs { $0.requestedUsers = [me] }, expected: .reviewRequested),
        Case(name: "1 team request, team known", builder: theirs { $0.requestedTeams = ["example-org/web"] }, teams: ["example-org/web"], expected: .reviewRequested),
        Case(name: "1 team request, teams unknown, found by request search", builder: theirs { $0.requestedTeams = ["example-org/web"] }, teams: nil, bySearch: true, expected: .reviewRequested),
        Case(name: "team request for a team I am not in", builder: theirs { $0.requestedTeams = ["example-org/infra"] }, teams: ["example-org/web"], expected: .watching),
        Case(name: "1 review request on a draft still counts", builder: theirs { $0.requestedUsers = [me]; $0.draft = true }, expected: .reviewRequested),
        Case(name: "2 re-requested after I reviewed", builder: theirs { $0.requestedUsers = [me]; $0.opinionated = [(me, "CHANGES_REQUESTED", -5, "sha1")] }, expected: .reReviewRequested),
        Case(name: "2 pushed after my changes request", builder: theirs { $0.opinionated = [(me, "CHANGES_REQUESTED", -5, "sha1")] }, expected: .reReviewRequested),
        Case(name: "12 my changes request, no new push", builder: theirs { $0.opinionated = [(me, "CHANGES_REQUESTED", -5, "sha2")] }, expected: .pendingRemediation),
        Case(name: "12 requested, my conversation comment after the last push", builder: theirs { $0.requestedUsers = [me]; $0.conversation = [(me, -1)] }, expected: .pendingRemediation),
        Case(name: "12 team requested, my conversation comment after the last push", builder: theirs { $0.requestedTeams = ["example-org/web"]; $0.conversation = [(me, -1)] }, teams: ["example-org/web"], expected: .pendingRemediation),
        Case(name: "2 requested, author pushed after my comment", builder: theirs { $0.requestedUsers = [me]; $0.conversation = [(me, -3)] }, expected: .reReviewRequested),
        Case(name: "1 requested, only someone else commented", builder: theirs { $0.requestedUsers = [me]; $0.conversation = [("ppatel", -1)] }, expected: .reviewRequested),
        Case(name: "12 my Commented review, no new push", builder: theirs { $0.latest = [(me, "COMMENTED", -1)] }, expected: .pendingRemediation),
        Case(name: "13 my Commented review, author pushed since", builder: theirs { $0.latest = [(me, "COMMENTED", -3)] }, expected: .reviewed),
        Case(name: "13 I approved after commenting", builder: theirs { $0.opinionated = [(me, "APPROVED", -1, "sha2")]; $0.conversation = [(me, -1.5)] }, expected: .reviewed),
        Case(name: "13 I approved", builder: theirs { $0.opinionated = [(me, "APPROVED", -5, "sha2")] }, expected: .reviewed),
        Case(name: "3 changes requested on mine", builder: mine { $0.decision = "CHANGES_REQUESTED"; $0.rollup = "FAILURE" }, expected: .changesRequested),
        Case(name: "3 changes requested without branch protection", builder: mine { $0.decision = nil; $0.opinionated = [("ppatel", "CHANGES_REQUESTED", -1, "sha2")] }, expected: .changesRequested),
        Case(name: "4 CI failing on mine", builder: mine { $0.rollup = "FAILURE" }, expected: .ciFailing),
        Case(name: "4 CI error on mine", builder: mine { $0.rollup = "ERROR" }, expected: .ciFailing),
        Case(name: "9 CI failing on my draft is a draft", builder: mine { $0.rollup = "FAILURE"; $0.draft = true }, expected: .draft),
        Case(name: "5 conflicts", builder: mine { $0.mergeable = "CONFLICTING"; $0.mergeState = "DIRTY" }, expected: .conflicts),
        Case(name: "6 ready to merge", builder: mine { $0.decision = "APPROVED"; $0.mergeState = "CLEAN" }, expected: .readyToMerge),
        Case(name: "6 ready with no checks and unstable optional checks", builder: mine { $0.decision = "APPROVED"; $0.rollup = nil; $0.mergeState = "UNSTABLE" }, expected: .readyToMerge),
        Case(name: "6 ready without branch protection", builder: mine { $0.decision = nil; $0.opinionated = [("asokolov", "APPROVED", -1, "sha2")]; $0.mergeState = "CLEAN" }, expected: .readyToMerge),
        Case(name: "7 new thread comment since last viewed", builder: mine { $0.threads = [(false, "ppatel", -1)] }, lastViewed: -3, expected: .newComments),
        Case(name: "7 new commented review since last viewed", builder: mine { $0.latest = [("ppatel", "COMMENTED", -1)] }, lastViewed: -3, expected: .newComments),
        Case(name: "7 conversation comment after my push, already opened", builder: mine { $0.conversation = [("ppatel", -1)] }, lastViewed: 0, expected: .newComments),
        Case(name: "7 commented review after my push, already opened", builder: mine { $0.latest = [("ppatel", "COMMENTED", -1)] }, lastViewed: 0, expected: .newComments),
        Case(name: "7 open thread reply after my push, already opened", builder: mine { $0.threads = [(false, "ppatel", -1)] }, lastViewed: 0, expected: .newComments),
        Case(name: "10 I replied after their comment", builder: mine { $0.conversation = [("ppatel", -1.5), (me, -1)] }, lastViewed: 0, expected: .waitingForReview),
        Case(name: "10 I pushed after their comment", builder: mine { $0.conversation = [("ppatel", -3)] }, lastViewed: 0, expected: .waitingForReview),
        Case(name: "10 their thread after my push is resolved", builder: mine { $0.threads = [(true, "ppatel", -1)] }, lastViewed: 0, expected: .waitingForReview),
        Case(name: "my own comment is not new", builder: mine { $0.threads = [(false, me, -1)] }, lastViewed: -3, expected: .waitingForReview),
        Case(name: "comment before last viewed is not new", builder: mine { $0.threads = [(false, "ppatel", -5)] }, lastViewed: -3, expected: .waitingForReview),
        Case(name: "8 approved but behind base", builder: mine { $0.decision = "APPROVED"; $0.mergeState = "BEHIND" }, expected: .behindBase),
        Case(name: "10 waiting for review, CI passing", builder: mine { $0.rollup = "SUCCESS" }, expected: .waitingForReview),
        Case(name: "10 waiting for review, CI running", builder: mine { $0.rollup = "PENDING" }, expected: .waitingForReview),
        Case(name: "11 approved, CI running", builder: mine { $0.decision = "APPROVED"; $0.rollup = "PENDING" }, expected: .ciRunning),
        Case(name: "open: approved, green, blocked", builder: mine { $0.decision = "APPROVED"; $0.mergeState = "BLOCKED" }, expected: .open),
    ]

    @Test(arguments: cases)
    func primaryState(_ testCase: Case) {
        let snapshot = derive(testCase.builder, teams: testCase.teams, bySearch: testCase.bySearch, lastViewed: testCase.lastViewed)
        #expect(snapshot.primary == testCase.expected)
    }
}

@Suite struct DimensionTests {
    @Test func roles() {
        #expect(derive(mine { _ in }).roles == [.author])
        #expect(derive(theirs { $0.requestedUsers = [me] }).roles == [.requestedReviewer])
        #expect(derive(theirs { $0.requestedTeams = ["example-org/web"] }, teams: ["example-org/web"]).roles == [.teamRequestedReviewer])
        // Directly requested and on a requested team: direct wins, no team role.
        #expect(derive(theirs { $0.requestedUsers = [me]; $0.requestedTeams = ["example-org/web"] }, teams: ["example-org/web"]).roles == [.requestedReviewer])
        #expect(derive(theirs { $0.opinionated = [(me, "APPROVED", -1, "sha2")] }).roles == [.previousReviewer])
        #expect(derive(theirs { _ in }).roles.isEmpty)
    }

    @Test func watcherRoleOnlyWithoutAnotherRelationship() {
        let context = DerivationContext(viewer: me, teams: [], lastViewed: [:], now: t0)
        let watchedOnly = StatusDeriver.snapshot(for: theirs { _ in }.build(), context: context, foundByRequestSearch: false, watched: true, previous: nil)
        #expect(watchedOnly.roles == [.watcher])
        #expect(watchedOnly.primary == .watching)
        let mineWatched = StatusDeriver.snapshot(for: mine { _ in }.build(), context: context, foundByRequestSearch: false, watched: true, previous: nil)
        #expect(mineWatched.roles == [.author])
    }

    @Test func loginComparisonIgnoresCase() {
        #expect(derive(theirs { $0.requestedUsers = ["YOU"] }).primary == .reviewRequested)
    }

    @Test func reviewStatusCommentedSinceLastPush() {
        #expect(derive(mine { $0.latest = [("ppatel", "COMMENTED", -1)]; $0.pushedAt = -2 }).review == .commented)
        #expect(derive(mine { $0.latest = [("ppatel", "COMMENTED", -3)]; $0.pushedAt = -2 }).review == .reviewRequired)
        #expect(derive(mine { $0.decision = nil }).review == .noReviews)
    }

    @Test func mergeReadiness() {
        #expect(derive(mine { $0.mergeState = "UNKNOWN"; $0.mergeable = "UNKNOWN" }).merge == .unknown)
        #expect(derive(mine { $0.draft = true; $0.mergeState = "DRAFT" }).merge == .draft)
        #expect(derive(mine { $0.mergeState = "HAS_HOOKS" }).merge == .ready)
    }

    @Test func checksAreMappedAndFailingFirst() {
        let snapshot = derive(mine {
            $0.contexts = [
                CheckContext(typename: "CheckRun", name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "https://ci.example.com/1",
                             startedAt: at(-1), completedAt: at(-0.5), context: nil, state: nil, targetUrl: nil, createdAt: nil),
                CheckContext(typename: "CheckRun", name: "e2e", status: "IN_PROGRESS", conclusion: nil, detailsUrl: "",
                             startedAt: at(-1), completedAt: nil, context: nil, state: nil, targetUrl: nil, createdAt: nil),
                CheckContext(typename: "StatusContext", name: nil, status: nil, conclusion: nil, detailsUrl: nil,
                             startedAt: nil, completedAt: nil, context: "lint", state: "FAILURE", targetUrl: nil, createdAt: at(-1)),
                CheckContext(typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED", detailsUrl: nil,
                             startedAt: nil, completedAt: nil, context: nil, state: nil, targetUrl: nil, createdAt: nil),
            ]
        })
        #expect(snapshot.checks.map(\.name) == ["lint", "e2e", "build", "docs"])
        #expect(snapshot.checks.map(\.state) == [.failing, .running, .passing, .neutral])
        #expect(snapshot.checks[2].duration == 1800)
        #expect(snapshot.checks[1].url == nil)
    }

    @Test func reviewersListRequestsThenReviews() {
        let snapshot = derive(theirs {
            $0.requestedUsers = [me]
            $0.requestedTeams = ["example-org/web"]
            $0.opinionated = [("asokolov", "APPROVED", -2, "sha2"), (me, "CHANGES_REQUESTED", -5, "sha1")]
            $0.latest = [("asokolov", "APPROVED", -2), (me, "CHANGES_REQUESTED", -5), ("mchen", "COMMENTED", -1)]
        })
        #expect(snapshot.reviewers.map(\.name) == [me, "example-org/web", "asokolov"])
        #expect(snapshot.reviewers.map(\.verdict) == [.requested, .requested, .approved])
    }

    @Test func ignoredChecksAreLeftOutOfCIStatus() {
        func run(_ name: String, _ conclusion: String) -> CheckContext {
            CheckContext(typename: "CheckRun", name: name, status: "COMPLETED", conclusion: conclusion, detailsUrl: nil,
                         startedAt: nil, completedAt: nil, context: nil, state: nil, targetUrl: nil, createdAt: nil)
        }
        let builder = mine {
            $0.rollup = "FAILURE"
            $0.contexts = [run("Test (ubuntu-latest) / CLI Test (staging)", "FAILURE"), run("build", "SUCCESS")]
        }
        #expect(derive(builder).primary == .ciFailing)
        let ignoring = derive(builder, ignored: ["cli test (STAGING)"])
        #expect(ignoring.ci == .passing)
        #expect(ignoring.primary == .waitingForReview)
        #expect(ignoring.checks.map(\.isIgnored) == [false, true])
        // Only ignored checks: no CI status.
        #expect(derive(mine { $0.contexts = [run("CLI Test (staging)", "FAILURE")] }, ignored: ["staging"]).ci == .none)
        // A blank pattern ignores nothing.
        #expect(derive(builder, ignored: [""]).ci == .failing)
    }

    @Test func ignoredBotCommentsDoNotWaitOnMyReply() {
        let builder = mine { $0.conversation = [("Lint-Bot[bot]", -1)] }
        let viewed = [builder.id: t0]
        func derive(ignoring bots: Set<String>) -> PrimaryState {
            StatusDeriver.snapshot(for: builder.build(), context: DerivationContext(viewer: me, teams: [], lastViewed: viewed, ignoredAuthors: bots, now: t0),
                                   foundByRequestSearch: false, previous: nil).primary
        }
        #expect(derive(ignoring: []) == .newComments)
        #expect(derive(ignoring: ["lint-bot[bot]"]) == .waitingForReview)
    }

    @Test func checkLinksAreLimitedToWebURLs() {
        #expect(StatusDeriver.webURL("https://ci.example.com/run/1")?.host() == "ci.example.com")
        #expect(StatusDeriver.webURL("http://ci.example.com/run/1") != nil)
        #expect(StatusDeriver.webURL("file:///Applications/Calculator.app") == nil)
        #expect(StatusDeriver.webURL("x-custom-app://run?cmd=1") == nil)
        #expect(StatusDeriver.webURL("javascript:alert(1)") == nil)
        #expect(StatusDeriver.webURL("https://") == nil)
        #expect(StatusDeriver.webURL("") == nil)
        #expect(StatusDeriver.webURL(nil) == nil)
    }

    @Test func cachedCheckWithoutIgnoredFlagDecodes() throws {
        let json = #"{ "name": "build", "state": "passing" }"#
        let check = try JSONDecoder().decode(CheckSummary.self, from: Data(json.utf8))
        #expect(check.isIgnored == false)
    }

    @Test func unresolvedThreads() {
        #expect(derive(mine { $0.threads = [(false, "a", -1), (true, "b", -1), (false, "c", -1)] }).unresolvedThreads == 2)
    }

    @Test func stateEnteredAtCarriesForwardWhileUnchanged() {
        let first = derive(theirs { $0.requestedUsers = [me]; $0.updated = -3 })
        #expect(first.stateEnteredAt == at(-3))
        let same = derive(theirs { $0.requestedUsers = [me]; $0.updated = -1 }, previous: first)
        #expect(same.stateEnteredAt == at(-3))
        let changed = derive(theirs { $0.opinionated = [(me, "APPROVED", -0.5, "sha2")] }, previous: first)
        #expect(changed.primary == .reviewed)
        #expect(changed.stateEnteredAt == t0)
    }
}

@Suite struct BrowseTests {
    private func snapshot(_ id: String, _ builder: PRBuilder, lastViewed: Double? = nil) -> PRSnapshot {
        var b = builder
        b.id = id
        return derive(b, lastViewed: lastViewed)
    }

    @Test func scopes() {
        let request = snapshot("R", theirs { $0.requestedUsers = [me] })
        let failing = snapshot("F", mine { $0.rollup = "FAILURE" })
        let waiting = snapshot("W", mine { _ in })
        let reviewed = snapshot("V", theirs { $0.opinionated = [(me, "APPROVED", -1, "sha2")] })
        let all = [request, failing, waiting, reviewed]
        #expect(Browse.visible(all, scope: .inbox, text: "", rules: InboxRules()).map(\.id) == ["R", "F"])
        #expect(Browse.visible(all, scope: .inbox, text: "", rules: InboxRules(snoozed: ["F"])).map(\.id) == ["R"])
        #expect(Browse.visible(all, scope: .snoozed, text: "", rules: InboxRules(snoozed: ["F"])).map(\.id) == ["F"])
        #expect(Browse.visible(all, scope: .mine, text: "", rules: InboxRules()).map(\.id) == ["F", "W"])
        #expect(Browse.visible(all, scope: .reviewing, text: "", rules: InboxRules()).map(\.id) == ["R", "V"])
        #expect(Browse.visible(all, scope: .repo("example-org/web-console"), text: "", rules: InboxRules()).count == 4)
        #expect(Browse.visible(all, scope: .repo("example-org/cli"), text: "", rules: InboxRules()).isEmpty)
    }

    @Test func inboxAgeCutoffAppliesToAuthoredOnly() {
        let oldRequest = snapshot("R", theirs { $0.requestedUsers = [me]; $0.updated = -24 * 200 })
        let oldFailing = snapshot("F", mine { $0.rollup = "FAILURE"; $0.updated = -24 * 200 })
        let newFailing = snapshot("N", mine { $0.rollup = "FAILURE"; $0.updated = -1 })
        let rules = InboxRules(authoredCutoff: at(-24 * 90))
        #expect(Browse.visible([oldRequest, oldFailing, newFailing], scope: .inbox, text: "", rules: rules).map(\.id) == ["R", "N"])
        #expect(Browse.visible([oldRequest, oldFailing, newFailing], scope: .mine, text: "", rules: rules).map(\.id) == ["F", "N"])
    }

    @Test func textSearch() {
        let pr = snapshot("R", theirs { $0.requestedUsers = [me] })
        #expect(Browse.matches(pr, text: "fictional"))
        #expect(Browse.matches(pr, text: "web-console #7"))
        #expect(Browse.matches(pr, text: "MCHEN"))
        #expect(!Browse.matches(pr, text: "fictional nope"))
    }

    @Test func inboxSortsByUrgencyThenLongestWaiting() {
        let newRequest = snapshot("new", theirs { $0.requestedUsers = [me]; $0.updated = -1 })
        let oldRequest = snapshot("old", theirs { $0.requestedUsers = [me]; $0.updated = -10 })
        let ready = snapshot("ready", mine { $0.decision = "APPROVED"; $0.mergeState = "CLEAN"; $0.updated = -20 })
        let waiting = snapshot("wait", mine { _ in })
        let sections = Browse.sectionsByMove([ready, newRequest, waiting, oldRequest])
        #expect(sections.map(\.title) == ["Your move", "Waiting on others"])
        #expect(sections[0].items.map(\.id) == ["old", "new", "ready"])
        #expect(sections[1].items.map(\.id) == ["wait"])
    }
}

@Suite struct SearchQueryTests {
    private func make(_ id: String, repo: String = "example-org/web-console", author: String = "mchen", labels: [String] = [], primary: PrimaryState = .reviewRequested, mine: Bool = false) -> PRSnapshot {
        var builder = PRBuilder()
        builder.id = id
        builder.author = mine ? me : author
        if !mine { builder.requestedUsers = [me] }
        var pr = derive(builder)
        pr.repo = repo
        pr.labels = labels
        pr.primary = primary
        return pr
    }

    @Test func parsing() {
        let query = SearchQuery("repo:web -label:wip  fix Author:MChen state: ")
        #expect(query.filters == [
            .init(key: .repo, value: "web", negated: false),
            .init(key: .label, value: "wip", negated: true),
            .init(key: .author, value: "mchen", negated: false),
        ])
        #expect(query.terms == ["fix"])
        #expect(SearchQuery("   ").isEmpty)
        // Unknown keys are plain text.
        #expect(SearchQuery("http://x").terms == ["http://x"])
    }

    @Test func filters() {
        let a = make("A", repo: "example-org/web-console", author: "mchen", labels: ["frontend"])
        let b = make("B", repo: "example-org/platform-api", author: "jrivera", labels: ["wip"], primary: .ciFailing, mine: true)
        let all = [a, b]
        func ids(_ text: String) -> [String] { all.filter { SearchQuery(text).matches($0) }.map(\.id) }
        #expect(ids("repo:platform") == ["B"])
        #expect(ids("repo:platform repo:web") == ["A", "B"])
        #expect(ids("-repo:platform") == ["A"])
        #expect(ids("author:me") == ["B"])
        #expect(ids("author:mch") == ["A"])
        #expect(ids("state:ci-fail") == ["B"])
        #expect(ids("state:review") == ["A"])
        #expect(ids("label:front") == ["A"])
        #expect(ids("-label:wip fictional") == ["A"])
        #expect(ids("repo:web fictional") == ["A"])
        #expect(ids("repo:web nope") == [])
    }
}

@Suite struct FuzzyMatchTests {
    @Test func subsequenceAndRanking() {
        #expect(FuzzyMatch.score("tok", in: "Rate limit token refresh endpoint") != nil)
        #expect(FuzzyMatch.score("xyz", in: "Rate limit token refresh endpoint") == nil)
        // Word-start and consecutive matches beat scattered ones.
        let wordStart = FuzzyMatch.score("trf", in: "token refresh")!
        let scattered = FuzzyMatch.score("trf", in: "attribute of")!
        #expect(wordStart > scattered)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }

    @Test func prNumbersRankFirst() {
        var builder = PRBuilder()
        builder.requestedUsers = [me]
        var pr = derive(builder)
        pr.number = 1197
        #expect(FuzzyMatch.score("#1197", pr: pr) == 1_000_000)
        #expect(FuzzyMatch.score("1197", pr: pr) == 1_000_000)
        #expect(FuzzyMatch.score("fict", pr: pr) != nil)
        #expect(FuzzyMatch.score("web fict", pr: pr) != nil)
        #expect(FuzzyMatch.score("zzz", pr: pr) == nil)
    }
}

@Suite struct StackTests {
    private func pr(_ id: String, number: Int, head: String, base: String = "main", repo: String = "example-org/web-console", fork: Bool = false, primary: PrimaryState = .waitingForReview) -> PRSnapshot {
        var builder = PRBuilder()
        builder.id = id
        builder.author = me
        var snapshot = derive(builder)
        snapshot.number = number
        snapshot.headRef = head
        snapshot.baseRef = base
        snapshot.repo = repo
        snapshot.isCrossRepository = fork
        snapshot.primary = primary
        return snapshot
    }

    @Test func chainAndFanOut() {
        // main <- A <- B <- C, and A <- D
        let a = pr("A", number: 1, head: "a")
        let b = pr("B", number: 2, head: "b", base: "a")
        let c = pr("C", number: 3, head: "c", base: "b")
        let d = pr("D", number: 4, head: "d", base: "a")
        let lone = pr("L", number: 5, head: "l")
        let positions = Stacks.positions([c, lone, d, b, a])
        #expect(positions["L"] == nil)
        #expect(positions["A"]?.depth == 0)
        #expect(positions["A"]?.parentID == nil)
        #expect(positions["C"]?.depth == 2)
        #expect(positions["C"]?.parentID == "B")
        #expect(positions["D"]?.parentID == "A")
        #expect(positions["A"]?.memberIDs == ["A", "B", "C", "D"])
    }

    @Test func otherReposForksAndDuplicatesAreNotParents() {
        let parentElsewhere = pr("P", number: 1, head: "feature", repo: "example-org/cli")
        let child = pr("C", number: 2, head: "c", base: "feature")
        #expect(Stacks.positions([parentElsewhere, child]).isEmpty)

        let forkParent = pr("F", number: 3, head: "shared", fork: true)
        let onFork = pr("G", number: 4, head: "g", base: "shared")
        #expect(Stacks.positions([forkParent, onFork]).isEmpty)

        let one = pr("X", number: 5, head: "dup")
        let two = pr("Y", number: 6, head: "dup")
        let based = pr("Z", number: 7, head: "z", base: "dup")
        #expect(Stacks.positions([one, two, based]).isEmpty)
    }

    @Test func cyclesTerminate() {
        let a = pr("A", number: 1, head: "a", base: "b")
        let b = pr("B", number: 2, head: "b", base: "a")
        let positions = Stacks.positions([a, b])
        #expect(Set(positions.keys) == ["A", "B"])
    }

    @Test func groupingKeepsStacksTogetherParentFirst() {
        let a = pr("A", number: 1, head: "a")
        let b = pr("B", number: 2, head: "b", base: "a")
        let c = pr("C", number: 3, head: "c", base: "b")
        let x = pr("X", number: 9, head: "x")
        let positions = Stacks.positions([a, b, c, x])
        // C sorted first (for example by urgency): its stack is pulled together there, parent first.
        let ordered = Stacks.grouped([c, x, a, b], positions: positions)
        #expect(ordered.map(\.id) == ["A", "B", "C", "X"])
        // Members missing from the list (another section) are skipped, order kept.
        #expect(Stacks.grouped([x, c, a], positions: positions).map(\.id) == ["X", "A", "C"])
    }

    @Test func boardKeyboardMoves() {
        let columns = [
            PRSection(id: "a", title: "A", items: [pr("A1", number: 1, head: "a1"), pr("A2", number: 2, head: "a2"), pr("A3", number: 3, head: "a3")]),
            PRSection(id: "empty", title: "Empty", items: []),
            PRSection(id: "b", title: "B", items: [pr("B1", number: 4, head: "b1")]),
        ]
        #expect(Browse.boardMove(from: nil, .down, columns: columns) == "A1")
        #expect(Browse.boardMove(from: "A1", .down, columns: columns) == "A2")
        #expect(Browse.boardMove(from: "A3", .down, columns: columns) == "A3")
        #expect(Browse.boardMove(from: "A1", .up, columns: columns) == "A1")
        // Right skips the empty column and clamps the row.
        #expect(Browse.boardMove(from: "A3", .right, columns: columns) == "B1")
        #expect(Browse.boardMove(from: "B1", .left, columns: columns) == "A1")
        #expect(Browse.boardMove(from: "B1", .right, columns: columns) == "B1")
        #expect(Browse.boardMove(from: nil, .down, columns: [PRSection(id: "e", title: "E", items: [])]) == nil)
    }

    @Test func boardColumns() {
        let columns = Browse.boardColumns([
            pr("R", number: 1, head: "r", primary: .reviewRequested),
            pr("F", number: 2, head: "f", primary: .ciFailing),
            pr("W", number: 3, head: "w", primary: .waitingForReview),
            pr("N", number: 4, head: "n", primary: .newComments),
        ])
        #expect(columns.map(\.id) == ["requested", "feedback", "ci", "conflicts", "ready", "waiting"])
        #expect(columns.map { $0.items.map(\.id) } == [["R"], ["N"], ["F"], [], [], ["W"]])
    }
}

@Suite struct ReviewerActionTargetTests {
    private func review(_ id: String, _ login: String, _ userID: String?, _ state: String, _ hour: Double) -> Review {
        Review(author: Account(login: login, avatarUrl: nil, id: userID), state: state, submittedAt: at(hour), commit: nil, id: id)
    }

    @Test func reviewersCarryIDsForActions() {
        var pr = PRBuilder(requestedUsers: ["bnguyen"], requestedTeams: ["example-org/web"]).build()
        pr.latestOpinionatedReviews = Connection(nodes: [
            review("PRR_A", "asokolov", "U_A", "APPROVED", -3),
            review("PRR_B", "bnguyen", "U_B", "CHANGES_REQUESTED", -5),
        ])
        pr.latestReviews = Connection(nodes: [
            review("PRR_A2", "asokolov", "U_A", "COMMENTED", -1),
            review("PRR_B", "bnguyen", "U_B", "CHANGES_REQUESTED", -5),
            review("PRR_C", "cpatel", "U_C", "COMMENTED", -2),
        ])
        let byName = Dictionary(uniqueKeysWithValues: StatusDeriver.reviewers(pr).map { ($0.name, $0) })

        // Re-requested after asking for changes: the change request can still be dismissed.
        let b = try! #require(byName["bnguyen"])
        #expect(b.verdict == .requested && b.opinion == .changesRequested && b.opinionReviewID == "PRR_B")
        #expect(b.canBeDismissed && !b.canBeReRequested)

        // Commented after approving: the approval is what gets dismissed.
        let a = try! #require(byName["asokolov"])
        #expect(a.verdict == .commented && a.opinion == .approved && a.opinionReviewID == "PRR_A" && a.userID == "U_A")
        #expect(a.canBeDismissed && a.canBeReRequested)

        // Only commented: nothing to dismiss, but a review can be re-requested.
        let c = try! #require(byName["cpatel"])
        #expect(!c.canBeDismissed && c.canBeReRequested)

        let team = try! #require(byName["example-org/web"])
        #expect(!team.canBeDismissed && !team.canBeReRequested)
    }

    @Test func cachedReviewsWithoutIDsOfferNoActions() {
        let pr = PRBuilder(opinionated: [("asokolov", "APPROVED", -3, "sha2")]).build()
        let reviewer = StatusDeriver.reviewers(pr)[0]
        #expect(!reviewer.canBeDismissed && !reviewer.canBeReRequested)
    }
}
