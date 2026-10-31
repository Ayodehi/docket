# Docket PRD

| | |
|---|---|
| Status | Draft v0.1 |
| Last updated | 2026-10-13 |
| Platform | macOS (native, Swift and SwiftUI) |
| Name | Docket (chosen 2026-10-13; early artifacts say GitReviewTool) |

Related documents:

- [Architecture](architecture.md)
- [GitHub integration](github-integration.md)
- [PR status model and notification rules](status-model-and-notifications.md)
- [Local workspace and Claude Code integration](local-workspace-integration.md)
- [Security and privacy](security-and-privacy.md)
- [Roadmap and milestones](roadmap.md)
- [UX options](ux-options.md)

## 1. Problem

I work on a team that ships through GitHub pull requests. My review work is split across two loops:

1. **Reviewer loop.** Teammates request my review. I need to notice the request, check out the branch, test it, and leave a review. When they push fixes, I need to notice that too and re-review.
2. **Author loop.** I request reviews on my PRs. Reviewers leave comments or request changes, which I need to address, or they approve, after which I merge once CI is green.

Today the signal for both loops is spread across GitHub email, the GitHub web notifications inbox, Slack mentions, and CI emails. The signals are noisy (every comment, every bot, every CI run), they arrive late or not at all, and none of them answer the question that matters: **what do I need to do next, and on which PR?**

Once I know what to do, getting started is also slow: find the repo locally, stash work, fetch, check out the branch, open a terminal, start a Claude Code session, and explain to it which PR to look at.

## 2. Goal

A macOS menu bar app that acts as a single pane of glass for my GitHub PR work. It:

- Watches the PRs I author, the PRs I am asked to review, and the repos I choose.
- Reduces raw GitHub activity to a short list of **actionable states** ("review requested", "changes requested on your PR", "ready to merge", "CI failed").
- Alerts me with a system notification and sound **only** when something moves into an actionable state.
- Gets me from an alert to working on the PR in one or two clicks: open on GitHub, check out locally, or start a Claude Code session in the right repo and branch with a useful prompt.

## 3. Users

The primary user is me: a developer who is both an author and a reviewer on a small team, works in several repos, uses the terminal and Claude Code daily, and runs macOS.

Secondary users are teammates with the same workflow, if the app proves useful and is shared (see [Security and privacy](security-and-privacy.md) for what that requires).

## 4. Success criteria

| Measure | Target |
|---|---|
| Time from a review request to my awareness of it | Under 2 minutes while the app is running |
| Notifications that I consider noise | Under 1 in 10 (self-reported over two weeks) |
| Clicks from a notification to a Claude Code session on the PR branch | 2 or fewer |
| GitHub API budget used | Under 20 percent of the hourly GraphQL limit at the default polling interval |
| Idle CPU and memory | Under 1 percent CPU averaged, under 150 MB resident |
| I stop checking GitHub email and the web inbox for PR work | Yes, after two weeks |

## 5. Scope

### 5.1 In scope for v1

**Connect and persist**

- Sign in to GitHub with a token. The token is stored in the macOS Keychain, never in plain files or logs.
- Settings persist across launches (watched repos, polling interval, notification preferences, local repo paths, launcher preferences).
- Launch at login, controlled by a toggle in Settings, using the system Login Items mechanism.
- Remember window size and position and the last selected view.

**Monitor**

- Automatically track every open PR where I am the author, a requested reviewer (directly or through a team), or a previous reviewer.
- Optionally watch whole repos to see all open PRs in them, not only mine.
- Poll GitHub on an adaptive schedule (default 60 seconds while active, slower when the machine is idle or on battery, with a manual "Refresh now").
- Detect state transitions between polls and keep the last known state on disk so restarts do not re-alert old items.

**See status**

For each PR, show:

- CI status: passing, failing, running, or none. Expandable to individual check runs, with links to logs.
- Review status: review required, changes requested, approved, commented, and who did what.
- My relationship: author, requested reviewer, team-requested reviewer, previous reviewer, or watcher.
- Merge readiness: mergeable, conflicts, behind base, blocked by branch protection, or draft.
- Unresolved review thread count, last activity time, age, and size (additions and deletions).

**Views**

- **Inbox (Needs my attention):** the derived list of PRs where the next action is mine, grouped and sorted by urgency.
- **My PRs:** everything I authored, with status.
- **Reviewing:** PRs where my review is requested or I have reviewed.
- **Repos:** watched repos with their open PRs, filterable by author, label, and status.
- Search and filter across all of the above.
- **View modes.** Each of the views above can be shown as a **List** (default: grouped list plus a detail pane), a **Board** (columns per state), or a **Table** (dense and sortable). The mode is remembered per view.
- **Compact window.** A narrow window showing the menu bar popover's card list, which can float above other windows.

