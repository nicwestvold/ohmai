# Codex 0.169.0 fixtures

Built from a real `~/.codex/sessions/.../rollout-*.jsonl` written by Codex 0.169.0. Every
line keeps its structure, key order and type fields; every other string (prompts, replies,
ids, paths, account ids, instructions) is replaced with a placeholder.

- `complete.jsonl`: one turn, `task_started` … `task_complete`. Observed.
- `open-turn.jsonl`: the same, cut before `task_complete` (a turn in progress).
- `aborted.jsonl`: `task_complete` swapped for a `turn_aborted` event. Constructed: the
  payload shape of `turn_aborted` hasn't been observed on disk yet.

When Codex changes the format, add a `codex-<version>/` directory next to this one.
