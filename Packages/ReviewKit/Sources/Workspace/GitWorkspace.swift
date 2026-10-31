import Foundation

public struct CloneState: Sendable, Equatable {
    public var branch: String
    public var isDirty: Bool
    /// Paths of linked worktrees.
    public var worktrees: [String]
}

public enum WorkspaceError: Error, Sendable, Equatable, CustomStringConvertible {
    case toolMissing(Tool)
    case unsafeValue(String)
    case dirty(path: String, branch: String)
    case branchCheckedOutElsewhere(String)
    case foreignWorktree(String)
    case failed(String)

    public var description: String {
        switch self {
        case .toolMissing(let tool): "\(tool.rawValue) was not found. Set its location in Settings > Workspace."
        case .unsafeValue(let what): "Refused an unsafe \(what)."
        case .dirty(let path, let branch): "\((path as NSString).lastPathComponent) has uncommitted changes on \(branch)."
        case .branchCheckedOutElsewhere(let branch): "\(branch) is already checked out in another worktree."
        case .foreignWorktree(let path): "\((path as NSString).abbreviatingWithTildeInPath) already exists and belongs to a different repository. Docket did not touch it."
        case .failed(let message): message
        }
    }
}

/// A worktree Docket created, recorded so cleanup only touches these.
public struct ReviewWorktree: Codable, Sendable, Hashable {
    public var prID: String
    public var repo: String
    public var number: Int
    public var clonePath: String
    public var path: String
    public var createdAt: Date

    public init(prID: String, repo: String, number: Int, clonePath: String, path: String, createdAt: Date) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.clonePath = clonePath
        self.path = path
        self.createdAt = createdAt
    }
}

/// One linked worktree of a clone, from `git worktree list --porcelain`. The main working tree
/// is never included.
public struct LinkedWorktree: Sendable, Hashable, Identifiable {
    public var path: String
    public var head: String
    /// `nil` when detached.
    public var branch: String?
    public var isLocked: Bool
    /// Git reports the folder missing; `git worktree prune` would drop the entry.
    public var isPrunable: Bool

    public var id: String { path }

    public init(path: String, head: String, branch: String?, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    /// Parses porcelain output. The first record is the main working tree and is skipped.
    public static func parse(porcelain: String) -> [LinkedWorktree] {
        let records = porcelain.components(separatedBy: "\n\n").map { $0.split(separator: "\n").map(String.init) }.filter { !$0.isEmpty }
        return records.dropFirst().compactMap { lines in
            guard let pathLine = lines.first(where: { $0.hasPrefix("worktree ") }), !lines.contains("bare") else { return nil }
            let value = { (key: String) in lines.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) } }
            let branch = value("branch").map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            return LinkedWorktree(path: String(pathLine.dropFirst("worktree ".count)), head: value("HEAD") ?? "",
                                  branch: branch,
                                  isLocked: lines.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                                  isPrunable: lines.contains { $0 == "prunable" || $0.hasPrefix("prunable ") })
        }
    }
}

/// Git operations for one clone. Every call is `git -C <path> ...` with an argument array.
/// Never stashes, resets, force-pushes, deletes branches, or removes worktrees with `--force`.
public struct GitWorkspace: Sendable {
    public let git: URL
    public let gh: URL?
    public let runner: ProcessRunner

    public init(git: URL, gh: URL?, runner: ProcessRunner) {
        self.git = git
        self.gh = gh
        self.runner = runner
    }

    public func state(of path: String) async throws -> CloneState {
        let branch = try await runner.check(git, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 15)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try await runner.check(git, ["-C", path, "status", "--porcelain=v1"], timeout: 30)
        let list = try await runner.check(git, ["-C", path, "worktree", "list", "--porcelain"], timeout: 15)
        let own = Safety.canonicalPath(path)
        let worktrees = list.split(separator: "\n").filter { $0.hasPrefix("worktree ") }
            .map { Safety.canonicalPath(String($0.dropFirst("worktree ".count))) }
            .filter { $0 != own }
        return CloneState(branch: branch == "HEAD" ? "(detached)" : branch, isDirty: !status.isEmpty, worktrees: worktrees)
    }

    /// Checks out a PR in the main clone. Refuses when the tree is dirty.
    public func checkout(number: Int, repo: String, clone: LocalClone) async throws {
        guard Safety.isSafeRepo(repo), number > 0 else { throw WorkspaceError.unsafeValue("repository") }
        let current = try await state(of: clone.path)
        if current.isDirty { throw WorkspaceError.dirty(path: clone.path, branch: current.branch) }
        if let gh {
            try await runner.check(gh, ["pr", "checkout", String(number), "--repo", repo], in: URL(fileURLWithPath: clone.path), timeout: 120)
        } else {
            try await runner.check(git, ["-C", clone.path, "fetch", clone.remote, "pull/\(number)/head:pr/\(number)"], timeout: 120)
            try await runner.check(git, ["-C", clone.path, "switch", "pr/\(number)"], timeout: 30)
        }
    }

