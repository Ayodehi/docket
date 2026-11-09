import Foundation
import Testing
@testable import GitHubKit
@testable import Sync

private let now = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func summary(_ id: String, updated: Date = daysAgo(1), sha: String = "a", ci: String? = "SUCCESS", repo: String = "example-org/r",
                     title: String = "Fictional change", author: String = "mchen") -> PRSummary {
    PRSummary(id: id, updatedAt: updated, headRefOid: sha, isDraft: false, reviewDecision: nil, ciRollup: ci, repo: repo, title: title, author: author)
}

private func spec(_ alias: SearchAlias, _ tier: Tier) -> SearchSpec {
    SearchCatalog.specs(now: now, policy: TierPolicy()).first { $0.key == SearchKey(alias, tier) }!
}

@Suite struct SearchCatalogTests {
    @Test func tierQueriesUseUTCDayBoundaries() {
        let specs = Dictionary(uniqueKeysWithValues: SearchCatalog.specs(now: now, policy: TierPolicy()).map { ($0.key.description, $0.query) })
        #expect(specs["requested.hot"] == "is:pr is:open review-requested:@me archived:false")
        #expect(specs["authored.hot"] == "is:pr is:open author:@me archived:false updated:>=2026-09-13")
        #expect(specs["authored.warm"] == "is:pr is:open author:@me archived:false updated:2026-07-15..2026-09-12")
        #expect(specs["authored.cold"] == "is:pr is:open author:@me archived:false updated:<2026-07-15")
        #expect(specs["reviewed.cold"] == "is:pr is:open reviewed-by:@me -author:@me archived:false updated:<2026-07-15")
        #expect(specs.count == 7)
    }

    @Test func hiddenReposAreExcludedFromEveryQuery() {
        let specs = SearchCatalog.specs(now: now, policy: TierPolicy(), excluding: ["example-org/b", "example-org/a"])
        #expect(specs.allSatisfy { $0.query.hasSuffix(" -repo:example-org/a -repo:example-org/b") })
        let many = Set((0..<40).map { "example-org/repo-\($0)" })
        let capped = SearchCatalog.specs(now: now, policy: TierPolicy(), excluding: many)[0].query
        #expect(capped.components(separatedBy: "-repo:").count - 1 == 30)
    }

    @Test func watchedReposGetTieredSearches() {
        let specs = SearchCatalog.specs(now: now, policy: TierPolicy(), excluding: ["example-org/b"], watching: ["example-org/b", "example-org/w"])
        let watched = specs.filter { $0.key.alias == .watched }
        #expect(watched.map(\.key.tier) == [.hot, .warm, .cold])
        #expect(watched[0].query == "is:pr is:open archived:false repo:example-org/w updated:>=2026-09-13 -repo:example-org/b")
        #expect(SearchCatalog.specs(now: now, policy: TierPolicy()).filter { $0.key.alias == .watched }.isEmpty)
    }

    @Test func unwatchingDropsWatchOnlyRecords() {
        var state = SyncState()
        state.setWatchedRepos(["example-org/w"])
        let watchSpec = SearchCatalog.specs(now: now, policy: TierPolicy(), watching: ["example-org/w"]).first { $0.key == SearchKey(.watched, .hot) }!
        state.apply(results: [summary("W", repo: "example-org/w"), summary("M", repo: "example-org/w")], for: watchSpec, at: now)
        state.apply(results: [summary("M", repo: "example-org/w")], for: spec(.authored, .hot), at: now)
        #expect(state.lastRun["watched.hot"] != nil)
        state.setWatchedRepos([])
        #expect(state.records["W"] == nil)
        #expect(state.records["M"]?.sources == [.authored])
        state.setWatchedRepos(["example-org/x"])
        #expect(state.lastRun["watched.hot"] == nil)
    }

    @Test func tierAssignment() {
        let policy = TierPolicy()
        #expect(policy.tier(updatedAt: daysAgo(1), now: now) == .hot)
        #expect(policy.tier(updatedAt: daysAgo(45), now: now) == .warm)
        #expect(policy.tier(updatedAt: daysAgo(200), now: now) == .cold)
    }
}

