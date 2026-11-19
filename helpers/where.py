#!/usr/bin/env python3
"""where.py — deterministic placement engine for `stk where`.

Computes the "home" of a session's subject (ownership block > read-only
prose > emerging cluster) and compares it with where the session runs NOW
(node + folder). It writes nothing and does no network: it reads the local index (the store in
local mode, the cached mirror with ssh)
(global index.jsonl + naming-map) and the CLAUDE.md/CLAUDE.local.md files in the tree of
the cwd. Emits a JSON object with `verdict` + `candidates` with evidence and score;
Claude (policy) decides whether and how to propose. See references/placement.md.
"""
import argparse, json, os, re, sys

CLOSED = {"done", "dropped", "superseded"}
DROPPED = {"dropped", "superseded"}   # excluded from the cluster (done stays: it marks a real home)
ACTIONS = None

# ---- naming-map: subject from a path (resolver shared with hook and close) ----
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from naming import load_naming_map, subject_of  # noqa: E402
import config as stkconfig  # noqa: E402

# ---- ownership: CLAUDE.md / CLAUDE.local.md ------------------------------
PRIMARY_RE = re.compile(r"^\s*-\s*Primary:\s*([^(]+?)\s*\(`?([^)`]+)`?\)\s*$", re.I)
SECOND_RE = re.compile(r"^\s*-\s*Secondaries:\s*(.+?)\s*$", re.I)
# "sola lettura" is kept on purpose: it matches Italian-language CLAUDE.md prose (a match pattern, not output)
RO_MARKERS = ("read-only", "sola lettura", "source of truth", "mirror read-only")

def parse_block(text):
    """Extracts (primary_node, primary_path, secondaries[]) from the structured
    '## Node ownership' block, if present."""
    lines = text.splitlines()
    inb = False
    prim_node = prim_path = None
    secs = []
    for ln in lines:
        if ln.strip().lower().startswith("## node ownership"):
            inb = True
            continue
        if inb and ln.startswith("## "):
            break
        if not inb:
            continue
        m = PRIMARY_RE.match(ln)
        if m:
            prim_node = m.group(1).strip().lower()
            prim_path = m.group(2).strip().strip("`")
            continue
        m = SECOND_RE.match(ln)
        if m:
            secs = [t.strip().lower() for t in re.split(r"[,\s]+", m.group(1)) if t.strip()]
    return prim_node, prim_path, secs

def read_ownership(cwd, node, known_nodes):
    """Walk up from the cwd looking for ownership. Priority: structured block
    (authoritative) > read-only prose (low confidence). The most specific wins."""
    out = {"declared": False, "primary_node": None, "primary_path": None,
           "is_secondary_here": False, "source": "none", "primary_known": None}
    if not cwd:
        return out
    d = cwd
    while True:
        for fname in ("CLAUDE.local.md", "CLAUDE.md"):
            fp = os.path.join(d, fname)
            if not os.path.isfile(fp):
                continue
            try:
                text = open(fp, encoding="utf-8").read()
            except Exception:
                continue
            pn, pp, secs = parse_block(text)
            if pn:
                return {"declared": True, "primary_node": pn, "primary_path": pp,
                        "is_secondary_here": (pn != node) or (node in secs),
                        "source": "block", "primary_known": pn in known_nodes}
            low = text.lower()
            if any(m in low for m in RO_MARKERS):
                # prose: this is a per-node CLAUDE.local.md that declares
                # read-only HERE -> current node is a secondary. Try to extract
                # the source-of-truth node from a known slug cited in the file.
                cand = None
                for kn in known_nodes:
                    if kn != node and re.search(r"\b" + re.escape(kn) + r"\b", low):
                        cand = kn
                        break
                return {"declared": True, "primary_node": cand, "primary_path": None,
                        "is_secondary_here": True, "source": "prose",
                        "primary_known": cand is not None}
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    return out

# ---- cluster from index.jsonl ---------------------------------------------
def load_index(path):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    for ln in open(path, encoding="utf-8"):
        ln = ln.strip()
        if not ln:
            continue
        try:
            rows.append(json.loads(ln))
        except Exception:
            continue
    return rows

def words(text):
    return {w for w in re.split(r"[^a-z0-9]+", (text or "").lower()) if len(w) >= 4}

def in_cluster(row, subj, nm, intent_words):
    name = row.get("name") or ""
    tags = [str(t).lower() for t in (row.get("tags") or [])]
    if subj:
        rs = subject_of(row.get("project_path") or "", nm)
        if rs == subj:
            return True
        if name.startswith(subj + "-") or name == subj:
            return True
        if subj.lower() in tags:
            return True
        return False
    # subject not resolvable: use textual overlap with the intent
    if not intent_words:
        return False
    bag = words(name) | set(tags)
    return bool(intent_words & bag)

