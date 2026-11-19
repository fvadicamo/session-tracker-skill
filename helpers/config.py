#!/usr/bin/env python3
"""config.py — node configuration shared by the Python helpers.

Same contract as `_cfg_get` / `_cfg_resolve` in `bin/stk` (keep the two in step):
  file        ${XDG_CONFIG_HOME:-~/.config}/session-tracker/config, `key=value` lines,
              `#` comments only at the start of a line, optional single or double quotes
              around the value; a leading `~/` is expanded on local paths only (data_dir,
              naming_map, hook_extra_context_file, and canon_path when canon_mode is local:
              with ssh the remote shell expands it)
  precedence  environment (STK_*) > file > default; an empty variable counts as unset
  lists       comma- or whitespace-separated
  on/off      the hook_* switches; any other value is treated as off by the hook (logged)
  paths       data_dir, naming_map, hook_extra_context_file and canon_path (local mode) are
              absolute or start with `~/`; a relative one is a config error (path_errors):
              it would resolve against the caller's cwd, a different folder for every session

Defaults are neutral: local store under data_dir, no remote host, git untouched, empty
node and alias lists, hook clauses off, naming policy `warn` (the hook proposes a name,
`close` reports a non-conforming one but accepts it). Nothing here names a real node.
"""
import os

HOME = os.path.expanduser("~")

# key -> (environment variable, default). The defaults of canon_path and naming_map depend on
# data_dir and are filled in by load().
KEYS = {
    "data_dir":                ("STK_LOCAL",                   os.path.join(HOME, ".local", "session-tracker")),
    "node":                    ("STK_NODE",                    ""),
    "canon_mode":              ("STK_CANON_MODE",              "local"),
    "canon_host":              ("STK_CANON_HOST",              ""),
    "canon_path":              ("STK_CANON_PATH",              ""),
    "canon_git":               ("STK_CANON_GIT",               "off"),
    "known_nodes":             ("STK_KNOWN_NODES",             ""),
    "remote_aliases":          ("STK_REMOTE_ALIASES",          ""),
    "pilot_commands":          ("STK_PILOT_COMMANDS",          ""),
    "naming_policy":           ("STK_NAMING_POLICY",           "warn"),
    "naming_map":              ("STK_NAMING_MAP",              ""),
    "hook_ask_intent":         ("STK_HOOK_ASK_INTENT",         "off"),
    "hook_placement":          ("STK_HOOK_PLACEMENT",          "off"),
    "hook_primary_check":      ("STK_HOOK_PRIMARY_CHECK",      "off"),
    "hook_tmux_tab":           ("STK_HOOK_TMUX_TAB",           "off"),
    "hook_extra_context_file": ("STK_HOOK_EXTRA_CONTEXT_FILE", ""),
}
LIST_KEYS = ("known_nodes", "remote_aliases", "pilot_commands")
# local paths: a leading ~/ is expanded (canon_path only when canon_mode is local, see load)
LOCAL_PATH_KEYS = ("data_dir", "naming_map", "hook_extra_context_file")
# paths that must be absolute (after the ~/ expansion); canon_path only in local mode
PATH_KEYS = ("data_dir", "canon_path", "naming_map", "hook_extra_context_file")


def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
    return os.path.join(base, "session-tracker", "config")


# the same explicit ASCII set bin/stk trims (never the locale's [:space:]: U+00A0 stays on every platform)
WS = " \t\r\n"


def read_file(path):
    """Parse a key=value file. Unknown keys are kept (the caller decides). Missing file -> {}.
    Bytes that are not UTF-8 are replaced, not fatal: bash reads the same file byte by byte."""
    out = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            ln = ln.strip(WS)
            if not ln or ln.startswith("#") or "=" not in ln:
                continue
            k, v = ln.split("=", 1)
            k, v = k.strip(WS), v.strip(WS)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k] = v
    return out


def split_list(value):
    return [t for t in (value or "").replace(",", " ").split() if t]


def declared(key, raw=None):
    """True when the key's value comes from the environment or the file, not from the default.
    `naming_map` declared but missing is a config error (the guard must not pass as if the map
    were simply absent); the default path missing just means the generic rules apply."""
    raw = read_file(config_path()) if raw is None else raw
    return bool(os.environ.get(KEYS[key][0]) or raw.get(key))


def path_errors(cfg):
    """One message per relative path in PATH_KEYS (same rule as `_paths_errors` in bin/stk)."""
    out = []
    for key in PATH_KEYS:
        v = cfg.get(key) or ""
        if key == "canon_path" and cfg.get("canon_mode") != "local":
            continue
        if v and not v.startswith("/"):
            out.append(f"{key}={v} relative: config paths are absolute or start with ~/")
    return out


def load(path=None):
    """Resolved configuration: every key of KEYS, env > file > default; lists as lists."""
    raw = read_file(path or config_path())
    cfg = {}
    for key, (env, default) in KEYS.items():
        # An empty environment variable counts as unset, as `${VAR:-}` does in bin/stk.
        cfg[key] = os.environ.get(env) or raw.get(key) or default
    def _tilde(v):
        return os.path.join(HOME, v[2:]) if v.startswith("~/") else v
    for key in LOCAL_PATH_KEYS:
        cfg[key] = _tilde(cfg[key])
    # the store default holds on-host only: with ssh the path is the host's and stays unset
    if cfg["canon_mode"] == "local":
        cfg["canon_path"] = _tilde(cfg["canon_path"]) or os.path.join(cfg["data_dir"], "store")
    # the map lands where `sync pull` copies it from the canon, next to the mirror
    cfg["naming_map"] = cfg["naming_map"] or os.path.join(cfg["data_dir"], "naming-map.yaml")
    for key in LIST_KEYS:
        cfg[key] = split_list(cfg[key])
    return cfg


FRONTMATTER_RE = r"(?m)^---[ \t]*$\n?"


def split_frontmatter(raw):
    """-> (frontmatter_text, body) of a record, or None when there is no frontmatter.
    The delimiter is a LINE of three dashes: a `---` inside a value (a name, a path, a note)
    is data. The index script in bin/stk and dashboard.py carry the same regex inline,
    because they run on the canon host where this module is not available."""
    import re
    parts = re.split(FRONTMATTER_RE, raw, maxsplit=2)
    if len(parts) < 3:
        return None
    return parts[1], parts[2]
