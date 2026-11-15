# Agent integrations: research

How ohmai can learn, for each agent, **when it is working** (to keep the Mac awake) and **how much it has used** (tokens and plan limits).

Researched 2026-11-14.

| Agent | Version | How it was verified |
|---|---|---|
| Claude Code | 2.1.325 | Docs, plus real local files |
| Codex CLI | 0.169.0 | Source at `openai/codex@81b995a`, plus real local rollouts |
| pi | 1.5.2 | Package docs and `dist` only. **Not installed locally.** |

Items marked **(unverified)** still need a hands-on check before an adapter depends on them.

---

## Summary

### Busy/idle signals

| | Claude Code | Codex | pi |
|---|---|---|---|
| Hook system | `settings.json` hooks or a plugin `hooks/hooks.json`. Supports `http` handlers. | `~/.codex/hooks.json` or `[hooks]` in `config.toml`, Claude-style | TypeScript extension in `~/.pi/agent/extensions/` |
| Busy | `UserPromptSubmit` | `UserPromptSubmit` | `agent_start` |
| Idle | `Stop` (if `background_tasks` is empty), `StopFailure` | `Stop` | `agent_settled` |
| Interrupted (Esc) | **No hook fires.** Known gap. | `Interrupt` | `agent_settled {aborted: true}` |
| Waiting on user | `PermissionRequest`, `Notification(permission_prompt)` | `PermissionRequest` | `ui_prompt_start` / `ui_prompt_end` |
| Session end | `SessionEnd` (1.5s budget) | `SessionEnd` | `session_shutdown` |
| Crash / kill -9 | No event fires: check pid liveness | Same | Same |
| Watch files without hooks? | Partly (undocumented sessions file) | **Yes**: the rollout records turn lifecycle | Usage only |

### Usage and rate limits

| | Tokens | Plan limit (5h / weekly) |
|---|---|---|
| Claude Code | Transcript JSONL (dedupe by `message.id`) | **Statusline stdin JSON only** (`rate_limits`) |
| Codex | Rollout `token_count` events | **In the rollout** (`rate_limits.primary` / `secondary`) |
| pi | Session JSONL `usage` with `cost` | None built in. Could forward provider headers from an extension **(unverified)**. |

### Recommended approach

| Agent | Activity source | Usage source |
|---|---|---|
| Claude Code | Watch `~/.claude/sessions/<pid>.json` (busy / idle / waiting); ohmai plugin hooks as a cross-check | Transcripts, plus a statusline tee wrapper for limits |
| Codex | Watch rollout files (no setup needed); optional hooks for "waiting on approval" | Rollout files |
| pi | ohmai extension | Session files |

All three need pid liveness checks and lease expiry.

---

## Claude Code

Sources:
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/statusline
- https://code.claude.com/docs/en/monitoring-usage

### Hooks

**Config locations:**
- `~/.claude/settings.json`
- `.claude/settings.json`, `.claude/settings.local.json`
- managed policy
- plugin `hooks/hooks.json` (uses `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}`)
- skill or subagent frontmatter

```json
{"hooks": {"Stop": [{"matcher": "", "hooks": [
  {"type": "http", "url": "http://127.0.0.1:<port>/claude", "timeout": 5}
]}]}}
```

**Handler types:**
- `command`: JSON on stdin. Supports `async: true` and `asyncRewake`.
- `http`: POSTs the same JSON.
- `mcp_tool`, `prompt`, `agent`.

**Timeouts:**
- Default 600s.
- `UserPromptSubmit`: 30s.
- `SessionEnd`: 1.5s total.

**Exit codes:** exit 2 *blocks* on `UserPromptSubmit` and `Stop`. ohmai's hooks must always exit 0 and return quickly.

**Common payload fields:**
- `session_id`, `transcript_path` (written asynchronously, may lag), `cwd`, `hook_event_name`, `permission_mode`
- `prompt_id` (absent before the first prompt)
- `agent_id` / `agent_type` (inside subagents)