def norm_path(p):
    return (p or "").rstrip("/")

# ---- assembly --------------------------------------------------------
def build(args):
    # a map declared in config but missing, or unreadable, is an error and not a missing
    # map (same rule as `close` and the hook): the subject would silently fall back to the
    # folder name. The caller (bin/stk) passes --require-map only for the configured path.
    if args.require_map and args.naming_map and not os.path.exists(args.naming_map):
        return {"naming_map_error": f"naming_map declared but missing ({args.naming_map})"}
    nm = load_naming_map(args.naming_map)
    if nm.get("error"):
        return {"naming_map_error": nm["error"]}
    rows = load_index(args.index)
    known_nodes = {str(r.get("node")).lower() for r in rows if r.get("node")}
    # known_nodes of the config: it counts while the index is empty or does not name the node
    known_nodes |= {n.lower() for n in stkconfig.load()["known_nodes"]}

    node = (args.node or "").lower()
    if node:
        known_nodes.add(node)   # the node you run on exists by definition
    cwd = norm_path(args.cwd)
    subj = subject_of(cwd, nm)
    intent_words = words(args.intent)

    own = read_ownership(cwd, node, known_nodes)

    # cluster (exclude self + dropped/superseded)
    cluster = []
    for r in rows:
        if r.get("session_id") == args.session:
            continue
        if (r.get("status") or "") in DROPPED:
            continue
        if in_cluster(r, subj, nm, intent_words):
            cluster.append(r)

    def anchor_key(r):
        non_closed = 0 if (r.get("status") or "") in CLOSED else 1
        return (non_closed, str(r.get("last_activity_at") or ""))
    anchors = [r for r in cluster
               if r.get("name_source") == "user" and r.get("class") == "task"]
    anchors.sort(key=anchor_key, reverse=True)

    # home: block > prose+cluster-path > cluster anchor
    home_node = home_path = home_src = None
    if own["source"] == "block" and own["primary_node"]:
        home_node, home_path = own["primary_node"], own["primary_path"]
        # declared primary that is not a known node (typo, or display name in
        # place of the slug): the declaration is not verifiable -> do not assert
        # 'elsewhere' with confidence, downgrade to low and say so in the evidence.
        home_src = "block" if own["primary_known"] else "block-unknown"
    elif own["source"] == "prose" and own["primary_node"]:
        home_node, home_src = own["primary_node"], "prose"
        # try to recover the folder from the cluster on that node
        on_node = [r for r in anchors if str(r.get("node")).lower() == home_node]
        if on_node:
            home_path = on_node[0].get("project_path")
    elif anchors:
        a = anchors[0]
        home_node, home_path, home_src = str(a.get("node")).lower(), a.get("project_path"), "cluster"
    elif cluster:
        c = sorted(cluster, key=anchor_key, reverse=True)[0]
        home_node, home_path, home_src = str(c.get("node")).lower(), c.get("project_path"), "cluster-weak"

    # are you already an anchor in this position? -> here
    self_is_anchor = any(
        str(r.get("node")).lower() == node and norm_path(r.get("project_path")) == cwd
        for r in anchors)

    # base confidence from the source of the home
    conf_of = {"block": "high", "block-unknown": "low", "prose": "low",
               "cluster": "medium", "cluster-weak": "low", None: "low"}

    candidates = []
    verdict = "unknown"

    def related(limit=6):
        out = []
        for r in sorted(cluster, key=anchor_key, reverse=True)[:limit]:
            out.append({k: r.get(k) for k in
                        ("node", "session_id", "name", "status",
                         "last_activity_at", "dormancy_risk")})
        return out

    if home_node is None:
        verdict = "unknown" if not subj and not own["declared"] else "here"
        candidates.append({"kind": "stay-standalone", "node": node,
                           "project_path": cwd, "subject": subj, "score": 0,
                           "confidence": "low",
                           "evidence": ["no known home: empty cluster and no ownership"],
                           "trunk": None, "related_sessions": related()})
    elif home_node != node:
        ev = []
        if home_src == "block":
            ev.append(f"ownership block: primary={home_node}")
        elif home_src == "block-unknown":
            ev.append(f"ownership block: primary={home_node}, which is NOT a known node "
                      f"(typo? display name instead of the slug?) - known: "
                      f"{', '.join(sorted(known_nodes))}")
        elif home_src == "prose":
            ev.append(f"ownership read-only prose: source-of-truth={home_node or '?'}")
        else:
            ev.append(f"cluster: anchor on {home_node}")
        if own["is_secondary_here"]:
            ev.append("current node declared secondary/read-only")
        if subj:
            ev.append(f"subject={subj}, {len(cluster)} sessions in the cluster")
        conf = conf_of[home_src]
        score = {"high": 88, "medium": 65, "low": 40}[conf]
        if own["is_secondary_here"] and conf == "low" and home_src != "block-unknown":
            conf, score = "medium", 60   # read-only is a strong mismatch signal
        verdict = "elsewhere"
        candidates.append({"kind": "relocate-node", "node": home_node,
                           "project_path": home_path, "subject": subj,
                           "score": score, "confidence": conf, "evidence": ev,
                           "trunk": None, "related_sessions": related()})
    elif home_path and norm_path(home_path) != cwd and not self_is_anchor:
        conf = conf_of[home_src]
        score = {"high": 82, "medium": 60, "low": 38}[conf]
        verdict = "elsewhere"
        candidates.append({"kind": "relocate-folder", "node": node,
                           "project_path": home_path, "subject": subj,
                           "score": score, "confidence": conf,
                           "evidence": [f"home folder ({home_src}): {home_path}",
                                        f"you are in {cwd}"],
                           "trunk": None, "related_sessions": related()})
    else:
        verdict = "here"

    # branch-from-trunk: you are in the right place (verdict here/unknown) but the
    # decisions may live in a live trunk of the cluster -> consider /branch
    # instead of starting from scratch. Skipped if you are already a branch (forked_from).
    # Self is already excluded from the cluster, so the trunk is always another session.
    if not args.forked_from and verdict in ("here", "unknown"):
        trunks = [r for r in cluster
                  if (r.get("status") or "") in ("active", "branched", "paused")]
        trunks.sort(key=lambda r: str(r.get("last_activity_at") or ""), reverse=True)
        if trunks:
            t = trunks[0]
            candidates.append({
                "kind": "branch-from-trunk",
                "node": str(t.get("node")).lower(),
                "project_path": t.get("project_path"), "subject": subj,
                "score": 50, "confidence": "low",
                "evidence": [f"live trunk in the cluster: {t.get('name')} [{t.get('status')}]",
                             "the decisions may live here: consider /branch instead of starting from scratch"],
                "trunk": {"node": str(t.get("node")).lower(),
                          "session_id": t.get("session_id"), "name": t.get("name")},
                "related_sessions": related()})

    candidates.sort(key=lambda c: c["score"], reverse=True)
    return {
        "current": {"node": node, "cwd": cwd, "subject": subj,
                    "forked_from": args.forked_from or None,
                    "ownership": own},
        "verdict": verdict,
        "candidates": candidates,
    }

