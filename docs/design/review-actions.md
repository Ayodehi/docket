# Design note: review actions from Docket

| | |
|---|---|
| Status | Built; off by default. |
| Date | 2026-10-14 |
| Change type | First write access from Docket to GitHub (integration change) |

## 1. Summary

Add three actions to the PR detail pane: request reviewers, re-request reviews, and dismiss a review. Today Docket is read-only against GitHub by rule (`CLAUDE.md`, PRD section 5.2), so this is the first time it would change data on GitHub.

## 2. Scope

| Action | What it does on GitHub | Who GitHub allows |
|---|---|---|
| Request reviewers | Adds users or teams to a PR's requested reviewers | Anyone with write access to the repo |
| Re-request review | Asks a reviewer who already reviewed to review again (shows as a re-request on GitHub) | Anyone with write access to the repo |
| Dismiss a review | Voids an approving or changes-requested review, with a required reason that appears on the PR | Repo admins and people with write access; branch protection can restrict this to specific people or teams |

Out of scope: removing a pending review request, approving or commenting, merging, re-running CI, and any change to branch protection. Each would need its own review.

Permissions and roles above were checked on 2026-10-14 against GitHub's docs ("Dismissing a pull request review", "About protected branches", "Permissions required for fine-grained personal access tokens") and the live GraphQL schema.

## 3. GitHub API

All three use GraphQL with values passed as variables, never interpolated into the query text.

| Action | Mutation | Inputs |
|---|---|---|
| Request | `requestReviewsByLogin` | `pullRequestId`, `userLogins`, `teamSlugs` (`org/slug`), `union: true` |
| Re-request | `rerequestReviews` | `pullRequestId`, `userIds`, `teamIds` (node IDs) |
| Dismiss | `dismissPullRequestReview` | `pullRequestReviewId`, `message` (required) |

`union` must always be `true`. Without it, `requestReviewsByLogin` replaces the PR's whole reviewer list, which would silently remove other people's requests.

Data Docket would add to its existing detail query: review node IDs, and reviewer and team node IDs. These are a few fields per PR. Reviewer suggestions come from `suggestedReviewers`, fetched only when the picker opens, not on every sync.

## 4. Token permissions

| Token | Today | With this change |
|---|---|---|
| Classic | `repo`, which already includes write | No change to scopes; the token already allows these actions |
| Fine-grained | Pull requests: read | Pull requests: **write**. All other permissions stay read-only. |

A fine-grained token limited to the owners you review for, with Pull requests write, is the smallest grant that allows these actions. It cannot push code, merge, or change settings.

## 5. Controls

1. **Off by default.** A setting, "Allow Docket to change reviews on GitHub", under Settings > Account. While off, the controls are hidden and the write code path is never reached.
2. **Confirm every write.** Each action shows a confirmation naming the PR (repo and number), the action, and the people or teams affected. No bulk actions across PRs.
3. **Dismissal reason is typed by the user.** The field starts empty; Docket never pre-fills it from PR text. It is sent as a GraphQL variable.
4. **Validated identifiers.** User logins must match GitHub's login format (letters, digits, and single hyphens, up to 39 characters); team slugs must be `org/slug` from data GitHub returned. Anything else is rejected before a request is made.
5. **No automatic retries for writes.** On any error the user sees the message and decides whether to try again. This avoids duplicate requests.
6. **GitHub stays the authority.** Docket does not try to predict permissions; a 403 or 422 from GitHub is shown as is (for example "branch protection restricts who can dismiss reviews").
7. **Audit.** Each write is logged at `notice` level (kept on disk): action, `owner/repo#number`, and the count of people affected. Logins are logged with `privacy: .private`. GitHub records each action on the PR timeline under the user's account.
8. **No PR text in actions.** Titles and bodies are shown only as plain text in the confirmation. They are never part of a request.

## 6. Notifications

Requesting and re-requesting reviewers create no event for the user under the current rules: the user is not the one being asked to review.

Dismissing a review can change the PR's state. Dismissing the only changes-requested review on the user's own approved, green PR moves it to Ready to merge, which would notify. As built, each mutation returns the updated PR; Docket shows it right away and makes it that PR's notification baseline, so the user's own change does not notify. Changes by other people after that notify as usual. A sync that started before the action cannot overwrite the newer result.

## 7. Threats

| Threat | Before | After | Mitigation |
|---|---|---|---|
| Stolen token | Read access to PRs the token covers | Plus: request reviewers and dismiss reviews on those PRs | Fine-grained token limited to Pull requests write; Keychain storage unchanged; token revocable on GitHub |
| Accidental or repeated action | n/a | Wrong reviewers requested, or a valid review dismissed | Off by default, per-action confirmation, single PR per action, no automatic retries |
| Injection through identifiers | n/a | A crafted login or slug altering a request | Validation in section 5.4; GraphQL variables only |
| Bypassing review requirements | n/a | Dismissing a changes-requested review to unblock a merge | GitHub enforces branch protection and dismissal restrictions; Docket cannot merge; dismissals are visible on the PR with the reason and the user's name |
| Misleading confirmation text | n/a | A PR title crafted to look like a different action | Confirmation states the action and identifiers from Docket's own data; the title is shown separately as quoted text |

## 8. Changes on approval

- `CLAUDE.md` rule becomes: read-only against GitHub except the opt-in review actions in this note.
- PRD: new requirements for the three actions; v1.1 table updated.
- `security-and-privacy.md`: token section and threat table.
- `github-integration.md`: section 5 (write operations) gains these mutations; Settings > Account sign-in text lists Pull requests write as optional.

## 9. Tests

- Unit: login and slug validation, including hostile values; request building always sets `union: true`; variables carry all user input.
- Client: stubbed transport for success, 403 (no permission), 422 (branch protection or invalid reviewer), with no retry on failure.
- Rules engine: no notification to the user after each of the three actions.
- Manual: each action on a test PR in a non-production repo before first use on real PRs.

## 10. Questions for the reviewer

1. Is dismissing reviews acceptable from a desktop tool, or should it stay GitHub-only?
2. Does the org approve fine-grained tokens with Pull requests write for this purpose (PRD open question R1)?
3. Is the audit in section 5.7 sufficient, given that GitHub also records each action on the PR?
4. Is suppressing notifications for one sync after a user's own action (section 6) acceptable, or should those notifications still fire?
