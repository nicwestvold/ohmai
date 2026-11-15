# Updates (Sparkle)

ohmai will update itself with [Sparkle 2](https://sparkle-project.org), the open-source (MIT) update framework most directly distributed Mac apps use. This doc covers how the app is prepared for it now, and what remains to wire it up later.

**Status:** prepared, not wired. The app ships with an update *seam* and a no-op implementation. Sparkle is added when there's a feed to point at.

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
- [ ] Release script (`scripts/release.sh`, `make release`; `make release-check` skips the upload):
  1. [x] archive
  2. [x] Developer ID sign (app + helper, hardened runtime), verified: team, runtime flag, no `get-task-allow`, helper plist present
  3. [x] notarize (`notarytool --keychain-profile ohmai-notary`) + staple + Gatekeeper check. First accepted build: 0.1.0 (1), 2026-11-14.
  4. [x] zip (+ SHA-256)
  5. [ ] `generate_appcast` (signs entries)
  6. [ ] upload archive + appcast
  - It refuses a dirty tree and a build number not above the latest `build-*` tag.
- [ ] Release notes: HTML or Markdown per version, referenced from the appcast
- [ ] Test an update: install an old build → publish a new one → confirm the update applies, the app relaunches, and the lid helper re-registers
- [ ] Optional: a Homebrew cask pointing at the same archives (`auto_updates true`, so brew doesn't fight Sparkle)
