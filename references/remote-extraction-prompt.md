# remote-extraction-prompt: ON-node extraction (service accounts)

For service accounts/instances (for example `bot-alpha`, `bot-beta`, ...) the raw session may contain sensitive instance-specific data: **it is not downloaded to the driver**. The node's Claude session is piloted with your remote piloting tool (the command listed in `pilot_commands`) with a message asking it to extract and sanitize in place and to return **only the digest**.

## Flow

1. `stk -u <alias> scan` -> manifest of the new/changed sessions on the remote node.
2. For the batch, send to the remote Claude session (through the piloting tool, addressed to `<alias>`) the request below, with the `session_id` + `jsonl_path` list from the manifest.
3. Collect the output through the same tool. ONLY the digest JSON lines must come back.
4. Bring the digests into the central merge as for trusted nodes.

## Message to send (summary)

> You are on node `<alias>`. For each listed `.jsonl` file, extract a digest and print it as a single JSON line (JSONL), with no other text. Rules: keys/enum in English, content in the language of the session, **translating is forbidden**. **Sanitize**: no raw commands, paths with secrets, tokens, credentials, instance-specific data (customer numbers, phone numbers, keys). Schema per line: `{session_id, lang, goal, summary, done[], open[], decisions[], internal_branches[], pilot_candidates[], proposed_status, tags[]}`. Allowed statuses: active|dormant|paused|branched|done|dropped|superseded|unknown. Files: `<list>`.

## Notes

- The digest schema is identical to `extraction-prompt.md`: the only difference is **where** it runs (on the node, not on the driver) and that the raw does not transit.
- If the piloting tool has a privacy check of its own, the same rule applies here: when in doubt, the remote session omits the datum and flags it as `[redacted]` in the `summary`.
- The choice of a small model applies only to the driver-side subagents: here the extraction runs inside the Claude session of the remote node, whose model is the one configured there.
- If the remote session is still working, wait until it is idle before sending.
