import Foundation

/// Fuzzy matching for the quick switcher. Every query character must appear in order;
/// matches at word starts and runs of consecutive characters score higher.
public enum FuzzyMatch {
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var score = 0
        var qi = 0
        var previous = -2
        for (ti, char) in t.enumerated() where qi < q.count && char == q[qi] {
            var points = 1
            if ti == previous + 1 { points += 5 }
            if ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber) { points += 8 }
            score += points
            previous = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter texts for equal matches.
        return score * 100 - min(t.count, 99)
    }

    /// Best score across a PR's searchable fields. A query that is a PR number (with or without
    /// `#`) and matches exactly ranks first.
    public static func score(_ query: String, pr: PRSnapshot) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if let number = Int(digits), number == pr.number { return 1_000_000 }
        return [pr.title, pr.repoName, "#\(pr.number)", pr.headRef, pr.author, "\(pr.repoName) \(pr.title)"]
            .compactMap { score(query, in: $0) }
            .max()
    }
}