**Notify**

- System notification banner with a sound when a PR enters an actionable state. Rules are in [PR status model and notification rules](status-model-and-notifications.md).
- Per-event-type toggle and sound selection.
- Notification actions: Open on GitHub, Open in app, Start Claude session, Snooze.
- Coalescing: several changes within a short window produce one summary notification, not a burst.
- Snooze a PR (1 hour, until tomorrow, until next change) and mute a repo.
- Respect macOS Focus modes; no custom do-not-disturb logic beyond optional quiet hours.

**Menu bar**

- Menu bar icon that shows the attention count and the worst state (for example, a failing CI on my PR).
- Menu with the attention list and quick actions per item, plus Refresh now, Pause notifications, Open main window, Settings, and Quit.
- The app can run with no Dock icon while the main window is closed.

**Act**

- Open a PR, its checks, or its files view on GitHub.
- Copy branch name, PR URL, or `gh pr checkout` command.
- Open the local clone in Terminal (or the configured terminal app) and in the configured editor.
- Check out the PR branch locally, or create a dedicated git worktree for review when the main clone has uncommitted changes.
- Start a Claude Code session in the repo (or worktree) on the PR branch with a prompt template: "review this PR" for review requests, "address review feedback" for my PRs with changes requested, "fix CI" for failing checks.
- Map GitHub repos to local clone paths automatically by scanning configured folders, with manual override.
- Global keyboard shortcut that opens a quick switcher to jump to any repo or PR by typing.

### 5.2 Out of scope for v1

- Writing reviews or comments inside the app (use GitHub or Claude Code).
- Merging, approving, or re-running CI from the app (planned for v1.1, see roadmap; these need write scopes).
- GitHub Enterprise Server, multiple GitHub accounts, GitLab, and Bitbucket.
- Issue tracking beyond PRs.
- Team analytics or dashboards (review latency charts and similar).
- Windows, Linux, iOS.
- App Store distribution. The app is signed locally and runs on my machine.

### 5.3 Candidates for later versions

Ranked by expected value. Details in the [roadmap](roadmap.md).

1. Merge from the app when approved and green, with a confirmation step, and "merge when ready" that merges automatically once checks pass.
2. Re-run failed CI jobs from the app.
3. Stale review reminders: nudge me when a review request has waited more than N working hours.
4. Reviewer turnaround hints: show how long my PRs have waited on each reviewer.
5. Asana task links: detect Asana links in PR bodies and show the linked task.
6. OAuth device flow sign-in instead of pasting a token.
7. Daily digest notification at a set time.
8. Desktop widget showing the attention count and top items.

## 6. User stories

| ID | As a... | I want to... | So that... |
|---|---|---|---|
| U1 | reviewer | get a notification when someone requests my review | I can respond quickly and not block them |
| U2 | reviewer | be notified when an author pushes new commits after I requested changes | I know when to re-review |
| U3 | reviewer | check out a PR branch locally in one click, without losing my in-progress work | I can test it safely |
| U4 | reviewer | open Claude Code on the PR branch with a review prompt | I can get a first-pass review and test plan quickly |
| U5 | author | be notified when a reviewer requests changes or leaves comments on my PR | I can address feedback promptly |
| U6 | author | be notified when my PR is approved and CI is green | I can merge it |
| U7 | author | be notified when CI fails on my PR | I can fix it before reviewers look |
| U8 | author | see unresolved thread counts and who has not reviewed yet | I know whom to nudge |
| U9 | author | open Claude Code with the review comments as context | I can work through the requested fixes |
| U10 | either | see everything that needs me in one list, ordered by urgency | I do not have to check several places |
| U11 | either | snooze a PR or mute a repo | I control noise |
| U12 | either | jump to any repo or PR with a keyboard shortcut | I can navigate without the mouse |
| U13 | either | have the app start at login with my settings intact | it just works every morning |
| U14 | either | quickly see from the menu bar icon whether anything needs me | I do not need to open the app |
| U15 | either | know when a PR has merge conflicts or is behind its base | I can rebase before it blocks a merge |

## 7. Functional requirements

Requirement IDs are referenced from the roadmap and test plans. Priority: P0 is required for v1, P1 is wanted for v1, P2 is later.

### 7.1 Authentication and settings

