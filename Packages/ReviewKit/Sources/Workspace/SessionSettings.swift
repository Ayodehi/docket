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

    /// Ask rules for review sessions. A review session starts in default mode, but it can end up in
    /// auto mode (observed when `/code-review`'s background agent reports back, or the user
    /// switching). There the classifier often blocked `gh pr review` even after the user confirmed,
    /// because it does not see Claude's replies (the review text and the question) and so cannot
    /// tell what a bare "yes" approved. An explicit ask rule is resolved before the classifier and
    /// always shows a permission prompt, in every mode, so posting takes one click instead of
    /// being blocked.
    public static let reviewAsk = ["Bash(gh pr review *)"]

    /// Rules added to the auto mode classifier's allow list in review sessions, for posts the ask
    /// rule does not catch (a command form it does not match) and for the Slack message. Each rule
    /// is written in terms the classifier can check: the user's own messages and the command. Both
    /// name the one pull request; the message rule covers only a message to that pull request's
    /// author. Nil for an unsafe target.
    public static func reviewAutoModeAllow(_ target: ReviewTarget) -> [String]? {
        guard Safety.isSafeRepo(target.repo), target.number > 0 else { return nil }
        let pr = "pull request #\(target.number) in \(target.repo)"
        return [
            "$defaults",
            "Posting a review on \(pr) with gh pr review \(target.number) (approve, request changes, or comment, with a body): the user started this session to review that pull request, and Claude shows the review and asks before posting. Allowed when the user's most recent message approves posting, even briefly, such as \"yes\" or \"post it\". Does not cover any other pull request, or merging, closing, editing, labeling, or commenting on this one outside the review",
            "Sending one message through a connected messaging tool such as Slack to the author of \(pr), saying the review is posted: Claude offers this after posting and shows the message and recipient first. Allowed when the user's most recent message approves sending it, even briefly, such as \"yes\" or \"send it\". Does not cover any other recipient or message",
        ]
    }

    /// - Parameters:
    ///   - permissionMode: also written as `permissions.defaultMode`, so anything that falls back to
    ///     the default mode during the session gets this one, not the user's.
    ///   - review: adds `reviewAsk` and `reviewAutoModeAllow` for that pull request.
    ///   - rejectedProjectServers: `.mcp.json` servers to mark rejected, so Claude neither starts
    ///     them nor asks the user to approve them.
    public static func json(permissionMode: String?, review: ReviewTarget?, rejectedProjectServers: [String]) -> Data? {
        var settings: [String: Any] = [:]
        var permissions: [String: Any] = [:]
        if let permissionMode { permissions["defaultMode"] = permissionMode }
        if let review, let allow = reviewAutoModeAllow(review) {
            permissions["ask"] = reviewAsk
            settings["autoMode"] = ["allow": allow]
        }
        if !permissions.isEmpty { settings["permissions"] = permissions }
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
