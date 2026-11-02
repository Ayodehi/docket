# Design note: self-update from GitHub Releases

| | |
|---|---|
| Status | Built; checks are manual until you opt in. |
| Date | 2026-11-02 |
| Change type | New network host and the first third-party dependency (integration change) |

## 1. Summary

Add **Check for Updates…** to the Docket menu and to Settings > General. It downloads the latest published release from GitHub, verifies it, replaces the app, and relaunches. It uses [Sparkle](https://sparkle-project.org) 2, the standard updater for Mac apps distributed outside the App Store, with the update feed and DMG hosted on GitHub Releases.

Until now Docket talked to `api.github.com` only and had no dependencies (`docs/security-and-privacy.md` section 3). This note records what changes.

## 2. Scope

- Release builds made by `tools/release.sh` only. Source builds (`tools/install.sh`, Xcode) have no update feed, so the menu item and settings are hidden and Sparkle never starts. They keep updating with `git pull` and `tools/install.sh`.
- Check for Updates… always works in a release build. Sparkle asks once, on the second launch, whether to check automatically; automatic checks run once a day only if you say yes, and Settings > General can turn them on or off.
- Every update is shown to you before it installs. Out of scope: silent background installs, beta or prerelease channels, delta updates, and Intel builds.

## 3. How an update works

1. `tools/release.sh --publish` writes `appcast.xml`, a one-item RSS feed describing the release: version, build number, minimum macOS, DMG URL, size, and an EdDSA signature of the DMG. It is attached to the GitHub Release next to the DMG.
2. The app's feed URL is `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`. GitHub resolves `latest` to the newest published release; drafts and prereleases are skipped, so nothing is offered until you publish.
3. Sparkle fetches the feed and compares the feed's `sparkle:version` with the running app's `CFBundleVersion`. That is why `CURRENT_PROJECT_VERSION` must increase with every release.
4. If it is newer, Sparkle shows the version and a link to the release notes on GitHub. If you choose Install, it downloads the DMG, then installs only if both checks pass:
   - The DMG's EdDSA signature verifies against the public key built into the running app (`SUPublicEDKey`).
   - The new app's Apple code signature is valid and comes from the same Developer ID team as the running app.
5. Sparkle's installer replaces `Docket.app` in place and relaunches it. If the app's folder is not writable, macOS asks for an administrator password.

Settings, the Keychain token, and Launch at login are untouched, since the bundle ID and signing team stay the same.

## 4. Network and data

| Request | Host | When |
|---|---|---|
| Update feed | `github.com`, redirecting to `objects.githubusercontent.com` | On Check for Updates…, or daily if you opted in |
| DMG download | Same | Only after you choose Install |

Requests are anonymous HTTPS GETs and carry no GitHub token. Sparkle's system profile, which can send hardware and OS details with the feed request, stays off (`SUEnableSystemProfiling` is not set; it defaults to off). GitHub sees the requester's IP address and user agent, as for any download.

## 5. Keys and secrets

- The EdDSA private key is created once with Sparkle's `generate_keys`, which stores it in the release Mac's login Keychain. It never enters the repository, CI, or logs. `release.sh` signs with Sparkle's `sign_update`, which reads it from the Keychain.
- The public key is committed in `project.yml` (`SPARKLE_PUBLIC_KEY`). It is public by design.
- Losing the private key means existing installs cannot verify new updates; users would have to download the next release by hand. Back it up with `generate_keys --account docket -x <file>` to an encrypted location of your choice.
- A stolen private key alone cannot ship an update: the new app must also be signed by the same Developer ID team. Both would have to be compromised.

## 6. Dependency

- Sparkle 2.10.1 (October 2026), pinned to an exact version in `project.yml` and fetched by Swift Package Manager. SwiftPM checks the binary framework against the checksum in Sparkle's package manifest.
- Upgrade deliberately: read the release notes, bump the pin, and run a test update (section 8) before releasing.
- Sparkle's embedded helpers (`Autoupdate`, `Updater.app`, and its XPC services) are re-signed by `release.sh` with the Developer ID identity, hardened runtime, and a secure timestamp, as notarization requires.

## 7. Threats

| Threat | Mitigation |
|---|---|
| Tampered DMG or feed on the network | HTTPS, plus EdDSA signature check against the built-in public key |
| Compromised GitHub account publishes a malicious release | The attacker also needs the EdDSA private key and the Developer ID certificate, which live only on the release Mac |
| Downgrade to an older, vulnerable release | Sparkle only offers builds with a higher `CFBundleVersion` than the running app |
| A release replaces someone's source build | Source builds have no feed and never start the updater |
| Feed request tracks users | No token, no system profile, manual unless you opt in |

## 8. Testing an update

`tools/release.sh --test-update` builds two copies under a separate bundle ID (`io.github.docket.test.Docket`), so the test has its own settings, Keychain entry, and login item:

- an older copy (build number lowered by one) whose feed points at a local HTTP server, and
- a newer copy, packaged as a DMG with a signed `appcast.xml` that the local server serves.

Both are Developer ID signed but not notarized, which is fine on the Mac that built them. Launch the older copy, choose Check for Updates…, install, and confirm the newer version relaunches.