| ID | Requirement | Priority |
|---|---|---|
| A1 | Accept a GitHub token on first run, validate it against the API, and show the signed-in login and the scopes or permissions it has. | P0 |
| A2 | Store the token in the login keychain (generic password item, not synced to iCloud). Never write it to UserDefaults, files, or logs. | P0 |
| A3 | Detect a revoked or expired token (HTTP 401) and prompt to re-authenticate without losing settings. | P0 |
| A4 | Detect organizations that require SAML SSO authorization for the token and show a link to authorize it. | P1 |
| A5 | Sign out removes the token from the Keychain and clears cached PR data. | P0 |
| A6 | Persist settings in UserDefaults; persist the PR snapshot cache in Application Support. | P0 |
| A7 | Launch at login toggle using the system Login Items API. | P0 |
| A8 | Import a token from the GitHub CLI (`gh auth token`) as a convenience, with explicit user action. | P1 |
| A9 | OAuth device flow sign-in. | P2 |

### 7.2 Sync

| ID | Requirement | Priority |
|---|---|---|
| S1 | Track open PRs authored by me, requesting my review (user or team), and reviewed by me, across all repos the token can see. | P0 |
| S2 | Track all open PRs in explicitly watched repos. | P1 |
| S3 | Default poll interval of 60 seconds; configurable from 30 seconds to 15 minutes. | P0 |
| S4 | Back off when the system is idle, asleep, on low power mode, or offline; refresh immediately on wake and on network reconnect. | P0 |
| S5 | Respect GitHub rate limit headers and the GraphQL `rateLimit` object; slow down before running out and show a banner if limited. | P0 |
| S6 | Detect PRs that close or merge and move them out of active lists (keep in a "Recently closed" list for 7 days). | P1 |
| S8 | Ignore PRs across all repos by title text (for example `[Snyk]`, `[dependabot]`) or `author:login`. Matching runs on discovery results, so ignored PRs are never detail-fetched, shown, counted, or notified. | P1 |
| S7 | Use the REST notifications endpoint with conditional requests as a cheap change trigger when the token supports it. | P2 |

### 7.3 Status and views

