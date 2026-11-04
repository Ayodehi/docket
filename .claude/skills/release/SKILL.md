---
name: release
description: Release Docket from main. Bumps the version from the latest GitHub Release, builds and notarizes the DMG, publishes the release with its update feed, and verifies that installed copies will see it.
argument-hint: --patch | --minor | --major
disable-model-invocation: true
---

# Release Docket

Run the whole release in `docs/releasing.md` for: `$ARGUMENTS`

Invoking this command is the user's go-ahead to push the version bump to `main` and publish the GitHub Release. Do not ask again, but stop and report at any failed check; never work around one. Never print, read, or ask for the notary password, the Developer ID key, or the Sparkle private key: the scripts read them from the Keychain.

Work from the repository root. `repo` below is `owner/repo` from the `origin` remote (the scripts use the same rule, or `DOCKET_RELEASE_REPO` if set).

## 1. Check the arguments and the checkout

1. The arguments must be exactly one of `--patch`, `--minor`, or `--major`. Otherwise stop and show the usage.
2. The current branch must be `main` and `git status --porcelain` must be empty.
3. `git fetch origin --tags`, then compare `main` with `origin/main`:
   - Behind only: `git pull --ff-only`.
   - Ahead or diverged: stop. List the unpushed commits and ask the user to push or drop them. Do not push them yourself.
4. Find the latest published release: `gh release view --repo <repo> --json tagName,isDraft`. If `git log --oneline <tag>..HEAD` is empty, stop: there is nothing to release.

**Resuming a failed run.** If `MARKETING_VERSION` in `project.yml` is already higher than the latest release and the last commit on `main` is its `Bump version to ...` commit, an earlier run stopped after step 2. Skip step 2 and continue at step 3 with that version. If a draft release for that version already exists, stop and ask the user whether to delete the draft; do not delete it yourself.

## 2. Bump the version

```bash
tools/bump_version.sh <the flag>
```

It prints `<version> <build>` and edits only `project.yml`. Check that `git diff` changes only `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, then commit on `main` with the message `Bump version to <version> (build <build>)` and push to `origin main`. Docket has no review gate, so the bump goes straight to `main`.

## 3. Build, notarize, and draft the release

```bash
tools/release.sh --publish
```

Run it in the background: building and two notarizations take 5 to 15 minutes. Wait for it to finish; do not poll. It must end with `Created draft release v<version>`. On any failure, show the relevant output and stop; the pushed bump stays, and running `/release` again resumes (step 1).

## 4. Write the release notes

Read the commits since the previous release (`git log --format='%h %s%n%b' <previous tag>..HEAD`, plus the merged PR descriptions with `gh pr view` where a commit names one). Write `dist/release-notes.md` (`dist/` is gitignored):

- User-visible changes only: what Docket now does or does differently, and bugs fixed as the user experienced them. Leave out docs, tests, refactors, tooling, the release script, and the version bump. No build numbers, image tags, commit hashes, or setup steps.
- Plain and specific, in the style of the README. No marketing words, emojis, or em or en dashes. Oxford comma.
- Use `## New`, `## Changed`, and `## Fixed`, each only if it has entries. If nothing is user-visible, write one line: `Internal improvements; no visible changes.`
- Never include real organization, repository, or person names from PR text; this repository is public.
- End with:

  ```markdown
  Installed copies update with **Docket > Check for Updates…**. To install, download `Docket-<version>.dmg`, open it, and drag Docket to Applications. Apple silicon only; on an Intel Mac, build from source. `Docket-<version>.dmg.sha256` holds the DMG's SHA-256 checksum.
  ```

## 5. Publish

```bash
gh release edit v<version> --repo <repo> --notes-file dist/release-notes.md --draft=false --latest
git fetch origin --tags
```

## 6. Verify that Check for Updates will see it

All must pass; report any that does not.

1. `gh release view v<version> --repo <repo> --json isDraft,isPrerelease,tagName,assets`: not a draft, not a prerelease, with `Docket-<version>.dmg`, its `.sha256`, and `appcast.xml` attached. `git rev-parse v<version>^{commit}` equals the bump commit.
2. The live feed (`curl -fsL https://github.com/<repo>/releases/latest/download/appcast.xml`) has `<sparkle:version><build></sparkle:version>` and `<sparkle:shortVersionString><version></sparkle:shortVersionString>`. GitHub can take a minute to switch `latest`; retry a few times before failing.
3. Download the DMG from the feed's `enclosure` URL into a new, empty folder in the scratchpad. Its `shasum -a 256` must match `dist/Docket-<version>.dmg`, and the feed's signature must verify:

   ```bash
   .build/Dist/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update --account docket --verify <downloaded dmg> <edSignature from the feed>
   ```

## 7. Report

Give the release link, version and build, the published notes, and the verification results. Tell the user that installed copies offer the update on **Docket > Check for Updates…**, or within a day if they turned on automatic checks.
