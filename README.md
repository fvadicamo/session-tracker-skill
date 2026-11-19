# session-tracker

A navigable map of all your Claude Code sessions, across every machine you work on, to find
**what is still open** among the many parentheses opened every day: one record per session with
its intent, open and closed tasks, status and relations (fork, pilot/piloted), queryable from a
dashboard, and a closure procedure that gives each session a canonical name.

It ships as a Claude Code plugin: a skill (`SKILL.md`), a `SessionStart` hook, and the `stk`
dispatcher that does the deterministic part (scan, notes, sync, index, close). The semantic part
(extracting what a session was about, judging its status) is done by Claude during a *pass*.

This README explains **how it works** (architecture, data flow, configuration). The operating
instructions Claude follows are in `SKILL.md`; the data model in `references/schema.md`; the
statuses in `references/status-taxonomy.md`; the naming conventions in `references/naming.md`.

## The problem

Claude Code leaves on every machine a raw log per session in
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. The logs are complete but unreadable and
not queryable: "what was I doing yesterday?", "which points are still open on project X?",
"which ghost sessions did I leave behind?" have no direct answer. The skill distills those logs
into **one record per session** (intent, open and closed tasks, status, fork and pilot/piloted
relations) and makes them queryable across nodes.

Model: **orchestrator-driven**. A *pass* is a driver (a Claude session) that fans out over the
nodes, extracts with the LLM, merges and reasons at the center. The `stk` dispatcher only does
the deterministic mechanics (enumeration, notes, sync, index, commit); the semantic judgement
is the driver's.

## Install

The repo is the plugin and its own marketplace:

```
claude plugin marketplace add fvadicamo/session-tracker-skill   # or the path of a clone
claude plugin install session-tracker@session-tracker-skill
```

The plugin's `bin/` is in the PATH of Claude's Bash shell only, so the shim is installed from a
Claude Code session (`! stk shim install`), or from a terminal through the install record:

```
"$(jq -r '.plugins["session-tracker@session-tracker-skill"][0].installPath' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json")"/bin/stk shim install
```

It writes `~/.local/bin/stk`, for ssh (`-u`, `primary-check`) and for your terminal: put
`~/.local/bin` in your PATH if it is not. From there:

```
stk init [...]            # node config, optional ("Node configuration" below)
stk doctor [--remote]     # what is configured, where the hook comes from, what `stk` resolves to
```

Dependencies: `bash` (3.2, the one macOS ships, is enough), `jq`, `python3` and [`uv`](https://docs.astral.sh/uv/) (the Python helpers
run with `uv run --with pyyaml`, nothing is installed globally; the first run downloads pyyaml),
`rsync` (every `publish`, local or remote, copies the staging with it), `flock` (serializes
`index` and `publish`) and `git` (`doctor`, `repo-status`, and the commits of the canon with
`canon_git=auto`); `ssh` for a canon or nodes on other hosts; `tmux` only for the optional
window clause.

**Zero configuration works**: with no config file the tool is a single-node tracker with a local
store under `~/.local/session-tracker/store`, it never touches git and sends no tracker data over
the network (the only traffic is `uv`'s: pyyaml and, where no Python 3.12 is installed, a managed
CPython 3.12 on the first run, then a periodic cache check against PyPI), and the hook
only proposes a canonical name for new sessions. Everything else (a central store on another
host, commits of the store, placement checks, the intent question) is opt-in.

The plugin's `bin/` is in the PATH of Claude's Bash shell only, and the installation path carries
the version: the **shim** (`shim/stk`, written by `stk shim install`) resolves the current
installation on every call (`STK_PLUGIN_ROOT`, then the Claude Code plugin records in the Claude
home, `CLAUDE_DIR` or `CLAUDE_CONFIG_DIR` or `~/.claude`, under `plugins/`, where a marketplace
added from a local path means the folder read in place and not the cached copy, then the next
`stk` in PATH that is not a shim) and runs its `bin/stk`. Install it on **every** node that is a
target of `-u` or the primary of a repo (it needs `python3`), and keep its folder in the PATH of
that node's **non-interactive** ssh shell, which on macOS often lacks `~/.local/bin`:
`stk doctor --remote` measures it from here.