| ID | Requirement | Priority |
|---|---|---|
| V1 | Derive a single primary state per PR from CI, reviews, mergeability, and my role, using the rules in the status model doc. | P0 |
| V2 | Inbox view listing PRs whose next action is mine, sorted by urgency, then age. | P0 |
| V3 | My PRs, Reviewing, and Repos views. | P0 |
| V4 | PR detail: checks list with status and links, reviewers and their latest review state, unresolved thread count, merge state, branch names, labels, body preview. | P0 |
| V5 | Filter by repo, author, state, and label; free-text search on title, number, and branch. | P1 |
| V6 | Quick switcher with fuzzy search over repos and PRs, opened by a global shortcut. | P1 |
| V7 | Recently closed list. | P2 |
| V8 | Presentation modes List, Board, and Table for every sidebar scope, switched from the toolbar or by shortcut, sharing selection, filters, and search. | P1 |
| V9 | Remember the presentation mode per scope; a setting sets the default for new scopes. | P1 |
| V10 | Inspector pane for PR detail in Board and Table modes, toggled from the toolbar. | P1 |
| V11 | Compact window that reuses the popover list, with "Keep on top" and "Expand to main window". | P1 |
| V12 | Command-F focuses the in-window search, which accepts `repo:`, `author:`, `state:`, and `label:` tokens. | P1 |
| V13 | Table mode sorts by any column, including PR number, and groups by repo, state, author, or none. | P1 |
| V14 | Stacked PRs (a PR based on another open PR's head branch in the same repo) are shown grouped, parent first, with the stack relationship in the detail. Tool-neutral; no stack tool integration. | P1 |

### 7.4 Notifications

| ID | Requirement | Priority |
|---|---|---|
| N1 | Post a system notification with sound when a PR transitions into an actionable state defined in the rules table. | P0 |
| N2 | Do not re-notify for a state already notified, including across app restarts. | P0 |
| N3 | Per-event-type enable toggle and sound selection. | P0 |
| N4 | Notification actions: Open on GitHub, Open in app, Start Claude session, Snooze 1 hour. | P1 |
| N5 | Coalesce events within a 10 second window into one summary notification. | P1 |
| N6 | Snooze per PR and mute per repo. | P1 |
| N7 | Optional quiet hours (in addition to system Focus). | P2 |
| N8 | Ignore activity from configured bot accounts (for example dependency update bots) unless I am explicitly requested. | P1 |
| N9 | Notification style setting: Smart (default), Every event, or Summary only, as defined in the status model doc. | P1 |
| N10 | Hide a repo: its PRs leave every view and it is excluded from sync, so it uses no API points. Hidden repos are listed in Settings and can be restored. | P1 |

### 7.5 Menu bar

| ID | Requirement | Priority |
|---|---|---|
| M1 | Menu bar icon with attention count; icon variant indicates the most urgent state. | P0 |
| M2 | Menu lists attention items (up to 10, then "Show all"), each with submenu or inline quick actions. | P0 |
| M3 | Global actions: Refresh now, Pause notifications (1 hour, until tomorrow, indefinitely), Open main window, Settings, Quit. | P0 |
| M4 | Option to hide the Dock icon while the main window is closed. | P1 |
| M5 | Show last sync time and sync errors in the menu. | P0 |

### 7.6 Local actions

| ID | Requirement | Priority |
|---|---|---|
| L1 | Map `owner/repo` to a local clone path by scanning configured root folders for git remotes; allow manual mapping. | P0 |
| L2 | Open the clone in the configured terminal app and editor. | P0 |
| L3 | Check out a PR branch in the main clone, refusing if the working tree is dirty and offering a worktree instead. | P1 |
| L4 | Create a review worktree for a PR in a configured worktrees folder and clean up worktrees for closed PRs on request. | P1 |
| L5 | Start a Claude Code session in the clone or worktree with a prompt template chosen by PR state. Templates are editable in Settings. | P0 |
| L6 | Never place untrusted PR text (titles, bodies, branch names from forks) unescaped into a shell command. | P0 |
| L7 | Offer "Clone repo" when no local clone exists. | P2 |

## 8. Non-functional requirements

| Area | Requirement |
|---|---|
| Performance | Main window opens in under 300 ms from the menu. List of 200 PRs scrolls smoothly. |
| Resource use | Idle CPU under 1 percent averaged; no polling while asleep. |
| Reliability | Network and API errors never crash the app or clear the displayed state; show last good data with a stale indicator. |
| Security | Token only in Keychain; HTTPS only; no telemetry; no third-party analytics. See [Security and privacy](security-and-privacy.md). |
| Accessibility | Status is shown with icon and text, not color alone. VoiceOver labels on all controls. Supports system text size and light and dark appearance. |
| Compatibility | macOS 14 Sonoma or later (needed for the Observation framework and recent MenuBarExtra and SwiftData behavior). |
| Distribution | Signed locally with my Apple Development identity; Hardened Runtime on; App Sandbox off (see architecture for why). |
| Observability | Local log via unified logging (`os.Logger`) with a privacy-safe subsystem; never log tokens or PR bodies. |

## 9. UX summary

The app has three surfaces:

1. **Menu bar item.** Always present. Shows a count and the worst state. Click opens a rich popover (status labels, tabs, and one-click actions per PR).
2. **Main window.** Opened from the menu, the Dock, or the global shortcut. The sidebar picks the scope (Inbox, My PRs, Reviewing, Snoozed, a repo); the toolbar picks the presentation (List by default, or Board or Table). A Compact window mode shows the popover list in a small window that can float.
3. **Notifications.** Banners with actions, grouped per repo. The Smart style is the default: high urgency events get their own banner and the rest are summarized.

Plus a global floating **quick switcher** panel, in-window search, and a **Settings** window.

Decisions and rationale are recorded in [UX options](ux-options.md).

## 10. Risks and open questions

| # | Item | Notes |
|---|---|---|
| R1 | Organization token policies | Our GitHub organization may restrict classic tokens, require fine-grained tokens, or require SAML SSO authorization. Confirm before choosing the default auth method. |
| R2 | Fine-grained token limits | Fine-grained tokens appear not to support the REST notifications endpoint (per GitHub docs at time of writing; verify). The design does not depend on it. |
| R3 | Search index lag | GitHub search can lag behind real state by seconds to a minute. Per-PR state is read from the PR itself, not from search results, to limit stale data. |
| R4 | Polling cost | Large teams or many watched repos could push GraphQL cost up. Mitigated by adaptive polling and query cost monitoring. |
| R5 | Terminal automation permissions | Driving Terminal or iTerm2 via Apple Events triggers a one-time macOS permission prompt. Users who deny it fall back to copying the command. |
| R6 | Sharing with teammates | Distributed builds handle tokens with access to private repositories; see Security and privacy section 7. |
| Q1 | Final app name. | Resolved 2026-10-13: Docket. |
| Q2 | Which main window layout and menu bar style to build first (see UX options). | Resolved 2026-10-13: List (triage inbox) as default with Board and Table modes; rich popover menu bar; Smart notifications; global switcher. |
| Q3 | Should "commented" reviews (no approve or request changes) trigger a notification by default? Current proposal: yes for my PRs, coalesced. | |
| Q4 | Should watched-repo PRs that do not involve me ever notify? Current proposal: no, view only, unless a rule is added. | |
