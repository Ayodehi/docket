# Releasing Docket

Releases are built locally by `tools/release.sh` and published as a GitHub Release with a `.dmg` attached. Release builds are Apple silicon (arm64) only, signed with a Developer ID certificate, and notarized, so Gatekeeper opens them on other Macs without a warning.

Nothing about signing lives in the repository. The script reads the signing identity and notary credential from your keychain and the environment, and command-line build settings override `Config/Local.xcconfig`, so a personal development setup does not end up in a release.

## Version

The version is set in `project.yml`, in the `Docket` target's settings:

- `MARKETING_VERSION`: the version users see, such as `0.2.0`. The release tag is `v` plus this value.
- `CURRENT_PROJECT_VERSION`: the build number. Increase it for every build you ship.

`Info.plist` takes both from these settings. Bump them in a pull request before you release.

## One-time setup

1. Join the Apple Developer Program, then create a **Developer ID Application** certificate (Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application). Check that it is in your login keychain:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Store a notary credential in your keychain under the profile name `docket-notary`. This prompts for your Apple ID, team ID, and an app-specific password (create one at account.apple.com); the values stay in the keychain:

   ```bash
   xcrun notarytool store-credentials docket-notary
   ```

3. Install and sign in to the [GitHub CLI](https://cli.github.com) (`gh auth login`) with permission to create releases on the repository.

Environment variables, all optional:

| Variable | Default | Purpose |
|---|---|---|
| `DOCKET_SIGN_IDENTITY` | `Developer ID Application` | Codesigning identity. Set the full name if you have more than one Developer ID certificate. |
| `DOCKET_NOTARY_PROFILE` | `docket-notary` | `notarytool` keychain profile |
| `DOCKET_BUNDLE_ID_PREFIX` | `io.github.docket` | Bundle ID prefix for the release build |

## Dry run

An ad hoc build needs no certificate and is not notarized. Use it to check packaging:

```bash
tools/release.sh --adhoc
```

This writes `dist/Docket-<version>-adhoc.dmg` and a `.sha256` file next to it. To check it, open the DMG and launch Docket from it. The dry run uses the default bundle ID `io.github.docket.Docket`, so it has its own settings and Keychain entry and does not touch an installed copy built with your own bundle ID prefix. Do not distribute an ad hoc DMG; on other Macs Gatekeeper blocks it.

## Release checklist

1. Complete a security review of the changes since the last release against [Security and privacy](security-and-privacy.md). Do not publish a release before it passes.
2. Merge a pull request that bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
3. On an up-to-date, clean `main`, build, notarize, and create a draft release:

   ```bash
   tools/release.sh --publish
   ```

   The script signs the app with the hardened runtime and a secure timestamp, notarizes and staples the app, packages it into `dist/Docket-<version>.dmg`, signs, notarizes, and staples the DMG, and checks it with `spctl`. It then creates a draft GitHub Release `v<version>` targeting the current commit, with the DMG and its SHA-256 checksum attached and notes generated from merged pull requests. It refuses to run with uncommitted changes or if the tag or release already exists. Notarization usually takes a few minutes.

   Without `--publish`, the script stops after writing the DMG.
4. Download the DMG from the draft on another Mac if you can, open it, drag Docket to Applications, and launch it.
5. Edit the draft's notes so they describe user-visible changes only, then publish it on GitHub or with `gh release edit v<version> --draft=false`. Publishing creates the tag.