The `SessionStart` hook comes from the plugin: do **not** add it to `settings.json` too, or the
context is injected twice (`stk doctor` reports it). A marketplace added from the path of a clone
loads the plugin in place (dogfood): changes apply from the next session or after
`/reload-plugins`. To try a clone without touching your node, isolate the session with temporary
`CLAUDE_CONFIG_DIR`, `STK_LOCAL` and `XDG_CONFIG_HOME` and run
`claude --init-only --plugin-dir <clone>` (it runs the `SessionStart` hooks only and exits). See
`CONTRIBUTING.md`.

## The three storage levels

```
[1] RAW LOGS            ~/.claude/projects/<encoded-cwd>/<sid>.jsonl
    (per node, source)     written by Claude Code, never modified by the skill
        |  scan + extraction (LLM) + merge      <- one "pass"
        v
[2] LOCAL STAGING       <data_dir> (default ~/.local/session-tracker/)
    (per node, not git)    node, shard/<encoded>/<sid>.md, manifest.jsonl,
                           naming-map.yaml (copy), hook.log
        |  stk sync publish    (rsync into the node's subfolder of the canon)
        v
[3] THE CANON           <data_dir>/store (canon_mode=local, default)
    (central store)        or <canon_host>:<canon_path> (canon_mode=ssh)
                           <node>/<encoded>/<sid>.md   one record per session
                           <node>/events.jsonl         append-only shard of the node
                           index.jsonl                 derived global index
                           naming-map.yaml             global naming data
        |  (canon_git=auto)  git commit  ->  git push
```

With `canon_mode=local` the canon is a folder on this node; with `canon_mode=ssh` it lives on a
host that every node reaches over ssh, and the other nodes keep only their local staging `[2]`
and sync it with rsync. If the canon sits inside a git repo, `canon_git=auto` makes `stk publish`
commit and push it.

Identity of a session = `{node, session_id}`. `node` is the node's slug, which is also the ssh
alias used for `-u <alias>`. Every node owns only its own `<node>/` subfolder of the canon, so the
`rsync` calls never step on each other.

## The `stk` dispatcher

`stk [-u <alias>] <subcommand> [args]` (see `stk -h`). Deterministic, no LLM.

