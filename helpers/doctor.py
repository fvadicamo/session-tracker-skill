#!/usr/bin/env python3
"""doctor.py — says what is configured and what is not, and where the config is broken.

Invoked by `stk doctor`. Reads the config with helpers/config.py (same contract as bin/stk) and
prints one line per check, `ok|warn|error  <topic>: <detail>`. Exit 1 if there is at least one
error, 0 otherwise: a warn stops nothing but says that something does not do what whoever wrote
it believed.

Checks:
  config          file read (or missing: the defaults apply); unknown keys or typos, which
                  bin/stk and config.py ignore silently (the typo leaves the default in force)
  values          canon_mode, canon_git, naming_policy, hook_* outside the domain; canon_mode=ssh
                  without canon_host or canon_path; pilot_commands with an invalid name
  path            relative data_dir, canon_path (local), naming_map, hook_extra_context_file
  naming_map      declared but missing (the guard must not pass as if the map were not
                  there); default missing (generic rules); malformed
  overlay         hook_extra_context_file declared but unreadable
  plugin          session-tracker installed as a Claude Code plugin and ACTIVE here. Source: `claude
                  plugin list --json` when `claude` is in PATH and the Claude home (CLAUDE_CONFIG_DIR)
                  is the one of --plugins-dir, because `enabled` there is already the merge of all
                  scopes (user, project, local, --settings, managed); otherwise the records of
                  installed_plugins.json in --plugins-dir with only the enabledPlugins of --settings
                  (user scope) and, for a project/local scope, the current folder under its
                  projectPath. The line says which source it used, and where this stk runs from
  hook            where `stk hook` comes from at session start: the active plugin (hooks/hooks.json)
                  or the SessionStart entries of settings.json (--settings); both = double injection,
                  neither (plugin disabled, nothing in settings) = no hook
  shim            what `command -v stk` finds: the shim of stk shim install (and what it
                  resolves), a symlink (does not follow updates), only the plugin's bin/ (which is
                  in PATH inside Claude and nowhere else: ssh and the terminal do not find it),
                  another program with the same name
  remotes         the hosts that -u and the primary-check reach: remote_aliases and known_nodes
                  (minus this node). Without --remote it lists them; with --remote it tries
                  `command -v stk` over ssh and reads line 2 of the file found: a session-tracker
                  bin/stk (exit 0), the shim (0 if it resolves an installation, 126 if not), another
                  program with the same name (125), nothing (127). ssh in BatchMode, 5 s to connect,
                  30 s per host overall
  tools           jq, rsync, git (ssh only if the config uses it)

CLI: doctor.py [--settings <settings.json>] [--plugins-dir <dir>] [--remote]
"""
import argparse, difflib, json, os, shutil, socket, subprocess, sys

HOME = os.path.expanduser("~")

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config as stkconfig  # noqa: E402
from naming import load_naming_map  # noqa: E402

ON_OFF = ("hook_ask_intent", "hook_placement", "hook_primary_check", "hook_tmux_tab")
DOMAIN = {"canon_mode": ("local", "ssh"), "canon_git": ("auto", "off"),
          "naming_policy": ("off", "warn", "error")}
TOKEN_RE = r"[A-Za-z0-9_.-]+"
# the node slug, as `stk init --node` checks it (bin/stk, LC_ALL=C): keep the two in step
NODE_RE = r"[a-z0-9][a-z0-9_.-]*"
PLUGIN_NAME = "session-tracker"
SHIM_MARKER = "# session-tracker shim"
OWN_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def plugin_installs(plugins_dir):
    """([(id, installPath, scope, projectPath)] of the session-tracker records, error): the list is
    empty also when the file is missing (no plugin installed), but a present and unreadable file is
    an error to report, not a "no record"."""
    path = os.path.join(plugins_dir, "installed_plugins.json")
    data = load_json(path)
    if data is None and os.path.exists(path):
        return [], f"{path} present but unreadable (invalid JSON)"
    recs = (data or {}).get("plugins") or {}
    out = []
    for pid, lst in recs.items():
        if pid.partition("@")[0] != PLUGIN_NAME:
            continue
        for rec in lst if isinstance(lst, list) else [lst]:
            rec = rec or {}
            out.append((pid, rec.get("installPath") or "", rec.get("scope") or "user", rec.get("projectPath") or ""))
    return out, ""


