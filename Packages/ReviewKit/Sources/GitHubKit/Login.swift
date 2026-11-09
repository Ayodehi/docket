import Foundation

/// Login comparison. GitHub's GraphQL API reports a bot as `claude` while REST, the web UI, and
/// most people write `claude[bot]`, so user-entered lists must match either spelling.
public enum Login {
    /// Lowercased, trimmed, without a trailing `[bot]`.
    public static func key(_ login: String) -> String {
        var key = login.trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasSuffix("[bot]") { key.removeLast("[bot]".count) }
        return key
    }

    public static func keys<S: Sequence<String>>(_ logins: S) -> Set<String> {
        Set(logins.map(key).filter { !$0.isEmpty })
    }
}
