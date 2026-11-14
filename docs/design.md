# ohmai: design

ohmai ("oh my ai") is a macOS menu bar app that:
1. **Keeps the Mac awake while an AI agent is working**, within a power policy you control.
2. **Tracks token usage and plan-limit position** for Claude Code, Codex and pi.

For each agent's hooks and data formats, see [agent-integrations.md](agent-integrations.md).

## Menu bar UI

The **menu bar icon** must answer "is an agent running?" at a glance, without opening the dropdown. Idle and working must differ in *shape*, not just fill or a subtle tint, and be legible at 16px on light and dark menu bars. Concepts: https://claude.ai/artifact/BoCobNp2RZPWWWiUc8gfnN. States:
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
- **App:** SwiftUI `MenuBarExtra`, `LSUIElement` (menu bar only, no Dock icon), macOS 14+.
- **Ingest:** a localhost HTTP listener for Claude `http` hooks, plus an `ohmai` CLI for `command` hooks, the statusline tee and the pi extension. Everything converges on a single event type.
- **Watchers:** FSEvents over the transcript and rollout directories. Imports are incremental: store a byte offset per file and never re-read from the start.
- **Distribution:** built for personal use first, possibly open-sourced later. It can't use the App Store sandbox, because it reads `~/.claude`, `~/.codex` and `~/.pi`.
  - **Signing:** the user's existing paid Developer ID account. Register app IDs for the app and the lid helper, and sign with Developer ID Application + notarization from day one, so builds behave like release builds (helper approval, Gatekeeper).
  - **If open-sourced:** signed and notarized releases via a Homebrew cask. People building from source sign with their own team ID, so the helper's code-signing requirement must take the team ID from build settings, not hard-code it.

## Activity and leases

- Each adapter emits `ActivityEvent(agent, sessionId, pid, activity, at)`.
- `busy` and `waiting` grant or renew a lease. `idle` and `gone` release it.
- **A lease expires** if any of these happen:
  - no signal for N minutes (default 10)
  - the pid is dead
  - the pid's start time no longer matches (pid reused)
- Expiry covers crashes, `kill -9` and Claude's missing Esc hook.
- **Waiting is not the same as busy.** A session waiting on you (an approval or question) holds a *capped* lease: it keeps the Mac awake for up to 1 hour (configurable) after waiting starts, then releases even if the session is still alive. Busy leases have no cap, only signal-based expiry. A waiting lease never keeps a closed lid awake.

## Power policy

```swift
func decide(leases: [Lease], power: PowerState, prefs: Prefs) -> Decision
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

The policy is pure and fully unit-tested. The menu bar always shows the current decision and its reason, e.g. "Awake: 2 agents · on AC".

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
    func engage(leaseSeconds: Int, reply: @escaping (Bool, String?) -> Void)  // disablesleep 1
    func renew(leaseSeconds: Int, reply: @escaping (Bool) -> Void)
    func release(reply: @escaping (Bool) -> Void)                             // disablesleep 0
    func status(reply: @escaping (_ engaged: Bool, _ expiresAt: Date?) -> Void)
}
```

**Caller check:** the helper accepts connections only from ohmai, matched by code-signing requirement (team ID + bundle ID), using `NSXPCConnection.setCodeSigningRequirement`.

**It only ever runs** `pmset -a disablesleep 0|1`. It takes no arbitrary commands.

### Safety: dead-man switch

The helper, not the app, guarantees the setting is turned back off:

- **Lease:** the app renews every 30s with a 90s lease. If the lease expires (app crashed, hung or quit), the helper sets `disablesleep 0` itself.
- **Startup reset:** on launch the helper always sets `disablesleep 0`, in case a crash or reboot left it on.
- **Battery and thermal:** the helper checks these itself and releases if:
  - it's on battery below the lid-closed floor (default 30%), or
  - thermal state is `.serious` or worse.
- **Lid-closed sessions pause idle sleep only while agents are busy.** When the last lease ends, release happens immediately, so a closed laptop goes to sleep as normal.

### Lid-closed conditions (policy rule 4)

All of the following must hold:
- Lid-closed mode is enabled and the helper is approved
- At least one `busy` lease. A lease that is only `waiting` never keeps a closed lid awake.
- On AC, or on battery above the lid-closed floor
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
- **Metrics window (later):**
  - tokens per day per agent
  - input / output / cache split
  - top projects
  - per-model breakdown (especially for pi, which spans several providers)

## Installing the integrations

ohmai's Settings → Integrations page installs and checks each one:

| Agent | Installs | Notes |
|---|---|---|
| Claude Code | Nothing required (watches `~/.claude/sessions/`). Optional plugin with `http` hooks as a cross-check; statusline wrapper that chains the existing command | Never overwrite the user's statusline; wrap it |
| Codex | Nothing required (watches rollouts). Optional `~/.codex/hooks.json` for approval-waiting | Hooks must be approved once in Codex; unapproved hooks fail silently, so Settings shows whether hook events have actually arrived |
| pi | `~/.pi/agent/extensions/ohmai.ts` | — |

## Build order

1. Menu bar shell, `PowerMonitor`, `AssertionManager`, `Policy` (with tests)
2. Lid-closed mode: helper, XPC, dead-man switch, opt-in UX in Settings
3. Claude adapter (hooks + liveness), so keep-awake works end to end
4. Codex adapter (rollout watcher), pi adapter (extension)
5. Ledger + incremental import, month-to-date vs. last month in the dropdown
6. Later: statusline tee for limits, metrics window
