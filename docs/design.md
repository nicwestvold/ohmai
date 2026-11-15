# ohmai: design

ohmai ("oh my ai") is a macOS menu bar app that:
1. **Keeps the Mac awake while an AI agent is working**, within a power policy you control.
2. **Tracks token usage and plan-limit position** for Claude Code, Codex and pi.

For each agent's hooks and data formats, see [agent-integrations.md](agent-integrations.md).

## v1 scope

**In:**
- automatic keep-awake
- opt-in lid-closed mode
- Claude Code, Codex and pi
- monthly usage vs. last month
- the Ω face icon
- launch at login
- in-app updates

**Later:**
- plan-limit bars and the Dizzy expression
- metrics window
- notifications, e.g. "agent waiting on you". The agents already notify, so revisit if needed.

## Platform and principles

- **macOS 26+**, built with Xcode 27 / Swift 6 / SwiftUI. Current macOS is 27; supporting one major version back covers everything this app needs.
- **Launch at login:** on by default, via `SMAppService.mainApp`, with a toggle in Settings.
- **Privacy:**
  - ohmai reads agent transcripts, which contain your code and prompts. It extracts **only usage numbers and session metadata** (agent, model, project path, timestamps, token counts) and stores nothing else.
  - It makes **no network calls** except the update check (below).
  - Promise this in the README, and keep it true in the code: a single module owns transcript parsing and returns only usage records.
- **Pricing:** a per-model price table bundled with the app and updated with releases. Nothing is fetched.
- **Updates:** see [updates.md](updates.md). Prepared behind an `Updater` seam with a no-op implementation; Sparkle gets wired when a feed exists. In-app via Sparkle 2, using the signed (EdDSA) appcast that Sparkle requires. This is the **one** network call:
  - it fetches only the appcast
  - Sparkle's system-profile reporting is off, so nothing about the Mac or usage is sent
  - automatic checks are **on by default** (`SUEnableAutomaticChecks = true`), with a Settings toggle to turn them off
  - two feeds: a stable appcast, and a separate preview feed for beta builds (the same pattern Rex uses)
  - privacy promise wording: "The only network request ohmai makes is checking its update feed, and you can turn that off."
- **Testing:**
  - The `Policy` and lease logic get pure unit tests.
  - Each adapter is tested against fixture files built from real session files, with message content replaced. When an agent update changes its format, it should show up as a failing test, not as wrong numbers.

## Menu bar UI

The **menu bar icon** must answer "is an agent running?" at a glance, without opening the dropdown. Idle and working must differ in *shape*, not just fill or a subtle tint, and be legible at 16px on light and dark menu bars. Concepts: https://claude.ai/artifact/BoCobNp2RZPWWWiUc8gfnN.

**Chosen: the Ω face.** The ohm sign as a little character, because the app should have personality. Two levels of detail:
- **Menu bar (16px):** four simple states: Asleep (outline, eyes shut), Working (solid, eyes open), Waiting (Working + dot badge), Shades (lid-closed mode).
- **Dropdown header and app icon:** the full set of expressions: Asleep, Focused, Oh! (waiting), Shades (lid-closed), Drowsy (low battery, letting the Mac sleep), Dizzy (rate limit hit), Happy (all agents just finished, shown briefly).

The generic state list below still applies:
- outline: no agents running
- filled: agent(s) busy
- dot badge: an agent is waiting on you
- distinct icon: ohmai is holding the Mac awake (lid-closed mode gets its own variant)

The **dropdown** shows what's running and the month's token usage. Keep-awake controls stay in the background:

```
 Running
   ● Claude Code   ohmai/        busy 4m
   ● Codex         gwt/          waiting on you
 ───────────────────────────────────────────
 November usage                     vs Oct 1–14
   Claude Code    48.2M   ~$212       ▲ 23%
   Codex          12.1M    ~$41       ▼  8%
   pi              3.4M    ~$18         new
   Total          63.7M   ~$271       ▲ 15%
 ───────────────────────────────────────────
 Settings…                              Quit
```

- **Month comparison** is month-to-date against the same days of last month, which is fairer than comparing against the whole of last month. Hovering a row shows last month's full total.
- **Settings** holds the keep-awake toggles, lid-closed mode, battery and thermal thresholds, integrations, and the token-counting choice.

