import CryptoKit
import Foundation

/// The checkout's project MCP servers (`.mcp.json`). In someone else's PR the author controls them.
public enum ProjectMCPServers {
    /// Larger files are not read; the session then loads no MCP servers.
    static let maxFileSize = 1_000_000

    /// Server names in the checkout's `.mcp.json`: empty when there is no file, nil when it is not a
    /// regular file (a symlink could point at a device or a huge file), is over `maxFileSize`, cannot
    /// be parsed, or names a server outside what Claude Code accepts in `disabledMcpjsonServers`
    /// (letters, digits, `_`, `-`). With nil, the session should load no MCP servers at all.
    public static func names(in path: String) -> [String]? {
        let file = (path as NSString).appendingPathComponent(".mcp.json")
        // attributesOfItem does not follow a final symlink, so a link reports its own type.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file) else {
            return FileManager.default.fileExists(atPath: file) || (try? FileManager.default.destinationOfSymbolicLink(atPath: file)) != nil ? nil : []
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maxFileSize,
              let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileSize + 1), data.count <= maxFileSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let names = servers.keys.sorted()
        return names.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.unicodeScalars.allSatisfy(allowed.contains) }) ? names : nil
    }
}

/// Settings passed with `--settings <file>`. Claude Code applies them even with
/// `--setting-sources user`, above the user's own settings.
public enum SessionSettings {
    /// The pull request a review session is for. `repo` and `number` go into auto mode rules, so
    /// they must be safe values (`Safety.isSafeRepo`, a positive number).
    public struct ReviewTarget: Sendable, Equatable {
        public var repo: String
        public var number: Int

        public init(repo: String, number: Int) {
            self.repo = repo
            self.number = number
        }
    }

    /// Rules added to the auto mode classifier's allow list in review sessions. A review session
    /// starts in default mode, but it can end up in auto mode (a user `defaultMode: auto`, or the
    /// user switching), where the classifier otherwise blocks posting even after the user confirms.
    /// Both rules name the one pull request and require the user's confirmation in the session; the
    /// message rule covers only a message to that pull request's author. Nil for an unsafe target.
    public static func reviewAutoModeAllow(_ target: ReviewTarget) -> [String]? {
        guard Safety.isSafeRepo(target.repo), target.number > 0 else { return nil }
        let pr = "pull request #\(target.number) in \(target.repo)"
        return [
            "$defaults",
            "Posting one review (approve, request changes, or comment) with gh pr review on \(pr), and no other pull request, after the user has seen the exact review text in this session and confirmed it",
            "Sending one message through a connected messaging tool such as Slack to the author of \(pr), and no one else, saying the review is posted, after the user has seen the exact message and recipient in this session and confirmed them",
        ]
    }

    /// - Parameters:
    ///   - permissionMode: also written as `permissions.defaultMode`, so anything that falls back to
    ///     the default mode during the session gets this one, not the user's.
    ///   - review: adds `reviewAutoModeAllow` for that pull request.
    ///   - rejectedProjectServers: `.mcp.json` servers to mark rejected, so Claude neither starts
    ///     them nor asks the user to approve them.
    public static func json(permissionMode: String?, review: ReviewTarget?, rejectedProjectServers: [String]) -> Data? {
        var settings: [String: Any] = [:]
        if let permissionMode { settings["permissions"] = ["defaultMode": permissionMode] }
        if let review, let allow = reviewAutoModeAllow(review) { settings["autoMode"] = ["allow": allow] }
        if !rejectedProjectServers.isEmpty { settings["disabledMcpjsonServers"] = rejectedProjectServers }
        guard !settings.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
    }

    /// File name derived from the contents, so identical settings share one file. The file has to
    /// outlive the launch command (Claude Code may read it again during the session), so unlike
    /// prompt files it is not removed once read.
    public static func fileName(for data: Data) -> String {
        "settings-" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
