import Foundation
import Testing
@testable import Workspace

@Suite(.serialized) struct RunProfileTests {
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let runner = ProcessRunner()

    private func temp() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DocketRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Safety.canonicalPath(url.path)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func values(_ checkout: String, branch: String? = "mchen/feature") -> RunValues {
        RunValues(path: checkout, number: 42, repo: "example-org/web-console", branch: branch)
    }

    /// A checkout with a `deploy` folder and an env file outside it.
    private func layout() throws -> (root: String, checkout: String, envFile: String) {
        let root = try temp()
        let checkout = root + "/web console"
        try mkdir(checkout + "/deploy")
        let envFile = root + "/env/web-console.env"
        try mkdir(root + "/env")
        try write("PLACEHOLDER=1\n", to: envFile)
        return (root, checkout, envFile)
    }

    private let guardFor = { (context: String) in
        "{ [ \"$(kubectl config current-context)\" = '\(context)' ] && kubectl config view --minify >/dev/null || { printf '%s\\n' 'Docket: the Kubernetes context is not \(context), or kubectl cannot resolve it. Nothing was run.' >&2; false; }; }"
    }

    @Test func devspaceCommandLocksTheContextAndExportsTheEnvFilePath() throws {
        let (root, checkout, envFile) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var profile = RunProfile.devspace(workingDirectory: "deploy")
        profile.envFile = envFile
        profile.kubeContext = "k3d-dev"
        profile.kubeNamespace = "web"
        let lock = root + "/kube/context.yaml"
        let prefix = "cd '\(checkout)/deploy' && export DEVSPACE_ENV_FILE='\(envFile)' && export KUBECONFIG='\(lock)':\"${KUBECONFIG:-$HOME/.kube/config}\" && export DEVSPACE_FLAGS='--kube-context k3d-dev --namespace web' && \(guardFor("k3d-dev"))"
        #expect(try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), kubeLock: lock) == prefix + " && devspace dev")
        #expect(try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), stop: true, kubeLock: lock) == prefix + " && devspace purge")
    }

