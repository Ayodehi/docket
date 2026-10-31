import Foundation
import GitHubKit

/// One tracked PR: the cheap summary from discovery plus the last full detail.
public struct PRRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var summary: PRSummary
    /// Which searches currently return this PR (my relationship to it).
    public var sources: Set<SearchAlias>
    public var detail: PullRequest?
    public var detailFetchedAt: Date?
    /// The summary when `detail` was fetched. A mismatch means the PR changed since.
    public var detailSummary: PRSummary?

    public init(summary: PRSummary, sources: Set<SearchAlias>) {
        self.id = summary.id
        self.summary = summary
        self.sources = sources
    }

    /// `owner/name`, from the summary or, for older cached records, the detail.
    public var repo: String? { summary.repo ?? detail?.repository.nameWithOwner }

    public var hasChangedSinceDetail: Bool {
        detail == nil || detailSummary != summary || detail?.mergeable == "UNKNOWN" || predatesCurrentQuery
    }

    /// Cached before fields were added to the detail query (review IDs, conversation comments):
    /// refetch once.
    var predatesCurrentQuery: Bool {
        guard let detail else { return false }
        return detail.comments == nil || (detail.latestOpinionatedReviews.nodes + detail.latestReviews.nodes).contains { $0.id == nil }
    }
}

