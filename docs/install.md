# Install, update and uninstall

## Install

ohmai needs macOS 26 or later.

1. Download the disk image (`.dmg`) from the [latest release](https://github.com/nicwestvold/ohmai/releases/latest). It's signed and notarized.
2. Open it and drag ohmai to Applications.
3. Open ohmai. It lives in the menu bar (there's no Dock icon) and opens at login by default (Settings → General).

## Agents

| Agent | Setup | How ohmai knows what it's doing |
|---|---|---|
| Claude Code | Nothing | `~/.claude/sessions/` status files, process checks, transcript timestamps |
| Codex | Nothing | Turn start/end markers in `~/.codex/sessions/` rollout files |
| pi | Settings → Agents → **Install Extension** | A small extension that writes pi's state to a status file |

Claude's and Codex's files are undocumented formats, so an agent update can change them. ohmai parses them defensively: anything it doesn't recognize is ignored, never treated as "busy". The details are in [agent-integrations.md](agent-integrations.md).

## Privacy

- **ohmai makes no network requests.** None: no analytics, no crash reporting, no update checks, no price lookups.
- It reads agent transcripts **only for usage numbers and session metadata** (agent, model, project path, timestamps, token counts). It never stores, logs or displays what you or the agents wrote. All transcript parsing lives in one module whose only output is usage records (`Packages/OhmaiCore/Sources/OhmaiTranscripts`).
- Everything stays on your Mac, in `~/Library/Application Support/ohmai/`.
- Costs are estimates at API list prices, from a price table bundled with the app, not a bill. Models without a known price are counted in tokens, never as $0.

## Update

ohmai doesn't update itself (that would take a network request). To update: quit ohmai, replace `ohmai.app` in `/Applications` with the new one, and open it. Your settings, history and approvals carry over, and the lid helper switches to the new version on its own. More in [updates.md](updates.md).

## Uninstall

**Settings → General → Uninstall…** turns sleep back on, removes the lid helper, the login item and the pi extension, optionally deletes your usage history, and moves ohmai to the Trash.

By hand, if needed:

1. Settings → Advanced → turn off **Keep working with the lid closed** (removes the helper), or turn ohmai's items off in System Settings → General → Login Items & Extensions.
2. `pmset -g | grep -i sleepdisabled` should show 0; if not, `sudo pmset -a disablesleep 0`.
3. Delete `~/Library/Application Support/ohmai`, `~/.pi/agent/extensions/ohmai.ts` (if you installed it) and run `defaults delete com.westvold.ohmai`.
4. Move `ohmai.app` to the Trash.
