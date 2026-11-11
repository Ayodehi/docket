# PR status model and notification rules

This document defines how raw GitHub data becomes the states shown in the app, and which state changes produce a notification. The rules engine implements this table directly; keep them in sync.

## 1. Inputs per PR

Collected each sync (see [GitHub integration](github-integration.md) for the query):

| Input | Source field | Values |
|---|---|---|
| Open, merged, closed | `state` | `OPEN`, `MERGED`, `CLOSED` |
| Draft | `isDraft` | bool |
| CI rollup | head commit `statusCheckRollup.state` | `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`, `EXPECTED`, or none |
| Individual checks | `statusCheckRollup.contexts` | check runs and commit statuses |
| Review decision | `reviewDecision` | `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or null (no review required by branch protection) |
| Latest review per reviewer | `latestOpinionatedReviews`, `latestReviews` | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` |
| Pending review requests | `reviewRequests` | users and teams |
| Merge state | `mergeable`, `mergeStateStatus` | `MERGEABLE`, `CONFLICTING`, `UNKNOWN`; `CLEAN`, `BLOCKED`, `BEHIND`, `DIRTY`, `UNSTABLE`, `HAS_HOOKS`, `DRAFT`, `UNKNOWN` |
| Unresolved threads | `reviewThreads.nodes.isResolved` | count |
| Head commit | `headRefOid`, commit `committedDate` | sha, time |
| Author | `author.login` | login |

## 2. Derived dimensions

### 2.1 My role

Computed per PR; a PR can have more than one role, and the highest one wins for display.

| Role | Condition | Rank |
|---|---|---|
| Author | `author.login == me` | 1 |
| Requested reviewer | `me` is in `reviewRequests` as a user | 2 |
| Team requested reviewer | a team I belong to is in `reviewRequests`, and I am not individually requested | 3 |
| Previous reviewer | I have a submitted review and am not currently requested | 4 |
| Watcher | PR is in a watched repo and none of the above | 5 |

### 2.2 CI status

| Display | Rule |
|---|---|
| Passing | rollup `SUCCESS` |
| Failing | rollup `FAILURE` or `ERROR` |
| Running | rollup `PENDING` or `EXPECTED` |
| None | no rollup (no checks configured) |

CI status is computed from the individual checks (any failing, else any running, else any passing, else none), keeping only the newest run of each check run per workflow and name. The rollup counts every run on the head commit, so a check that failed and then passed on a rerun leaves it at `FAILURE`, while GitHub's web UI shows the latest run. The rollup states above apply when there are no individual checks or when the detail query returned a full page of them (some may be missing). Changed 2026-11-02.

Required versus optional checks: v1 uses the rollup. A later version can mark which failing checks are required by branch protection.

Ignored checks: Settings > Inbox holds check name patterns (case-insensitive substring). When the list is not empty, CI status is always computed from the remaining checks, even when the page of checks is full. Ignored checks still appear, dimmed, in PR details. Added 2026-10-13 after one broken staging check marked 64 PRs as failing.

Check links (`detailsUrl`, `targetUrl`) are set by CI providers and by anyone who can post commit statuses. Only `http` and `https` links are kept; other schemes are dropped so a click cannot launch a local file or app.

### 2.3 Review status

| Display | Rule |
|---|---|
| Changes requested | `reviewDecision == CHANGES_REQUESTED`, or `reviewDecision` null and a latest opinionated review is `CHANGES_REQUESTED`, unless every reviewer whose latest opinionated review is `CHANGES_REQUESTED` has a pending review request again (re-requested); then Review required. GitHub keeps `CHANGES_REQUESTED` after a re-request. (Added 2026-11-11.) |
| Approved | `reviewDecision == APPROVED`, or `reviewDecision` null and a latest opinionated review is `APPROVED` (repos without required reviews) |
| Review required | `reviewDecision == REVIEW_REQUIRED` |
| Commented | `reviewDecision` null or `REVIEW_REQUIRED`, and at least one `COMMENTED` review since the last push |
| No reviews | none of the above |

### 2.4 Merge readiness

| Display | Rule |
|---|---|
| Conflicts | `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY` |
| Behind base | `mergeStateStatus == BEHIND` |
| Blocked | `mergeStateStatus == BLOCKED` (typically missing approvals or required checks) |
| Ready | `mergeStateStatus == CLEAN`, or `UNSTABLE` with only non-required checks failing |
| Draft | `isDraft` |
| Unknown | `UNKNOWN` (GitHub computes mergeability lazily; re-query on the next cycle) |