## Keep-awake mode

**Automatic only** (default on, toggled in Settings): ohmai keeps the Mac awake while any agent session holds a lease, and lets it sleep once none do. There is deliberately no manual "keep awake now" override; `caffeinate` already does that.

## Domain terms

| Term | Meaning |
|---|---|
| **Agent** | A supported tool: `claude`, `codex`, `pi` |
| **Session** | One running agent instance, identified by agent, session id and pid |
| **Activity** | A session's state: `busy`, `waiting` (on the user), `idle`, `gone` |
| **Lease** | A time-boxed claim to stay awake, renewed by signals from a busy or waiting session. It expires if the signals stop. |
| **Policy** | A pure function from (leases, power state, prefs) to a decision |
| **Assertion** | The OS-level effect: an IOKit power assertion, or lid-closed mode |
| **Ledger** | Local SQLite store of usage records and limit snapshots |
| **Adapter** | Per-agent code that turns hooks and files into Activity events and Ledger records |

## Architecture

```
 Claude hooks (http) ─┐
 Codex rollout files ─┤                ┌─ Policy ── AssertionManager ── IOPMAssertion
 Codex hooks         ─┼─► Adapters ──► │                           └── LidHelper (XPC, root)
 pi extension        ─┤   (normalize)  ├─ SessionRegistry + Leases
 statusline tee      ─┘                └─ Ledger (SQLite) ── Metrics UI
 transcripts (FSEvents) ──────────────►┘
```

**Parts:**
- **App:** SwiftUI `MenuBarExtra`, `LSUIElement` (menu bar only, no Dock icon), macOS 26+.
- **Ingest:** a localhost HTTP listener for Claude `http` hooks, plus an `ohmai` CLI for `command` hooks, the statusline tee and the pi extension. Everything converges on a single event type.
- **Watchers:** FSEvents over the transcript and rollout directories. Imports are incremental: store a byte offset per file and never re-read from the start.
- **Distribution:** built for personal use first, possibly open-sourced later. It can't use the App Store sandbox, because it reads `~/.claude`, `~/.codex` and `~/.pi`.
  - **Signing:** the user's existing paid Developer ID account. Register app IDs for the app and the lid helper, and sign with Developer ID Application + notarization from day one, so builds behave like release builds (helper approval, Gatekeeper).
  - **Releases:** signed and notarized DMG/zip, with the Sparkle appcast hosted alongside (e.g. GitHub Releases). A Homebrew cask can point at the same artifacts.
  - **If open-sourced:** People building from source sign with their own team ID, so the helper's code-signing requirement must take the team ID from build settings, not hard-code it.

## Activity and leases

- Each adapter emits `ActivityEvent(agent, sessionId, pid, activity, at)`.
- `busy` and `waiting` grant or renew a lease. `idle` and `gone` release it.
- **A lease expires** if any of these happen:
  - no signal for N minutes (default 10)
  - the pid is dead
  - the pid's start time no longer matches (pid reused)
- Expiry covers crashes, `kill -9` and Claude's missing Esc hook.
- **Quiet limit (busy):** a busy status alone isn't trusted forever. If a busy session writes nothing (no transcript or subagent transcript, no status change) for 1 hour (configurable), its adapter releases it, which covers an agent stuck on `busy`. It comes back when anything is written again. Only modification times are read. Hooks wouldn't help: a single long tool call is silent to hooks too.
- **Waiting is not the same as busy.** A session waiting on you (an approval or question) holds a *capped* lease: it keeps the Mac awake for up to 1 hour (configurable) after waiting starts, then releases even if the session is still alive. Busy leases have no cap, only signal-based expiry. A waiting lease never keeps a closed lid awake.

## Power policy

```swift
func decide(leases: [Lease], power: PowerState, prefs: Prefs, now: Date) -> Decision
// Decision: .allowSleep(reason) | .stayAwake(reason) | .stayAwakeLidClosed(reason)
```

**Inputs:**
- `IOPSCopyPowerSourcesInfo` for AC vs. battery and charge percentage. `IOPSNotificationCreateRunLoopSource` notifies on changes.
- `ProcessInfo.isLowPowerModeEnabled`, `thermalState`
- Whether the lid is closed and whether an external display is attached

