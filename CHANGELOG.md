# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/) and live in `.claude-plugin/plugin.json`.

## [1.0.0] - 2026-11-21

First public release of session-tracker as a Claude Code plugin.

### Added

- Plugin packaging: `.claude-plugin/plugin.json`, a self-marketplace (`marketplace.json`,
  source `./`) and the `SessionStart` hook in `hooks/hooks.json`.
- `stk shim install`: a shim for the ssh and terminal PATH that resolves the installed
  plugin on every call.
- `stk init` (writes a commented config file) and `stk doctor` (what is configured, what is
  broken, where the hook comes from, what `stk` resolves to in PATH; `--remote` probes the
  ssh targets).
- Node configuration file with neutral defaults: local store, no remote host, git untouched,
  hook clauses off, naming policy `warn`.
- Naming policy driven by a data file (`naming-map.yaml`): the hook proposes a canonical
  name, `close --name` checks it (`off | warn | error`). With `warn` the subject and the action
  are reported and accepted; the `wip-` marker and characters outside the lexicon are refused
  with any policy other than `off`, `--force` included, because they guard the record and not a
  convention.
- Placement (`stk where`) and primary check (`stk primary-check`) for multi-node setups.
- Lifecycle marker `wip-` on the harness title of a live session.
- `kb_layout` in the naming map: the folder names of a knowledge base (root, orgs folder,
  subject token) are data, not literals in the resolver.