@Suite struct SyncStateTests {
    @Test func everySearchIsDueInitiallyThenByTierInterval() {
        var state = SyncState()
        let policy = TierPolicy()
        #expect(state.dueSpecs(now: now, policy: policy, pollInterval: 60).count == 7)
        for spec in SearchCatalog.specs(now: now, policy: policy) { state.lastRun[spec.key.description] = now }

        let afterPoll = state.dueSpecs(now: now.addingTimeInterval(60), policy: policy, pollInterval: 60).map(\.key.tier)
        #expect(Set(afterPoll) == [.hot])
        let afterWarm = state.dueSpecs(now: now.addingTimeInterval(300), policy: policy, pollInterval: 60).map(\.key.tier)
        #expect(Set(afterWarm) == [.hot, .warm])
        let afterCold = state.dueSpecs(now: now.addingTimeInterval(1800), policy: policy, pollInterval: 60)
        #expect(afterCold.count == 7)
        #expect(state.dueSpecs(now: now.addingTimeInterval(10), policy: policy, pollInterval: 60, forceHot: true).count == 3)
    }

    @Test func searchAddsAndMergesSources() {
        var state = SyncState()
        state.apply(results: [summary("A")], for: spec(.authored, .hot), at: now)
        state.apply(results: [summary("A"), summary("B")], for: spec(.requested, .hot), at: now)
        #expect(state.records["A"]?.sources == [.authored, .requested])
        #expect(state.records["B"]?.sources == [.requested])
        #expect(state.lastRun["requested.hot"] == now)
    }

    @Test func missingFromCoveringSearchDropsSourceThenRecord() {
        var state = SyncState()
        state.apply(results: [summary("A")], for: spec(.authored, .hot), at: now)
        state.apply(results: [summary("A")], for: spec(.requested, .hot), at: now)
        // Review request removed: requested no longer returns it.
        state.apply(results: [], for: spec(.requested, .hot), at: now)
        #expect(state.records["A"]?.sources == [.authored])
        // Closed: the hot authored search covers it and no longer returns it.
        state.apply(results: [], for: spec(.authored, .hot), at: now)
        #expect(state.records["A"] == nil)
    }

    @Test func agingOutOfATierDoesNotDrop() {
        var state = SyncState()
        // Last seen by the hot search, but now 31 days old: the hot search no longer covers it.
        state.apply(results: [summary("A", updated: daysAgo(31))], for: spec(.authored, .hot), at: now)
        state.apply(results: [], for: spec(.authored, .hot), at: now)
        #expect(state.records["A"] != nil)
        // The warm search covers it; when warm stops returning it, it is gone.
        state.apply(results: [], for: spec(.authored, .warm), at: now)
        #expect(state.records["A"] == nil)
    }

    @Test func otherSearchesDoNotDrop() {
        var state = SyncState()
        state.apply(results: [summary("A")], for: spec(.authored, .hot), at: now)
        state.apply(results: [], for: spec(.reviewed, .hot), at: now)
        #expect(state.records["A"] != nil)
    }

    @Test func hiddenRepoRecordsAreDroppedAndSkipped() {
        var state = SyncState()
        state.apply(results: [summary("A", repo: "example-org/keep"), summary("B", repo: "example-org/hide")], for: spec(.requested, .hot), at: now)
        state.setHiddenRepos(["example-org/hide"])
        #expect(Set(state.records.keys) == ["A"])
        // Beyond the query cap, results from hidden repos are filtered locally.
        state.apply(results: [summary("A", repo: "example-org/keep"), summary("B", repo: "example-org/hide")], for: spec(.requested, .hot), at: now)
        #expect(Set(state.records.keys) == ["A"])
        #expect(!state.lastRun.isEmpty)
        // Unhiding makes every search due again.
        let unhid = state.setHiddenRepos([])
        #expect(unhid)
        #expect(state.lastRun.isEmpty)
    }

    @Test func ignoreRulesMatchTitleAndAuthor() {
        let rules = IgnoreRules(["[Snyk]", "author:dependabot[bot]", "  "])
        #expect(rules.matches(title: "[Snyk] Security upgrade axios", author: "you"))
        #expect(rules.matches(title: "[snyk] lowercase too", author: "you"))
        #expect(rules.matches(title: "Bump lodash from 4.17.20 to 4.17.21", author: "Dependabot[bot]"))
        // GraphQL reports the same bot as "dependabot".
        #expect(rules.matches(title: "Bump lodash", author: "dependabot"))
        #expect(IgnoreRules(["author:claude"]).matches(title: "x", author: "claude[bot]"))
        #expect(!rules.matches(title: "Fix snyk config", author: "you"))
        #expect(!rules.matches(title: "Bump x", author: "dependabot-fan"))
        #expect(!IgnoreRules(["  "]).matches(title: "anything", author: "x"))
        #expect(IgnoreRules(["  "]).isEmpty)
    }

