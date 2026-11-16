#!/usr/bin/env python3
"""Renders the README's images from a fake demo world: no real sessions, projects or usage.

  mise run build && scripts/readme-shots.py      (or: mise run readme-shots)

Outputs, all committed, in docs/images/:
  menu-light.png, menu-dark.png   the dropdown, with rounded corners and a shadow
  icon.png                        the app icon, from the Debug build's AppIcon.icns
  faces.svg                       the menu bar faces (from scripts/make-icons.py's paths)

How: builds a scratch home with synthetic transcripts and status files, starts placeholder
`sleep` processes to stand in for live agents (ohmai checks pids), then runs the Debug app
with its OHMAI_* overrides and OHMAI_SNAPSHOT_DIR. Needs rsvg-convert (brew install librsvg).
"""
import base64
import json as _json
import os
import pathlib
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "build/Build/Products/Debug/ohmai.app"
OUT = ROOT / "docs/images"

sys.path.insert(0, str(ROOT / "scripts"))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("make_icons", ROOT / "scripts/make-icons.py")
icons = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(icons)


def dumps(obj):
    """Compact, like the agents write: ohmai's pre-filters match `"type":"…"` byte for byte."""
    return _json.dumps(obj, separators=(",", ":"))


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond // 1000:03d}Z"


def ms(d):
    return int(d.timestamp() * 1000)