**Rules, in order** (all thresholds configurable):

| # | Condition | Decision |
|---|---|---|
| 1 | No active leases, or keep-awake turned off | Allow sleep |
| 2 | Thermal state `.serious` or worse | Allow sleep + notify |
| 3 | On battery and (< battery floor (default 50%) or Low Power Mode) | Allow sleep + notify "agent still running" |
| 4 | Lid-closed mode enabled and its own conditions met (below) | Stay awake, lid closed |
| 5 | Otherwise | Stay awake (idle-sleep assertion) |

The policy is pure and fully unit-tested. `now` is an input, not a clock read, so lease expiry (signal timeout, waiting cap) is decided inside the policy and a caller can't forget to drop expired leases.

**Edge cases:**
- Battery floors are "below" in the strict sense: exactly at the floor counts as OK, for both the general floor and the lid-closed floor.
- An unreadable charge, or an unknown power source, counts as below the floor. When in doubt, release.
- A thermal state macOS adds in the future is treated as `.critical`.

The menu bar always shows the current decision and its reason, e.g. "Awake: 2 agents · on AC".

**Idle-sleep assertion:** `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, …)` with the reason `"ohmai: <n> agent session(s) active"`. Optionally, `PreventUserIdleDisplaySleep` keeps the screen on too.

## Lid-closed mode (v1, opt-in)

Power assertions don't stop the sleep that happens when you close the lid (unless the Mac is in clamshell mode: on AC with an external display). Lid-closed mode uses `pmset -a disablesleep 1`, which needs root, so it requires a **privileged helper**.

### Opt-in UX

- Off by default. You enable it in Settings, behind an explanation of the risks (heat, battery).
- Enabling it registers the helper with `SMAppService.daemon(plistName:)`. macOS then asks you to approve it in System Settings → Login Items. ohmai shows the helper's status and links to that pane.
- The menu bar shows a distinct icon while lid-closed mode is engaged.
- Disabling it unregisters the helper.

### Helper (`ohmai-lidhelper`, root, launchd daemon)

**Keep it minimal.** It is root code, so its job is deliberately small. The XPC interface:

```swift
@objc protocol LidHelperProtocol {
    func engage(leaseSeconds: Int, batteryFloorPercent: Int, reply: @escaping (Bool, String?) -> Void)  // disablesleep 1
    func renew(leaseSeconds: Int, batteryFloorPercent: Int, reply: @escaping (Bool) -> Void)
    func release(reply: @escaping (Bool) -> Void)                                                       // disablesleep 0
    func status(reply: @escaping (_ engaged: Bool, _ expiresAt: Date?) -> Void)
    func version(reply: @escaping (String) -> Void)  // CFBundleVersion, to spot a stale helper after an update
}
```

- **The helper clamps its inputs:** leases to 1–300s, and the battery floor to 10–100%. A buggy app can't ask for a day-long lease or a 0% floor.
- Engaging while engaged renews. `renew` never engages.
- The app passes the lid-closed floor from Settings, so the helper and the policy agree on it.

**Caller check:** the helper accepts connections only from ohmai, matched by code-signing requirement (team ID + bundle ID), using `NSXPCConnection.setCodeSigningRequirement`. The app checks the helper the same way.
- The team ID comes from the helper's embedded Info.plist (`OHMAI_TEAM_ID`). If it's missing or malformed, the helper resets sleep and exits: it fails closed.

**It only ever runs** `pmset -a disablesleep 0|1`. It takes no arbitrary commands.

### Safety: dead-man switch

The helper, not the app, guarantees the setting is turned back off:

- **Lease:** the app renews every 30s with a 90s lease. If the lease expires (app crashed, hung or quit), the helper sets `disablesleep 0` itself.
- **Startup reset:** on launch the helper always sets `disablesleep 0`, in case a crash or reboot left it on.
  - The launchd plist has `RunAtLoad` (so the reset runs at boot even if ohmai never opens) and `KeepAlive` on unsuccessful exit (so a crash respawns it, and the reset runs again).
- **Signals:** on `SIGTERM` (unregister, shutdown, logout) the helper sets `disablesleep 0` before exiting.
- **Failed reset:** if `pmset` fails while turning sleep back on, the helper retries every 5s until it succeeds.
- **Battery and thermal:** the helper checks these itself and releases if:
  - it's on battery below the lid-closed floor (default 30%), or
  - thermal state is `.serious` or worse.
