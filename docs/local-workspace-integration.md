# Local workspace and Claude Code integration

How the app connects GitHub PRs to local clones, terminals, editors, and Claude Code sessions. Requirements L1 to L7 in the [PRD](PRD.md).

## 1. Mapping repos to local clones

### 1.1 Discovery

1. Settings holds a list of root folders to scan (default: `~/Projects`, `~/Developer`, `~/src`, whichever exist).
2. On launch and on demand ("Rescan"), walk each root to a depth of 3, looking for directories that contain `.git` (a directory, or a file for worktrees and submodules).
3. For each repo found, read the remotes from its git config (`.git/config`, or the common git dir for worktrees) and parse every remote URL into `owner/name`. Reading the file directly is much faster than running git per repo and gives the same URLs. Handle `git@github.com:owner/name.git`, `https://github.com/owner/name(.git)`, and `ssh://git@github.com/owner/name.git`.
4. Build an index `owner/name -> [LocalClone]`. When several clones exist, prefer a main clone over a worktree, then the one whose `origin` matches, then the most recently modified. Paths are stored canonicalized with realpath(3) so symlinked folders compare correctly.
5. Manual overrides in Settings take precedence over discovery.

Skip `node_modules`, `.build`, `DerivedData`, `Pods`, `vendor`, and hidden directories other than `.git` during the walk.

### 1.2 Clone state

On demand (when a PR detail opens or before an action), read:

- Current branch: `git -C <path> rev-parse --abbrev-ref HEAD`
- Dirty state: `git -C <path> status --porcelain=v1` (any output means dirty)
- Existing worktrees: `git -C <path> worktree list --porcelain`
- Whether the PR branch exists locally: `git -C <path> rev-parse --verify --quiet refs/heads/<branch>`

Show this in the PR detail ("Local: ~/Projects/platform-api on main, clean").

## 2. Actions

| Action | Behavior |
|---|---|
| Open on GitHub | `NSWorkspace.shared.open(prURL)`; variants for `/checks` and `/files` |
| Copy | Branch name, PR URL, or `gh pr checkout <n>` to the pasteboard |
| Open in terminal | Open the configured terminal at the clone (or worktree) path |
| Open in editor | Open the folder in the configured editor (VS Code, Cursor, Xcode, Zed, or a custom command) |
| Check out | Fetch and switch the main clone to the PR branch. Refuses when dirty and offers a worktree. |
| Review in worktree | Create or reuse a worktree for the PR, then open terminal, editor, or Claude in it |
| Start Claude session | Open the terminal in the right folder and run `claude` with a prompt chosen by PR state |
| Clean up worktrees | List worktrees created by the app whose PRs are closed; remove the selected ones after confirmation |

### 2.1 Checking out a PR

Prefer the GitHub CLI when available, because it handles forks and sets up tracking:

```
gh pr checkout <number> --repo <owner/name>
```

Fallback with plain git (works for same-repo and fork PRs):

```
git -C <path> fetch origin pull/<number>/head:pr/<number>
git -C <path> switch pr/<number>
```

Never stash or discard changes automatically. If the tree is dirty, show: "platform-api has uncommitted changes on feature/x. Review in a separate worktree instead?" with buttons "Use worktree" and "Cancel".

### 2.2 Review worktrees

- Location: configurable, default `~/Projects/.review-worktrees/<owner>-<repo>-pr-<number>`.
- Mode: someone else's PR gets a detached worktree at the PR head (`pull/<number>/head`). My own same-repo PR gets a worktree on its real branch so I can push; if that branch is already checked out in another worktree, that worktree is used instead (git does not allow one branch in two worktrees).
- Create: `git -C <clone> fetch origin pull/<number>/head` then `git -C <clone> worktree add <dir> FETCH_HEAD --detach`, or with `gh`: create the worktree, then run `gh pr checkout <number>` inside it.
- Reuse the worktree if it already exists; run `git fetch` and fast-forward to the new head when the PR has new commits.
- An existing worktree is reused when it belongs to any local clone whose remote points at the PR's GitHub repo, not only the clone Docket picked; it is fetched through that clone's remote and cleaned up against that clone. A folder from another repository, or one that is not a worktree, is refused and left untouched.
- Record created worktrees in Application Support so cleanup only touches worktrees the app made.
- Cleanup: `git -C <clone> worktree remove <dir>` (without `--force`; if it fails because of local changes, report and leave it).

Worktrees let me review while keeping my own branch untouched, and each Claude session gets an isolated folder.

### 2.3 Worktrees window (added 2026-10-16)

View > Worktrees (Option-Command-T), the sidebar, the Local panel, and Settings > Workspace open a window listing every linked worktree of every main clone Docket knows (scanned roots and repo folder overrides), not only the ones Docket made. A measured account had 88 across 25 clones.

