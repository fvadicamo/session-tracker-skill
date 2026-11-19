# extraction-prompt: driver-side subagent (trusted nodes)

Prompt for the subagents that extract the digest from one or more Claude sessions on trusted nodes (the local driver plus any other node you own). The subagent reads the indicated `.jsonl` files and returns **one digest JSON object per session**, nothing else. Launch it with a small model (for example `model: sonnet`) and `effort: low`.

## Non-negotiable rules

1. **Language**: keys/labels/enum in **English**; the *content* (goal, task, decisions, summary) stays in the **language of the session** (IT->IT, EN->EN). **Translating is forbidden.**
2. **Sanitization**: NEVER include raw commands, paths with secrets, tokens, keys, passwords, output with credentials. Only intent and synthesis. If a task concerns a secret, describe it without the value.
3. **Output**: JSONL ONLY, one object per session, no text around it.
4. **Fidelity**: do not invent. If a field cannot be inferred, use `null` or an empty list.

## Input

A list of `{session_id, jsonl_path}`. For each one, read the file (user/assistant events in order; the first user prompt and the last turns are the most informative).

## Output: one object per session

```json
{
  "session_id": "<uuid>",
  "lang": "it",
  "goal": "<initial goal, declared or inferable, in the source language>",
  "summary": "<2-4 short sanitized sentences, source language>",
  "done": ["<what was completed>"],
  "open": ["<tasks still open / unresolved>"],
  "decisions": ["<relevant decisions made>"],
  "internal_branches": ["<side tracks/sub-tasks opened inside the same session: 'let's do X first', 'meanwhile I'll look at Y'>"],
  "pilot_candidates": ["<node-slug if the session pilots remote sessions with one of the pilot_commands (config) and '-u <alias>'; [] if none>"],
  "proposed_status": "active|dormant|paused|branched|done|dropped|superseded|unknown",
  "tags": ["<3-6 thematic tags, lowercase, English or technical term>"]
}
```

## Guidelines

- `goal`: look for the first substantial user prompt; it is the original intent.
- `open`: this is the most valuable field. Include explicit TODOs, "then", "missing", "to do", and things left half done. Keep it distinct from `done`.
- `internal_branches`: flag deviations from the original plan ("let me open a parenthesis", "first I'll fix", "it occurs to me"). They help to see whether new branches have emerged.
- `proposed_status`: apply the guidelines in `status-taxonomy.md`. When in doubt -> `unknown`.
- `pilot_candidates`: ONLY aliases passed to `-u`/`--user` of the remote piloting commands listed in `pilot_commands` of the config (they are node slugs). Ignore other `-u`.
- `tags`: themes/areas (e.g. `ssh`, `vllm`, `dns`, `refactoring`), not generic verbs.
