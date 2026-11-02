# Docket documentation

Docket is a native macOS menu bar app that watches your GitHub pull requests, tells you when one needs you (review requested, changes requested, CI failed, ready to merge), and gets you from the alert to working on the PR, including starting a Claude Code session on the right repo and branch.

| Document | What it covers |
|---|---|
| [PRD](PRD.md) | Problem, goals, scope, user stories, requirements, risks, open questions |
| [Architecture](architecture.md) | Platform choices, modules, data flow, persistence, signing and entitlements, testing |
| [GitHub integration](github-integration.md) | Authentication options, GraphQL queries, rate limits and polling, write operations for v1.1 |
| [PR status model and notification rules](status-model-and-notifications.md) | How GitHub data maps to states, which transitions notify, suppression and coalescing |
| [Local workspace and Claude Code integration](local-workspace-integration.md) | Repo discovery, checkout and worktrees, terminal and editor launching, Claude prompt templates |
| [Security and privacy](security-and-privacy.md) | Token handling, process execution rules, data handling, what distributing builds would require |
| [Releasing](releasing.md) | Versioning, signing and notarization setup, and the release checklist |
| [Roadmap and milestones](roadmap.md) | M0 to M6 for v1, then v1.1 and later candidates |
| [UX options](ux-options.md) | Layout options, the recorded decision, and how the List, Board, Table, and Compact view modes work |
| [Design note: review actions](design/review-actions.md) | Request, re-request, and dismiss reviews from Docket (opt-in, off by default) |

These documents are the original design spec, written in the first person by the author. Dated notes record later changes. The setup guide for users is the [README](../README.md) at the repository root.