- Columns: folder, repo, branch or detached commit, the open PR it belongs to (Docket's record, the PR's head branch, or the PR's head commit), status, last modified, and whether Docket made it.
- Status, from `git worktree list --porcelain`, `git status --porcelain`, and for detached worktrees Docket did not make, `git for-each-ref --contains <HEAD>`: Clean, Uncommitted changes, Commits on no branch (removing would lose them), Locked, or Folder missing.
- Actions: open in terminal or editor, show in Finder, show the PR, remove selected, and remove every clean worktree without an open PR. Removal is `git worktree remove` without `--force`, so git keeps anything with local changes; branches are never deleted; locked worktrees are skipped; missing folders are dropped with `git worktree prune`. The confirmation names each folder and calls out commits on no branch and open PRs.

## 3. Starting a Claude Code session

### 3.1 Flow

1. Resolve the working folder: existing worktree for the PR, else main clone if it is on the PR branch, else follow Settings > Claude: use a worktree (default, so a notification action reaches Claude in two clicks), check out in the main clone, or ask: "Check out in main clone", "Use worktree", or "Open on current branch". The Claude button's menu can instead choose In a Worktree or In the Main Clone (Switch Branch) for one task; switching refuses when the main clone has uncommitted changes and offers a worktree. Each of those submenus also has Open Claude Session, which starts Claude in that folder with no prompt (isolation flags still apply to others' PRs). The Local panel shows which folder is the repo's main clone and lets me choose another; Docket accepts only a git repository with a GitHub remote for that repo.
2. Pick a prompt template from the PR's primary state (overridable from a submenu).
3. Write the rendered prompt to a temp file under the app's caches folder with `0600` permissions.
4. Launch the terminal with a command that changes to the folder and runs `claude` with the prompt read from that file.

### 3.2 Prompt templates

Templates use placeholders filled with **safe values only**: repo, number, URL, branch names after validation, and the local path. PR titles and bodies are never interpolated into the prompt or command; Claude Code can fetch them itself with `gh`. This avoids both shell injection and prompt injection through PR text that someone else controls.

Default templates (editable in Settings):

**Review a PR** (states: Review requested, Re-review requested)

```
/code-review {number}
```

Runs Claude Code's `/code-review` command on the PR from inside its worktree, so the number resolves against the right repository. Without `--comment` it reports findings in the session and posts nothing to GitHub. (Changed 2026-10-13 from a hand-written review prompt.)

Every review session is review-only, whoever wrote the PR (added 2026-10-14). Docket starts Claude with:

- `--disallowedTools=Edit,Write,NotebookEdit`, so Claude cannot edit files.
- `--permission-mode default`, so a user setting such as `defaultMode: auto` cannot let commands, including posting the review, run without asking (added 2026-10-15). The `=` form matters: the option takes a list and would otherwise swallow the prompt that follows it.
- `--settings <file>` (added 2026-10-28), a JSON file in `~/Library/Caches/Docket/settings` named by a hash of its contents and kept for a week after last use, because Claude may read it again during the session. It sets `permissions.defaultMode` to `default` as well: review sessions were observed switching to the user's `defaultMode: auto` partway through (when `/code-review`'s background agent reported back), after which the auto mode classifier blocked `gh pr review` even when the user confirmed. It also adds two `autoMode.allow` rules, so that if a session does end up in auto mode, the classifier lets through one review post on that PR, or one Slack message to that PR's author, that the user saw and confirmed in the session. Both rules name the repository and PR number (validated values only).
- `--append-system-prompt` (read from a temporary file, like the prompt, because a typed terminal line holds at most 1024 bytes and the rest is silently dropped) with instructions to change nothing in the repository, verify each finding against the code and drop any it cannot confirm, mark findings blocking or non-blocking, and then offer to post a review with `gh pr review`: request changes listing the blocking issues, or approve with any non-blocking issues in the body. Claude shows the exact review text and posts only after the user confirms. After posting, if a messaging tool such as Slack is connected, Claude offers to tell the PR author that the review is posted, showing the exact message and recipient and sending only after the user confirms (added 2026-10-28).

For others' PRs the isolation flags still apply (no project settings, hooks, or MCP servers from the checkout), but review sessions do not use plan mode (changed 2026-10-15): with the edit tools off, plan mode only failed to write its plan file and added a second approval before posting. Claude's default mode still asks before any command that is not read-only, including `gh pr review`. Other session types on others' PRs still start in plan mode.

MCP servers in isolated sessions (changed 2026-10-28): Docket no longer passes `--strict-mcp-config`, which dropped every MCP server, including the user's own and claude.ai connectors such as Slack. Instead it reads the server names from the checkout's `.mcp.json` and lists them in the session's `disabledMcpjsonServers`, so Claude marks them rejected and neither starts them nor asks to approve them. The user's servers load as usual. If the file is not a regular file (a symlink, for example), is over 1 MB, cannot be parsed, has no `mcpServers` object, or names a server with characters outside letters, digits, `_`, and `-`, Docket falls back to `--strict-mcp-config` and tells the user the session has no MCP servers.

