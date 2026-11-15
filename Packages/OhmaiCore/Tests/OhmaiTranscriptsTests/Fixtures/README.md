# Transcript fixtures

- `claude-2.1.325/session.jsonl`, `codex-0.169.0/rollout.jsonl`: the first lines of real
  transcripts, scrubbed. Structure, key order, numbers, timestamps, model ids and enum
  values are kept; ids are mapped to consistent fakes (so repeated lines stay repeated);
  every other string, and any object key that isn't a plain field name, is a placeholder.
- `pi-1.5.2/session.jsonl`: constructed from pi's documented session format (no real pi
  session existed when these were made). Replace with a scrubbed real one when available.

When an agent's format changes, add a new `<agent>-<version>/` directory next to these.
