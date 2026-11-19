# The SessionStart hook

What `stk hook` injects, clause by clause, and what its log says. Loaded on demand from
`SKILL.md`, "SessionStart hook".

`stk hook` comes from the plugin (`hooks/hooks.json`); a copy of the hook in the node's
`settings.json` would inject the context twice, and `stk doctor` reports it (see "Node setup"). On `source`
in `{startup, resume, clear}` and with no intent recorded yet, it injects an `additionalContext`
made of the **clauses enabled in the node's config** (`hook_ask_intent`, `naming_policy`,
`hook_tmux_tab`, `hook_placement`, `hook_primary_check`, plus the text of
`hook_extra_context_file` at the end; see the README, "Node configuration"). `stk init` writes
that file (the keys passed are active, the others commented with their default) and `stk doctor`
says what is configured and where the config is broken: a key with a typo, a value out of its
domain, a relative path, a `naming_map` declared but missing; exit 1 on errors, no network. With
the product defaults only the name proposal is on (`naming_policy=warn`). With
`hook_ask_intent=on` it asks Claude to record the goal on the first turn through `stk note
--session <id> --kind intent`; with `naming_policy` other than `off`, if the title is not yet
canonical, to **propose `/rename wip-<name>` as soon as the theme is clear** (per
`references/naming.md`): the name proposal applies to **every fresh session, startup included**,
not only to branches. The `wip-` marker says the session is not closed, and drops at the close,
where `--name` gets the same value without it. Inside tmux, with `hook_tmux_tab=on`, it adds the
clause on the window, per `references/naming.md` "tmux window". To the name request the hook
appends the **naming context resolved from the payload's `cwd`** (`helpers/naming.py context
--text`): the `contexts` row of `naming-map.yaml` that applies to that folder **with its
comment** (or the `kb_orgs` entry), the subject that follows, the set of actions read from
`references/naming.md`, and the request to read the two files anyway and cite the row in the
proposal. On a `real-target` repo it says the subject is not the repo; on a cwd unknown to the
map it says so instead of inventing; with no map at all it says to apply the generic rules only.
If the helper cannot run (no `uv` in the hook's PATH, a crash) the hook still injects the rest,
says in the text that the naming context was not resolved, and marks the log line
`degraded:naming-context:<reason>`. It also adds, on every fresh session, with
`hook_placement=on` the **placement clause** (after the intent: `stk where --current`, propose
`cd` / `ssh` / `/branch` only if `verdict=elsewhere` with enough confidence; see "Placement") and
with `hook_primary_check=on` the **primary-check clause** (if the declared ownership has a
primary other than the current node, consider `stk primary-check --current --human` and report
any `issues`; see "Primary check"). On `resume` / `clear` it always adds the clause to register a
possible branch (`stk branch --register --current`, no-op if it is not one): it is core, it has no
switch. With no clause on it emits nothing (`skip:nothing-to-inject` in the log). It skips
`compact` and the other sources. By design the hook neither parses nor writes records (no race
with the transcript flush, no grep-versus-jq hazard): it only injects, the writes are done by
Claude on the first turn with the complete transcript. Not interactive: the question is asked by
Claude. Diagnostic log in `$STK_LOCAL/hook.log`.

## What the log says

One tab-separated line per call: time, the session id (its first eight characters once the
id and the source passed the checks; the full id on a skipped source; `?` when missing), the
`source`, and a decision. Decisions: `inject:<source>`, with ` degraded:naming-context:<reason>`
appended when the naming helper could not run; `skip:source=<source>` (compact and the others);
`skip:no-sid`; `skip:intent-exists`; `skip:nothing-to-inject`; `inject:<source>:branch-only` (an
intent exists, but at `resume` or `clear` the branch registration clause still goes out). Warnings on their own line:
`warn:<key>=<value> invalid (on|off), counts as off` for the hook switches and
`warn:naming_policy=<value> invalid (off|warn|error), counts as warn`, written only when the
clause is evaluated (the tmux one only inside tmux and with `naming_policy` other than `off`);
`warn:<key>=<value> relative: config paths are absolute or start with ~/` for
every relative path of the config, which the hook also states at the start of the injected text
("Invalid session-tracker config") and never reads; `warn:hook_extra_context_file=<path>
unreadable`. With a relative `data_dir` the log cannot be written there and goes to stderr. A
payload without `cwd` falls back to the hook's working directory.