**Events relevant to ohmai:**

| Event | Use |
|---|---|
| `SessionStart` (startup / resume / clear / compact / fork) | Register the session |
| `UserPromptSubmit` | Busy. Also fires for turns Claude starts on its own. |
| `PreToolUse` / `PostToolUse` / `PostToolUseFailure` / `PostToolBatch` | Heartbeat: force busy |
| `PermissionRequest` | Waiting on user, immediately |
| `Notification` | `notification_type`: `permission_prompt` (after about 6s), `idle_prompt` (about 60s after the last response), `agent_needs_input`, `agent_completed`, `quota_auto_resume_*` |
| `SubagentStart` / `SubagentStop` | Scoped by `agent_id` |
| `Stop` | Idle if `background_tasks[]` and `session_crons[]` are empty. Otherwise the session is still waiting on background work, so keep the lease. |
| `StopFailure` | Idle. `error` is one of: rate_limit, overloaded, authentication_failed, billing_error, server_error, max_output_tokens, … |
| `SessionEnd` | Gone. `reason`: clear / resume / logout / prompt_input_exit / other |

There are 33 events in total. The others (Setup, UserPromptExpansion, MessageDisplay, TaskCreated/Completed, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, DirectoryAdded, FileChanged, Worktree*, Pre/PostCompact, Pre/PostModelSwitch, Elicitation*, PermissionDenied) are not needed for v1.

**Gaps:**
- **Esc interrupt:** `Stop` does not run on a user interrupt, and a cancelled tool doesn't fire `PostToolUseFailure`. Fallbacks:
  - lease expiry
  - the sessions file (below)
  - `idle_prompt`, if it fires after an interrupt **(unverified)**
- **Crash:** no `SessionEnd` fires. The hook's `$PPID` is the `claude` pid; record it and poll liveness.

### Usage data

**Transcripts:** `~/.claude/projects/<slugified-cwd>/<sessionId>.jsonl`. Subagents write to `<sessionId>/subagents/agent-*.jsonl`.

Each `type: "assistant"` line includes:
- `sessionId`, `timestamp`, `cwd`, `version`, `requestId`, `isSidechain`, `message.model`
- `message.usage`:
  - `input_tokens`, `output_tokens`
  - `cache_creation_input_tokens`, `cache_read_input_tokens`
  - `cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`
  - `output_tokens_details.thinking_tokens`
  - `server_tool_use.{web_search_requests, web_fetch_requests}`
  - `service_tier`, `speed`
- One API message spans several lines, so **dedupe by `message.id` / `requestId`**.
- Transcripts contain no rate-limit data.

**Statusline stdin JSON** is the only official source for plan limits:
- `rate_limits.five_hour.{used_percentage, resets_at}` and `rate_limits.seven_day.{…}` (resets_at is epoch seconds).
  - Only present for Pro/Max subscribers, and only after the session's first API response.
  - A window is dropped once its `resets_at` passes.
- `cost.total_cost_usd` (estimated at list price), `cost.total_duration_ms`
- `context_window.*`, `session_id`, `model.id`, `workspace.*`
- Refreshes on each assistant message (300ms debounce), or every N seconds with `refreshInterval`.
- **Only one statusline command can be configured.** The user's is currently `npx -y ccstatusline@latest`, so ohmai would ship a wrapper:

  ```sh
  #!/bin/sh
  # ohmai-statusline: send a copy to ohmai, then hand off to the user's real statusline
  input=$(cat)
  printf '%s' "$input" | ohmai ingest claude-statusline >/dev/null 2>&1 &
  printf '%s' "$input" | npx -y ccstatusline@latest
  ```

**OpenTelemetry** (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, OTLP exporter):
- Metrics: `claude_code.token.usage`, `claude_code.cost.usage`, `claude_code.active_time.total`
- Events: `api_request`, `api_error`, …
- **No rate-limit data.** Configured through env vars. Not needed for v1.

