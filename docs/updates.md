# Updates

ohmai has no in-app updates and makes **no network requests at all**. That is a deliberate, settled choice: an updater would mean a network call, a third-party dependency next to a root helper, and a signing key to guard forever.

Releases are notarized disk images (`.dmg`) attached to the repo's GitHub releases (`mise run release`, then `mise run publish`), installed by hand. A Homebrew cask pointing at the same disk images would add updates via `brew` without any network code in ohmai.

## Replacing the app by hand

Verified 2026-11-14, builds 5 → 6 → 7:

- The lid helper's approval **survives** an in-place update (same path, same team and bundle id). So do launch at login and settings.
- The *running* helper process doesn't change by itself: launchd keeps the old binary running. From build 6 on, the helper compares the build number embedded in its file on disk with its own; if the file is newer, it turns sleep back on and exits cleanly, and launchd starts the new binary on ohmai's next request (verified: old helper released 21:58:46, new one started 21:59:09 and engaged 21:59:41). The check runs on requests, which XPC only delivers from callers that passed the code-signing check.
- Builds 1–5 lack that check, so moving off them needs the old helper stopped once (`sudo kill <pid>` or a reboot).
- Pitfall found on the way: two apps with the same bundle id (a Debug build and the installed release) make macOS's background-item record flip between them, so approvals don't stick. Debug builds use `com.westvold.ohmai.debug`, and the release script keeps no loose app copies.

## Version numbers

- `CFBundleShortVersionString` = marketing version (`0.1.0`)
- `CFBundleVersion` = a monotonically increasing build number (`CURRENT_PROJECT_VERSION`). Never reuse or decrease it: the helper's stale-binary check and the release script both rely on it going up.

## Release script

`scripts/release.sh` (`mise run release`; `mise run release-check` stops before uploading to Apple):

1. archive
2. Developer ID sign (app + helper, hardened runtime), verified: team, runtime flag, no `get-task-allow`, helper plist present
3. notarize (`notarytool --keychain-profile ohmai-notary`) + staple + Gatekeeper check. First accepted build: 0.1.0 (1), 2026-11-14.
4. disk image (`.dmg` with an Applications shortcut), itself signed, notarized and stapled (+ SHA-256). Releases were zips up to build 11.

It refuses a dirty tree and a build number not above the latest `build-*` tag.
