# Releasing Docket

Releases are built locally by `tools/release.sh` and published as a GitHub Release with a `.dmg` and a Sparkle update feed (`appcast.xml`) attached. Installed release builds find new versions through that feed ([Design note: self-update](design/self-update.md)). Release builds are Apple silicon (arm64) only, signed with a Developer ID certificate, and notarized, so Gatekeeper opens them on other Macs without a warning.

Nothing secret lives in the repository. The script reads the signing identity, notary credential, and update signing key from your keychain and the environment, and command-line build settings override `Config/Local.xcconfig`, so a personal development setup does not end up in a release.

## Version

The version is set in `project.yml`, in the `Docket` target's settings:

- `MARKETING_VERSION`: the version users see, such as `0.2.0`. The release tag is `v` plus this value.
- `CURRENT_PROJECT_VERSION`: the build number. Increase it for every build you ship: installed copies only offer an update whose build number is higher than their own, and the script refuses to build a release whose build number is not higher than the latest published one.

`Info.plist` takes both from these settings. `tools/bump_version.sh --patch` (or `--minor`, `--major`) sets both for the next release: the version counts from the latest published GitHub Release, and the build number goes one past the published one.

## One-time setup

1. Join the Apple Developer Program, then create a **Developer ID Application** certificate (Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application). Check that it is in your login keychain:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Store a notary credential in your keychain under the profile name `docket-notary`. This prompts for your Apple ID, team ID, and an app-specific password (create one at account.apple.com); the values stay in the keychain:

   ```bash
   xcrun notarytool store-credentials docket-notary
   ```

3. Create the EdDSA key that signs updates. Sparkle's tools are downloaded with the package on the first build (any `tools/release.sh` run), then:

   ```bash
   .build/Dist/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account docket
   ```

   This stores the private key in your login keychain and prints the public key. Put the public key in `project.yml` as `SPARKLE_PUBLIC_KEY` (it is public by design) and commit it. Back up the private key with `generate_keys --account docket -x <file>` to encrypted storage of your choice, and keep it out of the repository. If the key is lost, installed copies cannot verify new updates, and users have to download the next release by hand.
4. Install and sign in to the [GitHub CLI](https://cli.github.com) (`gh auth login`) with permission to create releases on the repository.

Environment variables, all optional:

| Variable | Default | Purpose |
|---|---|---|
| `DOCKET_SIGN_IDENTITY` | `Developer ID Application` | Codesigning identity. Set the full name if you have more than one Developer ID certificate. |
| `DOCKET_NOTARY_PROFILE` | `docket-notary` | `notarytool` keychain profile |
| `DOCKET_SPARKLE_ACCOUNT` | `docket` | Keychain account of the update signing key |
| `DOCKET_BUNDLE_ID_PREFIX` | `io.github.docket` | Bundle ID prefix for the release build |
| `DOCKET_RELEASE_REPO` | the `origin` remote | GitHub `owner/repo` that hosts releases and the update feed |

## Dry run

An ad hoc build needs no certificate and is not notarized. Use it to check packaging:

```bash
tools/release.sh --adhoc
```

This writes `dist/Docket-<version>-adhoc.dmg` and a `.sha256` file next to it. To check it, open the DMG and launch Docket from it. The dry run uses the default bundle ID `io.github.docket.Docket`, so it has its own settings and Keychain entry and does not touch an installed copy built with your own bundle ID prefix. Do not distribute an ad hoc DMG; on other Macs Gatekeeper blocks it. Ad hoc builds have no update feed, so Check for Updates… is hidden.

## Testing an update

Run this after changing the updater or upgrading Sparkle:

```bash
tools/release.sh --test-update
```

It builds two Developer ID signed copies with the bundle ID `io.github.docket.test.Docket`, so the test has its own settings, Keychain entry, and login item: an old copy (version 0.0.1, build 1) in `dist/test-update/Docket.app`, and a newer copy packaged as `dist/test-update/Docket-test.dmg` with a signed `appcast.xml`. Neither is notarized, which is fine on the Mac that built them.

1. Serve the feed: `python3 -m http.server 8765 --bind 127.0.0.1 --directory dist/test-update`
2. Open `dist/test-update/Docket.app`. It asks for a token; you do not need one for this test.
3. Choose Docket > Check for Updates…, then Install Update and Install and Relaunch. The relaunched app should report the project's version in Docket > About Docket.
4. Quit the test copy, stop the server, and remove `dist/test-update` and `defaults delete io.github.docket.test.Docket`.

To upgrade Sparkle, read its release notes, change `exactVersion` in `project.yml`, and run this test before releasing.

## Releasing with Claude Code

In Claude Code, run this from an up-to-date, clean `main`:

```
/release --patch
```

Use `--minor` or `--major` for those parts. The command (`.claude/skills/release/SKILL.md`) runs the checklist below without stopping: it bumps the version, commits and pushes the bump to `main`, builds and notarizes, writes release notes covering user-visible changes, publishes the release, and checks that the live update feed and DMG verify. It stops at the first failed check; running it again after a failure picks up from the pushed bump.

## Release checklist

1. On an up-to-date, clean `main`, bump the version, then commit and push it:

   ```bash
   tools/bump_version.sh --patch
   git commit -am "Bump version to <version> (build <build>)"
   git push origin main
   ```

2. Build, notarize, and create a draft release:

   ```bash
   tools/release.sh --publish
   ```

   The script signs the app and Sparkle's helpers with the hardened runtime and a secure timestamp, notarizes and staples the app, packages it into `dist/Docket-<version>.dmg`, signs, notarizes, and staples the DMG, and checks it with `spctl`. It then writes `dist/appcast.xml` with the DMG's EdDSA signature and creates a draft GitHub Release `v<version>` targeting the current commit, with the DMG, its SHA-256 checksum, and the feed attached and notes generated from merged pull requests. It refuses to run with uncommitted changes, with a commit that is not pushed, or if the tag or release already exists. Notarization usually takes a few minutes.

   Without `--publish`, the script stops after writing the DMG and feed.
3. Download the DMG from the draft on another Mac if you can, open it, drag Docket to Applications, and launch it.
4. Edit the draft's notes so they describe user-visible changes only, then publish it on GitHub or with `gh release edit v<version> --draft=false --latest`. Publishing creates the tag and makes it the latest release, so installed copies offer it the next time they check.
