#!/usr/bin/env python3
"""naming.py — naming context from the cwd and guard on the canonical name.

One resolver for three consumers: `stk hook` (injects the contexts or kb_orgs entry
resolved from the cwd, so the model does not have to remember the map), `stk close
--name` (rejects a name that breaks the rules; `--force` passes the conventions, never the record invariants) and `where.py`
(subject for the placement). Data: `naming-map.yaml` (contexts/kb_orgs/kb_tiers/window_prefix/tokens)
and the closed set of actions in `references/naming.md`, read from the file and not copied. The
path of the map is passed by the caller (`naming_map` of the config).

Context resolution, in order:
  kb-org    <root>/<orgs_dir>/<org>[/<fn>] -> kb_orgs[org].repos[fn] | kb_orgs[org].umbrella (fn not a repo)
            (<root> and <orgs_dir> are the folder names declared in kb_layout; without that
            section neither kb branch fires)
            (fn repo not declared or with an empty value: unknown, never the umbrella)
            (org without an entry in kb_orgs: <contexts[org]>[-<fn>], fn only if it is a repo)
  map       basename in contexts         -> contexts[basename]   (real-target -> kind real-target;
            a list [a, b] = allowed subjects, the first is the default)
  kb-tier   <root>/<dir>/<area>         -> <kb_layout.token>-<kb_tiers[dir]>-<area> (declared folders only)
  prefix    basename = <key>-<slug>      -> contexts[key], candidate theme <slug> (a worktree named after a story)
  unknown   anything else                -> default subject the basename, not verified
  none      no cwd

CLI:
  naming.py context --cwd <p> [--naming-map <f>] [--naming-md <f>] [--text] [--policy warn|error]
                    [--require-map] [--window-auto=<0|1> --window-name=<name>]
                    (with --text: clause on the tmux window; --policy decides whether the text says
                    that close rejects or only reports)
  naming.py check   --cwd <p> --name <n> [--class task|distill] [--naming-map <f>] [--naming-md <f>]
                    [--require-map]
      exit 0 conforming, 1 rejected, 2 guard cannot run (naming.md unreadable or map malformed,
      window_prefix excluded). --require-map: the map is declared in the config (key naming_map),
      so if the file is missing it is an error (exit 2, reason "naming_map declared but missing") and not
      the case "map missing, the generic rules apply", which stays the one of the default path.
"""
import argparse, json, os, re, sys

LEXICON_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
DISTILL_RE = re.compile(r"-distill-\d{4}-\d{2}-\d{2}(-\d+)?$")
REAL_TARGET = "real-target"
DEFAULT_MD = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                          "..", "references", "naming.md")