class World:
    def __init__(self, root):
        self.root = root
        self.home = f"{root}/home"
        self.claude_sessions = f"{root}/claude-sessions"
        self.pi_status = f"{root}/pi-status"
        self.codex_sessions = f"{self.home}/.codex/sessions"
        for d in (self.claude_sessions, self.pi_status, self.codex_sessions):
            os.makedirs(d, exist_ok=True)
        self.now = datetime.now(timezone.utc)
        self.rng = random.Random(7)
        self.procs = []
        self.counter = 0

    # --- live sessions ---

    def spawn(self, executable="/bin/sleep", stdin=None):
        p = subprocess.Popen([executable, "3600"], stdin=stdin or subprocess.DEVNULL, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        lstart = subprocess.check_output(["ps", "-o", "lstart=", "-p", str(p.pid)], env={"TZ": "UTC"}, text=True)
        lstart = " ".join(lstart.split())
        started = datetime.strptime(lstart, "%a %b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc)
        return p.pid, lstart, started

    def claude_session(self, project, status, minutes_ago):
        pid, lstart, _ = self.spawn()
        began = self.now - timedelta(minutes=minutes_ago)
        record = {"pid": pid, "sessionId": str(uuid.UUID(int=self.rng.getrandbits(128), version=4)),
                  "cwd": f"/Users/demo/projects/{project}", "startedAt": ms(began), "procStart": lstart,
                  "version": "2.1.325", "kind": "interactive", "status": status,
                  "updatedAt": ms(self.now), "statusUpdatedAt": ms(began)}
        pathlib.Path(f"{self.claude_sessions}/{pid}.json").write_text(dumps(record))

    def pi_session(self, project, status, minutes_ago):
        pid, _, started = self.spawn()
        began = self.now - timedelta(minutes=minutes_ago)
        record = {"v": 1, "pid": pid, "processStart": ms(started), "startedAt": ms(began), "status": status,
                  "statusUpdatedAt": ms(began), "sessionId": None, "sessionFile": None,
                  "cwd": f"/Users/demo/projects/{project}"}
        pathlib.Path(f"{self.pi_status}/{pid}.json").write_text(dumps(record))

    def codex_turn(self, project, minutes_ago):
        began = self.now - timedelta(minutes=minutes_ago)
        sid = "00000000-0000-7000-8000-0000000000c1"
        folder = pathlib.Path(f"{self.codex_sessions}/{began:%Y/%m/%d}")
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"rollout-{began:%Y-%m-%dT%H-%M-%S}-{sid}.jsonl"
        path.write_text(
            dumps({"timestamp": iso(began), "ordinal": 0, "type": "session_meta", "payload": {
                "id": sid, "cwd": f"/Users/demo/projects/{project}", "cli_version": "0.169.0"}}) + "\n"
            + dumps({"timestamp": iso(began), "ordinal": 1, "type": "event_msg",
                     "payload": {"type": "task_started", "turn_id": "turn-live"}}) + "\n")
        # Codex records no pid: ohmai looks for a process named `codex` holding the rollout open.
        fake = f"{self.root}/bin/codex"
        os.makedirs(os.path.dirname(fake), exist_ok=True)
        shutil.copy("/bin/sleep", fake)
        subprocess.run(["codesign", "-f", "-s", "-", fake], check=True, capture_output=True)
        self.spawn(fake, stdin=open(path))

    # --- usage history ---

    def nid(self, prefix):
        self.counter += 1
        return f"{prefix}{self.counter:06d}"

    def days(self, start, end):
        d = start
        while d < end:
            if d.weekday() < 5 or self.rng.random() < 0.3:
                yield d
            d += timedelta(days=1)

    def moments(self, start, end, per_day):
        for day in self.days(start, end):
            for _ in range(self.rng.randint(*per_day)):
                t = day + timedelta(hours=self.rng.uniform(9, 19))
                if t <= self.now:
                    yield t

    def claude_usage(self, start, end, per_day):
        folder = pathlib.Path(f"{self.home}/.claude/projects/-Users-demo-projects-atlas-api")
        folder.mkdir(parents=True, exist_ok=True)
        r = self.rng
        with open(folder / f"{start:%Y%m}.jsonl", "w") as f:
            for t in self.moments(start, end, per_day):
                model = r.choice(["claude-opus-5-5"] * 4 + ["claude-sonnet-5-5"] * 2 + ["claude-haiku-5-5"])
                f.write(dumps({"type": "assistant", "timestamp": iso(t), "sessionId": "demo",
                               "message": {"id": self.nid("msg_demo"), "model": model, "usage": {
                                   "input_tokens": r.randint(2, 40), "output_tokens": r.randint(150, 2500),
                                   "cache_read_input_tokens": r.randint(8_000, 60_000),
                                   "cache_creation_input_tokens": r.randint(300, 4_000)}}}) + "\n")

    def codex_usage(self, start, end, per_day):
        sid = f"00000000-0000-7000-8000-{start:%Y%m}00c2"
        folder = pathlib.Path(f"{self.codex_sessions}/{start:%Y/%m/%d}")
        folder.mkdir(parents=True, exist_ok=True)
        r = self.rng
        with open(folder / f"rollout-{start:%Y-%m-%dT09-00-00}-{sid}.jsonl", "w") as f:
            f.write(dumps({"timestamp": iso(start), "ordinal": 0, "type": "session_meta", "payload": {"id": sid}}) + "\n")
            f.write(dumps({"timestamp": iso(start), "ordinal": 1, "type": "turn_context",
                           "payload": {"model": "gpt-6.1-sol"}}) + "\n")
            for t in self.moments(start, end, per_day):
                tokens = r.randint(10_000, 80_000)
                f.write(dumps({"timestamp": iso(t), "ordinal": self.counter + 2, "type": "token_usage_record",
                               "payload": {"session_id": sid, "response_id": self.nid("resp_demo"), "usage": {
                                   "input_tokens": tokens, "cached_input_tokens": int(tokens * 0.8),
                                   "cache_write_input_tokens": 0, "output_tokens": r.randint(100, 1800),
                                   "reasoning_output_tokens": r.randint(0, 600)}}}) + "\n")

    def pi_usage(self, start, end, per_day):
        folder = pathlib.Path(f"{self.home}/.pi/agent/sessions/--Users-demo-projects-dotfiles--")
        folder.mkdir(parents=True, exist_ok=True)
        r = self.rng
        with open(folder / f"{start:%Y-%m-%dT09-00-00}_pi-demo-{start:%Y%m}.jsonl", "w") as f:
            for t in self.moments(start, end, per_day):
                f.write(dumps({"type": "message", "id": self.nid("e"), "timestamp": iso(t), "message": {
                    "role": "assistant", "provider": "anthropic", "model": "claude-sonnet-5-5", "usage": {
                        "input": r.randint(5, 50), "output": r.randint(100, 1500),
                        "cacheRead": r.randint(5_000, 40_000), "cacheWrite": r.randint(200, 3_000)}}}) + "\n")

    def build(self):
        self.claude_session("atlas-api", "busy", 14)
        self.claude_session("marketing-site", "waiting", 3)
        self.codex_turn("ml-pipeline", 6)
        self.pi_session("dotfiles", "busy", 2)

        month = self.now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        last = (month - timedelta(days=1)).replace(day=1)
        # One record before last month, so its history counts as complete.
        early = pathlib.Path(f"{self.home}/.claude/projects/-Users-demo-projects-atlas-api/early.jsonl")
        early.parent.mkdir(parents=True, exist_ok=True)
        early.write_text(dumps({"type": "assistant", "timestamp": iso(last - timedelta(days=3)), "message": {
            "id": "msg_demo_early", "model": "claude-haiku-5-5", "usage": {"input_tokens": 10, "output_tokens": 10}}}) + "\n")
        # This month runs a bit ahead of last month, so the comparison reads naturally.
        self.claude_usage(last, month, (150, 280))
        self.claude_usage(month, self.now, (180, 336))
        self.codex_usage(last, month, (8, 20))
        self.codex_usage(month, self.now, (12, 30))
        self.pi_usage(last, month, (30, 70))
        self.pi_usage(month, self.now, (25, 60))

    def env(self, snapshots):
        return {**os.environ,
                "OHMAI_CLAUDE_SESSIONS_DIR": self.claude_sessions, "OHMAI_CODEX_SESSIONS_DIR": self.codex_sessions,
                "OHMAI_PI_STATUS_DIR": self.pi_status, "OHMAI_USAGE_HOME": self.home,
                "OHMAI_LEDGER_DB": f"{self.root}/ledger.sqlite", "OHMAI_SNAPSHOT_DIR": snapshots}

    def stop(self):
        for p in self.procs:
            p.kill()


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


def framed(png, out, radius=24, pad=48):
    """The screenshot as a floating panel: rounded corners, a soft shadow, transparent around."""
    w, h = png_size(png)
    data = base64.b64encode(pathlib.Path(png).read_bytes()).decode()
    W, H = w + 2 * pad, h + 2 * pad
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{W}" height="{H}">
<defs>
  <clipPath id="c"><rect x="{pad}" y="{pad}" width="{w}" height="{h}" rx="{radius}"/></clipPath>
  <filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="16" flood-opacity="0.28"/></filter>
</defs>
<rect x="{pad}" y="{pad}" width="{w}" height="{h}" rx="{radius}" fill="#888" filter="url(#s)"/>
<image x="{pad}" y="{pad}" width="{w}" height="{h}" clip-path="url(#c)" xlink:href="data:image/png;base64,{data}"/>
<rect x="{pad + 0.5}" y="{pad + 0.5}" width="{w - 1}" height="{h - 1}" rx="{radius}" fill="none" stroke="#000" stroke-opacity="0.12"/>
</svg>'''
    src = pathlib.Path(out).with_suffix(".svg.tmp")
    src.write_text(svg)
    subprocess.run(["rsvg-convert", "-f", "png", str(src), "-o", str(out)], check=True)
    src.unlink()


def faces_svg():
    """The three everyday menu bar faces, amber on the icon's ink, labelled in a neutral gray."""
    ink, amber, label = "#1C1C22", "#F3C04F", "#8B8B93"
    states = [("Face-asleep", "idle"), ("Face-working", "working"), ("Face-waiting", "needs you")]
    tile, gap, scale = 88, 40, 2.4
    width = len(states) * tile + (len(states) - 1) * gap
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{tile + 34}" viewBox="0 0 {width} {tile + 34}">']
    for i, (name, caption) in enumerate(states):
        lines, solid = icons.FACES[name]
        x = i * (tile + gap)
        off = (tile - 24 * scale) / 2
        parts.append(f'<rect x="{x}" y="0" width="{tile}" height="{tile}" rx="20" fill="{ink}"/>')
        parts.append(f'<g transform="translate({x + off} {off}) scale({scale})">')
        if lines:
            parts.append(f'<path d="{lines}" fill="none" stroke="{amber}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')
        if solid:
            parts.append(f'<path d="{solid}" fill="{amber}" fill-rule="evenodd"/>')
        parts.append("</g>")
        parts.append(f'<text x="{x + tile / 2}" y="{tile + 24}" text-anchor="middle" fill="{label}" '
                     f'font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', Helvetica, Arial, sans-serif" '
                     f'font-size="15">{caption}</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    if not APP.exists():
        sys.exit(f"No Debug build at {APP}. Run `mise run build` first.")
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        world = World(f"{tmp}/world")
        try:
            world.build()
            snapshots = f"{tmp}/snapshots"
            subprocess.run([str(APP / "Contents/MacOS/ohmai")], env=world.env(snapshots), check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        finally:
            world.stop()
        for theme in ("light", "dark"):
            framed(f"{snapshots}/menu-{theme}.png", OUT / f"menu-{theme}.png")
        subprocess.run(["sips", "-s", "format", "png", "--resampleWidth", "256",
                        str(APP / "Contents/Resources/AppIcon.icns"), "--out", str(OUT / "icon.png")],
                       check=True, capture_output=True)
    (OUT / "faces.svg").write_text(faces_svg())
    print(f"wrote {OUT.relative_to(ROOT)}/: menu-light.png menu-dark.png icon.png faces.svg")


if __name__ == "__main__":
    main()
