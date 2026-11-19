#!/usr/bin/env python3
# stk branch --register helper: writes/updates the STUB of a child session
# just born from /branch (or /fork, /rewind). Sets `forked_from` (authoritative
# edge, derived by the dispatcher from the FIELD forkedFrom of the JSONL) + `name`
# (auto, from the custom-title), leaving status=auto so the next pass
# refines the record. yaml-safe upsert: `## user_notes` and `## extracted`
# preserved byte for byte, user overrides (name_source=user) untouched.
# Invoked via:
#   uv run --with pyyaml --python 3.12 -q python stub.py <md> [opts]
# Output: one JSON line with created / forked_from / name.
import sys, os, json, argparse
import re
import tempfile
import yaml

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config as stkconfig  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("md_path")
ap.add_argument("--session", required=True)
ap.add_argument("--node", required=True)
ap.add_argument("--project-path", default="", dest="project_path")
ap.add_argument("--forked-from", required=True, dest="forked_from")  # sid of the parent (same node)
ap.add_argument("--name", default=None)                              # custom-title of the child
a = ap.parse_args()


def parse_body_sections(body: str) -> dict:
    """## name -> text (header excluded)."""
    sections, cur = {}, None
    for ln in body.splitlines():
        if ln.startswith("## "):
            cur = ln.strip()[3:].strip()
            sections[cur] = []
        elif cur is not None:
            sections[cur].append(ln)
    return {k: "\n".join(v).rstrip("\n") for k, v in sections.items()}


fm: dict = {}
extracted = ""
user_notes = ""
created = False

if os.path.exists(a.md_path):
    raw = open(a.md_path, encoding="utf-8").read()
    parts = stkconfig.split_frontmatter(raw) or []   # delimiter LINES: a --- inside a value is data
    parts = ["", parts[0], parts[1]] if parts else []
    if len(parts) >= 3:
        fm = yaml.safe_load(parts[1]) or {}
        secs = parse_body_sections(parts[2])
        extracted = secs.get("extracted", "")
        user_notes = secs.get("user_notes", "")
    else:
        created = True
else:
    created = True

if created or not fm:
    fm = {
        "schema": "v0",
        "session_id": a.session,
        "node": a.node,
        "project": os.path.basename(a.project_path) if a.project_path else "",
        "project_path": a.project_path,
        "lang": (fm.get("lang", "en") if fm else "en"),
        "name": "",
        "name_source": "auto",
        "class": "task",
        "status": "active",
        "status_source": "auto",
        "tags": [],
        "forked_from": None,
        "children": [],
        "pilots": [],
        "piloted_by": [],
    }
    created = True

# forked_from: authoritative edge, always rewritten (truth comes from the JSONL)
fm["forked_from"] = {"node": a.node, "session_id": a.forked_from}

# name: only if it is not a user override and not already set
if a.name and fm.get("name_source") != "user" and not (fm.get("name") or "").strip():
    fm["name"] = a.name
    fm["name_source"] = "auto"

fm_yaml = yaml.safe_dump(
    fm, allow_unicode=True, sort_keys=False, default_flow_style=None, width=1000
)
out_md = "---\n" + fm_yaml + "---\n"
out_md += f"## extracted\n{extracted}\n\n" if extracted else "## extracted\n\n"
out_md += f"## user_notes\n{user_notes}\n" if user_notes else "## user_notes\n"

os.makedirs(os.path.dirname(a.md_path), exist_ok=True)
# an exclusive temporary file in the record's folder (mkstemp: created, never followed, so a
# pre-existing symlink of a predictable name cannot redirect the write), then an atomic rename
fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(a.md_path)}.", suffix=".tmp", dir=os.path.dirname(a.md_path))
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(out_md)
# mkstemp creates 0600: a rewritten record keeps the mode it had, a new one takes the umask's
# (a shared canon is read by other accounts after rsync -a)
try:
    mode = os.stat(a.md_path).st_mode & 0o777
except FileNotFoundError:
    umask = os.umask(0); os.umask(umask)
    mode = 0o666 & ~umask
os.chmod(tmp, mode)
os.replace(tmp, a.md_path)

print(json.dumps({
    "created": created,
    "forked_from": fm["forked_from"],
    "name": fm.get("name", ""),
}, ensure_ascii=False))
