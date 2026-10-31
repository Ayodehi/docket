import Foundation

public enum RemoteURL {
    /// `owner/name` for a github.com remote, or nil. Handles `git@github.com:o/n(.git)`,
    /// `https://github.com/o/n(.git)`, and `ssh://git@github.com/o/n(.git)`.
    public static func gitHubRepo(_ remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespaces)
        var path: Substring
        if trimmed.hasPrefix("git@github.com:") {
            path = trimmed.dropFirst("git@github.com:".count)
        } else if let url = URL(string: trimmed), let host = url.host()?.lowercased(),
                  host == "github.com" || host == "www.github.com", ["https", "http", "ssh", "git"].contains(url.scheme ?? "") {
            path = Substring(url.path())
        } else {
            return nil
        }
        path = path.drop { $0 == "/" }
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let repo = String(path)
        return Safety.isSafeRepo(repo) ? repo : nil
    }
}