    @Test func ignoredPRsAreDroppedBeforeDetailAndReturnWhenRelaxed() {
        var state = SyncState()
        state.apply(results: [summary("S", title: "[Snyk] Upgrade react"), summary("K")], for: spec(.authored, .hot), at: now)
        state.setIgnoreRules(IgnoreRules(["[snyk]"]))
        #expect(Set(state.records.keys) == ["K"])
        #expect(state.ignoredIDs == ["S"])
        // Later searches keep leaving it out, so it never gets a detail fetch.
        state.apply(results: [summary("S", title: "[Snyk] Upgrade react"), summary("K")], for: spec(.authored, .hot), at: now)
        #expect(Set(state.records.keys) == ["K"])
        #expect(state.detailBatches(now: now, policy: TierPolicy()).flatMap { $0 } == ["K"])
        // Removing the rule makes every search due again.
        state.setIgnoreRules(IgnoreRules())
        #expect(state.lastRun.isEmpty)
        #expect(state.ignoredIDs.isEmpty)
    }

    @Test func detailBatchesPrioritizeChangedAndHot() {
        var state = SyncState()
        var policy = TierPolicy()
        policy.detailBatchSize = 2
        state.apply(results: [summary("cold", updated: daysAgo(200)), summary("hot1"), summary("hot2", updated: daysAgo(2))], for: spec(.requested, .hot), at: now)
        let batches = state.detailBatches(now: now, policy: policy)
        #expect(batches == [["hot1", "hot2"], ["cold"]])
    }

    @Test func detailRefreshOnChangeOrAge() throws {
        var state = SyncState()
        let policy = TierPolicy()
        state.apply(results: [summary("A")], for: spec(.requested, .hot), at: now)
        let detail = try pr(id: "A", updated: daysAgo(1))
        state.apply(details: [detail], requested: ["A"], at: now)
        #expect(state.detailBatches(now: now, policy: policy).isEmpty)

        // CI changed in discovery: refetch.
        var changed = PRSummary(detail)
        changed.ciRollup = "FAILURE"
        state.apply(results: [changed], for: spec(.requested, .hot), at: now)
        #expect(state.detailBatches(now: now, policy: policy) == [["A"]])

        // Unchanged but older than the hot refresh interval: refetch.
        state.apply(details: [detail], requested: ["A"], at: now)
        state.apply(results: [PRSummary(detail)], for: spec(.requested, .hot), at: now)
        #expect(state.detailBatches(now: now.addingTimeInterval(599), policy: policy).isEmpty)
        #expect(state.detailBatches(now: now.addingTimeInterval(600), policy: policy) == [["A"]])
    }

    @Test func unknownMergeStateIsRefetched() throws {
        var state = SyncState()
        state.apply(results: [summary("A")], for: spec(.requested, .hot), at: now)
        state.apply(details: [try pr(id: "A", updated: daysAgo(1), mergeable: "UNKNOWN")], requested: ["A"], at: now)
        #expect(state.detailBatches(now: now, policy: TierPolicy()) == [["A"]])
    }

    @Test func olderDetailDoesNotReplaceNewer() throws {
        // A sync batch that started before a review action finishes after it.
        var state = SyncState()
        state.apply(results: [summary("A")], for: spec(.requested, .hot), at: now)
        state.apply(details: [try pr(id: "A", updated: daysAgo(1), mergeable: "CONFLICTING")], requested: ["A"], at: now)
        state.apply(details: [try pr(id: "A", updated: daysAgo(2))], requested: ["A"], at: now)
        #expect(state.records["A"]?.detail?.mergeable == "CONFLICTING")
    }

    @Test func closedOrMissingDetailsDropRecords() throws {
        var state = SyncState()
        state.apply(results: [summary("A"), summary("B")], for: spec(.requested, .hot), at: now)
        state.apply(details: [try pr(id: "A", updated: daysAgo(1), state: "MERGED")], requested: ["A", "B"], at: now)
        #expect(state.records.isEmpty)
    }
}

