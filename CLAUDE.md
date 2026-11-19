# CLAUDE.md

Repo of the **session-tracker** project: the Claude Code skill, the `stk` dispatcher, the
Python helpers and the tests.

## Layout

```
.claude-plugin/   plugin.json (name, version; no `skills` key) and marketplace.json (source ./)
hooks/hooks.json  SessionStart -> "${CLAUDE_PLUGIN_ROOT}"/bin/stk hook
SKILL.md          the Claude Code skill (frontmatter + procedures), at the root: loads as the single skill
references/       material the skill loads on demand
helpers/          Python helpers invoked by stk (close, merge, stub, where, doctor, ...)
bin/stk           bash dispatcher (scan|note|link|sync|index|close|branch|hook|shim|doctor|...)
shim/stk          the shim that `stk shim install` writes in ~/.local/bin/stk (resolves the current installation)
tests/run.sh      deterministic black-box suite
README.md         extended documentation (architecture, schema, config)
CONTRIBUTING.md   setup, tests, conventions, privacy guard
```

The repo is the plugin and the marketplace of itself: `claude plugin marketplace add <path or
repo>` and `claude plugin install session-tracker@session-tracker-skill`; a marketplace added from
the path of a clone loads the plugin in place. The dispatcher resolves `helpers/` from its own
real path, so the repo is cloned, never copied in pieces. Validation: `claude plugin validate .`
(passes with the warnings on the root `CLAUDE.md`, which the plugin does not load, and on the
missing icon); try it without installing and without
touching the node: temporary `CLAUDE_CONFIG_DIR`, `STK_LOCAL` and `XDG_CONFIG_HOME` and
`claude --init-only --plugin-dir <clone>` (runs the `SessionStart` hooks only; on a node that has
the hook in `settings.json` a bare `--plugin-dir` would inject twice and write to the real
tracker).

## Conventions

- Commits: Conventional Commits (`feat(stk): ...`, `fix(where): ...`).
- **Run `bash tests/run.sh` before committing** a change to `bin/stk` or the helpers. It runs
  every check and exits != 0 if any failed. Deps: bash, jq, python3, uv.
- SKILL.md under 500 lines; detail goes to `references/`.
- No global Python packages: the helpers run through `uv run --with pyyaml`.
- Everything is in English: code, comments, messages, docs, the text the hook injects. A node's
  rules in another language arrive through `hook_extra_context_file`, not through the repo.