**`~/.claude/stats-cache.json`** (undocumented): `dailyModelTokens`, `modelUsage`, `dailyActivity`.

**Do not use** the unofficial `GET api.anthropic.com/api/oauth/usage`. It needs the OAuth token from the Keychain, which is a ToS and security risk, and the statusline already gives the same numbers.

### Other signals (undocumented)

- **`~/.claude/sessions/<pid>.json`:** one file per interactive session.
  - Fields: `pid`, `sessionId`, `cwd`, `status`, `statusUpdatedAt`, `kind`, `entrypoint`, `version`, `name`, `messagingSocketPath`.
  - Only `"busy"` has been observed. **Check whether it flips to an idle value after Esc**; if it does, it closes the interrupt gap.
  - Always verify the pid is alive, because files can outlive their process.
- Process name: `claude`. Tools run as `/bin/zsh -c` children.
- `~/.claude/ide/<port>.lock` when an IDE extension is connected.

---

## Codex CLI

Sources:
- `openai/codex` repo, in `codex-rs/`. The repo's `docs/` are now stubs pointing to developers.openai.com/codex.
- Installed via Homebrew cask, arm64 binary `codex`.

### Legacy `notify`, not recommended

`notify = ["/path/bin"]` in `config.toml`.
- Fires on turn **complete** only.
- The JSON payload is passed as the last argv argument (`type: "agent-turn-complete"`, `thread-id`, `turn-id`, `cwd`, …).
- Deprecated (`hooks/src/legacy_notify.rs`, marked TODO-remove).

### Lifecycle hooks

Feature `hooks`, stable, on by default.

**Config locations:**
- `~/.codex/hooks.json` or `<repo>/.codex/hooks.json`
- `[hooks]` in `config.toml`
- a plugin's `hooks/hooks.json`

The shape matches Claude Code's, and the payload is JSON on stdin.

**Common fields:** `session_id`, `turn_id`, `cwd`, `model`, `permission_mode`, `transcript_path` (the rollout file), `hook_event_name`.

| Event | When it fires |
|---|---|
| `SessionStart` | `source`: startup / resume / clear / compact / fork |
| `UserPromptSubmit` | **Turn start** (user prompt admitted) |
| `PreModelRequest` / `PostModelRequest` | Each sampling request, whatever started it |
| `PreToolUse` / `PostToolUse` | Around each tool call |
| `PermissionRequest` | An approval prompt is about to show: **waiting on user** |
| `Stop` | Turn finished normally |
| `Interrupt` | Turn aborted by the user (Esc) |
| `SubagentStart` / `SubagentStop` | Subagent lifecycle |
| `PreCompact` / `PostCompact` | Compaction |
| `SessionEnd` | `reason` |

**Trust gate:**
- User and project hooks **do not run until the user approves them in Codex**, once per hook definition.
- Approval is stored as `trusted_hash`. Changing the hook definition invalidates it.
- Managed hooks (`requirements.toml`) skip the gate.
- How approval looks in the 0.169 TUI is **(unverified)**.

**Gaps:**
- `Stop` probably doesn't fire on turns that end in an error **(unverified)**.
- `UserPromptSubmit` may not fire for turns the user didn't start; `PreModelRequest` covers those.

### Rollout files: the primary source

**Location:** `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<thread-uuid>.jsonl`. Each line is `{timestamp, ordinal, type, payload}`.

**Turn lifecycle** (`event_msg` payloads):
- `task_started` (with `turn_id` and `turn_attribution.turn_trigger`) means busy.
- `task_complete` or `turn_aborted` means idle.
- Approval requests are **not** persisted, so the rollout can't show "waiting on approval".

**Token usage and rate limits.** A real example (from this Mac):