| subcommand | what it does | where |
|---|---|---|
| `scan [--since <dur>] [--all]` | enumerates the node's raw `.jsonl` files and emits a JSONL manifest (one line per session: id, path, timeline, last_uuid, fork, pilot candidates, scan_status) | local, or `-u <alias>` |
| `note (--current\|--session <id>) --kind <intent\|past\|present\|future\|placement> "<text>"` | appends a note event (with its own id) to the staging and writes it into the record's `## user_notes` under that id; a pass never rewrites that section | local, or `-u <alias>` |
| `link --pilot <id> --piloted <node>:<sid> [--label <s>] [--confidence low\|medium\|high]` | records a pilot to piloted link event; the merge writes it into the records at the next pass that rewrites them (a session unchanged since the last scan gets it with `scan --all`) | local |
| `sync (pull\|publish\|both)` | `pull`: canon to staging, plus a read-only global mirror in `canon/`; a transfer that fails (host unreachable, partial copy) is an error, and `both` does not publish after it; only a canon or a node slice that does not exist yet is "the first round", exit 0. `publish`: staging to the node's subfolder of the canon | local and canon |
| `index` | rebuilds the global `index.jsonl` from the records of every node (serialized with flock) | canon |
| `close (--current\|--session <id>)... [--status done\|dropped\|superseded\|branched] [--name <s>] [--class task\|distill] [--distill-target <s>] [--add-tag <t>]... [--add-link <u>]... [--summary <s>] [--rationale <s>] [--force]` | closes **one or more** sessions (user override protected); open-tab guard and name guard (subject from the cwd through `naming-map.yaml`, action from the closed set of `naming.md`, no `wip-`; `--force` skips the open-tab guard and the subject and action rules, never `wip-` or the lexicon) | staging, or `-u <alias>` |
| `branch (--current\|--session <id>) --name <trunk> --child <child> [--add-tag <t>]...` | trunk side: checkpoint at `status=branched` and prints the `/rename` and `/branch` to run by hand | staging |
| `branch --register (--current\|--session <id>)` | child side (first turn after `/branch`): writes the `forked_from` stub read from the transcript | staging |
| `dashboard [--triage]` | global open items (risk-ranked, `unknown` included, `EV` column); `--triage` clusters by actionability (open now / resumable / not resumable / other nodes) | canon, or `-u <alias>` |
| `where (--current\|--session <id> \| --cwd <p> --node <n>) [--intent <s>] [--human]` | read-only placement: the subject's home versus where you are, JSON `verdict` plus candidates | local (no network) |
| `repo-status <path>` | one-shot git state of a path (branch, dirty, ahead, behind), pure bash, no fetch | local, or `-u <alias>` |
| `primary-check (--current\|--session <id> \| --cwd <p> --node <n>) [--human] [--force]` | extends `where`: compares the live local state with the primary over ssh (remote `repo-status`, 30-minute cache); `issues` and `related_sessions` say where to resume | local plus network to the primary |
| `hygiene [--apply]` | lists (dry run) and with `--apply` removes orphan empty stubs | local staging |
| `publish [--no-push]` | end-of-block pass: `sync publish` + `index` and, with `canon_git=auto`, `git commit` of the subtree **and `git push`** (`--no-push` for the commit only); with `canon_git=off` (default) it stops at the index | local, canon, git |
| `init [--node <slug>] [--canon-mode local\|ssh] [--canon-host <h>] [--canon-path <p>] [--canon-git auto\|off] [--naming-policy off\|warn\|error] [--force]` | writes the config file: the keys passed are active, the others commented with their default and a line saying what they do; never overwrites without `--force` | config |
| `doctor [--remote]` | says what is configured and what is not: unknown or misspelled keys (warn, with the nearest key), values out of their domain, relative paths, a `naming_map` declared but missing or malformed, an unreadable overlay, the installed plugin, where the hook comes from (plugin or `settings.json`; both means double injection), what `stk` resolves to in PATH, tools. Exit 1 on any error. No network, except `--remote`: over ssh `command -v stk` on every alias of `remote_aliases` and every slug of `known_nodes` other than this node | config |
| `shim (install [--dest <path>] [--force] \| resolve)` | `install`: writes the shim to `<path>` (default `~/.local/bin/stk`); replaces its own shim or a symlink to a session-tracker `bin/stk`; anything else only with `--force`. `resolve`: prints the `bin/stk` the shim would run here | node |
| `hook` | the `SessionStart` entry: injects the clauses enabled in the config ("Node configuration") | local |

`-u <alias>` runs the subcommand on a remote node over ssh. **Allowlist**:
`scan close note publish dashboard repo-status`. Everything runs **on the remote node**, because
open tabs, resumability and the shard are local concepts of that node (for example
`stk -u <alias> dashboard --triage` detects the live tabs *of that node*). The other subcommands
stay local and talk to the canon over rsync and ssh.

## Use cases with examples

Every command is copy-paste. Replace `<sid>` with a full session id and the
paths with real ones.

**See what is still open (the typical question):**
```sh
stk sync pull            # align the local mirror of the canon (offline queries)
stk dashboard            # global open items, risk-ranked, with unknown + EV column
stk dashboard --triage   # actionable view: what to reopen versus what to close
```
`dashboard` and `dashboard --triage` color the output (ANSI) in a real terminal: RISK and
STATUS by color, dim metadata, the name and the resume command highlighted. In a pipe or a
capture (`| less`, or `! ...` inside Claude) the output stays plain text. Force or disable with
`FORCE_COLOR=1` / `NO_COLOR=1`. Through `-u <alias>` or ssh the color follows the local side.

**Resume an open session:** the triage prints the ready command.
```sh
stk dashboard --triage
# under "## RESUMABLE" copy the line:
cd /path/to/project && claude -r <sid>
```

**See the live tabs of another node:**
```sh
stk -u <alias> dashboard --triage   # open tabs and resumability computed ON that node
```

**Close the current session (with a canonical name and metadata):**
```sh
stk close --current --status done --name <canonical-name> --class task \
  --add-tag theme1 --add-tag theme2 \
  --add-link https://github.com/org/repo/pull/123 \
  --summary "what was done" --rationale "why I am closing it"
stk publish              # propagates to the canon; with canon_git=auto also commit + push
```

