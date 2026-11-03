# Docket

Docket is a native macOS menu bar app that watches your GitHub pull requests, tells you when one needs you, and gets you from the alert to working on it, including starting a [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) session on the right repository and branch.

It answers one question: whose move is it, and on which PR?

## Features

- **Actionable states, not activity.** Docket reduces GitHub activity to states such as review requested, changes requested, CI failing, conflicts, and ready to merge, for PRs you author and PRs you are asked to review.
- **Quiet notifications.** System notifications fire only when a PR moves into a state that needs you, with per-event toggles and sounds, snooze, per-repository mute, and pause.
- **Several views.** A triage list grouped by whose move it is, a board, and a table in the main window, plus a menu bar popover, a compact always-available window, and a global quick switcher.
- **Local workspace.** Docket finds your local clones, creates review worktrees for PRs, and opens them in your terminal or editor. It never stashes, resets, or force-pushes on its own.
- **Claude Code sessions.** One click starts Claude Code on a PR with a prompt chosen by its state: review it, address feedback, fix failing CI, or resolve conflicts. Sessions open in a terminal (Terminal, iTerm2, or a custom command) or in the Claude desktop app.
- **Safer reviews of others' PRs.** Terminal review sessions cannot edit files, pin the permission mode, and post a review only after you confirm. For other people's PRs, Claude starts without the checkout's `.claude` settings, hooks, and `.mcp.json` servers.
- **Optional review actions.** Request, re-request, or dismiss reviews from Docket. Off by default.
- **Updates.** Release builds update themselves from GitHub Releases with Check for Updates….

## Requirements

