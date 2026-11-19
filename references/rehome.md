# Re-homing a session to another project

A session started in the wrong folder shows up in the wrong resume picker and stays
classified under the wrong project forever. Re-homing it **is not a `mv`**: the
session -> project association lives in **six places**, eight files and directories in all (two
entries bundle two each). Three are silent if you skip them (the `cwd`, the tracker
record, scratchpad and env); two give a symptom that does not name the cause (a title that goes
back to auto-generated, the up arrow that no longer recalls anything); only one shows immediately.

Conventions of this page: `<sid>` = session id; `<claude>` = `$CLAUDE_DIR`, normally
`~/.claude`; `<canon>` = `$STK_CANON_PATH`; `$SHARD` = `$STK_LOCAL/shard`; `<node>` = node slug;
`<tmp>` = root of the scratchpads, `/tmp/claude-<uid>`; `<old-path>`/`<new-path>` = the two
absolute cwds; `<enc>` = the name of the project directory (`<enc-old>`, `<enc-new>`).

## `<enc>` is verified, not built in your head

The harness derives the name of the project directory from the cwd by replacing with `-` **both `/` and
`.`**, and leaves uppercase letters intact. Checked against the `cwd` of real transcripts:

```
/x/y/github.com/z            ->  -x-y-github-com-z
/x/.claude/worktrees/w       ->  -x--claude-worktrees-w      (the dot gives the double dash)
/tmp/bench-Xp75Oj/repo       ->  -tmp-bench-Xp75Oj-repo      (uppercase intact)
```

The `.` is what gets forgotten, and every clone under a host with a dot in the name has it. But the
defense is not remembering the rule: **the destination directory must already exist**, because a
folder where you have never opened Claude has no project. If it is not there, the name is wrong
or that folder is new: a `mkdir -p` on a badly derived name creates a ghost project
that the picker will never show.

```bash
ls -d "$CLAUDE_DIR/projects/<enc-new>"                    # must exist
ls -d "$CLAUDE_DIR"/projects/*/"<sid>.jsonl"              # where the session is NOW
```

## Prerequisite: the session must not be alive

A transcript moved from under a process that is appending to it breaks. `stk dashboard --triage`
lists among the *open now* the sessions with a live tab (derived from `<claude>/sessions/*.json`,
`sessionId`/`pid` pair verified with `kill -0`: the `open_pid` map in `helpers/triage.py`, `_sid_open_pid` in `bin/stk`).
If the session to move is there, close the tab first.

## The six places

1. **The transcript**: `<claude>/projects/<enc-old>/<sid>.jsonl` -> `<enc-new>/`. It is the only one that
   decides **in which folder** the session appears in the picker: the picker groups by project
   directory. The other five neither make it appear nor make it disappear.
2. **The sidecar dir**: `<claude>/projects/<enc-old>/<sid>/`, with `custom-title.json` (and, if
   there were any, `subagents/` and `tool-results/`). If it stays behind the session loses the name given
   with `/rename` and comes back with the auto title.