```json
{"type":"event_msg","payload":{"type":"token_count",
 "info":{"total_token_usage":{"input_tokens":15508,"cached_input_tokens":12032,
   "cache_write_input_tokens":0,"output_tokens":105,"reasoning_output_tokens":0,"total_tokens":15613},
   "last_token_usage":{},"model_context_window":475000},
 "rate_limits":{"limit_id":"codex",
   "primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1794522529},
   "secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":1794598607},
   "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
   "plan_type":"plus","rate_limit_reached_type":null}}}
```

- `primary` is the 5h window; `secondary` is weekly.
- `info` can be null.
- Other `limit_id` values are possible.
- There is also a per-response `token_usage_record` line.
- Local sqlite state lives in `~/.codex/state_5.sqlite` and `thread_history_1.sqlite`.

### Other surfaces

**App-server daemon** (`codex app-server daemon start`). The TUI attaches to it automatically. JSON-RPC notifications include:
- `thread/status/changed`: `idle | active{activeFlags: [waitingOnApproval | waitingOnUserInput]} | systemError`
- `account/rateLimits/updated`

`account/rateLimits/read` can poll limits even while idle. This is the most precise source, but it's experimental, and whether a passive observer can subscribe to TUI threads is **(unverified)**. Consider it for v2.

**Other options:**
- `codex exec --json`: only for runs ohmai launches itself.
- OTel `[otel]`: needs an OTLP receiver. Not needed for v1.

**Process:** `codex`. A long-lived daemon `codex` process means "codex process alive" does **not** mean busy.

---

## pi

The package was renamed: `@mariozechner/pi-coding-agent` (deprecated at 0.73.1) is now **`@earendil-works/pi-coding-agent`** (1.5.2). Repo: https://github.com/earendil-works/pi. The CLI is still `pi`.

### Extensions

**Auto-discovered from:**
- `~/.pi/agent/extensions/*.ts|*.js`
- `~/.pi/agent/extensions/*/index.ts`
- packages with a `pi.extensions` field
- project `.pi/extensions/`, after the project is trusted

They can also be listed in `settings.json` or loaded with `pi -e`. Extensions load via jiti, so there is no build step. **Start timers and sockets in `session_start`, not in the factory function.**

**Lifecycle events relevant to ohmai:**

| Event | Use |
|---|---|
| `session_start` (startup / reload / new / resume / fork) | Register the session |
| `agent_start` | Busy |
| `agent_end` | **Not** idle: retries, compaction and queued follow-ups can start another run |
| `agent_settled {aborted}` | **Idle**. Also covers Esc. `ctx.isIdle()` is true here. |
| `ui_prompt_start` / `ui_prompt_end` | Waiting on user |
| `message_end` | The assistant message carries `provider`, `model`, `usage` |
| `after_provider_response {status, headers}` | Possible rate-limit header source **(unverified per transport)** |
| `session_shutdown` (quit / reload / new / resume / fork) | Gone. Quit covers Ctrl+C/D, SIGHUP, SIGTERM. |

**Context helpers:** `ctx.isIdle()`, `ctx.model`, `ctx.mode`, `ctx.sessionManager.getSessionFile()` / `getSessionId()`.

**Crash or SIGKILL:** no event fires. Check pid liveness.

**Draft extension.** Change the file-heartbeat transport to whatever ohmai settles on.

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const dir = join(homedir(), "Library/Application Support/ohmai/pi");
const file = join(dir, `${process.pid}.json`);