**Close a group at once (batch):** repeat `--session`, same outcome for all.
```sh
# for example, drop empty artifacts or dogfooding experiments:
stk close --session <sid1> --session <sid2> --session <sid3> \
  --status dropped --add-tag cleanup --rationale "cleanup"
# in a batch the PER-SESSION fields (--name/--class/--distill-target/--summary)
# are rejected; a sid with a live tab is SKIPPED (warn) and the batch goes on.
```

**Close a session that lives on another node:**
```sh
stk -u <alias> close --session <sid> --status done --name <name>
stk -u <alias> publish   # propagates from there
```

**Force the closure of a session with an open tab:**
```sh
stk close --session <sid> --status done --force
```

**Record an intent or a parenthesis without starting a pass:**
```sh
stk note --current --kind intent "refactoring the stk dispatcher"
stk note --current --kind future "the open-tab guard still lacks a test"
```

**Clean up orphan empty stubs (records with no information):**
```sh
stk hygiene              # dry run: lists only
stk hygiene --apply      # removes (local shard only)
```

**Am I in the right place to continue?**
```sh
stk where --current      # JSON: verdict here|elsewhere|unknown + candidates (cd/ssh/branch)
```

**Branch the current session (`/branch`):**
```sh
stk branch --current --name <trunk-name> --child <child-name>
# then, IN the trunk, by hand:  /rename <trunk-name>   and   /branch <child-name>
# in the child, on the first turn:  stk branch --register --current
```

**A full incremental pass (for whoever maintains the map):**
```sh
stk sync pull                                                    # 1) align
stk scan --since 7d > "${STK_LOCAL:-$HOME/.local/session-tracker}/manifest.jsonl"   # 2) delta new/changed: stdout, and merge reads <data_dir>/manifest.jsonl
# 3) LLM extraction (subagent: a small model, low effort) -> digests.jsonl, then:
uv run --no-project --with pyyaml --python 3.12 python "$(dirname "$(stk shim resolve)")/../helpers/merge.py" digests.jsonl
stk publish                                                      # 4) publish + index (+ commit + push with canon_git=auto)
```

## Commit versus push

When the canon sits inside a git repo and `canon_git=auto`, `stk publish` does **both** a commit
and a push by default: an opt-in push is the one that never runs, and unpushed commits pile up
on the canon's host unnoticed (`stk primary-check` from a secondary node reports them as
`primary-ahead`). For a deliberate
staging without an immediate push, `stk publish --no-push`: the record is safe in the local
history, the push comes later (`stk publish`, or a manual push of the repo).

Details of the commit:

- it commits **only the sessions subtree**: work staged elsewhere in that repo is untouched
  (commit with a pathspec);
- **idempotent**: no commit if the subtree did not change;
- **serialized with flock** (`STK_CANON_LOCK`, default `$STK_CANON_PATH/.stk.lock`): several
  sessions running `publish` or `index` in parallel neither corrupt `index.jsonl` nor collide on
  the repo's `.git/index.lock`;
- the lockfile is gitignored in the sessions folder, it never lands in a commit.

## Are a secondary node's records aligned?

Yes, in two senses, with `canon_mode=ssh`:

- **The node's records in the canon**: `stk publish` run *from* the node copies its staging to
  `<canon>/<node>/...` and, with `canon_git=auto`, commits on the canon's host. The node itself
  has no git repo for its sessions, so there is nothing to commit there.
- **The global index on the node**: `publish` regenerates `index.jsonl` on the canon but does
  not bring it back; `sync pull` downloads the node's slice, `naming-map.yaml` and a read-only
  mirror of the whole canon in `<data_dir>/canon/`, which is what `dashboard --triage` and
  `where` read on that node. The live picture lives on the canon's host: `stk dashboard` without
  `--triage` queries it there over ssh.

With `canon_mode=local` the canon is the store on this node, `canon/` is only a copy of it one
round behind (`sync pull` runs before `publish` in `sync both`), and `where` reads the store.

## The record per session

`<node>/<encoded>/<sid>.md`, three layers (details in `references/schema.md`):

- **YAML frontmatter**: metadata and computed fields (status, name, tags, fork, pilot,
  timeline, watermark). Managed by the driver.
