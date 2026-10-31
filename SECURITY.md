# Security policy

Docket holds a GitHub token and launches local processes, so security reports are taken seriously.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub: on this repository's **Security** tab, choose **Report a vulnerability**. Include the steps to reproduce, the affected version or commit, and the impact you expect.

You should get a response within a week. Fixes are released as soon as practical, and reporters are credited unless they prefer otherwise.

## Scope

In scope:

- Token exposure: the GitHub token leaving the Keychain, or appearing in logs, files, or prompts.
- Command or prompt injection through PR data such as titles, branch names, or repository contents.
- Isolation gaps when Claude Code sessions run on other people's PRs (for example a checkout's hooks or MCP servers loading).
- Unintended writes to GitHub.

Out of scope: vulnerabilities in GitHub, Claude Code, the Claude desktop app, or macOS themselves. Report those to their vendors.

## Supported versions

Only the latest commit on `main` is supported.
