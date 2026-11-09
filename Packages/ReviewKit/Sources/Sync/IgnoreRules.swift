import Foundation
import GitHubKit

/// User rules for PRs to leave out everywhere (Settings > Inbox > Ignored PRs).
/// Plain text matches the title (case-insensitive contains), so `[Snyk]` catches Snyk's PRs even
/// when they are opened under my account. `author:<login>` matches the author exactly, with or
/// without a bot's `[bot]` suffix.
public struct IgnoreRules: Codable, Sendable, Equatable {
    public var patterns: [String]

    public init(_ patterns: [String] = []) {
        self.patterns = patterns
    }

    public var isEmpty: Bool { patterns.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    public func matches(title: String?, author: String?) -> Bool {
        let title = title?.lowercased() ?? ""
        let author = author.map(Login.key) ?? ""
        return patterns.contains { raw in
            let pattern = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !pattern.isEmpty else { return false }
            if pattern.hasPrefix("author:") {
                let login = pattern.dropFirst("author:".count).trimmingCharacters(in: .whitespaces)
                return !login.isEmpty && author == Login.key(login)
            }
            return title.contains(pattern)
        }
    }

    public func matches(_ summary: PRSummary) -> Bool {
        matches(title: summary.title, author: summary.author)
    }
}
