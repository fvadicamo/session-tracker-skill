# Placement: `stk where`

Detect when a session is open **in the wrong place** (a folder or node that does not match the
project the work is about) and propose where to continue. The mechanics are deterministic
(`stk where` -> `helpers/where.py`); the **policy** (whether to propose, and how) is Claude's. See
`SKILL.md`, section "Placement: continue in the right place".

## The problem

Lifecycle of a project: it is born as a `/branch` from the trunk that holds the decisions, then
graduates to standalone sessions launched **from the project folder on the primary node** (e.g. a
project `shop-web`: from `.../shop-web` on the workstation, with a `CLAUDE.local.md` that gives
orientation). Often, though, Claude is opened in an arbitrary folder, or on the laptop (secondary,
read-only), and work starts on a project whose home is elsewhere. Two kinds of mismatch:

- **wrong node**: you are on a secondary (e.g. the laptop) but the primary of the project is another node;
- **wrong folder**: right node but a cwd different from the canonical home of the project.

And three possible outcomes: **relocate** (cd/ssh to the home), **branch-from-trunk** (the
decisions live in a trunk session: resume + `/branch` instead of starting from
scratch), **stay-standalone** (no home: here is fine).

## The ownership block

The declaration that `where` and `primary-check` read lives in the repo's `CLAUDE.md` or
`CLAUDE.local.md` (gitignored: the usual choice when the topology must not be committed):

```
## Node ownership
- Primary: alpha (/home/u/code/x)
- Secondaries: bravo (/home/u2/code/x)
```

The node is its slug, the path is in parentheses (backticks around it are accepted), and
`Secondaries` is a comma-separated list or `none`. Any other form is read as "no block".

## The verdict is advisory here, but a hook can give it teeth

`stk where` proposes; it does not prevent anything. The same block can be read by a guard
registered as a Claude Code hook (not part of this plugin) that denies `Write`/`Edit`/`NotebookEdit`
inside a repo whose primary is another node and leaves `Bash` free for the correct path (ssh
to the primary, edit and commit there, `git pull` here). Two things follow: a session that
proposes "continue elsewhere" without knowing that local writes are already denied reads the
first refusal as a fault instead of as the same diagnosis; and whoever changes the criterion
of `where.py` changes what such a hook denies. A declaration kept in a gitignored
`CLAUDE.local.md` exists only on the node where someone wrote it: a mirror that looks "without
ownership" most likely has the declaration on the other node.

## Signals, in order of reliability

1. **current cwd + node**: the "where you are" (from transcript / `resolve_node`).
2. **ownership block `## Node ownership`** (`CLAUDE.md` / `CLAUDE.local.md`): `Primary`/`Secondaries` with node + path: **authoritative** for the home. Sparse (few repos use it in structured form; some delegate to `CLAUDE.local.md` or use prose).
3. **naming-map** (`contexts`/`tokens`): identity of the **subject** (current and of the candidates). `ops -> real-target` (a heterogeneous repo) cannot be resolved from the path alone: the intent is needed.
4. **emerging cluster** (`index.jsonl`: `name`/`tags`/`project_path`): where the work really **lands** + the trunk. Noisy: requires a threshold. NB: the cluster alone can mislead (e.g. the development of a repo may historically run from `laptop:.../ops`, but the real home is `workstation`): that is why **ownership beats the cluster**.
5. **declared intent** (`intent` note of the 1st turn): disambiguates the subject in heterogeneous repos.
6. **`forked_from`**: if you are already a branch, do not propose a branch toward the lineage again.
7. **org folder of a knowledge base** (`kb_layout` and `kb_orgs` of the naming map): org identity + the map of its repos; it does **not** map code-repo->node: a weak signal, not used to decide.

## Where the "home" lives: derived, no registry

The home `(node, path)` of a project is **derived** in layers, in priority order:

1. **ownership block** present -> `(primary_node, primary_path)`, `source=block`, base confidence **high**. If the declared `Primary` is not a known node (nodes in `index.jsonl` + current node + the `known_nodes` of the config) the declaration is not verifiable - typically a typo, or the **display name** of the machine instead of the **slug** (`LAPTOP01` instead of `laptop01`): `primary_known=false`, confidence **low** and the reason ends up in the evidence, so that a typo no longer produces a falsely confident `elsewhere`;
2. **read-only prose** (the per-node `CLAUDE.local.md` declares read-only here) -> `is_secondary_here=true`, `primary_node` = known slug cited near "source of truth" (if present), `source=prose`, base confidence **low** (raised to medium by the read-only signal);
3. **cluster** -> the most recent **anchor** (`name_source=user` AND `class=task`), `source=cluster`, confidence **medium**; fallback to the most recent session of the cluster (`cluster-weak`, low);
4. none of the three -> no home.

No `project->home` registry: it would duplicate `index.jsonl` (where the work
lands) + ownership (who is primary). If the derivation turns out to be noisy, the
next step is an optional field `home: {node, path}` per subject in
`naming-map.yaml` (curated, already in the canon): not planned, the derivation has been enough so far.