    /// Creates or refreshes a worktree for a PR.
    /// - `branch`: check out this branch (my own PRs, so I can push). `nil`: detached at the PR head (reviews).
    public func ensureWorktree(number: Int, branch: String?, clone: LocalClone, at directory: URL) async throws {
        let path = directory.path
        if let branch, !Safety.isSafeBranchName(branch) { throw WorkspaceError.unsafeValue("branch name") }
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
        if !exists && FileManager.default.fileExists(atPath: path) {
            // Something else is in the way; never write into it.
            throw WorkspaceError.foreignWorktree(path)
        }
        if exists {
            // Only reuse a worktree of this clone. Fetching this PR into another repo's checkout
            // would put the wrong code in front of the reviewer.
            guard try await commonGitDir(path) == commonGitDir(clone.path) else { throw WorkspaceError.foreignWorktree(path) }
            // Reuse. Move to the new head only when clean; never discard local work.
            guard try await !state(of: path).isDirty else { return }
            if let branch {
                _ = try? await runner.run(git, ["-C", path, "pull", "--ff-only", clone.remote, branch], timeout: 120)
            } else {
                try await runner.check(git, ["-C", path, "fetch", clone.remote, "pull/\(number)/head"], timeout: 120)
                try await runner.check(git, ["-C", path, "checkout", "--detach", "FETCH_HEAD"], timeout: 60)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let branch {
            try await runner.check(git, ["-C", clone.path, "fetch", clone.remote, branch], timeout: 120)
            let hasLocal = try await runner.run(git, ["-C", clone.path, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], timeout: 15).succeeded
            let result = hasLocal
                ? try await runner.run(git, ["-C", clone.path, "worktree", "add", path, branch], timeout: 120)
                : try await runner.run(git, ["-C", clone.path, "worktree", "add", "--track", "-b", branch, path, "\(clone.remote)/\(branch)"], timeout: 120)
            if !result.succeeded {
                if result.stderr.contains("already checked out") || result.stderr.contains("already used by worktree") {
                    throw WorkspaceError.branchCheckedOutElsewhere(branch)
                }
                throw ProcessError(tool: "git", result: result)
            }
        } else {
            try await runner.check(git, ["-C", clone.path, "fetch", clone.remote, "pull/\(number)/head"], timeout: 120)
            try await runner.check(git, ["-C", clone.path, "worktree", "add", "--detach", path, "FETCH_HEAD"], timeout: 120)
        }
    }

    /// The shared `.git` directory of a clone or any of its worktrees.
    func commonGitDir(_ path: String) async throws -> String {
        let dir = try await runner.check(git, ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 15)
        return Safety.canonicalPath(dir.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes a worktree without `--force`; fails (and keeps it) when it has local changes.
    public func removeWorktree(_ worktree: ReviewWorktree) async throws {
        try await removeWorktree(at: worktree.path, clone: worktree.clonePath)
    }

    /// Removes any linked worktree of `clone` without `--force`. Git refuses when it has local
    /// changes or is locked, and the folder is kept. The branch is never deleted.
    public func removeWorktree(at path: String, clone: String) async throws {
        try await runner.check(git, ["-C", clone, "worktree", "remove", path], timeout: 60)
    }

    /// Linked worktrees of a clone, main working tree excluded.
    public func worktrees(of clone: String) async throws -> [LinkedWorktree] {
        LinkedWorktree.parse(porcelain: try await runner.check(git, ["-C", clone, "worktree", "list", "--porcelain"], timeout: 15))
    }

    /// Drops records of worktrees whose folders are gone. Touches no files that exist.
    public func pruneWorktrees(of clone: String) async throws {
        try await runner.check(git, ["-C", clone, "worktree", "prune"], timeout: 30)
    }

    /// True when `commit` is on some branch, remote-tracking branch, or tag of `clone`. A detached
    /// worktree whose HEAD is not would lose those commits if removed.
    public func isReachable(_ commit: String, in clone: String) async -> Bool {
        guard (7...64).contains(commit.count), commit.allSatisfy(\.isHexDigit) else { return false }
        let result = try? await runner.run(git, ["-C", clone, "for-each-ref", "--contains", commit, "--count=1", "--format=%(refname)",
                                                  "refs/heads", "refs/remotes", "refs/tags"], timeout: 30)
        return result?.succeeded == true && !(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// True when the worktree has uncommitted or untracked changes.
    public func isDirty(_ path: String) async throws -> Bool {
        try await !runner.check(git, ["-C", path, "status", "--porcelain=v1"], timeout: 30).isEmpty
    }

    /// Folder for a PR's review worktree: `<owner>-<name>-pr-<number>`. The owner is included so
    /// same-named repos from different owners (a fork and its upstream) never share a folder.
    public static func worktreeDirectory(root: URL, repo: String, number: Int) -> URL {
        let name = repo.replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent("\(name)-pr-\(number)", isDirectory: true)
    }
}
