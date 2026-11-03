import GitHubKit
import ReviewCore
import SwiftUI
import Workspace

struct PRDetailView: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot
    @State private var requestingReviewers = false
    @State private var dismissing: ReviewerState?
    @State private var reRequesting: ReviewerState?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                HStack(alignment: .top, spacing: 12) {
                    checksPanel
                    reviewersPanel
                }
                if let stack = app.stacks[pr.id] {
                    StackPanel(pr: pr, stack: stack)
                }
                LocalPanel(pr: pr)
                if !pr.labels.isEmpty {
                    Panel(title: "Labels") {
                        Text(pr.labels.joined(separator: ", ")).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hardTopScrollEdge()
        .sheet(isPresented: $requestingReviewers) { RequestReviewersSheet(pr: pr) }
        .sheet(isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } })) {
            if let dismissing { DismissReviewSheet(pr: pr, reviewer: dismissing) }
        }
        .confirmationDialog(reRequesting.map { "Re-request a review from \($0.name)?" } ?? "",
                            isPresented: Binding(get: { reRequesting != nil }, set: { if !$0 { reRequesting = nil } }),
                            presenting: reRequesting) { reviewer in
            Button("Re-request Review") { reRequest(reviewer) }
        } message: { _ in
            Text("GitHub asks them to review \(pr.repo) #\(pr.number) again and notifies them.")
        }
        .alert("Review action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func reRequest(_ reviewer: ReviewerState) {
        guard let userID = reviewer.userID else { return }
        Task {
            do {
                try await app.perform(try ReviewAction.makeRerequest(pullRequestID: pr.id, userIDs: [userID]), on: pr)
            } catch let error as ReviewInputError {
                actionError = error.message
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(pr.repo) #\(pr.number) · \(pr.isMine ? "your PR" : "opened by \(pr.author)") · \(Age.short(since: pr.createdAt)) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(pr.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text("\(pr.headRef) → \(pr.baseRef) · +\(pr.additions) −\(pr.deletions) · \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Chip(state: pr.primary)
                Chip(ci: pr.ci, short: false)
                Chip(text: pr.merge.title, symbol: "arrow.triangle.merge", tone: pr.merge.tone)
                if pr.isCrossRepository { Chip(text: "From a fork", symbol: "arrow.triangle.branch", tone: .off) }
            }
        }
    }

    private var actions: some View {
        let kind = PromptKind.forState(pr)
        return HStack(spacing: 8) {
            Menu {
                Section("Wherever it is checked out") {
                    ForEach(PromptKind.allCases, id: \.self) { other in
                        Button(other.actionTitle) { app.startClaude(pr, kind: other) }
                    }
                }
                Divider()
                ClaudeLocationMenu(pr: pr, location: .worktree, title: "In a Worktree", symbol: "arrow.triangle.branch")
                ClaudeLocationMenu(pr: pr, location: .mainClone, title: "In the Main Clone (Switch Branch)", symbol: "folder")
                Divider()
                ClaudeAppMenu(pr: pr, claudeApp: app.workspaceSettings.claudeApp.other)
            } label: {
                Label(kind.actionTitle, systemImage: "sparkles")
            } primaryAction: {
                app.startClaude(pr, kind: kind)
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("Starts Claude Code with the \(kind.title.lowercased()) prompt in this PR's worktree or clone. The menu picks the task and where Claude works, opens a session with no task, or uses the other Claude app.")
            Button { app.makeWorktree(pr) } label: { Label("Worktree", systemImage: "arrow.triangle.branch") }
                .help("Create or update a review worktree for this PR")
            RunMenu(pr: pr)
            Menu {
                Button("Conversation") { app.openOnGitHub(pr) }
                Button("Checks") { app.openOnGitHub(pr, path: "checks") }
                Button("Files Changed") { app.openOnGitHub(pr, path: "files") }
            } label: {
                Label("GitHub", systemImage: "arrow.up.right.square")
            } primaryAction: {
                app.openOnGitHub(pr)
            }
            .fixedSize()
            Menu {
                SnoozeMenuItems(pr: pr)
            } label: {
                Label(app.snoozed.contains(pr.id) ? "Snoozed" : "Snooze", systemImage: app.snoozed.contains(pr.id) ? "moon.fill" : "moon")
            }
            .fixedSize()
            Menu {
                Button("Branch Name") { app.copy(pr.headRef) }
                Button("PR URL") { app.copy(pr.url.absoluteString) }
                Button("gh pr checkout Command") { app.copy("gh pr checkout \(pr.number) --repo \(pr.repo)") }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .fixedSize()
        }
        .controlSize(.regular)
    }

    private var checksPanel: some View {
        let counted = pr.checks.filter { !$0.isIgnored }
        let passed = counted.filter { $0.state == .passing }.count
        return Panel(title: "Checks", trailing: counted.isEmpty ? "" : "\(passed) of \(counted.count) passed") {
            if pr.checks.isEmpty {
                PanelRow { Text("No checks configured").foregroundStyle(.secondary) }
            }
            ForEach(Array(pr.checks.enumerated()), id: \.offset) { _, check in
                PanelRow {
                    Image(systemName: check.state.symbol).foregroundStyle(check.state.tone.text).frame(width: 14)
                    if let url = check.url {
                        Link(check.name, destination: url).foregroundStyle(.primary)
                    } else {
                        Text(check.name)
                    }
                    Spacer()
                    if check.isIgnored {
                        Text("ignored").foregroundStyle(.secondary)
                    }
                    Text(check.duration.map(Self.duration) ?? (check.state == .running ? "running" : ""))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .opacity(check.isIgnored ? 0.55 : 1)
                .help(check.isIgnored ? "Ignored in Settings > Inbox; not counted in the CI status" : "")
            }
        }
    }

    private var reviewersPanel: some View {
        Panel(title: "Reviewers", trailing: "\(pr.unresolvedThreads) unresolved") {
            if pr.reviewers.isEmpty {
                PanelRow { Text("None requested").foregroundStyle(.secondary) }
            }
            ForEach(pr.reviewers, id: \.name) { reviewer in
                PanelRow {
                    Image(systemName: reviewer.isTeam ? "person.2" : reviewer.verdict.symbol)
                        .foregroundStyle(reviewer.verdict.tone.text)
                        .frame(width: 14)
                    Text(reviewer.name)
                    Spacer()
                    Text(reviewer.verdict.title + (reviewer.at.map { " \(Age.short(since: $0))" } ?? ""))
                        .foregroundStyle(.secondary)
                    if app.reviewActionsEnabled && (reviewer.canBeReRequested || reviewer.canBeDismissed) {
                        Menu {
                            reviewerActions(reviewer)
                        } label: {
                            Label("Review actions for \(reviewer.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Re-request or dismiss this review")
                    }
                }
                .contextMenu {
                    if app.reviewActionsEnabled { reviewerActions(reviewer) }
                }
            }
            if app.reviewActionsEnabled {
                PanelRow {
                    Button { requestingReviewers = true } label: { Label("Request Reviewers…", systemImage: "person.badge.plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private func reviewerActions(_ reviewer: ReviewerState) -> some View {
        if reviewer.canBeReRequested {
            Button("Re-request Review…") { reRequesting = reviewer }
        }
        if reviewer.canBeDismissed {
            Button(reviewer.opinion == .approved ? "Dismiss Approval…" : "Dismiss Change Request…") { dismissing = reviewer }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 60 ? "\(total / 60)m \(String(format: "%02d", total % 60))s" : "\(total)s"
    }
}

/// One place Claude can work, with every task plus an empty session.
private struct ClaudeLocationMenu: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot
    let location: WorkLocation
    let title: String
    let symbol: String

    var body: some View {
        Menu {
            Button("Open Claude Session") { app.startClaude(pr, task: .session, location: location) }
            Divider()
            ForEach(PromptKind.allCases, id: \.self) { kind in
                Button(kind.actionTitle) { app.startClaude(pr, task: .prompt(kind), location: location) }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// Every task, plus an empty session, in the Claude app that is not the default.
private struct ClaudeAppMenu: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot
    let claudeApp: ClaudeApp

    var body: some View {
        Menu {
            Button("Open Claude Session") { app.startClaude(pr, task: .session, location: .automatic, in: claudeApp) }
            Divider()
            ForEach(PromptKind.allCases, id: \.self) { kind in
                Button(kind.actionTitle) { app.startClaude(pr, kind: kind, in: claudeApp) }
            }
        } label: {
            Label(claudeApp == .desktop ? "In Claude Desktop" : "In Terminal", systemImage: claudeApp == .desktop ? "macwindow" : "terminal")
        }
    }
}

/// Bordered panel with a small uppercase header, as in the mockups.
struct Panel<Content: View>: View {
    let title: String
    var trailing = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                Spacer()
                Text(trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5))
            Divider()
            content
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct PanelRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
        }
    }
}

/// Local clone status and workspace actions.
private struct LocalPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let pr: PRSnapshot
    @State private var info: LocalInfo?

    var body: some View {
        Panel(title: "Local", trailing: info?.state.map { $0.isDirty ? "uncommitted changes" : "clean" } ?? "") {
            if let info {
                if let clone = info.clone {
                    PanelRow {
                        Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 14)
                        Text(abbreviated(clone.path)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let state = info.state {
                            Text("on \(state.branch)").foregroundStyle(.secondary).lineLimit(1)
                        }
                        Menu {
                            Button("Choose Folder…") { chooseFolder() }
                            if app.workspaceSettings.overrides[pr.repo] != nil {
                                Button("Use the Folder Docket Found") { app.setRepoLocation(pr.repo, nil) }
                            }
                        } label: {
                            Label("Repo folder", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(app.workspaceSettings.overrides[pr.repo] == nil
                              ? "Docket found this clone by scanning. Choose a different folder for \(pr.repo)."
                              : "You chose this folder for \(pr.repo).")
                    }
                    if let worktree = info.worktree {
                        PanelRow {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(Tone.accent.text).frame(width: 14)
                            Text(abbreviated(worktree.path)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("review worktree").foregroundStyle(.secondary)
                        }
                    }
                    if let error = info.error {
                        PanelRow { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.text) }
                    }
                    PanelRow {
                        Button("Terminal") { app.openTerminal(pr) }
                        Button("Editor") { app.openEditor(pr) }
                        Button("Check Out") { app.checkOut(pr) }
                            .help("Switch the main clone to this PR. Refuses if it has uncommitted changes.")
                        if app.runSettings(for: pr.repo).profiles.isEmpty {
                            Button("Set Up Run…") {
                                app.runSettingsRepo = pr.repo
                                openSettings()
                            }
                            .help("Add a command that starts this repo's checkout, such as devspace dev")
                        }
                        Spacer()
                        Button("Worktrees…") { openWindow(id: "worktrees") }
                            .help("Every worktree of your clones, with cleanup")
                    }
                } else {
                    PanelRow {
                        Text("No local clone of \(pr.repo) found.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Folder…") { chooseFolder() }
                        SettingsLink { Text("Settings…") }
                    }
                }
            } else {
                PanelRow { ProgressView().controlSize(.small); Spacer() }
            }
        }
        .task(id: "\(pr.id)-\(pr.headSha)-\(app.localInfoVersion)-\(app.repoIndex.scannedAt?.timeIntervalSince1970 ?? 0)") {
            info = await app.localInfo(for: pr)
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your clone of \(pr.repo). Docket uses it as the main clone for this repo."
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { app.setRepoLocation(pr.repo, url.path) }
    }
}

extension View {
    /// On macOS 26 and later, content scrolling under the toolbar gets a soft blurred, tinted edge.
    /// In the detail pane that read as a color band over the header; a hard edge is a plain divider.
    @ViewBuilder func hardTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

/// The PR's stack, parent first, with each member's state. Clicking a member selects it.
private struct StackPanel: View {
    @Environment(AppState.self) private var app
    let pr: PRSnapshot
    let stack: StackPosition

    var body: some View {
        let parent = stack.parentID.flatMap(app.snapshot(id:))
        Panel(title: "Stack", trailing: parent.map { "based on #\($0.number)" } ?? "\(stack.memberIDs.count) PRs") {
            ForEach(stack.memberIDs, id: \.self) { id in
                if let member = app.snapshot(id: id) {
                    let depth = app.stacks[id]?.depth ?? 0
                    PanelRow {
                        Image(systemName: id == pr.id ? "arrowtriangle.right.fill" : (depth == 0 ? "square.stack.3d.up" : "arrow.turn.down.right"))
                            .foregroundStyle(id == pr.id ? Tone.accent.text : .secondary)
                            .frame(width: 14)
                        Text("#\(member.number)").monospacedDigit().foregroundStyle(.secondary)
                        Text(member.title).lineLimit(1).fontWeight(id == pr.id ? .semibold : .regular)
                        Spacer()
                        Chip(state: member.primary)
                    }
                    .padding(.leading, CGFloat(StackIndent.level(depth)) * 12)
                    .contentShape(Rectangle())
                    .onTapGesture { app.browser.selection = id }
                }
            }
            if let parent, pr.primary == .readyToMerge {
                PanelRow {
                    Label("Merge #\(parent.number) first; this PR is based on its branch.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warn.text)
                }
            }
        }
    }
}

/// Starts or stops the repo's run profiles. Hidden until the repo has one.
struct RunMenu: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    let pr: PRSnapshot

    var body: some View {
        let settings = app.runSettings(for: pr.repo)
        if let primary = settings.defaultProfile {
            Menu {
                Section("Run") {
                    ForEach(settings.profiles) { profile in
                        Button(profile.lockedContext.map { "\(profile.name) on \($0)" } ?? profile.name) { app.startRun(pr, profile: profile) }
                    }
                }
                let stoppable = settings.profiles.filter(\.hasStop)
                if !stoppable.isEmpty {
                    Section("Stop") {
                        ForEach(stoppable) { profile in
                            Button("Stop \(profile.name)") { app.stopRun(pr, profile: profile) }
                        }
                    }
                }
                Divider()
                Button("Edit Run Profiles…") {
                    app.runSettingsRepo = pr.repo
                    openSettings()
                }
            } label: {
                Label("Run", systemImage: "play")
            } primaryAction: {
                app.startRun(pr, profile: primary)
            }
            .fixedSize()
            .help("Runs \"\(primary.name)\" in a terminal, in this PR's worktree or clone\(primary.lockedContext.map { ", locked to the Kubernetes context \($0)" } ?? ""). The menu picks another profile or runs a stop command.")
        }
    }
}