## 3. Primary state (what needs me)

Every open PR gets exactly one primary state. Evaluate top to bottom; the first match wins. "Mine" means my role is Author. "To review" means my role is Requested or Team requested reviewer.

| # | Primary state | Condition | Whose move | Inbox | Urgency |
|---|---|---|---|---|---|
| 1 | Review requested | To review, I have not reviewed since the request | Me | Yes | High |
| 2 | Re-review requested | To review, I reviewed or commented before, and the author re-requested me or pushed after my feedback; or I requested changes and the author pushed since | Me | Yes | High |
| 3 | Changes requested | Mine, review status Changes requested | Me | Yes | High |
| 4 | CI failing | Mine, CI Failing, not draft | Me | Yes | High |
| 5 | Conflicts | Mine, merge readiness Conflicts | Me | Yes | Medium |
| 6 | Ready to merge | Mine, Approved, CI Passing or None, merge readiness Ready | Me | Yes | Medium |
| 7 | New comments | Mine, and either new review comments or a Commented review, by anyone other than me or an ignored bot, since I last opened the PR in the app, or someone else's Commented or Changes requested review, conversation comment, or unresolved thread reply came after my last push and my last reply (review, conversation comment, or thread reply). The second part stays until I push or reply; ignored bots (Settings > Notifications) do not count. (Widened 2026-11-02 so a follow-up conversation comment is not lost behind Waiting for review.) | Me | Yes | Medium |
| 8 | Behind base | Mine, merge readiness Behind base, otherwise approved | Me | Yes | Low |
| 9 | Draft | Mine, draft | Me (when ready) | No | None |
| 10 | Waiting for review | Mine, Review required, CI Passing or Running | Others | No | None |
| 11 | CI running | Mine, CI Running | Others (CI) | No | None |
| 12 | Pending remediation | I gave feedback without approving and the author has not pushed since: my latest review is Changes requested, or my latest review or conversation comment came after the last push and after any approval of mine. Applies even while my review request is still open, since a conversation comment does not clear it on GitHub. (Renamed from Waiting on author and widened 2026-10-14.) | Others | No | None |
| 13 | Reviewed | Previous reviewer, no new activity requiring me | Others | No | None |
| 14 | Watching | Watcher | Others | No | None |
| 15 | Open | Mine, none of the above (for example approved and green but blocked by a required check) | Others | No | None |

Inbox sort order: urgency (High, Medium, Low), then time the PR entered the state, oldest first, so requests that have waited longest float up.

Inbox age rule: my own PRs not updated within a set number of days (Settings > Inbox, default 90, or any time) stay out of the Inbox and the menu bar count, though they remain in My PRs and repo views. Review requests (states 1 and 2) always count. Added 2026-10-13: 61 of 97 Inbox items on the measured account were authored PRs untouched for more than 90 days.

"Since I last opened the PR in the app" (state 7) starts from when Docket first saw the PR, so comments made before Docket was installed do not count as new. The first time a PR is seen, its state's start time is its last update time.

## 4. Notification rules

A notification fires on a **transition** into a state, never on the steady state. The rules engine compares the previous snapshot with the new snapshot for each PR and emits events.

| Event | Fires when | Default | Default sound | Actions |
|---|---|---|---|---|
| `reviewRequested` | PR enters state 1 | On | Distinct sound "Request" | Open, Review with Claude, Check out, Snooze |
| `reReviewRequested` | PR enters state 2 | On | "Request" | Open, Review with Claude, Snooze |
| `changesRequested` | PR enters state 3, or a new changes-requested review arrives while already in state 3 | On | "Attention" | Open, Address with Claude, Snooze |
| `ciFailed` | Mine, CI goes from Running or Passing to Failing | On | "Failure" | Open checks, Fix with Claude, Snooze |
| `ciRecovered` | Mine, CI goes from Failing to Passing | Off | Soft | Open |
| `approved` | Mine, a new approving review arrives | On | "Success" | Open |
| `readyToMerge` | PR enters state 6 | On | "Success" | Open, Merge (v1.1), Snooze |
| `conflicts` | PR enters state 5 | On | "Attention" | Open, Open terminal |
| `newComment` | Mine, a new review comment or Commented review by someone other than me or an ignored bot | On, coalesced | Soft | Open |
| `mentioned` | I am mentioned in a PR I am tracking (needs notifications endpoint, v1.1) | Off | Soft | Open |
| `prMerged` | A PR I authored is merged by someone else | Off | None | Open |
| `reviewDismissed` | My approving review was dismissed on someone else's PR | Off | None | Open |

