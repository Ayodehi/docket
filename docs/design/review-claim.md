# Design note: assign and label on review start

| | |
|---|---|
| Status | Built; off by default. |
| Date | 2026-11-12 |
| Change type | New GitHub writes (assignees and labels), alongside the review actions in `review-actions.md` |

## 1. Summary

When Claude starts a review session on someone else's PR, Docket can assign me to the PR and add a label such as "In Review". When my review is posted, Docket removes the label it added. Each part is a setting under Settings > Account, and all are off until set.

## 2. Behavior

| Setting | Default | What it does |
|---|---|---|
| Assign me to the PR | Off | Adds me to the PR's assignees. Other assignees are kept. Docket never unassigns. |
| Add label | Empty (off) | Adds the named label. The label must already exist in the repository; Docket never creates labels. The name is matched case-insensitively. |
| Remove the label when my review is posted | On (only applies when a label is set) | Removes the label once a review by me, submitted after the session started, shows up in a sync. |

Trigger: a review session (prompt kind `review`) started from Docket in the terminal or the Claude desktop app, on a PR I did not author. Other session types, worktrees, and checkouts do not trigger it. The writes run after the session has started and never block it; problems are shown in one alert afterwards.

Label removal:

- Docket records a claim only when it added the label. A label that was already on the PR (put there by a teammate, or by me on GitHub) is left alone and never removed.
- "Posted" means a review by me in `latestReviews` or `latestOpinionatedReviews`, not `PENDING`, with a `submittedAt` later than my latest review at claim time (GitHub's clock on both sides, so local clock skew does not matter). Approve, request changes, and comment all count.
- PRs I reviewed stay in sync through the `reviewed-by:@me` search, so the review is seen on a normal cycle.
- A claim is dropped without a write when the PR is closed or merged, when the label is no longer on it, or after 14 days without seeing the PR.
- Turning off "Remove the label" drops all pending claims. Signing out clears them.
- Claims are stored in `review-claims.json` in Application Support: PR node ID, repo and number, label ID and name, and two dates. No PR text.

Claimed column: the Table view has a Claimed column naming who has claimed each PR. A PR counts as claimed when it carries the claim label from settings and has at least one assignee other than its author, whoever added them. The column shows "you" for me and is empty when no claim label is set. Assignees come from `assignees(first: 10)` in the detail query. The column is not sortable.

## 3. GitHub API

GraphQL, with every value passed as a variable. Field names were checked against the live schema on 2026-11-12.

| Step | Operation | Inputs |
|---|---|---|
| Lookup | `viewer { id }` and `repository(owner:, name:) { labels(first: 50, query:) }` | `owner`, `name`, label name. `label(name:)` is case-sensitive, so Docket searches and picks the case-insensitive exact match. |
| Assign | `addAssigneesToAssignable` | `assignableId`, `assigneeIds` (my node ID) |
| Add label | `addLabelsToLabelable` | `labelableId`, `labelIds` |
| Remove label | `removeLabelsFromLabelable` | `labelableId`, `labelIds` |

Each mutation returns the updated PR. Docket shows it right away and makes it that PR's notification baseline, as with review actions, so my own change does not notify.

## 4. Token permissions

Same as review actions: a classic token's `repo` scope already allows these writes; a fine-grained token needs Pull requests: write. If GitHub refuses, the alert says so and quotes GitHub's message.

## 5. Controls

1. **Off by default.** Nothing is written until I turn on assignment or enter a label name.
2. **Settings are the confirmation.** These writes are not confirmed per PR, since the point is to happen automatically on review start. The settings text says exactly what will be written.
3. **Validated values.** Node IDs use the same check as review actions. Label names are trimmed, 1 to 50 characters, with no control characters; repository owners must be valid logins. Anything else is rejected before a request.
4. **No PR text in requests.** Only node IDs, the repo name, and the label name from settings are sent.
5. **Retries.** Assignment and adding the label run once. Removing the label, which is idempotent, is tried again on the next sync after a network, server, or rate-limit error, up to 3 attempts; any other error stops it and is shown.
6. **Audit.** Each write is logged at `notice` (kept on disk) with the action and `owner/repo#number`. GitHub records each change on the PR timeline under my account.

## 6. Threats

| Threat | Mitigation |
|---|---|
| Stolen token | No new scope beyond review actions; fine-grained Pull requests: write is still the ceiling. |
| Removing someone else's label | Only labels Docket added are recorded for removal. |
| Unexpected writes on many PRs | Writes happen only on a review session I start, one PR at a time. |
| Injection through the label name | Sent only as a GraphQL variable; validated length and characters. |
