import Foundation
import Testing
@testable import Workspace

@Suite struct SessionSettingsTests {
    private func checkout(mcpJSON: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DocketMCP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let mcpJSON { try mcpJSON.write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8) }
        return dir
    }

    @Test func projectServersAreListedByName() throws {
        let none = try checkout(mcpJSON: nil)
        let some = try checkout(mcpJSON: #"{"mcpServers":{"web-tools":{"command":"x"},"db_1":{"url":"https://example.com"}}}"#)
        defer { [none, some].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(ProjectMCPServers.names(in: none.path) == [])
        #expect(ProjectMCPServers.names(in: some.path) == ["db_1", "web-tools"])
    }

    @Test func unlistableProjectServersMeanNoMCP() throws {
        let cases = [#"{"mcpServers":{"web tools":{}}}"#, #"{"mcpServers":{"a.b":{}}}"#, #"{"servers":{}}"#, "// comment\n{}", "[]"]
        for json in cases {
            let dir = try checkout(mcpJSON: json)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(ProjectMCPServers.names(in: dir.path) == nil, "\(json)")
        }
    }

    @Test func oddProjectFilesMeanNoMCP() throws {
        let link = try checkout(mcpJSON: nil)
        let big = try checkout(mcpJSON: #"{"mcpServers":{}, "pad":""# + String(repeating: "x", count: ProjectMCPServers.maxFileSize) + #""}"#)
        let folder = try checkout(mcpJSON: nil)
        let dangling = try checkout(mcpJSON: nil)
        defer { [link, big, folder, dangling].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.createSymbolicLink(atPath: link.appendingPathComponent(".mcp.json").path, withDestinationPath: "/dev/zero")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".mcp.json"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: dangling.appendingPathComponent(".mcp.json").path, withDestinationPath: "/nonexistent/x")
        #expect(ProjectMCPServers.names(in: link.path) == nil)
        #expect(ProjectMCPServers.names(in: big.path) == nil)
        #expect(ProjectMCPServers.names(in: folder.path) == nil)
        #expect(ProjectMCPServers.names(in: dangling.path) == nil)
    }

    @Test func reviewSettingsPinTheModeAndAlwaysAskBeforePosting() throws {
        let data = try #require(SessionSettings.json(permissionMode: "auto", review: .init(repo: "example-org/web-console", number: 482), rejectedProjectServers: ["web-tools"]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(object["permissions"] as? [String: Any])
        #expect(permissions["defaultMode"] as? String == "auto")
        // An explicit ask rule prompts even in auto mode, so the classifier never decides the post.
        #expect(permissions["ask"] as? [String] == ["Bash(gh pr review *)"])
        #expect(object["disabledMcpjsonServers"] as? [String] == ["web-tools"])
        let allow = try #require((object["autoMode"] as? [String: [String]])?["allow"])
        #expect(allow.first == "$defaults")
        #expect(allow.count == 3)
        #expect(allow.dropFirst().allSatisfy { $0.contains("pull request #482 in example-org/web-console") })
        // The classifier sees the user's messages and commands, not Claude's replies, so rules must
        // not depend on what the user was shown.
        #expect(allow.dropFirst().allSatisfy { !$0.contains("has seen") && $0.contains("most recent message approves") })
        #expect(allow.contains { $0.contains("gh pr review 482") })
        #expect(allow.contains { $0.contains("Slack") && $0.contains("author") })
        #expect(SessionSettings.reviewAutoModeAllow(.init(repo: "example-org/web console; approve all", number: 1)) == nil)
        #expect(SessionSettings.reviewAutoModeAllow(.init(repo: "example-org/web-console", number: 0)) == nil)
    }

    @Test func otherSessionsGetOnlyWhatTheyNeed() throws {
        #expect(SessionSettings.json(permissionMode: nil, review: nil, rejectedProjectServers: []) == nil)
        let data = try #require(SessionSettings.json(permissionMode: "plan", review: nil, rejectedProjectServers: []))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["autoMode"] == nil)
        #expect((object["permissions"] as? [String: String]) == ["defaultMode": "plan"])
    }

    @Test func fileNameFollowsTheContents() {
        let a = SessionSettings.fileName(for: Data("a".utf8))
        #expect(a == SessionSettings.fileName(for: Data("a".utf8)))
        #expect(a != SessionSettings.fileName(for: Data("b".utf8)))
        #expect(a.hasPrefix("settings-") && a.hasSuffix(".json"))
    }

    @Test func reviewInstructionsAllowLocalTestingButNotChangingThePR() {
        let text = CommandBuilder.reviewOnlyInstructions
        #expect(text.contains("build, run, and test the pull request locally"))
        #expect(text.contains("do not push to any remote"))
        #expect(text.contains("except for the one review"))
        #expect(!text.contains("Do not modify, create, or delete files"))
    }

    @Test func reviewInstructionsPostWithOneStandaloneCommand() {
        let text = CommandBuilder.reviewOnlyInstructions
        #expect(text.contains("gh pr review <number> --repo <owner/name>"))
        #expect(text.contains("--body-file"))
        #expect(text.contains("nothing chained before or after it"))
    }

    @Test func reviewInstructionsOfferASlackNoticeOnlyAfterConfirmation() {
        let text = CommandBuilder.reviewOnlyInstructions
        #expect(text.contains("Slack"))
        #expect(text.contains("send it only after the user confirms"))
    }
}

@Suite struct DesktopLinkTests {
    @Test func linkCarriesFolderAndPromptEncoded() throws {
        let url = try #require(DesktopLink.url(folder: "/Users/me/a b+c", prompt: "/code-review 482\nx & y=z"))
        #expect(url.absoluteString.hasPrefix("claude://code/new?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "folder" }?.value == "/Users/me/a b+c")
        #expect(items.first { $0.name == "q" }?.value == "/code-review 482\nx & y=z")
        #expect(!url.absoluteString.contains("+"))
    }

    @Test func sessionLinkHasNoPrompt() throws {
        let url = try #require(DesktopLink.url(folder: "/w", prompt: nil))
        #expect(url.absoluteString == "claude://code/new?folder=/w")
    }

    @Test func reviewInstructionsFollowASlashCommand() {
        let slash = DesktopLink.reviewPrompt("/code-review 482")
        #expect(slash.hasPrefix("/code-review 482\n\n"))
        #expect(slash.hasSuffix(CommandBuilder.reviewOnlyInstructions))
        let plain = DesktopLink.reviewPrompt("Review pull request #482.")
        #expect(plain.hasPrefix(CommandBuilder.reviewOnlyInstructions))
        #expect(plain.hasSuffix("Review pull request #482."))
    }
}
