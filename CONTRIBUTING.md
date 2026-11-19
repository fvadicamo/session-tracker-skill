# Contributing

Thanks for taking the time. This file says how the repo is laid out, how to run it
without touching your own node, and what a change needs before it is merged.

## Layout

```
.claude-plugin/   plugin.json (name, version) and marketplace.json (source "./")
hooks/hooks.json  SessionStart -> "${CLAUDE_PLUGIN_ROOT}"/bin/stk hook
SKILL.md          the skill, at the root: the plugin loads it as its single skill
references/       material the skill loads on demand
bin/stk           the bash dispatcher (scan | note | close | sync | index | where | doctor | ...)
shim/stk          the shim that `stk shim install` writes in ~/.local/bin/stk
helpers/          Python helpers invoked by stk, run with `uv run --with pyyaml`
tests/run.sh      the deterministic black-box test suite
```

The dispatcher resolves `helpers/` from its own real path: clone the repo, do not copy
pieces of it.

## Dependencies

`bash`, `jq`, `python3` and [`uv`](https://docs.astral.sh/uv/). Nothing is installed
globally: the helpers run in an ephemeral environment (`uv run --with pyyaml`), and the first
run downloads pyyaml (and a Python 3.12 if your system has none).

## Running the tests

```
bash tests/run.sh
```

The suite is hermetic: it uses temporary directories for the data dir, the config, the Claude
home and the store, and never reads or writes your real `~/.claude` or
`~/.local/session-tracker`. It runs every check, exits non-zero if any failed, and prints a `SKIP` line for
a check that cannot run on this machine (for example `claude plugin validate` when `claude` is
not installed): a `SKIP` is never a pass.

Run it **before every commit that touches `bin/stk`, `shim/stk` or `helpers/`**. Many tests
assert on the exact wording of user-visible messages: when you change a message, change its
assertion in the same commit.

## Trying the plugin without touching your node

The repo is the plugin and its own marketplace. To load it in place and keep your real
tracker untouched, give the session a temporary Claude home, data dir and config:

```
export CLAUDE_CONFIG_DIR=$(mktemp -d) STK_LOCAL=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d)
claude --init-only --plugin-dir "$PWD" < /dev/null     # runs the SessionStart hooks only
cat "$STK_LOCAL/hook.log"                              # one `inject:startup` line
```

`claude plugin validate .` checks the manifest; it passes with warnings about the root
`CLAUDE.md` and the missing icon, which is expected.

For a longer dogfood on a node that already has the plugin installed, add the marketplace from
the path of your clone (`claude plugin marketplace add /path/to/clone`, then
`claude plugin install session-tracker@session-tracker-skill`): Claude reads the plugin in place,
and a change is live from the next session or after `/reload-plugins`. Do not use `--plugin-dir`
on such a node: the shim would still run the installed copy, so the hook and the dispatcher
would come from two versions (a known limit).

## Conventions

- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(stk): ...`, `fix(where): ...`, `docs(readme): ...`.
- **English everywhere**: code, comments, messages, docs and the text the hook injects.
- **`SKILL.md` stays under 500 lines**; detail goes to `references/`.
- **No behavior behind a hidden default.** Anything node-specific is a config key (see the
  README, "Node configuration") with a neutral default, never a constant in the code.
- **Paths in the config are absolute** (or start with `~/`): every reader rejects a relative
  one, because it would resolve against the current folder of whoever runs `stk`.
- **A check must be able to say no.** When you add a guard, add the negative test next to the
  positive one, and prefer a mutation test (a copy of the code without the guard must fail
  the test) when the guard is cheap to remove by accident.
- **Fixtures are neutral**: invented node names (`alpha`, `bravo`, `testnode`), invented paths
  (`/x/foo-repo`). Never a real hostname, user name or home path.

## Privacy guard

`.pre-commit-config.yaml` runs [gitleaks](https://github.com/gitleaks/gitleaks) on every
commit; enable it once per clone with `pre-commit install`. The maintainers also run a local
denylist check (`scripts/check_privacy.sh`) against a gitignored file that is deliberately not
in the repo: for contributors and in CI that check is a no-op and only gitleaks runs. That
check reads only the lines a commit adds, so when it blocks it is reporting a new token, and
`--no-verify` is not the answer. Fixtures stay neutral (see Conventions): never a real
hostname, user name or home path in a committed file.

## Issues and pull requests

- Open an issue with the template that fits (bug or feature). A good bug report has the
  command, the config in use (or "no config"), and the output; the temporary-environment
  recipe above makes a reproduction safe to share.
- Open a pull request from a branch. CI runs the test suite, `claude plugin validate` and
  gitleaks; all three must be green.
- The version lives in `.claude-plugin/plugin.json`; a release bumps it and tags the commit
  `vX.Y.Z`. Users who install from GitHub stay on the version they installed until they
  update explicitly.

## License

By contributing you agree that your contributions are licensed under the MIT License of this
repository.