- macOS 14 or later.
- Xcode with Swift 6. Docket is developed with a current Xcode release.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- `git`.
- Optional: [GitHub CLI](https://cli.github.com) (`gh`), to import its token and for Claude to read PRs; the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code/overview) or the Claude desktop app, for sessions.

## Download

Signed and notarized releases for Apple silicon Macs are published on the [Releases](https://github.com/Ayodehi/docket/releases) page when available.

1. Download `Docket-<version>.dmg` from the latest release.
2. Open it and drag Docket to the Applications folder.
3. Eject the disk image, then open Docket from Applications and continue with [First launch](#4-first-launch).

To update, choose **Docket > Check for Updates…** (also in Settings > General). Docket downloads the new release, checks its signatures, replaces itself, and relaunches. On the second launch it asks once whether to check automatically each day. On an Intel Mac, build from source.

### Switching from a source build

Releases use the bundle ID `io.github.docket.Docket`. Quit Docket before you replace it. PR history, snoozes, and notification history are kept in `~/Library/Application Support/Docket`, which every copy shares. Settings and the GitHub token are stored under the bundle ID, so what carries over depends on how you built it:

- **Built with the default signing settings:** the bundle ID is the same, so everything carries over. The release has a different signature, so on first launch macOS asks whether Docket may use its Keychain item; choose Always Allow.
- **Built with your own bundle ID prefix** (in `Config/Local.xcconfig`): the release is a separate app to macOS.
  1. With Docket quit, copy your settings, replacing `com.example` with your prefix:

     ```bash
     defaults export com.example.Docket - | defaults import io.github.docket.Docket -
     defaults delete io.github.docket.Docket launchAtLoginPath
     ```

     The second command lets the release register itself for Launch at login. It prints an error if Launch at login was never on; that is fine.
  2. Replace the app in Applications with the release and open it.
  3. Sign in again: paste a token or import the GitHub CLI's.
  4. If System Settings > General > Login Items shows a second Docket entry, remove the one that no longer works. The old token stays in your Keychain under your old bundle ID until you delete it.

## Build and install

These steps build Docket from source and take you from nothing to Docket running in your menu bar.

### 1. Install the tools

1. Install Xcode from the Mac App Store, open it once, and let it finish installing its components.
2. Make sure the command-line tools use that Xcode:

   ```bash
   xcode-select -p
   ```

   If this does not print a path inside `Xcode.app`, run `sudo xcode-select -s /Applications/Xcode.app`.
3. Install XcodeGen with [Homebrew](https://brew.sh):

   ```bash
   brew install xcodegen
   ```

### 2. Get the source

```bash
git clone https://github.com/Ayodehi/docket.git
cd docket
```

### 3. Build and install

Choose one way.

**Install script (recommended).** From the `docket` folder:

```bash
tools/install.sh
```

The script generates the Xcode project, builds a Release copy, replaces `/Applications/Docket.app`, and opens it. It takes a minute or two the first time. When it prints `Installed /Applications/Docket.app`, you are done; continue with [Getting started](#getting-started).

**Xcode (for working on Docket).**

1. Generate the project and open it:

   ```bash
   xcodegen generate
   open Docket.xcodeproj
   ```

2. In the Xcode toolbar, check that the scheme is **Docket** and the destination is **My Mac**.
3. Choose **Product > Run** (Command-R). Xcode builds Docket and starts it; its icon appears in the menu bar and the main window opens.

A copy run from Xcode lives in Xcode's build folder, not in Applications, and it takes over Launch at login until the installed copy runs again. Run `xcodegen generate` again whenever you pull changes that add files or edit `project.yml`.

### 4. First launch

1. Docket opens its main window and adds an icon to the menu bar. Sign in with a GitHub token (see [Getting started](#getting-started)).
2. Allow notifications when macOS asks, so Docket can tell you when a PR needs you.
3. The first time Docket starts Claude in Terminal or iTerm2, macOS asks whether Docket may control that app. Allow it; otherwise Docket copies the command to the clipboard for you to paste.
4. Optional: turn on Launch at login in Docket's settings.

### Updating

```bash
cd docket
git pull
tools/install.sh
```

### Uninstalling

1. Quit Docket, then delete `/Applications/Docket.app`.
2. To remove its data too: choose Sign out in Docket's settings first (this deletes the token from the Keychain), then delete `~/Library/Application Support/Docket`, `~/Library/Caches/Docket`, and the `Docket-*.caf` files in `~/Library/Sounds`, and run `defaults delete io.github.docket.Docket` (or your own bundle ID).

### Signing

By default Docket is ad hoc signed with the bundle ID `io.github.docket.Docket`, which needs no Apple developer account. macOS ties Keychain access to the app's signature, and an ad hoc signature changes with every build, so you may be asked to allow Keychain access again after rebuilding.

To sign with your own Apple team, create `Config/Local.xcconfig` (git ignores it):

```
BUNDLE_ID_PREFIX = com.example
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

Then run `xcodegen generate` again.

## Getting started

1. **Sign in.** Paste a GitHub token, or import the one the GitHub CLI uses. Docket stores it only in your login Keychain.

   A classic token is recommended: it covers everything Docket shows.

   | Capability | Classic token scopes | Fine-grained token permissions |
   |---|---|---|
   | Read PRs, reviews, and CI status | `repo` | Pull requests, Commit statuses, and Contents: read (Metadata is added automatically) |
   | Tell team review requests from direct ones | `read:org` | Members (an organization permission): read |
   | Optional review actions | (included in `repo`) | Pull requests: write |

   Fine-grained tokens have two limits. GitHub offers no Checks permission for them, so CI results from GitHub Actions (check runs) may not show; commit statuses from other CI services do. And organization permissions such as Members only appear when the token's **Resource owner** is an organization, not your personal account; your organization may also need to allow fine-grained tokens. A fine-grained token covers one resource owner, so PRs in other owners' private repositories will not appear.

   If your organization uses SAML single sign-on, authorize the token for it; Docket shows the link when GitHub asks.

2. **Point Docket at your code.** Settings > Workspace lists the folders scanned for clones (by default `~/Projects`, `~/Developer`, and `~/src`, whichever exist) and where review worktrees go.

3. **Pick how Claude starts.** Settings > Claude chooses Terminal or the Claude desktop app, the terminal to use, and the prompt template for each task. Templates can use `{number}`, `{repo}`, `{url}`, `{head_ref}`, `{base_ref}`, and `{path}`. PR titles, descriptions, and comments are never inserted.

## How Claude Code sessions work

Docket starts the `claude` CLI in the PR's worktree or clone. The prompt is passed through a temporary file that the launch command deletes once read; nothing written by the PR's author is placed in the command or the prompt.

Review sessions, whoever wrote the PR:

- run with Edit, Write, and NotebookEdit disallowed;
- pin the permission mode to `default`, so commands such as `gh pr review` ask first even if your settings use another mode;
- get instructions to verify findings, mark them blocking or non-blocking, and post a review only after you confirm the exact text. If a messaging tool such as Slack is connected, Claude then offers to tell the author, again only after you confirm.

Sessions on other people's PRs also start without the checkout's project settings and hooks, and with its `.mcp.json` servers rejected. Your own MCP servers still load. This isolation is on by default (Settings > Claude).

The Claude desktop app is opened through its `claude://code/new` link, which carries only a folder and a prompt. None of the protections above can be applied there, so Docket warns before opening a review or someone else's PR in the desktop app.

See [Local workspace and Claude Code integration](docs/local-workspace-integration.md) for details.

## Privacy and security

- The GitHub token lives only in the login Keychain. It is never written to files, settings, or logs.
- Docket talks to `api.github.com` for your PRs. Release builds also check GitHub Releases for updates when you ask, or daily if you opt in, without sending your token. There is no telemetry or crash reporting.
- Docket is read-only against GitHub unless you turn on review actions.
- Processes run with argument arrays; the terminal launch command is the only shell string, and every value in it is validated or single-quoted.

Details are in [Security and privacy](docs/security-and-privacy.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Troubleshooting

Docket logs to unified logging under its bundle ID. Use `/usr/bin/log` (in zsh, plain `log` is a different builtin):

```bash
/usr/bin/log show --last 1h --info --predicate 'subsystem == "io.github.docket.Docket"' --style compact
```

Replace the subsystem if you set your own bundle ID prefix.

## Project layout

| Path | Contents |
|---|---|
| `Docket/` | The app target: scenes, views, and view models |
| `Packages/ReviewKit/` | Core logic as a Swift package, testable without UI: `GitHubKit`, `ReviewCore`, `Sync`, `Workspace`, `Persistence` |
| `Config/` | Signing settings |
| `docs/` | Design spec: PRD, architecture, GitHub integration, status model, workspace integration, and security |
| `tools/` | `install.sh`, `release.sh` and `bump_version.sh` (see [Releasing](docs/releasing.md)), and the app icon generator |

`project.yml` is the source of truth for the Xcode project; `Docket.xcodeproj` is generated and not committed.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