/// Everything the sync engine knows, persisted between launches as one file.
public struct SyncState: Codable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion = SyncState.schemaVersion
    public var viewerLogin: String?
    public var records: [String: PRRecord] = [:]
    public var lastRun: [String: Date] = [:]
    public var rateLimit: RateLimitInfo?
    public var lastSuccess: Date?
    public var detailBatchSize: Int?
    /// `org/slug` of my teams; `nil` until fetched or when the token cannot read them.
    public var teams: Set<String>?
    public var teamsFetchedAt: Date?
    /// `owner/name` of repos the user hid. Excluded from searches and never fetched.
    public var hiddenRepos: Set<String> = []
    /// `owner/name` of repos whose open PRs are all tracked (role Watching).
    public var watchedRepos: Set<String> = []
    /// The last discovery was missing results because of SAML SSO.
    public var ssoPartial = false
    public var ignoreRules = IgnoreRules()
    /// PRs left out by `ignoreRules` in recent searches, for the count in Settings.
    public var ignoredIDs: Set<String> = []

    public init() {}

    // MARK: Discovery

    public func dueSpecs(now: Date, policy: TierPolicy, pollInterval: TimeInterval, forceHot: Bool = false) -> [SearchSpec] {
        SearchCatalog.specs(now: now, policy: policy, excluding: hiddenRepos, watching: watchedRepos).filter { spec in
            if forceHot && spec.key.tier == .hot { return true }
            guard let last = lastRun[spec.key.description] else { return true }
            // Small tolerance so a timer firing a moment early still counts.
            return now.timeIntervalSince(last) >= policy.discoveryInterval(spec.key.tier, pollInterval: pollInterval) - 2
        }
    }

    /// Applies a complete (all pages) search result.
    public mutating func apply(results: [PRSummary], for spec: SearchSpec, at now: Date) {
        let alias = spec.key.alias
        var results = results.filter { !hiddenRepos.contains($0.repo ?? "") }
        if !ignoreRules.isEmpty {
            let ignored = results.filter(ignoreRules.matches)
            ignoredIDs.formUnion(ignored.map(\.id))
            results.removeAll(where: ignoreRules.matches)
        }
        let returned = Set(results.map(\.id))
        for summary in results {
            if var record = records[summary.id] {
                record.summary = summary
                record.sources.insert(alias)
                records[summary.id] = record
            } else {
                records[summary.id] = PRRecord(summary: summary, sources: [alias])
            }
        }
        for (id, var record) in records where !returned.contains(id) && record.sources.contains(alias) && spec.covers(record.summary.updatedAt) {
            record.sources.remove(alias)
            records[id] = record.sources.isEmpty ? nil : record
        }
        lastRun[spec.key.description] = now
    }

    // MARK: Detail

    /// IDs to fetch this cycle, in batches. Changed PRs first (hot before cold), then periodic refresh.
    public func detailBatches(now: Date, policy: TierPolicy) -> [[String]] {
        let size = max(1, detailBatchSize ?? policy.detailBatchSize)
        let order: (PRRecord, PRRecord) -> Bool = { a, b in
            let ta = policy.tier(updatedAt: a.summary.updatedAt, now: now)
            let tb = policy.tier(updatedAt: b.summary.updatedAt, now: now)
            return ta != tb ? ta < tb : a.summary.updatedAt > b.summary.updatedAt
        }
        let changed = records.values.filter(\.hasChangedSinceDetail).sorted(by: order)
        let due = records.values.filter { record in
            guard !record.hasChangedSinceDetail, let fetched = record.detailFetchedAt else { return false }
            let tier = policy.tier(updatedAt: record.summary.updatedAt, now: now)
            return now.timeIntervalSince(fetched) >= policy.detailRefresh(tier)
        }.sorted { ($0.detailFetchedAt ?? .distantPast) < ($1.detailFetchedAt ?? .distantPast) }

        return Array(changed.map(\.id).chunked(size).prefix(policy.maxChangedBatchesPerCycle))
            + Array(due.map(\.id).chunked(size).prefix(policy.maxRotationBatchesPerCycle))
    }

    public mutating func apply(details: [PullRequest], requested ids: [String], at now: Date) {
        let returned = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            guard var record = records[id] else { continue }
            guard let pr = returned[id], pr.state == "OPEN" else {
                // Merged, closed, deleted, or no longer visible to the token.
                records[id] = nil
                continue
            }
            // A detail fetch that started before a review action must not undo its result.
            if let current = record.detail, current.updatedAt > pr.updatedAt { continue }
            let summary = PRSummary(pr)
            record.summary = summary
            record.detail = pr
            record.detailFetchedAt = now
            record.detailSummary = summary
            records[id] = record
        }
    }

    /// Sets the hidden repos and drops their records. Returns true when a repo was unhidden,
    /// in which case every search is made due so its PRs come back on the next cycle.
    @discardableResult
    public mutating func setHiddenRepos(_ repos: Set<String>) -> Bool {
        let unhidden = !hiddenRepos.subtracting(repos).isEmpty
        hiddenRepos = repos
        records = records.filter { !repos.contains($0.value.repo ?? "") }
        if unhidden { lastRun = [:] }
        return unhidden
    }

    /// Sets the ignore rules and drops matching records. Relaxing the rules makes every search due
    /// so previously ignored PRs come back on the next cycle.
    public mutating func setIgnoreRules(_ rules: IgnoreRules) {
        let relaxed = rules != ignoreRules && !ignoreRules.isEmpty
        ignoreRules = rules
        ignoredIDs = []
        guard !rules.isEmpty else {
            if relaxed { lastRun = [:] }
            return
        }
        for (id, record) in records {
            let title = record.summary.title ?? record.detail?.title
            let author = record.summary.author ?? record.detail?.author?.login
            if rules.matches(title: title, author: author) {
                records[id] = nil
                ignoredIDs.insert(id)
            }
        }
        if relaxed { lastRun = [:] }
    }

    /// Sets the watched repos. Newly watched repos are searched on the next cycle; PRs that were
    /// only tracked because their repo was watched are dropped when it is unwatched.
    public mutating func setWatchedRepos(_ repos: Set<String>) {
        let removed = watchedRepos.subtracting(repos)
        let added = repos.subtracting(watchedRepos)
        watchedRepos = repos
        for (id, var record) in records where removed.contains(record.repo ?? "") && record.sources.contains(.watched) {
            record.sources.remove(.watched)
            records[id] = record.sources.isEmpty ? nil : record
        }
        if !added.isEmpty {
            for tier in Tier.allCases { lastRun[SearchKey(.watched, tier).description] = nil }
        }
    }

    public func count(in tier: Tier, now: Date, policy: TierPolicy) -> Int {
        records.values.filter { policy.tier(updatedAt: $0.summary.updatedAt, now: now) == tier }.count
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
