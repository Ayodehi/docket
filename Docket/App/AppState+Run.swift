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
    /// Another person's PR asks first, once per head commit: running a checkout runs its code.
    func startRun(_ pr: PRSnapshot, profile: RunProfile? = nil, confirmed: Bool = false) {
        guard let profile = profile ?? runSettings(for: pr.repo).defaultProfile else {
            return show(title: "No run profile for \(pr.repo)", message: "Add one in Settings > Run.")
        }
        guard confirmed || confirmRun(pr, profile: profile, action: "Run", then: { self.startRun(pr, profile: profile, confirmed: true) }) else { return }
        withWorkFolder(pr, location: .automatic, question: "Where should \"\(profile.name)\" run?") { folder in
            self.launchRun(pr, profile: profile, checkout: folder, stop: false)
        }
    }

    /// Runs the profile's stop command in the PR's review worktree, or else the main clone. Never
    /// creates a worktree or switches branches.
    func stopRun(_ pr: PRSnapshot, profile: RunProfile? = nil, confirmed: Bool = false) {
        guard let profile = profile ?? runSettings(for: pr.repo).defaultProfile, profile.hasStop else {
            return show(title: "No stop command", message: "Add a stop command to the run profile in Settings > Run.")
        }
        // A stop command reads the checkout's configuration too (devspace purge runs its hooks).
        guard confirmed || confirmRun(pr, profile: profile, action: "Stop", then: { self.stopRun(pr, profile: profile, confirmed: true) }) else { return }
        guard let folder = recordedWorktree(for: pr)?.path ?? clone(for: pr.repo)?.path else { return showNoClone(pr) }
        launchRun(pr, profile: profile, checkout: folder, stop: true)
    }

    /// True when `pr` may run now: the user's own PR, or another person's head commit already
    /// confirmed this session. Otherwise asks, calls `then` on confirmation, and returns false.
    private func confirmRun(_ pr: PRSnapshot, profile: RunProfile, action: String, then: @escaping @MainActor () -> Void) -> Bool {
        let head = "\(pr.id)@\(pr.headSha)"
        if pr.isMine || confirmedRunHeads.contains(head) { return true }
        workspaceAlert = WorkspaceAlert(
            title: "Run \(pr.author)'s code?",
            message: "\"\(profile.name)\" runs a command in this PR's checkout on your Mac. Its build files, scripts, and configuration come from the PR, so only continue if you trust the changes.",
            actions: [
                .init(title: action, role: .destructive) {
                    self.confirmedRunHeads.insert(head)
                    then()
                },
                .init(title: "Cancel", role: .cancel) {},
            ])
        openMainRequest += 1
        return false
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
