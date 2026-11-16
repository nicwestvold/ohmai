# Updates (Sparkle)

ohmai will update itself with [Sparkle 2](https://sparkle-project.org), the open-source (MIT) update framework most directly distributed Mac apps use. This doc covers how the app is prepared for it now, and what remains to wire it up later.

**Status: deferred (decided 2026-11-14).** v1 ships without Sparkle, so ohmai makes **no network requests at all**. Releases are notarized disk images (`.dmg`) attached to GitHub releases on the private `nicwestvold/ohmai` repo (`mise run release`, then `mise run publish`), installed by hand. The update *seam* and its no-op implementation stay in place.

Why: while ohmai is private and mostly used by its author, Sparkle's cost (a third-party dependency next to a root helper, an EdDSA key to guard forever, a public feed, and a network call that weakens the privacy promise) outweighs automatic updates. Revisit if ohmai goes open source or gains users who won't update by hand. A Homebrew cask is the step before Sparkle: updates via `brew`, still no network code in ohmai.

Moving later: a private repo's release assets can't be fetched without a token (never ship one in the app), so Sparkle needs a public feed. If the repo goes public, its existing releases become downloadable and the appcast can live there. (A separate public `ohmai-releases` repo was considered and deleted; if the source stays private but Sparkle is wanted, that pattern works: a public repo holding only zips and the appcast.)

**Replacing the app by hand (verified 2026-11-14, builds 5 → 6 → 7):**
- The lid helper's approval **survives** an in-place update (same path, same team and bundle id). So do launch at login and settings.
- The *running* helper process doesn't change by itself: launchd keeps the old binary running. From build 6 on, the helper checks the build number embedded in its file on disk whenever ohmai connects; if it's newer, it turns sleep back on and exits cleanly, and launchd starts the new binary on ohmai's next request (verified: old helper released 21:58:46, new one started 21:59:09 and engaged 21:59:41).
- Builds 1–5 lack that check, so moving off them needs the old helper stopped once (`sudo kill <pid>` or a reboot).
- Pitfall found on the way: two apps with the same bundle id (a Debug build and the installed release) make macOS's background-item record flip between them, so approvals don't stick. Debug builds now use `com.westvold.ohmai.debug`, and the release script keeps no loose app copies.

Everything below is the plan for when Sparkle is wired.

## Decisions

| Decision | Choice |
|---|---|
| Framework | Sparkle 2, via Swift Package Manager |
| Automatic checks | **On** by default (`SUEnableAutomaticChecks = true`); toggle in Settings |
| System profiling | **Off** (`SUEnableSystemProfiling = false`). The update check is ohmai's only network request. |
| Feeds | Two: `stable` and `preview` (betas), the same pattern Rex uses |
| Signing | Developer ID Application + notarization (paid Developer ID account), plus Sparkle EdDSA signatures on every update |
| Hosting | **Open.** See below. |

**Privacy promise** (for the README): "The only network request ohmai makes is checking its update feed, and you can turn that off."

## How Sparkle works

1. The app fetches an **appcast**: an XML feed listing versions, download URLs, release notes and an EdDSA signature for each archive.
2. If there's a newer version, Sparkle shows the standard update UI, downloads the archive, **verifies the EdDSA signature** against `SUPublicEDKey` in Info.plist, replaces the app and relaunches it.
3. Security comes from the signatures, not from keeping the feed secret. A public feed is safe.

## The seam: prepare now, so wiring later needs no refactor

The app talks to an `Updater` protocol, never to Sparkle directly:

```swift
@MainActor
protocol Updater: AnyObject {
    var canCheckForUpdates: Bool { get }          // drives the menu item's enabled state
    var automaticallyChecksForUpdates: Bool { get set }  // bound to the Settings toggle
    func checkForUpdates()                        // "Check for Updates…"
}

/// Ships until Sparkle is wired: the menu item is hidden and the toggle is disabled.
final class NoopUpdater: Updater {
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}

// Later, in its own file and the only one that imports Sparkle:
// final class SparkleUpdater: Updater { let controller: SPUStandardUpdaterController … }
```

- **Composition root:** the app picks the implementation at startup. A build setting, `OHMAI_UPDATES_ENABLED`, switches between `NoopUpdater` and `SparkleUpdater`, so dev builds never phone home.
- **UI:**
  - "Check for Updates…" appears in the dropdown's footer menu and the app menu only when `canCheckForUpdates` is true.
  - Settings → General has "Check for updates automatically", disabled with the note "Updates not available in this build" under the no-op updater.
- **Info.plist:** the Sparkle keys are added only when it's wired up. A `SUFeedURL` without Sparkle does nothing, but leaving it out keeps the plist honest.
- **Version numbers:** set them up correctly from the first commit, because Sparkle compares `CFBundleVersion`:
  - `CFBundleShortVersionString` = marketing version (`0.1.0`)
  - `CFBundleVersion` = a monotonically increasing build number, from CI or `agvtool`
  - Never reuse or decrease a build number.
- **Lid helper:** Sparkle replaces the whole `.app`, which includes the bundled helper. After an update, the app must check whether the registered helper is outdated and re-register it (`SMAppService` unregister + register) if its version changed. Plan the helper's XPC interface with a `version` call from the start.

## Hosting options (open decision)

The feed and archives must be **reachable** from wherever ohmai runs, but they don't have to be **public**.

| Option | How | Fits |
|---|---|---|
| Tailnet | Serve the appcast + archives from a machine on the user's Tailscale network | Personal use; truly private; updates only while connected |
| Public but unlisted | Public bucket or URL that isn't advertised (Rex does this for its preview feed) | Betas, small groups |
| Authenticated | Private storage + token sent via Sparkle's custom HTTP headers | Invite-only. The token ships in the app, so it's a gate, not real security. |
| GitHub Releases | Public repo releases, appcast attached or on Pages | Once open source |

Switching between them is just a change to `SUFeedURL`, plus where the release script uploads.

## Wiring checklist (later)

- [ ] Choose hosting, and create the `stable` and `preview` feed URLs
- [ ] Add the Sparkle 2 SPM package; add `SparkleUpdater` (`SPUStandardUpdaterController`)
- [ ] Generate the EdDSA key pair with Sparkle's `generate_keys`. The private key goes in the login Keychain plus a CI secret, **backed up**: losing it means existing installs can't verify updates.
- [ ] Info.plist: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks = true`, `SUEnableSystemProfiling = false`
- [ ] Preview builds: a separate scheme or config with the preview `SUFeedURL`. Alternatively, let users pick a channel via `feedURLString(for:)` / allowed channels.
- [ ] Release script (`scripts/release.sh`, `mise run release`; `mise run release-check` skips the upload):
  1. [x] archive
  2. [x] Developer ID sign (app + helper, hardened runtime), verified: team, runtime flag, no `get-task-allow`, helper plist present
  3. [x] notarize (`notarytool --keychain-profile ohmai-notary`) + staple + Gatekeeper check. First accepted build: 0.1.0 (1), 2026-11-14.
  4. [x] disk image (`.dmg` with an Applications shortcut), itself signed, notarized and stapled (+ SHA-256). Releases were zips up to build 11.
  5. [ ] `generate_appcast` (signs entries)
  6. [ ] upload archive + appcast
  - It refuses a dirty tree and a build number not above the latest `build-*` tag.
- [ ] Release notes: HTML or Markdown per version, referenced from the appcast
- [ ] Test an update: install an old build → publish a new one → confirm the update applies, the app relaunches, and the lid helper re-registers
- [ ] Optional: a Homebrew cask pointing at the same archives (`auto_updates true`, so brew doesn't fight Sparkle)