def render_human(res):
    c = res["current"]
    out = [f"position: {c['node']}:{c['cwd']}  subject={c['subject']}",
           f"verdict: {res['verdict']}"]
    if c["ownership"]["declared"]:
        o = c["ownership"]
        out.append(f"ownership: primary={o['primary_node']} src={o['source']} "
                   f"secondary-here={o['is_secondary_here']}")
    for cand in res["candidates"]:
        out.append(f"- [{cand['confidence']}/{cand['score']}] {cand['kind']} "
                   f"-> {cand['node']}:{cand['project_path']}")
        for e in cand["evidence"]:
            out.append(f"    · {e}")
    return "\n".join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", required=True)
    ap.add_argument("--cwd", default="")
    ap.add_argument("--session", default="")
    ap.add_argument("--forked-from", dest="forked_from", default="")
    ap.add_argument("--intent", default="")
    ap.add_argument("--index", default="")
    ap.add_argument("--naming-map", dest="naming_map", default="")
    ap.add_argument("--require-map", dest="require_map", action="store_true",
                    help="the map is declared in config: a missing file is an error, not a missing map")
    ap.add_argument("--human", action="store_true")
    args = ap.parse_args()
    res = build(args)
    if res.get("naming_map_error"):
        # exit 2 like naming.py: the placement could not be computed, it is not `unknown`
        if args.human:
            print(f"where: {res['naming_map_error']}", file=sys.stderr)
        else:
            print(json.dumps(res, ensure_ascii=False))
        sys.exit(2)
    if args.human:
        print(render_human(res))
    else:
        print(json.dumps(res, ensure_ascii=False))

if __name__ == "__main__":
    main()