- **`## extracted`**: the LLM digest (goal, summary, done, open, decisions), rewritten at every
  advance.
- **`## user_notes`**: sacred, never touched by agents. The `stk note` notes (the `intent`
  included) land here, upserted by `id`.

The watermark of the incremental delta is `last_indexed_uuid` in the frontmatter: `scan`
compares the last `uuid` of the source `.jsonl` with the stored one and classifies the session
`new | changed | unchanged`.

## Naming

A closed session gets a canonical name, `<subject>[-<issue number>]-<theme>-<action>`, where the
action comes from a closed set and the subject is the real target of the work, never the repo
it started from. A live session carries the same name with the `wip-` marker on the harness
title (`/rename wip-<name>`), which drops at the close. The generic rules are in
`references/naming.md`; the data (which subject a folder maps to, short tokens, tiers of a
knowledge base, window prefixes for tmux) is a YAML file you keep in the canon,
`naming-map.yaml`, which `sync pull` copies to the node. Minimal example:

```yaml
schema: v0
tokens:
  shop: shop-web          # short token -> what it stands for
contexts:
  shop-web: shop          # repo basename -> subject
  ops: real-target        # never the repo name: use the real target
```

A knowledge base with tiers and org folders is declared with `kb_layout` (its folder names),
`kb_tiers` and `kb_orgs`: see `references/naming.md`, "How to choose the subject".

`naming_policy` decides how much the guard of `stk close --name` enforces: `warn` (default)
reports a wrong subject or action and accepts the name, `error` rejects it (`--force` passes), `off`
disables the check and the proposal. Two rules guard the record itself and are refused with
`warn` and with `--force` too: the `wip-` marker (a closed record cannot carry it) and characters
outside the lexicon (`[a-z0-9-]`). With no map the generic rules apply alone.

## Node configuration

File `${XDG_CONFIG_HOME:-~/.config}/session-tracker/config`, `key=value` lines, `#` comments
**at the start of a line** (after a value it is part of the value), optional quotes around the
value, a leading `~/` expanded. Precedence: environment variable (`STK_*`) > file > default; an
empty variable counts as unset. An unknown key is ignored: `stk doctor` reports it, with the
nearest key if it is a typo. Paths (`data_dir`, `naming_map`, `hook_extra_context_file`,
`canon_path` with `local`) are absolute or start with `~/`: a relative one is a config error,
which `doctor` reports and every command refuses before reading or writing; the hook says it in
the context it injects and logs it. `stk init` writes the file. **The defaults are neutral**:
without a config the tool is a single-node tracker with the store under `data_dir`, which never
touches git nor the network; the first `stk publish` (or `stk index`) creates the index that
`dashboard` reads. A remote canon, commits of the store, known nodes and pilot aliases are
opt-in. `bin/stk` and `helpers/config.py` read the same file.

