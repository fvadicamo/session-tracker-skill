# Session naming conventions

Rules to derive the **canonical name** of a Claude Code session, applied **at birth** (with the `wip-` marker, see below) and **at closure** (see SKILL.md "Explicit closure of a session"). Goal: archived records that are uniform and **recognizable by name** in the resume picker and in queries.

**Where the data lives**: the *generic* rules (structure, set of actions) live here (shippable with the skill). The *personal entries* context->subject, the concise tokens, the kb tiers and the orgs live in the data file **`naming-map.yaml`**, which lives in the canon and which `stk sync pull` copies to the `naming_map` path of the node config (default `<data_dir>/naming-map.yaml`). If the map is missing, apply only the rules of this file and infer the subject sensibly from the content. How strictly the `stk close` guard enforces these rules is decided by `naming_policy` in the config (`warn`: report and accept the subject and the action, refuse `wip-` and characters outside the lexicon; `error`: reject every violation).

## Name structure

Two classes.

### `task` (default, ~90% of sessions)
```
[wip-]<subject>[-<number>]-<theme>-<action>
```
- **no date** in the name (the record already has `started_at`/`last_activity_at`)
- the prefix is the **real subject**, never the name of the repo the session starts from
- `<number>` is the **issue number** the session works on, **without `#`**, right after the
  subject; it is missing only if there is no issue (a story or ticket number counts as one)
- `<theme>` is one or more tokens (`[<subsubject>-]<qualifier>`)
- examples: `shop-search-index-setup`, `bot-alpha-news-pipeline-refactor`, `corpvpn-diagnostics-fix`
- examples with the issue: `acme-i-3307-build-tool-setup`, `acme-kb-product-512-invoice-layout-update`

### `distill` (fork that distills the parent's findings into a skill)
```
[wip-]<parent-canonical-name>-<skilltag>-distill-<YYYY-MM-DD>
```
- it sits **adjacent to the parent** in the picker (same prefix) -> you immediately see whether a session has been distilled
- `<skilltag>` concise (e.g. `bot` for `bot-skill`)
- same parent+day collision -> suffix `-2`, `-3`
- metadata: `class: distill`, `distill_target: <skill>`; the parent is already in `forked_from`
- example: parent `acme-member-enrollment-fix` -> `acme-member-enrollment-fix-bot-distill-2026-06-05`

## The `wip-` lifecycle marker

The canonical name says **what** a session is about; `wip-` says it is **not closed yet**.
They are two different pieces of information, and that is why they sit in two different places
of the name. It goes in front of everything, before the subject: in the `<subject>...` line above
the word "prefix" indicates the subject, which is a different thing.

```
wip-shop-search-index-setup     session running
shop-search-index-setup         the same, closed
```

- **Every session is born `wip-`.** The name does not wait for the end: as soon as the theme is
  clear, `/rename wip-<canonical-name>` is proposed. It is while a session is alive that the
  resume picker is useful, and that is where the name must already be readable.
- **The marker drops at closure**, and drops there: `stk close --name` is given the name
  **without** `wip-`, and `/rename <canonical-name>` is **offered** without waiting. The name is
  chosen by Claude: at closure it is not asked, it is derived and applied.
- **`wip-` is not a status.** The status lives in the record (`status`), which is the source; the
  marker is its projection onto the **harness title**, that is the only place where the record is
  not read. It follows that in the record the `name` never carries `wip-`: if it did, every query
  on `name` would have to strip it, and the index would have two spellings for the same session.
- **When it is there and when not is mechanical, and asks for no judgment**: `wip-` stays until
  the `status` is terminal. `branched` is **not** terminal, so a branched trunk keeps it until
  someone closes it, even if the work has moved to the child; and the child is born `wip-` like
  all the others.
- **`wip-` is reserved**: it is never a subject, a subsubject or a qualifier.

**It is guarded by `stk close`** according to `naming_policy`: a `--name wip-...` is rejected with the rule in the message with `error` **and** with `warn` (default), because the marker is an invariant of the record and not a convention (`--force` does not pass it either); the same holds for characters outside the lexicon below. The same guard (`helpers/naming.py check`) checks the subject
against the entry of `contexts` (or of `kb_orgs`) that `naming-map.yaml` assigns to the cwd, admits the
issue number as a digits-only token right after the subject, and checks the final action against
the closed set of the "Lexicon" section, which is **read from this file**: changing the set here changes the guard.
`stk branch --child` does not apply it (the child is born alive: there the marker lives in the
proposed title, not in the record).

## Lexicon
lowercase, separator `-`, ascii, no spaces or prepositions. Closed set of actions:
`setup | fix | update | migration | refactor | integration | planning | check | issue | investigation | distill`.

## How to choose the subject

The subject is the **real target** of the work, derived from the context (cwd/repo) through `naming-map.yaml` -> `contexts`, and expressed with the **concise tokens** of `naming-map.yaml` -> `tokens`. Rules:

