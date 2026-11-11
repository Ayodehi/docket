import AppKit
import Foundation
import GitHubKit
import ReviewCore
import SwiftUI
import Workspace

/// Settings > Workspace and Settings > Claude.
struct WorkspaceSettings: Codable, Equatable {
    init() {}

    /// Missing keys (settings saved by an earlier version) fall back to defaults.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkspaceSettings()
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? d.roots
        overrides = try c.decodeIfPresent([String: String].self, forKey: .overrides) ?? d.overrides
        worktreesFolder = try c.decodeIfPresent(String.self, forKey: .worktreesFolder) ?? d.worktreesFolder
        terminal = try c.decodeIfPresent(TerminalChoice.self, forKey: .terminal) ?? d.terminal
        customTerminal = try c.decodeIfPresent(String.self, forKey: .customTerminal) ?? d.customTerminal
        editor = try c.decodeIfPresent(EditorChoice.self, forKey: .editor) ?? d.editor
        customEditor = try c.decodeIfPresent(String.self, forKey: .customEditor) ?? d.customEditor
        toolPaths = try c.decodeIfPresent([Tool: String].self, forKey: .toolPaths) ?? d.toolPaths
        notCheckedOut = try c.decodeIfPresent(NotCheckedOut.self, forKey: .notCheckedOut) ?? d.notCheckedOut
        isolateOthersPRs = try c.decodeIfPresent(Bool.self, forKey: .isolateOthersPRs) ?? d.isolateOthersPRs
        claudeApp = try c.decodeIfPresent(ClaudeApp.self, forKey: .claudeApp) ?? d.claudeApp
        templates = try c.decodeIfPresent([PromptKind: String].self, forKey: .templates) ?? d.templates
        runProfiles = try c.decodeIfPresent([String: RepoRunSettings].self, forKey: .runProfiles) ?? d.runProfiles
    }

    enum NotCheckedOut: String, Codable, CaseIterable {
        case worktree, ask, checkout

        var title: String {
            switch self {
            case .worktree: "A worktree"
            case .ask: "Ask each time"
            case .checkout: "The main clone (switch branch)"
            }
        }
    }

    var roots: [String] = WorkspaceSettings.defaultRoots()
    /// `owner/name` to a local path; wins over discovery.
    var overrides: [String: String] = [:]
    var worktreesFolder = (NSHomeDirectory() as NSString).appendingPathComponent("Projects/.review-worktrees")
    var terminal: TerminalChoice = .terminal
    var customTerminal = "/usr/bin/open -na Ghostty --args --working-directory={path} -e /bin/zsh -lc {command}"
    var editor: EditorChoice = .vsCode
    var customEditor = "/usr/bin/open -a Zed {path}"
    var toolPaths: [Tool: String] = [:]
    var notCheckedOut: NotCheckedOut = .worktree
    /// Start Claude without the repo's settings, hooks, and MCP servers, in plan mode, for others' PRs.
    var isolateOthersPRs = true
    /// Where the Claude button starts Claude; the button's menu can pick the other one per launch.
    var claudeApp: ClaudeApp = .terminal
    var templates: [PromptKind: String] = [:]
    /// `owner/name` to that repo's run profiles (Settings > Run).
    var runProfiles: [String: RepoRunSettings] = [:]

    func template(_ kind: PromptKind) -> String { templates[kind] ?? kind.defaultTemplate }

    static func defaultRoots() -> [String] {
        ["Projects", "Developer", "src"].map { (NSHomeDirectory() as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

/// What Claude starts with: a prompt from a template, or an empty session.
enum ClaudeTask: Equatable {
    case prompt(PromptKind)
    case session

    var logName: String {
        switch self {
        case .prompt(let kind): kind.rawValue
        case .session: "session"
        }
    }
}

/// Where Claude works. `automatic` reuses an existing worktree or checkout, then follows the setting.
enum WorkLocation: Equatable {
    case automatic, worktree, mainClone
}

/// Local clone status for the detail pane.
struct LocalInfo: Equatable {
    var clone: LocalClone?
    var state: CloneState?
    var worktree: ReviewWorktree?
    var error: String?
}

/// A dialog the main window shows for workspace choices and errors.
struct WorkspaceAlert: Identifiable {
    struct Action {
        var title: String
        var role: ButtonRole?
        var run: @MainActor () -> Void
    }

    let id = UUID()
    var title: String
    var message: String
    var actions: [Action] = []
}

private let indexFile = "repo-index.json"
private let worktreesFile = "worktrees.json"

extension AppState {
    // MARK: Setup

    func prepareWorkspace() {
        repoIndex = (try? files?.load(LocalRepoIndex.self, from: indexFile, decoder: GitHubJSON.decoder())) ?? LocalRepoIndex()
        reviewWorktrees = (try? files?.load([ReviewWorktree].self, from: worktreesFile, decoder: GitHubJSON.decoder())) ?? []
        removeStalePromptFiles()
        Task {
            await locateTools()
            await rescanRepos()
        }
    }

    func locateTools() async {
        tools = await ToolLocator.locate(overrides: workspaceSettings.toolPaths)
    }

    func rescanRepos() async {
        isScanningRepos = true
        let roots = workspaceSettings.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let index = await Task.detached(priority: .utility) { LocalRepoIndex.scan(roots: roots) }.value
        repoIndex = index
        isScanningRepos = false
        try? files?.save(index, as: indexFile, encoder: GitHubJSON.encoder())
    }

    var runner: ProcessRunner {
        ProcessRunner(extraPaths: tools.values.map { $0.deletingLastPathComponent().path })
    }

    var gitWorkspace: GitWorkspace? {
        tools[.git].map { GitWorkspace(git: $0, gh: tools[.gh], runner: runner) }
    }

    var launcher: Launcher {
        Launcher(terminal: workspaceSettings.terminal, customTerminal: workspaceSettings.customTerminal,
                 editor: workspaceSettings.editor, customEditor: workspaceSettings.customEditor, runner: runner)
    }

    // MARK: Lookup

    func clone(for repo: String) -> LocalClone? {
        if let path = workspaceSettings.overrides[repo] {
            return LocalClone(path: Safety.canonicalPath(path), remote: repoIndex.preferredClone(for: repo)?.remote ?? "origin", isWorktree: false, modified: .distantPast)
        }
        return repoIndex.preferredClone(for: repo)
    }

    /// Sets (or with `nil`, clears) the folder used as the main clone of `repo`. Refuses a folder
    /// that is not a git repository whose remotes include `repo` on GitHub.
    func setRepoLocation(_ repo: String, _ path: String?) {
        guard let path else {
            workspaceSettings.overrides[repo] = nil
            localInfoVersion += 1
            return
        }
        let canonical = Safety.canonicalPath(path)
        let found = LocalRepoIndex.scan(roots: [URL(fileURLWithPath: canonical, isDirectory: true)], depth: 0)
        guard let key = found.clones.keys.first(where: { $0.lowercased() == repo.lowercased() }), let clone = found.preferredClone(for: key) else {
            return show(title: "Not a clone of \(repo)",
                        message: "\((canonical as NSString).abbreviatingWithTildeInPath) is not a git repository with a GitHub remote for \(repo). Docket kept the current folder.")
        }
        workspaceSettings.overrides[repo] = clone.path
        Log.workspace.notice("Repo folder set for a repo")
        localInfoVersion += 1
    }

    func recordedWorktree(for pr: PRSnapshot) -> ReviewWorktree? {
        reviewWorktrees.first { $0.prID == pr.id && FileManager.default.fileExists(atPath: $0.path) }
    }

    func localInfo(for pr: PRSnapshot) async -> LocalInfo {
        guard let clone = clone(for: pr.repo) else { return LocalInfo() }
        guard let workspace = gitWorkspace else { return LocalInfo(clone: clone, error: WorkspaceError.toolMissing(.git).description) }
        do {
            return LocalInfo(clone: clone, state: try await workspace.state(of: clone.path), worktree: recordedWorktree(for: pr))
        } catch {
            return LocalInfo(clone: clone, error: String(describing: error))
        }
    }

    // MARK: Actions

    func openTerminal(_ pr: PRSnapshot) {
        guard let folder = recordedWorktree(for: pr)?.path ?? clone(for: pr.repo)?.path else { return showNoClone(pr) }
        Task { await perform { try await self.launcher.openTerminal(at: folder) } }
    }

    func openEditor(_ pr: PRSnapshot) {
        guard let folder = recordedWorktree(for: pr)?.path ?? clone(for: pr.repo)?.path else { return showNoClone(pr) }
        Task { await perform { try await self.launcher.openEditor(at: folder) } }
    }

    func checkOut(_ pr: PRSnapshot) {
        guard let clone = clone(for: pr.repo) else { return showNoClone(pr) }
        guard let workspace = gitWorkspace else { return show(WorkspaceError.toolMissing(.git)) }
        Task {
            do {
                try await workspace.checkout(number: pr.number, repo: pr.repo, clone: clone)
                localInfoVersion += 1
            } catch let error as WorkspaceError {
                if case .dirty = error {
                    workspaceAlert = WorkspaceAlert(
                        title: "Uncommitted changes",
                        message: "\(error.description) Review in a separate worktree instead?",
                        actions: [.init(title: "Use Worktree", role: nil) { self.makeWorktree(pr) },
                                  .init(title: "Cancel", role: .cancel) {}])
                } else {
                    show(error)
                }
            } catch {
                show(error)
            }
        }
    }

    func makeWorktree(_ pr: PRSnapshot, then: (@MainActor (String) -> Void)? = nil) {
        Task {
            do {
                let path = try await ensureWorktree(pr)
                localInfoVersion += 1
                then?(path)
            } catch {
                show(error)
            }
        }
    }

    /// Starts Claude Code in the right folder with a prompt picked from the PR state.
    func startClaude(_ pr: PRSnapshot, kind: PromptKind? = nil, in claudeApp: ClaudeApp? = nil) {
        startClaude(pr, task: .prompt(kind ?? PromptKind.forState(pr)), location: .automatic, in: claudeApp)
    }

    /// Starts Claude on `pr` with a task (or none) in the chosen place.
    func startClaude(_ pr: PRSnapshot, task: ClaudeTask, location: WorkLocation, in claudeApp: ClaudeApp? = nil) {
        let target = claudeApp ?? workspaceSettings.claudeApp
        guard target == .desktop || tools[.claude] != nil else {
            return show(title: "Claude Code not found",
                        message: "Docket could not find the claude command. Install Claude Code, or set its location in Settings > Workspace.")
        }
        withWorkFolder(pr, location: location, question: "Where should Claude work?") { self.launchClaude(pr, task: task, folder: $0, in: target) }
    }

    /// Finds or makes the folder to work on `pr` in, then calls `run` with it. `automatic` reuses the
    /// PR's review worktree, then the main clone if it is on the PR branch, then follows the setting.
    func withWorkFolder(_ pr: PRSnapshot, location: WorkLocation, question: String, then run: @escaping @MainActor (String) -> Void) {
        guard let clone = clone(for: pr.repo) else { return showNoClone(pr) }
        Task {
            switch location {
            case .worktree:
                return makeWorktree(pr, then: run)
            case .mainClone:
                if await isOnPRBranch(clone, pr) { return run(clone.path) }
                return checkOutThen(pr, clone: clone, run: run)
            case .automatic:
                break
            }
            // 1. An existing review worktree for this PR.
            if let worktree = recordedWorktree(for: pr) {
                if let path = try? await ensureWorktree(pr) { return run(path) }
                return run(worktree.path)
            }
            // 2. The main clone already on the PR branch.
            if await isOnPRBranch(clone, pr) { return run(clone.path) }
            // 3. Otherwise follow the setting.
            switch workspaceSettings.notCheckedOut {
            case .worktree:
                makeWorktree(pr, then: run)
            case .checkout:
                checkOutThen(pr, clone: clone, run: run)
            case .ask:
                workspaceAlert = WorkspaceAlert(
                    title: "\(pr.repoName) #\(pr.number) is not checked out",
                    message: question,
                    actions: [
                        .init(title: "Use Worktree", role: nil) { self.makeWorktree(pr, then: run) },
                        .init(title: "Check Out in Main Clone", role: nil) { self.checkOutThen(pr, clone: clone, run: run) },
                        .init(title: "Open on Current Branch", role: nil) { run(clone.path) },
                        .init(title: "Cancel", role: .cancel) {},
                    ])
                openMainRequest += 1
            }
        }
    }

    func isOnPRBranch(_ clone: LocalClone, _ pr: PRSnapshot) async -> Bool {
        guard let state = try? await gitWorkspace?.state(of: clone.path) else { return false }
        return state.branch == pr.headRef || state.branch == "pr/\(pr.number)"
    }

    private func checkOutThen(_ pr: PRSnapshot, clone: LocalClone, run: @escaping @MainActor (String) -> Void) {
        guard let workspace = gitWorkspace else { return show(WorkspaceError.toolMissing(.git)) }
        Task {
            do {
                try await workspace.checkout(number: pr.number, repo: pr.repo, clone: clone)
                localInfoVersion += 1
                run(clone.path)
            } catch let error as WorkspaceError {
                if case .dirty = error {
                    workspaceAlert = WorkspaceAlert(
                        title: "Uncommitted changes",
                        message: "\(error.description) Docket does not switch branches over local changes. Use a separate worktree instead?",
                        actions: [.init(title: "Use Worktree", role: nil) { self.makeWorktree(pr, then: run) },
                                  .init(title: "Cancel", role: .cancel) {}])
                    openMainRequest += 1
                } else {
                    show(error)
                }
            } catch {
                show(error)
            }
        }
    }

    private func launchClaude(_ pr: PRSnapshot, task: ClaudeTask, folder: String, in target: ClaudeApp) {
        if target == .desktop { return launchDesktop(pr, task: task, folder: folder) }
        guard let claude = tools[.claude] else { return }
        Task {
            var files: [URL] = []
            do {
                // Another person's PR: its checkout may contain .claude hooks, .mcp.json servers, commands,
                // or a CLAUDE.md written to steer Claude. Do not load them, require approval for actions,
                // and do not resolve slash commands the checkout could redefine.
                let isolate = workspaceSettings.isolateOthersPRs && !pr.isMine
                var notice: String?
                var promptFile: URL?
                var systemFile: URL?
                var flags: [String] = []
                var permissionMode: String?
                switch task {
                case .session:
                    if isolate {
                        flags = CommandBuilder.untrustedCheckoutFlags
                        permissionMode = "plan"
                    }
                case .prompt(let kind):
                    var template = workspaceSettings.template(kind)
                    if case .plainText(let reason) = PromptPolicy.choose(template: template, untrusted: !pr.isMine,
                                                                          customizations: ProjectCustomizations.find(in: folder)) {
                        template = kind.plainTextTemplate
                        notice = reason + " Docket started Claude with the plain review prompt instead."
                    }
                    promptFile = try writePromptFile(try PromptRenderer.render(template, pr: pr, path: folder))
                    files.append(promptFile!)
                    let isolation = kind == .review ? CommandBuilder.untrustedReviewFlags : CommandBuilder.untrustedCheckoutFlags
                    flags = (kind == .review ? CommandBuilder.reviewOnlyFlags : []) + (isolate ? isolation : [])
                    if kind == .review {
                        systemFile = try writePromptFile(CommandBuilder.reviewOnlyInstructions)
                        files.append(systemFile!)
                        permissionMode = "default"
                    } else if isolate {
                        permissionMode = "plan"
                    }
                }
                // The user's own MCP servers (Slack, for example) load; the checkout's are rejected by
                // name, or, when they cannot be listed safely, no MCP servers load at all.
                var rejectedServers: [String] = []
                if isolate {
                    if let names = ProjectMCPServers.names(in: folder) {
                        rejectedServers = names
                    } else {
                        flags += CommandBuilder.noMCPFlags
                        notice = [notice, "This PR's .mcp.json could not be read safely, so Docket started Claude without any MCP servers, including your own."]
                            .compactMap { $0 }.joined(separator: "\n\n")
                    }
                }
                if let settings = SessionSettings.json(permissionMode: permissionMode, review: task == .prompt(.review) ? .init(repo: pr.repo, number: pr.number) : nil,
                                                       rejectedProjectServers: rejectedServers) {
                    flags += CommandBuilder.settingsFlags(file: try writeSettingsFile(settings).path)
                }
                let command = CommandBuilder.claudeCommand(path: folder, promptFile: promptFile?.path, claude: claude.path, flags: flags,
                                                           systemPromptFile: systemFile?.path)
                guard command.utf8.count < CommandBuilder.maxTerminalLine else {
                    throw WorkspaceError.failed("The command to start Claude is too long for a terminal line (\(command.utf8.count) of \(CommandBuilder.maxTerminalLine) characters). Use a shorter worktree folder in Settings > Workspace.")
                }
                let outcome = try await launcher.runInTerminal(command, folder: folder)
                if outcome == .copiedCommand {
                    show(title: "Command copied", message: "Docket is not allowed to control your terminal. The command is on the clipboard; paste it in the terminal window to start Claude. You can allow Docket under System Settings > Privacy & Security > Automation.")
                }
                Log.workspace.notice("Started Claude (\(task.logName, privacy: .public))")
                if let notice { show(title: "Claude started with limits", message: notice) }
            } catch {
                files.forEach { try? FileManager.default.removeItem(at: $0) }
                show(error)
            }
        }
    }

    /// A Code session in the Claude desktop app. Its link takes only a folder and a prompt, so none of
    /// the terminal session's flags apply: review-only instructions go in the prompt instead, and
    /// reviews or isolated PRs get a warning first listing what the session will not have.
    private func launchDesktop(_ pr: PRSnapshot, task: ClaudeTask, folder: String, warned: Bool = false) {
        let isolate = workspaceSettings.isolateOthersPRs && !pr.isMine
        let review = task == .prompt(.review)
        if (isolate || review) && !warned {
            var missing = ["The review instructions are part of the prompt instead of the system prompt.",
                           "The permission mode is whatever the desktop app uses, not pinned to default, and the auto mode rules for posting a confirmed review are not added."]
            if isolate {
                missing.append("This checkout's .claude settings, hooks, and .mcp.json servers are not blocked. The PR author wrote them, and its hooks run when the session starts.")
            }
            workspaceAlert = WorkspaceAlert(
                title: "Claude desktop cannot apply Docket's safeguards",
                message: "Docket opens a desktop session with only a folder and a prompt, so this session will run without them:\n\n"
                    + missing.map { "- " + $0 }.joined(separator: "\n") + "\n\nThe terminal session applies all of them.",
                actions: [
                    .init(title: "Open in Claude Desktop", role: .destructive) { self.launchDesktop(pr, task: task, folder: folder, warned: true) },
                    .init(title: "Use Terminal", role: nil) { self.launchClaude(pr, task: task, folder: folder, in: .terminal) },
                    .init(title: "Cancel", role: .cancel) {},
                ])
            openMainRequest += 1
            return
        }
        do {
            var prompt: String?
            if case .prompt(let kind) = task {
                var template = workspaceSettings.template(kind)
                if case .plainText = PromptPolicy.choose(template: template, untrusted: !pr.isMine, customizations: ProjectCustomizations.find(in: folder)) {
                    template = kind.plainTextTemplate
                }
                let rendered = try PromptRenderer.render(template, pr: pr, path: folder)
                prompt = kind == .review ? DesktopLink.reviewPrompt(rendered) : rendered
            }
            guard let url = DesktopLink.url(folder: folder, prompt: prompt) else {
                throw WorkspaceError.failed("Could not build the link to the Claude desktop app.")
            }
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                throw WorkspaceError.failed("The Claude desktop app is not installed. Install it, or choose Terminal in Settings > Claude.")
            }
            NSWorkspace.shared.open(url)
            Log.workspace.notice("Started Claude desktop (\(task.logName, privacy: .public))")
        } catch {
            show(error)
        }
    }

    /// Picks the worktree mode: my own same-repo PRs get their branch (so I can push); others are detached.
    func ensureWorktree(_ pr: PRSnapshot) async throws -> String {
        guard let clone = clone(for: pr.repo) else { throw WorkspaceError.failed("No local clone of \(pr.repo).") }
        guard let workspace = gitWorkspace else { throw WorkspaceError.toolMissing(.git) }
        let branch = pr.isMine && !pr.isCrossRepository && Safety.isSafeBranchName(pr.headRef) ? pr.headRef : nil
        let directory = recordedWorktree(for: pr).map { URL(fileURLWithPath: $0.path) }
            ?? GitWorkspace.worktreeDirectory(root: URL(fileURLWithPath: workspaceSettings.worktreesFolder), repo: pr.repo, number: pr.number)
        let ownerClone: String
        do {
            ownerClone = try await workspace.ensureWorktree(number: pr.number, branch: branch, repo: pr.repo, clone: clone, at: directory)
        } catch WorkspaceError.branchCheckedOutElsewhere {
            // My branch is open in another worktree already: use that one.
            if let state = try? await workspace.state(of: clone.path) {
                for path in state.worktrees {
                    if (try? await workspace.state(of: path).branch) == branch { return path }
                }
            }
            throw WorkspaceError.branchCheckedOutElsewhere(branch ?? "")
        }
        let path = Safety.canonicalPath(directory.path)
        if !reviewWorktrees.contains(where: { $0.path == path }) {
            reviewWorktrees.append(ReviewWorktree(prID: pr.id, repo: pr.repo, number: pr.number, clonePath: ownerClone, path: path, createdAt: Date()))
            saveWorktreeRecords()
        }
        return path
    }

    /// Worktrees Docket created whose PRs are no longer open.
    var staleWorktrees: [ReviewWorktree] {
        let open = Set(snapshots.map(\.id))
        return reviewWorktrees.filter { !open.contains($0.prID) }
    }

    func cleanUpWorktrees(_ worktrees: [ReviewWorktree]) {
        guard let workspace = gitWorkspace else { return show(WorkspaceError.toolMissing(.git)) }
        Task {
            var failures: [String] = []
            for worktree in worktrees {
                do {
                    if FileManager.default.fileExists(atPath: worktree.path) { try await workspace.removeWorktree(worktree) }
                    reviewWorktrees.removeAll { $0.path == worktree.path }
                } catch {
                    failures.append("\((worktree.path as NSString).lastPathComponent): \(error)")
                }
            }
            saveWorktreeRecords()
            if !failures.isEmpty {
                show(title: "Some worktrees were kept", message: "They have local changes or could not be removed:\n" + failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: Helpers

    private func writePromptFile(_ prompt: String) throws -> URL {
        let dir = try promptDirectory()
        let file = dir.appendingPathComponent("prompt-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(prompt.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError.failed("Could not write the prompt file.")
        }
        return file
    }

    /// Settings files are named by their contents and kept, since Claude may read them again later
    /// in the session; `removeStalePromptFiles` clears ones unused for a week.
    private func writeSettingsFile(_ data: Data) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("Docket/settings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(SessionSettings.fileName(for: data))
        if FileManager.default.contents(atPath: file.path) == data {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            try? FileManager.default.removeItem(at: file)
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw WorkspaceError.failed("Could not write the Claude settings file.")
            }
        }
        return file
    }

    private func promptDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("Docket/prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Prompt files are deleted by the terminal command once read; this catches any that never ran,
    /// and settings files no session has used for a week.
    private func removeStalePromptFiles() {
        guard let dir = try? promptDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > 3600 { try? FileManager.default.removeItem(at: file) }
        }
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let settings = try? FileManager.default.contentsOfDirectory(at: caches.appendingPathComponent("Docket/settings"),
                                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in settings {
            let used = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(used) > 7 * 86400 { try? FileManager.default.removeItem(at: file) }
        }
    }

    func saveWorktreeRecords() {
        try? files?.save(reviewWorktrees, as: worktreesFile, encoder: GitHubJSON.encoder())
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        do { try await work() } catch { show(error) }
    }

    func show(_ error: any Error) {
        show(title: "Could not complete the action", message: String(describing: error))
    }

    func show(title: String, message: String) {
        workspaceAlert = WorkspaceAlert(title: title, message: message, actions: [.init(title: "OK", role: .cancel) {}])
        openMainRequest += 1
    }

    func showNoClone(_ pr: PRSnapshot) {
        show(title: "No local clone of \(pr.repo)",
             message: "Docket scans \(workspaceSettings.roots.isEmpty ? "no folders" : workspaceSettings.roots.joined(separator: ", ")). Add a folder or map this repo to a path in Settings > Workspace.")
    }
}