| key | env | default | note |
|---|---|---|---|
| `data_dir` | `STK_LOCAL` | `~/.local/session-tracker` | staging and local mirror; the files `node` and `shard/events.jsonl` are a contract other tools may read |
| `node` | `STK_NODE` | file `node` in `data_dir`, then the short hostname | the node's slug (`[a-z0-9][a-z0-9_.-]*`) |
| `canon_mode` | `STK_CANON_MODE` | `local` | `local` (canon on this host) or `ssh` (on `canon_host`). **Only this key decides**, not the existence of a folder |
| `canon_host` | `STK_CANON_HOST` | (empty) | ssh host of the canon; required with `canon_mode=ssh`. That host needs `rsync`, `flock` and `uv` (`index` and `dashboard` run there), plus `git` with `canon_git=auto` |
| `canon_path` | `STK_CANON_PATH` | `<data_dir>/store` with `local` | path of the canon. With `ssh` it is a path **on the host** and must be declared |
| `canon_git` | `STK_CANON_GIT` | `off` | `off`: `publish` never touches git. `auto`: commits and pushes if the canon sits in a git repo, **whatever** repo contains it: with the default store inside a home under git the records would end up in that home's remote, which is why it is not the default |
| `known_nodes` | `STK_KNOWN_NODES` | (empty) | slugs of the known nodes for `where` (added to those of the index); commas or spaces |
| `remote_aliases` | `STK_REMOTE_ALIASES` | (empty) | ssh aliases accepted as pilots by `merge.py`; empty list = no pilot materialized |
| `pilot_commands` | `STK_PILOT_COMMANDS` | (empty) | remote-piloting commands whose `-u <alias>` (or `--user`) `scan` reads as a pilot candidate; empty = no candidates. Names of `[A-Za-z0-9_.-]` only |
| `naming_policy` | `STK_NAMING_POLICY` | `warn` | `off`: the hook proposes no name and `close --name` does not check. `warn`: the hook proposes, `close` reports a wrong subject or action on stderr but accepts the name; `wip-` and characters outside the lexicon are refused anyway, `--force` included. `error`: `close` rejects every violation without writing (`--force` passes, except those two). The three values are the severity levels of ESLint rules. Another value stops `close --name` (without `--force`); the hook logs it and acts as `warn` |
| `naming_map` | `STK_NAMING_MAP` | `<data_dir>/naming-map.yaml` | the map read by the hook, `close` and `where`; `sync pull` copies it here from the canon if the canon has one. `~/` expanded. Declared (file or env) but missing: the guard cannot run (exit 2: with `error` the close stops unless `--force`, which writes the name unchecked and says so; with `warn` it says so and accepts; `wip-` and characters outside the lexicon are refused anyway, they are checked before the map), the hook says so and `where` exits 2; the default path missing means "no map, generic rules" |
| `hook_ask_intent`, `hook_placement`, `hook_primary_check`, `hook_tmux_tab` | `STK_HOOK_ASK_INTENT`, `STK_HOOK_PLACEMENT`, `STK_HOOK_PRIMARY_CHECK`, `STK_HOOK_TMUX_TAB` | `off` | hook clauses, `on` or `off`. The tmux window needs `naming_policy` other than `off` (the prefix comes from the naming context). Another value acts as `off` and goes to `hook.log` when the clause is evaluated (the tmux one only inside tmux and with `naming_policy` other than `off`) |
| `hook_extra_context_file` | `STK_HOOK_EXTRA_CONTEXT_FILE` | (empty) | a file whose text the hook appends to its own context, as is: the injection point for a private overlay (rules in another language, house procedures). Unreadable: the rest goes through, `hook.log` says so. `~/` expanded |

Example of a secondary node publishing to a remote canon:

```
canon_mode = ssh
canon_host = hub
canon_path = /srv/sessions
canon_git = auto
known_nodes = hub, laptop
```

Other environment variables (overrides only):

| var | default | note |
|---|---|---|
| `STK_CANON_LOCK` | `$STK_CANON_PATH/.stk.lock` | serialization lockfile; absolute only in local mode |
| `CLAUDE_DIR` | `CLAUDE_CONFIG_DIR`, then `~/.claude` | the Claude Code home (sessions, projects, `settings.json`, plugin records). `CLAUDE_CONFIG_DIR` is the variable users move it with, and Claude passes it to hooks and Bash (not with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`); an `stk` run from a terminal that does not see it reads `~/.claude`, not the session's home |

## The hook

`stk hook` runs at `SessionStart` and injects, for a new session (`startup`, `resume`, `clear`)
with no intent recorded yet, the clauses enabled in the config: with the defaults, only the
proposal of a canonical name (`/rename wip-<name>`) with the naming context resolved from the
current folder; opt-in, the intent question (`hook_ask_intent`), the placement check
(`hook_placement`), the primary check (`hook_primary_check`), the tmux window rename
(`hook_tmux_tab`), and the text of `hook_extra_context_file` at the end. On `resume` and
`clear` it always asks to register a possible branch. It never writes records. Log in
`<data_dir>/hook.log`; `references/hook.md` has the clause-by-clause description.

## Tests

`bash tests/run.sh`: a deterministic, hermetic black-box suite over the dispatcher, the
helpers, the hook, the configuration, the plugin files and the shim. Run it before committing a
change to `bin/stk` or `helpers/`. Deps: bash, jq, python3, uv. See `CONTRIBUTING.md` for the
development setup and the privacy guard.

## Boundaries

- Driving a remote tmux or Claude session is not covered: `stk -u <alias>` only runs `stk`
  there over ssh.
- Token and cost accounting is not covered.

## License

MIT, see `LICENSE`.