## `stk where`: contract

```
stk where (--current | --session <id> | --cwd <p> --node <n>)
          [--intent <s>] [--forked-from <sid>] [--human]
          [--index <path>] [--naming-map <path>]
```

With `--current`/`--session` it fills cwd/forked_from/intent from the transcript + shard;
in override mode (`--cwd`+`--node`) it skips the resolution (hypothetical use / test).
Default sources: the index (`<canon_path>/index.jsonl` with `canon_mode=local`, the mirror `$STK_LOCAL/canon/index.jsonl` with `ssh`) and the `naming_map` map of the config (default `$STK_LOCAL/naming-map.yaml`)
(**no pull**). JSON output:

```jsonc
{
  "current": { "node", "cwd", "subject", "forked_from",
               "ownership": { "declared", "primary_node", "primary_path",
                              "is_secondary_here", "source": "block|prose|none",
                              "primary_known": true|false|null } },
  "verdict": "here | elsewhere | unknown",
  "candidates": [ {
    "kind": "relocate-node | relocate-folder | branch-from-trunk | stay-standalone",
    "node", "project_path", "subject", "score", "confidence": "high|medium|low",
    "evidence": [ ... ], "trunk": {node,session_id,name}|null,
    "related_sessions": [ {node,session_id,name,status,last_activity_at,dormancy_risk} ]
  } ]
}
```

### Scoring / thresholds

- `relocate-node`: block 88 (high) · cluster 65 (medium) · prose 40->60 (low->medium if read-only) · block with unknown primary 40 (low, no read-only bump).
- `relocate-folder`: block 82 (high) · cluster 60 (medium).
- `branch-from-trunk`: 50 (low): only if `verdict ∈ {here, unknown}` and you are not a branch.
- `stay-standalone`: 0: informative, below threshold.
- **`verdict`**: `elsewhere` if the home exists and is on a different node or folder; `here` if you are at the home (or are already the anchor there); `unknown` if the subject is not resolvable and there is no ownership.

## Policy (Claude)

- Propose **only** if `verdict=elsewhere` with `confidence` **medium or high**. `here`/`unknown` -> silence (unless the user explicitly asks).
- Translate the `kind`: `relocate-node` -> `ssh <node>` + `cd <path>`; `relocate-folder` -> `cd <path>`; `branch-from-trunk` -> resume of the `trunk.session_id` and `/branch` (Claude cannot run it: it proposes it); `stay-standalone` -> confirm that here is fine.
- One proposal only, do not insist. If the user chooses "I stay here", record it: `stk note --current --kind placement "stay: <reason>"` (future resumes see it).

## Anti-noise

- Deterministic confidence threshold + Claude as a second barrier.
- `self_is_anchor` (you are already the home at this location) -> `here`, no proposal.
- Child (`forked_from`) -> no branch-from-trunk (avoids pointing to your own trunk).
- Best effort: no network at startup; with `ssh` a missing or stale mirror -> fewer candidates / low confidence.
- The hook stays **injector-not-writer**: it only injects the clause, the computation is done by `stk where` at the 1st turn (when the intent is there); on resume with the intent already present it does not re-inject -> no re-nag.

## Examples

| Situation | verdict | candidate |
|---|---|---|
| `shop-web` opened on the laptop, cluster says workstation | elsewhere | relocate-node -> workstation:.../shop-web (medium) |
| repo with ownership block, you are on the secondary | elsewhere | relocate-node (high), `is_secondary_here=true` |
| right primary node, wrong folder | elsewhere | relocate-folder -> primary_path |
| you are at the home, live trunk in the cluster | here | branch-from-trunk -> trunk (low) |
| generic folder, no cluster/ownership, subject resolved | here | stay-standalone |
| cwd in a heterogeneous repo (`ops`), no home | unknown | none (silence) |

## Known limits

- **Sparse ownership blocks**: many repos do not have a structured `## Node ownership` (they use prose or delegate to `CLAUDE.local.md`). v1 relies on the cluster + the block where there is one; a repo without the block is resolved from the cluster alone.
- **Prose**: from the read-only `CLAUDE.local.md` we get `is_secondary_here` and, if cited, the `primary_node`; **not** the `primary_path` (we recover it from the cluster on that node, if present).
- **`real-target`**: for heterogeneous repos (`ops`) the subject is not resolvable from the cwd alone; without intent the home stays undetermined (`unknown`).
- **Multi-skill repos (container)**: for repos that host several skills under one root (`skills-repo`, ...), `subject_of(cwd)` gives the token of the repo, coarser than the naming subject (one skill). The cluster under-matches (it looks for `<repo-token>-*`, misses the `<skill>-*`); the **node** (ownership) holds anyway. A per-skill token resolver is issue #13. Marking such a repo `real-target` is not the remedy: the intent word matching produces noise.