export default function (pi: ExtensionAPI) {
  let timer: NodeJS.Timeout | undefined;
  const write = (state: string, ctx: any, extra = {}) =>
    writeFileSync(file, JSON.stringify({
      pid: process.pid, state, ts: Date.now(), cwd: ctx.cwd,
      session: ctx.sessionManager.getSessionFile(),
      provider: ctx.model?.provider, model: ctx.model?.id, ...extra,
    }));

  pi.on("session_start", (_e, ctx) => {
    mkdirSync(dir, { recursive: true });
    write("idle", ctx);
    timer = setInterval(() => write(ctx.isIdle() ? "idle" : "busy", ctx), 15_000);
  });
  pi.on("agent_start", (_e, ctx) => write("busy", ctx));
  pi.on("ui_prompt_start", (_e, ctx) => write("waiting", ctx));
  pi.on("ui_prompt_end", (_e, ctx) => write(ctx.isIdle() ? "idle" : "busy", ctx));
  pi.on("agent_settled", (e, ctx) => write("idle", ctx, { aborted: e.aborted }));
  pi.on("session_shutdown", () => { clearInterval(timer); rmSync(file, { force: true }); });
}
```

### Session files

**Location:** `~/.pi/agent/sessions/--<cwd, / replaced by ->--/<timestamp>_<uuid>.jsonl`. Version 3. Entries form a tree via `id` / `parentId`.

**Assistant message entry:**

```json
{"type":"message","id":"…","parentId":"…","timestamp":"…","message":{"role":"assistant",
 "provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":0,"output":0,
 "cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,
 "cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop"}}