@Suite struct SyncEngineTests {
    @Test func firstCycleRunsAllSearchesFollowsPagesAndFetchesDetails() async throws {
        let client = FakeClient()
        await client.setPages(query: "author:@me archived:false updated:>=", pages: [
            SearchPage(issueCount: 2, hasNextPage: true, endCursor: "c1", nodes: [summary("A")]),
            SearchPage(issueCount: 2, hasNextPage: false, endCursor: nil, nodes: [summary("B")]),
        ])
        await client.setDetails([try pr(id: "A", updated: daysAgo(1)), try pr(id: "B", updated: daysAgo(1))])
        let engine = SyncEngine(client: client, state: SyncState(), clock: { now }, persist: { _ in })

        let report = try await engine.runCycle(pollInterval: 60)
        let state = await engine.state
        #expect(report.searches.count == 7)
        #expect(Set(state.records.keys) == ["A", "B"])
        #expect(state.records["A"]?.detail != nil)
        #expect(state.viewerLogin == "you")
        #expect(state.teams == ["example-org/web"])
        #expect(await client.discoverCalls == 2)
    }

    @Test func progressIsReportedAfterDiscoveryAndEachBatch() async throws {
        let client = FakeClient()
        await client.setPages(query: "review-requested", pages: [SearchPage(issueCount: 1, hasNextPage: false, endCursor: nil, nodes: [summary("A")])])
        await client.setDetails([try pr(id: "A", updated: daysAgo(1))])
        let seen = Counter()
        let engine = SyncEngine(client: client, state: SyncState(), clock: { now }, progress: { state in
            await seen.record(state.records["A"]?.detail != nil)
        }, persist: { _ in })
        try await engine.runCycle(pollInterval: 60)
        #expect(await seen.values == [false, true])
    }

    @Test func serverTimeoutHalvesDetailBatchSize() async throws {
        let client = FakeClient()
        await client.setPages(query: "review-requested", pages: [SearchPage(issueCount: 1, hasNextPage: false, endCursor: nil, nodes: [summary("A")])])
        await client.failDetails(with: .server(status: 502))
        let engine = SyncEngine(client: client, state: SyncState(), clock: { now }, persist: { _ in })
        try await engine.runCycle(pollInterval: 60)
        #expect(await engine.state.detailBatchSize == 5)
        #expect(await engine.state.records["A"]?.detail == nil)
    }

    @Test func discoveryErrorKeepsPreviousState() async throws {
        var seeded = SyncState()
        seeded.apply(results: [summary("A")], for: spec(.requested, .hot), at: now)
        seeded.lastRun = [:]
        let client = FakeClient()
        await client.failDiscovery(with: .unauthorized)
        let engine = SyncEngine(client: client, state: seeded, clock: { now }, persist: { _ in })
        await #expect(throws: GitHubError.unauthorized) { try await engine.runCycle(pollInterval: 60) }
        #expect(await engine.state.records["A"] != nil)
    }

    @Test func concurrentCyclesJoin() async throws {
        let client = FakeClient()
        let engine = SyncEngine(client: client, state: SyncState(), clock: { now }, persist: { _ in })
        async let first = engine.runCycle(pollInterval: 60)
        async let second = engine.runCycle(pollInterval: 60)
        _ = try await (first, second)
        #expect(await client.discoverCalls == 1)
    }
}

// MARK: - Helpers

private actor Counter {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}

private func pr(id: String, updated: Date, state: String = "OPEN", mergeable: String = "MERGEABLE") throws -> PullRequest {
    let json = """
    { "id": "\(id)", "number": 1, "title": "t", "url": "https://github.com/example-org/r/pull/1", "state": "\(state)", "isDraft": false,
      "createdAt": "2026-10-01T00:00:00Z", "updatedAt": "\(ISO8601DateFormatter().string(from: updated))",
      "additions": 1, "deletions": 1, "changedFiles": 1, "author": { "login": "you" },
      "repository": { "nameWithOwner": "example-org/r" }, "headRefName": "h", "headRefOid": "a", "baseRefName": "main",
      "isCrossRepository": false, "reviewDecision": null, "mergeable": "\(mergeable)", "mergeStateStatus": "CLEAN",
      "labels": { "nodes": [] }, "reviewRequests": { "nodes": [] }, "latestOpinionatedReviews": { "nodes": [] },
      "latestReviews": { "nodes": [] }, "comments": { "nodes": [] }, "reviewThreads": { "totalCount": 0, "nodes": [] },
      "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "state": "SUCCESS" } } } ] } }
    """
    return try GitHubJSON.decoder().decode(PullRequest.self, from: Data(json.utf8))
}

