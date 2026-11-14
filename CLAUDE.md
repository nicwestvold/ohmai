# ohmai

A macOS menu bar app. It keeps the Mac awake while AI coding agents (Claude Code, Codex, pi) are working, and shows token usage for this month compared with last month. The name means "oh my ai" and nods to the ohm.

## Read first

- `docs/design.md`: v1 scope, domain terms, architecture, power policy, lid-closed mode, UI, icon, build order. **This is the source of truth.** If code and doc disagree, raise it; don't silently diverge.
- `docs/agent-integrations.md`: how each agent signals busy/idle and where usage data lives, with verified findings and open questions.
- `docs/updates.md`: the Sparkle plan. It sits behind an `Updater` seam and isn't wired yet.

When a decision changes, update the relevant doc in the same change.

## Stack

- Swift 6 (strict concurrency), SwiftUI `MenuBarExtra`, `LSUIElement` (no Dock icon)
- macOS 26+, Xcode 27
- Not sandboxed (it reads `~/.claude`, `~/.codex`, `~/.pi`). Hardened runtime on.
- Swift Package Manager for dependencies. Keep them minimal: Sparkle later, SQLite via the system library or a small wrapper.

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
- `Policy`: **pure** `decide(leases:power:prefs:) -> Decision`. No I/O, fully unit-tested.
- `PowerMonitor` (IOKit power sources, Low Power Mode, thermal state) and `AssertionManager` (IOPMAssertion + lid helper client)
- Adapters turn hooks and file changes into `ActivityEvent`s and Ledger records. One adapter per agent, isolated from the others.
- `Updater` protocol, with `NoopUpdater` until Sparkle is wired. Only `SparkleUpdater` may import Sparkle.

## Rules that matter

### Privacy
- ohmai reads transcripts that contain the user's code and prompts. Parsing code extracts **only** usage numbers and session metadata (agent, model, project path, timestamps, token counts).
- Never store, log or display message content.
- Keep all transcript parsing in one module whose public API returns only usage records.
- **No network calls**, except Sparkle's update check once it's wired. Don't add analytics, crash reporting, or remote price fetching.

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
- Hooks are the cross-check.

### Version numbers
`CFBundleVersion` is a monotonically increasing build number (Sparkle depends on it). Never reuse or decrease it.

## Testing

- `Policy` and lease logic: exhaustive unit tests, including battery thresholds, thermal state, waiting-lease cap and lid conditions.
- Adapters: test against **fixture files** built from real agent session files, with message content replaced by placeholders. Never commit real transcript content.
- When an agent's format changes, add a new fixture next to the old one, so both versions keep parsing.
- Don't change real system power state in tests. `AssertionManager` and the lid helper client sit behind protocols and are faked in tests.

## Conventions

- Commits: follow the global rules (conventional, atomic, one line, no attribution trailers).
- Build order is in `docs/design.md`. Work one step at a time, and keep each step shippable.