# ---- data --------------------------------------------------------------------
def load_naming_map(path):
    """{contexts, kb_orgs, kb_tiers, kb_layout, window_prefix, window_error, tokens, raw, path, error}. Map MISSING -> empty (the generic rules apply).
    Map present but unreadable, with `contexts` not a mapping, `kb_orgs` not in the form
    <org>: {umbrella, repos}, `kb_tiers` not in the form <folder>: <token>, or `kb_layout`
    (the folder names of the knowledge base: root, orgs_dir, token) missing while kb_orgs or
    kb_tiers are declared, or malformed -> `error`
    set: the guard does not pass (exit 2) and the hook says so, instead of pretending there
    is no entry. `window_prefix` not in the form <subject>: <prefix> -> only
    `window_error`: it turns off the tmux window clause, not the guard on the name."""
    nm = {"contexts": {}, "kb_orgs": {}, "kb_tiers": {}, "kb_layout": {}, "window_prefix": {}, "window_error": "", "tokens": {}, "raw": "", "path": path or "", "error": ""}
    if not path or not os.path.exists(path):
        return nm
    try:
        import yaml
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        d = yaml.safe_load(raw) or {}
    except Exception as e:
        nm["error"] = f"naming-map.yaml unreadable ({path}): {e.__class__.__name__}"
        return nm
    ctx = d.get("contexts") if isinstance(d, dict) else None
    if ctx is not None and not isinstance(ctx, dict):
        nm["error"] = f"naming-map.yaml: `contexts` is not a mapping ({path})"
        return nm
    kbo = d.get("kb_orgs") if isinstance(d, dict) else None
    if kbo is not None and (not isinstance(kbo, dict)
                            or any(v is not None and (not isinstance(v, dict) or not isinstance(v.get("repos") or {}, dict))
                                   for v in kbo.values())):
        nm["error"] = f"naming-map.yaml: `kb_orgs` is not a mapping <org>: {{umbrella, repos}} ({path})"
        return nm
    # kb_tiers: tier folder under the kb root -> subject token (<kb_layout.token>-<token>-<area>).
    # Without the section the kb-tier branch does not fire: the table lives in the map
    tiers = d.get("kb_tiers") if isinstance(d, dict) else None
    if tiers is not None and (not isinstance(tiers, dict)
                              or any(not isinstance(k, str) or not isinstance(v, str)
                                     or not re.fullmatch(r"[a-z0-9]+", v) for k, v in tiers.items())):
        nm["error"] = f"naming-map.yaml: `kb_tiers` is not a mapping <folder>: <token> of [a-z0-9] only ({path})"
        return nm
    # kb_layout: the folder names of the knowledge base, declared in the map, not in this file.
    # `root` is the kb root folder (matched as a path segment at any depth), `orgs_dir` the folder
    # under it that holds the orgs of kb_orgs, `token` the first token of the subject inside the kb.
    # Without it the two kb branches do not fire; with kb_orgs or kb_tiers declared its absence is
    # an error, not a silent off.
    lay = d.get("kb_layout") if isinstance(d, dict) else None
    if lay is None and (kbo or tiers):
        nm["error"] = f"naming-map.yaml: `kb_layout` (root, orgs_dir, token) is missing while kb_orgs or kb_tiers are declared ({path})"
        return nm
    if lay is not None and (not isinstance(lay, dict)
                            or set(lay) != {"root", "orgs_dir", "token"}
                            or not all(isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9._-]+", v) for v in lay.values())
                            or not re.fullmatch(r"[a-z0-9]+", lay["token"])):
        nm["error"] = f"naming-map.yaml: `kb_layout` is not a mapping with root, orgs_dir and token (folder names, token of [a-z0-9]) ({path})"
        return nm
    nm["contexts"] = ctx or {}
    nm["kb_orgs"] = kbo or {}
    nm["kb_tiers"] = tiers or {}
    nm["kb_layout"] = lay or {}
    wpx = d.get("window_prefix") if isinstance(d, dict) else None
    if wpx is not None and (not isinstance(wpx, dict)
                            or any(not isinstance(x, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", x) for kv in wpx.items() for x in kv)):
        nm["window_error"] = f"naming-map.yaml: `window_prefix` is not a mapping <subject>: <prefix> of tokens only ({path})"
    else:
        nm["window_prefix"] = wpx or {}
    nm["tokens"] = (d.get("tokens") or {}) if isinstance(d, dict) else {}
    nm["raw"] = raw
    return nm


def entry_lines(raw, key):
    """The `<key>:` line of contexts plus the comments that follow it, as they are in the file:
    the comment is where the map keeps the rule that decides (e.g. story sessions)."""
    if not raw or not key:
        return []
    lines = raw.splitlines()
    out, grab, in_ctx, key_indent = [], False, False, 0
    for ln in lines:
        if re.match(r"^contexts:\s*$", ln):
            in_ctx = True
            continue
        if not in_ctx:
            continue
        if re.match(r"^\S", ln):          # another top-level section
            break
        if grab:
            m = re.match(r"^(\s*)#", ln)
            if m and len(m.group(1)) > key_indent:
                out.append(ln.strip())
                continue
            break
        m = re.match(r"^(\s+)" + re.escape(key) + r":(\s|$)", ln)
        if m:
            out.append(ln.strip())
            key_indent = len(m.group(1))
            grab = True
    return out


def entry_comment(lines):
    """The comment of an entry: the `# ...` tail of the key line plus the continuations."""
    out = []
    for i, ln in enumerate(lines):
        if i == 0:
            if "#" in ln:
                out.append(ln.split("#", 1)[1].strip())
        else:
            out.append(ln.lstrip("# ").rstrip())
    return [c for c in out if c]


def load_actions(md_path):
    """Closed set of actions from the line `Closed set of actions:` of naming.md.
    ValueError if the file or the line is missing: the guard must not pass by absence."""
    try:
        with open(md_path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        raise ValueError(f"naming.md unreadable ({md_path}): {e}")
    m = re.search(r"Closed set of actions:\s*\n?([^\n]+)", text)
    if not m:
        raise ValueError(f"line 'Closed set of actions:' not found in {md_path}")
    acts = [a.strip() for a in m.group(1).replace("`", "").rstrip(".").split("|") if a.strip()]
    if any(not re.fullmatch(r"[a-z]+", a) for a in acts):
        raise ValueError(f"set of actions not parsable in {md_path}: {acts}")
    if not acts:
        raise ValueError(f"empty set of actions in {md_path}")
    return acts


# ---- context from the cwd ----------------------------------------------------------
def resolve_context(cwd, nm):
    return _finish(_resolve(cwd, nm))


def _resolve(cwd, nm):
    ctx = nm.get("contexts", {})
    res = {"kind": "none", "key": None, "subject": None, "subjects": None, "guard_prefix": None, "rule": "",
           "theme_hint": None, "basename": "", "cwd": cwd or "", "entry_lines": []}
    if not cwd:
        return res
    parts = [p for p in cwd.split("/") if p]
    base = parts[-1] if parts else ""
    res["basename"] = base
    root = "/" if cwd.startswith("/") else ""

    def valid(v):
        if isinstance(v, list):    # several allowed subjects for the same entry
            return bool(v) and all(valid(x) and x != REAL_TARGET for x in v)
        return isinstance(v, str) and v.strip() != ""

    def subjects(v):
        return [str(x).strip() for x in v] if isinstance(v, list) else [str(v).strip()]

    def shown(v):
        return "[" + ", ".join(subjects(v)) + "]" if isinstance(v, list) else v

    # the kb is recognized by the folder names of kb_layout: no layout, no kb branch
    lay = nm.get("kb_layout") or {}
    kb_root, orgs_dir, kb_tok = lay.get("root"), lay.get("orgs_dir"), lay.get("token")
    kb_i = parts.index(kb_root) if kb_root and kb_root in parts else None
    rest = parts[kb_i + 1:] if kb_i is not None else []

    # <root>/<orgs_dir>/<org>[/<function repo>] with an entry in kb_orgs: subject declared per repo
    # (umbrella and function repo), never composed from contexts[org] + fn
    kbo = nm.get("kb_orgs", {})
    if kb_i is not None and len(rest) > 1 and rest[0] == orgs_dir and rest[1] in kbo:
        org, spec = rest[1], kbo[rest[1]] or {}
        repos = spec.get("repos") or {}
        fn = rest[2] if len(rest) > 2 else None
        fn_repo = fn is not None and os.path.exists(os.path.join(root, *parts[:kb_i + 4], ".git"))
        if fn in repos and valid(repos[fn]):
            subj, line = str(repos[fn]).strip(), f"kb_orgs: {org}: repos: {fn}: {repos[fn]}"
        elif fn in repos or fn_repo:
            # repo declared without a value, or repo (.git dir or file) not declared: it is not
            # the umbrella, and the map does not say its subject. Detects the .git only locally
            res.update(kind="unknown", key=org, subject=None, undeclared=True,
                       rule=f"naming-map.yaml kb_orgs: {org}: the repo {fn} has no subject in repos, subject not verifiable")
            return res
        elif valid(spec.get("umbrella")):
            subj, line = str(spec["umbrella"]).strip(), f"kb_orgs: {org}: umbrella: {spec['umbrella']}"
        else:
            res.update(kind="unknown", key=org, subject=None,
                       rule=f"naming-map.yaml kb_orgs: {org}: no valid subject for {cwd}, subject not verifiable")
            return res
        res.update(kind="kb-org", key=org, subject=subj,
                   rule=f"naming-map.yaml {line} -> {subj}-<theme>")
        return res

    # <root>/<orgs_dir>/<org>[/<function repo>] without an entry in kb_orgs: only for an org DECLARED in contexts (the basename of a
    # function repo is generic and collides: <root>/<orgs_dir>/<org>/<fn> is not the repo called <fn>)
    if kb_i is not None and len(rest) > 1 and rest[0] == orgs_dir and rest[1] in ctx and valid(ctx[rest[1]]) \
            and ctx[rest[1]] != REAL_TARGET:
        org = rest[1]
        subj = str(ctx[org])
        if len(rest) > 2 and os.path.isdir(os.path.join(root, *parts[:kb_i + 4], ".git")):
            subj = f"{subj}-{rest[2]}"
        res.update(kind="kb-org", key=org, subject=subj,
                   rule=f"naming-map.yaml contexts: {org}: {ctx[org]} + {kb_root}/{orgs_dir}/{org}/<function repo> -> {subj}-<theme>",
                   entry_lines=entry_lines(nm.get("raw", ""), org))
        return res

    # basename declared in contexts: wins also inside the kb (e.g. <kb>/<dir>/<repo> -> <token>)
    if base in ctx:
        val = ctx[base]
        res.update(key=base, entry_lines=entry_lines(nm.get("raw", ""), base))
        if val == REAL_TARGET:
            res.update(kind=REAL_TARGET, subject=None,
                       rule=f"naming-map.yaml contexts: {base}: {REAL_TARGET} -> NEVER the repo name, use the real target")
        elif not valid(val):
            res.update(kind="unknown", subject=base,
                       rule=f"naming-map.yaml contexts: {base}: entry without a valid subject ({val!r}), subject not verifiable")
        else:
            res.update(kind="map", subject=subjects(val)[0], subjects=subjects(val),
                       rule=f"naming-map.yaml contexts: {base}: {shown(val)}")
        return res

    tiers = nm.get("kb_tiers", {})
    if kb_i is not None and rest and rest[0] in tiers:
        tok = tiers[rest[0]]
        area = rest[1] if len(rest) > 1 else None
        res.update(kind="kb-tier", subject=f"{kb_tok}-{tok}-{area}" if area else f"{kb_tok}-{tok}",
                   guard_prefix=f"{kb_tok}-{tok}", theme_hint=rest[-1] if len(rest) > 1 else None,
                   rule="naming-map.yaml kb_tiers: " + rest[0] + ": " + tok + " -> " + kb_tok + "-" + tok + "-<area> from the path (naming.md § How to choose the subject, Inside the kb)")
        return res

    pref = sorted((k for k in ctx if isinstance(k, str) and base.startswith(k + "-")
                   and (ctx[k] == REAL_TARGET or valid(ctx[k]))), key=len)
    if pref:
        key = pref[-1]
        val = ctx[key]
        res.update(key=key, theme_hint=base[len(key) + 1:],
                   entry_lines=entry_lines(nm.get("raw", ""), key))
        if val == REAL_TARGET:
            res.update(kind=REAL_TARGET, subject=None,
                       rule=f"naming-map.yaml contexts: {key}: {REAL_TARGET} (prefix of {base}) -> NEVER the repo name, use the real target")
        else:
            res.update(kind="prefix", subject=subjects(val)[0], subjects=subjects(val),
                       rule=f"naming-map.yaml contexts: {key}: {shown(val)} (prefix of {base}; candidate theme: {res['theme_hint']})")
        return res

    res.update(kind="unknown", subject=base or None,
               rule=f"{base!r} is not an entry of contexts: subject not verifiable from the map")
    return res


def _finish(res):
    if res["guard_prefix"] is None:
        res["guard_prefix"] = res["subject"]
    if res["subjects"] is None and res["guard_prefix"]:
        res["subjects"] = [res["guard_prefix"]]
    return res


def subject_of(path, nm):
    """Compat for where.py: subject (concise token) or None if not resolvable from the path."""
    return resolve_context(path, nm)["subject"]


def _subject_re(subject):
    # "<prefix>{N}" -> <prefix>[0-9]+
    return re.escape(subject).replace(r"\{N\}", "[0-9]+")


# ---- guard on the name ----------------------------------------------------------
def check_invariants(name, checks):
    """The three rules that guard the record itself and need neither the map nor
    naming.md: an empty name, the `wip-` marker, characters outside the lexicon.
    -> a rejection dict (invariant=True) or None; `checks` receives the rules passed.
    `main()` runs them BEFORE the map errors: a map declared but missing must not
    let a wip- name through as "not checked"."""
    def reject(reason, rule):
        return {"ok": False, "reason": reason, "rule": rule, "invariant": True, "checks": list(checks)}

    if not name:
        return reject("empty name", "naming.md § Name structure")
    if name.startswith("wip-"):
        return reject("starts with 'wip-'",
                      "naming.md § The `wip-` lifecycle marker: reserved to sessions not closed, --name takes the name without it")
    checks.append("wip")
    if not LEXICON_RE.match(name):
        return reject("characters outside the lexicon ([a-z0-9] only, separated by '-')", "naming.md § Lexicon")
    checks.append("lexicon")
    return None


def check_name(name, ctx, actions, sclass="task"):
    """-> {ok, reason, rule, invariant, checks}. No earlier condition short-circuits
    the subject check: every rule is evaluated and the first one violated rejects.
    `invariant` marks a rejection that guards the record itself (check_invariants)
    and not a convention of the map: `stk close` refuses those with
    naming_policy=warn too, see bin/stk."""
    checks = []

    def reject(reason, rule, invariant=False):
        return {"ok": False, "reason": reason, "rule": rule, "invariant": invariant, "checks": checks}

    inv = check_invariants(name, checks)
    if inv:
        return inv


    if sclass == "distill":
        if not DISTILL_RE.search(name):
            return reject("distill class without the suffix -<skilltag>-distill-<YYYY-MM-DD>",
                          "naming.md § distill: <parent-canonical-name>-<skilltag>-distill-<YYYY-MM-DD>")
        checks.append("distill-suffix")
        return {"ok": True, "reason": "distill: conforming suffix (subject = name of the parent, not verified)",
                "rule": "naming.md § distill", "checks": checks}

    if "-" not in name:
        return reject("a single token: the subject or the action is missing",
                      "naming.md § Name structure: <subject>[-<number>]-<theme>-<action>")
    checks.append("tokens")
    action = name.rsplit("-", 1)[-1]
    if action not in actions:
        return reject(f"final action '{action}' outside the closed set ({' | '.join(actions)})",
                      "naming.md § Lexicon: closed set of actions")
    checks.append("action")

    kind = ctx["kind"]
    if kind in ("map", "prefix", "kb-tier", "kb-org"):
        # several allowed subjects (list entry): the one the name carries counts; the longest
        # first, so a subject that is a prefix of another does not steal its match
        allowed = ctx.get("subjects") or [ctx["guard_prefix"]]
        subj = next((x for x in sorted(allowed, key=len, reverse=True)
                     if re.match(_subject_re(x) + r"(-|$)", name)), None)
        if subj is None:
            want = " | ".join(f"'{x}'" for x in allowed)
            return reject(f"the first token is not the subject {want} of the context {ctx['key'] or ctx['basename']!r}",
                          ctx["rule"] + " -> the name starts with " + " or ".join(f"'{x}-'" for x in allowed))
        checks.append("subject")
        # a token of digits only right after the subject: the issue number (naming.md
        # § Name structure); allowed, and the subject in front stays verified. In kb-tier
        # the verified prefix is not the whole subject (the area is missing): no annotation
        after = re.sub("^" + _subject_re(subj) + "-?", "", name, count=1).split("-")
        issue = after[0] if kind != "kb-tier" and len(after) > 1 and after[0].isdigit() else None
        if issue:
            checks.append("issue")
        return {"ok": True, "reason": f"subject '{subj}'" + (f", issue {issue}" if issue else "")
                + f" and action '{action}' conforming", "rule": ctx["rule"], "checks": checks}
    if kind == REAL_TARGET:
        for b in {ctx["basename"], ctx["key"]} - {None, ""}:
            if name == b or name.startswith(b + "-"):
                return reject(f"the subject is the repo name '{b}', which the map marks real-target", ctx["rule"])
        checks.append("not-repo-name")
        return {"ok": True, "reason": f"action '{action}' conforming; subject not verifiable (real-target)",
                "rule": ctx["rule"], "checks": checks}
    return {"ok": True, "reason": f"action '{action}' conforming; subject not verified ({ctx['rule']})",
            "rule": ctx["rule"], "checks": checks}


# ---- text for the hook ----------------------------------------------------------
def context_text(ctx, actions, map_path, errors=(), policy="warn", map_present=True):
    acts = " | ".join(actions) if actions else "set NOT read"
    if errors:
        return ("Naming context NOT resolvable: " + "; ".join(errors)
                + ". Fix the file before proposing a name; meanwhile the rules of references/naming.md apply.")
    k, s, cwd = ctx["kind"], ctx["subject"], ctx["cwd"]
    # naming_policy of the config: with error close rejects, with warn it reports and accepts
    guard = ("and stk close rejects it if it does not respect subject or action (--force to pass)" if policy == "error"
             else "and stk close reports a name that does not respect subject or action, but accepts it (naming_policy=warn)")
    # with no map (default path missing, not declared) there is nothing to read but the
    # generic rules: the clause must not send the model to a file that does not exist
    if map_present:
        check = (f"Before proposing a name read references/naming.md of the session-tracker skill and {map_path}, "
                 "and cite in the proposal the map row applied: "
                 "a name already in the title or in the record does not count as conforming until it is compared with that row.")
    else:
        check = ("Before proposing a name read references/naming.md of the session-tracker skill: "
                 "a name already in the title or in the record does not count as conforming until it is compared with its rules.")
    tail = (f" The name ends with an action of the closed set of references/naming.md ({acts}). "
            "After the subject comes the issue number without #, if the session works on an issue, then the theme. "
            f"stk close --name takes the same value without wip-, {guard}. " + check)
    if k == "none":
        return (f"Naming context: no cwd or naming-map.yaml missing in {map_path}; apply ONLY the generic rules "
                f"of references/naming.md of the session-tracker skill and derive the subject from the content (actions: {acts}).")
    if not map_present:
        return (f"Naming context for the cwd {cwd}: no naming map ({map_path} missing). Apply ONLY the generic rules "
                "of references/naming.md of the session-tracker skill and derive the subject from the content of the work "
                f"(by default the basename `{ctx['basename']}`, otherwise the real target). Every proposed name "
                "(/rename wip-<name> and stk close --name) starts with the subject." + tail)
    if k in ("map", "prefix"):
        alls = ctx.get("subjects") or [s]
        shown = f"[{', '.join(alls)}]" if len(alls) > 1 else s
        head = (f"Naming context resolved from the cwd {cwd}: row `{ctx['key']}: {shown}` of contexts in {map_path}"
                + (f" (the basename {ctx['basename']} has the prefix of the entry; candidate theme: {ctx['theme_hint']})" if k == "prefix" else ""))
        if len(alls) > 1:
            head += (f". Allowed subjects: `{s}` (default) and " + ", ".join(f"`{x}`" for x in alls[1:])
                     + ": the subject is decided by the repo the session actually works on; without one the "
                     "default applies. Every proposed name "
                     "(/rename wip-<name> and stk close --name) starts with " + " or ".join(f"`{x}-`" for x in alls) + ".")
        else:
            head += f". The subject is `{s}`: every proposed name (/rename wip-<name> and stk close --name) starts with `{s}-`."
        com = entry_comment(ctx["entry_lines"])
        if com:
            head += " Comment of the entry in the map: " + " ".join(com)
        return head + tail
    if k == "kb-tier":
        return (f"Naming context resolved from the cwd {cwd}: {ctx['rule']}. Every proposed name starts with "
                f"`{ctx['guard_prefix']}-<area>`, with the area taken from the folder right under the tier (here `{ctx['subject'][len(ctx['guard_prefix']) + 1:]}`; "
                "deeper levels go in the theme), "
                "abbreviated with the tokens of the map if it has one (e.g. net for network)." + tail)
    if k == "kb-org":
        return (f"Naming context resolved from the cwd {cwd}: {ctx['rule']}. The subject is `{s}`: every proposed name "
                f"starts with `{s}-`." + tail)
    if k == REAL_TARGET:
        return (f"Naming context resolved from the cwd {cwd}: row `{ctx['key']}: real-target` of contexts in {map_path}. "
                f"The subject is NOT `{ctx['basename']}`: it is the real target of the work (node, instance, tool, domain), "
                "to be derived from the content with the concise tokens of the tokens section of the map." + tail)
    if ctx.get("undeclared"):
        return (f"Naming context for the cwd {cwd}: {ctx['rule']} ({map_path}). The subject must be declared "
                f"in kb_orgs.{ctx['key']}.repos; do not use the basename `{ctx['basename']}` (generic, collides) "
                "nor the umbrella's subject: propose to the user the entry to add." + tail)
    return (f"Naming context for the cwd {cwd}: {ctx['rule']} ({map_path}). "
            f"Subject not derivable from the map: by default the basename `{ctx['basename']}`, otherwise the real target from the content." + tail)


def window_prefixes(ctx, nm):
    """Allowed prefixes for the name of a tmux window: the subject, or its abbreviation in
    window_prefix (the key also applies to the subjects <key>-*, the longest wins). [] if the
    map does not declare the subject: unknown folder, real-target, kb-tier (the session derives it)."""
    if ctx["kind"] not in ("map", "prefix", "kb-org"):
        return []
    wpx = nm.get("window_prefix", {})
    out = []
    for s in ctx.get("subjects") or []:
        p = next((v for k, v in sorted(wpx.items(), key=lambda kv: -len(kv[0])) if s == k or s.startswith(f"{k}-")), s)
        if p not in out:
            out.append(p)
    return out


def window_text(ctx, nm, name, auto):
    """Sentence for the hook about the current tmux window. Only a never-named window
    (automatic-rename on) or one called <prefix>-<number> can be renamed: every other name stays intact."""
    if nm.get("window_error"):
        return nm["window_error"] + ": fix the file, and meanwhile do not rename the tmux window."
    prefs = window_prefixes(ctx, nm)
    form = " or ".join(f"{p}-<issue number>, or {p}-<short slug>" for p in prefs) or "<subject>-<issue number>, or <subject>-<short slug>"
    form += " if there is no issue"
    if not prefs:
        form += " (the subject is the one of the session name)"
    numbered = any(re.fullmatch(_subject_re(p) + r"-[0-9]+", name) for p in prefs)
    if auto == "1" or numbered:
        head = (f"As soon as the issue or the theme is clear rename your own window with tmux rename-window -t \"$TMUX_PANE\" {form}, "
                "if the window does not already have that name.")
    else:
        head = (f"The tmux window is called `{name}` and the name stays. Do not rename it.")
    return f"{head} A new window that you open for this project is called {form}; the prefix alone is left to the user."


# ---- CLI -----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("context", "check"):
        p = sub.add_parser(name)
        p.add_argument("--cwd", default="")
        p.add_argument("--naming-map", dest="naming_map", default="")
        p.add_argument("--naming-md", dest="naming_md", default=DEFAULT_MD)
        p.add_argument("--require-map", dest="require_map", action="store_true",
                       help="the map file is declared in the config: if it is missing it is an error, not an absent map")
        if name == "context":
            p.add_argument("--text", action="store_true", help="sentence for the hook instead of the JSON")
            p.add_argument("--policy", choices=("warn", "error"), default="warn",
                           help="naming_policy of the config: changes the sentence about the behaviour of close")
            p.add_argument("--window-name", dest="window_name", default=None, help="name of the current tmux window")
            p.add_argument("--window-auto", dest="window_auto", default=None, help="#{automatic-rename} of the window")
        else:
            p.add_argument("--name", required=True)
            p.add_argument("--class", dest="sclass", default="task")
    a = ap.parse_args()

    errors = []
    if a.require_map and a.naming_map and not os.path.exists(a.naming_map):
        errors.append(f"naming_map declared but missing ({a.naming_map})")
    nm = load_naming_map(a.naming_map)
    if nm["error"]:
        errors.append(nm["error"])
    ctx = resolve_context(a.cwd, nm)
    try:
        actions = load_actions(a.naming_md)
    except ValueError as e:
        errors.append(str(e))
        actions = []

    if a.cmd == "context":
        if a.text:
            text = context_text(ctx, actions, a.naming_map or "~/.local/session-tracker/naming-map.yaml", errors, a.policy,
                                map_present=bool(a.naming_map) and os.path.exists(a.naming_map))
            if a.window_auto is not None and not errors:
                text += " " + window_text(ctx, nm, a.window_name or "", a.window_auto)
            print(text)
        else:
            print(json.dumps({**ctx, "actions": actions, "errors": errors}, ensure_ascii=False))
        return

    # invariants first: they need no map, so a map error must not turn a wip- name into
    # "not checked" (with naming_policy=warn that would write the record)
    inv = check_invariants(a.name, [])
    if inv:
        print(json.dumps(inv, ensure_ascii=False))
        sys.exit(1)
    if errors:
        print(json.dumps({"ok": False, "reason": "; ".join(errors), "rule": "guard cannot run"}))
        sys.exit(2)
    res = check_name(a.name, ctx, actions, a.sclass)
    res["context"] = {k: ctx[k] for k in ("kind", "key", "subject", "subjects", "guard_prefix", "basename")}
    print(json.dumps(res, ensure_ascii=False))
    sys.exit(0 if res["ok"] else 1)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # never exit 1 (= rejection) for a crash: 2 = guard cannot run
        print(json.dumps({"ok": False, "reason": f"crash: {e.__class__.__name__}: {e}", "rule": "guard cannot run"}))
        sys.exit(2)
