#!/usr/bin/env python3
# Deterministic merge: digests.jsonl + manifest.jsonl -> md records in the local shard.
# Upsert (NOT replace): keeps user overrides when the record already exists.
#
# Auto computed fields:
#   - digest + manifest join, reciprocal children, dormancy_risk monotonic by age,
#     auto downgrade active->dormant for stale sessions with open items, pilot link
#     forward-ref (low-confidence, session_id null).
#
# Preservation rules (record already present):
#   - status_source=user -> keeps status_source + status (user override)
#   - tags = union(existing, dg.tags) (no replace)
#   - links = kept as they are (written only by `stk close --add-link`)
#   - pilots = union(existing, new pilot_candidates)
#   - piloted_by = kept (written only by incoming link events)
#   - ## user_notes = sacred (kept byte for byte)
#   - ## extracted = always rewritten from the digest (it is the "LLM source")
import json, os, re, sys
import yaml
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config as stkconfig  # noqa: E402

CFG = stkconfig.load()
# a relative path in config would put the shard under the current folder (same rule as
# `_paths_check` in bin/stk for every other writer): stop before reading anything.
_PATH_ERRORS = stkconfig.path_errors(CFG)
if _PATH_ERRORS:
    sys.stderr.write("merge.py: " + "; ".join(_PATH_ERRORS) + "\n")
    sys.exit(2)
STK_LOCAL = CFG["data_dir"]
SHARD = f"{STK_LOCAL}/shard"
def _node():
    n = CFG["node"]          # STK_NODE, then the `node` key of the config file
    if n: return n
    p = f"{STK_LOCAL}/node"
    if os.path.exists(p): return open(p).read().strip()
    return os.uname().nodename.split(".")[0].lower()
NODE = _node()
# ssh aliases allowed as pilot: `remote_aliases` of the config. Empty list = no
# pilot materialized, which for whoever does not pilot remote sessions is the right behaviour.
VALID_PILOTS = set(CFG["remote_aliases"])
NOW = datetime.now(timezone.utc)
NOW_ISO = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")

def load_jsonl(p):
    d = {}
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        d[o["session_id"]] = o
    return d

manifest = load_jsonl(f"{STK_LOCAL}/manifest.jsonl")
digests  = load_jsonl(sys.argv[1])

def load_link_events(path):
    """the `link` events (`stk link`) of this node's shard, in order; [] if there is none"""
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("event") == "link" and ev.get("rel") == "pilots":
            out.append(ev)
    return out
link_events_in = load_link_events(f"{SHARD}/events.jsonl")

def age_days(iso):
    try:
        t = datetime.fromisoformat(iso.replace("Z","+00:00"))
        return (NOW - t).days
    except Exception:
        return 9999

# reciprocal children from the whole manifest (every scanned session, not only the ones with a
# digest in this pass), merged below with the children a record already has
indexed = set(digests)
children = {}
for sid in manifest:
    fk = manifest.get(sid, {}).get("forked_from")
    if fk and fk in indexed:
        children.setdefault(fk, []).append(sid)

def parse_body(body_text):
    """## name -> text (header excluded)."""
    sections, cur = {}, None
    for ln in body_text.splitlines():
        if ln.startswith("## "):
            cur = ln[3:].strip()
            sections[cur] = []
        elif cur is not None:
            sections[cur].append(ln)
    return {k: "\n".join(v).rstrip("\n") for k, v in sections.items()}

def read_existing(md_path):
    """({frontmatter}, user_notes_text). ({}, '') if missing or malformed."""
    if not os.path.exists(md_path):
        return {}, ""
    raw = open(md_path, encoding="utf-8").read()
    # the delimiter is a LINE of three dashes: a `---` inside a value (a name, a note) is data
    parts = stkconfig.split_frontmatter(raw) or []
    parts = ["", parts[0], parts[1]] if parts else []  # same shape as before: [prefix, frontmatter, body]
    if len(parts) < 3:
        return {}, ""
    try:
        fm = yaml.safe_load(parts[1]) or {}
    except Exception:
        fm = {}
    secs = parse_body(parts[2])
    return fm, secs.get("user_notes", "")

def stringify_datetimes(o):
    if isinstance(o, dict): return {k: stringify_datetimes(v) for k, v in o.items()}
    if isinstance(o, list): return [stringify_datetimes(v) for v in o]
    if isinstance(o, datetime):
        s = o.isoformat()
        if s.endswith("+00:00"): s = s[:-6] + "Z"
        return s
    return o

def ylist(items, indent="  "):
    if not items: return " []"
    return "\n" + "\n".join(f"{indent}- {str(x)}" for x in items)

