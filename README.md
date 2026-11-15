# ohmai

A menu bar dashboard for your AI coding agents: what's running, what's waiting on you, and this month's token usage and cost against last month. For Claude Code, Codex and pi.

The name is "oh my ai", with a nod to the ohm (Ω), which is also its face.

## What it shows

- **Running agents.** Every Claude Code, Codex and pi session that's working or waiting on you, with its project and how long it's been at it. The menu bar face changes shape when an agent is working, and gets a dot when one is waiting on you.
- **This month vs last month.** Tokens and estimated cost per agent, compared against the same days of last month, with last month's total for scale. Costs are estimates at API list prices, not a bill. Models without a known price are counted in tokens, never as $0.

## Privacy

- **ohmai makes no network requests.** None: no analytics, no crash reporting, no update checks, no price lookups.
- It reads agent transcripts **only for usage numbers and session metadata** (agent, model, project path, timestamps, token counts). It never stores, logs or displays what you or the agents wrote. All transcript parsing lives in one module whose only output is usage records (`Packages/OhmaiCore/Sources/OhmaiTranscripts`).
- Everything stays on your Mac, in `~/Library/Application Support/ohmai/`.

## Agents

| Agent | Setup | How ohmai knows what it's doing |
|---|---|---|
| Claude Code | Nothing | `~/.claude/sessions/` status files, process checks, transcript timestamps |
| Codex | Nothing | Turn start/end markers in `~/.codex/sessions/` rollout files |
| pi | Settings → Agents → **Install Extension** | A small extension that writes pi's state to a status file |

Claude's and Codex's files are undocumented formats, so an agent update can change them. ohmai parses them defensively: anything it doesn't recognize is ignored, never treated as "busy".

## Power

While an agent is working, ohmai can stop your Mac from going to sleep on its own (an idle-sleep assertion, the same mechanism as `caffeinate`), and lets it sleep as soon as the work stops. It's on by default; turn it off in Settings → General.

It's deliberately conservative:

- **Every claim expires.** A session must keep proving it's alive (its process is running and is the same process, and it keeps writing). An agent waiting on you holds the Mac awake for at most an hour; a "busy" agent that writes nothing for an hour is treated as stuck. Both limits are adjustable.
- **It lets the Mac sleep** on battery below 50% (adjustable), in Low Power Mode, or when the Mac gets hot.
- If ohmai quits or crashes, macOS drops its claim automatically.

### Lid-closed mode (opt-in)

Closing a MacBook's lid sleeps it even mid-task. If you turn on **Settings → Lid Closed**, ohmai installs a small helper so a *busy* agent can keep going with the lid shut (an agent waiting on you never does). This needs a helper that runs as root, which macOS asks you to approve.

The helper is kept small and fails safe:

- Its only action is `pmset -a disablesleep 0|1`. It accepts no other commands.
- It only accepts requests from ohmai itself, checked by code signature (team and bundle ID).
- **Dead-man switch:** ohmai must renew every 30 seconds. If it stops (crash, hang, quit), the helper turns sleep back on within 90 seconds by itself. It also turns sleep back on when it starts, when it's stopped, and on battery below 30% or when the Mac gets hot, checking these itself.
- Turning lid-closed mode off removes the helper.

If you ever want to check: `pmset -g | grep -i sleepdisabled` shows 0 (or nothing) when sleep is allowed. `sudo pmset -a disablesleep 0` restores it by hand.

## Install

Requires macOS 26 or later. Download the notarized zip from this repo's Releases, unzip it, and move `ohmai.app` to `/Applications`. ohmai opens at login by default (Settings → General).

## Uninstall

**Settings → General → Uninstall…** turns sleep back on, removes the lid helper, the login item and the pi extension, optionally deletes your usage history, and moves ohmai to the Trash.

By hand, if needed:

1. Settings → Lid Closed → off (removes the helper), or turn ohmai's items off in System Settings → General → Login Items & Extensions.
2. `pmset -g | grep -i sleepdisabled` should show 0; if not, `sudo pmset -a disablesleep 0`.
3. Delete `~/Library/Application Support/ohmai`, `~/.pi/agent/extensions/ohmai.ts` (if you installed it) and run `defaults delete com.westvold.ohmai`.
4. Move `ohmai.app` to the Trash.

## Build from source

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make test       # package tests (fast, no Xcode project needed)
make build      # generates ohmai.xcodeproj and builds Debug
```

To sign with your own Apple team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `OHMAI_TEAM_ID`. The lid helper's caller check is built from that value.

Releases: `make release` archives, signs with Developer ID, notarizes, staples and zips (see `scripts/release.sh`).

## Docs

- [`docs/design.md`](docs/design.md): scope, architecture, power policy, lid-closed mode, performance budget
- [`docs/agent-integrations.md`](docs/agent-integrations.md): how each agent's state and usage are read, with verified findings
- [`docs/updates.md`](docs/updates.md): why there are no in-app updates yet, and the plan for them