3. **The `cwd` field inside the transcript**, on every entry that has it (not all: count them, below).
   **It does not decide where the record goes**: that is decided by the directory of the transcript (the
   `encoded_project` of the scan manifest, which `helpers/merge.py` turns into the record's directory): but it is from there that `scan` derives `project` and `project_path`
   (the `jq` of `cmd_scan` in `bin/stk` fills both from `cwd`), the two fields that the index, the dashboard and `where` filter on. If you do not
   rewrite it, the record stays in the right place **with the fields of the old project**, and in every
   query the session appears as belonging to another project. It also applies to `stk note` and `stk close`, which go
   through `_resolve_encoded` in `bin/stk`: position from the directory, fields from the `cwd`.
4. **The tracker record, in two copies**: `$SHARD/<enc>/<sid>.md` and
   `<canon>/<node>/<enc>/<sid>.md`. `project` (basename of the cwd) and `project_path` change. The
   `## user_notes` block is carried over **verbatim**: it is sacred (see SKILL.md, "Merge rules (critical)").
5. **The prompt history**: `<claude>/history.jsonl`, `project` field line by line: it is what
   sweeps the up-arrow recall by folder. It is sorted **by content, not by session
   id** (see "What is not rewritten").
6. **Session scratchpad and env**: `<tmp>/<enc-old>/<sid>/scratchpad` and
   `<claude>/session-env/<sid>/*.sh`, which exports the transcript path to the plugins. The second is
   regenerated at every start, but **may contain blocks of other sessions**: look for it by session id
   inside the files, not by directory name.

## The procedure

```bash
SID=<sid>
OLD="$CLAUDE_DIR/projects/<enc-old>"; NEW="$CLAUDE_DIR/projects/<enc-new>"
ls -d "$NEW" || { echo "the destination does not exist: <enc-new> is wrong or the folder is new"; }

# 1. cwd: substitution on an EXACT literal, and the match of the two counts is the check
grep -o "\"cwd\":\"<old-path>\"" "$OLD/$SID.jsonl" | wc -l          # occurrences of the literal
jq -rn '[inputs | select(.cwd != null)] | length' "$OLD/$SID.jsonl" # entries that have a cwd
grep -o '"cwd": *"' "$OLD/$SID.jsonl" | sort -u                     # no other spelling of the field
sed "s|\"cwd\":\"<old-path>\"|\"cwd\":\"<new-path>\"|g" "$OLD/$SID.jsonl" > "$OLD/$SID.jsonl.new"

# 2. transcript + sidecar dir, all chained: if a step fails, the rest does not run
mv "$OLD/$SID.jsonl.new" "$NEW/$SID.jsonl" && chmod 600 "$NEW/$SID.jsonl" \
  && mv "$OLD/$SID" "$NEW/$SID" \
  && rm "$OLD/$SID.jsonl"

# 3. record, in the TWO copies: move the file and fix the two frontmatter lines
#    (the rest of the md passes intact, user_notes included)

# 4. publication: publish ALREADY does sync + index, and with canon_git=auto it commits and
#    PUSHES by default (with the product default, canon_git=off, it stops after the index)
stk publish            # --no-push for the local commit only
```

The two counts of step 1 must match: if they do not, the substitution does not cover everything
(another spelling of the field, or nested occurrences in the content) and you go and look at which ones before
proceeding. The `sed` writes with the current umask, so the transcript must be put back to **600** like
its peers, or it stays readable by everyone.

The order between 1 and 2 does not eliminate the intermediate state, it chooses it: with the `cwd` rewritten and the transcript
still in place, a pass that interposed would write the record in the **old** directory with
the new fields. Chaining step 2 reduces the window; it does not close it.

## The checks, and why re-reading the files is not one of them

- **`stk scan` with `--all`.** Without `--all` a session already extracted comes out `unchanged` and is
  filtered (`only_changed` in `cmd_scan`): the output is **empty** with exit 0, and an empty here reads as a failed
  rehome, that is a false alarm on correct work. And look at `project_path`, not only
  `encoded_project`: the first comes from the `cwd` and is the only one that betrays step 1 not done,
  because the second comes from the directory and would be right anyway.

  ```bash
  stk scan --all --since 1d | grep -e "<sid>"      # project_path and encoded_project both new
  ```
- **The negative half, with the form that holds.** An `<enc>` starts with `-`, so it must be passed with
  `-e` or `grep` takes it for an option: the bare form exits with a usage error and an **empty**
  count, which in a report reads as zero.

  ```bash
  stk scan --all | grep -e "<sid>" | grep -c -e "<enc-old>"   # 0: this session is no longer there
  stk scan --all | grep -c -e "<enc-old>"                     # >0: the OTHER ones are still there,
                                                              #     so the predicate can say yes
  ```
- **The picker is looked at RENDERED.** `--resume` without a value opens the interactive picker and there is
  no flag that merely lists, so it is rendered in a pty and the ANSI is stripped:

  ```bash
  cd <new-path> && COLUMNS=200 timeout 12 script -qec "claude --resume" /tmp/r.raw </dev/null
  sed -r 's/\x1b\[[0-9;?]*[a-zA-Z]//g' /tmp/r.raw
  ```

  From both folders: present in the new one, absent in the old one. Two measured details: with
  non-tty stdin `-q` does **not** suppress the `Script started on...`/`Script done on...` lines, which stay
  in the output; and this form is util-linux, while on macOS `script` is BSD and has neither `-c` nor
  `-e` (it rejects them as `illegal option`), where the proven form is `script -q /dev/null <command>`.

## Two measured traps

- **`sync publish` does not propagate deletions.** It uses `rsync -a` without `--delete`
  (`cmd_sync` in `bin/stk`, both the local and the ssh branch; the `--delete` is only on the
  read-only mirror `canon/`), so the old record in the canon **survives** even after you have removed it from the
  shard: it must be deleted by hand *in the canon*. `stk publish` (with `canon_git=auto`) then commits the removal, because it does
  `git add -- <canon>` on the directory (`cmd_publish`), and `git add` on a directory also stages
  the deletions.
- **Two records for the same `{node, session_id}` become two lines in the index**, with a contradictory
  `project`: `stk index` globs the md files (`cmd_index`) and **does not deduplicate** by session id.
  Every downstream query (dashboard, `where`, `related_sessions`) sees the session twice.
  Measured on a throwaway canon: two records -> `index.jsonl: 2 sessions` and two lines for
  that id; old one removed -> one.

## What is not rewritten

- **The content of the conversation.** The historical commands that name the old paths are the
  record of what ran: they stay as they are. The literal `"cwd":"<path>"` of step 1 is
  specific enough not to collide with them, and it is the match of the counts that proves it
  instead of promising it.
- **`gitBranch`.** It records the true branch of that time, which belonged to another repo; on resume the new
  entries will carry the new one.
- **Memories written by other sessions.** The `memory/` directory is **per-project, not
  per-session**: before moving one, find who wrote it and compare the dates. That the
  session to be moved has written none is the normal case, not a sign of a badly
  done search.

  ```bash
  grep -l "<memory-file-name>" "$CLAUDE_DIR/projects/<enc-old>"/*.jsonl
  ```
- **History that talks about something else.** A session started in the wrong place often also carries
  prompts of the old theme: those stay where they are. Sorting `history.jsonl` by session id
  instead of by content takes them all away.

## Automation

There is none: the sequence is manual. Issue #14 proposes `stk rehome --session <sid> --to
<path>`. As long as it stays manual, this page is the checklist.
