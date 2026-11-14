# ohmai: design

ohmai ("oh my ai") is a macOS menu bar app that:
1. **Keeps the Mac awake while an AI agent is working**, within a power policy you control.
2. **Tracks token usage and plan-limit position** for Claude Code, Codex and pi.

For each agent's hooks and data formats, see [agent-integrations.md](agent-integrations.md).

## Menu bar UI

The **menu bar icon** shows the state at a glance:
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
 November tokens             vs Oct 1–14
   Claude Code     48.2M          ▲ 23%
   Codex           12.1M          ▼  8%
   pi               3.4M            new
   Total           63.7M          ▲ 15%
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
- **Distribution:** Developer ID signing plus notarization, via a Homebrew cask. It can't use the App Store sandbox, because it reads `~/.claude`, `~/.codex` and `~/.pi`.

## Activity and leases

- Each adapter emits `ActivityEvent(agent, sessionId, pid, activity, at)`.
- `busy` and `waiting` grant or renew a lease. `idle` and `gone` release it.
- **A lease expires** if any of these happen:
  - no signal for N minutes (default 10)
  - the pid is dead
  - the pid's start time no longer matches (pid reused)
- Expiry covers crashes, `kill -9` and Claude's missing Esc hook.
- **Waiting keeps the Mac awake by default**, so a pending approval can still be answered later. Prefs offer three choices: awake / awake for N min / allow sleep.

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
- At least one `busy` lease. By default a lease that is only `waiting` does **not** keep a closed lid awake; there's a pref to change this.
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
  - **Open decision:** whether cache reads count. Claude's cache reads can be 10–100× its input + output, so including them makes the number huge and dominated by cache. Proposal: headline = input + output + cache writes, with a Settings toggle to include cache reads.
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
| Claude Code | Plugin with `http` hooks; statusline wrapper that chains the existing command | Never overwrite the user's statusline; wrap it |
| Codex | Nothing required (watches rollouts). Optional `~/.codex/hooks.json` for approval-waiting | Hooks must be approved once in Codex |
| pi | `~/.pi/agent/extensions/ohmai.ts` | — |

## Build order

1. Menu bar shell, `PowerMonitor`, `AssertionManager`, `Policy` (with tests)
2. Lid-closed mode: helper, XPC, dead-man switch, opt-in UX in Settings
3. Claude adapter (hooks + liveness), so keep-awake works end to end
4. Codex adapter (rollout watcher), pi adapter (extension)
5. Ledger + incremental import, month-to-date vs. last month in the dropdown
6. Later: statusline tee for limits, metrics window
