# Primary-check: `stk primary-check` / `stk repo-status`

Extends `where` (see `placement.md`) with a **live** check of the alignment
between the current secondary node and the declared primary: uncommitted
changes on either side, or primary commits not yet pushed. Unlike `where`,
which is declaredly read-only/no network, this command **uses the network**
(ssh to the primary): that is why it stays a separate subcommand, not
folded into `where`.

## The problem

A declared ownership (see `placement.md`) means that edits on that repo happen
only on the primary node (over ssh from anywhere else), never on a secondary.
`where` reads the declaration but makes no live check: a file edited by mistake
on a secondary raises no alarm, and commits made on the primary but never pushed
stay invisible to the secondary until someone checks by hand with `git status`
over `ssh`.

## `stk repo-status <path>`: contract

One-shot git state of a local path, pure bash (no python/uv, no
`git fetch`: it reads the state/remote-tracking-ref as it is, no
network side effect even when it runs via `-u` on a remote node):

```jsonc
{"path", "branch", "dirty": <count>, "has_upstream": bool, "ahead": <n>, "behind": <n>}
// or, on error (never `die`, always JSON: the caller is often via ssh):
{"path", "error": "path-not-found" | "not-a-git-repo"}
```

`behind` can be stale if nobody has fetched recently (it is not the purpose
here: a check against an up-to-date origin belongs to the tool that syncs that repo). It is in the
allowlist of `-u`: `stk -u <node> repo-status <path>` runs `repo-status` on a
remote node, and that is how `primary-check` uses it for the primary side.

## `stk primary-check`: contract

```
stk primary-check (--current | --session <id> | --cwd <p> --node <n>) [--human] [--force]
```

1. Calls `stk where` with the same arguments (full reuse of the
   ownership/cluster resolution, no reimplementation).
2. Not applicable (`ownership.declared != true`, or empty `primary_node`, or
   it coincides with the current node) -> `{"applicable":false}`, silent.
3. **Local: always live, never cached**: it is the most important signal not
   to delay (the case that matters: a dirty file on a secondary).
4. **Remote: behind a cache**: `stk -u <primary_node> repo-status <primary_path>`,
   result cached in `$STK_LOCAL/primary-check/<key>.json` for
   `STK_PRIMARY_CHECK_TTL` seconds (default 1800; only the remote side is
   cached, never the local one). `--force` bypasses the cache.

```jsonc
{
  "applicable": true,
  "ownership": { "declared", "primary_node", "primary_path", "is_secondary_here", "source" },
  "local":  { "path", "branch", "dirty", "has_upstream", "ahead", "behind" },
  "remote": { "path", "branch", "dirty", "has_upstream", "ahead", "behind" } | { "error": "unreachable", "node" },
  "issues": [ "local-dirty" | "primary-dirty" | "primary-ahead" | "primary-unreachable" ],
  "related_sessions": [ {node,session_id,name,status,last_activity_at,dormancy_risk} ]
}
```

`related_sessions` is taken as-is from `where`'s `candidates[].related_sessions`
(the same cluster already computed): no new logic, only re-exposed here
together with the outcome of the check so as to suggest where to resume.

### Issues

| issue | meaning |
|---|---|
| `local-dirty` | the current secondary node has uncommitted changes: an edit that belonged on the primary |
| `primary-dirty` | the primary has uncommitted changes |
| `primary-ahead` | the primary has commits not yet pushed |
| `primary-unreachable` | ssh to the primary failed or timed out: see Known limits |

## Cache

One file per `(primary_node, primary_path)` pair under `$STK_LOCAL/primary-check/`,
key = slug (`tr -c 'A-Za-z0-9_.-' '_'` of `"<node>:<path>"`), atomic
write (`tmp + mv`). It contains **only** the last remote probe:

```jsonc
{"ts", "ts_epoch", "primary_node", "primary_path", "remote": {...}}
```

No `flock`: each write is independent and atomic; a concurrent double-ssh
(several tabs on the same repo in the same window) is only an
inefficiency, not corruption: it is not worth the complexity of a lock for this.

## Policy (Claude)

- Consider running `stk primary-check --current --human` when `stk where`
  (already run for the placement) reports a declared ownership with a
  `primary_node` different from the current node. Do not repeat it more than once in the
  same session (the remote-side cache already discourages it, but still avoid
  relaunching it at every turn).
- `applicable:false` or failed command -> silence, no mention.
- empty `issues` -> silence (everything aligned, no noise).
- non-empty `issues` -> tell the user what does not add up, and use
  `related_sessions` to propose the node/canonical session/folder where to
  possibly resume instead of proceeding blindly from the secondary
  (same style as the `where` proposal: one proposal only, do not insist).
- `local-dirty` in particular means an edit landed on the wrong node: say so
  explicitly, not just "changes present".

## Known limits

- **SSH alias != node slug, not validated**: the assumption (also declared in
  `schema.md`) is that `ownership.primary_node` is also a usable SSH
  alias. If the alias configured in `~/.ssh/config` diverges from the node
  slug, `stk -u <primary_node> repo-status ...` fails with "Could not
  resolve hostname": caught by the generic fallback (`primary-unreachable`),
  but indistinguishable from "the primary is really unreachable". Not
  blocking, but to keep in mind when reading an unexpected `primary-unreachable`.
- **`ownership.source=prose`**: if the read-only prose does not cite a known slug,
  `primary_node` can stay empty even with `declared=true`: treated as
  not applicable (no attempt to ssh to an empty string).
- **local/remote `behind` can be stale**: no `git fetch` in
  `repo-status` (by design, no network side effects beyond the necessary);
  if an up-to-date number is needed, an explicit fetch must be done elsewhere first.