- **Lid-closed sessions pause idle sleep only while agents are busy.** When the last lease ends, release happens immediately, so a closed laptop goes to sleep as normal.
- **Ticking:** the helper checks expiry and guards every 5s, only while engaged (or while a reset is pending). When idle it runs no timers.
- The menu bar shows Shades only once the helper has actually engaged, not merely when the policy wants it to.

### Testing lid-closed mode by hand

Unit tests fake `pmset` and never change real power state. To try the real helper:

1. Before you start, check the state, and keep the restore command ready:
   ```sh
   pmset -g | grep -i sleepdisabled      # expect absent or 0
   sudo pmset -a disablesleep 0          # restore, if anything goes wrong
   ```
2. Build, and launch ohmai from `build/Build/Products/Debug`. Enable lid-closed mode in Settings and approve the helper in System Settings → Login Items.
3. Check the helper: `sudo launchctl print system/com.westvold.ohmai.lidhelper`, and its log: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.westvold.ohmai.lidhelper"'`. Use the full path: in zsh, plain `log` is a shell builtin. Each engage and release is logged, with the reason for the release.
4. Dead-man check: with it engaged, `kill -9` the ohmai app (`pkill -9 -x ohmai`). `SleepDisabled` must return to 0 within about 95s of the app's last renewal (90s lease, plus up to one 5s tick).

**Verified 2026-11-14** (Debug build, Apple Development signing): helper approved, startup reset logged, engaged with a busy Claude session on AC, and after `kill -9` of the app the helper released on its own.

### Lid-closed conditions (policy rule 4)

All of the following must hold:
- Lid-closed mode is enabled and the helper is approved
- At least one `busy` lease. A lease that is only `waiting` never keeps a closed lid awake.
- On AC, or on battery at or above the lid-closed floor
- Thermal state is nominal or fair

## Usage and metrics

- **Ledger tables:**
  - `usage_records`: agent, session, model, provider, timestamp, input / output / cache-read / cache-write / reasoning tokens, cost (estimated or real)
  - `limit_snapshots`: agent, window (5h / 7d), used %, resets_at, observed_at
- **Sources:**
  - Claude: transcripts + statusline tee
  - Codex: rollout `token_count`
  - pi: session `usage`, plus forwarded headers if that turns out to work
- **Headline number:** tokens this month per agent, compared with the same days of last month (see Menu bar UI).
  - **All token types count**, cache reads included: they're real usage, just billed at a different rate. Raw token totals are dominated by cache reads, though, so the month-over-month comparison uses **estimated API-equivalent cost**, which weights each token type by its price. Each row shows tokens and estimated $; the ▲/▼ is computed on cost.
  - **Pricing table:** a bundled, versioned per-model price list (input, output, cache write, cache read). pi already records `cost` per message; use it directly. For Claude and Codex subscriptions this is "what it would have cost on the API", not a bill, and the UI labels it as an estimate.
