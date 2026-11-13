# Security and privacy

Docket holds a GitHub token that can read your repositories, including private and organization ones, and it launches local processes based on data from GitHub. This document lists how the app protects both.

## 1. Data the app handles

| Data | Classification | Where it lives |
|---|---|---|
| GitHub token | Credential | Keychain only |
| PR metadata (titles, branch names, authors, review states, check names) | As sensitive as the repositories it comes from | Memory; snapshot cache in Application Support |
| PR bodies and comment text | As above; may contain personal or customer details if someone pasted them into a PR | Not stored. Fetched on demand for display only, or not fetched at all in v1 |
| Local repo paths | Personal | UserDefaults |
| Claude prompts | Contain only repo, number, URL, branch, path | Temp file, deleted after launch |

Sensitive data should never be in PRs to begin with. The app does not copy PR text into prompts, logs, or notifications beyond the title, which limits exposure if it happens.

## 2. Token handling

- Stored as a generic password in the login keychain; not synced to iCloud Keychain. Only this app's code signature can read it without a prompt.
- Read into memory only when building a request; never logged, never shown in the UI after entry (show the login and scopes instead).
- The token entry field is a `SecureField`; the pasteboard is not read automatically.
- Sign out deletes the Keychain item and clears the snapshot cache.
- Request the minimum scopes for v1 (read-only). Write scopes are opt-in when v1.1 write features ship.
- If a token is ever exposed (pasted into chat, committed, logged), revoke it on GitHub immediately and create a new one.

## 3. Network

- HTTPS to `api.github.com` for everything Docket shows. No telemetry and no crash reporting service.
- Release builds also fetch the update feed and DMG from GitHub Releases (`github.com`), anonymously and without the token: when you choose Check for Updates…, and daily only if you opt in. Source builds never do. See [Design note: self-update](design/self-update.md) (added 2026-11-02).
- No inbound sockets or local servers.
- Avatars, if shown, load from `avatars.githubusercontent.com`; this can be disabled.

## 4. Process execution

The app runs `git`, `gh`, editors, and terminals. Rules:

1. Use `Process` with an executable URL and an argument array. Never pass a string to `/bin/sh -c` except for the terminal launch commands described in [Local workspace integration](local-workspace-integration.md): the Claude command and the run profile command (section 3.5). The run command's fragment is the user's own setting, not PR content; every value Docket adds to it is quoted.
2. Never interpolate PR titles, bodies, comment text, author-controlled labels, or fork branch names into commands or prompts.
3. Validate branch names against git ref rules and a character allowlist before use; drop the value if it fails.
4. Single-quote and escape every path placed into the terminal command.
5. Never run code from a PR automatically (no auto-build, no running scripts from the checked-out branch). Checking out a branch is safe; running it is the user's choice. Run profiles start only from an explicit Run or Stop action, and for another person's PR Docket asks first, keyed to the commit checked out in the run folder.
6. Never force-push, reset, stash, or delete branches automatically. Worktree removal does not use `--force`.

Untrusted PR content is a real concern: anyone who can open a PR against a watched repo controls the title, body, and branch name. Treat all of it as data.

## 5. Notifications

- Notification text includes the repo, PR number, title, and actor login. It does not include comment text.
- Option to hide titles in notifications ("Review requested on platform-api#1197"), useful when screen sharing.

## 6. Local storage

- Snapshot cache and ledger files are created with user-only permissions in `~/Library/Application Support/Docket/`.
- "Clear cache" in Settings deletes them.
- Logs use `os.Logger` with `privacy: .private` interpolation for user and PR identifiers, and never include tokens or response bodies.

## 7. Distributing builds

Prebuilt releases are signed with a Developer ID certificate and notarized by `tools/release.sh`; see [Releasing](releasing.md). Source builds are signed locally.

- Consider moving to OAuth device flow with an organization-approved OAuth App so tokens are scoped and revocable centrally.

## 8. Threat summary

