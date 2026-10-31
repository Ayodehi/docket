# GitHub integration

How the app authenticates to GitHub, what it queries, and how it stays within rate limits. API details here reflect GitHub documentation at the time of writing; verify field names against the current GraphQL schema before implementing (`gh api graphql` with an introspection query, or the GitHub GraphQL Explorer).

## 1. Authentication

### 1.1 Options

| Option | How it works | Pros | Cons |
|---|---|---|---|
| Classic personal access token | User creates a token with scopes and pastes it | Simple; works with every endpoint including notifications | Broad scopes; org may block classic tokens; needs SSO authorization per org |
| Fine-grained personal access token | User creates a token limited to an org and repos with specific permissions | Least privilege; org admins can require approval | Per-org; notifications endpoint appears unsupported; must be re-created when it expires |
| Import from GitHub CLI | Run `gh auth token` once and store the result in our Keychain item | Zero setup if `gh` is signed in | Inherits `gh` scopes; ties us to another tool's credential |
| OAuth device flow | App shows a code, user approves in browser | Best UX; no token handling by the user | Needs a registered OAuth App (client ID); org may need to approve the app |

### 1.2 Decision for v1

- **Primary:** paste a token (classic or fine-grained). The setup screen explains both and links to the GitHub token pages with the right scopes pre-filled where GitHub supports it.
- **Convenience:** "Import from GitHub CLI" button (A8).
- **Later:** OAuth device flow (A9).

Required access:

| Capability | Classic scopes | Fine-grained permissions |
|---|---|---|
| Read PRs, reviews, checks (private repos) | `repo` | Pull requests: read; Checks: read; Commit statuses: read; Contents: read; Metadata: read |
| Resolve team review requests | `read:org` | Organization Members: read |
| Notifications trigger (optional) | `notifications` | Not supported (verify) |
| Merge, re-run CI (v1.1) | `repo`, `workflow` if re-running Actions | Pull requests: write; Contents: write; Actions: write |

v1 is read-only. Do not request write access until the v1.1 features ship, and make them opt-in.

### 1.3 Token lifecycle

1. On save, call `query { viewer { login } }` and read the `X-OAuth-Scopes` response header (classic tokens) to show what the token can do.
2. Store in the Keychain (see [Security and privacy](security-and-privacy.md)).
3. On any 401, stop polling, mark the account as needing re-authentication, and show it in the menu bar and main window.
4. On 403 with a SAML SSO message (the `X-GitHub-SSO` header carries an authorization URL), show "Authorize this token for <org>" with that link.

## 2. What to fetch

### 2.1 Discovery queries

Three searches find the PRs that involve me, across all repos the token can see. They run as aliases in a single GraphQL request.

| Alias | Search query | Why |
|---|---|---|
| `authored` | `is:pr is:open author:@me archived:false` | My PRs |
| `requested` | `is:pr is:open review-requested:@me archived:false` | Direct and team review requests |
| `reviewed` | `is:pr is:open reviewed-by:@me -author:@me archived:false` | PRs I reviewed; needed because submitting a review removes me from `review-requested`, and I still need to see re-review triggers |

Notes:

- `review-requested:@me` includes requests to my teams. `user-review-requested:@me` restricts to direct requests. The app uses the broader one and computes the role locally from `reviewRequests`.
- Search results can lag real state by up to about a minute. Treat search as discovery only. State for each PR comes from the PR fields in the same response, which are read from the PR itself.
- The `reviewed` query can grow over time on busy repos. It is split by `updated:` date into tiers (see 2.4) rather than cut off.

### 2.2 Watched repos

For each watched repo, query `repository(owner:, name:) { pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { ... } }`. Batch several repos per request using aliases.

### 2.3 PR fragment

Shared by all queries. Starting point; trim fields that the UI does not use.

```graphql
fragment PRFields on PullRequest {
  id
  number
  title
  url
  state
  isDraft
  createdAt
  updatedAt
  additions
  deletions
  changedFiles
  author { login avatarUrl }
  repository { nameWithOwner isArchived }
  headRefName
  headRefOid
  baseRefName
  headRepository { nameWithOwner }      # differs from repository for forks
  isCrossRepository
  reviewDecision
  mergeable
  mergeStateStatus
  labels(first: 10) { nodes { name color } }
  reviewRequests(first: 20) {
    nodes {
      requestedReviewer {
        __typename
        ... on User { login }
        ... on Team { slug organization { login } }
      }
    }
  }
  latestOpinionatedReviews(first: 20) {
    nodes { author { login } state submittedAt commit { oid } }
  }
  latestReviews(first: 20) {
    nodes { author { login } state submittedAt }
  }
  reviewThreads(first: 100) {
    totalCount
    nodes { isResolved comments(last: 1) { nodes { author { login } createdAt } } }
  }
  commits(last: 1) {
    nodes {
      commit {
        oid
        committedDate
        statusCheckRollup {
          state
          contexts(first: 50) {
            nodes {
              __typename
              ... on CheckRun { name status conclusion detailsUrl startedAt completedAt }
              ... on StatusContext { context state targetUrl createdAt }
            }
          }
        }
      }
    }
  }
}
```

