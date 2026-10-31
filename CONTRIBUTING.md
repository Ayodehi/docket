# Contributing to Docket

Thanks for helping. Bug reports, fixes, and focused features are welcome.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Changes that add GitHub write access or token scopes, or that change how Docket runs processes or launches Claude, need a short design note in `docs/design/` (see `docs/design/review-actions.md` for the format).

## Development setup

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Docket.xcodeproj -scheme Docket -destination 'platform=macOS' build
swift test --package-path Packages/ReviewKit
```

See the [README](README.md#signing) for signing with your own team. Never commit `Config/Local.xcconfig`, a team ID, or a personal bundle ID prefix.

## Guidelines

- Put core logic in `Packages/ReviewKit` with tests; keep the app target to scenes, views, and view models.
- `project.yml` is the source of truth. Do not commit `Docket.xcodeproj`.
- The GitHub token lives only in the Keychain. Never write it to settings, files, logs, or test fixtures.
- Run processes with `Process` and an argument array. The terminal launch command in `Workspace` is the only shell string.
- Never put PR titles, bodies, comments, labels, or fork branch names into commands or Claude prompts. Validate branch names and single-quote paths.
- Never stash, reset, force-push, delete branches, or remove worktrees with `--force` automatically.
- Show status with an icon and text, never color alone.
- Tests and docs use fictional data only (for example `example-org/web-console`). No real organization, repository, or person names, internal links, or credentials.

`CLAUDE.md` and `AGENTS.md` carry the same rules for coding agents.

## Pull requests

- Keep each PR to one change, with tests where the logic allows.
- Make sure `swift test --package-path Packages/ReviewKit` passes and the app builds.
- Update the docs in `docs/` when behavior changes.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
