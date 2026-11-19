#!/usr/bin/env python3
# stk close helper: edits the YAML frontmatter of the session record in a
# yaml-safe way (keeps `## user_notes` sacred). Invoked via:
#   uv run --with pyyaml --python 3.12 -q python close.py <md> [opts]
# Output: one JSON line with prev_status / new_status / tags_added / links_added / created.
import sys, os, json, argparse
import re
import tempfile
import yaml

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config as stkconfig  # noqa: E402
from datetime import datetime

ap = argparse.ArgumentParser()
ap.add_argument("md_path")
ap.add_argument("--status", required=True, choices=["done", "dropped", "superseded", "branched"])
ap.add_argument("--session", required=True)
ap.add_argument("--node", required=True)
ap.add_argument("--project-path", default="", dest="project_path")
ap.add_argument("--add-tag", action="append", default=[], dest="add_tag")
ap.add_argument("--add-link", action="append", default=[], dest="add_link")
ap.add_argument("--summary", default=None)
ap.add_argument("--name", default=None)                       # canonical name (see references/naming.md)
ap.add_argument("--class", default=None, dest="session_class")  # task | distill
ap.add_argument("--distill-target", default=None, dest="distill_target")  # only class=distill
a = ap.parse_args()


def stringify_datetimes(d):
    if isinstance(d, dict):
        return {k: stringify_datetimes(v) for k, v in d.items()}
    if isinstance(d, list):
        return [stringify_datetimes(v) for v in d]
    if isinstance(d, datetime):
        # round-trip ISO 8601 with Z if UTC
        s = d.isoformat()
        if s.endswith("+00:00"):
            s = s[:-6] + "Z"
        return s
    return d


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

if created:
    fm = {
        "schema": "v0",
        "session_id": a.session,
        "node": a.node,
        "project": os.path.basename(a.project_path) if a.project_path else "",
        "project_path": a.project_path,
        "lang": fm.get("lang", "en"),
        "name": fm.get("name", ""),
        "name_source": fm.get("name_source", "auto"),
        "class": fm.get("class", "task"),
        "status": "unknown",
        "status_source": "auto",
        "tags": [],
        "forked_from": None,
        "children": [],
        "pilots": [],
        "piloted_by": [],
    }

prev_status = fm.get("status", "unknown")

old_tags = list(fm.get("tags") or [])
new_tags = list(old_tags)
tags_added = []
for t in a.add_tag:
    if t not in new_tags:
        new_tags.append(t)
        tags_added.append(t)

old_links = list(fm.get("links") or [])
new_links = list(old_links)
links_added = []
for l in a.add_link:
    if l not in new_links:
        new_links.append(l)
        links_added.append(l)

fm["status"] = a.status
fm["status_source"] = "user"
fm["dormancy_risk"] = "low"  # closed = low
fm["tags"] = new_tags
if new_links:
    fm["links"] = new_links

# canonical name / class: user override (name_source=user -> not overwritable by the merge)
if a.name is not None:
    fm["name"] = a.name
    fm["name_source"] = "user"
if a.session_class is not None:
    fm["class"] = a.session_class
if a.distill_target is not None:
    fm["distill_target"] = a.distill_target

fm = stringify_datetimes(fm)

if a.summary is not None:
    lines = extracted.splitlines() if extracted else []
    out_lines = []
    replaced = False
    for ln in lines:
        if ln.startswith("summary:") and not replaced:
            out_lines.append(f"summary: {a.summary}")
            replaced = True
        else:
            out_lines.append(ln)
    if not replaced:
        out_lines.append(f"summary: {a.summary}")
    extracted = "\n".join(out_lines)

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
    "prev_status": prev_status,
    "new_status": a.status,
    "name": fm.get("name", ""),
    "class": fm.get("class", ""),
    "tags_added": tags_added,
    "links_added": links_added,
    "created": created,
}, ensure_ascii=False))