- **History:** Claude Code deletes transcripts after 30 days by default (`cleanupPeriodDays`). The Ledger must keep its own copy so last month's numbers survive. On first run, import everything still on disk; for the first month the comparison may be partial, and the UI says so.
- **Plan-limit bars** (5h / weekly) are captured in the Ledger, but they appear in the dropdown only as a later option.
- **Dropdown (built, step 5):** one row per agent plus a total: `this month / last month total` and a ▲/▼ change against the **same days** of last month. A bar under each row fills with this month so far, ends at last month's total, and a tick marks the same day last month. Hovering shows tokens, the same-days figures and the estimate note. The change is hidden (shown as "—") while history is partial.
- **Unpriced models** (no entry in `prices.json`, e.g. Codex's `gpt-6.1-sol` today) never count as $0: that agent's row compares on tokens, and the total stays on cost but shows `+` as a lower bound. Prices are added only from a real source.
- **Claude Code writes 1-hour cache entries** (`cache_creation.ephemeral_1h_input_tokens`), billed at 2× input, not 1.25×. The parser keeps the split.
- **Import performance (measured 2026-11-14, 3.5 GB / 1,189 files):** first import 27 s at background priority, 72 MB peak footprint; incremental imports ~0.1 s; ledger 20 MB. Reads drain an autorelease pool per 4 MB chunk (without it the peak was 4.9 GB). After each import, SQLite's page cache and the malloc zones are released: the running app holds ~29 MB, within budget, while live imports run every 10 s during active sessions. Re-run with `OHMAI_BENCH_DB=… swift test -c release --filter RealImportBenchmark`.
- **Metrics window (later):**
  - tokens per day per agent
  - input / output / cache split
  - top projects
  - per-model breakdown (especially for pi, which spans several providers)

## Installing the integrations

ohmai's Settings → Integrations page installs and checks each one:

| Agent | Installs | Notes |
|---|---|---|
| Claude Code | Nothing required (watches `~/.claude/sessions/`). No hooks plugin in v1: the sessions file, pid liveness and the quiet limit cover what hooks would. Statusline wrapper (later, for limits) that chains the existing command | Never overwrite the user's statusline; wrap it |
| Codex | Nothing required (watches rollouts). Optional `~/.codex/hooks.json` for approval-waiting | Hooks must be approved once in Codex; unapproved hooks fail silently, so Settings shows whether hook events have actually arrived |
| pi | `~/.pi/agent/extensions/ohmai.ts`, written only when you click Install in Settings → Agents. Update and Remove are there too; ohmai never overwrites or removes a file that isn't its own. | pi loads it on next start or `/reload` |

## Performance budget

ohmai runs all day in the background, so it must cost nothing when idle and stay small when busy. The energy cost of *keeping the Mac awake* is the point of the app, and the power policy bounds it. This budget covers ohmai's own overhead.

| | Budget |
|---|---|
| Idle (no leases) | 0% CPU, **no timers**. Wakes only for OS notifications (power source, Low Power Mode, thermal state, system wake) and incoming hook or file events. |
| Leases held | A single timer, set for the earliest lease expiry (2s tolerance so the OS can coalesce it). No fixed-interval polling. |
| Agent sessions active | Each adapter may hold **one** renewal timer while its own sessions are busy or waiting, only when the agent gives no heartbeat (Claude: re-read `~/.claude/sessions/` every 30s, 5s tolerance). Process exit is noticed via kqueue (`NOTE_EXIT`), not polling. |
| Memory | Physical footprint under 30 MB at steady state (step 1 measured 17 MB). |
| Dropdown | Live-updating views (e.g. "busy 4m") only update while the dropdown is open. Usage totals are cached, not queried on each render. |

**Rules for later steps:**
- **File watching:** FSEvents with a few seconds of latency to coalesce bursts. Agents append to transcripts many times a second during a busy session; handle a batch, not every write. Never poll directories.
- **Imports:** incremental from a stored byte offset, streaming line by line, never reading a whole file into memory. Decode only the usage fields. Run at `.utility` QoS, or `.background` for the first-run import of history, off the main actor.
- **First-run import:** resumable (offsets are committed as it goes), so quitting or crashing midway doesn't start over.
- **Pid liveness checks** (step 3): run only while leases exist, folded into the expiry timer, not a separate poll.
- **Lid helper renewals** (every 30s) run only while lid-closed mode is engaged.
- **Ledger:** aggregates are recomputed after an import batch and cached for the UI.
- **Check it:** `top -pid <pid> -stats pid,cpu,mem,idlew,power` over a few minutes, idle and with an agent busy. A regression against this table is a bug.

## Build order

1. Menu bar shell, `PowerMonitor`, `AssertionManager`, `Policy` (with tests)
2. Lid-closed mode: helper, XPC, dead-man switch, opt-in UX in Settings
3. Claude adapter (sessions file + liveness + quiet limit), so keep-awake works end to end. No hooks plugin in v1: hooks are blind during a long tool call, the same as transcripts, and a plugin plus a localhost listener adds setup and a local attack surface for no extra coverage.
4. Codex adapter (rollout watcher), pi adapter (extension)
5. Ledger + incremental import, month-to-date vs. last month in the dropdown
6. Launch at login, release pipeline (sign, notarize), Sparkle wiring per updates.md (the `Updater` seam goes in at step 1)
7. Later: statusline tee for limits + Dizzy, metrics window, notifications
