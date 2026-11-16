# ohmai

A macOS menu bar app that shows your AI coding agents (Claude Code, Codex, pi) at a glance, and their token usage and estimated cost this month against last month. It can also prevent idle sleep while an agent works, with an opt-in lid-closed mode; that's deliberately secondary (Settings → Advanced, never mentioned in the dropdown or public descriptions). The name means "oh my ai" and nods to the ohm.

## Read first

- `docs/design.md`: v1 scope, domain terms, architecture, power policy, lid-closed mode, UI, icon, build order. **This is the source of truth.** If code and doc disagree, raise it; don't silently diverge.
- `docs/agent-integrations.md`: how each agent signals busy/idle and where usage data lives, with verified findings and open questions.
- `docs/updates.md`: no in-app updates, by design; manual updates, the helper's stale-binary restart, version numbers and the release script.

When a decision changes, update the relevant doc in the same change.

## Stack

- Swift 6 (strict concurrency), SwiftUI `MenuBarExtra`, `LSUIElement` (no Dock icon)
- macOS 26+, Xcode 27
- Not sandboxed (it reads `~/.claude`, `~/.codex`, `~/.pi`). Hardened runtime on.
- Swift Package Manager for dependencies. Keep them minimal: SQLite via the system library or a small wrapper.

## Identity and signing

| | Value |
|---|---|
| App bundle ID | `com.westvold.ohmai` |
| Lid helper bundle ID | `com.westvold.ohmai.lidhelper` |
| Team ID | `9UT6FTF6V6` (Westvold Development, LLC) |
| Release signing | Developer ID Application + notarization |

**Never hard-code the team ID in Swift.** It lives in an `.xcconfig` (`OHMAI_TEAM_ID`) and reaches code via Info.plist, so someone building from source can use their own. The lid helper's XPC caller check builds its code-signing requirement from that value.

## Architecture

The domain terms are in `docs/design.md`. Use them in type names.

| Domain | Role |
|---|---|
| **Agent**, **Session**, **Activity** | busy / waiting / idle / gone |
| **Lease** | time-boxed claim to stay awake |
| **Policy** | pure decision function |
| **Assertion** | IOKit / lid helper |
| **Ledger** | SQLite usage store |
| **Adapter** | one per agent |

Main components:
- `Policy`: **pure** `decide(leases:power:prefs:now:) -> Decision`. No I/O, fully unit-tested.
- `PowerMonitor` (IOKit power sources, Low Power Mode, thermal state) and `AssertionManager` (IOPMAssertion + lid helper client)
- Adapters turn hooks and file changes into `ActivityEvent`s and Ledger records. One adapter per agent, isolated from the others.

## Rules that matter

### Privacy
- ohmai reads transcripts that contain the user's code and prompts. Parsing code extracts **only** usage numbers and session metadata (agent, model, project path, timestamps, token counts).
- Never store, log or display message content.
- Keep all transcript parsing in one module whose public API returns only usage records.
- **No network calls. At all.** ohmai makes no network requests, and has no in-app updater (see `docs/updates.md`). Don't add analytics, crash reporting, remote price fetching, or update checks.

### Keeping the Mac awake safely
- Every lease must expire (signal timeout, pid liveness + start-time check).
- A bug that keeps the Mac awake forever is worse than one that lets it sleep. When in doubt, release.

### Lid helper (runs as root)
- Keep it tiny: `engage` / `renew` / `release` / `status` / `version` over XPC, and it only ever runs `pmset -a disablesleep 0|1`.
- **The dead-man switch is not optional:**
  - the lease expires → `disablesleep 0`
  - helper startup always resets to `disablesleep 0`
  - battery and thermal guards are enforced in the helper itself
- Never test `disablesleep` changes without a way to restore. Check with `pmset -g | grep -i sleepdisabled`.

### Undocumented agent signals
- `~/.claude/sessions/<pid>.json` (status: busy / idle / waiting) and the Codex rollout file formats are **undocumented** and can change in any agent release.
- Parse them defensively: unknown fields are ignored, and unknown values are logged once and treated as "unknown", never as busy forever.
- Cross-check with a second signal: for Claude, pid liveness plus transcript modification times. (No Claude hooks plugin in v1. Codex hooks are optional, for approval-waiting.)

