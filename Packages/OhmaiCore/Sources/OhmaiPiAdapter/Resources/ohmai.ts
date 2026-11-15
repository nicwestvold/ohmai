// ohmai: tells the ohmai menu bar app when pi is working, so the Mac can stay awake.
// Installed and updated by ohmai (Settings → Agents). Edits will be overwritten.
// ohmai-extension-version: 1
//
// Writes only status metadata (state, pid, session id, cwd, timestamps) to
// ~/Library/Application Support/ohmai/pi/<pid>.json. Never prompts, replies or code.
// No timers, no network: it writes only when pi's state changes.

import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const VERSION = 1;
const dir = join(homedir(), "Library", "Application Support", "ohmai", "pi");
const file = join(dir, `${process.pid}.json`);
const processStart = Math.round(Date.now() - process.uptime() * 1000);

type State = "idle" | "busy" | "waiting";

export default function ohmai(pi: any) {
  let ctx: any;
  let state: State = "idle";
  let statusUpdatedAt = Date.now();
  let startedAt = Date.now();

  const write = () => {
    try {
      const sessions = ctx?.sessionManager;
      const record = {
        v: VERSION,
        pid: process.pid,
        processStart,
        startedAt,
        status: state,
        statusUpdatedAt,
        sessionId: sessions?.getSessionId?.() ?? null,
        sessionFile: sessions?.getSessionFile?.() ?? null,
        cwd: ctx?.cwd ?? process.cwd(),
      };
      mkdirSync(dir, { recursive: true });
      const tmp = `${file}.tmp`;
      writeFileSync(tmp, JSON.stringify(record));
      renameSync(tmp, file);
    } catch {
      // Never disturb pi. ohmai's lease expiry covers a missed write.
    }
  };

  const set = (next: State, c: any) => {
    if (c) ctx = c;
    if (next !== state) {
      state = next;
      statusUpdatedAt = Date.now();
    }
    write();
  };

  pi.on("session_start", (_e: any, c: any) => {
    ctx = c;
    startedAt = Date.now();
    state = "idle";
    statusUpdatedAt = startedAt;
    write();
  });
  pi.on("agent_start", (_e: any, c: any) => set("busy", c));
  pi.on("ui_prompt_start", (_e: any, c: any) => set("waiting", c));
  pi.on("ui_prompt_end", (_e: any, c: any) => set(c?.isIdle?.() ? "idle" : "busy", c));
  // agent_end isn't idle: retries and queued follow-ups can start another run.
  pi.on("agent_settled", (_e: any, c: any) => set("idle", c));
  pi.on("session_shutdown", () => {
    try {
      rmSync(file, { force: true });
    } catch {}
  });
}
