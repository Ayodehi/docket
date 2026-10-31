import Foundation

/// Rules for values that reach commands or Claude prompts. PR titles, bodies, comments, and labels
/// never do. Anything else is validated or quoted here (docs/security-and-privacy.md section 4).
public enum Safety {
    /// A branch name that passes `git check-ref-format --branch` rules and a conservative allowlist.
    /// Fork authors control branch names, so anything unusual is rejected rather than escaped.
    public static func isSafeBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        if name.hasPrefix("-") || name.hasPrefix("/") || name.hasSuffix("/") || name.hasSuffix(".") || name.hasSuffix(".lock") { return false }
        if name.contains("..") || name.contains("//") || name.contains("@{") { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }

    /// `owner/name` as GitHub allows it.
    public static func isSafeRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".." && !part.hasPrefix("-") && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    public static func isGitHubPRURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == "github.com"
    }

    /// Single-quotes a value for a POSIX shell: `'` becomes `'\''`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The real path with symlinks resolved, as git reports it (`/private/var/...`, not `/var/...`).
    /// Foundation's `resolvingSymlinksInPath` strips `/private`, so use realpath(3).
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Escapes a value for an AppleScript string literal.
    public static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