### Version numbers
`CFBundleVersion` is a monotonically increasing build number (the helper's stale-binary check and the release script depend on it). Never reuse or decrease it.

### Releases
- `mise run release` runs `scripts/release.sh`: archive, Developer ID export, signature checks, notarize and staple the app, then a disk image (`.dmg`, with an Applications shortcut) that's signed, notarized and stapled too, plus its SHA-256. `mise run release-check` stops before uploading to Apple.
- Notarization credentials live in the login keychain as the notarytool profile `ohmai-notary` (override with `NOTARY_PROFILE`). Never put credentials in the repo.
- After a release, tag it `build-<N>` and bump `CURRENT_PROJECT_VERSION`.
- `mise run publish` attaches the disk image to a GitHub release on the `nicwestvold/ohmai` repo. It needs the `build-<N>` tag already pushed and never pushes anything itself; pushing is the user's call.

## Layout and build

| Path | What |
|---|---|
| `Packages/OhmaiCore` | Local Swift package. `OhmaiCore`: domain types, leases and `Policy`, Foundation only, no I/O. `OhmaiPower`: `PowerMonitor`, `AssertionManager` (IOKit), the lid helper client and `LidSession`. `OhmaiLidXPC`: the XPC contract. `OhmaiLidHelperCore`: everything the root helper does (`LidController` is the dead-man switch). `OhmaiPowerSource`: battery and thermal reading, shared with the helper. `OhmaiAdapterSupport`: pid liveness and start time, exit and directory watchers. `OhmaiClaudeAdapter`, `OhmaiCodexAdapter`, `OhmaiPiAdapter`: one adapter per agent, each its own target. Claude and pi share `StatusDirectoryAdapter` / `StatusRecordScanner` (per-process status files). pi's extension ships as a resource in `OhmaiPiAdapter`. `OhmaiUsage`: usage records, the bundled `prices.json`, month comparison. `OhmaiTranscripts`: **the only module that parses transcripts**; public API returns `UsageRecord`s only. `OhmaiLedger`: SQLite store and incremental importer. |
| `App/` | The app target: composition root, `AppModel`, SwiftUI views, helper registration |
| `LidHelper/` | The root helper's `main.swift` (wiring only), its Info.plist and launchd plist |
| `Config/*.xcconfig` | Signing, versions, `OHMAI_TEAM_ID`. Per-developer overrides go in `Config/Local.xcconfig` (gitignored). |
| `project.yml` | XcodeGen spec. `ohmai.xcodeproj` is generated, not committed. |

- Tools are pinned in `mise.toml` (xcodegen, gh, node); run `mise install` once. Tasks: `mise tasks`.
- `mise run test` runs the package tests (`swift test`); it's fast and needs no Xcode project.
- `mise run project` regenerates the Xcode project; `mise run build` builds the app. `mise run icons` regenerates the Ω artwork (needs `brew install librsvg`).
- Debug builds are `com.westvold.ohmai.debug`: own preferences, own `ledger-debug.sqlite`, and no lid helper (release-only). Never run two builds with the same bundle ID at once: macOS's background-item record for the helper flips between them and its approval won't stick.
- Debug builds read `OHMAI_CLAUDE_SESSIONS_DIR`, `OHMAI_CODEX_SESSIONS_DIR` and `OHMAI_PI_STATUS_DIR` to point the adapters at scratch directories, for manual testing without touching real agent data. `OHMAI_SNAPSHOT_DIR` renders the dropdown and Settings tabs to PNG (light and dark) and quits. `OHMAI_LEDGER_DB` points the usage ledger at a scratch database.
- Try the pi extension without installing it: `pi -p --no-session -e Packages/OhmaiCore/Sources/OhmaiPiAdapter/Resources/ohmai.ts "…"`.

## Testing

- `Policy` and lease logic: exhaustive unit tests, including battery thresholds, thermal state, waiting-lease cap and lid conditions.
- Adapters: test against **fixture files** built from real agent session files, with message content replaced by placeholders. Never commit real transcript content.
- When an agent's format changes, add a new fixture next to the old one, so both versions keep parsing.
- Don't change real system power state in tests. `AssertionManager` and the lid helper client sit behind protocols and are faked in tests.

## Conventions

- Commits: follow the global rules (conventional, atomic, one line, no attribution trailers).
- Build order is in `docs/design.md`. Work one step at a time, and keep each step shippable.
