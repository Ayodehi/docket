import Foundation
import GitHubKit

/// Runs sync cycles one at a time. A cycle requested while one is running joins it.
///
/// M1 scope: tiered discovery with paging and detail batches. Adaptive intervals, power and
/// network awareness, and rate-limit slowdown arrive in M2.
public actor SyncEngine {
    public struct Report: Sendable {
        public var searches: [String]
        public var detailFetched: Int
        public var pointsUsed: Int
    }

    private let client: any GitHubClient
    private let policy: TierPolicy
    private let clock: @Sendable () -> Date
    private let persist: @Sendable (SyncState) async -> Void
    /// Called after discovery and after each detail batch so the UI fills in during long cycles.
    private let progress: @Sendable (SyncState) async -> Void
    /// Upper bound on pages per search per cycle, as a guard against runaway paging.
    private let maxPages = 10
    private let teamsRefresh: TimeInterval = 60 * 60

    public private(set) var state: SyncState
    private var running: Task<Report, any Error>?

    public init(
        client: any GitHubClient,
        state: SyncState,
        policy: TierPolicy = TierPolicy(),
        clock: @escaping @Sendable () -> Date = { Date() },
        progress: @escaping @Sendable (SyncState) async -> Void = { _ in },
        persist: @escaping @Sendable (SyncState) async -> Void
    ) {
        self.client = client
        self.state = state
        self.policy = policy
        self.clock = clock
        self.progress = progress
        self.persist = persist
    }

    /// Applies the user's hidden repos immediately and persists. Unhiding forces a full rediscovery.
    public func setHiddenRepos(_ repos: Set<String>) async {
        state.setHiddenRepos(repos)
        await persist(state)
    }

    public func setIgnoreRules(_ rules: IgnoreRules) async {
        state.setIgnoreRules(rules)
        await persist(state)
    }

    public func setWatchedRepos(_ repos: Set<String>) async {
        state.setWatchedRepos(repos)
        await persist(state)
    }

    /// Applies a PR returned by a review action, so the result shows without waiting for a sync.
    public func apply(actionResult pr: PullRequest) async {
        guard state.records[pr.id] != nil else { return }
        state.apply(details: [pr], requested: [pr.id], at: clock())
        await persist(state)
    }

    @discardableResult
    public func runCycle(pollInterval: TimeInterval, forceHot: Bool = false) async throws -> Report {
        if let running { return try await running.value }
        let task = Task { try await self.cycle(pollInterval: pollInterval, forceHot: forceHot) }
        running = task
        defer { running = nil }
        return try await task.value
    }

    private func cycle(pollInterval: TimeInterval, forceHot: Bool) async throws -> Report {
        let now = clock()
        var points = 0
        let specs = state.dueSpecs(now: now, policy: policy, pollInterval: pollInterval, forceHot: forceHot)

        if !specs.isEmpty {
            let (results, login, cost) = try await discover(specs)
            points += cost
            if let previous = state.viewerLogin, previous != login {
                // A different account: start over rather than mixing data.
                state = SyncState()
            }
            state.viewerLogin = login
            for spec in specs {
                state.apply(results: results[spec.key] ?? [], for: spec, at: now)
            }
            await progress(state)
        }

        if let login = state.viewerLogin, now.timeIntervalSince(state.teamsFetchedAt ?? .distantPast) >= teamsRefresh {
            state.teamsFetchedAt = now
            do {
                state.teams = try await client.teams(login: login)
                points += 1
            } catch let error as GitHubError where error == .unauthorized {
                throw error
            } catch {
                // Usually missing read:org. Team requests still show up through the request search.
                state.teams = nil
            }
        }

        var fetched = 0
        for batch in state.detailBatches(now: now, policy: policy) {
            try Task.checkCancellation()
            do {
                let result = try await client.pullRequests(ids: batch)
                state.apply(details: result.pullRequests, requested: batch, at: clock())
                if let rate = result.rateLimit { state.rateLimit = rate; points += rate.cost }
                fetched += batch.count
                await progress(state)
            } catch GitHubError.server {
                // Usually a GitHub query timeout. Use smaller batches from now on and stop for this cycle.
                state.detailBatchSize = max(2, (state.detailBatchSize ?? policy.detailBatchSize) / 2)
                break
            }
        }

        state.lastSuccess = clock()
        await persist(state)
        return Report(searches: specs.map(\.key.description), detailFetched: fetched, pointsUsed: points)
    }

    /// Runs the specs' searches in one request per page round, following cursors.
    private func discover(_ specs: [SearchSpec]) async throws -> ([SearchKey: [PRSummary]], String, Int) {
        var results: [SearchKey: [PRSummary]] = [:]
        var pending = specs.map { (spec: $0, after: String?.none) }
        var login = ""
        var points = 0
        var round = 0
        while !pending.isEmpty && round < maxPages {
            try Task.checkCancellation()
            let response = try await client.discover(pending.map { SearchRequest(query: $0.spec.query, after: $0.after) })
            login = response.viewerLogin
            if round == 0 { state.ssoPartial = response.ssoPartial }
            if let rate = response.rateLimit { state.rateLimit = rate; points += rate.cost }
            var next: [(spec: SearchSpec, after: String?)] = []
            for (item, page) in zip(pending, response.pages) {
                results[item.spec.key, default: []] += page.nodes
                if page.hasNextPage, let cursor = page.endCursor { next.append((item.spec, cursor)) }
            }
            pending = next
            round += 1
        }
        if let item = pending.first {
            // Applying incomplete results would wrongly drop PRs, so fail the cycle instead.
            throw GitHubError.graphQL(["Search \(item.spec.key) exceeded \(maxPages) pages"])
        }
        return (results, login, points)
    }
}