| Threat | Mitigation |
|---|---|
| Token theft from disk | Login keychain only, not synced, readable only by this app without a prompt |
| Token leakage in logs or crash reports | No token logging; no third-party crash reporting |
| Shell injection through PR branch names or titles | No PR text in commands; validation and quoting of branch names and paths |
| Prompt injection through PR content into Claude sessions | Prompts contain only safe identifiers; Claude reads PR content itself through `gh`, and the prompts say not to push without confirmation. Users should still review what Claude proposes. |
| Code execution through a reviewed PR's Claude configuration (`.claude` hooks, `.mcp.json` servers) | Claude sessions for others' PRs start with `--setting-sources user` (on by default, Settings > Claude), and the checkout's `.mcp.json` servers are listed by name in a `--settings` file's `disabledMcpjsonServers`; if any name cannot be listed safely, Docket uses `--strict-mcp-config` and no MCP servers load. Non-review sessions also use `--permission-mode plan`. Review sessions instead run in the permission mode chosen in Settings > Claude, pinned on the command line and as `permissions.defaultMode` in the settings file, with review instructions that treat PR content as data and rule out pushing or changing the PR beyond the one confirmed review. Edits, builds, and test runs are allowed so the PR can be tested locally (since 2026-11-11). In `default` mode Claude asks before any edit or command that is not read-only, including running the PR's code. In auto mode (the default since 2026-11-12) Claude Code's classifier decides those instead, so the PR's code can run without a prompt when the classifier judges it safe; pick `default` to approve each command. In both modes a `permissions.ask` rule makes `gh pr review` always show a permission prompt. The checkout's `CLAUDE.md` is still read, so any action it suggests needs approval. |
| Prompt injection steering the user's own MCP tools (Slack, for example) from a review session | The user's MCP servers load in isolated sessions so Claude can notify the PR author. Claude reads PR content as data under the review-only instructions, shows the exact message and recipient, and sends only after the user confirms; default mode also asks before each MCP tool call. If the session is in auto mode, the classifier allow rules cover only a review post on the PR under review and a message to its author about that review, each when the user's latest message approves it; the post also always shows a permission prompt. |
| Opening someone else's PR in the Claude desktop app, where Docket's flags cannot be applied | Terminal is the default. The desktop link carries only a folder and a prompt; before opening a review or another person's PR there, Docket warns that the checkout's hooks, settings, and MCP servers load and that edit tools and the permission mode are not restricted, and offers the terminal instead. Review-only instructions go in the prompt. |
| A reviewed PR redefining `/code-review` (project commands, skills, or agents in its checkout) | Before a slash-command prompt runs in someone else's checkout, Docket looks for `.claude/commands`, `.claude/skills`, and `.claude/agents`. If any exist it uses the plain-text review prompt instead and says why. |
| Running a PR's code through a run profile | Runs only on an explicit Run or Stop click, with a confirmation for others' PRs keyed to the commit actually checked out in the run folder, so a later push asks again. Stop runs only where the PR is checked out. The command and env file are the user's settings; the PR controls only the files the command reads. The env file stays outside the checkout (Variable delivery), or is copied only to a git-ignored path and never over a different file. Placeholders exclude PR text and fork branch names. |
| A run deploying to the wrong Kubernetes cluster (for example production, when it is the shell's current context) | DevSpace profiles must name a context. The run gets a `KUBECONFIG` whose first file sets only that context, `--kube-context` through `DEVSPACE_FLAGS`, and a guard that stops the line unless kubectl reports that context. Stop uses the same lock. |
| Reusing the wrong checkout for a review | Worktree folders include the owner (`<owner>-<name>-pr-<n>`); an existing folder is reused only if it is a worktree of the same clone, otherwise Docket refuses and leaves it alone. |
| Accidental data loss in local clones | No automatic stash, reset, or force; dirty-tree checks; worktrees for reviews |
| Over-privileged token | Read-only scopes in v1; fine-grained tokens supported |
