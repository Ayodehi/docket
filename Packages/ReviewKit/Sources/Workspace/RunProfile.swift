import Foundation

/// What a run profile was made for. Only a label and the source of presets; every profile runs the
/// same way (`RunPlanner.command`).
public enum RunKind: String, Codable, Sendable, CaseIterable {
    case devspace, custom

    public var title: String {
        switch self {
        case .devspace: "DevSpace"
        case .custom: "Custom"
        }
    }
}

/// How a profile's env file reaches the tool. The file stays on this Mac, outside every checkout.
public enum EnvFileDelivery: Codable, Sendable, Hashable {
    /// `export <name>='<absolute path>'`, for tools that take the env file's path from a variable
    /// (DevSpace reads `DEVSPACE_ENV_FILE`). Nothing is written into the checkout.
    case variable(String)
    /// Copies the file to this path, relative to the run folder, for tools that only read a fixed
    /// name such as `.env`. The destination must be ignored by git.
    case copy(to: String)
}

public struct EnvVar: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var key: String
    /// Literal text plus placeholders. The whole value is single-quoted, so it is never shell syntax.
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// A command that runs a PR's checkout locally, configured per repository by the user. Values in
/// it are the user's own settings, never PR content.
public struct RunProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: RunKind
    /// Relative to the checkout root. Empty means the root.
    public var workingDirectory: String
    /// A shell fragment the user wrote, for example `devspace dev`. Placeholders are substituted
    /// with single-quoted values.
    public var command: String
    /// Optional, for example `devspace purge`. Runs in the same folder with the same environment.
    public var stopCommand: String?
    /// Absolute path on this Mac.
    public var envFile: String?
    public var envFileDelivery: EnvFileDelivery
    public var environment: [EnvVar]

    public init(id: UUID = UUID(), name: String, kind: RunKind = .custom, workingDirectory: String = "", command: String,
                stopCommand: String? = nil, envFile: String? = nil, envFileDelivery: EnvFileDelivery = .copy(to: ".env"),
                environment: [EnvVar] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.command = command
        self.stopCommand = stopCommand
        self.envFile = envFile
        self.envFileDelivery = envFileDelivery
        self.environment = environment
    }

    /// `devspace dev` in the folder holding `devspace.yaml`, stopped with `devspace purge`. The env
    /// file goes through `DEVSPACE_ENV_FILE` so it is never copied into the checkout.
    public static func devspace(workingDirectory: String) -> RunProfile {
        RunProfile(name: "DevSpace", kind: .devspace, workingDirectory: workingDirectory, command: "devspace dev",
                   stopCommand: "devspace purge", envFileDelivery: .variable("DEVSPACE_ENV_FILE"))
    }

    public var hasStop: Bool { !(stopCommand ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Run profiles for one repository, keyed by `owner/name` in the app's settings.
public struct RepoRunSettings: Codable, Sendable, Hashable {
    public var profiles: [RunProfile]
    public var defaultID: UUID?

    public init(profiles: [RunProfile] = [], defaultID: UUID? = nil) {
        self.profiles = profiles
        self.defaultID = defaultID
    }

    /// The chosen default, else the first profile.
    public var defaultProfile: RunProfile? {
        profiles.first { $0.id == defaultID } ?? profiles.first
    }
}

/// The values a profile may reference. Never PR titles, bodies, labels, or fork branch names.
public struct RunValues: Sendable, Equatable {
    /// The checkout root.
    public var path: String
    public var number: Int
    public var repo: String
    /// Only for a same-repository PR whose branch passes `Safety.isSafeBranchName`.
    public var branch: String?

    public init(path: String, number: Int, repo: String, branch: String?) {
        self.path = path
        self.number = number
        self.repo = repo
        self.branch = branch.flatMap { Safety.isSafeBranchName($0) ? $0 : nil }
    }
}

public enum RunError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyCommand
    case noStopCommand
    case badKey(String)
    case badFolder(String)
    case folderMissing(String)
    case envFileMissing(String)
    case envFileInsideCheckout
    case branchUnavailable
    case notIgnored(String)
    case destinationDiffers(String)
    case tooLong

    public var description: String {
        switch self {
        case .emptyCommand: "The run profile has no command."
        case .noStopCommand: "The run profile has no stop command."
        case .badKey(let key): "\"\(key)\" is not a valid environment variable name."
        case .badFolder(let folder): "\"\(folder)\" must be a folder inside the checkout, written as a relative path without \"..\"."
        case .folderMissing(let folder): "The checkout has no folder \"\(folder)\"."
        case .envFileMissing(let file): "The env file \((file as NSString).abbreviatingWithTildeInPath) was not found."
        case .envFileInsideCheckout: "The env file must be outside the checkout, so it is never committed or replaced by the PR."
        case .branchUnavailable: "This profile uses {branch}, which is only available for branches in the same repository with a safe name."
        case .notIgnored(let path): "\(path) is not ignored by git, so Docket did not copy the env file there. Add it to .gitignore or deliver the file through a variable."
        case .destinationDiffers(let path): "\(path) already exists with different contents. Docket did not replace it."
        case .tooLong: "The run command is longer than a terminal line allows. Move variables into the env file."
        }
    }
}

/// Builds the terminal command for a run profile and checks its paths.
public enum RunPlanner {
    public static let placeholders = ["{path}", "{number}", "{repo}", "{branch}"]

    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return key.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// A relative path with no `..`, `.` or empty components. Empty means the root.
    public static func isValidRelativePath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let trimmed = path.hasSuffix("/") ? parts.dropLast() : parts[...]
        return !trimmed.isEmpty && trimmed.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Replaces placeholders. `quoted` single-quotes each value, for text that is shell syntax.
    public static func substitute(_ text: String, values: RunValues, quoted: Bool) throws -> String {
        if text.contains("{branch}"), values.branch == nil { throw RunError.branchUnavailable }
        func wrap(_ value: String) -> String { quoted ? Safety.shellQuote(value) : value }
        return text
            .replacingOccurrences(of: "{path}", with: wrap(values.path))
            .replacingOccurrences(of: "{number}", with: wrap(String(values.number)))
            .replacingOccurrences(of: "{repo}", with: wrap(values.repo))
            .replacingOccurrences(of: "{branch}", with: wrap(values.branch ?? ""))
    }

    /// The run folder: the checkout plus `workingDirectory`, which must exist and, with symlinks
    /// resolved, stay inside the checkout.
    public static func folder(checkout: String, profile: RunProfile) throws -> String {
        let relative = profile.workingDirectory.trimmingCharacters(in: .whitespaces)
        guard isValidRelativePath(relative) else { throw RunError.badFolder(relative) }
        let root = Safety.canonicalPath(checkout)
        if relative.isEmpty { return root }
        let joined = (root as NSString).appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: joined, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RunError.folderMissing(relative)
        }
        let resolved = Safety.canonicalPath(joined)
        guard resolved.hasPrefix(root + "/") else { throw RunError.badFolder(relative) }
        return resolved
    }

    /// The env file, if any: absolute, present, and outside the checkout.
    public static func envFile(of profile: RunProfile, checkout: String) throws -> String? {
        guard let file = profile.envFile?.trimmingCharacters(in: .whitespaces), !file.isEmpty else { return nil }
        let expanded = (file as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw RunError.envFileMissing(file)
        }
        let resolved = Safety.canonicalPath(expanded)
        let root = Safety.canonicalPath(checkout)
        if resolved == root || resolved.hasPrefix(root + "/") { throw RunError.envFileInsideCheckout }
        return resolved
    }

    /// `cd '<folder>' && export KEY='value' && ... && <command>`. The command is the user's own
    /// shell fragment; every value Docket adds is single-quoted.
    public static func command(checkout: String, profile: RunProfile, values: RunValues, stop: Bool = false) throws -> String {
        let fragment = (stop ? profile.stopCommand ?? "" : profile.command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { throw stop ? RunError.noStopCommand : RunError.emptyCommand }
        let folder = try folder(checkout: checkout, profile: profile)
        var steps = ["cd \(Safety.shellQuote(folder))"]
        if let file = try envFile(of: profile, checkout: checkout), case .variable(let name) = profile.envFileDelivery {
            guard isValidKey(name) else { throw RunError.badKey(name) }
            steps.append("export \(name)=\(Safety.shellQuote(file))")
        }
        for variable in profile.environment where !variable.key.isEmpty {
            guard isValidKey(variable.key) else { throw RunError.badKey(variable.key) }
            steps.append("export \(variable.key)=\(Safety.shellQuote(try substitute(variable.value, values: values, quoted: false)))")
        }
        steps.append(try substitute(fragment, values: values, quoted: true))
        let line = steps.joined(separator: " && ")
        guard line.utf8.count < CommandBuilder.maxTerminalLine else { throw RunError.tooLong }
        return line
    }

    /// For `.copy` delivery: copies the env file into the run folder, mode 0600. Refuses a
    /// destination git does not ignore, and never replaces a file with different contents.
    public static func installEnvFile(checkout: String, profile: RunProfile, git: GitWorkspace) async throws {
        guard case .copy(let destination) = profile.envFileDelivery, let source = try envFile(of: profile, checkout: checkout) else { return }
        let relative = destination.trimmingCharacters(in: .whitespaces)
        guard !relative.isEmpty, isValidRelativePath(relative) else { throw RunError.badFolder(relative) }
        let folder = try folder(checkout: checkout, profile: profile)
        let target = (folder as NSString).appendingPathComponent(relative)
        let parent = Safety.canonicalPath((target as NSString).deletingLastPathComponent)
        guard parent == Safety.canonicalPath(checkout) || parent.hasPrefix(Safety.canonicalPath(checkout) + "/") else {
            throw RunError.badFolder(relative)
        }
        let ignored = try await git.runner.run(git.git, ["-C", folder, "check-ignore", "-q", "--", relative], timeout: 15)
        guard ignored.status == 0 else { throw RunError.notIgnored(relative) }
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        if FileManager.default.fileExists(atPath: target) {
            guard (try? Data(contentsOf: URL(fileURLWithPath: target))) == data else { throw RunError.destinationDiffers(relative) }
            return
        }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: target, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError.failed("Could not write \(relative).")
        }
    }
}

/// Suggests run profiles from files in a clone. Checks file names only and runs nothing.
public enum RunDetector {
    static let devspaceFiles = ["devspace.yaml", "devspace.yml"]
    static let skipped: Set<String> = ["node_modules", "vendor", "build", "dist"]

    /// The root and its immediate subfolders, in that order.
    public static func suggest(in clone: String) -> [RunProfile] {
        let manager = FileManager.default
        var folders = [""]
        if let entries = try? manager.contentsOfDirectory(atPath: clone) {
            folders += entries.sorted().filter { name in
                var isDirectory: ObjCBool = false
                return !name.hasPrefix(".") && !skipped.contains(name)
                    && manager.fileExists(atPath: (clone as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }
        return folders.compactMap { folder in
            let base = (clone as NSString).appendingPathComponent(folder)
            guard devspaceFiles.contains(where: { manager.fileExists(atPath: (base as NSString).appendingPathComponent($0)) }) else { return nil }
            var profile = RunProfile.devspace(workingDirectory: folder)
            if !folder.isEmpty { profile.name = "DevSpace (\(folder))" }
            return profile
        }
    }
}
