#!/usr/bin/env python3
# Dashboard "what was left open": one line per non-closed session, by risk.
# ANSI colour as in triage.py (auto on a tty, NO_COLOR/FORCE_COLOR): RISK and STATUS by
# colour, metadata (DATE/EV) dim, NAME bold. In a pipe/capture it stays plain
# text. Over ssh the remote stdout is not a tty: the dispatcher forces FORCE_COLOR
# on the local side (see cmd_dashboard / dispatch -u in `stk`).
import sys, os, json, glob, re
root = sys.argv[1]
idx = [json.loads(l) for l in open(os.path.join(root, "index.jsonl")) if l.strip()]

_USE_COLOR = (os.environ.get("FORCE_COLOR") not in (None, "0")) or (
    sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
)
def c(code, s):
    return f"\033[{code}m{s}\033[0m" if _USE_COLOR else s
RISK_COLOR = {"high": "1;31", "medium": "33", "low": "2"}
STATUS_COLOR = {"active": "32", "paused": "33", "branched": "35", "dormant": "31", "unknown": "2"}

def md_fields(node, sid):
    goal = ""; n = 0
    for f in glob.glob(os.path.join(root, node, "*", sid + ".md")):
        t = open(f, encoding="utf-8").read()
        body = re.split(r"(?m)^---[ \t]*$\n?", t, maxsplit=2)[2]; cap = False   # delimiter LINES (inline: this file runs on the canon host from stdin)
        for ln in body.splitlines():
            if ln.startswith("goal:"): goal = ln[5:].strip()
            if ln.startswith("open:"):
                cap = True
                if ln.strip() == "open: []": return goal, 0
                continue
            if cap:
                if ln.startswith("  - "): n += 1
                elif ln and not ln.startswith(" "): break
        return goal, n
    return goal, n

rank = {"high": 0, "medium": 1, "low": 2}
# non-closed = everything that is not terminal. `unknown` (not yet extracted)
# must be INCLUDED: it is exactly what stays open (excluding it hid real
# sessions). EV = n_events: tells an empty stub (small EV) from a real
# session that was not extracted (large EV). See `stk hygiene` to clean up empty stubs.
CLOSED = ("done", "dropped", "superseded")
pending = [r for r in idx if r.get("status") not in CLOSED]
n_unknown = sum(1 for r in pending if r.get("status") == "unknown")
pending.sort(key=lambda r: (rank.get(r.get("dormancy_risk"), 9), str(r.get("last_activity_at"))))
print(c("1", f"=== OPEN: {len(pending)} non-closed sessions (of {len(idx)} indexed; {n_unknown} unknown/not extracted) ==="))
print(c("2", f"{'RISK':6} {'STATUS':8} {'SID':9} {'DATE':10} {'OPEN':>4} {'EV':>5}  {'NAME':32}  GOAL"))
for r in pending:
    goal, n = md_fields(r["node"], r["session_id"])
    name = (r.get("name") or "")[:32]
    ev = r.get("n_events"); ev = str(ev) if isinstance(ev, int) else "?"
    risk = r.get("dormancy_risk") or "?"
    st = r.get("status") or "?"
    print(
        c(RISK_COLOR.get(risk, "0"), f"{risk:6}") + " "
        + c(STATUS_COLOR.get(st, "0"), f"{st:8}") + " "
        + f"{r['session_id'][:8]} "
        + c("2", f"{str(r.get('last_activity_at'))[:10]}") + " "
        + f"{n:>4} "
        + c("2", f"{ev:>5}") + "  "
        + c("1", f"{name:32}") + "  "
        + goal[:40]
    )
