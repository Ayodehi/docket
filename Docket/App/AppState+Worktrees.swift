import AppKit
import Foundation
import ReviewCore
import Workspace

/// One linked worktree of any clone Docket knows, with what it belongs to and whether removing
/// it is safe.
struct WorktreeRow: Identifiable, Hashable {
    enum Status: Int, Comparable {
        case clean, changes, commitsOnNoBranch, locked, missing

        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .clean: "Clean"
            case .changes: "Uncommitted changes"
            case .commitsOnNoBranch: "Commits on no branch"
            case .locked: "Locked"
            case .missing: "Folder missing"
            }
        }
    }

    var path: String
    var repo: String
    var clonePath: String
    var branch: String?
    var head: String
    var status: Status
    var modified: Date?
    var createdByDocket: Bool
    /// The open PR this worktree belongs to, if any.
    var prID: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// Clean and not tied to an open PR: what bulk cleanup removes.
    var isCleanupCandidate: Bool { status == .clean && prID == nil }
}

extension AppState {
    /// Lists linked worktrees of every main clone in the repo index and the repo folder overrides.
    func scanWorktrees() async {
        guard let workspace = gitWorkspace, !isScanningWorktrees else { return }
        isScanningWorktrees = true
        defer { isScanningWorktrees = false }

        // One entry per main clone; a clone with several GitHub remotes is listed once.
        var clones: [String: String] = [:] // clone path -> repo
        for (repo, entries) in repoIndex.clones {
            for clone in entries where !clone.isWorktree {
                if clones[clone.path] == nil || clone.remote == "origin" { clones[clone.path] = repo }
            }
        }
        for (repo, path) in workspaceSettings.overrides { clones[Safety.canonicalPath(path)] = repo }

        let recorded = Dictionary(reviewWorktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let open = snapshots
        let rows = await withTaskGroup(of: [WorktreeRow].self) { group in
            for (clonePath, repo) in clones {
                group.addTask {
                    guard let linked = try? await workspace.worktrees(of: clonePath) else { return [] }
                    var rows: [WorktreeRow] = []
                    for tree in linked {
                        let path = Safety.canonicalPath(tree.path)
                        let docket = recorded[path]
                        let status: WorktreeRow.Status
                        if tree.isPrunable || !FileManager.default.fileExists(atPath: path) {
                            status = .missing
                        } else if tree.isLocked {
                            status = .locked
                        } else if (try? await workspace.isDirty(path)) != false {
                            status = .changes
                        } else if tree.branch == nil, docket == nil, !(await workspace.isReachable(tree.head, in: clonePath)) {
                            status = .commitsOnNoBranch
                        } else {
                            status = .clean
                        }
                        let pr = open.first { pr in
                            guard pr.repo.lowercased() == repo.lowercased() else { return false }
                            if let docket, docket.prID == pr.id { return true }
                            return (tree.branch != nil && tree.branch == pr.headRef) || (!tree.head.isEmpty && tree.head == pr.headSha)
                        }
                        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                        rows.append(WorktreeRow(path: path, repo: repo, clonePath: clonePath, branch: tree.branch, head: tree.head,
                                                status: status, modified: modified, createdByDocket: docket != nil, prID: pr?.id))
                    }
                    return rows
                }
            }
            var all: [WorktreeRow] = []
            for await rows in group { all += rows }
            return all
        }
        worktreeRows = rows.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        Log.workspace.notice("Worktrees: \(rows.count) across \(clones.count) clones, \(rows.filter(\.isCleanupCandidate).count) removable")
    }

    /// Removes worktrees with `git worktree remove` (never `--force`) and keeps their branches.
    /// Git refuses ones with local changes; those are reported and left in place.
    func removeWorktrees(_ rows: [WorktreeRow]) {
        guard let workspace = gitWorkspace else { return show(WorkspaceError.toolMissing(.git)) }
        Task {
            var failures: [String] = []
            var removed = 0
            for row in rows {
                guard row.status != .missing, row.status != .locked else { continue }
                do {
                    try await workspace.removeWorktree(at: row.path, clone: row.clonePath)
                    reviewWorktrees.removeAll { $0.path == row.path }
                    removed += 1
                } catch {
                    failures.append("\(row.name): \(error)")
                }
            }
            for clone in Set(rows.filter { $0.status == .missing }.map(\.clonePath)) {
                try? await workspace.pruneWorktrees(of: clone)
            }
            saveWorktreeRecords()
            Log.workspace.notice("Removed \(removed) worktrees, \(failures.count) kept")
            localInfoVersion += 1
            await scanWorktrees()
            if !failures.isEmpty {
                show(title: "Some worktrees were kept", message: "Git did not remove them, usually because of local changes:\n" + failures.joined(separator: "\n"))
            }
        }
    }

    func openWorktreeInTerminal(_ row: WorktreeRow) {
        Task { do { try await launcher.openTerminal(at: row.path) } catch { show(error) } }
    }

    func openWorktreeInEditor(_ row: WorktreeRow) {
        Task { do { try await launcher.openEditor(at: row.path) } catch { show(error) } }
    }

    func revealWorktree(_ row: WorktreeRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
    }
}
