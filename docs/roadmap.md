# Roadmap and milestones

Milestones are sized for a single developer working part time. Each milestone ends with something usable. Requirement IDs refer to the [PRD](PRD.md).

## M0: Project skeleton (about 1 day)

- Xcode project with app target and local `ReviewKit` package (modules per [Architecture](architecture.md)).
- Hardened Runtime on, App Sandbox off, Apple Events entitlement and usage string.
- `MenuBarExtra` with a placeholder label, main `Window`, and `Settings` scene.
- Unified logging set up.

Exit: app builds, signs, launches, and shows a menu bar icon.

## M1: Auth and first data (2 to 3 days)

- Token entry, validation, Keychain storage, sign out (A1, A2, A3, A5).
- `GitHubClient` with the sync query; decode into models (S1).
- Main window shows a raw list of authored and review-requested PRs.
- Settings persistence (A6) and launch at login toggle (A7).

Exit: after a restart at login, the app shows my open PRs without asking for the token again.

## M2: Status model and views (3 to 4 days)

- `StatusDeriver` and primary states, with table-driven tests (V1).
- Inbox, My PRs, Reviewing views in List mode; PR detail with checks and reviewers (V2, V3, V4).
- `BrowserModel` with scope and presentation separated from the start, even though only List exists yet, so later modes plug in without refactoring.
- Menu bar count and rich popover attention list (`AttentionListView`) with Open on GitHub (M1, M2, M3, M5).
- Adaptive polling, sleep and network handling, rate limit tracking (S3, S4, S5).

Exit: I can use the app instead of the GitHub web UI to see what needs me.

## M3: Notifications (2 to 3 days)

- Rules engine diffing and suppression, with snapshot sequence tests (N1, N2).
- Notification categories, actions, sounds, per-type settings, test button (N3, N4).
- Coalescing with the Smart style, snooze, mute, pause (N5, N6, M3).
- Notification style setting with Every event and Summary only (N9).
- Silent first sync with summary.
- Ignored bots list (N8).
- Hide repo (N10): removed from every view and from sync. Searches add `-repo:owner/name` (verified to work up to at least 40 exclusions) and hidden repos are also filtered locally before any detail fetch, so they cost no detail queries.

Exit: I get one useful notification per actionable change and no duplicates after restarts.

## M4: Local workspace and Claude (3 to 4 days)

- Repo discovery and manual mapping (L1).
- Open in terminal and editor with adapters for Terminal.app, iTerm2, and custom (L2).
- Start Claude session with prompt templates, safe command building, and fallback to copy (L5, L6).
- Check out with dirty-tree guard; review worktrees and cleanup (L3, L4).
- Tool detection for `git`, `gh`, `claude`.

Exit: from a review request notification, two clicks put me in a Claude session on the PR branch in a worktree.

## M5: Polish (2 to 3 days)

- Quick switcher with global shortcut (V6).
- Filters and in-window search with filter tokens (V5, V12).
- Table mode with sorting (any column, including PR number), grouping by repo, state, author, or none, and the inspector (V8, V10, V13).
- Per-scope presentation memory (V9).
- Compact window reusing `AttentionListView`, with Keep on top and Expand (V11).
- Watched repos (S2).
- Hide Dock icon option (M4).
- SAML SSO detection (A4), import from `gh` (A8).
- Accessibility pass (VoiceOver labels, non-color status cues), light and dark appearance check.

Exit: daily-usable app with List and Table modes.

## M6: Board mode (2 to 3 days)

- Board presentation with one column per primary state group, sharing `sectionsByState` with List mode (V8).
- Inspector for Board, keyboard navigation between cards and columns.
- View menu shortcuts for all three presentations.
- Stacked PRs (V14): detect stacks from existing data (a PR whose base branch is another open PR's head branch in the same repo) and show them grouped, parent first, in List, Table, and Board, with "based on #N" in the detail.

Exit: v1 complete. Use daily for two weeks and measure against the success criteria.

## v1.1 candidates

| Feature | Notes |
|---|---|
| Merge from app, with confirmation; enable auto-merge | Needs write scope; opt-in |
| Re-run failed CI jobs | Needs Actions write |
| Notifications endpoint as change trigger (S7) | Classic tokens only |
| Mentions event | Depends on S7 |
| Recently closed list (V7) | |
| Stale review reminders | "mchen has waited 26 working hours for your review" |
| Asana task links from PR body | Show linked task name and status |
| Quiet hours (N7) | |

## Later

- OAuth device flow (A9).
- Reviewer turnaround hints and personal review stats.
- Desktop widget (WidgetKit).
- Daily digest notification.
- Multiple accounts and GitHub Enterprise Server.
- Clone repo action (L7).
