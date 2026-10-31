import Foundation

public enum Tool: String, CaseIterable, Codable, Sendable {
    case git, gh, claude
}

/// Finds `git`, `gh`, and `claude`. Checks common install paths, then asks the login shell once,
/// because apps launched at login do not inherit the shell's PATH.
public enum ToolLocator {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home.appendingPathComponent(".local/bin").path,
         home.appendingPathComponent(".claude/local").path]
    }

    public static func locate(overrides: [Tool: String] = [:], runner: ProcessRunner = ProcessRunner()) async -> [Tool: URL] {
        var found: [Tool: URL] = [:]
        let fm = FileManager.default
        for tool in Tool.allCases {
            if let path = overrides[tool], fm.isExecutableFile(atPath: path) {
                found[tool] = URL(fileURLWithPath: path)
                continue
            }
            if let dir = candidates().first(where: { fm.isExecutableFile(atPath: "\($0)/\(tool.rawValue)") }) {
                found[tool] = URL(fileURLWithPath: "\(dir)/\(tool.rawValue)")
            }
        }
        let missing = Tool.allCases.filter { found[$0] == nil }
        guard !missing.isEmpty else { return found }
        for (tool, path) in await loginShellLookup(missing, runner: runner) where fm.isExecutableFile(atPath: path) {
            found[tool] = URL(fileURLWithPath: path)
        }
        return found
    }

    /// One login-shell call with a fixed script; no user or PR data is involved.
    static func loginShellLookup(_ tools: [Tool], runner: ProcessRunner) async -> [Tool: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let script = tools.map { "printf 'docket-tool %s=%s\\n' \($0.rawValue) \"$(command -v \($0.rawValue))\"" }.joined(separator: "; ")
        guard let result = try? await runner.run(URL(fileURLWithPath: shell), ["-lc", script], timeout: 10) else { return [:] }
        var found: [Tool: String] = [:]
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("docket-tool ") {
            let pair = line.dropFirst("docket-tool ".count).split(separator: "=", maxSplits: 1)
            if pair.count == 2, let tool = Tool(rawValue: String(pair[0])), pair[1].hasPrefix("/") { found[tool] = String(pair[1]) }
        }
        return found
    }
}