    @Test func devspaceRefusesToRunWithoutAContextOrLock() throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var profile = RunProfile.devspace(workingDirectory: "deploy")
        #expect(throws: RunError.contextRequired) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), kubeLock: "/x") }
        #expect(throws: RunError.contextRequired) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), stop: true, kubeLock: "/x") }
        profile.kubeContext = "  "
        #expect(throws: RunError.contextRequired) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), kubeLock: "/x") }
        profile.kubeContext = "k3d-dev"
        #expect(throws: RunError.kubeLockMissing) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout)) }
        profile.kubeContext = "dev'; rm -rf ~"
        #expect(throws: RunError.badKubeName("dev'; rm -rf ~")) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), kubeLock: "/x") }
        profile.kubeContext = "k3d-dev"
        profile.kubeNamespace = "a b"
        #expect(throws: RunError.badKubeName("a b")) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout), kubeLock: "/x") }
    }

    @Test func customProfileLockKeepsUserVariablesAndMergesDevspaceFlags() throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let arn = "arn:aws:eks:us-east-1:000000000000:cluster/dev"
        let custom = RunProfile(name: "Helm", command: "helm list", environment: [EnvVar(key: "KUBECONFIG", value: "/k/extra")], kubeContext: arn)
        #expect(try RunPlanner.command(checkout: checkout, profile: custom, values: values(checkout), kubeLock: "/l")
            == "cd '\(checkout)' && export KUBECONFIG='/k/extra' && export KUBECONFIG='/l':\"${KUBECONFIG:-$HOME/.kube/config}\" && \(guardFor(arn)) && helm list")
        var devspace = RunProfile.devspace(workingDirectory: "")
        devspace.kubeContext = "k3d-dev"
        devspace.environment = [EnvVar(key: "DEVSPACE_FLAGS", value: "-p local")]
        #expect(try RunPlanner.command(checkout: checkout, profile: devspace, values: values(checkout), kubeLock: "/l")
            == "cd '\(checkout)' && export KUBECONFIG='/l':\"${KUBECONFIG:-$HOME/.kube/config}\" && export DEVSPACE_FLAGS='--kube-context k3d-dev -p local' && \(guardFor("k3d-dev")) && devspace dev")
    }

    @Test func kubeLockFileSetsOnlyTheContext() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = URL(fileURLWithPath: root + "/kube")
        let path = try RunPlanner.writeKubeLock(context: "k3d-dev", in: dir)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "apiVersion: v1\nkind: Config\ncurrent-context: \"k3d-dev\"\n")
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        // Rewritten on the next launch, undoing a use-context made during a run.
        try "current-context: prod\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try RunPlanner.writeKubeLock(context: "k3d-dev", in: dir) == path)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("\"k3d-dev\""))
        #expect(try RunPlanner.writeKubeLock(context: "other", in: dir) != path)
        #expect(throws: RunError.badKubeName("a\"b")) { try RunPlanner.writeKubeLock(context: "a\"b", in: dir) }
    }

    @Test func rootFolderVariablesAndPlaceholders() throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let profile = RunProfile(name: "Web", command: "make dev PR={number} REPO={repo} DIR={path}",
                                 environment: [EnvVar(key: "BRANCH", value: "b-{branch}"), EnvVar(key: "NOTE", value: "it's $HOME")])
        let command = try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout))
        #expect(command == "cd '\(checkout)' && export BRANCH='b-mchen/feature' && export NOTE='it'\\''s $HOME' && make dev PR='42' REPO='example-org/web-console' DIR='\(checkout)'")
    }

    @Test func copyDeliveryAddsNoVariable() throws {
        let (root, checkout, envFile) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let profile = RunProfile(name: "Web", command: "pnpm dev", envFile: envFile, envFileDelivery: .copy(to: ".env"))
        #expect(try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout)) == "cd '\(checkout)' && pnpm dev")
    }

    @Test func branchPlaceholderNeedsASafeBranch() throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let profile = RunProfile(name: "Web", command: "run {branch}")
        #expect(throws: RunError.branchUnavailable) {
            try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout, branch: nil))
        }
        #expect(throws: RunError.branchUnavailable) {
            try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout, branch: "x;rm -rf ~"))
        }
    }

    @Test(arguments: ["../outside", "/etc", "~/x", "a/../b", "./a", "a//b"])
    func badWorkingDirectoriesAreRejected(_ folder: String) throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let profile = RunProfile(name: "Web", workingDirectory: folder, command: "make")
        #expect(throws: RunError.badFolder(folder)) {
            try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout))
        }
    }

    @Test func missingFolderAndSymlinkEscape() throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(throws: RunError.folderMissing("nope")) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "Web", workingDirectory: "nope", command: "make"), values: values(checkout))
        }
        try FileManager.default.createSymbolicLink(atPath: checkout + "/escape", withDestinationPath: root + "/env")
        #expect(throws: RunError.badFolder("escape")) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "Web", workingDirectory: "escape", command: "make"), values: values(checkout))
        }
    }

    @Test func badKeysEmptyCommandsAndEnvFiles() throws {
        let (root, checkout, envFile) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let v = values(checkout)
        #expect(throws: RunError.badKey("1X")) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "W", command: "make", environment: [EnvVar(key: "1X", value: "")]), values: v)
        }
        #expect(throws: RunError.badKey("A;B")) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "W", command: "make", envFile: envFile, envFileDelivery: .variable("A;B")), values: v)
        }
        #expect(throws: RunError.emptyCommand) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "W", command: "  "), values: v)
        }
        #expect(throws: RunError.noStopCommand) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "W", command: "make"), values: v, stop: true)
        }
        #expect(throws: RunError.envFileMissing(root + "/none.env")) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "W", command: "make", envFile: root + "/none.env"), values: v)
        }
        try write("X=1\n", to: checkout + "/inside.env")
        #expect(throws: RunError.envFileInsideCheckout) {
            try RunPlanner.command(checkout: checkout, profile: RunProfile(name: "W", command: "make", envFile: checkout + "/inside.env"), values: v)
        }
    }

    @Test func tooLongIsRejected() throws {
        let (root, checkout, _) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let profile = RunProfile(name: "W", command: String(repeating: "x", count: 1100))
        #expect(throws: RunError.tooLong) { try RunPlanner.command(checkout: checkout, profile: profile, values: values(checkout)) }
    }

    @Test func detectorFindsDevspaceAtRootAndOneLevelDown() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(RunDetector.suggest(in: root).isEmpty)
        try mkdir(root + "/deploy")
        try write("version: v2beta1\n", to: root + "/deploy/devspace.yaml")
        try mkdir(root + "/node_modules/pkg")
        try write("", to: root + "/node_modules/devspace.yaml")
        var found = RunDetector.suggest(in: root)
        #expect(found.map(\.workingDirectory) == ["deploy"])
        #expect(found.first?.command == "devspace dev")
        #expect(found.first?.stopCommand == "devspace purge")
        #expect(found.first?.envFileDelivery == .variable("DEVSPACE_ENV_FILE"))
        try write("", to: root + "/devspace.yml")
        found = RunDetector.suggest(in: root)
        #expect(found.map(\.workingDirectory) == ["", "deploy"])
    }

    @Test func copyDeliveryOnlyToIgnoredPaths() async throws {
        let (root, checkout, envFile) = try layout()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await runner.check(git, ["init", "-q", checkout])
        let workspace = GitWorkspace(git: git, gh: nil, runner: runner)
        let profile = RunProfile(name: "W", workingDirectory: "deploy", command: "make", envFile: envFile, envFileDelivery: .copy(to: ".env"))

        await #expect(throws: RunError.notIgnored(".env")) {
            try await RunPlanner.installEnvFile(checkout: checkout, profile: profile, git: workspace)
        }
        #expect(!FileManager.default.fileExists(atPath: checkout + "/deploy/.env"))

        try write(".env\n", to: checkout + "/.gitignore")
        try await RunPlanner.installEnvFile(checkout: checkout, profile: profile, git: workspace)
        let target = checkout + "/deploy/.env"
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "PLACEHOLDER=1\n")
        let mode = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Same contents again is fine; different contents are left alone.
        try await RunPlanner.installEnvFile(checkout: checkout, profile: profile, git: workspace)
        try write("LOCAL=1\n", to: target)
        await #expect(throws: RunError.destinationDiffers(".env")) {
            try await RunPlanner.installEnvFile(checkout: checkout, profile: profile, git: workspace)
        }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "LOCAL=1\n")
    }

    @Test func settingsRoundTrip() throws {
        var profile = RunProfile.devspace(workingDirectory: "deploy")
        profile.environment = [EnvVar(key: "A", value: "{number}")]
        let other = RunProfile(name: "Copy", command: "make", envFileDelivery: .copy(to: ".env"))
        let settings = RepoRunSettings(profiles: [profile, other], defaultID: other.id)
        let decoded = try JSONDecoder().decode(RepoRunSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.defaultProfile?.name == "Copy")
        #expect(RepoRunSettings(profiles: [profile]).defaultProfile == profile)
    }
}
