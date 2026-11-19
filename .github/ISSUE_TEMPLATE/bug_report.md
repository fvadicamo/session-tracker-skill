---
name: Bug report
about: Something does the wrong thing, or the right thing silently
title: ''
labels: bug
assignees: ''
---

## What happens

The command, what you expected, what you got.

## Reproduction

A sequence that reproduces it in a temporary environment, so it is safe to paste:

```
export STK_LOCAL=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d)
mkdir -p "$XDG_CONFIG_HOME/session-tracker"
# config, if any:
printf 'canon_mode = local\n' > "$XDG_CONFIG_HOME/session-tracker/config"
stk <command> ...
```

## What can go wrong while it stays

One sentence: who is affected and what they see (or do not see).

## Environment

- `stk doctor` output (remove anything private)
- OS, bash and jq versions
- Claude Code version (`claude --version`)
