#!/usr/bin/env python3
# stk hygiene: finds (and with --apply removes) the EMPTY STUB records in the local
# shard. An empty stub is an orphan record with no information: typically
# created by `note`/`close` on a sid whose JSONL was already pruned, or similar
# leftovers. Criteria (ALL true):
#   - status == unknown  and  status_source == auto   (never closed/branched by hand)
#   - empty name  and  name_source != user            (no user override)
#   - forked_from null                                (not a legitimate child stub)
#   - empty ## user_notes
#   - ## extracted with no goal/summary filled in and no list entries
# Default: dry-run (lists only). --apply removes the files.
# Operates ONLY on the local shard ($STK_LOCAL/shard): the canon is git-versioned
# (removals there go through git rm + publish, not from here).
import sys, os, glob, argparse
import yaml

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config as stkconfig  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--shard", default=None)
ap.add_argument("--apply", action="store_true")
a = ap.parse_args()

HOME = os.path.expanduser("~")
STK_LOCAL = os.environ.get("STK_LOCAL", os.path.join(HOME, ".local/session-tracker"))
SHARD = a.shard or os.path.join(STK_LOCAL, "shard")


def parse_body(body):
    sections, cur = {}, None
    for ln in body.splitlines():
        if ln.startswith("## "):
            cur = ln[3:].strip()
            sections[cur] = []
        elif cur is not None:
            sections[cur].append(ln)
    return {k: "\n".join(v).strip() for k, v in sections.items()}


def extracted_empty(txt):
    """True if ## extracted has no goal/summary filled in and no list entries."""
    for ln in txt.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("goal:") and s[5:].strip():
            return False
        if s.startswith("summary:") and s[8:].strip():
            return False
        if s.startswith("- "):
            return False
    return True


empties = []
for md in glob.glob(os.path.join(SHARD, "*", "*.md")):
    try:
        raw = open(md, encoding="utf-8").read()
        split = stkconfig.split_frontmatter(raw)   # delimiter LINES: a --- inside a value is data
        if split is None:
            continue
        fm = yaml.safe_load(split[0]) or {}
        secs = parse_body(split[1])
    except Exception as e:
        sys.stderr.write(f"[hygiene] skip {md}: {e}\n")
        continue
    if fm.get("status") != "unknown":
        continue
    if fm.get("status_source", "auto") != "auto":
        continue
    if (fm.get("name") or "").strip():
        continue
    if fm.get("name_source") == "user":
        continue
    if fm.get("forked_from"):
        continue
    if secs.get("user_notes", "").strip():
        continue
    if not extracted_empty(secs.get("extracted", "")):
        continue
    empties.append(md)

if not empties:
    print("[hygiene] no empty stub found in the local shard")
    sys.exit(0)

tag = " (REMOVED)" if a.apply else " (dry-run; --apply to remove)"
print(f"[hygiene] {len(empties)} empty stubs{tag}:")
for md in sorted(empties):
    print(f"  {os.path.relpath(md, SHARD)}")
    if a.apply:
        os.remove(md)