When `approved` and `readyToMerge` fire in the same cycle, send only `readyToMerge`.

### 4.1 Suppression

A computed event is dropped when any of these is true:

- The actor is me (I pushed, I commented, I requested the review).
- The actor is in the ignored bots list, unless I am directly requested.
- The PR is snoozed or the repo is muted.
- Notifications are paused from the menu.
- The event was already delivered for the same PR, event type, and head sha (deduplication key, stored on disk).
- The PR is a draft, except for `reviewRequested` on drafts where someone explicitly requested me.
- It is the first sync after sign-in or after the cache was cleared. The first sync seeds the snapshot silently and shows a single summary: "You have N PRs that need attention."
- The PR is mine, was not updated within the Inbox age setting, and the event is not a review request.
- The PR is seen for the first time and is not a review request, unless I opened it within the last 24 hours. This covers PRs that appear late (an unhidden repo, detail arriving over several cycles) so they do not announce old state.
- The change came from a setting (ignored checks, marking a PR viewed) rather than from GitHub. Those changes move the baseline without notifying.

Logins in the ignored bots list match with or without a `[bot]` suffix, because GitHub's GraphQL API reports a bot as `claude` where REST and the web UI show `claude[bot]`. The same applies to `author:` rules for ignored PRs. Comments from ignored bots are removed from `newComment` events and from comment marks before counting; an event left with no comments is dropped. Hidden repos are never synced, so they produce no events.

### 4.2 Coalescing and notification style

Events produced within a 10 second window, or within one sync cycle, form a batch. Within a batch, several events on one PR always collapse into one notification for the most urgent event, with a subtitle listing the rest ("Also: 2 new comments").

How the batch is delivered depends on the notification style setting (N9):

| Style | Delivery |
|---|---|
| Smart (default) | Each High urgency event (`reviewRequested`, `reReviewRequested`, `changesRequested` by default) gets its own notification with actions. All other events in the batch go into one summary notification ("2 more updates: CI failed on cli#341, 2 comments on platform-api#1203") that opens the Inbox. If the batch has a single event, it is delivered individually regardless of urgency. |
| Every event | Each PR in the batch gets its own notification. |
| Summary only | One summary notification per batch ("3 PRs need you: 1 review request, 1 CI failure, 2 new comments"). Optionally, hold all summaries and deliver at scheduled digest times. |

Under Smart, each event type can be promoted to or demoted from High urgency in Settings. At most one sound plays per notification, and a batch never plays more than two sounds.

Notifications use `threadIdentifier = owner/repo` so macOS groups them per repo in Notification Center.

### 4.3 Sound

- Each event type maps to a sound name stored in settings. Sounds ship in the app bundle (short `.caf` files) plus the option of "System default" or "None".
- Sound plays as part of the notification so macOS Focus modes can silence it.
- A "Test" button next to each event type in Settings posts a sample notification.

### 4.4 Snooze and mute semantics

| Action | Effect |
|---|---|
| Snooze 1 hour / until tomorrow 9:00 | Suppresses notifications and hides the PR from the Inbox until the time passes. Shows it with a snooze indicator in other views. |
| Snooze until next change | Suppresses until the PR head sha, review decision, or CI rollup changes. |
| Mute repo | No notifications from the repo. PRs still appear in views. |
| Hide repo | Not synced at all and not shown anywhere. Restore from Settings. |
| Pause all | Global, from the menu bar. Inbox still updates. |

## 5. Examples

1. A teammate requests my review on `web-console#482`. Next sync: role becomes Requested reviewer, state 1, event `reviewRequested`, notification "Review requested: Add audit log filters to project view (web-console#482) by mchen".
2. I submit a changes-requested review. My role becomes Previous reviewer, state 12, no event.
3. The author pushes two commits. Head sha changes after my changes-requested review, state 2, event `reReviewRequested`.
4. On my PR `platform-api#1203`, CI finishes failing while a reviewer approves in the same cycle. Events `ciFailed` and `approved`; coalesced into one notification led by `ciFailed` ("CI failed on platform-api#1203. Also: approved by ppatel").
5. I fix CI and it goes green. `ciRecovered` is off by default; the PR enters state 6 and `readyToMerge` fires.