private actor FakeClient: GitHubClient {
    private var pagesByQuery: [(match: String, pages: [SearchPage])] = []
    private var details: [String: PullRequest] = [:]
    private var detailError: GitHubError?
    private var discoveryError: GitHubError?
    private(set) var discoverCalls = 0

    func setPages(query: String, pages: [SearchPage]) { pagesByQuery.append((query, pages)) }
    func setDetails(_ prs: [PullRequest]) { for pr in prs { details[pr.id] = pr } }
    func failDetails(with error: GitHubError) { detailError = error }
    func failDiscovery(with error: GitHubError) { discoveryError = error }

    nonisolated func viewer() async throws -> TokenInfo { TokenInfo(login: "you", scopes: nil) }

    func discover(_ requests: [SearchRequest]) async throws -> DiscoveryResult {
        discoverCalls += 1
        try await Task.sleep(for: .milliseconds(20))
        if let discoveryError { throw discoveryError }
        let pages = requests.map { request -> SearchPage in
            guard let entry = pagesByQuery.first(where: { request.query.contains($0.match) }) else {
                return SearchPage(issueCount: 0, hasNextPage: false, endCursor: nil, nodes: [])
            }
            let index = request.after == nil ? 0 : (entry.pages.firstIndex { $0.endCursor == request.after } ?? -1) + 1
            return entry.pages[min(index, entry.pages.count - 1)]
        }
        return DiscoveryResult(viewerLogin: "you", rateLimit: nil, pages: pages)
    }

    nonisolated func teams(login: String) async throws -> Set<String> { ["example-org/web"] }

    func pullRequests(ids: [String]) async throws -> DetailResult {
        if let detailError { throw detailError }
        return DetailResult(pullRequests: ids.compactMap { details[$0] }, rateLimit: nil)
    }
}

@Suite struct SyncScheduleTests {
    private func delay(_ edit: (inout SyncConditions) -> Void = { _ in }, poll: TimeInterval = 60, rate: RateLimitInfo? = nil, limitedUntil: Date? = nil) -> TimeInterval? {
        var conditions = SyncConditions()
        edit(&conditions)
        return SyncSchedule.delay(conditions: conditions, pollInterval: poll, rateLimit: rate, rateLimitedUntil: limitedUntil, now: now)
    }

    @Test func intervals() {
        #expect(delay() == 60)
        #expect(delay(poll: 900) == 900)
        #expect(delay({ $0.windowVisible = true }) == 30)
        #expect(delay({ $0.windowVisible = true }, poll: 15) == 15)
        #expect(delay({ $0.idleSeconds = 601 }) == 300)
        #expect(delay({ $0.lowPowerMode = true }) == 300)
        #expect(delay({ $0.onBatteryBelow20 = true; $0.windowVisible = true }) == 300)
    }

    @Test func pauses() {
        #expect(delay({ $0.asleep = true }) == nil)
        #expect(delay({ $0.screenLocked = true }) == nil)
        #expect(delay({ $0.online = false }) == nil)
    }

    @Test func rateLimits() {
        let low = RateLimitInfo(cost: 1, remaining: 400, resetAt: now.addingTimeInterval(1200), limit: 5000)
        #expect(delay(rate: low) == 600)
        let lowResetSoon = RateLimitInfo(cost: 1, remaining: 400, resetAt: now.addingTimeInterval(120), limit: 5000)
        #expect(delay(rate: lowResetSoon) == 120)
        let healthy = RateLimitInfo(cost: 1, remaining: 4000, resetAt: now.addingTimeInterval(1200), limit: 5000)
        #expect(delay(rate: healthy) == 60)
        #expect(delay(limitedUntil: now.addingTimeInterval(900)) == 900)
        #expect(delay(limitedUntil: now.addingTimeInterval(-10)) == 60)
    }
}
