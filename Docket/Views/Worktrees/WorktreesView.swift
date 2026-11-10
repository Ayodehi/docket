import ReviewCore
import SwiftUI

/// Every worktree of the clones Docket knows, with cleanup. Removal uses `git worktree remove`
/// without `--force`, so git keeps anything with local changes, and branches are never deleted.
struct WorktreesView: View {
    enum Filter: String, CaseIterable {
        case all = "All", noOpenPR = "No open PR", changes = "Has changes"
    }

    @Environment(\.appState) private var app
    @State private var filter: Filter = .all
    @State private var selection = Set<WorktreeRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\WorktreeRow.sortModified, order: .reverse)]
    @State private var pendingRemoval: [WorktreeRow] = []

    private var rows: [WorktreeRow] {
        let filtered = app.worktreeRows.filter { row in
            switch filter {
            case .all: true
            case .noOpenPR: row.prID == nil
            case .changes: row.status == .changes || row.status == .commitsOnNoBranch
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    private var candidates: [WorktreeRow] { app.worktreeRows.filter(\.isCleanupCandidate) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Folder", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Text((row.path as NSString).deletingLastPathComponent.abbreviatedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(row.path)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Repo", value: \.repo) { row in
                Text(row.repo.split(separator: "/").last.map(String.init) ?? row.repo).lineLimit(1).help(row.repo)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Branch", value: \.sortBranch) { row in
                Text(row.branch ?? "detached at \(row.head.prefix(7))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(row.branch == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("PR") { row in
                if let pr = app.snapshot(id: row.prID) {
                    HStack(spacing: 6) {
                        Text("#\(pr.number)").monospacedDigit()
                        Chip(state: pr.primary)
                    }
                } else {
                    Text("No open PR").foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 190)
            TableColumn("Status", value: \.status) { row in
                Label(row.status.title, systemImage: row.status.symbol)
                    .foregroundStyle(row.status.tone.text)
                    .lineLimit(1)
                    .help(row.status.explanation)
            }
            .width(min: 110, ideal: 160)
            TableColumn("Modified", value: \.sortModified) { row in
                Text(row.modified.map { Age.short(since: $0) + " ago" } ?? "").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Made by", value: \.madeBy) { row in
                Text(row.madeBy).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: WorktreeRow.ID.self) { ids in
            let chosen = app.worktreeRows.filter { ids.contains($0.id) }
            if chosen.count == 1, let row = chosen.first {
                Button("Open in Terminal") { app.openWorktreeInTerminal(row) }.disabled(row.status == .missing)
                Button("Open in Editor") { app.openWorktreeInEditor(row) }.disabled(row.status == .missing)
                Button("Show in Finder") { app.revealWorktree(row) }.disabled(row.status == .missing)
                if let pr = app.snapshot(id: row.prID) {
                    Divider()
                    Button("Show PR in Docket") { app.reveal(pr.id); app.openMainRequest += 1 }
                }
                Divider()
            }
            if !chosen.isEmpty {
                Button(chosen.count == 1 ? "Remove Worktree…" : "Remove \(chosen.count) Worktrees…", role: .destructive) { pendingRemoval = chosen }
                    .disabled(chosen.allSatisfy { $0.status == .locked })
            }
        } primaryAction: { ids in
            if ids.count == 1, let row = app.worktreeRows.first(where: { ids.contains($0.id) }), row.status != .missing {
                app.openWorktreeInTerminal(row)
            }
        }
        .overlay {
            if app.worktreeRows.isEmpty {
                if app.isScanningWorktrees {
                    ProgressView("Looking for worktrees…")
                } else {
                    ContentUnavailableView("No worktrees", systemImage: "arrow.triangle.branch",
                                           description: Text("None of your clones has linked worktrees."))
                }
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle("Worktrees")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { Task { await app.scanWorktrees() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(app.isScanningWorktrees)
                    .help("Look for worktrees again (Command-R)")
            }
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })) {
            Button(pendingRemoval.count == 1 ? "Remove Worktree" : "Remove \(pendingRemoval.count) Worktrees", role: .destructive) {
                app.removeWorktrees(pendingRemoval)
                selection.subtract(pendingRemoval.map(\.id))
                pendingRemoval = []
            }
        } message: {
            Text(removalMessage)
        }
        .frame(minWidth: 820, minHeight: 360)
        .task { await app.scanWorktrees() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(summary).foregroundStyle(.secondary)
            Spacer()
            Button("Remove \(candidates.count) Clean Without an Open PR…") { pendingRemoval = candidates }
                .disabled(candidates.isEmpty || app.isScanningWorktrees)
                .help("Removes clean worktrees that no open PR uses. Their branches are kept.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var summary: String {
        let all = app.worktreeRows
        let changes = all.filter { $0.status == .changes || $0.status == .commitsOnNoBranch }.count
        let noPR = all.filter { $0.prID == nil }.count
        return "\(all.count) worktrees · \(noPR) without an open PR · \(changes) with work not on a branch or uncommitted"
    }

    private var removalTitle: String {
        pendingRemoval.count == 1 ? "Remove \(pendingRemoval[0].name)?" : "Remove \(pendingRemoval.count) worktrees?"
    }

    private var removalMessage: String {
        var lines = ["Each folder is deleted with git worktree remove. Branches are kept, and git refuses any worktree with uncommitted changes."]
        let risky = pendingRemoval.filter { $0.status == .commitsOnNoBranch }
        if !risky.isEmpty {
            lines.append("\(risky.count) \(risky.count == 1 ? "has commits" : "have commits") that are on no branch. Removing \(risky.count == 1 ? "it" : "them") loses those commits: \(risky.map(\.name).joined(separator: ", ")).")
        }
        let open = pendingRemoval.filter { $0.prID != nil }
        if !open.isEmpty {
            lines.append("\(open.count) \(open.count == 1 ? "belongs" : "belong") to an open PR.")
        }
        let names = pendingRemoval.prefix(12).map(\.name).joined(separator: "\n")
        lines.append(names + (pendingRemoval.count > 12 ? "\nand \(pendingRemoval.count - 12) more" : ""))
        return lines.joined(separator: "\n\n")
    }
}

extension WorktreeRow {
    var sortModified: Date { modified ?? .distantPast }
    var sortBranch: String { branch ?? "" }
    var madeBy: String { createdByDocket ? "Docket" : "Other" }
}

extension WorktreeRow.Status {
    var symbol: String {
        switch self {
        case .clean: "checkmark.circle"
        case .changes: "pencil.circle"
        case .commitsOnNoBranch: "exclamationmark.triangle"
        case .locked: "lock"
        case .missing: "questionmark.folder"
        }
    }

    var tone: Tone {
        switch self {
        case .clean: .ok
        case .changes, .commitsOnNoBranch: .warn
        case .locked, .missing: .off
        }
    }

    var explanation: String {
        switch self {
        case .clean: "No uncommitted changes. Removing it keeps its branch."
        case .changes: "Has uncommitted or untracked files. Git will not remove it."
        case .commitsOnNoBranch: "Detached with commits that are on no branch. Removing it loses those commits."
        case .locked: "Locked with git worktree lock. Docket leaves it alone."
        case .missing: "The folder is gone. Removing it drops git's record of it (git worktree prune)."
        }
    }
}

private extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
