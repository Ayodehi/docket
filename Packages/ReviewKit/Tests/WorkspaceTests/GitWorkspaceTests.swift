import Foundation
import Testing
@testable import Workspace

/// Runs against real temporary git repositories. Needs /usr/bin/git.
@Suite(.serialized) struct GitWorkspaceTests {
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let runner = ProcessRunner()

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DocketGit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: Safety.canonicalPath(url.path), isDirectory: true)
    }

    private func sh(_ args: [String], in dir: URL? = nil) async throws {
        try await runner.check(git, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args, in: dir)
    }

    /// An "origin" with a PR ref, and a clone of it whose remote points at github.com for the index.
    private func fixture() async throws -> (root: URL, origin: URL, clone: URL) {
        let root = try temp()
        let origin = root.appendingPathComponent("origin")
        try await sh(["init", origin.path])
        try "one\n".write(to: origin.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await sh(["-C", origin.path, "add", "."])
        try await sh(["-C", origin.path, "commit", "-m", "one"])
        try await sh(["-C", origin.path, "checkout", "-b", "mchen/feature"])
        try "two\n".write(to: origin.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await sh(["-C", origin.path, "commit", "-am", "two"])
        try await sh(["-C", origin.path, "update-ref", "refs/pull/7/head", "mchen/feature"])
        try await sh(["-C", origin.path, "checkout", "main"])
        let clone = root.appendingPathComponent("projects/web-console")
        try await sh(["clone", origin.path, clone.path])
        return (root, origin, clone)
    }

    @Test func indexFindsClonesByGitHubRemote() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await sh(["-C", clone.path, "remote", "add", "upstream", "git@github.com:example-org/web-console.git"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/node_modules/x/.git"), withIntermediateDirectories: true)
        let index = LocalRepoIndex.scan(roots: [root.appendingPathComponent("projects")])
        #expect(index.clones.keys.sorted() == ["example-org/web-console"])
        let preferred = try #require(index.preferredClone(for: "example-org/web-console"))
        #expect(preferred.path == clone.path)
        #expect(preferred.remote == "upstream")
    }

    @Test func stateAndDirtyCheckout() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        var state = try await workspace.state(of: clone.path)
        #expect(state == CloneState(branch: "main", isDirty: false, worktrees: []))

        try "local edit\n".write(to: clone.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        state = try await workspace.state(of: clone.path)
        #expect(state.isDirty)
        let local = LocalClone(path: clone.path, remote: "origin", isWorktree: false, modified: Date())
        await #expect(throws: WorkspaceError.dirty(path: clone.path, branch: "main")) {
            try await workspace.checkout(number: 7, repo: "example-org/web-console", clone: local)
        }
        // The local edit is untouched.
        #expect(try String(contentsOf: clone.appendingPathComponent("file.txt"), encoding: .utf8) == "local edit\n")
    }

    @Test func checkoutWithGitFallback() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        try await workspace.checkout(number: 7, repo: "example-org/web-console", clone: LocalClone(path: clone.path, remote: "origin", isWorktree: false, modified: Date()))
        #expect(try await workspace.state(of: clone.path).branch == "pr/7")
    }

    @Test func detachedReviewWorktreeCreateReuseAndRemove() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        let local = LocalClone(path: clone.path, remote: "origin", isWorktree: false, modified: Date())
        let dir = GitWorkspace.worktreeDirectory(root: root.appendingPathComponent(".review-worktrees"), repo: "example-org/web-console", number: 7)
        #expect(dir.lastPathComponent == "example-org-web-console-pr-7")

        try await workspace.ensureWorktree(number: 7, branch: nil, clone: local, at: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("file.txt"), encoding: .utf8) == "two\n")
        #expect(try await workspace.state(of: dir.path).branch == "(detached)")
        #expect(try await workspace.state(of: clone.path).worktrees == [dir.path])
        // The main clone stays on its branch.
        #expect(try await workspace.state(of: clone.path).branch == "main")

        // Reuse is a no-op success.
        try await workspace.ensureWorktree(number: 7, branch: nil, clone: local, at: dir)

        // Removal refuses when the worktree has local changes, and keeps them.
        try "review notes\n".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let record = ReviewWorktree(prID: "PR_7", repo: "example-org/web-console", number: 7, clonePath: clone.path, path: dir.path, createdAt: Date())
        await #expect(throws: ProcessError.self) { try await workspace.removeWorktree(record) }
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try await sh(["-C", dir.path, "checkout", "--", "file.txt"])
        try await workspace.removeWorktree(record)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func listsWorktreesAndFlagsCommitsOnNoBranch() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        let side = root.appendingPathComponent("side")
        try await sh(["-C", clone.path, "worktree", "add", "--detach", side.path, "HEAD"])
        var list = try await workspace.worktrees(of: clone.path)
        #expect(list.map(\.path) == [side.path] && list[0].branch == nil)
        #expect(try await !workspace.isDirty(side.path))
        #expect(await workspace.isReachable(list[0].head, in: clone.path))

        // A commit made in the detached worktree is on no branch: removing it would lose the commit.
        try "local\n".write(to: side.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await sh(["-C", side.path, "commit", "-am", "local only"])
        list = try await workspace.worktrees(of: clone.path)
        #expect(await !workspace.isReachable(list[0].head, in: clone.path))
        #expect(await !workspace.isReachable("not-a-sha", in: clone.path))

        // A folder deleted by hand is reported prunable, and prune drops it.
        try FileManager.default.removeItem(at: side)
        #expect(try await workspace.worktrees(of: clone.path).first?.isPrunable == true)
        try await workspace.pruneWorktrees(of: clone.path)
        #expect(try await workspace.worktrees(of: clone.path).isEmpty)
    }

    /// Two different repos must never share a worktree folder, and an existing folder from
    /// another repo is never reused.
    @Test func foreignWorktreeIsRefused() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("projects/other-web-console")
        try await sh(["init", other.path])
        try "x\n".write(to: other.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try await sh(["-C", other.path, "add", "."])
        try await sh(["-C", other.path, "commit", "-m", "x"])
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        let shared = root.appendingPathComponent("wt/shared")
        try await sh(["-C", other.path, "worktree", "add", "--detach", shared.path])

        let local = LocalClone(path: clone.path, remote: "origin", isWorktree: false, modified: Date())
        await #expect(throws: WorkspaceError.foreignWorktree(shared.path)) {
            try await workspace.ensureWorktree(number: 7, branch: nil, clone: local, at: shared)
        }
        // A plain folder in the way is also refused.
        let plain = root.appendingPathComponent("wt/plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await #expect(throws: WorkspaceError.foreignWorktree(plain.path)) {
            try await workspace.ensureWorktree(number: 7, branch: nil, clone: local, at: plain)
        }
        #expect(GitWorkspace.worktreeDirectory(root: root, repo: "org-a/web", number: 1) != GitWorkspace.worktreeDirectory(root: root, repo: "org-b/web", number: 1))
    }

    @Test func branchWorktreeForMyOwnPR() async throws {
        let (root, _, clone) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        let local = LocalClone(path: clone.path, remote: "origin", isWorktree: false, modified: Date())
        let dir = root.appendingPathComponent("wt/web-console-pr-7")
        try await workspace.ensureWorktree(number: 7, branch: "mchen/feature", clone: local, at: dir)
        #expect(try await workspace.state(of: dir.path).branch == "mchen/feature")

        // The same branch cannot be checked out in a second worktree.
        await #expect(throws: WorkspaceError.branchCheckedOutElsewhere("mchen/feature")) {
            try await workspace.ensureWorktree(number: 7, branch: "mchen/feature", clone: local, at: root.appendingPathComponent("wt/other"))
        }
        await #expect(throws: WorkspaceError.unsafeValue("branch name")) {
            try await workspace.ensureWorktree(number: 7, branch: "x; rm -rf ~", clone: local, at: root.appendingPathComponent("wt/bad"))
        }
    }
}
