import Foundation
import ReviewCore
import Workspace

/// Run profiles: start or stop a PR's checkout with a command the user configured for its repo
/// (docs/local-workspace-integration.md, "Run profiles").
extension AppState {
    func runSettings(for repo: String) -> RepoRunSettings {
        workspaceSettings.runProfiles[repo] ?? RepoRunSettings()
    }

    /// Runs `profile` (or the repo's default) on `pr`, in the same folder Claude would use.
    /// Another person's PR asks first, for the commit actually checked out there.
    func startRun(_ pr: PRSnapshot, profile: RunProfile? = nil) {
        guard let profile = profile ?? runSettings(for: pr.repo).defaultProfile else {
            return show(title: "No run profile for \(pr.repo)", message: "Add one in Settings > Run.")
        }
        withWorkFolder(pr, location: .automatic, question: "Where should \"\(profile.name)\" run?") { folder in
            self.confirmThenLaunch(pr, profile: profile, checkout: folder, stop: false)
        }
    }

    /// Runs the profile's stop command where this PR is checked out: its review worktree, or the
    /// main clone when that is on the PR's branch. Never creates a worktree or switches branches.
    func stopRun(_ pr: PRSnapshot, profile: RunProfile? = nil) {
        guard let profile = profile ?? runSettings(for: pr.repo).defaultProfile, profile.hasStop else {
            return show(title: "No stop command", message: "Add a stop command to the run profile in Settings > Run.")
        }
        Task {
            var folder = recordedWorktree(for: pr)?.path
            if folder == nil, let clone = clone(for: pr.repo), await isOnPRBranch(clone, pr) { folder = clone.path }
            guard let folder else {
                return show(title: "\(pr.repoName) #\(pr.number) is not checked out",
                            message: "Docket runs the stop command only in this PR's worktree or a clone on its branch. Run the stop command yourself from the checkout that is running.")
            }
            // A stop command reads the checkout's configuration too (devspace purge runs its hooks).
            confirmThenLaunch(pr, profile: profile, checkout: folder, stop: true)
        }
    }

    /// Another person's PR asks first, once per commit per app session, keyed to the commit checked
    /// out in `checkout` at this moment, not the one Docket last synced: the worktree may have
    /// fetched newer commits, or the folder may be on another branch.
    private func confirmThenLaunch(_ pr: PRSnapshot, profile: RunProfile, checkout: String, stop: Bool) {
        if pr.isMine { return launchRun(pr, profile: profile, checkout: checkout, stop: stop) }
        guard let workspace = gitWorkspace else { return show(WorkspaceError.toolMissing(.git)) }
        Task {
            let head: String
            do {
                head = try await workspace.runner.check(workspace.git, ["-C", checkout, "rev-parse", "HEAD"], timeout: 15)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return show(error)
            }
            let key = "\(pr.id)@\(head)"
            if confirmedRunHeads.contains(key) { return launchRun(pr, profile: profile, checkout: checkout, stop: stop) }
            let commit = String(head.prefix(7))
            let note = head == pr.headSha ? "the PR's latest commit \(commit)" : "commit \(commit), which is not the PR head Docket last saw"
            workspaceAlert = WorkspaceAlert(
                title: "Run \(pr.author)'s code?",
                message: "\"\(profile.name)\" runs a command in \((checkout as NSString).abbreviatingWithTildeInPath), checked out at \(note). Its build files, scripts, and configuration come from there, so only continue if you trust them.",
                actions: [
                    .init(title: stop ? "Stop" : "Run", role: .destructive) {
                        self.confirmedRunHeads.insert(key)
                        self.launchRun(pr, profile: profile, checkout: checkout, stop: stop)
                    },
                    .init(title: "Cancel", role: .cancel) {},
                ])
            openMainRequest += 1
        }
    }

    private func launchRun(_ pr: PRSnapshot, profile: RunProfile, checkout: String, stop: Bool) {
        let branch = pr.isCrossRepository ? nil : pr.headRef
        let values = RunValues(path: Safety.canonicalPath(checkout), number: pr.number, repo: pr.repo, branch: branch)
        Task {
            do {
                if !stop, case .copy = profile.envFileDelivery {
                    guard let workspace = gitWorkspace else { throw WorkspaceError.toolMissing(.git) }
                    try await RunPlanner.installEnvFile(checkout: checkout, profile: profile, git: workspace)
                }
                let command = try RunPlanner.command(checkout: checkout, profile: profile, values: values, stop: stop)
                let folder = try RunPlanner.folder(checkout: checkout, profile: profile)
                let outcome = try await launcher.runInTerminal(command, folder: folder)
                if outcome == .copiedCommand {
                    show(title: "Command copied", message: "Docket is not allowed to control your terminal. The command is on the clipboard; paste it in the terminal window. You can allow Docket under System Settings > Privacy & Security > Automation.")
                }
                Log.workspace.notice("\(stop ? "Stopped" : "Started", privacy: .public) a run profile (\(profile.kind.rawValue, privacy: .public))")
                localInfoVersion += 1
            } catch {
                show(error)
            }
        }
    }
}
