import GitHubKit
import ReviewCore
import SwiftUI
import Sync
import Workspace

struct SettingsView: View {
    @Environment(\.appState) private var app
    @State private var tab = "account"

    var body: some View {
        TabView(selection: $tab) {
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag("account")
            InboxSettingsView()
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag("inbox")
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag("notifications")
            WorkspaceSettingsView()
                .tabItem { Label("Workspace", systemImage: "folder") }
                .tag("workspace")
            ClaudeSettingsView()
                .tabItem { Label("Claude", systemImage: "sparkles") }
                .tag("claude")
            RunSettingsView()
                .tabItem { Label("Run", systemImage: "play.circle") }
                .tag("run")
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
        }
        .onAppear { if app.runSettingsRepo != nil { tab = "run" } }
        .onChange(of: app.runSettingsRepo) { if app.runSettingsRepo != nil { tab = "run" } }
    }
}

private struct AccountSettingsView: View {
    @Environment(\.appState) private var app
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch app.session {
            case .loading:
                ProgressView()
            case .signedOut:
                SignInView()
            case .signedIn(let login, let scopes):
                LabeledContent("Signed in as", value: login)
                LabeledContent("Token access") {
                    Text(scopes.map { $0.isEmpty ? "No scopes" : $0.joined(separator: ", ") } ?? "Fine-grained or not reported")
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    @Bindable var app = app
                    Toggle("Allow Docket to change reviews on GitHub", isOn: $app.reviewActionsEnabled)
                    Text("Adds Request Reviewers, Re-request, and Dismiss to the Reviewers panel. Each change is confirmed first and runs as you on GitHub. A fine-grained token needs Pull requests: write; a classic token with repo already allows it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                ReviewClaimSettingsView()
                Divider()
                Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("Sign out of GitHub?", isPresented: $confirmSignOut) {
                        Button("Sign Out", role: .destructive) { app.signOut() }
                    } message: {
                        Text("This removes the token from the Keychain and clears cached pull requests.")
                    }
            case .needsReauth(let login):
                Label("GitHub rejected the token for \(login). Enter a new one.", systemImage: "exclamationmark.triangle")
                SignInView()
            case .ssoRequired(let login, let url):
                Label("An organization requires SAML SSO authorization for \(login)'s token.", systemImage: "lock.shield")
                if let url { Link("Authorize the token on GitHub", destination: url) }
                Button("Retry") { app.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .frame(width: 560, height: 600)
    }
}

/// Assign me and label the PR when a review session starts (docs/design/review-claim.md).
private struct ReviewClaimSettingsView: View {
    @Environment(\.appState) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            Text("When Claude starts a review of someone else's PR").font(.headline)
            Toggle("Assign me to the PR", isOn: $app.reviewClaimSettings.assignMe)
            LabeledContent("Add label") {
                TextField("None", text: $app.reviewClaimSettings.label, prompt: Text("For example, In Review"))
                    .frame(maxWidth: 220)
            }
            Toggle("Remove the label when my review is posted", isOn: $app.reviewClaimSettings.removeLabelWhenPosted)
                .disabled(app.reviewClaimSettings.labelName == nil)
            if !app.reviewClaimSettings.label.trimmingCharacters(in: .whitespaces).isEmpty && app.reviewClaimSettings.labelName == nil {
                Label("Label names are up to \(ReviewLabel.maxLength) characters on one line.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Text("The label must already exist in the repository; Docket does not create labels. A label that was already on the PR is left alone. Changes run as you on GitHub; a fine-grained token needs Pull requests: write.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(\.appState) private var app
    @Environment(Updater.self) private var updater
    private let intervals: [TimeInterval] = [30, 60, 120, 300, 600, 900]

    var body: some View {
        @Bindable var app = app
        @Bindable var updater = updater
        Form {
            Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            Toggle("Hide the Dock icon when the main window is closed", isOn: $app.viewSettings.hideDockIconWhenClosed)
            Toggle("Show a red dot in the menu bar when CI fails on your PR", isOn: $app.showCIFailureDot)
            Toggle("Hide draft PRs", isOn: $app.viewSettings.hideDrafts)
            Picker("Quick switcher shortcut", selection: $app.viewSettings.switcherShortcut) {
                ForEach(SwitcherShortcut.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Check for changes every", selection: $app.pollInterval) {
                ForEach(intervals, id: \.self) { seconds in
                    Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")").tag(seconds)
                }
            }
            if updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                    LabeledContent("Docket \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")") {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }
            Section("Sync") {
                LabeledContent("Updated in the last 30 days", value: "\(app.tierCounts[.hot] ?? 0) PRs, every check")
                LabeledContent("30 to 90 days", value: "\(app.tierCounts[.warm] ?? 0) PRs, every 5 minutes")
                LabeledContent("Older", value: "\(app.tierCounts[.cold] ?? 0) PRs, every 30 minutes")
                if let rate = app.rateLimit {
                    LabeledContent("GitHub API points left", value: "\(rate.remaining) of \(rate.limit ?? 5000), resets \(rate.resetAt.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
        .formStyle(.grouped)
        // Grouped forms scroll and have no natural height, so size the tab explicitly.
        .frame(width: 560, height: 420)
    }
}

private struct InboxSettingsView: View {
    @Environment(\.appState) private var app
    private let ages = [30, 60, 90, 180, 365, 0]

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Include your PRs updated within", selection: $app.inboxMaxAgeDays) {
                    ForEach(ages, id: \.self) { days in
                        Text(days == 0 ? "Any time" : "\(days) days").tag(days)
                    }
                }
            } footer: {
                Text("Older PRs of yours stay in My PRs and repo views but leave the Inbox and the menu bar count. Review requests always count.")
                    .foregroundStyle(.secondary)
            }
            Section {
                StringListEditor(items: $app.ignoredChecks, placeholder: "Check name contains…", monospaced: true)
            } header: {
                Text("Ignored checks")
            } footer: {
                Text("Checks whose name contains any of these (ignoring case) do not count toward a PR's CI status. They still appear, dimmed, in PR details.")
                    .foregroundStyle(.secondary)
            }
            IgnoredPRsSection()
            WatchedReposSection()
            Section {
                if app.mutedRepos.isEmpty && app.hiddenRepos.isEmpty {
                    Text("Right-click a repo in the sidebar to mute or hide it.").foregroundStyle(.secondary)
                }
                ForEach(app.mutedRepos.sorted(), id: \.self) { repo in
                    LabeledContent {
                        Button("Unmute") { app.toggleMute(repo) }
                    } label: {
                        Label(repo, systemImage: "bell.slash")
                    }
                }
                ForEach(app.hiddenRepos.sorted(), id: \.self) { repo in
                    LabeledContent {
                        Button("Show Again") { app.setHidden(repo, false) }
                    } label: {
                        Label(repo, systemImage: "eye.slash")
                    }
                }
            } header: {
                Text("Muted and hidden repos")
            } footer: {
                Text("Muted repos still appear but never notify. Hidden repos are not shown and not synced, so they use no GitHub API points.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
    }

}

/// Editable list of strings with remove buttons and an add field.
struct StringListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    var monospaced = false
    @State private var draft = ""

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack {
                Text(item).font(monospaced ? .system(.body, design: .monospaced) : .body)
                Spacer()
                Button { items.removeAll { $0 == item } } label: { Label("Remove \(item)", systemImage: "minus.circle").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
        HStack {
            TextField(placeholder, text: $draft).onSubmit(add)
            Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}

private struct NotificationSettingsView: View {
    @Environment(\.appState) private var app
    private let soundChoices = NotificationSettings.soundNames + ["default", ""]

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                LabeledContent("Permission") {
                    HStack {
                        Text(statusText).foregroundStyle(app.notificationStatus == .denied ? Tone.warn.text : .secondary)
                        if app.notificationStatus == .denied || app.notificationStatus == .notDetermined {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                    }
                }
                if !app.notificationSoundsAllowed {
                    LabeledContent("Sounds") {
                        HStack {
                            Label("Off in System Settings", systemImage: "speaker.slash").foregroundStyle(Tone.warn.text)
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                    }
                    .help("Turn on Play sound for notification under Notifications > Docket. Docket cannot change this itself.")
                }
                Picker("Style", selection: $app.notificationSettings.style) {
                    ForEach(NotificationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Hide PR titles in notifications", isOn: $app.notificationSettings.hideTitles)
            } footer: {
                Text(styleHelp).foregroundStyle(.secondary)
            }
            Section("Events") {
                ForEach(EventKind.allCases, id: \.self) { kind in
                    HStack(spacing: 10) {
                        Toggle(kind.title, isOn: enabled(kind))
                        Spacer()
                        if app.notificationSettings.style == .smart {
                            Toggle("High urgency", isOn: high(kind))
                                .toggleStyle(.checkbox)
                                .help("High urgency events get their own banner under the Smart style")
                        }
                        Picker("Sound", selection: sound(kind)) {
                            ForEach(soundChoices, id: \.self) { name in
                                Text(name == "" ? "None" : name == "default" ? "System default" : name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Button("Test") { app.sendTestNotification(kind) }
                    }
                }
            }
            Section {
                StringListEditor(items: $app.notificationSettings.ignoredBots, placeholder: "Login, for example claude[bot]")
            } header: {
                Text("Ignored bots")
            } footer: {
                Text("Comments and reviews from these accounts never count as new comments or wait on your reply, and their activity does not notify unless they request your review directly. The [bot] suffix is optional.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 560)
        .task { await app.refreshNotificationStatus() }
    }

    private var statusText: String {
        switch app.notificationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Off in System Settings"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }

    private var styleHelp: String {
        switch app.notificationSettings.style {
        case .smart: "High urgency events get their own banner; the rest from the same sync are summarized in one."
        case .everyEvent: "One banner per PR with changes. Several changes on one PR are combined."
        case .summaryOnly: "One banner per sync with counts by type."
        }
    }

    private func enabled(_ kind: EventKind) -> Binding<Bool> {
        Binding(get: { app.notificationSettings.isEnabled(kind) }, set: { app.notificationSettings.enabled[kind] = $0 })
    }

    private func high(_ kind: EventKind) -> Binding<Bool> {
        Binding(get: { app.notificationSettings.isHighUrgency(kind) }, set: { app.notificationSettings.highUrgency[kind] = $0 })
    }

    private func sound(_ kind: EventKind) -> Binding<String> {
        Binding(get: { app.notificationSettings.sound(kind) }, set: { app.notificationSettings.sounds[kind] = $0 })
    }
}

private struct WorkspaceSettingsView: View {
    @Environment(\.appState) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var overrideRepo = ""
    @State private var confirmCleanup = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                ForEach(app.workspaceSettings.roots, id: \.self) { root in
                    HStack {
                        Text((root as NSString).abbreviatingWithTildeInPath).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { app.workspaceSettings.roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…") {
                        if let path = choose(directory: true) { app.workspaceSettings.roots.append(path) }
                    }
                    Button(app.isScanningRepos ? "Scanning…" : "Rescan") { Task { await app.rescanRepos() } }
                        .disabled(app.isScanningRepos)
                    Spacer()
                    Text("\(app.repoIndex.clones.count) GitHub repos found").foregroundStyle(.secondary)
                }
            } header: {
                Text("Folders to scan for clones")
            } footer: {
                Text("Docket looks three levels deep for git repos and matches their GitHub remotes.").foregroundStyle(.secondary)
            }
            Section("Repo locations") {
                ForEach(app.workspaceSettings.overrides.keys.sorted(), id: \.self) { repo in
                    LabeledContent(repo) {
                        HStack {
                            Text((app.workspaceSettings.overrides[repo]! as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                            Button { app.workspaceSettings.overrides[repo] = nil } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Picker("Repo", selection: $overrideRepo) {
                        Text("Choose a repo").tag("")
                        ForEach(app.repos.map(\.name), id: \.self) { repo in
                            Text(repo + (app.clone(for: repo) == nil ? " (not found)" : "")).tag(repo)
                        }
                    }
                    Button("Set Folder…") {
                        if let path = choose(directory: true) { app.workspaceSettings.overrides[overrideRepo] = path }
                    }
                    .disabled(overrideRepo.isEmpty)
                }
            }
            Section("Review worktrees") {
                LabeledContent("Folder") {
                    HStack {
                        Text((app.workspaceSettings.worktreesFolder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                        Button("Change…") { if let path = choose(directory: true) { app.workspaceSettings.worktreesFolder = path } }
                    }
                }
                LabeledContent("\(app.reviewWorktrees.count) created, \(app.staleWorktrees.count) for closed PRs") {
                    HStack {
                        Button("Clean Up…") { confirmCleanup = true }.disabled(app.staleWorktrees.isEmpty)
                        Button("Manage Worktrees…") { openWindow(id: "worktrees") }
                    }
                }
                .confirmationDialog("Remove \(app.staleWorktrees.count) worktrees for closed PRs?", isPresented: $confirmCleanup) {
                    Button("Remove", role: .destructive) { app.cleanUpWorktrees(app.staleWorktrees) }
                } message: {
                    Text(app.staleWorktrees.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ") + "\n\nWorktrees with uncommitted changes are kept.")
                }
            }
            Section("Apps") {
                Picker("Terminal", selection: $app.workspaceSettings.terminal) {
                    ForEach(TerminalChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if app.workspaceSettings.terminal == .custom {
                    TextField("Command (use {path} and {command})", text: $app.workspaceSettings.customTerminal)
                        .font(.system(.body, design: .monospaced))
                }
                Picker("Editor", selection: $app.workspaceSettings.editor) {
                    ForEach(EditorChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if app.workspaceSettings.editor == .custom {
                    TextField("Command (use {path})", text: $app.workspaceSettings.customEditor)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Section("Command-line tools") {
                ForEach(Tool.allCases, id: \.self) { tool in
                    LabeledContent(tool.rawValue) {
                        HStack {
                            if let url = app.tools[tool] {
                                Text((url.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                            } else {
                                Label("Not found", systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.text)
                            }
                            Button("Locate…") {
                                if let path = choose(directory: false) {
                                    app.workspaceSettings.toolPaths[tool] = path
                                    Task { await app.locateTools() }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 560)
        .onChange(of: app.workspaceSettings.roots) { Task { await app.rescanRepos() } }
    }

    private func choose(directory: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url.map { Safety.canonicalPath($0.path) } : nil
    }
}

private struct ClaudeSettingsView: View {
    @Environment(\.appState) private var app
    @State private var kind: PromptKind = .review

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Open Claude in", selection: $app.workspaceSettings.claudeApp) {
                    ForEach(ClaudeApp.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("The Claude button's menu can use the other one for a single launch. Only the terminal session gets Docket's safeguards: review-only flags, the pinned permission mode, and isolation from others' checkouts. The desktop app is opened with just a folder and a prompt, so Docket puts the review instructions in the prompt and warns before opening a review or someone else's PR there.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Where Claude works by default", selection: $app.workspaceSettings.notCheckedOut) {
                    ForEach(WorkspaceSettings.NotCheckedOut.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Isolate Claude when reviewing others' PRs", isOn: $app.workspaceSettings.isolateOthersPRs)
            } footer: {
                Text("Used by the Claude button when the PR is not already in a worktree or checked out. The button's menu can pick a worktree or the main clone for one task, or open a session with no task. Your own PRs get a worktree on their branch so you can push; others' PRs get one at the PR's latest commit. Isolation starts Claude without that checkout's .claude settings, hooks, and .mcp.json servers (your own MCP servers, such as Slack, still load), and in plan mode except for reviews, which cannot edit files. The checkout's CLAUDE.md is still read, so treat its instructions with care.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Template", selection: $kind) {
                    ForEach(PromptKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextEditor(text: Binding(get: { app.workspaceSettings.template(kind) }, set: { app.workspaceSettings.templates[kind] = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                HStack {
                    Spacer()
                    Button("Restore Default") { app.workspaceSettings.templates[kind] = nil }
                        .disabled(app.workspaceSettings.templates[kind] == nil)
                }
            } header: {
                Text("Prompt templates")
            } footer: {
                Text("Placeholders: {number}, {repo}, {url}, {head_ref}, {base_ref}, {path}. PR titles, descriptions, and comments are never inserted; Claude reads them itself with gh, so text someone else wrote cannot steer the prompt.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 560)
    }
}

private struct WatchedReposSection: View {
    @Environment(\.appState) private var app
    @State private var draft = ""

    var body: some View {
        Section {
            ForEach(app.watchedRepos.sorted(), id: \.self) { repo in
                LabeledContent {
                    Button("Stop Watching") { app.setWatched(repo, false) }
                } label: {
                    Label(repo, systemImage: "binoculars")
                }
            }
            HStack {
                TextField("owner/name", text: $draft).onSubmit(add)
                Menu("Known Repos") {
                    ForEach(knownRepos, id: \.self) { repo in
                        Button(repo) { draft = repo }
                    }
                }
                .fixedSize()
                Button("Watch", action: add).disabled(!Safety.isSafeRepo(draft.trimmingCharacters(in: .whitespaces)))
            }
        } header: {
            Text("Watched repos")
        } footer: {
            Text("Shows every open PR in these repos, labeled Watching. They never notify unless they involve you. Busy repos add to sync cost.")
                .foregroundStyle(.secondary)
        }
    }

    private var knownRepos: [String] {
        Set(app.repos.map(\.name)).union(app.repoIndex.clones.keys).subtracting(app.watchedRepos).sorted()
    }

    private func add() {
        let repo = draft.trimmingCharacters(in: .whitespaces)
        guard Safety.isSafeRepo(repo) else { return }
        app.setWatched(repo, true)
        draft = ""
    }
}

private struct IgnoredPRsSection: View {
    @Environment(\.appState) private var app
    private let suggestions = ["[Snyk]", "[dependabot]", "author:dependabot[bot]", "author:renovate[bot]", "author:snyk-bot"]

    var body: some View {
        @Bindable var app = app
        Section {
            StringListEditor(items: $app.ignoredPRPatterns, placeholder: "Title text, or author:login")
            let missing = suggestions.filter { !app.ignoredPRPatterns.contains($0) }
            if !missing.isEmpty {
                HStack {
                    Text("Add:").foregroundStyle(.secondary)
                    ForEach(missing, id: \.self) { suggestion in
                        Button(suggestion) { app.ignoredPRPatterns.append(suggestion) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
        } header: {
            Text("Ignored PRs")
        } footer: {
            Text("Applies to every repo. Plain text matches anywhere in the title, ignoring case, so [Snyk] catches Snyk PRs opened under your account. author:login matches the PR author; a bot's [bot] suffix is optional. Ignored PRs are not fetched, shown, counted, or notified." + (app.ignoredPRCount > 0 ? " Currently ignoring \(app.ignoredPRCount)." : ""))
                .foregroundStyle(.secondary)
        }
    }
}