### 2.4 Two-phase sync (as built)

Measured on 2026-10-13 against a real account (129 open authored PRs across 15 repos, 11 review requests):

- The single request above with `first: 50` fails with HTTP 502 (GitHub's roughly 10 second query timeout), and so does `first: 20`.
- The slow fields are `mergeable` and `mergeStateStatus`, which GitHub computes lazily per PR.
- Without them, 50 PRs per search costs 161 points per request, about 9,700 points per hour at 60 second polling. That is over the 5,000 point hourly limit.

So sync runs in two phases (`Sync` module, `SyncEngine`):

1. **Discovery.** Several searches as aliases `s0, s1, ...` in one request, each `first: 50` with cursor paging, using a small fragment: `id updatedAt headRefOid isDraft reviewDecision` and the head commit's `statusCheckRollup { state }`. About 2 points and 3 to 6 seconds per request.
2. **Detail.** `nodes(ids:)` with the full `PRFields` fragment from 2.3, in batches of 10 (about 11 points and 4.5 seconds per batch). Fetched only for PRs that are new, whose discovery summary changed, whose merge state is `UNKNOWN`, or whose detail is older than the tier's refresh interval. If a batch returns a 5xx, the batch size is halved for later cycles.

Discovery searches are split into tiers by `updated:` date so old PRs cost little:

| Tier | Searches | Discovery | Detail refresh when unchanged |
|---|---|---|---|
| Hot | `review-requested:@me` (no date limit); authored and reviewed with `updated:>=` 30 days ago | Every poll | 10 minutes |
| Warm | Authored and reviewed updated 30 to 90 days ago | 5 minutes | 30 minutes |
| Cold | Authored and reviewed updated more than 90 days ago | 30 minutes | 2 hours |

Any activity on a PR bumps `updatedAt`, which moves it into the hot search on the next poll. Slower tiers only delay changes that do not touch the PR itself, such as CI finishing or the base branch moving (which can change merge state).

A PR leaves the tracked set when a search whose date range covers its last known `updatedAt` stops returning it for every relationship (authored, requested, reviewed), or when a detail fetch shows it merged, closed, or gone. Changed PRs are fetched first, hot before cold, up to 10 batches per cycle; periodic refreshes are limited to 2 batches per cycle.

### 2.5 Team membership

To tell a direct request from a team request, fetch my teams once per hour:

```graphql
query { viewer { organizations(first: 20) { nodes { login teams(first: 100, userLogins: ["<me>"]) { nodes { slug } } } } } }
```

## 3. Rate limits and polling

- GraphQL allows 5,000 points per hour for a user token (verify current limits). Each response includes `rateLimit { cost remaining resetAt }`; log the cost and show it in a debug panel.
- With the two-phase, tiered sync in 2.4, the estimate for the measured account is about 600 points per hour at 60 second polling (about 12 percent), mostly from periodic detail refreshes of hot PRs. The limit is per user, so `gh` and other tools using the same account share it.
- Adaptive schedule:

| Condition | Interval |
|---|---|
| Main window or menu open | 30 seconds |
| Normal | User setting, default 60 seconds |
| User idle more than 10 minutes | 5 minutes |
| Low Power Mode or on battery below 20 percent | 5 minutes |
| Asleep, screen locked | Paused; refresh on wake or unlock |
| Offline | Paused; refresh on reconnect (Network framework path monitor) |
| `remaining` below 10 percent | Slow to 10 minutes until `resetAt` |
| Secondary rate limit or 403 with `Retry-After` | Wait the given time, then exponential backoff |

- On any HTTP error, keep the last good snapshot and mark it stale in the UI.

### 3.1 Optional change trigger (v1.1)

The REST endpoint `GET /notifications` supports conditional requests with `If-Modified-Since` and returns `X-Poll-Interval`. A `304 Not Modified` response does not count against the rate limit. When the token supports it (classic token with `notifications` scope), the app can poll it every `X-Poll-Interval` seconds and run the full GraphQL sync only when something changed, plus a slower safety sync (every 5 minutes). This lowers latency and cost. It is an optimization, not a dependency, because CI status changes do not always produce notifications.

## 4. Webhooks

Not used. Webhooks need a public endpoint, and a desktop app should not run one. Polling with adaptive intervals is sufficient for a single user.

## 5. Write operations (v1.1, opt-in)

| Action | API |
|---|---|
| Merge | GraphQL `mergePullRequest(input: {pullRequestId, mergeMethod})` honoring the repo's allowed methods |
| Auto-merge when ready | GraphQL `enablePullRequestAutoMerge` (requires auto-merge enabled on the repo) |
| Re-run failed jobs | REST `POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs` |
| Update branch | REST `PUT /repos/{owner}/{repo}/pulls/{number}/update-branch` |

All write actions require a confirmation step in the UI and must respect branch protection. The app never offers to bypass required reviews or checks.

## 6. Testing against the API

- Record real responses (with private data replaced by fictional values) as JSON fixtures for the parser and rules engine tests.
- A `GitHubClient` protocol lets tests inject a fake client that returns scripted snapshot sequences, which is how the notification transition tests run.
