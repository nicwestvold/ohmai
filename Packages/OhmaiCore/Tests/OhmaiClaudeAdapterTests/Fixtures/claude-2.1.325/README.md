# Claude Code 2.1.325 fixtures

`sessions/*.json` copy the key set and layout of a real `~/.claude/sessions/<pid>.json`
from Claude Code 2.1.325. Every identifying value (session id, cwd, name, socket path,
tmux) is a placeholder. No transcript or prompt content is included.

- `busy.json`: observed on disk.
- `idle.json`, `waiting.json`: the same record with the status values (and `waitingFor`)
  that the 2.1.325 binary writes, per docs/agent-integrations.md. Not yet observed on disk.

When Claude changes this format, add a new `claude-<version>/` directory next to this one.
