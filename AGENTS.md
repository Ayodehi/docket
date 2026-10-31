# Docket

Native macOS menu bar app (Swift 6, SwiftUI, macOS 14+) that watches the user's GitHub pull requests and launches Claude Code sessions on them. The spec is in `docs/`; start with `docs/README.md`. User-facing setup is in the root `README.md`.

## Build and test

```bash
xcodegen generate
xcodebuild -project Docket.xcodeproj -scheme Docket -destination "platform=macOS,arch=$(uname -m)" build
swift test --package-path Packages/ReviewKit
```

- Install: `tools/install.sh` builds Release and replaces `/Applications/Docket.app`. Debug builds in `.build/DerivedData` are for development; launching one makes it take over Launch at login until the installed app runs again.
- App icon: drawn by `tools/make_icon.swift` (no SF Symbols; their license excludes app icons).
- `project.yml` is the source of truth. `Docket.xcodeproj` is generated and gitignored; never edit it by hand.
- Signing and the bundle ID prefix live in `Config/Signing.xcconfig` (ad hoc, `io.github.docket`), overridden by an uncommitted `Config/Local.xcconfig`. Never commit a team ID or personal bundle prefix.
- Logs: unified logging, subsystem = the bundle ID (`io.github.docket.Docket` by default), categories `app`, `sync`, `notify`, `workspace`. Use `/usr/bin/log` explicitly; in zsh, plain `log` is a builtin and silently does something else:
  `/usr/bin/log show --last 1h --info --predicate 'subsystem == "io.github.docket.Docket"' --style compact`
  `notice` and above are kept on disk; `info` only briefly. An hourly `API usage` notice records points used per hour.
- Core logic belongs in `Packages/ReviewKit` (GitHubKit, ReviewCore, Sync, Workspace, Persistence) so it is testable without UI. The app target holds scenes, views, and view models.

## Rules

- The GitHub token lives only in the Keychain. Never write it to UserDefaults, files, logs, fixtures, or chat.
- Test fixtures and docs use fictional data only (example-org, web-console). This repository is public: no real organization, repository, or person names, internal links, or credentials.
- Run processes with `Process` and an argument array. The only shell string is the terminal launch command built in `Workspace`.
- Never put PR titles, bodies, comments, labels, or fork branch names into commands or Claude prompts. Validate branch names and single-quote paths.
- Never stash, reset, force-push, delete branches, or remove worktrees with `--force` automatically.
- Read-only against GitHub except the opt-in review actions in `docs/design/review-actions.md` (request, re-request, dismiss; off by default). Add no other writes or scopes without a design note in `docs/design/`.
- Status is shown with icon and text, never color alone.