link_events = []
written = []
for sid, dg in digests.items():
    m = manifest.get(sid)
    if not m:
        print(f"WARN: no manifest for {sid}", file=sys.stderr); continue

    ep = m["encoded_project"]
    dst_dir = f"{SHARD}/{ep}"
    os.makedirs(dst_dir, exist_ok=True)
    md_path = f"{dst_dir}/{sid}.md"
    existing_fm, existing_user_notes = read_existing(md_path)

    proposed = dg.get("proposed_status","unknown")
    openitems = dg.get("open") or []
    a = age_days(m.get("last_activity_at",""))

    # status / status_source: honours the user override
    existing_ss = existing_fm.get("status_source", "auto")
    if existing_ss == "user":
        status = existing_fm.get("status", proposed)
        ss = "user"
    else:
        status = proposed
        ss = "auto"
        if status == "active" and a > 7 and openitems:
            status = "dormant"

    closed = status in {"done","dropped","superseded"}
    if closed or not openitems: risk = "low"
    elif a > 30: risk = "high"
    elif a >= 7: risk = "medium"
    else: risk = "low"

    # name / name_source: honours the user override (mirror of status). auto = harness
    # title captured by the scan (manifest.custom_title); if missing, keeps the existing one.
    if existing_fm.get("name_source") == "user":
        name = existing_fm.get("name", "")
        name_source = "user"
    else:
        name = m.get("custom_title") or existing_fm.get("name", "") or ""
        name_source = "auto"
    # class / distill_target: kept (set at close or derived); default task
    session_class = existing_fm.get("class") or "task"
    distill_target = existing_fm.get("distill_target")

    # tags: union(existing, digest), keeps order
    old_tags = list(existing_fm.get("tags") or [])
    tags = list(old_tags)
    for t in (dg.get("tags") or []):
        if t not in tags: tags.append(t)

    # links: kept intact
    links = list(existing_fm.get("links") or [])

    # pilots: union(existing, new pilot_candidates), dedup by (node, session_id)
    existing_pilots = list(existing_fm.get("pilots") or [])
    pcands = [p for p in (dg.get("pilot_candidates") or []) if p in VALID_PILOTS]
    pilots = list(existing_pilots)
    def _pilot_known(p_node, p_sid):
        for ep_ in pilots:
            if ep_.get("node") == p_node and ep_.get("session_id") == p_sid:
                return True
        return False
    for p in pcands:
        if not _pilot_known(p, None):
            pilots.append({"node": p, "session_id": None, "confidence": "low"})
            link_events.append({
                "ts": NOW_ISO, "node": NODE,
                "event":"link","rel":"pilots",
                "pilot":{"node":NODE,"session_id":sid},
                "piloted":{"node":p,"session_id":None},
                "by":"auto","confidence":"low"
            })

    piloted_by = list(existing_fm.get("piloted_by") or [])
    # `stk link` events of this node's shard: pilots on the pilot's record, piloted_by on the
    # piloted one (when it is a session of this node); dedup by (node, session_id)
    for ev in link_events_in:
        pl, pd = ev.get("pilot") or {}, ev.get("piloted") or {}
        if pl.get("node") == NODE and pl.get("session_id") == sid and not _pilot_known(pd.get("node"), pd.get("session_id")):
            pilots.append({"node": pd.get("node"), "session_id": pd.get("session_id"), "confidence": ev.get("confidence", "low")})
        if pd.get("node") == NODE and pd.get("session_id") == sid \
           and not any(x.get("node") == pl.get("node") and x.get("session_id") == pl.get("session_id") for x in piloted_by):
            piloted_by.append({"node": pl.get("node"), "session_id": pl.get("session_id"), "confidence": ev.get("confidence", "low")})

    fk = m.get("forked_from")
    forked = {"node": NODE, "session_id": fk} if fk else None
    chld = list(existing_fm.get("children") or [])
    for c in children.get(sid, []):
        if not any(x.get("node") == NODE and x.get("session_id") == c for x in chld):
            chld.append({"node": NODE, "session_id": c})

    fm_out = {
        "schema": "v0",
        "session_id": sid,
        "node": NODE,
        "project": m.get("project", ""),
        "project_path": m.get("project_path", ""),
        "git_branch": m.get("git_branch", ""),
        "lang": dg.get("lang", "en"),
        "name": name,
        "name_source": name_source,
        "class": session_class,
        "status": status,
        "status_source": ss,
        "dormancy_risk": risk,
        "tags": tags,
        "forked_from": forked,
        "children": chld,
        "pilots": pilots,
        "piloted_by": piloted_by,
        "started_at": m.get("started_at", ""),
        "last_activity_at": m.get("last_activity_at", ""),
        "last_indexed_at": NOW_ISO,
        "last_indexed_uuid": m.get("last_uuid", ""),
        "n_events": m.get("n_events", 0),
    }
    if links:
        fm_out["links"] = links
    if distill_target:
        fm_out["distill_target"] = distill_target

    fm_out = stringify_datetimes(fm_out)
    fm_yaml = yaml.safe_dump(fm_out, allow_unicode=True, sort_keys=False,
                             default_flow_style=None, width=1000)

    body = []
    body.append("## extracted")
    body.append(f"goal: {dg.get('goal','')}")
    body.append(f"summary: {dg.get('summary','')}")
    body.append("done:" + ylist(dg.get("done") or []))
    body.append("open:" + ylist(openitems))
    body.append("decisions:" + ylist(dg.get("decisions") or []))
    body.append("internal_branches:" + ylist(dg.get("internal_branches") or []))
    body.append("")
    body.append("## user_notes")
    if existing_user_notes:
        body.append(existing_user_notes)

    out_md = "---\n" + fm_yaml + "---\n" + "\n".join(body) + "\n"
    open(md_path, "w", encoding="utf-8").write(out_md)
    written.append((sid, status, risk, len(openitems), [p["node"] for p in pilots]))

# append link events to the local shard
if link_events:
    with open(f"{SHARD}/events.jsonl", "a", encoding="utf-8") as fh:
        for e in link_events:
            fh.write(json.dumps(e, ensure_ascii=False) + "\n")

for sid, st, rk, no, pl in written:
    print(f"{sid[:8]}  status={st:<9} risk={rk:<6} open={no}  pilots={pl}")
print(f"-- {len(written)} records written, {len(link_events)} link events")