- **Heterogeneous repo** (e.g. an `ops` repo): NEVER use the name of the repo. Use the real target (a node, a service instance, a tool, a domain). It is the case where the prefix matters most: from `ops` start sessions on very different subjects.
- **A machine is a fallback subject**: a token for a host (say `vps-alpha`) only for machine-level work (hardening, firewall, base). If on that machine you operate on a specific subject (say the service instance `bot-alpha`), the subject stays that one, no machine token in front.
- **A knowledge base is declared by `kb_layout`** in `naming-map.yaml`: `root` (the folder name
  of the kb root, matched as a path segment at any depth), `orgs_dir` (the folder under the root
  that holds the orgs of `kb_orgs`) and `token` (the first token of the subject inside the kb).
  Without it the two rules below do not fire; with `kb_orgs` or `kb_tiers` declared and no
  `kb_layout` the guard stops (exit 2) instead of going silent, for every cwd, because the map
  is invalid as a whole; the only kb rule that stays silent without the section is the one for
  an org named only in `contexts` (nothing tells the resolver which folder holds the orgs). Provenance of the names: `layout`
  is the usual word for a folder structure; `root` as in `git rev-parse --show-toplevel`
  and the `rootDir` of tsconfig; `orgs_dir` names the section it serves with the `_dir` suffix of
  `data_dir`; `token` is the vocabulary of the map's own `tokens` section.
- **Inside the kb**: `<kb token>-<token>-<area>`, where `<token>` is the one that the `kb_tiers` section of `naming-map.yaml` assigns to the tier folder (the first level under the kb root) and `<area>` is the folder right under the tier; deeper levels go in the theme. For example, with `kb_tiers: {team: t}` a session in `<kb>/team/network/` has subject `wiki-t-net` (the `kb_layout` token being `wiki`). A folder with no entry in `kb_tiers` is not a tier and the subject stays not verifiable. The area is abbreviated with the tokens of the map (`net` = network).
- **Inside `<root>/<orgs_dir>/<org>`**: if the org has an entry in `naming-map.yaml` -> `kb_orgs`, the subject is
  the one declared **per repo**: `umbrella` for `<root>/<orgs_dir>/<org>` (and its non-repo folders),
  `repos.<fn>` for the function repo `<root>/<orgs_dir>/<org>/<fn>`. Never composed from `contexts[<org>]` plus
  the function. A repo under the org that has no value in `repos` does not take the umbrella: the subject
  stays not verifiable until the map declares it. The repo is recognized by the local `.git`,
  so an undeclared repo seen from another node falls back to the umbrella: declare them all. Without an entry in `kb_orgs` the rule is
  `<contexts[org]>[-<fn>]`.
- **Several subjects for one folder**: an entry of `contexts` can list more than one
  (`<folder>: [<default>, <other>]`) when from the same folder you work on different repos.
  The subject is decided by the repo the session actually works on, the first entry being the
  default. The guard accepts any of them.
- **A family of targets can have a single token**: a `tokens` entry declares it, and the rest follows from it. For example, if `tokens` declares `bot` for a family of bots, the instances are `bot-<name>` and the `<skilltag>` of the distill is `bot`. This is an example of how a `tokens` entry works, not a rule of the skill: each map declares its own.
- **`{N}` in a subject stands for a number**: a `contexts` value `exp{N}` accepts `exp3-...` as the subject, and that `3` is part of the subject, not an issue number.

## tmux window

A tmux window is named `<prefix>-<issue number>` or `<prefix>-<short slug>`. The prefix is the
subject declared by the map, or its abbreviation in the `window_prefix` section of
`naming-map.yaml` (`window` is the tmux term); the key also applies to the subjects
`<key>-*`, and between two keys the longest wins. If the map does not declare the subject (unknown
folder, `real-target`, a kb tier) the prefix is the subject that the session derives for its
own name, and only a never-named window is renamed. A malformed `window_prefix` turns off only
this clause, not the guard on the name.

The hook reads the current window and decides before the model starts (`helpers/naming.py`,
`window_text`):

- **it is renamed** only if it was never named (`#{automatic-rename}` on) or if it is called
  `<prefix>-<number>`;
- **every other name stays**: a user slug, the prefix alone (the primary window of a
  project), a name with another prefix. Also `<prefix>-<slug>` stays, because from the form you
  cannot tell a user slug from a session one.

A new window takes the same form, and the prefix alone is not assigned by any session.

## Examples (invented before/after)

| Before | After |
|---|---|
| `news-pipeline-restructure` | `bot-alpha-news-pipeline-refactor` |
| `shop-search-embedding-service-setup` | `shop-embedding-setup` |
| `router-wan-status-check` | `wiki-t-net-router-wan-check` |
| `tech-002-phase8-planning` | `acme-tech-002-phase8-planning` |
| `helper-bot-distill-2026-05-21` | `<parent-name>-bot-distill-2026-05-21` |
| `bot-distill from model-x on bot-alpha` | `<parent-name>-bot-distill-<date>` |
| hardening of a VPS, no other subject | `vps-<node>-hardening-setup` |
