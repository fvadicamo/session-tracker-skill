---
name: session-tracker
description: |-
  Map, classify and navigate the user's Claude Code SESSIONS across nodes:
  open, dormant or closed, parent/child and pilot/piloted trees, an archive
  of intents and notes per session.

  Use when the user wants to:
  - close a session ("close this session", "mark it done / dropped /
    superseded");
  - recap what was done, what is open and how to continue ("where are we
    against the plan?", "what did we do?", "what is still open?");
  - check whether they are working in the right place ("am I in the right
    place?", "where should I continue?"): compares the current node and
    folder with the project's home;
  - see the global state of open items ("what is still hanging?", "dormant
    sessions", "open points in the sessions about X");
  - find or navigate past sessions ("find the session about X", "tree of
    the sessions of Y", "which sessions did I have open");
  - record an intent or a note ("note the intent of this session", "record
    as future");
  - update the map ("update the session index").

  Mark tracker content with "(tracker, last pass <date>)": records are
  snapshots, not live state.

  Dispatcher `stk` (scan|note|link|sync|index|publish|dashboard|close|branch|where|
  primary-check|repo-status|hygiene|hook|init|doctor|shim);
  extraction through subagents.

  NOT for driving a remote tmux or Claude session, and NOT for token
  accounting.
---

# session-tracker

Keeps a navigable map of all of the user's Claude Code sessions, across nodes, to find
**what is still open** among the many parentheses opened every day. The raw data
(`~/.claude/projects/*/<sid>.jsonl`) already exists; this skill distills it into one record
per session, with intent, open and closed tasks, status and relations (fork, pilot/piloted),
and makes it queryable.

Model: **orchestrator-driven**. A *pass* is a driver (this session) that fans out over the
nodes, extracts (LLM), merges and reasons at the center; `stk` does only the deterministic mechanics.

## When to use it

- "what was I doing yesterday / last week?"
- "what are the open points on project X?"
- "what is still hanging / which ghost sessions do I have?"
- "update the session map" (incremental tick)
- "note: this is a parenthesis on X, I am going back to Y" (in-session note)
- "show me the tree of the sessions about X"
- "am I in the right place? where should I continue?" (placement)

**Recap of the CURRENT session** ("what did we do?", "how do we continue?", "where are we
against the plan?"): the chat is the primary source. Enrich the answer with the tracker only
if it really has something for this session (no inventions): (a) the `stk note` notes of the
current session id (intent/past/present/future, useful after a context reset), (b) the related
sessions (same `project_path` or branch, fork, pilot).

## When not to use it

Driving a remote tmux or Claude session (this skill only calls `stk` on a remote node through
`-u <alias>`), and token or cost accounting: not covered.

## Architecture (summary)

- **`stk`** (dispatcher, deterministic, no LLM): `scan | note | link | sync | index | close |
  branch | hook | init | doctor | shim`. See `stk -h`.
- **Extraction** (LLM, scoped): from JSONL to a sanitized digest. Driver-side (subagent,
  **a small model at low effort**) for nodes whose transcripts the driver can read; on-node for
  nodes it cannot (the node's own Claude session runs the extraction and returns only the
  digest).
- **The canon** (the central store): `index.jsonl` (global index) + `<node>/events.jsonl`
  (append-only shard of the node) + `<node>/<encoded-project>/<sid>.md` (one record per
  session). With `canon_mode=local` (the default) it is `<data_dir>/store` on this node; with
  `canon_mode=ssh` it lives on `canon_host`.

Session identity = `{node, session_id}`. `node` is the node's slug, which is also the ssh
alias used for `-u <alias>`. Data details in `references/schema.md`, statuses in
`references/status-taxonomy.md`, naming conventions in `references/naming.md` (plus the data
file `naming-map.yaml`, which lives in the canon).

## Node setup

The repo is a Claude Code plugin and its own marketplace. Installation:

```
claude plugin marketplace add fvadicamo/session-tracker-skill   # or the path of a clone (dogfood: loaded in place)
claude plugin install session-tracker@session-tracker-skill
stk shim install    # ~/.local/bin/stk: the plugin's bin/ is only in the PATH of Claude's shell; ssh (-u, primary-check) and the terminal use the shim
stk init [...] && stk doctor
```

The `SessionStart` hook comes from the plugin (`hooks/hooks.json`): it must not also be in
`settings.json` (double injection; `stk doctor` reports it). The shim resolves the current
installation on every call (`STK_PLUGIN_ROOT`, then the Claude Code plugin records, then the
next `stk` in PATH that is not a shim) and goes on every node that is a target of `-u` or the
primary of a repo, with its folder in the PATH of that node's **non-interactive** ssh shell
(on macOS `~/.local/bin` is often missing from it); `stk doctor --remote` probes `stk` over
ssh on `remote_aliases` and `known_nodes`. To try the plugin without touching the node: temporary
`CLAUDE_CONFIG_DIR`, `STK_LOCAL` and `XDG_CONFIG_HOME`, then `claude --init-only --plugin-dir
<clone>`.

## Anatomy of a pass

1. **Align**: `stk sync pull` brings the canon's mirror for this node to the local staging
   (watermark = `last_indexed_uuid` in the md files). It uses `rsync -au`: newer local changes
   not yet published (close, note, branch) are protected from clobbering, because the shard is
   per node and **shared** among concurrent sessions.
2. **Scan** (no LLM): `stk scan --since <dur>` emits a JSONL manifest of the new/changed sessions
   on stdout (unchanged ones do not appear): write it to `<data_dir>/manifest.jsonl`, where the
   merge reads it. For remote nodes: `stk -u <alias> scan`.
3. **Extract** (LLM, in parallel):
   - **Readable nodes** (the driver's node and the nodes whose transcripts it can read): read
     the JSONL of the sessions in the manifest and launch **subagents** with the prompt
     `references/extraction-prompt.md`, passing explicitly a small model (for example
     `model: sonnet`) and `effort: low`. Batch about 12 to 15 sessions per agent. Each agent
     returns one digest per session. The smaller model is deliberate: extraction is mechanical
     work on self-contained context (the agent reads the JSONL it is given, not the current
     conversation), so the main loop's model is not needed and the parent session's cache is
     untouched. Semantic judgement stays at the center (step 4), where the large context matters.
   - **Nodes the driver cannot read** (service accounts): drive that node's own Claude session
     with the prompt `references/remote-extraction-prompt.md` and receive ONLY the sanitized
     digest (the raw transcript stays on the node).
4. **Merge + reason** (LLM, at the center): merge the digests, write or update the md records in
   the local staging `<data_dir>/shard/<encoded>/<sid>.md`, reason across nodes (below), then
   `stk publish` (`sync publish` + `index` and, with `canon_git=auto`, a commit of the canon, in
   batch). The deterministic join (digest + manifest to record: `dormancy_risk`, the
   `active` to `dormant` downgrade for stale sessions with open items, `pilots` and link
   materialization, reciprocal `children`, computed fields) is **`helpers/merge.py
   <digests.jsonl>`** (it reads `$STK_LOCAL/manifest.jsonl`); you provide the digests and the
   semantic judgement (status, overrides).

### Merge rules (critical)

- **`## user_notes` is sacred**: never rewrite it. Notes (`intent` included) come from `note`
  events (with an `id`) and are **upserted by `id`** (re-running a pass does not duplicate).
- **`status`**: update from the digest's `proposed_status` ONLY if `status_source: auto`. If
  `status_source: user`, leave it.
- **`forked_from` / `children`**: `forked_from` comes from the JSONL; rebuild `children` as reciprocals.
- **`pilots` / `piloted_by`**: materialize from the digest's `pilot_candidates` and from `link`
  events, on the records the pass rewrites (the sessions with a digest in it): a link to a
  session unchanged since the last scan lands at the next pass that includes it (`scan --all`
  forces one); same for the reciprocal `children`. Discard candidates that are not plausible node slugs (noisy heuristic). Cross-node links may be forward references (`session_id: null`) until the piloted node is scanned.
- **`dormancy_risk`** and the timeline are computed: see `references/status-taxonomy.md`.
- **Sanitization**: records carry only intent and summary, NEVER raw commands or credentials.

## Procedures

### Bootstrap (first full pass)
Local node only, 30-day window. `stk scan --since 30d`, then extract in batches with subagents
(small model, `effort: low`), merge, `stk publish` (publish + index, and a commit with
`canon_git=auto`). Validate taxonomy, extraction, dormancy and queries before adding remote legs.

### Incremental tick
Same pass; the scan returns only the delta (changed/new). For every changed session re-read the
new events (from the watermark) and ask: new open tasks? a new branch? a status change? Update
the record. Run by hand or on a schedule for a dormancy sweep.

### Notes between passes (no LLM)
`stk note --current --kind <intent|past|present|future> "<text>"` (or `--session <id>`).
Immediate append to the shard plus a stub md, without waiting for a pass. Capture the intent
while it is fresh.

### Cross-node coverage
Add the remote legs: `stk -u <alias> scan` (delta pull plus central extraction for a readable
node) or on-node extraction for a node you cannot read (sanitized digest). Resolve the
forward-reference pilot links of the bootstrap. Requires the ssh aliases configured on the
driver.

`-u <alias>` is not only for `scan`: the allowlist is `scan close note publish dashboard
repo-status`. Everything runs **on the remote node** (open tab, resumability and the shard are
local concepts of that node), with safe argument quoting. Useful cases: `stk -u <alias>
dashboard --triage` (the **live tabs of that node**), `stk -u <alias> close --session <sid>
--status done` (close a session that lives there), then `stk -u <alias> publish` to propagate to
the canon. The other subcommands (index, where, branch, sync, ...) stay local.

### Re-homing to another project (rehome)
A session started in the wrong folder shows up in the wrong resume picker and stays classified
under the wrong project. **It is not a `mv`**: the association lives in six places (transcript,
title sidecar dir, the `cwd` field of every entry that has one, the record in both copies, shard
and canon, `history.jsonl`, scratchpad/`session-env`), and **three are silent** if you skip them.
Only the transcript decides which folder the session appears in; an unrewritten `cwd` leaves the
record in the right place **with the `project` / `project_path` of the old project**, so the
session belongs to another project in every query. Procedure, two-way checks and measured traps:
**`references/rehome.md`**.

## Queries

`stk sync pull`, then filter `index.jsonl` (machine-first, jq) and open only the relevant md
files. With `canon_mode=ssh` the pull leaves a read-only global mirror in `$STK_LOCAL/canon`
(`index.jsonl` of every node plus the records): global queries run against it. With
`canon_mode=local` the canon is the local store itself (`$STK_CANON_PATH`): query it directly,
`canon/` is only a copy of the store one round behind. Ready-made dashboard for "what is still
open": **`helpers/dashboard.py <root>`** lists the non-closed records sorted by `dormancy_risk`.
For the **live** view without a pull, `stk dashboard` runs it on the canon (locally, or over
ssh with `canon_mode=ssh`). The dashboard includes **every** non-closed record (the `unknown`
ones not yet extracted too: hiding them under-reported the open items) and shows the **EV**
column (`n_events`) to tell an empty stub (small EV) from a real session not yet extracted. The
**triage** view (what to reopen or close): `stk dashboard --triage` (helper `triage.py`) clusters
the non-closed records into *open now* (live tab, from `~/.claude/sessions`), *resumable* (JSONL
present, with the ready `cd ... && claude -r <sid>` command), *not resumable* (pruned transcript),
*other nodes*. Open tab and resumability are relative to the **node where you run it**: for the
live tabs of another node, `stk -u <alias> dashboard --triage`. Leftover empty stubs are cleaned
with `stk hygiene [--apply]` (local shard).

```
stk sync pull                       # align the local mirror (offline queries)
stk dashboard                       # global open items, risk-ranked (unknown included, EV column)
stk dashboard --triage              # actionable local view (open now / resumable / ...)
stk -u <alias> dashboard --triage   # live tabs and resumable sessions OF that node
stk hygiene                         # dry run: lists orphan empty stubs
stk hygiene --apply                 # removes them (local shard only)
```

`dashboard` and `dashboard --triage` color the output on a tty (RISK/STATUS by color, dim
metadata, the resume command highlighted); in a pipe or a capture it stays plain text.
`FORCE_COLOR=1` forces it, `NO_COLOR=1` disables it; through `-u` or ssh the color follows the
local side.

- *yesterday / monday*: time filter on `last_activity_at`, non-terminal status.
- *open points on X*: `project` / `tags` + non-terminal status + non-empty `open[]`; merge and
  dedup pilot/piloted.
- *what is still hanging*: high `dormancy_risk`, sort.
- *tree of X*: records with `forked_from.session_id == X` (the authoritative edge) plus the
  `pilots` branch. `children[]` is a convenience denormalization, materialized only when trunk
  and child fall in the same pass: navigate on `forked_from`, not on the reciprocal.
- *where did I discuss Y*: text search on `goal` + `summary`.
- *find the session "X"* (by name): filter on `name` (indexed; reflects `/rename`, falls back
  to the AI title), then `goal` + `summary`.
- *am I in the right place / where do I continue*: `stk where --current` (deterministic
  placement: the subject's home versus where you are). See "Placement".

## Placement: continue in the right place

It happens to open Claude in some folder, or on a secondary node, and start working on a
project whose **home is elsewhere** (canonical folder plus primary node). `stk where` detects the
mismatch and proposes where to continue. Same mechanics/policy split as the rest of the skill:
**`stk where` computes** the candidates deterministically, **Claude judges** whether and how to
propose.

- **Mechanics** (`stk where`, helper `helpers/where.py`): reads the index (the store with
  `canon_mode=local`, the cached mirror `$STK_LOCAL/canon/index.jsonl` with `ssh`), the naming
  map, and the `CLAUDE.md` / `CLAUDE.local.md` files in the cwd's tree. READ-ONLY, **no network
  and no pull** (best effort: a stale mirror lowers the confidence; consider `stk sync pull`
  when precision matters). It derives the subject's *home* in layers: **ownership block
  `## Node ownership`** (authoritative) > **read-only prose** (low) > **emergent cluster** from
  `index.jsonl` (where the work lands). **No new registry**: the home is derived. It emits JSON
  with `verdict` (`here|elsewhere|unknown`) + `candidates` (`kind`, `confidence`, `score`,
  `evidence`, `related_sessions`, possibly `trunk`). A naming map declared in the config but
  missing, or malformed, is an error (exit 2, `naming_map_error`), not a map with no entries.
- **Policy** (Claude): propose **only** if `verdict=elsewhere` with `confidence` medium or
  high. Kinds: `relocate-node` (`ssh <node>` + `cd`), `relocate-folder` (`cd <path>` on the same
  node), `branch-from-trunk` (resume the live trunk and `/branch` instead of starting over),
  `stay-standalone` (here is fine). If `verdict` is `here` or `unknown`, **propose nothing**.
- **When it fires**: (a) **proactively at birth**: the hook (with `hook_placement=on` in the
  config, fresh sessions only, after the intent if asked) injects the clause that runs
  `stk where --current`; (b) **on demand**: "am I in the right place?", "where should I
  continue?".
- **Anti-noise**: confidence threshold plus Claude as a second barrier; no re-proposal if you
  are already an anchor of the cluster (`here`); on a child (`forked_from`) no branch proposal
  towards its own lineage; the decision "I stay here" can be recorded with `stk note --kind
  placement "<reason>"` so future resumes do not insist.
- **Placement and rehome are two remedies for the same symptom, chosen by direction**:
  `relocate-folder` moves **you** (`cd <path>`) and leaves the session where it is, right while
  the session is fresh; if the work is already inside that session and it must stay reachable
  from the right folder, the **session** moves (see "Re-homing to another project" under
  Procedures, and `references/rehome.md`).

Algorithm, scoring, thresholds, examples and known limits (scattered ownership blocks; a
`real-target` subject not resolvable from the path alone, so the intent is needed) in
`references/placement.md`.

## Primary check: is the primary aligned?

An extension of `where` that **uses the network** (unlike `where`, which is read-only by
contract): when the ownership is declared with a primary other than the current node,
`stk primary-check` compares the local state (always live) with the primary's over ssh (remote
`repo-status`, cached 30 minutes on the remote side only). Typical case: a file edited by
mistake on a secondary node and two commits left unpushed on the primary, both found only by
checking by hand.

- **Mechanics**: `stk repo-status <path>` (pure bash, one-shot git state: branch, dirty, ahead,
  behind, no `git fetch`) also runs through `-u <alias>` (it is in the allowlist).
  `stk primary-check` uses it locally and remotely, and crosses the result with the
  `related_sessions` already computed by `where` to suggest where to resume.
- **Policy** (Claude): consider running it when `where` reports a declared ownership whose
  primary is not the current node (do not repeat it in the same session). `applicable:false` or
  a failed command: silence. Empty `issues`: silence. Non-empty `issues` (`local-dirty`,
  `primary-dirty`, `primary-ahead`, `primary-unreachable`): report the problem and use
  `related_sessions` to propose the node, canonical session or folder where to resume, instead
  of proceeding blindly from the secondary.

JSON contract, cache schema, issues table and known limits (an ssh alias that is not the node
slug is not validated) in `references/primary-check.md`.

## Explicit closure of a session

When the user says "close this session" (even with open questions left), run this procedure
before invoking `stk close`:

1. **Identify the session**: normally the current one (`stk close --current`); otherwise
   `--session <id>`. To close several sessions with the **same** outcome at once (drop a group
   of empty artifacts, mark a series of experiments `done`) repeat `--session <id>` (batch): they
   share `--status/--add-tag/--add-link/--rationale`, while the per-session fields
   (`--name/--class/--distill-target/--summary`) are rejected in a batch (do those one by one).
   For a session that lives on another node: `stk -u <alias> close --session <id> ...`.
2. **Read the record's current state**: `<data_dir>/shard/<encoded>/<sid>.md` if it exists. Note:
   status, tags, links, goal, summary, recorded open items.
3. **Compare with the content of the current conversation**:
   - Which themes were actually touched? Do the tags cover them?
   - PRs, branches, commits, issues, URLs mentioned that should become `--add-link`?
   - Recurring keywords (technologies, files, people, decisions) missing from the tags?
   - Does the `summary` reflect what was done, or is it stale?
4. **Identify the loose ends**:
   - Open items of the record NOT resolved in the session.
   - Sub-themes or parentheses opened during the current session.
   - Postponed decisions.
5. **Derive the canonical name and apply it**, reading the rules, not remembering them. The name
   derives from the map, and the map is opened every time: a rule that lives only in the data
   file (a comment next to a `contexts` entry) is not in context until you read it. Before
   proposing the name run:
   ```
   cat <skill>/references/naming.md <naming_map of the config, default <data_dir>/naming-map.yaml>
   ```
   and in the proposal **cite the `contexts` row applied** (for example "`<repo>: <subject>` to
   `<subject>[-<issue number>]-<theme>-<action>`"). A name already in the record or in the title
   **does not count as conforming until it is compared with that row**: it may have been proposed
   at the opening without the map. The hook injects the entry resolved from the cwd (see
   "SessionStart hook"), but it is a reminder of the row, not a substitute for reading it. If
   there is no map (default path absent), apply only the generic rules of `references/naming.md`
   and derive the subject from the content.
   - From the analyzed content plus the context (repo/cwd) derive
     `<subject>[-<issue number>]-<theme>-<action>` (number without `#`, absent only without an
     issue). The subject is the real TARGET (never the repo name); resolve it with the
     `contexts` / `kb_orgs` / `tokens` sections of `naming-map.yaml`.
   - Distill (a fork that distills into a skill): go back to `forked_from`, read the parent's
     `name` and compose `<parent-name>-<skilltag>-distill-<YYYY-MM-DD>` (`--class distill`,
     `--distill-target <skill>`).
   - **Claude picks the name, not the user, and the closure does not stop to wait for it.** An
     invoked `close` is the instruction to close: deriving the name is derivation work, not a
     preference, so asking turns a command into a round of confirmations. If two readings remain
     plausible, take the one that describes the **block declared at the opening**, not the
     largest side effect, and say in one line which one was discarded and why.
   - Compare with the current name (the `custom-title` captured by the scan): if it already
     conforms up to the marker, say so and proceed. Otherwise close anyway passing `--name`, and
     **offer** `/rename <name>` as a line the user can run to align the harness title too
     (Claude cannot run it). An unaligned title blocks nothing: the record already has the right
     `name`, and that is what the index queries.
   - **The `wip-` marker drops here**: a live session is called `wip-<name>`, a closed one
     `<name>`. `--name` **always** gets the form without `wip-`, because the record's state is
     already in `status` and `name` must have one spelling. `stk close` rejects it with
     `naming_policy=error` and with `warn` alike (see "Name guard" in the step that
     invokes `stk close`).
6. **Ask only if necessary**, and the name is not among the things to ask:
   - If the session touched several themes and it is unclear which are actually closed: ask.
   - If there are important loose ends: ask whether they are dropped or tracked elsewhere (an
     issue, another session).
   - If important keywords for future findability are missing: propose and confirm.
7. **Residual sub-tasks to track separately**: record them FIRST with `stk note --kind future
   "..."` so they stay visible as open points after the main record is closed, and write them
   also where the project keeps its to-dos (issue, backlog), which is what the people working on
   that project read.
8. **Invoke `stk close`**:
   ```
   stk close --current --status done \
     --name <canonical-name> --class task \
     --add-tag X --add-tag Y \
     --add-link https://github.com/.../pull/123 \
     --summary "<updated summary if needed>" \
     --rationale "<reason for closing, optional>"
   ```
   Batch and cross-node (see step 1):
   ```
   # batch: same outcome on several sids (no per-session fields name/class/summary)
   stk close --session <sid1> --session <sid2> --session <sid3> \
     --status dropped --add-tag cleanup --rationale "experiment cleanup"
   # a session that lives on another node:
   stk -u <alias> close --session <sid> --status done --name <canonical-name>
   stk -u <alias> publish    # propagates to the canon from there
   ```
   Status: `done` (work concluded), `dropped` (decision not to proceed), `superseded`
   (replaced).
   **Open-tab guard**: `stk close` refuses if the session is a live tab (pid in
   `~/.claude/sessions`), to avoid closing work in progress; `--force` to override. Self-close
   (`--current`) is always allowed. In a batch the guard **skips** (warn) the open sid and goes on
   with the others, instead of aborting.
   **Name guard** (`helpers/naming.py check`, per the config's `naming_policy`: `error` rejects as
   described here, `warn` (the product default) reports on stderr and accepts, except the two
   record invariants, `wip-` and characters outside the lexicon, which it rejects like `error`;
   `off` does not check): with `error`, `--name` is rejected without writing anything if it starts with `wip-`,
   if it leaves the lexicon, if the final action is not in the closed set of
   `references/naming.md`, if the first token is not the subject (or one of the subjects, when
   the entry lists several) that `naming-map.yaml` assigns to the session's cwd (repo basename,
   the `<entry>-<slug>` prefix of a worktree, `<kb token>-<tier token>-` inside a knowledge base
   declared in `kb_layout`, for the tiers of `kb_tiers`, the `kb_orgs` entry for the umbrella and the function repos
   under the orgs folder, or `<contexts[org]>[-<function repo>]` for an org without an entry),
   or if it is the repo name when the map marks it `real-target`; `--class distill` requires
   the suffix `-<skilltag>-distill-<YYYY-MM-DD>`. With a cwd unknown to the map the subject is
   not checked and the other rules remain. The rejection line names the rule; if the guard
   cannot run (`naming.md` unreadable, `naming-map.yaml` declared but missing or malformed)
   with `error` the close stops (`--force` writes the name unchecked and says so), with `warn` it accepts and says the name was not checked. `--force` passes the subject and action rules (never `wip-` or the lexicon), and forces the live tab too: use it when
   the rule is wrong for that case, and say so in `--rationale`. A malformed `window_prefix`
   does not stop the guard: it only disables the tmux window clause.
   `--name` / `--class` set `name_source=user` (and `class`); `status_source` becomes `user`.
   The automatic merge of future passes will NOT overwrite name, class or status.
9. **Propagate to the canon**: `stk publish` (= `sync publish` + `index` and, with
   `canon_git=auto` in the node's config, a git commit and push of the sessions subtree in the
   repo that contains the canon; the default `off` stops at the index). `close` writes only the
   local shard; without a publish the closed session (and its `name`) does NOT appear in the
   global index or the dashboard until a pass runs. Meant for the end of a session or block, not
   for every close.

## Branching a session (/branch, /fork, /rewind)

`/branch` (and `/fork`, `/rewind`) forks the conversation into a child session: it takes you
**live into the child** (same process, `CLAUDE_CODE_SESSION_ID` updated) and the child inherits
the trunk's history with `forkedFrom={sessionId,messageUuid}` on every copied event. `/branch` is
a slash command of the TUI: Claude cannot run it, it proposes it (like `/rename`). Two sides, two
moments.

### Trunk side (before branching): optional but recommended
When the user wants to branch from where you are:
1. Run the pre-analysis of a closure (steps 1 to 5 of "Explicit closure"): derive the canonical
   name of the **trunk** and the expected one of the **child**, and identify which `open[]`
   items move to the child.
2. `stk branch (--current|--session <id>) --name <trunk-name> --child <child-name> [--add-tag
   X]...`: checkpoints the trunk at `status=branched` (a user override, not terminal) and prints
   the commands to run by hand.
3. Propose to the user, **in the trunk**: `/rename <trunk-name>` (the harness title changes here:
   after `/branch` there is no way back) and then `/branch <child-name>` (the title becomes the
   child's `customTitle`, no separate `/rename` for it).

The trunk checkpoint is best effort: if the user just runs `/branch`, the trunk stays `active`
and unnamed. The child side (below) is automatic instead.

### Child side (first turn after /branch): automatic
`/branch` fires `SessionStart` with `source=resume`; the hook injects the request to register
the link (see "SessionStart hook"). On the first turn in the child run:
```
stk branch --register --current
```
It reads `forkedFrom` from the **field** of its own transcript (jq, **never grep**: the transcript
may contain the string "forkedFrom" as text) and writes the light stub: `forked_from` (the
authoritative edge) + `name` (from the custom title), `status` left auto so the next pass refines
the record. No-op if the session is not a branch. Then record the child's intent: `stk note
--current --kind intent "..."`. The reciprocal `children` on the trunk materialize at the next
pass whose scan manifest lists the child (the merge reads `forked_from` from the whole manifest
and keeps the children a record already has), and the global index at the next `stk publish`;
tree queries rely on `forked_from` (see Queries),
not on the reciprocal. Keep the action light: if the user already has a request on the first
turn, register and go on, do not block.

**Caveat (empty first turn)**: if the child's first turn is the automatic "Continue from where
you left off" with nothing pending, the hook's clause **does not run**: no `stk branch
--register`, no `/rename` proposal. A child branched and abandoned at once stays with a
non-canonical title and no record. If you wake up in an already-branched child, do not assume
the registration happened: check it and, if missing, do it on the first turn.

**Child title**: `/branch` often leaves it with a **non-canonical** automatic title (the harness
derives it from the child's seed message, for example a command such as `/draft-post`, with the
suffix ` (Branch)`; it does NOT inherit the trunk's title). If the title contains the `<command-`
tag, ends with ` (Branch)`, or does not follow `references/naming.md`, derive the canonical name
(from the content plus the trunk) and **propose `/rename wip-<name>`** (Claude cannot run it): a
child is born live like any session, so it is born with the marker. If the child already has a
clean title (the user passed the name to `/branch`), propose nothing.

## Development backlog

This section is for whoever maintains session-tracker itself. Its structural loose ends (bugs,
sub-features, design decisions) are the issues of its repository, distinct from the future notes
of a single session (per sid, in the records). A residue of the user's own work never goes there:
it goes where the user's project keeps its to-dos (step 7 of "Explicit closure").

## Tests

Deterministic black-box tests in `tests/run.sh`, hermetic (temporary data dir, config, store
and Claude home): the mechanics of every subcommand, the hook with every clause on and off, the
naming guard (positive, negative and by mutation), the configuration with every value and the
bad ones, `doctor`, `init`, the plugin files, the shim. The LLM derivation of the name at closure
is NOT covered (judgement, not deterministic code). Run them **before committing changes to
`stk` or the helpers**: `bash tests/run.sh` (deps: bash, jq, python3, uv). It runs every check
and exits non-zero if any failed.

## SessionStart hook

`stk hook` comes from the plugin (`hooks/hooks.json`); a copy of the hook in the node's
`settings.json` would inject the context twice, and `stk doctor` reports it. On `source` in `{startup, resume, clear}` and
with no intent recorded yet, it injects an `additionalContext` made of the **clauses enabled in
the node's config** (`hook_ask_intent`, `naming_policy`, `hook_tmux_tab`, `hook_placement`,
`hook_primary_check`, plus the text of `hook_extra_context_file` at the end). With the product
defaults only the name proposal is on (`naming_policy=warn`): propose `/rename wip-<name>` as
soon as the theme is clear, with the naming context resolved from the cwd appended (the
`contexts` row that applies, the subject, the set of actions). On `resume` / `clear` it always
adds the clause to register a possible branch (`stk branch --register --current`). It never
writes records: the writes are done by Claude on the first turn. Clause by clause, what it says
when the map is missing or the helper cannot run, and the log: `references/hook.md`.