**Address review feedback** (state: Changes requested, New comments)

```
My pull request #{number} in {repo} ({url}) has review feedback.
Use `gh pr view {number} --comments` and
`gh api repos/{repo}/pulls/{number}/comments` to read all unresolved comments.
List each requested change, then work through them one at a time, asking me
before anything ambiguous. Do not push until I confirm.
```

**Fix failing CI** (state: CI failing)

```
CI is failing on pull request #{number} in {repo} ({url}), branch {head_ref}.
Use `gh pr checks {number}` and `gh run view --log-failed` to find the failures.
Explain the root cause and propose a fix. Do not push until I confirm.
```

**Resolve conflicts** (state: Conflicts, Behind base)

```
Pull request #{number} in {repo} is out of date with {base_ref}.
Rebase {head_ref} onto origin/{base_ref}, resolve conflicts, and explain each
resolution. Do not force-push until I confirm.
```

Note that the prompts tell Claude not to push without confirmation. The user decides when to push, and pushes go through the normal PR and review process.

### 3.3 Terminal adapters

Terminal choice is a setting. Each adapter turns `(folder, command)` into a launch.

| Terminal | Mechanism |
|---|---|
| Terminal.app | AppleScript: `tell application "Terminal" to do script "<command>"` then `activate` |
| iTerm2 | AppleScript: `create window with default profile` then `write text "<command>"` on the current session |
| Ghostty, WezTerm, Kitty, Alacritty | Command-line launch with a working directory and command argument. Flags differ per app and version; check each terminal's documentation and make the template editable. |
| Warp | Warp URL scheme for opening a path; command injection is limited, so fall back to opening the folder and copying the command |
| Custom | User-defined command template with `{path}` and `{command}` placeholders |

The command passed to the terminal:

```
cd '<path>' && p=$(cat '<prompt-file>') && rm -f '<prompt-file>' && '<claude>' "$p"
```

- `<path>`, `<prompt-file>`, and `<claude>` (the detected absolute path) are app-controlled, single-quoted with embedded single quotes escaped as `'\''`.
- The prompt file is deleted by the command as soon as the shell has read it. Any left over (a launch that never ran) are removed after an hour.
- Before use, branch names are validated against `git check-ref-format --branch` rules and a conservative character allowlist; any value that fails is left out of the prompt.
- If Apple Events permission is denied, copy the command to the pasteboard, open the terminal at the folder, and show "Command copied. Paste it in the terminal to start Claude."

### 3.3a Claude desktop app (added 2026-10-29)

Settings > Claude > "Open Claude in" picks Terminal (the default) or the Claude desktop app, and the Claude button's menu can use the other one for a single launch. Docket opens a desktop Code session with the app's `claude://code/new?folder=<path>&q=<prompt>` link through `NSWorkspace`, so it needs neither Apple Events nor a terminal line under 1024 bytes. `+` in the query is percent-encoded because the app reads it as a space. An empty session sends only `folder`.

The link takes a folder and a prompt and nothing else, so a desktop session has none of the CLI flags in 3.2:

- Edit, Write, and NotebookEdit are not disallowed.
- The permission mode is the desktop app's own, with no pinned mode and no `--settings` file, so no `autoMode.allow` rules for a confirmed post.
- No `--setting-sources user`, so for others' PRs the checkout's `.claude` settings and hooks load, and its `.mcp.json` servers are not rejected.

For reviews, the review-only instructions go into the prompt: after the slash command, so `/code-review` still runs, or before a plain-text prompt. The plain-text fallback for checkouts that define their own commands still applies. Before opening a review or someone else's PR (with isolation on) in the desktop app, Docket shows what the session will lack, with buttons to open it there anyway, use the terminal instead, or cancel.

Whether the app sends the prompt at once or only fills it in for the user to send is decided by the desktop app, not Docket; it was not confirmed when this was added.

### 3.4 Editors

| Editor | Launch |
|---|---|
| VS Code | `open -a "Visual Studio Code" <path>` or the `code` CLI if installed |
| Cursor | `open -a Cursor <path>` |
| Xcode | `open -a Xcode <path>` (opens the folder; if a `.xcodeproj` or `.xcworkspace` is at the root, open that instead) |
| Zed | `open -a Zed <path>` |
| Custom | Command template with `{path}` |

All launches use `Process` with an argument array (no shell) except the terminal command string, which is constructed as described above.

## 4. Tool detection

On launch, locate `git`, `gh`, and `claude` by checking common install paths (`/usr/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`) and the user's login shell `PATH` (run `$SHELL -lc 'command -v claude'` once and cache). GUI apps launched at login do not inherit the shell `PATH`, so this step is required. Show detection results in Settings with a "Locate..." button for each tool.

If `claude` is missing, the Claude actions show "Install Claude Code" with a link to the setup docs instead of failing silently.