```

- `reasoning`, when present, is already included in `output`; don't add it twice.
- These entries also carry `usage` and count toward totals: `{"type":"usage","kind":"cache_warm"}`, `compaction.usage`, `branch_summary.usage`.
- `cost` is calculated from pi's price catalog, so it's an **estimate** on subscriptions. Exception: with Anthropic Pro/Max auth, third-party usage is billed as extra per-token usage, so `cost` is close to real spend.

### Rate limits

pi has none built in. Options:
- Forward Anthropic `anthropic-ratelimit-unified-*` or Codex `x-codex-*` headers from `after_provider_response`.
- Read raw stream events from `provider_stream_event`.

Both are **(unverified)**.

### Other surfaces

- **RPC mode** (`pi --mode rpc`): `get_state` (`isStreaming`), `get_session_stats`. Only for pi processes ohmai spawns itself.
- **Process:** `process.title = "pi"`; env vars `PI_CODING_AGENT=true` and `AI_AGENT=pi`. How it appears in macOS `ps` is **(unverified)**.

---

## Hands-on checks (2026-11-14)

### Claude Code 2.1.325: the sessions file is a real busy/idle source

The code that writes `~/.claude/sessions/<pid>.json` computes `status` like this (read from the shipped binary):

```js
function YEe(h){
  let P = R1o(h);                       // waiting reason, if any
  if (P !== void 0) return {status:"waiting", waitingFor:P, working:false};
  return {status: h.isLoading || h.delegatedActive ? "busy" : "idle", waitingFor:void 0, working:h.isQueryActive};
}
// R1o returns: "input needed" | <dialog's waitingFor> | "worker request" | "sandbox request" | "dialog open"
```

- **The status values are `busy`, `idle` and `waiting`**, with `waitingFor` giving the reason. An interrupt clears `isLoading`, so Esc should flip it to `idle`. This closes the Esc gap without any hooks.
- **`busy` includes background work** (`delegatedActive`). For example, a session sat at `busy` for 3+ hours while its transcript showed `pendingBackgroundAgentCount: 2`. That's correct for keep-awake.
- **`statusUpdatedAt` changes only when the status changes**, and `updatedAt` on every write. So staleness must be judged from pid liveness and transcript writes, not from `statusUpdatedAt`.
- **It's undocumented and could change in any release.** Use it as the primary activity source, with hooks as a cross-check and a fallback if the file disappears.
- **Interrupt markers in transcripts:** `[Request interrupted by user]` and `[Request interrupted by user for tool use]`. `system` entries with `subtype: "turn_duration"` mark ends of turns and carry `pendingBackgroundAgentCount`.
- Still unverified: whether `Notification(idle_prompt)` fires after an interrupt. It's no longer needed.
- **No heartbeat writes.** While a session stays `busy`, the file isn't rewritten at all (`updatedAt` didn't move for over a minute of continuous work). Watching for file changes alone can't renew a lease, so the adapter re-reads the directory every 30s while any session is busy or waiting.
- **`procStart`** is the process start time as a ctime-style string **in UTC** (e.g. `Sat Nov 14 20:56:27 2026`), matching `TZ=UTC ps -o lstart`. **`startedAt`** (epoch ms) is about 2s after the kernel's process start. Either one detects a reused pid: compare with `sysctl(KERN_PROC_PID)`'s `p_starttime`.
- Other fields seen in 2.1.325: `startedAt`, `procStart`, `pidDomain`, `peerProtocol`, `peerFeatures`, `tmux`, `nameSource`, `nameSince`, `asksForConvertedSkills`. Each `<pid>.json` sits next to a `<pid>.<hash>.key` file, which ohmai never reads.
- **Proof of life:** transcripts live at `~/.claude/projects/<folder>/<sessionId>.jsonl` and subagents at `<folder>/<sessionId>/subagents/*.jsonl`. Their modification times show a busy session is really working. ohmai only stats them, and never opens them for this.
- **`name` is derived from the conversation**, so ohmai treats it as message content and never reads it.

### Codex 0.169.0: hooks work, but untrusted hooks silently don't run

The test ran `codex exec` with inline `-c hooks.<Event>=[…]` command hooks:
- **Without trust:** no hooks ran, with no warning or error. The turn completed normally.
- **With `--dangerously-bypass-hook-trust`:** `SessionStart`, `UserPromptSubmit`, `PreModelRequest`, `Stop` and `SessionEnd` all fired, in that order, with these payload fields:

| Event | Fields |
|---|---|
| `SessionStart` | cwd, hook_event_name, model, permission_mode, session_id, source, transcript_path |
| `UserPromptSubmit` | + prompt, turn_id |
| `PreModelRequest` | cwd, hook_event_name, model, session_id, transcript_path, turn_id |
| `Stop` | + last_assistant_message, stop_hook_active, turn_id |
| `SessionEnd` | cwd, hook_event_name, reason, session_id, transcript_path |

What this means for ohmai:
- Hooks must be installed in `~/.codex/hooks.json` and approved once in the Codex TUI (from source: a startup review screen and a hooks browser; the screen itself hasn't been seen).
- ohmai can't tell from outside whether they've been approved, so Settings should show **"seen a Codex hook event recently: yes/no"** rather than assume.
- **Rollout watching stays the primary source**, because it works with zero approval.
- Gotcha: `codex exec` waits for stdin when it isn't a TTY. Use `</dev/null` when scripting it.

### pi 1.5.2 (installed, no provider connected)

- **Install:** `~/.local/bin/pi` → `~/.pi/agent/bin/pi` (a shell script launcher).
- **Data:** `~/.pi/agent/{auth.json, settings.json, models-store.json, sessions/}`.
- **Session path format is confirmed:** `~/.pi/agent/sessions/--Users-example-projects-demo--/<ISO-timestamp>_<uuid>.jsonl`.
- **Session files are written lazily.** The directory and file path exist at `session_start`, but no file appears until the first message. An empty session dir is normal.
- **The extension API works as documented.** Loading a test extension with `-e` showed:
  - the factory runs first, then `session_start` (`ctx.isIdle()` = true, `getSessionFile()` returns the path), then `session_shutdown` on stdin EOF
  - the extension's `.ts` loaded with no build step
- **Process name:** `pgrep -x pi-rpc` matched the RPC process, so `process.title` is visible to macOS process lookups. Interactive sessions should match `pgrep -x pi`, but that hasn't been seen yet.
- **Not yet testable:** `agent_start` / `agent_settled`, the `usage` schema in real messages, and the rate-limit headers from `after_provider_response`. All need a connected provider.

## Open questions


- [ ] Codex: does `Stop` fire on turns that end in an error? Can a passive app-server client observe TUI threads?
- [ ] pi: once a provider is connected, check agent events, the message `usage` schema, and rate-limit headers.
