import Foundation
import GitHubKit

/// Sync frequency by how recently a PR was updated. Any activity bumps `updatedAt`, which moves
/// the PR into the hot search on the next poll, so slower tiers only delay changes that do not
/// touch the PR itself (CI status, the base branch moving).
public enum Tier: Int, Codable, Sendable, CaseIterable, Comparable {
    case hot, warm, cold

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct TierPolicy: Codable, Sendable, Hashable {
    public var hotDays = 30
    public var warmDays = 90
    /// Hot discovery runs every poll; the poll interval comes from Settings.
    public var warmDiscoveryInterval: TimeInterval = 5 * 60
    public var coldDiscoveryInterval: TimeInterval = 30 * 60
    public var hotDetailRefresh: TimeInterval = 10 * 60
    public var warmDetailRefresh: TimeInterval = 30 * 60
    public var coldDetailRefresh: TimeInterval = 2 * 60 * 60
    /// PRs per detail request. GitHub times out on large batches because merge state is computed lazily.
    public var detailBatchSize = 10
    /// Batches per cycle for new or changed PRs.
    public var maxChangedBatchesPerCycle = 10
    /// Batches per cycle for periodic refresh of unchanged PRs.
    public var maxRotationBatchesPerCycle = 2

    public init() {}

    public func discoveryInterval(_ tier: Tier, pollInterval: TimeInterval) -> TimeInterval {
        switch tier {
        case .hot: pollInterval
        case .warm: max(pollInterval, warmDiscoveryInterval)
        case .cold: max(pollInterval, coldDiscoveryInterval)
        }
    }

    public func detailRefresh(_ tier: Tier) -> TimeInterval {
        switch tier {
        case .hot: hotDetailRefresh
        case .warm: warmDetailRefresh
        case .cold: coldDetailRefresh
        }
    }

    /// Tier boundaries as UTC calendar days, matching the `updated:` search qualifiers.
    public func boundaries(now: Date) -> (hotStart: Date, warmStart: Date) {
        let calendar = Self.utc
        let today = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: -hotDays, to: today)!,
                calendar.date(byAdding: .day, value: -warmDays, to: today)!)
    }

    public func tier(updatedAt: Date, now: Date) -> Tier {
        let (hotStart, warmStart) = boundaries(now: now)
        if updatedAt >= hotStart { return .hot }
        if updatedAt >= warmStart { return .warm }
        return .cold
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

public enum SearchAlias: String, Codable, Sendable, CaseIterable {
    case authored, requested, reviewed
    /// All open PRs in repos the user chose to watch.
    case watched
}

public struct SearchKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var alias: SearchAlias
    public var tier: Tier

    public init(_ alias: SearchAlias, _ tier: Tier) {
        self.alias = alias
        self.tier = tier
    }

    public var description: String { "\(alias.rawValue).\(tier)" }
}

public struct SearchSpec: Sendable, Hashable {
    public var key: SearchKey
    public var query: String
    /// `updatedAt` values this search returns when the PR is still open and involves me.
    /// A record in this range that the search did not return has left this search.
    public var covers: Range<Date>

    public func covers(_ date: Date) -> Bool { covers.contains(date) }
}

public enum SearchCatalog {
    static let authored = "is:pr is:open author:@me archived:false"
    static let requested = "is:pr is:open review-requested:@me archived:false"
    static let reviewed = "is:pr is:open reviewed-by:@me -author:@me archived:false"

    /// Most `-repo:` exclusions per query. Verified working up to 40 (about 1,500 characters);
    /// hidden repos beyond the cap are still filtered locally before any detail fetch.
    static let maxExclusions = 30

    /// Review requests are always hot and have no date limit; authored and reviewed are split by tier.
    /// Most watched repos per query (`repo:` qualifiers are ORed by GitHub search).
    static let maxWatched = 30

    public static func specs(now: Date, policy: TierPolicy, excluding hidden: Set<String> = [], watching watched: Set<String> = []) -> [SearchSpec] {
        let exclusions = hidden.sorted().prefix(maxExclusions).map { " -repo:\($0)" }.joined()
        var specs = baseSpecs(now: now, policy: policy)
        let watchedRepos = watched.subtracting(hidden).sorted().prefix(maxWatched)
        if !watchedRepos.isEmpty {
            let repos = watchedRepos.map { " repo:\($0)" }.joined()
            let tiers = baseSpecs(now: now, policy: policy).filter { $0.key.alias == .authored }
            specs += tiers.map { tier in
                // Reuse the authored tier's date qualifier and coverage.
                let dates = tier.query.replacingOccurrences(of: authored, with: "")
                return SearchSpec(key: SearchKey(.watched, tier.key.tier), query: "is:pr is:open archived:false" + repos + dates, covers: tier.covers)
            }
        }
        return specs.map { spec in
            var spec = spec
            spec.query += exclusions
            return spec
        }
    }

    static func baseSpecs(now: Date, policy: TierPolicy) -> [SearchSpec] {
        let (hotStart, warmStart) = policy.boundaries(now: now)
        let warmEnd = TierPolicy.utc.date(byAdding: .day, value: -1, to: hotStart)!
        let all = Date.distantPast..<Date.distantFuture
        let hot = hotStart..<Date.distantFuture
        let warm = warmStart..<hotStart
        let cold = Date.distantPast..<warmStart
        let hotQ = "updated:>=\(day(hotStart))"
        let warmQ = "updated:\(day(warmStart))..\(day(warmEnd))"
        let coldQ = "updated:<\(day(warmStart))"
        return [
            SearchSpec(key: SearchKey(.requested, .hot), query: requested, covers: all),
            SearchSpec(key: SearchKey(.authored, .hot), query: "\(authored) \(hotQ)", covers: hot),
            SearchSpec(key: SearchKey(.reviewed, .hot), query: "\(reviewed) \(hotQ)", covers: hot),
            SearchSpec(key: SearchKey(.authored, .warm), query: "\(authored) \(warmQ)", covers: warm),
            SearchSpec(key: SearchKey(.reviewed, .warm), query: "\(reviewed) \(warmQ)", covers: warm),
            SearchSpec(key: SearchKey(.authored, .cold), query: "\(authored) \(coldQ)", covers: cold),
            SearchSpec(key: SearchKey(.reviewed, .cold), query: "\(reviewed) \(coldQ)", covers: cold),
        ]
    }

    static func day(_ date: Date) -> String {
        let parts = TierPolicy.utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
