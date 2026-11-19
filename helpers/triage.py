#!/usr/bin/env python3
# Triage/resume view: non-closed sessions clustered by ACTIONABILITY from the local node.
# Clusters: open now (live tab) / resumable / not resumable (pruned jsonl) / other nodes.
# Open-tab and resumability are detected on the LOCAL NODE (~/.claude/sessions + projects);
# for the records of other nodes only the path + resume command are shown (to be verified there).
# Coloured output (ANSI) when stdout is a tty and NO_COLOR is not set: so queries
# in a pipe/capture stay plain text (the tests run in command substitution -> no tty).
# Override: NO_COLOR always disables, FORCE_COLOR forces it even outside a tty.
import sys, os, json, glob
root = sys.argv[1]
HOME = os.path.expanduser("~")
CLAUDE = os.environ.get("CLAUDE_DIR", os.path.join(HOME, ".claude"))
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config as stkconfig  # noqa: E402
CFG = stkconfig.load()
STK_LOCAL = CFG["data_dir"]
nf = os.path.join(STK_LOCAL, "node")
# STK_NODE, then the `node` key of the config (both in CFG), then the node file, then the hostname
LOCAL_NODE = CFG["node"] or (open(nf).read().strip() if os.path.exists(nf) else os.uname().nodename.split(".")[0].lower())
CUR = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
CLOSED = {"done", "dropped", "superseded"}

# --- ANSI colour (auto on a tty, honours NO_COLOR / FORCE_COLOR) ---
_USE_COLOR = (os.environ.get("FORCE_COLOR") not in (None, "0")) or (
    sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
)
def c(code, s):
    return f"\033[{code}m{s}\033[0m" if _USE_COLOR else s
# colour per status: green=active, yellow=paused, magenta=branched, red=dormant, dim=unknown
STATUS_COLOR = {"active": "32", "paused": "33", "branched": "35", "dormant": "31", "unknown": "2"}
def stag(st):
    return c(STATUS_COLOR.get(st, "0"), f"[{st}]")

idx = [json.loads(l) for l in open(os.path.join(root, "index.jsonl")) if l.strip()]
ap = [r for r in idx if r.get("status") not in CLOSED]

# open tabs: pid->sid from ~/.claude/sessions, live pids only
open_pid = {}
for s in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
    try: d = json.load(open(s))
    except Exception: continue
    sid, pid = d.get("sessionId"), d.get("pid")
    if sid and pid:
        try: os.kill(int(pid), 0); open_pid[sid] = pid
        except (OSError, ValueError): pass

def jsonl_present(sid):
    return bool(glob.glob(os.path.join(CLAUDE, "projects", "*", sid + ".jsonl")))

def cwd_of(r):
    if r.get("project_path"): return r["project_path"]
    for f in glob.glob(os.path.join(root, r.get("node", ""), "*", r["session_id"] + ".md")):
        for ln in open(f, encoding="utf-8").read().splitlines():
            if ln.startswith("project_path:"): return ln.split(":", 1)[1].strip()
    return ""

def label(r):
    return r.get("name") or r.get("project") or "(unnamed)"

C = {"open": [], "resume": [], "pruned": [], "remote": []}
for r in ap:
    if r.get("node") != LOCAL_NODE: C["remote"].append(r); continue
    sid = r["session_id"]
    C["open" if sid in open_pid else ("resume" if jsonl_present(sid) else "pruned")].append(r)

print(c("1", f"=== TRIAGE non-closed: {len(ap)} (local node: {LOCAL_NODE}) ==="))
print("    " + " | ".join([
    c("1;33", f"open now {len(C['open'])}"),
    c("1;32", f"resumable {len(C['resume'])}"),
    c("2", f"not resumable {len(C['pruned'])}"),
    c("1;36", f"other nodes {len(C['remote'])}"),
]) + "\n")

if C["open"]:
    print(c("1;33", "## OPEN NOW in a tab (live pid) -- go to the tab, no resume"))
    for r in C["open"]:
        me = c("1;35", "  <- THIS ONE") if r["session_id"] == CUR else ""
        print("  " + stag(r.get("status")) + " " + label(r) + "  "
              + c("2", f"(pid {open_pid[r['session_id']]}, {cwd_of(r)})") + me)
    print()
if C["resume"]:
    print(c("1;32", "## RESUMABLE -- copy and run"))
    for r in sorted(C["resume"], key=lambda x: str(x.get("last_activity_at")), reverse=True):
        print("  " + c("2", "# ") + stag(r.get("status")) + " " + label(r))
        print("  " + c("1", f"cd {cwd_of(r) or '<no-path>'} && claude -r {r['session_id']}"))
    print()
if C["pruned"]:
    print(c("2", "## NOT RESUMABLE (transcript pruned) -- record only, no resume"))
    for r in C["pruned"]:
        print("  " + stag(r.get("status")) + " " + label(r) + "  "
              + c("2", f"(sid {r['session_id'][:8]}, historical cwd {cwd_of(r) or '?'})"))
    print()
if C["remote"]:
    print(c("1;36", "## OTHER NODES -- ssh then resume (open/jsonl to be verified on the node)"))
    for r in sorted(C["remote"], key=lambda x: (x.get("node", ""), str(x.get("status")))):
        print("  " + c("2", f"# [{r.get('node')}/{r.get('status')}] {label(r)}"))
        print("  " + c("36", f"ssh {r.get('node')} 'cd {cwd_of(r) or '<no-path>'} && claude -r {r['session_id']}'"))
    print()
