import Foundation

/// In-window search: free text plus `repo:`, `author:`, `state:`, and `label:` tokens.
/// Values match as case-insensitive substrings. Repeating a key matches any of its values;
/// a leading `-` excludes (`-repo:docs`). `author:me` matches my own PRs.
public struct SearchQuery: Sendable, Equatable {
    public enum Key: String, Sendable, CaseIterable {
        case repo, author, state, label
    }

    public struct Filter: Sendable, Equatable {
        public var key: Key
        public var value: String
        public var negated: Bool
    }

    public var filters: [Filter] = []
    public var terms: [String] = []

    public init(_ text: String) {
        for raw in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let negated = raw.hasPrefix("-") && raw.count > 1
            let body = negated ? String(raw.dropFirst()) : raw
            if let colon = body.firstIndex(of: ":"), let key = Key(rawValue: body[..<colon].lowercased()) {
                let value = body[body.index(after: colon)...].lowercased()
                if !value.isEmpty { filters.append(Filter(key: key, value: value, negated: negated)) }
                // A bare `repo:` while typing filters nothing.
            } else {
                terms.append(raw.lowercased())
            }
        }
    }

    public var isEmpty: Bool { filters.isEmpty && terms.isEmpty }

    public func matches(_ pr: PRSnapshot) -> Bool {
        for key in Key.allCases {
            let positive = filters.filter { $0.key == key && !$0.negated }
            if !positive.isEmpty && !positive.contains(where: { Self.test($0, pr) }) { return false }
            if filters.contains(where: { $0.key == key && $0.negated && Self.test($0, pr) }) { return false }
        }
        let haystack = "\(pr.title) \(pr.repo) #\(pr.number) \(pr.headRef) \(pr.author)".lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }

    static func test(_ filter: Filter, _ pr: PRSnapshot) -> Bool {
        switch filter.key {
        case .repo:
            return pr.repo.lowercased().contains(filter.value)
        case .author:
            if filter.value == "me" || filter.value == "@me" { return pr.isMine }
            return pr.author.lowercased().contains(filter.value)
        case .state:
            return pr.primary.token.contains(filter.value) || pr.primary.title.lowercased().contains(filter.value)
        case .label:
            return pr.labels.contains { $0.lowercased().contains(filter.value) }
        }
    }
}