def under(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def plugin_list_via_claude(plugins_dir):
    """[(id, enabled, path)] from `claude plugin list --json`, or None when it cannot be used: `claude`
    missing, command failed, or the home that `claude` would read (CLAUDE_CONFIG_DIR or ~/.claude) is
    not the one of --plugins-dir (CLAUDE_DIR is the override of stk and `claude` itself does not see it)."""
    exe = shutil.which("claude")
    if not exe or not plugins_dir:
        return None
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
    if os.path.realpath(os.path.join(home, "plugins")) != os.path.realpath(plugins_dir):
        return None
    try:
        res = subprocess.run([exe, "plugin", "list", "--json"], capture_output=True, text=True, timeout=60,
                             stdin=subprocess.DEVNULL)
        data = json.loads(res.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if not isinstance(data, list):
        return None
    out = []
    for e in data:
        e = e or {}
        pid = e.get("id") or ""
        if pid.partition("@")[0] != PLUGIN_NAME:
            continue
        out.append((pid, bool(e.get("enabled")), e.get("readFromFolder") or e.get("installPath") or ""))
    return out


def second_line(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            fh.readline()
            return fh.readline()
    except OSError:
        return ""


def is_shim(path):
    return second_line(path).startswith(SHIM_MARKER)


def is_stk(path):
    """A session-tracker bin/stk (of any installation): line 2 is its header."""
    return second_line(path).startswith("# stk ")


class Report:
    def __init__(self):
        self.lines, self.errors = [], 0

    def ok(self, topic, msg):    self.lines.append(f"ok     {topic}: {msg}")
    def warn(self, topic, msg):  self.lines.append(f"warn   {topic}: {msg}")
    def error(self, topic, msg): self.lines.append(f"error  {topic}: {msg}"); self.errors += 1


def run(settings_path, plugins_dir="", remote=False):
    import re
    r = Report()
    cfg_path = stkconfig.config_path()
    raw = stkconfig.read_file(cfg_path)
    cfg = stkconfig.load(cfg_path)

    # -- file and keys -------------------------------------------------------------
    if os.path.isfile(cfg_path):
        r.ok("config", f"{cfg_path} ({len(raw)} keys)")
    else:
        r.ok("config", f"{cfg_path} missing: defaults apply (single-node, local store, no network)")
    for k in raw:
        if k in stkconfig.KEYS:
            continue
        near = difflib.get_close_matches(k, stkconfig.KEYS.keys(), n=1, cutoff=0.6)
        hint = f" (maybe `{near[0]}`? its default applies meanwhile)" if near else " (no similar key)"
        r.warn("config", f"unknown key `{k}` ignored{hint}")
    env_over = [stkconfig.KEYS[k][0] for k in stkconfig.KEYS if os.environ.get(stkconfig.KEYS[k][0])]
    if env_over:
        r.ok("config", "environment variables that override the file: " + ", ".join(env_over))

    # -- values ----------------------------------------------------------------------
    for key, dom in DOMAIN.items():
        v = cfg[key]
        if v in dom:
            r.ok(key, v)
        else:
            r.error(key, f"invalid value `{v}` ({'|'.join(dom)})")
    for key in ON_OFF:
        v = cfg[key]
        if v in ("on", "off"):
            r.ok(key, v)
        else:
            r.error(key, f"invalid value `{v}` (on|off): the hook treats it as off")
    if cfg["hook_tmux_tab"] == "on" and cfg["naming_policy"] == "off":
        r.warn("hook_tmux_tab", "on with naming_policy=off: the tmux window clause does not fire (the prefix comes from naming)")
    bad = [c for c in cfg["pilot_commands"] if not re.fullmatch(TOKEN_RE, c)]
    if bad:
        r.error("pilot_commands", "invalid name " + ", ".join(f"`{c}`" for c in bad) + f" (only {TOKEN_RE})")
    elif cfg["pilot_commands"]:
        r.ok("pilot_commands", ", ".join(cfg["pilot_commands"]) + " (scan reads the alias after -u|--user)")
    else:
        r.ok("pilot_commands", "empty: scan produces no pilot candidates")
    for key in ("known_nodes", "remote_aliases"):
        r.ok(key, ", ".join(cfg[key]) if cfg[key] else "empty")

    # -- path --------------------------------------------------------------------
    perrs = stkconfig.path_errors(cfg)
    # with a relative data_dir the paths derived from it (canon_path, naming_map defaults)
    # are relative too, but the user wrote only data_dir: report the root once, not three times.
    derived = {k for k in ("canon_path", "naming_map")
               if not (os.environ.get(stkconfig.KEYS[k][0]) or raw.get(k))}
    if any(e.startswith("data_dir=") for e in perrs):
        perrs = [e for e in perrs if e.split("=", 1)[0] not in derived]
    for e in perrs:
        r.error("path", e + " (sync/index/publish/dashboard, the shard writers and primary-check refuse it)")
    if not perrs:
        r.ok("path", "absolute")

    # -- node and data ---------------------------------------------------------------------
    node_file = os.path.join(cfg["data_dir"], "node")
    # the same lexicon as `stk init --node`: the slug is what the ownership blocks and
    # `stk where` compare, exact, and a display name never matches
    own_slug = cfg["node"] or (open(node_file).read().strip() if os.path.isfile(node_file) else "")
    if own_slug and not re.fullmatch(NODE_RE, own_slug):
        r.error("node", f"`{own_slug}` is not a slug (lowercase, [a-z0-9_.-]): stk init --node refuses it, "
                        "and an ownership block that names this node never matches")
    elif cfg["node"]:
        r.ok("node", f"{cfg['node']} (config or STK_NODE)")
    elif os.path.isfile(node_file):
        r.ok("node", f"{open(node_file).read().strip()} (file {node_file})")
    else:
        r.warn("node", f"neither config nor file {node_file}: the hostname `{socket.gethostname().split('.')[0].lower()}` applies, "
                       "which is often not the node slug")
    r.ok("data_dir", cfg["data_dir"] + ("" if os.path.isdir(cfg["data_dir"]) else " (not created yet: the first note or publish creates it)"))

    # -- canon ------------------------------------------------------------------------
    if cfg["canon_mode"] == "ssh":
        missing = [k for k in ("canon_host", "canon_path") if not cfg[k]]
        if missing:
            r.error("canon", "canon_mode=ssh requires " + " and ".join(missing) + " (the path is the one on the host)")
        else:
            r.ok("canon", f"ssh {cfg['canon_host']}:{cfg['canon_path']}")
    elif cfg["canon_mode"] == "local" and not perrs:
        store = cfg["canon_path"]
        if os.path.isdir(store):
            idx = os.path.join(store, "index.jsonl")
            r.ok("canon", f"local {store}" + ("" if os.path.isfile(idx) else " (no index.jsonl: the first publish or index creates it)"))
        else:
            r.ok("canon", f"local {store} (not created yet: the first sync or publish creates it)")

    # -- naming -----------------------------------------------------------------------
    nm_declared = stkconfig.declared("naming_map", raw)
    nm_path = cfg["naming_map"]
    if not os.path.exists(nm_path):
        if nm_declared and cfg["naming_policy"] != "off":
            r.error("naming_map", f"declared but missing ({nm_path}): with naming_policy={cfg['naming_policy']} "
                                  "the close guard does not run (exit 2) and the hook says so")
        elif nm_declared:
            r.warn("naming_map", f"declared but missing ({nm_path}); with naming_policy=off nobody reads it")
        else:
            r.ok("naming_map", f"default {nm_path} missing: only the rules of references/naming.md apply "
                               "(sync pull copies it from the canon if the canon has one)")
    else:
        nm = load_naming_map(nm_path)
        if nm["error"]:
            r.error("naming_map", nm["error"] + ": the close guard does not run")
        else:
            lay = nm.get("kb_layout") or {}
            layout = f"kb_layout {lay['root']}/{lay['orgs_dir']}, token {lay['token']}" if lay else "no kb_layout"
            r.ok("naming_map", f"{nm_path} ({len(nm['contexts'])} contexts, {len(nm['kb_orgs'])} kb_orgs, {len(nm['kb_tiers'])} kb_tiers, {layout})")

    # -- overlay -----------------------------------------------------------------------------
    extra = cfg["hook_extra_context_file"]
    if extra:
        if os.path.isfile(extra) and os.access(extra, os.R_OK):
            r.ok("hook_extra_context_file", extra)
        else:
            r.warn("hook_extra_context_file", f"{extra} unreadable: the hook injects the rest and logs it")
    else:
        r.ok("hook_extra_context_file", "empty (no overlay)")

    # -- plugin: installed and active? and where this stk runs from --------------------------------
    # active = record present, not `false` in enabledPlugins of the given settings.json, and for a
    # project/local scope with the current folder under its projectPath. A record of a disabled
    # plugin is still there (claude plugin disable leaves it), but its hook does not run.
    st = None
    if settings_path:
        try:
            with open(settings_path, encoding="utf-8") as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            st = None
    enabled_map = (st or {}).get("enabledPlugins") or {}
    installs, inactive, rec_err = [], [], ""
    listed = plugin_list_via_claude(plugins_dir)
    if listed is not None:
        source = "source: claude plugin list, all scopes"
        for pid, enabled, path in listed:
            if enabled:
                installs.append((pid, path))
            else:
                inactive.append(f"{pid} disabled (enabled=false in claude plugin list)")
    else:
        source = f"source: records in {plugins_dir} and enabledPlugins of the user settings.json only, the project and local scopes are not visible"
        records, rec_err = plugin_installs(plugins_dir) if plugins_dir else ([], "")
        for pid, path, scope, proj in records:
            if enabled_map.get(pid) is False:
                inactive.append(f"{pid} disabled in enabledPlugins ({settings_path})")
            elif scope in ("project", "local") and proj and not under(os.getcwd(), proj):
                inactive.append(f"{pid} scope {scope} of {proj}, not of this folder")
            else:
                installs.append((pid, path))
    if installs:
        r.ok("plugin", "; ".join(f"{pid} ({path or 'path not recorded'})" for pid, path in installs)
             + f" ({source}); this stk runs from {OWN_ROOT}")
    elif inactive:
        r.warn("plugin", "; ".join(inactive) + f": installed but not active here, its hook and its bin/ are not there; "
                                               f"this stk runs from {OWN_ROOT}")
    elif rec_err:
        r.warn("plugin", rec_err + ": I do not know whether the plugin is installed (Claude Code rebuilds it at the next start); "
                         f"this stk runs from {OWN_ROOT}")
    else:
        r.ok("plugin", f"no installation record in {plugins_dir or '(plugins dir not given)'}: "
                       f"this stk runs from {OWN_ROOT} (symlink, --plugin-dir or clone)")

    # -- hook: from the active plugin or from settings.json ------------------------------------------------
    if settings_path:
        try:
            if st is None:
                with open(settings_path, encoding="utf-8") as fh:
                    st = json.load(fh)
            cmds = [h.get("command", "") for grp in (st.get("hooks") or {}).get("SessionStart") or []
                    for h in (grp.get("hooks") or [])]
            n = sum(1 for c in cmds if "stk hook" in c)
            if installs and n:
                r.warn("hook", f"stk hook comes from the plugin (hooks/hooks.json) AND from settings.json ({n} in SessionStart of "
                               f"{settings_path}): double injection, remove the settings.json entry")
            elif installs:
                r.ok("hook", "stk hook comes from the plugin (hooks/hooks.json); no copy in settings.json")
            elif n == 1:
                r.ok("hook", f"stk hook registered in SessionStart ({settings_path})")
            elif n > 1:
                r.warn("hook", f"stk hook registered {n} times in SessionStart ({settings_path}): double injection")
            elif inactive:
                r.warn("hook", f"no hook: the plugin is not active here and stk hook is not among the SessionStart entries of {settings_path}")
            else:
                r.warn("hook", f"stk hook is not among the SessionStart entries of {settings_path} and the plugin does not appear installed: "
                               "no clause at session start (with --plugin-dir that is expected)")
        except FileNotFoundError:
            if installs:
                r.ok("hook", f"stk hook comes from the plugin (hooks/hooks.json); {settings_path} missing")
            else:
                r.warn("hook", f"{settings_path} missing: no hook registered")
        except (OSError, ValueError) as e:
            r.error("hook", f"{settings_path} unreadable: {e.__class__.__name__}")

    # -- shim: what `stk` finds in PATH --------------------------------------------------------
    own_bin = os.path.join(OWN_ROOT, "bin", "stk")
    found = shutil.which("stk")
    if not found:
        r.warn("shim", "stk is not in PATH: an ssh shell (-u, primary-check) and the terminal do not find it; stk shim install")
    elif os.path.realpath(found) == os.path.realpath(own_bin) and os.path.normpath(found) == own_bin:
        r.warn("shim", f"stk in PATH is the plugin's bin/ ({found}): it exists only inside Claude; "
                       "an ssh shell (-u, primary-check) and the terminal do not find it; stk shim install")
    elif is_shim(found):
        try:
            res = subprocess.run(["bash", found, "--stk-shim-resolve"], capture_output=True, text=True, timeout=20)
            target = res.stdout.strip() if res.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            target = ""
        if not target:
            r.warn("shim", f"shim {found} resolves no installation: outside Claude 'stk' fails "
                           f"(no record in {plugins_dir or 'plugins dir'}, no STK_PLUGIN_ROOT, no other stk in PATH)")
        elif os.path.realpath(target) == os.path.realpath(own_bin):
            r.ok("shim", f"{found} -> {target} (this installation)")
        else:
            r.warn("shim", f"shim {found} resolves {target}, but this stk runs from {own_bin}: two installations; "
                           "outside Claude the first one wins")
    elif os.path.realpath(found) == os.path.realpath(own_bin):
        r.warn("shim", f"{found} is a symlink or a copy of this installation: it does not follow the plugin updates; "
                       "stk shim install replaces it")
    elif is_stk(os.path.realpath(found)):
        r.warn("shim", f"{found} is a symlink or a copy of another session-tracker installation "
                       f"({os.path.realpath(found)}), not of this one ({own_bin}): outside Claude that one runs; "
                       "stk shim install replaces it with the shim")
    else:
        r.warn("shim", f"`stk` in PATH is another program ({found}), not session-tracker: an ssh shell and the "
                       "terminal run that one; rename it or put the shim earlier in PATH")

    # -- remotes: the targets of -u (remote_aliases) and of the primary-check (-u <slug> with the slugs of
    # known_nodes); canon_host is not there: on the canon's host run rsync, flock, uv and git, not stk --------------
    own_node = cfg["node"] or (open(node_file).read().strip() if os.path.isfile(node_file) else "")
    hosts = []
    for h in list(cfg["remote_aliases"]) + list(cfg["known_nodes"]):
        if h and h != own_node and h not in hosts:
            hosts.append(h)
    # `command -v` also finds a shim that resolves nothing or another program with the same name:
    # line 2 of the file found says what it is (sed follows a symlink), and a shim is queried
    # with --stk-shim-resolve. Exit: 0 bin/stk or a shim that resolves, 126 a shim that does not resolve,
    # 125 another program, 127 nothing. POSIX sh syntax, the remote shell may be dash or zsh.
    probe = ('p=$(command -v stk) || exit 127; l=$(sed -n 2p "$p" 2>/dev/null); case "$l" in '
             '"# session-tracker shim"*) t=$(stk --stk-shim-resolve 2>/dev/null) || { echo "$p"; exit 126; }; echo "$p -> $t";; '
             '"# stk "*) echo "$p";; *) echo "$p"; exit 125;; esac')
    if remote and hosts:
        for h in hosts:
            try:
                res = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", h, probe],
                                     capture_output=True, text=True, timeout=30)
            except (OSError, subprocess.SubprocessError) as e:
                r.warn("remotes", f"{h}: ssh cannot run ({e.__class__.__name__})")
                continue
            out = res.stdout.strip()
            if res.returncode == 0 and out:
                r.ok("remotes", f"{h}: stk in {out}")
            elif res.returncode == 126:
                r.warn("remotes", f"{h}: stk is there ({out}) but it is a shim that resolves no installation (exit 126): "
                                 "install the plugin there and retry")
            elif res.returncode == 125:
                r.warn("remotes", f"{h}: `stk` in the ssh shell PATH is another program ({out}), not session-tracker: "
                                 "-u and primary-check would run that one")
            elif res.returncode == 255:
                r.warn("remotes", f"{h}: ssh cannot reach the host (exit 255): {res.stderr.strip()[:120]}")
            else:
                r.warn("remotes", f"{h}: stk is not in the ssh shell PATH (exit {res.returncode}): -u and primary-check "
                                 "towards this node fail; stk shim install there, and its folder in the PATH of the "
                                 "NON-interactive ssh shell (on macOS ~/.local/bin is often missing)")
    elif remote:
        r.ok("remotes", "no alias in remote_aliases nor slug in known_nodes besides this node: nothing to check")
    elif hosts:
        r.ok("remotes", f"{len(hosts)} hosts ({', '.join(hosts)}): stk doctor --remote checks that stk is there and starts in their ssh PATH")

    # -- tools --------------------------------------------------------------------------------
    tools = ["jq", "rsync", "git"]
    if cfg["canon_mode"] == "ssh" or cfg["remote_aliases"]:
        tools.append("ssh")
    missing = [t for t in tools if not shutil.which(t)]
    if missing:
        r.error("tools", "missing: " + ", ".join(missing))
    else:
        r.ok("tools", ", ".join(tools))
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--settings", default="", help="Claude Code settings.json in which to look for the hook")
    ap.add_argument("--plugins-dir", default="", help="folder of the Claude Code plugin records (installed_plugins.json)")
    ap.add_argument("--remote", action="store_true", help="try `command -v stk` over ssh on the configured aliases")
    a = ap.parse_args()
    r = run(a.settings, a.plugins_dir, a.remote)
    print("\n".join(r.lines))
    print(f"doctor: {r.errors} error" if r.errors else "doctor: no error")
    sys.exit(1 if r.errors else 0)


if __name__ == "__main__":
    main()
