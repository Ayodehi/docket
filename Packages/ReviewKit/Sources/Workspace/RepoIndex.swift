import Foundation

public struct LocalClone: Codable, Sendable, Hashable {
    public var path: String
    /// The remote whose URL points at the GitHub repo, usually `origin`.
    public var remote: String
    public var isWorktree: Bool
    public var modified: Date

    public init(path: String, remote: String, isWorktree: Bool, modified: Date) {
        self.path = path
        self.remote = remote
        self.isWorktree = isWorktree
        self.modified = modified
    }
}

/// Maps `owner/name` to local clones by scanning root folders (docs/local-workspace-integration.md 1.1).
public struct LocalRepoIndex: Codable, Sendable {
    public var clones: [String: [LocalClone]] = [:]
    public var scannedAt: Date?

    public init() {}

    static let skipped: Set<String> = ["node_modules", ".build", "DerivedData", "Pods", "vendor", ".review-worktrees"]

    /// Walks each root to `depth` levels looking for `.git`. Reads remotes from `.git/config`
    /// directly, which is much faster than running git per repo.
    public static func scan(roots: [URL], depth: Int = 3, now: Date = Date()) -> LocalRepoIndex {
        var index = LocalRepoIndex()
        let fm = FileManager.default
        func walk(_ dir: URL, _ level: Int) {
            let gitURL = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDir) {
                if let config = configURL(gitURL: gitURL, isDirectory: isDir.boolValue),
                   let text = try? String(contentsOf: config, encoding: .utf8) {
                    let modified = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? .distantPast
                    for (remote, url) in parseRemotes(text) {
                        guard let repo = RemoteURL.gitHubRepo(url) else { continue }
                        let clone = LocalClone(path: Safety.canonicalPath(dir.path), remote: remote, isWorktree: !isDir.boolValue, modified: modified)
                        if !index.clones[repo, default: []].contains(where: { $0.path == clone.path }) {
                            index.clones[repo, default: []].append(clone)
                        }
                    }
                }
                return
            }
            guard level < depth, let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || skipped.contains(name) { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                walk(child, level + 1)
            }
        }
        for root in roots { walk(root, 0) }
        index.scannedAt = now
        return index
    }

    /// Preferred clone: a main clone over a worktree, the `origin` remote first, then most recently modified.
    public func preferredClone(for repo: String) -> LocalClone? {
        clones[repo]?.sorted { a, b in
            if a.isWorktree != b.isWorktree { return !a.isWorktree }
            if (a.remote == "origin") != (b.remote == "origin") { return a.remote == "origin" }
            return a.modified > b.modified
        }.first
    }

    static func configURL(gitURL: URL, isDirectory: Bool) -> URL? {
        if isDirectory { return gitURL.appendingPathComponent("config") }
        // A worktree or submodule: `.git` is a file with `gitdir: <path>`; remotes live in the common dir.
        guard let text = try? String(contentsOf: gitURL, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        var gitDir = URL(fileURLWithPath: raw, relativeTo: gitURL.deletingLastPathComponent()).standardizedFileURL
        if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
            gitDir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir).standardizedFileURL
        }
        return gitDir.appendingPathComponent("config")
    }

    /// `[remote "name"]` sections and their `url` values.
    static func parseRemotes(_ config: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var current: String?
        for rawLine in config.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                if line.hasPrefix("[remote \""), let end = line.lastIndex(of: "\"") {
                    let start = line.index(line.startIndex, offsetBy: "[remote \"".count)
                    if start < end { current = String(line[start..<end]) }
                }
            } else if let remote = current, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" {
                    result.append((remote, parts[1].trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return result
    }
}
