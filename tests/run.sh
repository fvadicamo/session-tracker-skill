#!/usr/bin/env bash
# session-tracker — deterministic test suite (black-box, hermetic).
# Exercises `stk` + helpers against synthetic fixtures in temporary dirs; does NOT touch
# the real canon nor ~/.claude. Covers the deterministic logic (scan/merge/
# close/index); the LLM derivation of the name at close is NOT here (judgement, not code).
#
# Usage: bash tests/run.sh
# Deps:  bash, jq, python3, uv (downloads pyyaml in an ephemeral env). Exit != 0 on failure.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)   # physical paths: macOS puts the temp root and /tmp behind symlinks, and doctor reports realpaths
STK="$HERE/../bin/stk"
H="$HERE/../helpers"
[ -x "$STK" ] || { echo "stk not found/executable: $STK"; exit 2; }

T=$(cd "$(mktemp -d)" && pwd -P)
# the config block of bin/stk, extracted once to a FILE for the bash/python parity checks:
# bash 3.2 (the one macOS ships) cannot `source` a process substitution, it reads nothing
CFGBLOCK="$T/cfgblock.sh"; sed -n "/^# ---- config/,/^SHARD=/p" "$STK" > "$CFGBLOCK"
trap 'rm -rf "$T"' EXIT
export STK_LOCAL="$T/local" STK_NODE=testnode STK_CANON_PATH="$T/canon" CLAUDE_DIR="$T/claude"
# node config: the suite does not read the host's (XDG in the empty temporary dir) and
# starts without inherited STK_* beyond the ones above. Section AA proves it with its own file.
export XDG_CONFIG_HOME="$T/xdg"
unset STK_CANON_MODE STK_CANON_HOST STK_KNOWN_NODES STK_REMOTE_ALIASES
# sections E, F and V measure the commit and push of publish: it is the behaviour with canon_git=auto
# (a node whose canon lives in a git repository); the product default is off, proved in AA.
export STK_CANON_GIT=auto
# sections J, W, X, Y, Z measure the hook with all the clauses and the guard that refuses: it is the
# behaviour with hook_*=on and naming_policy=error (a node with every clause on); the product defaults
# (clauses off, naming warn) are proved in AB.
export STK_HOOK_ASK_INTENT=on STK_HOOK_PLACEMENT=on STK_HOOK_PRIMARY_CHECK=on STK_HOOK_TMUX_TAB=on STK_NAMING_POLICY=error
unset STK_NAMING_MAP STK_HOOK_EXTRA_CONTEXT_FILE
# section AD reads the plugin records from $CLAUDE_DIR/plugins: the Claude Code variables that
# would move that folder, and the shim's pin, must not come from the host's environment
unset CLAUDE_CONFIG_DIR CLAUDE_CODE_PLUGIN_CACHE_DIR STK_PLUGIN_ROOT
mkdir -p "$STK_LOCAL" "$STK_CANON_PATH" "$CLAUDE_DIR/projects" "$XDG_CONFIG_HOME"

P=0; F=0; K=0
ok(){ printf '  PASS  %s\n' "$1"; P=$((P+1)); }
ko(){ printf '  FAIL  %s\n' "$1"; F=$((F+1)); }
# a check that cannot run here is declared: SKIP is not PASS, and the total counts it separately
skip(){ printf '  SKIP  %s\n' "$1"; K=$((K+1)); }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (got='$2' want='$3')"; fi; }

PY='uv run --with pyyaml --python 3.12 -q python'
fmget(){ $PY -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]).read().split('---')[1]);print(d.get(sys.argv[2],''))" "$1" "$2"; }
fmhas(){ $PY -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]).read().split('---')[1]);sys.exit(0 if sys.argv[3] in (d.get(sys.argv[2]) or []) else 1)" "$1" "$2" "$3"; }
fmget_forked(){ $PY -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]).read().split('---')[1]);f=d.get('forked_from') or {};print(f.get('session_id',''))" "$1"; }

echo "== A: scan captures custom_title (custom-title > ai-title > null) =="
EPA="-pa"; mkdir -p "$CLAUDE_DIR/projects/$EPA"
SA=aaaaaaaa-0000-0000-0000-000000000001
cat > "$CLAUDE_DIR/projects/$EPA/$SA.jsonl" <<EOF
{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/pa","gitBranch":"main","uuid":"u1"}
{"type":"ai-title","aiTitle":"Auto A","sessionId":"$SA"}
{"type":"custom-title","customTitle":"my-rename-a","sessionId":"$SA"}
EOF
SB=bbbbbbbb-0000-0000-0000-000000000002
cat > "$CLAUDE_DIR/projects/$EPA/$SB.jsonl" <<EOF
{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/pa","uuid":"u1"}
{"type":"ai-title","aiTitle":"Auto B","sessionId":"$SB"}
EOF
SC=cccccccc-0000-0000-0000-000000000003
cat > "$CLAUDE_DIR/projects/$EPA/$SC.jsonl" <<EOF
{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/pa","uuid":"u1"}
EOF
OUT=$(bash "$STK" scan --all 2>/dev/null)
eq "custom-title wins over ai-title" "$(echo "$OUT" | jq -r --arg s "$SA" 'select(.session_id==$s).custom_title')" "my-rename-a"
eq "fallback ai-title"             "$(echo "$OUT" | jq -r --arg s "$SB" 'select(.session_id==$s).custom_title')" "Auto B"
eq "null if no title"         "$(echo "$OUT" | jq -r --arg s "$SC" 'select(.session_id==$s).custom_title')" "null"

echo "== B: merge auto-name + preservation of the user override across passes =="
EP="-test-proj"; SID=11111111-0000-0000-0000-000000000001
MD="$STK_LOCAL/shard/$EP/$SID.md"
mkmanifest(){ cat > "$STK_LOCAL/manifest.jsonl" <<EOF
{"session_id":"$SID","encoded_project":"$EP","project":"proj","project_path":"/p","git_branch":"main","started_at":"2026-06-07T08:00:00Z","last_activity_at":"2026-06-07T09:00:00Z","last_uuid":"u1","n_events":5,"forked_from":null,"pilot_candidates":[],"custom_title":"$1"}
EOF
}
mkdigest(){ cat > "$T/dg.jsonl" <<EOF
{"session_id":"$SID","lang":"it","goal":"g","summary":"$1","done":[],"open":["x"],"decisions":[],"internal_branches":[],"pilot_candidates":[],"proposed_status":"active","tags":["$2"]}
EOF
}
mkmanifest "auto-name-1"; mkdigest "s1" "t-auto"
$PY "$H/merge.py" "$T/dg.jsonl" >/dev/null 2>&1
eq "merge: auto name from custom_title" "$(fmget "$MD" name)" "auto-name-1"
eq "merge: name_source auto"          "$(fmget "$MD" name_source)" "auto"
eq "merge: class default task"        "$(fmget "$MD" class)" "task"

$PY "$H/close.py" "$MD" --status done --session "$SID" --node testnode --project-path /p \
    --name "user-canonical" --class distill --distill-target bot-skill --add-tag t-user >/dev/null 2>&1
eq "close: name_source user" "$(fmget "$MD" name_source)" "user"
printf -- '- 2026-06-07 (future): remember-X  <!-- nid:tnote1 -->\n' >> "$MD"

mkmanifest "HARNESS-CHANGED"; mkdigest "s2" "t-new"
$PY "$H/merge.py" "$T/dg.jsonl" >/dev/null 2>&1
eq "re-merge: name preserved"          "$(fmget "$MD" name)" "user-canonical"
eq "re-merge: name_source user"         "$(fmget "$MD" name_source)" "user"
eq "re-merge: class preserved"         "$(fmget "$MD" class)" "distill"
eq "re-merge: distill_target preserved" "$(fmget "$MD" distill_target)" "bot-skill"
eq "re-merge: status preserved"        "$(fmget "$MD" status)" "done"
eq "re-merge: status_source user"       "$(fmget "$MD" status_source)" "user"
if fmhas "$MD" tags t-user; then ok "re-merge: user tag preserved"; else ko "re-merge: user tag lost"; fi
if fmhas "$MD" tags t-new;  then ok "re-merge: digest tag merged";     else ko "re-merge: digest tag lost"; fi
if grep -q 'nid:tnote1' "$MD"; then ok "re-merge: user_notes preserved"; else ko "re-merge: user_notes lost"; fi

echo "== C: stk close (dispatcher) created-branch + edge =="
SIDC=22222222-0000-0000-0000-000000000002
bash "$STK" close --session "$SIDC" --status done --name "demo-dev-setup-sk-distill-2026-06-07" --class distill --distill-target bot-skill >/dev/null 2>&1
MDC="$STK_LOCAL/shard/_unindexed/$SIDC.md"
if [ -f "$MDC" ]; then ok "close: created branch creates the record"; else ko "close: record not created"; fi
eq "close: user name"   "$(fmget "$MDC" name)" "demo-dev-setup-sk-distill-2026-06-07"
eq "close: class distill"  "$(fmget "$MDC" class)" "distill"
SIDD=33333333-0000-0000-0000-000000000003
# --force: the name is outside the lexicon on purpose (it proves the yaml-safety of close.py, not the guard: see N)
STK_NAMING_POLICY=off bash "$STK" close --session "$SIDD" --status done --name 'weird: name: colon #2' --class task --force >/dev/null 2>&1   # off: the lexicon invariant would refuse it, and the point here is the yaml
eq "close: name with special characters is yaml-safe" "$(fmget "$STK_LOCAL/shard/_unindexed/$SIDD.md" name)" "weird: name: colon #2"
if bash "$STK" close --session zzz --status done --class bogus >/dev/null 2>&1; then ko "close: --class bogus accepted"; else ok "close: --class bogus rejected"; fi

echo "== D: stk index projects name/class/distill_target =="
EPD="-idx-proj"; mkdir -p "$STK_CANON_PATH/testnode/$EPD"; cp "$MD" "$STK_CANON_PATH/testnode/$EPD/$SID.md"
bash "$STK" index >/dev/null 2>&1
if $PY -c "import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];r=r[0] if r else {};sys.exit(0 if ('name' in r and 'class' in r) else 1)" "$STK_CANON_PATH/index.jsonl"; then ok "index: name+class present"; else ko "index: fields missing"; fi
eq "index: name correct" "$($PY -c "import json,sys;print([json.loads(l) for l in open(sys.argv[1])][0].get('name',''))" "$STK_CANON_PATH/index.jsonl")" "user-canonical"

echo "== E: stk publish (batch commit of the canon, idempotent) =="
GR="$STK_CANON_PATH"   # in this harness the git repo coincides with the canon
git -C "$GR" init -q
git -C "$GR" config user.email t@t; git -C "$GR" config user.name t
# --no-push here: sections E/F test commit/index/lock, not the push (see V for the default push)
bash "$STK" publish --no-push >/dev/null 2>&1
N1=$(git -C "$GR" rev-list --count HEAD 2>/dev/null || echo 0)
if [ "${N1:-0}" -ge 1 ]; then ok "publish: creates a commit when the subtree changes"; else ko "publish: no commit created"; fi
bash "$STK" publish --no-push >/dev/null 2>&1
N2=$(git -C "$GR" rev-list --count HEAD 2>/dev/null || echo 0)
eq "publish: no-op when the subtree is clean" "$N2" "$N1"
GR2="$T/nogit"; mkdir -p "$GR2"
if STK_CANON_PATH="$GR2" bash "$STK" publish --no-push >/dev/null 2>&1; then ok "publish: non-git repo -> commit skipped without error"; else ko "publish: non-git repo -> error"; fi
echo "== F: stk publish concurrent and serialized (flock) =="
if command -v flock >/dev/null 2>&1; then
    printf -- '- 2026-06-07 (future): conc-test  <!-- nid:cc1 -->\n' >> "$MD"
    bash "$STK" publish --no-push >"$T/F1.out" 2>&1 & pF1=$!
    bash "$STK" publish --no-push >"$T/F2.out" 2>&1 & pF2=$!
    wait $pF1; rF1=$?; wait $pF2; rF2=$?
    if [ "$rF1" = 0 ] && [ "$rF2" = 0 ]; then ok "concurrent publish: both rc=0 (no git index.lock collision)"; else ko "concurrent publish: rc=($rF1,$rF2)"; fi
    if $PY -c "import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()]" "$STK_CANON_PATH/index.jsonl" 2>/dev/null; then ok "concurrent publish: index.jsonl intact"; else ko "concurrent publish: index.jsonl corrupted"; fi
    if git -C "$GR" ls-files --error-unmatch .stk.lock >/dev/null 2>&1; then ko "publish: .stk.lock tracked"; else ok "publish: .stk.lock not tracked (gitignored)"; fi
else
    echo "  SKIP  flock not available on this OS (serialization not testable)"
fi

echo '== G: sync pull mirrors the global canon into $STK_LOCAL/canon =='
bash "$STK" sync pull >/dev/null 2>&1
if [ -f "$STK_LOCAL/canon/index.jsonl" ]; then ok "pull: global index.jsonl in canon/"; else ko "pull: canon/index.jsonl missing"; fi
if ls "$STK_LOCAL/canon/testnode/"*/*.md >/dev/null 2>&1; then ok "pull: node records mirrored in canon/"; else ko "pull: records not in canon/"; fi
if $PY "$H/dashboard.py" "$STK_LOCAL/canon" >/dev/null 2>&1; then ok "pull: dashboard.py runs on canon/"; else ko "pull: dashboard.py fails on canon/"; fi

echo "== H: stk dashboard (live view on the canon) =="
OUT=$(bash "$STK" dashboard 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q "OPEN:"; then ok "dashboard: runs on the canon and produces the open-items view"; else ko "dashboard: rc=$rc unexpected output"; fi
if printf '%s' "$OUT" | grep -q $'\033'; then ko "dashboard: ANSI in capture (non-tty)"; else ok "dashboard: no ANSI in capture (non-tty)"; fi
OUTHC=$(FORCE_COLOR=1 bash "$STK" dashboard 2>&1)
if printf '%s' "$OUTHC" | grep -q $'\033'; then ok "dashboard: FORCE_COLOR propagated (stk -> dashboard.py)"; else ko "dashboard: FORCE_COLOR not propagated"; fi

echo "== I: stk branch (trunk checkpoint + child register) =="
SIDP=44444444-0000-0000-0000-000000000004
bash "$STK" branch --session "$SIDP" --name "trunk-name" --child "child-name" --add-tag t-branch >/dev/null 2>&1
MDP="$STK_LOCAL/shard/_unindexed/$SIDP.md"
if [ -f "$MDP" ]; then ok "branch: checkpoint creates the trunk record"; else ko "branch: trunk record not created"; fi
eq "branch: trunk status branched"    "$(fmget "$MDP" status)" "branched"
eq "branch: trunk status_source user" "$(fmget "$MDP" status_source)" "user"
eq "branch: trunk name_source user"   "$(fmget "$MDP" name_source)" "user"
eq "branch: trunk name"               "$(fmget "$MDP" name)" "trunk-name"
if fmhas "$MDP" tags t-branch; then ok "branch: tag on the trunk"; else ko "branch: tag missing"; fi
if jq -e --arg s "$SIDP" 'select(.session_id==$s and .event=="status_change" and .to=="branched")' "$STK_LOCAL/shard/events.jsonl" >/dev/null 2>&1; then ok "branch: status_change -> branched in events"; else ko "branch: status_change missing"; fi

EPF="-fork-proj"; mkdir -p "$CLAUDE_DIR/projects/$EPF"
SIDF=55555555-0000-0000-0000-000000000005
PARENT44=44444444-0000-0000-0000-000000000004
cat > "$CLAUDE_DIR/projects/$EPF/$SIDF.jsonl" <<EOF
{"type":"user","timestamp":"2026-06-11T08:00:00Z","cwd":"/pf","forkedFrom":{"sessionId":"$PARENT44","messageUuid":"m1"}}
{"type":"custom-title","customTitle":"child-name","sessionId":"$SIDF"}
EOF
bash "$STK" branch --register --session "$SIDF" >/dev/null 2>&1
MDF="$STK_LOCAL/shard/$EPF/$SIDF.md"
if [ -f "$MDF" ]; then ok "branch --register: creates the child stub"; else ko "branch --register: stub not created"; fi
eq "branch --register: forked_from session_id" "$(fmget_forked "$MDF")" "$PARENT44"
eq "branch --register: name from the custom-title"  "$(fmget "$MDF" name)" "child-name"
eq "branch --register: status auto (active)"   "$(fmget "$MDF" status)" "active"
eq "branch --register: status_source auto"     "$(fmget "$MDF" status_source)" "auto"

printf -- '- 2026-06-11 (intent): goal-x  <!-- nid:fnote1 -->\n' >> "$MDF"
bash "$STK" branch --register --session "$SIDF" >/dev/null 2>&1
if grep -q 'nid:fnote1' "$MDF"; then ok "branch --register: idempotent, user_notes preserved"; else ko "branch --register: user_notes lost"; fi
eq "branch --register: forked_from stable"    "$(fmget_forked "$MDF")" "$PARENT44"

SIDN=66666666-0000-0000-0000-000000000006
cat > "$CLAUDE_DIR/projects/$EPF/$SIDN.jsonl" <<EOF
{"type":"user","timestamp":"2026-06-11T08:00:00Z","cwd":"/pf","uuid":"u1"}
EOF
bash "$STK" branch --register --session "$SIDN" >/dev/null 2>&1
if [ -f "$STK_LOCAL/shard/$EPF/$SIDN.md" ]; then ko "branch --register: wrote a stub for a non-branch"; else ok "branch --register: no-op if no forkedFrom"; fi

SIDB=77777777-0000-0000-0000-000000000007
if bash "$STK" close --session "$SIDB" --status branched >/dev/null 2>&1; then ok "close: --status branched accepted"; else ko "close: --status branched rejected"; fi

echo "== J: stk hook (injection at startup/resume/clear, /rename on every fresh one, branch clause only at resume/clear) =="
HSID=88888888-0000-0000-0000-000000000008
OUTH=$(printf '{"session_id":"%s","source":"startup"}' "$HSID" | bash "$STK" hook 2>/dev/null)
if printf '%s' "$OUTH" | jq -e '.hookSpecificOutput.additionalContext | test("stk note")' >/dev/null 2>&1; then ok "hook startup: injects the intent request"; else ko "hook startup: no intent injection"; fi
if printf '%s' "$OUTH" | jq -e '.hookSpecificOutput.additionalContext | test("stk branch --register")' >/dev/null 2>&1; then ko "hook startup: branch clause present (it must not be)"; else ok "hook startup: no branch clause"; fi
if printf '%s' "$OUTH" | jq -e '.hookSpecificOutput.additionalContext | test("/rename")' >/dev/null 2>&1; then ok "hook startup: proposes /rename (canonical name)"; else ko "hook startup: /rename clause missing"; fi
if printf '%s' "$OUTH" | jq -e '.hookSpecificOutput.additionalContext | test("stk where")' >/dev/null 2>&1; then ok "hook startup: placement clause (stk where)"; else ko "hook startup: placement clause missing"; fi

HSID2=aaaaaaaa-9999-9999-9999-000000000009
OUTH=$(printf '{"session_id":"%s","source":"resume"}' "$HSID2" | bash "$STK" hook 2>/dev/null)
if printf '%s' "$OUTH" | jq -e '.hookSpecificOutput.additionalContext | test("stk branch --register")' >/dev/null 2>&1; then ok "hook resume: branch clause present"; else ko "hook resume: branch clause missing"; fi
if printf '%s' "$OUTH" | jq -e '.hookSpecificOutput.additionalContext | test("/rename")' >/dev/null 2>&1; then ok "hook resume: rename clause present"; else ko "hook resume: rename clause missing"; fi

OUTH=$(printf '{"session_id":"%s","source":"compact"}' "$HSID2" | bash "$STK" hook 2>/dev/null)
eq "hook compact: no injection" "$OUTH" ""

bash "$STK" note --session "$HSID2" --kind intent "already-recorded" >/dev/null 2>&1
OUTH=$(printf '{"session_id":"%s","source":"startup"}' "$HSID2" | bash "$STK" hook 2>/dev/null)
eq "hook: skip if intent already present (startup)" "$OUTH" ""
OUTH=$(printf '{"session_id":"%s","source":"resume"}' "$HSID2" | bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if [[ "$OUTH" == *"stk branch --register --current"* && "$OUTH" != *"stk note"* ]]; then ok "hook: with an intent, resume injects the branch clause alone"; else ko "hook: resume with intent: [$OUTH]"; fi

echo "== K: sync pull does not clobber more recent local changes (rsync -au) =="
EPK="-pullprot"; SIDK=cafe0000-0000-0000-0000-000000000010
mkdir -p "$STK_CANON_PATH/testnode/$EPK" "$STK_LOCAL/shard/$EPK"
# canon: old version (no forked_from), old mtime
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: unknown\nstatus_source: auto\n---\n## extracted\n\n## user_notes\n' "$SIDK" > "$STK_CANON_PATH/testnode/$EPK/$SIDK.md"
touch -t 202601010000 "$STK_CANON_PATH/testnode/$EPK/$SIDK.md"
# local: UNpublished change (forked_from), more recent mtime
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: unknown\nstatus_source: auto\nforked_from: {node: testnode, session_id: parentsid}\n---\n## extracted\n\n## user_notes\n' "$SIDK" > "$STK_LOCAL/shard/$EPK/$SIDK.md"
touch -t 202612310000 "$STK_LOCAL/shard/$EPK/$SIDK.md"
bash "$STK" sync pull >/dev/null 2>&1
if grep -q 'forked_from' "$STK_LOCAL/shard/$EPK/$SIDK.md"; then ok "sync pull: more recent local change preserved (rsync -au)"; else ko "sync pull: local change clobbered"; fi
# counter-proof: a MORE RECENT canon is still pulled
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: done\nstatus_source: user\n---\n## extracted\n\n## user_notes\n' "$SIDK" > "$STK_CANON_PATH/testnode/$EPK/$SIDK.md"
touch -t 202601010000 "$STK_LOCAL/shard/$EPK/$SIDK.md"          # old local
touch -t 202606010000 "$STK_CANON_PATH/testnode/$EPK/$SIDK.md"  # more recent canon
bash "$STK" sync pull >/dev/null 2>&1
if grep -q 'status: done' "$STK_LOCAL/shard/$EPK/$SIDK.md"; then ok "sync pull: more recent canon is still pulled"; else ko "sync pull: more recent canon not pulled"; fi

echo "== L: stk where (deterministic placement: ownership > prose > cluster) =="
WNM="$T/wnm.yaml"; cat > "$WNM" <<'YML'
schema: v0
contexts:
  acme-site: acme
  infra: real-target
YML
WIDX="$T/widx.jsonl"; cat > "$WIDX" <<'JSONL'
{"session_id":"w-mer-1","node":"alpha","project_path":"/home/u/code/acme-site","name":"acme-deploy-setup","name_source":"user","class":"task","status":"active","tags":["acme"],"last_activity_at":"2026-06-20T10:00:00Z","dormancy_risk":"low"}
JSONL
W(){ bash "$STK" where --index "$WIDX" --naming-map "$WNM" "$@"; }
# L1: cluster home on another node -> elsewhere + relocate-node
J=$(W --node bravo --cwd /Users/x/acme-site)
eq "where L1: verdict elsewhere (cluster)" "$(echo "$J"|jq -r .verdict)" "elsewhere"
eq "where L1: kind relocate-node"          "$(echo "$J"|jq -r '.candidates[0].kind')" "relocate-node"
eq "where L1: home node alpha"             "$(echo "$J"|jq -r '.candidates[0].node')" "alpha"
# L2: structured ownership block, wrong node -> high + secondary-here
mkdir -p "$T/wb/sub"; cat > "$T/wb/CLAUDE.md" <<'MD'
## Node ownership
- Primary: alpha (`/home/u/code/x`)
- Secondaries: bravo (`/Users/x/x`)
MD
J=$(W --node bravo --cwd "$T/wb/sub")
eq "where L2: verdict elsewhere (block)"   "$(echo "$J"|jq -r .verdict)" "elsewhere"
eq "where L2: confidence high"             "$(echo "$J"|jq -r '.candidates[0].confidence')" "high"
eq "where L2: ownership source block"      "$(echo "$J"|jq -r '.current.ownership.source')" "block"
eq "where L2: secondary-here true"         "$(echo "$J"|jq -r '.current.ownership.is_secondary_here')" "true"
# L3: same primary node, wrong folder -> relocate-folder
J=$(W --node alpha --cwd "$T/wb/sub")
eq "where L3: verdict elsewhere (folder)"  "$(echo "$J"|jq -r .verdict)" "elsewhere"
eq "where L3: kind relocate-folder"        "$(echo "$J"|jq -r '.candidates[0].kind')" "relocate-folder"
# L4: ambiguous subject (real-target) + no home -> unknown
J=$(W --node bravo --cwd /Users/x/code/infra)
eq "where L4: verdict unknown"             "$(echo "$J"|jq -r .verdict)" "unknown"
# L5: at home (home==current) with a live trunk in the cluster -> here + branch-from-trunk
J=$(W --node alpha --cwd /home/u/code/acme-site)
eq "where L5: verdict here"                "$(echo "$J"|jq -r .verdict)" "here"
eq "where L5: offers branch-from-trunk"     "$(echo "$J"|jq -r '.candidates[0].kind')" "branch-from-trunk"
eq "where L5: trunk sid correct"          "$(echo "$J"|jq -r '.candidates[0].trunk.session_id')" "w-mer-1"
# L6: child (forked_from) at home -> here, NEVER branch-from-trunk towards its own lineage
J=$(W --node alpha --cwd /home/u/code/acme-site --forked-from w-mer-1)
eq "where L6: child verdict here"          "$(echo "$J"|jq -r .verdict)" "here"
eq "where L6: child no branch-from-trunk" "$(echo "$J"|jq '[.candidates[]|select(.kind=="branch-from-trunk")]|length')" "0"
# L7: dispatcher rejects an unknown flag
if W --node x --cwd /y --bogus >/dev/null 2>&1; then ko "where L7: bogus flag accepted"; else ok "where L7: bogus flag rejected"; fi
# L8: declared primary that is not a known node (display name with a typo, zero for
# o, in place of the slug) -> not verifiable: confidence low, no read-only bump
mkdir -p "$T/wbx"
printf '## Node ownership\n- Primary: BRAV0 (`%s`)\n- Secondaries: alpha (`/home/u/x`)\n' "$T/wbx" > "$T/wbx/CLAUDE.md"
J=$(W --node bravo --cwd "$T/wbx")
eq "where L8: primary_known false"         "$(echo "$J"|jq -r '.current.ownership.primary_known')" "false"
eq "where L8: confidence low"              "$(echo "$J"|jq -r '.candidates[0].confidence')" "low"
eq "where L8: score 40 (no bump)"      "$(echo "$J"|jq -r '.candidates[0].score')" "40"
# counter-proof: same block with the correct slug -> known primary and you are at home
printf '## Node ownership\n- Primary: bravo (`%s`)\n- Secondaries: alpha (`/home/u/x`)\n' "$T/wbx" > "$T/wbx/CLAUDE.md"
J=$(W --node bravo --cwd "$T/wbx")
eq "where L8: correct slug -> known primary" "$(echo "$J"|jq -r '.current.ownership.primary_known')" "true"
eq "where L8: correct slug -> verdict here" "$(echo "$J"|jq -r .verdict)" "here"

echo "== M: stk close batch (several --session; per-session fields rejected) =="
SIDM1=88880000-0000-0000-0000-00000000000a
SIDM2=88880000-0000-0000-0000-00000000000b
bash "$STK" close --session "$SIDM1" --session "$SIDM2" --status dropped --add-tag batch-t --rationale "cleanup" >/dev/null 2>&1
MDM1="$STK_LOCAL/shard/_unindexed/$SIDM1.md"; MDM2="$STK_LOCAL/shard/_unindexed/$SIDM2.md"
eq "batch close: sid1 dropped" "$(fmget "$MDM1" status)" "dropped"
eq "batch close: sid2 dropped" "$(fmget "$MDM2" status)" "dropped"
if fmhas "$MDM1" tags batch-t && fmhas "$MDM2" tags batch-t; then ok "batch close: tag on both"; else ko "batch close: tag missing"; fi
NSC=$(jq -r 'select(.event=="status_change" and (.session_id=="'"$SIDM1"'" or .session_id=="'"$SIDM2"'") and .to=="dropped")|.session_id' "$STK_LOCAL/shard/events.jsonl" | sort -u | wc -l | tr -d ' ')
eq "batch close: two distinct status_change" "$NSC" "2"
if bash "$STK" close --session "$SIDM1" --session "$SIDM2" --status done --name x >/dev/null 2>&1; then ko "batch close: --name with batch accepted"; else ok "batch close: --name with batch rejected"; fi
if bash "$STK" close --session "$SIDM1" --session "$SIDM2" --status done --summary y >/dev/null 2>&1; then ko "batch close: --summary with batch accepted"; else ok "batch close: --summary with batch rejected"; fi

echo "== N: stk hygiene (empty stubs: dry-run vs --apply, full record preserved) =="
EPN="-hyg"; mkdir -p "$STK_LOCAL/shard/$EPN"
SIDNE=99990000-0000-0000-0000-00000000000e   # empty stub -> to remove
SIDNF=99990000-0000-0000-0000-00000000000f   # record with goal -> to preserve
SIDNG=99990000-0000-0000-0000-00000000001a   # empty but name_source user -> preserve
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: unknown\nstatus_source: auto\nname: ""\nname_source: auto\nforked_from: null\n---\n## extracted\n\n## user_notes\n' "$SIDNE" > "$STK_LOCAL/shard/$EPN/$SIDNE.md"
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: unknown\nstatus_source: auto\nname: ""\nname_source: auto\nforked_from: null\n---\n## extracted\ngoal: something\nsummary: x\n\n## user_notes\n' "$SIDNF" > "$STK_LOCAL/shard/$EPN/$SIDNF.md"
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: unknown\nstatus_source: auto\nname: keep-me\nname_source: user\nforked_from: null\n---\n## extracted\n\n## user_notes\n' "$SIDNG" > "$STK_LOCAL/shard/$EPN/$SIDNG.md"
OUTN=$(bash "$STK" hygiene 2>/dev/null)
if printf '%s' "$OUTN" | grep -q "$SIDNE"; then ok "hygiene dry-run: detects the empty stub"; else ko "hygiene dry-run: stub not detected"; fi
if printf '%s' "$OUTN" | grep -q "$SIDNF"; then ko "hygiene dry-run: false positive on record with goal"; else ok "hygiene dry-run: record with goal ignored"; fi
if printf '%s' "$OUTN" | grep -q "$SIDNG"; then ko "hygiene dry-run: false positive on name_source user"; else ok "hygiene dry-run: name_source user ignored"; fi
if [ -f "$STK_LOCAL/shard/$EPN/$SIDNE.md" ]; then ok "hygiene dry-run: does not remove without --apply"; else ko "hygiene dry-run: removed without --apply"; fi
bash "$STK" hygiene --apply >/dev/null 2>&1
if [ -f "$STK_LOCAL/shard/$EPN/$SIDNE.md" ]; then ko "hygiene --apply: empty stub not removed"; else ok "hygiene --apply: empty stub removed"; fi
if [ -f "$STK_LOCAL/shard/$EPN/$SIDNF.md" ]; then ok "hygiene --apply: record with goal preserved"; else ko "hygiene --apply: record with goal removed"; fi
if [ -f "$STK_LOCAL/shard/$EPN/$SIDNG.md" ]; then ok "hygiene --apply: name_source user preserved"; else ko "hygiene --apply: name_source user removed"; fi

echo "== O: triage.py (resumable clusters / other nodes) =="
echo testnode > "$STK_LOCAL/node"
TROOT="$T/troot"; mkdir -p "$TROOT"
SIDO1=0a000000-0000-0000-0000-0000000000a1   # local, resumable (jsonl present)
SIDO2=0b000000-0000-0000-0000-0000000000b2   # other node
cat > "$TROOT/index.jsonl" <<EOF
{"session_id":"$SIDO1","node":"testnode","project_path":"/p/o1","name":"triage-local-one","status":"active","last_activity_at":"2026-06-20T10:00:00Z"}
{"session_id":"$SIDO2","node":"otherhost","project_path":"/p/o2","name":"triage-remote-one","status":"dormant","last_activity_at":"2026-06-19T10:00:00Z"}
EOF
mkdir -p "$CLAUDE_DIR/projects/-p-o1"
echo '{"type":"user","cwd":"/p/o1"}' > "$CLAUDE_DIR/projects/-p-o1/$SIDO1.jsonl"
OUTO=$($PY "$H/triage.py" "$TROOT" 2>&1)
if printf '%s' "$OUTO" | grep -q "RESUMABLE"; then ok "triage: RESUMABLE section"; else ko "triage: RESUMABLE missing"; fi
if printf '%s' "$OUTO" | grep -q "claude -r $SIDO1"; then ok "triage: resume command for the local one"; else ko "triage: resume command missing"; fi
if printf '%s' "$OUTO" | grep -q "OTHER NODES"; then ok "triage: OTHER NODES section"; else ko "triage: OTHER NODES missing"; fi
if printf '%s' "$OUTO" | grep -q "ssh otherhost"; then ok "triage: ssh for the remote node"; else ko "triage: remote ssh missing"; fi
# colour: absent in capture (non-tty), present with FORCE_COLOR
if printf '%s' "$OUTO" | grep -q $'\033'; then ko "triage: ANSI codes in capture (non-tty)"; else ok "triage: no ANSI in capture (non-tty)"; fi
OUTOC=$(FORCE_COLOR=1 $PY "$H/triage.py" "$TROOT" 2>&1)
if printf '%s' "$OUTOC" | grep -q $'\033'; then ok "triage: ANSI with FORCE_COLOR"; else ko "triage: FORCE_COLOR does not colour"; fi

echo "== P: close guard on a live tab (refuse single, --force, batch skip) =="
# live pid that is NOT an ancestor of stk (a background sleep): that way the session counts as
# "open" but NOT "current" -> the guard fires. ($$ would be an ancestor => self-close.)
sleep 300 & GP=$!
EPP="-guard"; mkdir -p "$STK_LOCAL/shard/$EPP" "$CLAUDE_DIR/sessions"
SIDP1=ab000000-0000-0000-0000-00000000aa01   # live tab
SIDP3=ab000000-0000-0000-0000-00000000aa03   # live tab (batch)
SIDP2=ab000000-0000-0000-0000-00000000aa02   # normal (batch)
mkrec(){ printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nstatus: unknown\nstatus_source: auto\n---\n## extracted\n\n## user_notes\n' "$1" > "$STK_LOCAL/shard/$EPP/$1.md"; }
mkrec "$SIDP1"; mkrec "$SIDP3"
printf '{"sessionId":"%s","pid":%s}' "$SIDP1" "$GP" > "$CLAUDE_DIR/sessions/$SIDP1.json"
printf '{"sessionId":"%s","pid":%s}' "$SIDP3" "$GP" > "$CLAUDE_DIR/sessions/$SIDP3.json"
if bash "$STK" close --session "$SIDP1" --status done >/dev/null 2>&1; then ko "guard: close of a live tab NOT refused"; else ok "guard: close of a live tab refused"; fi
eq "guard: record not closed (stays unknown)" "$(fmget "$STK_LOCAL/shard/$EPP/$SIDP1.md" status)" "unknown"
bash "$STK" close --session "$SIDP1" --status done --force >/dev/null 2>&1
eq "guard: --force closes anyway" "$(fmget "$STK_LOCAL/shard/$EPP/$SIDP1.md" status)" "done"
bash "$STK" close --session "$SIDP3" --session "$SIDP2" --status dropped >/dev/null 2>&1 || true
eq "guard batch: live tab skipped (stays unknown)" "$(fmget "$STK_LOCAL/shard/$EPP/$SIDP3.md" status)" "unknown"
eq "guard batch: normal session closed"            "$(fmget "$STK_LOCAL/shard/_unindexed/$SIDP2.md" status)" "dropped"
kill "$GP" 2>/dev/null || true

echo "== Q: _resolve_encoded (note/close on a sid with a pruned JSONL -> existing record, never _unindexed) =="
EPQ="-realproj"; mkdir -p "$STK_LOCAL/shard/$EPQ"
SIDQ=de000000-0000-0000-0000-00000000ee01     # no live JSONL, but a record in the shard
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nproject: realproj\nproject_path: /real/proj\nstatus: unknown\nstatus_source: auto\n---\n## extracted\n\n## user_notes\n' "$SIDQ" > "$STK_LOCAL/shard/$EPQ/$SIDQ.md"
bash "$STK" note --session "$SIDQ" --kind future "note-resolve-x" >/dev/null 2>&1
if grep -q 'note-resolve-x' "$STK_LOCAL/shard/$EPQ/$SIDQ.md"; then ok "resolve: note appended to the existing record"; else ko "resolve: note not on the existing record"; fi
if [ -e "$STK_LOCAL/shard/_unindexed/$SIDQ.md" ]; then ko "resolve: note created an _unindexed orphan"; else ok "resolve: no _unindexed orphan from note"; fi
bash "$STK" close --session "$SIDQ" --status done >/dev/null 2>&1
eq "resolve: close updates the existing record" "$(fmget "$STK_LOCAL/shard/$EPQ/$SIDQ.md" status)" "done"
if [ -e "$STK_LOCAL/shard/_unindexed/$SIDQ.md" ]; then ko "resolve: close created an _unindexed orphan"; else ok "resolve: no _unindexed orphan from close"; fi

echo "== R: dashboard includes the unknown ones + EV column (anti under-report) =="
DROOT="$T/droot"; mkdir -p "$DROOT/testnode/-dp"
SIDR=cd000000-0000-0000-0000-00000000dd01
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nproject: dp\nstatus: unknown\nstatus_source: auto\ndormancy_risk: medium\nn_events: 7\nname: ""\nlast_activity_at: 2026-06-20T10:00:00Z\n---\n## extracted\ngoal: stuff\nopen:\n  - x\n\n## user_notes\n' "$SIDR" > "$DROOT/testnode/-dp/$SIDR.md"
printf '{"session_id":"%s","node":"testnode","project":"dp","status":"unknown","dormancy_risk":"medium","n_events":7,"name":"","last_activity_at":"2026-06-20T10:00:00Z"}\n' "$SIDR" > "$DROOT/index.jsonl"
OUTR=$($PY "$H/dashboard.py" "$DROOT" 2>&1)
# the dashboard prints only the 8-char prefix of the sid
if printf '%s' "$OUTR" | grep -q "${SIDR:0:8}.*unknown\|unknown.*${SIDR:0:8}"; then ok "dashboard: includes the unknown status"; else ko "dashboard: unknown hidden (under-report)"; fi
if printf '%s' "$OUTR" | grep -q " EV "; then ok "dashboard: EV column present"; else ko "dashboard: EV column missing"; fi
if printf '%s' "$OUTR" | grep -q "1 unknown/not extracted"; then ok "dashboard: header counts the unknown ones"; else ko "dashboard: header does not count the unknown ones"; fi
if printf '%s' "$OUTR" | grep -q $'\033'; then ko "dashboard: ANSI in capture (non-tty)"; else ok "dashboard: no ANSI in capture"; fi
OUTRC=$(FORCE_COLOR=1 $PY "$H/dashboard.py" "$DROOT" 2>&1)
if printf '%s' "$OUTRC" | grep -q $'\033'; then ok "dashboard: ANSI with FORCE_COLOR"; else ko "dashboard: FORCE_COLOR does not colour"; fi

echo "== S: -u allowlist (rejects the non-whitelisted subcommands, no ssh) =="
if bash "$STK" -u somehost index 2>/dev/null;        then ko "-u: index accepted (must reject)"; else ok "-u: index rejected pre-ssh"; fi
if bash "$STK" -u somehost where --cwd /x 2>/dev/null; then ko "-u: where accepted (must reject)"; else ok "-u: where rejected pre-ssh"; fi
if bash "$STK" -u somehost primary-check --cwd /x 2>/dev/null; then ko "-u: primary-check accepted (must reject, see the double-hop comment)"; else ok "-u: primary-check rejected pre-ssh"; fi
ERRS=$(bash "$STK" -u somehost hook 2>&1 >/dev/null || true)
if printf '%s' "$ERRS" | grep -q "scan close note publish dashboard repo-status"; then ok "-u: message lists the updated allowlist"; else ko "-u: allowlist message missing/not updated"; fi
# repo-status must PASS the allowlist (it fails later, on the actual ssh attempt)
ERRS2=$(bash "$STK" -u somehost repo-status /tmp 2>&1 >/dev/null || true)
if printf '%s' "$ERRS2" | grep -q "supported only with: scan"; then ko "-u: repo-status rejected by the allowlist (it should not be)"; else ok "-u: repo-status passes the allowlist"; fi

echo "== T: stk repo-status (pure bash, dirty/ahead/behind, structured errors) =="
mkdir -p "$T/rs/clean" && (cd "$T/rs/clean" && git init -q && git config user.email t@t && git config user.name t && echo a > a.txt && git add a.txt && git commit -qm init)
J=$(bash "$STK" repo-status "$T/rs/clean")
eq "repo-status T1: dirty=0 on a clean repo"    "$(echo "$J"|jq -r .dirty)" "0"
eq "repo-status T1: has_upstream=false (no remote)" "$(echo "$J"|jq -r .has_upstream)" "false"

echo b >> "$T/rs/clean/a.txt"
J=$(bash "$STK" repo-status "$T/rs/clean")
eq "repo-status T2: dirty=1 on a dirty repo"    "$(echo "$J"|jq -r .dirty)" "1"
(cd "$T/rs/clean" && git checkout -q -- a.txt)

J=$(bash "$STK" repo-status "$T/rs/does-not-exist")
eq "repo-status T3: path-not-found"            "$(echo "$J"|jq -r .error)" "path-not-found"

J=$(bash "$STK" repo-status "$T")
eq "repo-status T4: not-a-git-repo"            "$(echo "$J"|jq -r .error)" "not-a-git-repo"

echo "== U: stk primary-check (applicable, issues, cache) =="
mkdir -p "$T/pc/sub"; cat > "$T/pc/CLAUDE.md" <<'MD'
## Node ownership
- Primary: alpha (`/home/u/code/x`)
- Secondaries: testnode (`/Users/x/x`)
MD
mkdir -p "$T/pcbogus/sub"; cat > "$T/pcbogus/CLAUDE.md" <<'MD'
## Node ownership
- Primary: stk-test-bogus-host-xyzzy (`/nowhere`)
- Secondaries: testnode (`/here`)
MD
PC(){ bash "$STK" primary-check "$@"; }

# U1: current node is already the primary -> not applicable, no ssh
J=$(PC --node alpha --cwd "$T/pc/sub")
eq "primary-check U1: applicable false (you are the primary)" "$(echo "$J"|jq -r .applicable)" "false"

# U2: ownership not declared -> not applicable
J=$(PC --node testnode --cwd "$T")
eq "primary-check U2: applicable false (no ownership)"   "$(echo "$J"|jq -r .applicable)" "false"

# U3: primary unreachable (nonexistent ssh alias) -> issue primary-unreachable, no crash
J=$(PC --node testnode --cwd "$T/pcbogus/sub")
eq "primary-check U3: applicable true"                    "$(echo "$J"|jq -r .applicable)" "true"
eq "primary-check U3: remote error unreachable"           "$(echo "$J"|jq -r '.remote.error')" "unreachable"
eq "primary-check U3: issues contains primary-unreachable" "$(echo "$J"|jq -r '.issues|index("primary-unreachable")!=null')" "true"

# U4: cache hit — pre-seed a fake fresh entry, verify that it does NOT try ssh (otherwise it would return unreachable)
KEY=$(printf '%s:%s' "stk-test-bogus-host-xyzzy" "/nowhere" | tr -c 'A-Za-z0-9_.-' '_')
mkdir -p "$STK_LOCAL/primary-check"
cat > "$STK_LOCAL/primary-check/$KEY.json" <<JSON
{"ts":"2026-01-01T00:00:00Z","ts_epoch":$(date +%s),"primary_node":"stk-test-bogus-host-xyzzy","primary_path":"/nowhere","remote":{"path":"/nowhere","branch":"main","dirty":0,"has_upstream":true,"ahead":0,"behind":0}}
JSON
J=$(PC --node testnode --cwd "$T/pcbogus/sub")
eq "primary-check U4: cache hit, remote.dirty from the cache" "$(echo "$J"|jq -r '.remote.dirty')" "0"
eq "primary-check U4: no primary-unreachable (cache, no ssh)" "$(echo "$J"|jq -r '.issues|index("primary-unreachable")!=null')" "false"

# U5: STK_PRIMARY_CHECK_TTL=0 forces the miss even with a fresh cache -> retries ssh -> unreachable
J=$(STK_PRIMARY_CHECK_TTL=0 PC --node testnode --cwd "$T/pcbogus/sub")
eq "primary-check U5: TTL=0 forces a miss, returns unreachable" "$(echo "$J"|jq -r '.remote.error')" "unreachable"

# U6: --force bypasses the cache even with the default TTL and a fresh cache -> retries ssh -> unreachable
cat > "$STK_LOCAL/primary-check/$KEY.json" <<JSON
{"ts":"2026-01-01T00:00:00Z","ts_epoch":$(date +%s),"primary_node":"stk-test-bogus-host-xyzzy","primary_path":"/nowhere","remote":{"path":"/nowhere","branch":"main","dirty":0,"has_upstream":true,"ahead":0,"behind":0}}
JSON
J=$(PC --force --node testnode --cwd "$T/pcbogus/sub")
eq "primary-check U6: --force bypasses a fresh cache, returns unreachable" "$(echo "$J"|jq -r '.remote.error')" "unreachable"

echo "== V: stk publish pushes by default; --no-push skips it (--push is accepted as the default) =="
BARE="$T/pub-bare.git"; git init -q --bare "$BARE"
git -C "$GR" remote add origin "$BARE" 2>/dev/null || git -C "$GR" remote set-url origin "$BARE"
git -C "$GR" branch -M main 2>/dev/null || true
git -C "$GR" push -q -u origin main 2>/dev/null || true  # baseline: aligns origin/main to the current HEAD of GR (already populated by E/F)

printf -- '- 2026-06-07 (future): push-default-test  <!-- nid:pd1 -->\n' >> "$MD"
bash "$STK" publish >/dev/null 2>&1
LHEAD1=$(git -C "$GR" rev-parse HEAD)
RHEAD1=$(git -C "$BARE" rev-parse main 2>/dev/null || echo none)
eq "publish V1: default pushes (bare remote aligned)" "$RHEAD1" "$LHEAD1"

printf -- '- 2026-06-07 (future): no-push-test  <!-- nid:np1 -->\n' >> "$MD"
bash "$STK" publish --no-push >/dev/null 2>&1
LHEAD2=$(git -C "$GR" rev-parse HEAD)
RHEAD2=$(git -C "$BARE" rev-parse main 2>/dev/null || echo none)
if [ "$LHEAD2" != "$LHEAD1" ]; then ok "publish V2: --no-push still commits locally"; else ko "publish V2: --no-push did not commit"; fi
if [ "$RHEAD2" = "$RHEAD1" ]; then ok "publish V2: --no-push does not push (bare remote behind)"; else ko "publish V2: --no-push pushed anyway"; fi

printf -- '- 2026-06-07 (future): explicit-push-test  <!-- nid:ep1 -->\n' >> "$MD"
bash "$STK" publish --push >/dev/null 2>&1
LHEAD3=$(git -C "$GR" rev-parse HEAD)
RHEAD3=$(git -C "$BARE" rev-parse main 2>/dev/null || echo none)
eq "publish V3: explicit --push pushes (a synonym of the default)" "$RHEAD3" "$LHEAD3"

echo "== W: naming (hook: context from the cwd; close --name: guard on the positive, on the negative and by mutation) =="
# test naming-map in the suite's STK_LOCAL: the hook and the guard read it (default path)
cat > "$STK_LOCAL/naming-map.yaml" <<'YML'
schema: v0
contexts:
  foo-repo:  foo              # test subject
                              # a story session -> foo-<slug>-<action>
  infra:     real-target
  acme-tool: acm              # wiki/alpha/acme-tool -> acm (not wk-al-acme-tool)
  nul:
  # block at the end of the section: it does not belong to the nul entry
  acme:          acme-c          # product monorepo of the test org
  acme-internal: [acme-i, acme-c] # a story session: theme = worktree slug, action from intent
  customer-desk: acme-cs
  lab-game:  "exp{N}"
window_prefix:
  acme: a
kb_layout:                    # the folder names of the test kb: data, not code
  root: wiki
  orgs_dir: teams
  token: wk
kb_tiers:
  alpha: al                   # the folders not listed (e.g. beta) are not tiers
kb_orgs:
  acme:
    umbrella: acme-kb-meta
    repos:
      product: acme-kb-product
      admin:   acme-kb-admin
      infra:   acme-kb-infra
      brand:   acme-kb-brand
YML
hookctx(){ printf '{"session_id":"%s","source":"startup","cwd":"%s"}' "$1" "$2" | env -u TMUX_PANE bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext'; }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
# portable forms (the suite runs on Linux and macOS): BSD sed has no `-i` without a suffix, BSD
# stat has no `-c`, BSD wc pads its count, `timeout` is GNU coreutils
sedi(){ local f="${@: -1}"; sed "${@:1:$#-1}" "$f" > "$f.sedi" && cat "$f.sedi" > "$f" && rm -f "$f.sedi"; }
fmode(){ $PY -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777)[2:])" "$1"; }
tmo(){ if command -v timeout >/dev/null 2>&1; then timeout "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }
# W1: cwd that maps to a known context -> map row, subject, entry comment, set of actions from naming.md
OUTW=$(hookctx 99999999-0000-0000-0000-000000000011 /x/foo-repo)
if has "$OUTW" 'row `foo-repo: foo`'; then ok "hook W1: cites the applied map row"; else ko "hook W1: map row missing"; fi
if has "$OUTW" 'starts with `foo-`'; then ok "hook W1: subject foo from the context"; else ko "hook W1: subject missing"; fi
if has "$OUTW" 'a story session -> foo-<slug>-<action>'; then ok "hook W1: entry comment injected"; else ko "hook W1: entry comment missing"; fi
if has "$OUTW" 'test subject'; then ok "hook W1: also the comment on the key's line"; else ko "hook W1: comment on the key's line lost"; fi
if has "$OUTW" 'setup | fix | update | migration'; then ok "hook W1: set of actions read from naming.md"; else ko "hook W1: set of actions missing"; fi
if has "$OUTW" 'read references/naming.md of the session-tracker skill and'; then ok "hook W1: asks to read naming.md and the map"; else ko "hook W1: read command missing"; fi
if has "$OUTW" 'After the subject comes the issue number without #'; then ok "hook W1: the issue number after the subject"; else ko "hook W1: issue number not named"; fi
# W2: real-target -> the subject is NOT the repo
OUTW=$(hookctx 99999999-0000-0000-0000-000000000012 /x/infra)
if has "$OUTW" 'infra: real-target' && has "$OUTW" 'is NOT `infra`'; then ok "hook W2: real-target, the subject is not the repo"; else ko "hook W2: real-target clause missing"; fi
if has "$OUTW" 'issue number without #'; then ok "hook W2: the issue number also holds on real-target"; else ko "hook W2: issue number missing on real-target"; fi
# W3: cwd unknown to the map -> it says so, does not invent
OUTW=$(hookctx 99999999-0000-0000-0000-000000000013 /x/zzz-unknown)
if has "$OUTW" 'is not an entry of contexts'; then ok "hook W3: unknown cwd declared"; else ko "hook W3: unknown cwd not declared"; fi
if has "$OUTW" 'row `'; then ko "hook W3: invents a map row"; else ok "hook W3: no row invented"; fi
OUTW=$(hookctx 99999999-0000-0000-0000-000000000015 /x/nul)
if has "$OUTW" 'block at the end of the section'; then ko "hook W3b: trailing comment attributed to the last entry"; else ok "hook W3b: trailing comment not attributed"; fi
if has "$OUTW" 'without a valid subject'; then ok "hook W3b: entry without a value declared, not 'None'"; else ko "hook W3b: entry without a value not declared"; fi
OUTW=$(hookctx 99999999-0000-0000-0000-000000000016 /h/wiki/alpha/acme-tool)
if has "$OUTW" 'row `acme-tool: acm`'; then ok "hook W3c: inside kb the declared entry wins over the tier rule"; else ko "hook W3c: kb rule overrode the map"; fi
# W4: payload without cwd -> fallback to PWD, clause still present
OUTW=$(printf '{"session_id":"%s","source":"startup"}' 99999999-0000-0000-0000-000000000014 | bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')
if has "$OUTW" 'Naming context'; then ok "hook W4: without cwd in the payload the clause is still there"; else ko "hook W4: clause missing without cwd"; fi

# guard on stk close --name: sessions with cwd in the transcript
mkw(){ local ep; ep=$(printf '%s' "$2" | tr '/' '-'); mkdir -p "$CLAUDE_DIR/projects/$ep"
       printf '{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"%s","uuid":"u1"}\n' "$2" > "$CLAUDE_DIR/projects/$ep/$1.jsonl"; printf '%s' "$ep"; }
# returns 0 if close ACCEPTS; stderr in $WERR
tryclose(){ WERR=$(bash "$STK" close --session "$1" --status done "${@:2}" 2>&1 >/dev/null); }
WS=99999999-0000-0000-0000-00000000002
EPW=$(mkw "${WS}1" /x/foo-repo)
if tryclose "${WS}1" --name foo-thing-fix; then ok "guard W5: compliant name accepted"; else ko "guard W5: compliant name rejected: $WERR"; fi
eq "guard W5: name written in the record" "$(fmget "$STK_LOCAL/shard/$EPW/${WS}1.md" name)" "foo-thing-fix"
if has "$WERR" "compliant (naming-map.yaml contexts: foo-repo: foo"; then ok "guard W5: the confirmation cites the rule"; else ko "guard W5: confirmation without a rule: $WERR"; fi
mkw "${WS}2" /x/foo-repo >/dev/null
if tryclose "${WS}2" --name bar-thing-fix; then ko "guard W6: wrong subject ACCEPTED"; else ok "guard W6: wrong subject rejected"; fi
if has "$WERR" "foo-repo: foo"; then ok "guard W6: the rejection names the map row"; else ko "guard W6: rejection without a rule: $WERR"; fi
if [ -e "$STK_LOCAL/shard/$EPW/${WS}2.md" ]; then ko "guard W6: record written despite the rejection"; else ok "guard W6: no write on rejection"; fi
mkw "${WS}3" /x/foo-repo >/dev/null
if tryclose "${WS}3" --name foo-thing-release; then ko "guard W7: action outside the set ACCEPTED"; else ok "guard W7: action outside the set rejected"; fi
if has "$WERR" "closed set"; then ok "guard W7: the rejection names the closed set"; else ko "guard W7: rejection without a rule: $WERR"; fi
# cwd unknown to the map: that way the subject check cannot reject in place of the wip- one
mkw "${WS}3w" /x/zzz-unknown >/dev/null
if tryclose "${WS}3w" --name wip-zzz-thing-fix; then ko "guard W8: wip- ACCEPTED"; else ok "guard W8: wip- rejected"; fi
if has "$WERR" "starts with 'wip-'"; then ok "guard W8: the rejection names the wip- rule"; else ko "guard W8: rejection for another rule: $WERR"; fi
mkw "${WS}4" /x/infra >/dev/null
if tryclose "${WS}4" --name infra-hardening-fix; then ko "guard W9: name of the real-target repo ACCEPTED"; else ok "guard W9: name of the real-target repo rejected"; fi
if tryclose "${WS}4" --name node-a-hardening-setup; then ok "guard W9: real target accepted"; else ko "guard W9: real target rejected: $WERR"; fi
mkw "${WS}4w" /x/infra-wt >/dev/null
if tryclose "${WS}4w" --name infra-hardening-fix; then ko "guard W9b: worktree of a real-target with the repo's name ACCEPTED"; else ok "guard W9b: worktree of a real-target with the repo's name rejected"; fi
mkw "${WS}5" /h/wiki/alpha/acme/sub >/dev/null
if tryclose "${WS}5" --name acme-report-check; then ko "guard W10: kb without the wk-al prefix ACCEPTED"; else ok "guard W10: kb without the wk-al prefix rejected"; fi
if tryclose "${WS}5" --name wk-al-acme-report-check; then ok "guard W10: wk-al-<area> accepted"; else ko "guard W10: wk-al-<area> rejected: $WERR"; fi
mkw "${WS}5k" /h/wiki/alpha/acme-tool >/dev/null
if tryclose "${WS}5k" --name acm-report-check; then ok "guard W10b: declared entry inside kb accepted (acm-)"; else ko "guard W10b: declared entry inside kb rejected: $WERR"; fi
if tryclose "${WS}5k" --name wk-al-acme-tool-report-check; then ko "guard W10b: wk-al- on a declared entry ACCEPTED"; else ok "guard W10b: wk-al- on a declared entry rejected"; fi
mkw "${WS}6" /x/zzz-unknown >/dev/null
if tryclose "${WS}6" --name anything-goes-release; then ko "guard W11: unknown cwd, action outside the set ACCEPTED"; else ok "guard W11: unknown cwd, action still checked"; fi
if tryclose "${WS}6" --name anything-goes-check; then ok "guard W11: unknown cwd, subject not checked -> passes"; else ko "guard W11: unknown cwd rejected: $WERR"; fi
if tryclose "${WS}6" --name fix; then ko "guard W11b: single-action name ACCEPTED"; else ok "guard W11b: single-action name rejected"; fi
mkw "${WS}7" /x/foo-repo >/dev/null
if tryclose "${WS}7" --class distill --name foo-thing-fix; then ko "guard W12: distill without suffix ACCEPTED"; else ok "guard W12: distill without suffix rejected"; fi
if tryclose "${WS}7" --class distill --name foo-thing-fix-sk-distill-2026-10-17; then ok "guard W12: distill with suffix accepted"; else ko "guard W12: distill with suffix rejected: $WERR"; fi
mkw "${WS}8" /x/foo-repo >/dev/null
if tryclose "${WS}8" --name bar-thing-fix --force; then ok "guard W13: --force passes"; else ko "guard W13: --force does not pass: $WERR"; fi
eq "guard W13: forced name written" "$(fmget "$STK_LOCAL/shard/$EPW/${WS}8.md" name)" "bar-thing-fix"
# W14: guard not runnable (naming.md missing) -> exit 2, not 0
$PY "$H/naming.py" check --cwd /x/foo-repo --name foo-thing-fix --naming-map "$STK_LOCAL/naming-map.yaml" --naming-md "$T/nonexistent.md" >/dev/null 2>&1; RC=$?
eq "guard W14: naming.md missing -> exit 2 (never a silent pass)" "$RC" "2"
printf 'contexts: [a, b\n' > "$T/bad.yaml"
$PY "$H/naming.py" check --cwd /x/foo-repo --name bar-a-fix --naming-map "$T/bad.yaml" >/dev/null 2>&1; RC=$?
eq "guard W14b: malformed naming-map -> exit 2 (not a pass with an empty map)" "$RC" "2"
printf 'contexts:\n  - a\n' > "$T/bad2.yaml"
$PY "$H/naming.py" check --cwd /x/foo-repo --name bar-a-fix --naming-map "$T/bad2.yaml" >/dev/null 2>&1; RC=$?
eq "guard W14c: contexts non-mapping -> exit 2 (not a crash read as a rejection)" "$RC" "2"
OUTW=$($PY "$H/naming.py" context --text --cwd /x/foo-repo --naming-map "$T/bad.yaml" 2>/dev/null)
if has "$OUTW" "NOT resolvable"; then ok "hook W14d: with a malformed map the text says so"; else ko "hook W14d: malformed map not declared"; fi
# W15: MUTATION — copy of stk without the guard block: the wrong name must PASS,
# otherwise W6 measures something else. Canary: the sed really removed lines.
mkdir -p "$T/mut/bin"; ln -s "$(cd "$H" && pwd)" "$T/mut/helpers"
sed '/# naming-guard-begin/,/# naming-guard-end/d' "$STK" > "$T/mut/bin/stk"; chmod +x "$T/mut/bin/stk"
NL_ORIG=$(wc -l < "$STK"); NL_MUT=$(wc -l < "$T/mut/bin/stk")
if [ "$NL_MUT" -lt "$NL_ORIG" ] && ! grep -q 'naming.py" check' "$T/mut/bin/stk"; then ok "mutation W15: the copy is without the guard ($NL_ORIG -> $NL_MUT lines)"; else ko "mutation W15: sed did not remove the guard"; fi
mkw "${WS}9" /x/foo-repo >/dev/null
if bash "$T/mut/bin/stk" close --session "${WS}9" --status done --name bar-thing-fix >/dev/null 2>&1; then ok "mutation W15: without the guard the wrong subject passes (W6 measures the guard)"; else ko "mutation W15: the mutant rejects even without the guard: W6 does not measure the guard"; fi
mkw "${WS}0" /x/foo-repo >/dev/null
if bash "$T/mut/bin/stk" close --session "${WS}0" --status done --name foo-thing-fix >/dev/null 2>&1; then ok "mutation W15: control, the compliant name passes in both"; else ko "mutation W15: the mutant rejects the compliant name"; fi

echo "== X: subjects per repo (contexts acme-c/-i/-cs, kb_orgs for umbrella and function repo) and issue number =="
ctxt(){ $PY "$H/naming.py" context --text --cwd "$1" --naming-map "$STK_LOCAL/naming-map.yaml" 2>/dev/null; }
# X1: context --text cites the map row and the subject for the three repos and the five kb cwds
for spec in "/x/acme|row \`acme: acme-c\`|acme-c" "/x/acme-internal|row \`acme-internal: [acme-i, acme-c]\`|acme-i" \
            "/x/customer-desk|row \`customer-desk: acme-cs\`|acme-cs" \
            "/h/wiki/teams/acme|kb_orgs: acme: umbrella: acme-kb-meta|acme-kb-meta" \
            "/h/wiki/teams/acme/product|kb_orgs: acme: repos: product: acme-kb-product|acme-kb-product" \
            "/h/wiki/teams/acme/admin|kb_orgs: acme: repos: admin: acme-kb-admin|acme-kb-admin" \
            "/h/wiki/teams/acme/infra|kb_orgs: acme: repos: infra: acme-kb-infra|acme-kb-infra" \
            "/h/wiki/teams/acme/brand|kb_orgs: acme: repos: brand: acme-kb-brand|acme-kb-brand"; do
  c=${spec%%|*}; r=${spec#*|}; r=${r%|*}; sj=${spec##*|}
  OUTX=$(ctxt "$c")
  if has "$OUTX" "$r" && has "$OUTX" "starts with \`$sj-\`"; then ok "context X1: $c -> $sj"; else ko "context X1: $c does not cite '$r' / subject $sj: $OUTX"; fi
done
# on a function repo with .git the resolver without kb_orgs composed contexts[org]+fn: here it must fall
for fn in product admin infra media; do mkdir -p "$T/h/wiki/teams/acme/$fn/.git"; done
OUTX=$(ctxt "$T/h/wiki/teams/acme/product")
if has "$OUTX" 'acme-c-product'; then ko "context X1b: wiki/teams/acme/product composed from contexts+fn (acme-c-product)"; else ok "context X1b: no contexts+fn composition"; fi
if has "$OUTX" 'starts with `acme-kb-product-`'; then ok "context X1b: repo with .git -> subject from kb_orgs"; else ko "context X1b: repo with .git not resolved on kb_orgs: $OUTX"; fi
OUTX=$(ctxt "$T/h/wiki/teams/acme/infra")
if has "$OUTX" 'real-target'; then ko "context X1b: wiki/teams/acme/infra mistaken for the infra real-target repo"; else ok "context X1b: wiki/teams/acme/infra is not the infra repo"; fi
# repo under the org without a value in repos: subject not checked, NEVER the umbrella
OUTX=$(ctxt "$T/h/wiki/teams/acme/media")
if has "$OUTX" 'acme-kb-meta'; then ko "context X1d: undeclared repo mistaken for the umbrella"; else ok "context X1d: undeclared repo does not take the umbrella"; fi
if has "$OUTX" 'the repo media has no subject in repos'; then ok "context X1d: undeclared repo declared as such"; else ko "context X1d: undeclared repo not reported: $OUTX"; fi
if has "$OUTX" 'do not use the basename `media`'; then ok "context X1d: undeclared repo, no basename proposed as subject"; else ko "context X1d: the text proposes the basename: $OUTX"; fi
mkdir -p "$T/h/wiki/teams/acme/media/assets/logo"
CHK=$($PY "$H/naming.py" context --cwd "$T/h/wiki/teams/acme/media/assets/logo" --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)
eq "context X1d: deep subfolder of an undeclared repo -> unknown" "$CHK" "unknown"
mkdir -p "$T/h/wiki/teams/acme/wt"; printf 'gitdir: /x\n' > "$T/h/wiki/teams/acme/wt/.git"
CHK=$($PY "$H/naming.py" context --cwd "$T/h/wiki/teams/acme/wt" --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)
eq "context X1d: undeclared repo with .git file (worktree/submodule) -> unknown" "$CHK" "unknown"
printf 'contexts: {}\nkb_layout: {root: wiki, orgs_dir: teams, token: wk}\nkb_orgs:\n  acme:\n    umbrella: acme-kb-meta\n    repos:\n      product:\n' > "$T/emptyrepo.yaml"
CHK=$($PY "$H/naming.py" check --cwd /h/wiki/teams/acme/product --name acme-kb-meta-quotes-update --naming-map "$T/emptyrepo.yaml" | jq -r '.context.kind')
eq "context X1d: repos with an empty value -> unknown, not umbrella" "$CHK" "unknown"
printf 'contexts: {}\nkb_orgs:\n  acme: acme-kb-meta\n' > "$T/badkbo.yaml"
$PY "$H/naming.py" check --cwd /x/zzz --name zzz-a-fix --naming-map "$T/badkbo.yaml" >/dev/null 2>&1; RC=$?
eq "guard X1e: malformed kb_orgs -> exit 2 (not a pass with an ignored section)" "$RC" "2"
printf 'contexts: {}\nkb_orgs:\n  acme:\n    umbrella: acme-kb-meta\n    repos: [product]\n' > "$T/badrepos.yaml"
$PY "$H/naming.py" check --cwd /x/zzz --name zzz-a-fix --naming-map "$T/badrepos.yaml" >/dev/null 2>&1; RC=$?
eq "guard X1e: repos non-mapping -> exit 2 (not a crash inside the resolver)" "$RC" "2"
# empty org entry in kb_orgs: the org stays in kb_orgs (unknown), NEVER the contexts[org]+fn composition
printf 'contexts:\n  acme: acme-c\nkb_layout: {root: wiki, orgs_dir: teams, token: wk}\nkb_orgs:\n  acme:\n' > "$T/nullorg.yaml"
CHK=$($PY "$H/naming.py" context --cwd "$T/h/wiki/teams/acme/product" --naming-map "$T/nullorg.yaml" | jq -r '"\(.kind) \(.subject)"')
eq "context X1f: empty org entry -> unknown, not the contexts+fn composition (acme-c-product)" "$CHK" "unknown null"
OUTX=$(ctxt /h/wiki/teams/acme/decisions)
if has "$OUTX" 'umbrella: acme-kb-meta'; then ok "context X1c: non-repo folder of the umbrella -> umbrella"; else ko "context X1c: umbrella folder not resolved on the umbrella: $OUTX"; fi
# X2: guard on the positive and on the negative, per subject (the old forms and the prefix neighbours fall)
XS=99999999-0000-0000-0000-00000000003
xcase(){ # $1 sfx, $2 cwd, $3 name expected accepted, $4.. names expected rejected
  local sfx=$1 c=$2 good=$3 bad; shift 3; mkw "${XS}$sfx" "$c" >/dev/null
  for bad in "$@"; do
    if tryclose "${XS}$sfx" --name "$bad"; then ko "guard X2: $c ACCEPTS $bad"; else ok "guard X2: $c rejects $bad"; fi
  done
  if tryclose "${XS}$sfx" --name "$good"; then ok "guard X2: $c accepts $good"; else ko "guard X2: $c rejects $good: $WERR"; fi
}
xcase a1 /x/acme                 acme-c-thing-fix               acme-thing-fix acme-cs-thing-fix acme-i-thing-fix
xcase a2 /x/acme-internal        acme-i-monitor-rows-fix        acme-thing-fix acme-cs-thing-fix acme-internal-thing-fix acme-kb-product-1-x-setup
xcase a3 /x/customer-desk        acme-cs-thing-check            acme-c-thing-check customer-desk-thing-check
xcase a4 /x/acme-internal-rows   acme-i-rows-fix                acme-cs-rows-fix
xcase k1 /h/wiki/teams/acme         acme-kb-meta-handbook-update   acme-c-handbook-update acme-handbook-update
xcase k2 /h/wiki/teams/acme/product acme-kb-product-512-invoice-layout-update acme-c-product-quotes-update acme-kb-meta-quotes-update
xcase k3 /h/wiki/teams/acme/admin   acme-kb-admin-payroll-check    acme-c-admin-payroll-check acme-kb-product-payroll-check
xcase k4 /h/wiki/teams/acme/infra   acme-kb-infra-dns-fix          acme-c-infra-dns-fix infra-dns-fix
xcase k5 /h/wiki/teams/acme/brand   acme-kb-brand-logo-update      acme-c-brand-logo-update acme-kb-meta-logo-update brand-logo-update
# X3: issue number after the subject: allowed, and subject and action remain checked
xcase i1 /x/acme-internal        acme-i-3307-build-tool-setup acme-cs-3307-build-tool-setup acme-i-3307-build-tool-release acme-i-#3307-build-tool-setup 3307-acme-i-tool-setup
RSN=$($PY "$H/naming.py" check --cwd /x/acme-internal --name acme-i-3307-build-tool-setup --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .reason)
if has "$RSN" 'issue 3307'; then ok "guard X3: the confirmation reports the issue number"; else ko "guard X3: issue not reported: $RSN"; fi
CHK=$($PY "$H/naming.py" check --cwd /x/acme-internal --name acme-i-3307-build-tool-setup --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '.checks | index("issue") != null')
eq "guard X3: check records the issue token" "$CHK" "true"
CHK=$($PY "$H/naming.py" check --cwd /x/acme-internal --name acme-i-build-tool-setup --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '.checks | index("issue") != null')
eq "guard X3: without an issue no issue token (the number is optional)" "$CHK" "false"
CHK=$($PY "$H/naming.py" check --cwd /h/wiki/alpha/acme/sub --name wk-al-12-sub-fix --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '.checks | index("issue") != null')
eq "guard X3: in kb-tier the token after the tier token is not annotated as an issue (it is the area)" "$CHK" "false"
# X4: MUTATION of the guard in stk (same copy as W15): the new wrong names pass without the guard
mkw "${XS}m1" /x/acme-internal >/dev/null
if bash "$T/mut/bin/stk" close --session "${XS}m1" --status done --name acme-cs-3307-thing-fix >/dev/null 2>&1; then ok "mutation X4: without the guard the wrong subject with issue passes"; else ko "mutation X4: the mutant rejects even without the guard"; fi
mkw "${XS}m2" /h/wiki/teams/acme/product >/dev/null
if bash "$T/mut/bin/stk" close --session "${XS}m2" --status done --name acme-c-product-quotes-update >/dev/null 2>&1; then ok "mutation X4: without the guard the composed kb subject passes"; else ko "mutation X4: the mutant rejects the composed kb subject"; fi
# X5: MUTATION of the resolver: without the kb_orgs branch the X2 negative on product must fall
# (contexts acme-c + fn), while the control on the known repo stays the same
mkdir -p "$T/mut2"; sed 's/rest\[0\] == orgs_dir and rest\[1\] in kbo:/rest[0] == orgs_dir and False:/' "$H/naming.py" > "$T/mut2/naming.py"
# canary on the POSITIVE: the mutation is in the copy (the absence of the old form proves nothing)
if grep -q 'rest\[0\] == orgs_dir and False:' "$T/mut2/naming.py" && ! cmp -s "$H/naming.py" "$T/mut2/naming.py"; then ok "mutation X5: the copy is without the kb_orgs branch"; else ko "mutation X5: sed did not apply the mutation"; fi
mchk(){ $PY "$1" check --cwd "$2" --name "$3" --naming-map "$STK_LOCAL/naming-map.yaml" --naming-md "$H/../references/naming.md" >/dev/null 2>&1; echo $?; }
eq "mutation X5: with the kb_orgs branch acme-c-product is rejected" "$(mchk "$H/naming.py" "$T/h/wiki/teams/acme/product" acme-c-product-quotes-update)" "1"
eq "mutation X5: without the kb_orgs branch acme-c-product passes (X2 measures the branch)" "$(mchk "$T/mut2/naming.py" "$T/h/wiki/teams/acme/product" acme-c-product-quotes-update)" "0"
eq "mutation X5: control, acme-c-thing-fix on /x/acme passes in both" "$(mchk "$T/mut2/naming.py" /x/acme acme-c-thing-fix)$(mchk "$H/naming.py" /x/acme acme-c-thing-fix)" "00"

echo "== Y: contexts entry with several allowed subjects ([default, other]): the subject is decided by the worktree's repo =="
# Y1: from a folder with two subjects (acme-internal) both subjects pass, no other
xcase y1 /x/acme-internal        acme-c-4201-sync-report-rows-fix acme-kb-product-1-x-setup acme-cs-4201-rows-fix
xcase y2 /x/acme-internal        acme-i-3307-build-tool-setup  acme-kb-product-1-x-setup
xcase y3 /x/acme-internal-rows   acme-c-rows-fix                 acme-cs-rows-fix
# Y2: from the product repo (single-subject entry) only its own passes
xcase y4 /x/acme                 acme-c-4201-sync-report-rows-fix acme-i-4201-sync-report-rows-fix
CHK=$($PY "$H/naming.py" context --cwd /x/acme-internal --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '"\(.subject) \(.subjects|join(","))"')
eq "context Y3: default = first of the list (where.py uses subject)" "$CHK" "acme-i acme-i,acme-c"
OUTY=$(ctxt /x/acme-internal)
if has "$OUTY" 'Allowed subjects: `acme-i` (default) and `acme-c`' && has "$OUTY" "the repo the session actually works on"; then ok "context Y3: the text says allowed subjects and who decides"; else ko "context Y3: allowed subjects rule missing: $OUTY"; fi
OUTY=$(ctxt /x/acme)
if has "$OUTY" 'Allowed subjects'; then ko "context Y3: allowed subjects on a single-subject entry"; else ok "context Y3: single-subject entry without the allowed subjects rule"; fi
# Y4: invalid list (empty or with real-target) -> entry without a valid subject, not a pass on the first element
printf 'contexts:\n  bad1: []\n  bad2: [real-target, x]\n' > "$T/badlist.yaml"
for b in bad1 bad2; do CHK=$($PY "$H/naming.py" context --cwd "/x/$b" --naming-map "$T/badlist.yaml" | jq -r .kind); eq "context Y4: list $b invalid -> unknown" "$CHK" "unknown"; done
# Y5: MUTATION: the guard that reads only the default subject must reject acme-c- from acme-internal
mkdir -p "$T/mut3"; sed 's/allowed = ctx.get("subjects") or \[ctx\["guard_prefix"\]\]/allowed = [ctx["guard_prefix"]]/' "$H/naming.py" > "$T/mut3/naming.py"
if grep -q 'allowed = \[ctx\["guard_prefix"\]\]' "$T/mut3/naming.py"; then ok "mutation Y5: the copy reads only the default"; else ko "mutation Y5: sed did not apply the mutation"; fi
eq "mutation Y5: without the list acme-c-4201 from acme-internal is rejected (Y1 measures the list)" "$(mchk "$T/mut3/naming.py" /x/acme-internal acme-c-4201-sync-report-rows-fix)" "1"
eq "mutation Y5: control, acme-i-3307 passes in both" "$(mchk "$T/mut3/naming.py" /x/acme-internal acme-i-3307-build-tool-setup)$(mchk "$H/naming.py" /x/acme-internal acme-i-3307-build-tool-setup)" "00"

echo "== Z: tmux window (the hook decides from the current name, with a fake tmux; mutation on the predicate) =="
mkdir -p "$T/ftmux"
cat > "$T/ftmux/tmux" <<'SH'
#!/bin/sh
[ -n "$FAKE_WIN" ] || exit 1
printf '%s\n' "$FAKE_WIN"
SH
chmod +x "$T/ftmux/tmux"
ZN=30
# zctx <cwd> <"auto name"> [pane] [stk]: the default pane is %1; "-" leaves it empty
zctx(){ ZN=$((ZN+1)); local pane="${3:-%1}"; [ "$pane" = "-" ] && pane=""
  printf '{"session_id":"99999999-0000-0000-0000-0000000000%s","source":"startup","cwd":"%s"}' "$ZN" "$1" \
    | PATH="$T/ftmux:$PATH" FAKE_WIN="$2" TMUX_PANE="$pane" bash "${4:-$STK}" hook 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext'; }
RN='tmux rename-window -t "$TMUX_PANE"'
zyes(){ local o; o=$(zctx "$2" "$3"); if has "$o" "$RN $4"; then ok "tmux $1"; else ko "tmux $1: rename to $4 missing"; fi; }
zno(){ local o; o=$(zctx "$2" "$3"); if has "$o" "$RN"; then ko "tmux $1: asks to rename"; elif has "$o" 'Do not rename it'; then ok "tmux $1"; else ko "tmux $1: prohibition missing"; fi; }
zyes "Z1: never named, renamed with the subject" /x/foo-repo "1 claude" 'foo-<issue number>, or foo-<short slug>'
zyes "Z2: <prefix>-<number>, renamed" /x/foo-repo "0 foo-123" 'foo-<issue number>'
zno "Z3: the prefix alone stays" /x/foo-repo "0 foo"
zno "Z4: <prefix>-<slug> stays" /x/foo-repo "0 foo-chief"
zno "Z5: name with another prefix stays" /x/foo-repo "0 c-380"
zno "Z6: free name with a space stays" /x/foo-repo "0 my window"
zno "Z6b: the name is read in full, even if it ends in the form" /x/foo-repo "0 my foo-12"
zno "Z7: a number that follows the form only in part stays" /x/foo-repo "0 foo-123-bis"
zyes "Z8: window_prefix shortens the subject, even with several allowed subjects" /x/acme-internal "1 claude" 'a-<issue number>, or a-<short slug>'
zyes "Z9: window_prefix applies to the <key>-* subjects" /x/customer-desk "0 a-12" 'a-<issue number>'
zno "Z10: with window_prefix the long subject is no longer the form" /x/acme-internal "0 acme-i-12"
OUTZ=$(zctx /x/acme-internal "1 claude"); if has "$OUTZ" 'acme-i-<issue' || has "$OUTZ" ' or a-<issue'; then ko "tmux Z8b: two prefixes for the same abbreviation"; else ok "tmux Z8b: a single prefix"; fi
zyes "Z11: real-target, never named: the session derives the subject" /x/infra "1 claude" '<subject>-<issue number>'
zno "Z12: real-target, existing name: stays" /x/infra "0 infra-12"
OUTZ=$(zctx /x/foo-repo "0 foo"); if has "$OUTZ" 'A new window that you open for this project is called foo-<issue number>'; then ok "tmux Z13: the form of the new windows arrives even if the current one stays"; else ko "tmux Z13: form of the new windows missing"; fi
OUTZ=$(hookctx 99999999-0000-0000-0000-000000000051 /x/foo-repo); if has "$OUTZ" 'rename-window' || has "$OUTZ" 'A new window'; then ko "tmux Z14: clause outside tmux"; elif has "$OUTZ" 'Naming context'; then ok "tmux Z14: outside tmux no clause"; else ko "tmux Z14: hook without context"; fi
OUTZ=$(zctx /x/foo-repo ""); if has "$OUTZ" 'rename-window' || has "$OUTZ" 'Do not rename it'; then ko "tmux Z15: clause with failed tmux"; else ok "tmux Z15: tmux failed, no clause"; fi
if has "$OUTZ" 'Naming context'; then ok "tmux Z15: the rest of the context stays"; else ko "tmux Z15: naming context lost"; fi
OUTZ=$(zctx /x/foo-repo "1 claude" -); if has "$OUTZ" 'rename-window'; then ko "tmux Z16: empty \$TMUX_PANE queries tmux"; elif has "$OUTZ" 'Naming context'; then ok "tmux Z16: empty \$TMUX_PANE, no clause"; else ko "tmux Z16: hook without context"; fi
printf 'contexts: {foo-repo: foo}\nwindow_prefix: [a]\n' > "$T/badwp.yaml"
OUTZ=$($PY "$H/naming.py" context --text --cwd /x/foo-repo --naming-map "$T/badwp.yaml" --window-auto=1 --window-name=claude 2>/dev/null)
if has "$OUTZ" 'window_prefix' && ! has "$OUTZ" 'rename-window'; then ok "tmux Z17: malformed window_prefix declared, no rename"; else ko "tmux Z17: malformed window_prefix not handled"; fi
zyes "Z20: kb-tier, never named: the session derives the subject" /h/wiki/alpha/acme/sub "1 claude" '<subject>-<issue number>'
zno "Z20: kb-tier, existing name: stays" /h/wiki/alpha/acme/sub "0 wk-al-12"
zyes "Z26: worktree <entry>-<slug>, the prefix is the entry's" /x/acme-internal-foo "0 a-12" 'a-<issue number>'
zyes "Z27: kb-org, the prefix is the org's" /h/wiki/teams/acme "0 a-12" 'a-<issue number>'
OUTZ=$(zctx /x/foo-repo "1 claude"); if has "$OUTZ" "or foo-<short slug> if there is no issue"; then ok "tmux Z29: the slug only if there is no issue"; else ko "tmux Z29: criterion between number and slug missing"; fi
zyes "Z25: unknown folder, never named: the session derives the subject" /x/zzz-unknown "1 claude" '<subject>-<issue number>'
zno "Z25: unknown folder, existing name: stays" /x/zzz-unknown "0 zzz-unknown-12"
zyes "Z21: {N} in the subject counts as a number" /x/lab-game "0 exp3-12" 'exp{N}-<issue number>'
zno "Z21: {N} does not apply to a name without a number" /x/lab-game "0 expX-12"
zmap(){ printf '%s\n' "$1" > "$T/wp.yaml"; $PY "$H/naming.py" context --text --cwd "$2" --naming-map "$T/wp.yaml" --window-auto="$3" --window-name="$4" 2>/dev/null; }
OUTZ=$(zmap 'contexts: {nest: acme-kb-meta}
window_prefix: {acme: a, acme-kb: k}' /x/nest 1 claude); if has "$OUTZ" "$RN k-<issue"; then ok "tmux Z22: nested keys, the longest wins"; else ko "tmux Z22: short key chosen"; fi
OUTZ=$(zmap 'contexts: {nest: acme-kb-meta}
window_prefix: {acme-kb: k, acme: a}' /x/nest 1 claude); if has "$OUTZ" "$RN k-<issue"; then ok "tmux Z22: also with the keys reversed"; else ko "tmux Z22: the order in the file decides"; fi
OUTZ=$(zmap 'contexts: {multi: [x, y]}' /x/multi 0 y-12); if has "$OUTZ" "$RN x-<issue number>, or x-<short slug> or y-<issue"; then ok "tmux Z23: the second allowed subject counts too"; else ko "tmux Z23: only the first subject counts"; fi
for v in 'foo: ""' 'foo: 7' 'foo: true' 'foo: [a, b]' 'foo: ~' '7: a' 'true: a' 'foo: "$(id)"' 'foo: "f g"'; do
  OUTZ=$(zmap "contexts: {foo-repo: foo}
window_prefix: {$v}" /x/foo-repo 1 claude)
  if has "$OUTZ" 'window_prefix' && has "$OUTZ" 'Naming context' && ! has "$OUTZ" 'rename-window'; then ok "tmux Z24: window_prefix {$v} declared, the rest of the context stays"; else ko "tmux Z24: {$v} not handled"; fi
  if $PY "$H/naming.py" check --cwd /x/foo-repo --name foo-thing-fix --naming-map "$T/wp.yaml" --naming-md "$H/../references/naming.md" >/dev/null 2>&1; then ok "tmux Z24: {$v} does not stop the guard on the name"; else ko "tmux Z24: {$v} stops the guard on the name"; fi
done
OUTZ=$(zmap 'contexts: {x: foo}
window_prefix: {foo: f}' /x/x 0 f-12); if has "$OUTZ" "$RN f-<issue"; then ok "tmux Z28: subject equal to the key"; else ko "tmux Z28: subject equal to the key ignored"; fi
OUTZ=$(zmap 'contexts: {x: foobar}
window_prefix: {foo: f}' /x/x 1 claude); if has "$OUTZ" "$RN foobar-<issue"; then ok "tmux Z28: the key does not capture a subject that starts the same"; else ko "tmux Z28: key without hyphen"; fi
OUTZ=$(zmap 'contexts: [a]' /x/foo-repo 1 claude); if has "$OUTZ" "NOT resolvable" && ! has "$OUTZ" 'rename-window'; then ok "tmux Z30: broken map, no clause on the window"; else ko "tmux Z30: clause with the broken map"; fi
# Z18: MUTATION of the predicate: without the check on the name Z3 must fall, and Z1 stay the same
mkdir -p "$T/mut4/bin" "$T/mut4/helpers"; cp "$STK" "$T/mut4/bin/stk"; cp "$H"/*.py "$T/mut4/helpers/"; mkdir -p "$T/mut4/references"; cp "$H/../references/naming.md" "$T/mut4/references/"
sed -i.bak 's/if auto == "1" or numbered:/if True:/' "$T/mut4/helpers/naming.py"
if grep -q '    if True:$' "$T/mut4/helpers/naming.py"; then ok "mutation Z18: the copy is without the predicate"; else ko "mutation Z18: sed did not apply"; fi
OUTZ=$(zctx /x/foo-repo "0 foo" %1 "$T/mut4/bin/stk"); if has "$OUTZ" "$RN"; then ok "mutation Z18: without the predicate the user's name would be renamed (Z3 measures the predicate)"; else ko "mutation Z18: Z3 passes even without the predicate"; fi
OUTZ=$(zctx /x/foo-repo "1 claude" %1 "$T/mut4/bin/stk"); if has "$OUTZ" "$RN foo-"; then ok "mutation Z18: control, the never-named one is renamed in the copy too"; else ko "mutation Z18: control fell"; fi
# Z19: MUTATION of the check on an empty $TMUX_PANE: in the copy the clause must appear
mkdir -p "$T/mut5/bin"; ln -s "$T/mut4/helpers" "$T/mut5/helpers"; ln -s "$T/mut4/references" "$T/mut5/references"; cp "$H/naming.py" "$T/mut4/helpers/naming.py"
sed 's/if \[\[ -n "${TMUX_PANE:-}" \]\] && _hook_on hook_tmux_tab "$STK_HOOK_TMUX_TAB"; then/if true; then/' "$STK" > "$T/mut5/bin/stk"
if grep -q '^ *if true; then$' "$T/mut5/bin/stk"; then ok "mutation Z19: the copy is without the check"; else ko "mutation Z19: sed did not apply"; fi
OUTZ=$(zctx /x/foo-repo "1 claude" - "$T/mut5/bin/stk"); if has "$OUTZ" "$RN"; then ok "mutation Z19: without the check an empty pane queries tmux (Z16 measures the check)"; else ko "mutation Z19: Z16 passes even without the check"; fi

echo "== AA: node config (zero-config, file, precedence, canon_mode, canon_git, lists, fake ssh) =="
# Every case uses its own XDG_CONFIG_HOME: the suite's global config stays empty.
# ssh, and rsync when it has a host:path operand, are FAKE: they record the command line in
# $SSHLOG and exit 0. That way the ssh branch is proved on the positive without a network, and "no ssh"
# is measured on the log and not on a string in the output.
FAKEBIN="$T/fakebin"; SSHLOG="$T/ssh.log"; mkdir -p "$FAKEBIN"; : > "$SSHLOG"
REAL_RSYNC=$(command -v rsync)
printf '#!/usr/bin/env bash\nprintf "ssh %%s\\n" "$*" >> "%s"\nexit 0\n' "$SSHLOG" > "$FAKEBIN/ssh"
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *:*) printf "rsync %%s\\n" "$*" >> "%s"; exit 0;; esac; done\nexec "%s" "$@"\n' "$SSHLOG" "$REAL_RSYNC" > "$FAKEBIN/rsync"
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/rsync"
PATH="$FAKEBIN:$PATH" ssh canary-host true
if grep -q '^ssh canary-host true$' "$SSHLOG"; then ok "config AA0: the fake ssh is in PATH and records"; else ko "config AA0: fake ssh does not record"; fi
: > "$SSHLOG"
# base environment of the cases: no STK_CANON_* inherited from the suite, fake tools in front
AAENV(){ env -u STK_CANON_PATH -u STK_CANON_HOST -u STK_CANON_GIT PATH="$FAKEBIN:$PATH" "$@"; }

# AA1: zero-config = working single-node: local store under data_dir, no network, no git
ZC="$T/zc"; mkdir -p "$ZC"
zc(){ AAENV STK_LOCAL="$ZC" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" "$@"; }
SIDZ=aaaa0000-0000-0000-0000-0000000000aa
zc note --session "$SIDZ" --kind intent "zero config" >/dev/null 2>&1
zc publish >/dev/null 2>&1; rc=$?
eq "config AA1: zero-config publish exits 0" "$rc" "0"
if [ -f "$ZC/store/testnode/_unindexed/$SIDZ.md" ]; then ok "config AA1: the store is <data_dir>/store"; else ko "config AA1: record not in <data_dir>/store"; fi
if [ -f "$ZC/store/index.jsonl" ]; then ok "config AA1: index.jsonl in the local store"; else ko "config AA1: index.jsonl missing"; fi
if [ ! -s "$SSHLOG" ]; then ok "config AA1: no remote ssh or rsync call (empty log)"; else ko "config AA1: zero-config called: $(head -1 "$SSHLOG")"; fi
if zc dashboard >/dev/null 2>&1; then ok "config AA1: dashboard runs on the local store"; else ko "config AA1: dashboard fails"; fi
if zc dashboard --triage >/dev/null 2>&1; then ok "config AA1: dashboard --triage runs after publish"; else ko "config AA1: dashboard --triage fails"; fi
if [ ! -e "$T/canon/testnode/_unindexed/$SIDZ.md" ] && [ ! -e "$HOME/.local/session-tracker/store/testnode/_unindexed/$SIDZ.md" ]; then ok "config AA1: nothing written in the suite's canon nor in the home"; else ko "config AA1: write outside data_dir"; fi
# the default store inside a git repo that contains it (a home under git): with zero config
# publish must NOT commit nor push the records into that repo
git -C "$ZC" init -q; git -C "$ZC" config user.email t@t; git -C "$ZC" config user.name t
zc publish >/dev/null 2>&1
eq "config AA1: store inside a git repo, canon_git default off -> no commit" "$(git -C "$ZC" rev-list --count HEAD 2>/dev/null || echo 0)" "0"
# triage on a virgin store: the advice in local mode is stk index, not sync pull
OUTZ=$(AAENV STK_LOCAL="$T/zc-virgin" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" dashboard --triage 2>&1)
if printf '%s' "$OUTZ" | grep -q 'run first: stk index'; then ok "config AA1: triage on a virgin store recommends stk index"; else ko "config AA1: triage recommends something else: $OUTZ"; fi

# AA2: multi-node on a shared local store: two data_dir, two nodes, one index
MN="$T/mn"; mkdir -p "$MN"
mn(){ local n="$1"; shift; AAENV STK_LOCAL="$MN/$n" STK_NODE="$n" STK_CANON_PATH="$MN/store" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" "$@"; }
mn alpha note --session aaaa0000-0000-0000-0000-0000000000a1 --kind intent "alpha" >/dev/null 2>&1
mn bravo note --session aaaa0000-0000-0000-0000-0000000000b1 --kind intent "bravo" >/dev/null 2>&1
mn alpha publish >/dev/null 2>&1; mn bravo publish >/dev/null 2>&1
eq "config AA2: the index lists the two nodes" "$(jq -r .node "$MN/store/index.jsonl" | sort | paste -sd, -)" "alpha,bravo"
mn alpha sync pull >/dev/null 2>&1
if ls "$MN/alpha/canon/bravo/"*/*.md >/dev/null 2>&1; then ok "config AA2: pull on alpha mirrors bravo's records"; else ko "config AA2: mirror of the other node missing"; fi

# AA3: config file that reproduces an on-host canon at a chosen path
CF="$T/xdg-cf/session-tracker"; mkdir -p "$CF" "$T/cf"
printf '# test config\ncanon_mode = local\ncanon_path = "%s"\nknown_nodes = charlie, delta\nremote_aliases = "zulu"\ncanon_git = auto\n' "$T/cfstore" > "$CF/config"
cf(){ AAENV STK_LOCAL="$T/cf" XDG_CONFIG_HOME="$T/xdg-cf" bash "$STK" "$@"; }
SIDF=aaaa0000-0000-0000-0000-0000000000cf
cf note --session "$SIDF" --kind intent "from file" >/dev/null 2>&1
cf publish --no-push >/dev/null 2>&1
if [ -f "$T/cfstore/testnode/_unindexed/$SIDF.md" ]; then ok "config AA3: canon_path from the file (quotes removed)"; else ko "config AA3: canon_path from the file ignored"; fi
if [ ! -e "$T/cf/store" ]; then ok "config AA3: the default <data_dir>/store was not used"; else ko "config AA3: also written in the default"; fi
# precedence: the environment variable wins over the file; an EMPTY variable does not (counts as absent)
AAENV STK_LOCAL="$T/cf" STK_CANON_PATH="$T/envstore" XDG_CONFIG_HOME="$T/xdg-cf" bash "$STK" publish --no-push >/dev/null 2>&1
if [ -f "$T/envstore/testnode/_unindexed/$SIDF.md" ]; then ok "config AA3: STK_CANON_PATH wins over the file"; else ko "config AA3: env does not win over the file"; fi
SIDF2=aaaa0000-0000-0000-0000-0000000000c2
AAENV STK_LOCAL="$T/cf" STK_CANON_PATH= XDG_CONFIG_HOME="$T/xdg-cf" bash "$STK" note --session "$SIDF2" --kind intent "empty env" >/dev/null 2>&1
AAENV STK_LOCAL="$T/cf" STK_CANON_PATH= XDG_CONFIG_HOME="$T/xdg-cf" bash "$STK" publish --no-push >/dev/null 2>&1
if [ -f "$T/cfstore/testnode/_unindexed/$SIDF2.md" ] && [ ! -e "$T/cf/store" ]; then ok "config AA3: empty STK_CANON_PATH = absent, the file wins"; else ko "config AA3: empty env overrode the file"; fi
# node key: applies when STK_NODE is not set
mkdir -p "$T/xdg-node/session-tracker"; printf 'node = xray\n' > "$T/xdg-node/session-tracker/config"
SIDN=aaaa0000-0000-0000-0000-0000000000de
# (not AAENV: after an assignment `env` reads `-u` as the command to run)
env -u STK_CANON_PATH -u STK_CANON_HOST -u STK_CANON_GIT -u STK_NODE PATH="$FAKEBIN:$PATH" STK_LOCAL="$T/nodecfg" XDG_CONFIG_HOME="$T/xdg-node" bash "$STK" note --session "$SIDN" --kind intent "n" >/dev/null 2>&1
eq "config AA3: node key from the file (bash)"   "$(fmget "$T/nodecfg/shard/_unindexed/$SIDN.md" node)" "xray"
eq "config AA3: node key from the file (python)" "$(env -u STK_NODE XDG_CONFIG_HOME="$T/xdg-node" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; print(config.load()['node'])" "$H")" "xray"
eq "config AA3: STK_NODE wins over the node key (python)" "$(STK_NODE=envnode XDG_CONFIG_HOME="$T/xdg-node" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; print(config.load()['node'])" "$H")" "envnode"
SIDN2=aaaa0000-0000-0000-0000-0000000000df
AAENV STK_NODE=envnode STK_LOCAL="$T/nodecfg" XDG_CONFIG_HOME="$T/xdg-node" bash "$STK" note --session "$SIDN2" --kind intent "n" >/dev/null 2>&1
eq "config AA3: STK_NODE wins over the node key (bash)" "$(fmget "$T/nodecfg/shard/_unindexed/$SIDN2.md" node)" "envnode"
# the node key also reaches merge.py (invoked directly by the skill) and triage.py
mkdir -p "$T/nodemerge"; printf '{"session_id":"%s","encoded_project":"-nm","project":"nm","project_path":"/nm","git_branch":"main","started_at":"2026-06-07T08:00:00Z","last_activity_at":"2026-06-07T09:00:00Z","last_uuid":"u1","n_events":5,"forked_from":null,"pilot_candidates":[],"custom_title":"nm-x"}\n' "$SIDN" > "$T/nodemerge/manifest.jsonl"
printf '{"session_id":"%s","lang":"it","goal":"g","summary":"s","done":[],"open":[],"decisions":[],"internal_branches":[],"pilot_candidates":[],"proposed_status":"active","tags":[]}\n' "$SIDN" > "$T/nodemerge/dg.jsonl"
env -u STK_NODE -u STK_CANON_PATH -u STK_CANON_HOST STK_LOCAL="$T/nodemerge" XDG_CONFIG_HOME="$T/xdg-node" $PY "$H/merge.py" "$T/nodemerge/dg.jsonl" >/dev/null 2>&1
eq "config AA3: node key read by merge.py" "$(fmget "$T/nodemerge/shard/-nm/$SIDN.md" node)" "xray"
env -u STK_CANON_PATH -u STK_CANON_HOST -u STK_CANON_GIT -u STK_NODE PATH="$FAKEBIN:$PATH" STK_LOCAL="$T/nodecfg" XDG_CONFIG_HOME="$T/xdg-node" bash "$STK" publish >/dev/null 2>&1
OUTN=$(env -u STK_CANON_PATH -u STK_CANON_HOST -u STK_CANON_GIT -u STK_NODE PATH="$FAKEBIN:$PATH" STK_LOCAL="$T/nodecfg" XDG_CONFIG_HOME="$T/xdg-node" bash "$STK" dashboard --triage 2>&1)
if printf '%s' "$OUTN" | grep -q 'local node: xray'; then ok "config AA3: node key read by triage.py"; else ko "config AA3: triage ignores the node key: $(printf '%s' "$OUTN" | grep -o 'local node: [a-z0-9]*')"; fi
# bash/Python parity on the file: non-UTF-8 bytes in a comment, trailing U+00A0, `~/` in the local
# paths (fake HOME), `~/` also from env. Same resolved value in the two parsers, and Python does not fall.
mkdir -p "$T/xdg-par/session-tracker" "$T/parhome"
printf '# caff\xe8\ncanon_mode = local\ncanon_path = ~/cp\xc2\xa0\nknown_nodes = echo\n' > "$T/xdg-par/session-tracker/config"
PARB=$(env -u STK_CANON_PATH -u STK_CANON_HOST HOME="$T/parhome" STK_LOCAL='~/dd' XDG_CONFIG_HOME="$T/xdg-par" bash -c 'source "$1"; printf "%s|%s|%s" "$STK_LOCAL" "$STK_CANON_PATH" "$STK_KNOWN_NODES"' _ "$CFGBLOCK")
PARP=$(env -u STK_CANON_PATH -u STK_CANON_HOST HOME="$T/parhome" STK_LOCAL='~/dd' XDG_CONFIG_HOME="$T/xdg-par" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; c=config.load(); print(c['data_dir']+'|'+c['canon_path']+'|'+' '.join(c['known_nodes']), end='')" "$H" 2>&1)
eq "config AA3: bash/python parity (non-UTF-8 bytes, U+00A0, local ~/)" "$PARP" "$PARB"
eq "config AA3: ~/ expanded with HOME in the local paths"  "$PARB" "$T/parhome/dd|$T/parhome/cp"$'\xc2\xa0'"|echo"

# AA4: canon_mode decides by itself, and a broken config stops only the subcommands on the canon
CB="$T/xdg-bad/session-tracker"; mkdir -p "$CB"
bad(){ AAENV STK_LOCAL="$T/bad" XDG_CONFIG_HOME="$T/xdg-bad" bash "$STK" "$@"; }
printf 'canon_mode=ssh\n' > "$CB/config"
OUTB=$(bad sync pull 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$OUTB" | grep -q 'canon_host'; then ok "config AA4: canon_mode=ssh without canon_host rejected, and the message names the key"; else ko "config AA4: ssh without host accepted (rc=$rc: $OUTB)"; fi
printf 'canon_mode=ssh\ncanon_host=hubx\n' > "$CB/config"
OUTB=$(bad index 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$OUTB" | grep -q 'canon_path'; then ok "config AA4: canon_mode=ssh without canon_path rejected (the local default does not apply on the host)"; else ko "config AA4: ssh without canon_path accepted (rc=$rc: $OUTB)"; fi
if [ ! -s "$SSHLOG" ]; then ok "config AA4: the incomplete config stops before any ssh"; else ko "config AA4: ssh called with an incomplete config"; fi
printf 'canon_mode=bogus\n' > "$CB/config"
OUTB=$(bad index 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$OUTB" | grep -q 'invalid canon_mode'; then ok "config AA4: unknown canon_mode rejected"; else ko "config AA4: canon_mode bogus accepted"; fi
if bad note --session aaaa0000-0000-0000-0000-0000000000b4 --kind intent "x" >/dev/null 2>&1; then ok "config AA4: note does not depend on the canon (a broken config does not stop it)"; else ko "config AA4: note stopped by a canon config"; fi
# canon folder EXISTING locally but mode=ssh: it is the mode that decides, not the folder
mkdir -p "$T/bad/existing-store"
printf 'canon_mode=ssh\ncanon_host=hubx\ncanon_path=%s\n' "$T/bad/existing-store" > "$CB/config"
: > "$SSHLOG"; bad index >/dev/null 2>&1
if grep -q '^ssh hubx ' "$SSHLOG" && [ ! -f "$T/bad/existing-store/index.jsonl" ]; then ok "config AA4: with mode=ssh the index goes to the host and does not write locally even if the folder exists"; else ko "config AA4: mode=ssh wrote locally or did not call ssh"; fi

# AA5: canon_git. Store inside a git repo that contains it: off (default) does not commit, auto does
GO="$T/gitoff"; mkdir -p "$GO/store"; git -C "$GO" init -q; git -C "$GO" config user.email t@t; git -C "$GO" config user.name t
go(){ AAENV STK_LOCAL="$GO/local" STK_CANON_PATH="$GO/store" XDG_CONFIG_HOME="$T/xdg-none" "$@"; }
go bash "$STK" note --session aaaa0000-0000-0000-0000-0000000000a5 --kind intent "g" >/dev/null 2>&1
go bash "$STK" publish >/dev/null 2>&1; rc=$?
eq "config AA5: publish with the default canon_git exits 0" "$rc" "0"
eq "config AA5: canon_git default off -> no commit in the repo that contains the store" "$(git -C "$GO" rev-list --count HEAD 2>/dev/null || echo 0)" "0"
if [ -f "$GO/store/index.jsonl" ]; then ok "config AA5: the index is regenerated anyway"; else ko "config AA5: index skipped"; fi
go env STK_CANON_GIT=off bash "$STK" publish >/dev/null 2>&1
eq "config AA5: explicit canon_git=off, no commit" "$(git -C "$GO" rev-list --count HEAD 2>/dev/null || echo 0)" "0"
go env STK_CANON_GIT=auto bash "$STK" publish --no-push >/dev/null 2>&1
eq "config AA5: with canon_git=auto the commit is there" "$(git -C "$GO" rev-list --count HEAD 2>/dev/null || echo 0)" "1"
if go env STK_CANON_GIT=maybe bash "$STK" index >/dev/null 2>&1; then ko "config AA5: canon_git bogus accepted"; else ok "config AA5: canon_git bogus rejected"; fi

# AA6: known_nodes makes verifiable a primary that the index does not name
mkdir -p "$T/kn"; : > "$T/kn/empty.jsonl"
printf '## Node ownership\n- Primary: charlie (`/home/u/code/x`)\n- Secondaries: testnode (`/x`)\n' > "$T/kn/CLAUDE.md"
kn(){ AAENV STK_LOCAL="$T/cf" XDG_CONFIG_HOME="$1" bash "$STK" where --node testnode --cwd "$T/kn" --index "$T/kn/empty.jsonl" --naming-map "$T/kn/none.yaml"; }
J=$(kn "$T/xdg-cf")
eq "config AA6: known_nodes from the file -> known primary"   "$(echo "$J"|jq -r '.current.ownership.primary_known')" "true"
eq "config AA6: confidence high"                        "$(echo "$J"|jq -r '.candidates[0].confidence')" "high"
J=$(kn "$T/xdg-none")
eq "config AA6: without known_nodes -> primary not known"  "$(echo "$J"|jq -r '.current.ownership.primary_known')" "false"
J=$(AAENV STK_LOCAL="$T/cf" STK_KNOWN_NODES="charlie" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" where --node testnode --cwd "$T/kn" --index "$T/kn/empty.jsonl" --naming-map "$T/kn/none.yaml")
eq "config AA6: STK_KNOWN_NODES via env"                "$(echo "$J"|jq -r '.current.ownership.primary_known')" "true"

# AA7: remote_aliases is the allowlist of the pilots in merge.py (empty list = no pilot).
# merge.py is invoked directly, as the skill does: here the Python parser is measured.
RA="$T/ra"; mkdir -p "$RA"
SIDR=aaaa0000-0000-0000-0000-0000000000ca
cat > "$RA/manifest.jsonl" <<EOF
{"session_id":"$SIDR","encoded_project":"-ra","project":"ra","project_path":"/ra","git_branch":"main","started_at":"2026-06-07T08:00:00Z","last_activity_at":"2026-06-07T09:00:00Z","last_uuid":"u1","n_events":5,"forked_from":null,"pilot_candidates":["zulu","yankee"],"custom_title":"ra-x"}
EOF
cat > "$RA/dg.jsonl" <<EOF
{"session_id":"$SIDR","lang":"it","goal":"g","summary":"s","done":[],"open":[],"decisions":[],"internal_branches":[],"pilot_candidates":["zulu","yankee"],"proposed_status":"active","tags":[]}
EOF
pilots_of(){ $PY -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]).read().split('---')[1]);print(','.join(p['node'] for p in d.get('pilots') or []))" "$RA/shard/-ra/$SIDR.md"; }
ra(){ AAENV STK_LOCAL="$RA" STK_NODE=testnode XDG_CONFIG_HOME="$1" "${@:2}" $PY "$H/merge.py" "$RA/dg.jsonl"; }
ra "$T/xdg-none" >/dev/null 2>&1
eq "config AA7: without remote_aliases no pilot" "$(pilots_of)" ""
rm -rf "$RA/shard"; ra "$T/xdg-cf" >/dev/null 2>&1   # remote_aliases = "zulu" in the file: yankee stays out
eq "config AA7: with remote_aliases=\"zulu\" (quotes) only zulu passes" "$(pilots_of)" "zulu"
rm -rf "$RA/shard"; ra "$T/xdg-cf" env STK_REMOTE_ALIASES= >/dev/null 2>&1
eq "config AA7: empty STK_REMOTE_ALIASES = absent, the file wins (python)" "$(pilots_of)" "zulu"
rm -rf "$RA/shard"; ra "$T/xdg-cf" env STK_REMOTE_ALIASES=yankee >/dev/null 2>&1
eq "config AA7: non-empty STK_REMOTE_ALIASES wins over the file (python)" "$(pilots_of)" "yankee"

# AA8: secondary with a remote canon: every command on the canon goes through the fake
# host and nothing is written locally
mkdir -p "$T/xdg-t2/session-tracker"
printf 'canon_mode = ssh\ncanon_host = hubx\ncanon_path = /srv/sessions\ncanon_git = auto\n' > "$T/xdg-t2/session-tracker/config"
t2(){ AAENV STK_LOCAL="$T/t2" XDG_CONFIG_HOME="$T/xdg-t2" bash "$STK" "$@"; }
: > "$SSHLOG"
t2 note --session aaaa0000-0000-0000-0000-0000000000e2 --kind intent "t2" >/dev/null 2>&1
t2 sync publish >/dev/null 2>&1
if grep -q '^ssh hubx mkdir -p /srv/sessions/testnode$' "$SSHLOG"; then ok "config AA8: sync publish creates the node folder on the host"; else ko "config AA8: remote mkdir missing"; fi
if grep -q '^rsync -a .*/t2/shard/ hubx:/srv/sessions/testnode/$' "$SSHLOG"; then ok "config AA8: sync publish rsync to the host"; else ko "config AA8: rsync to the host missing"; fi
: > "$SSHLOG"; t2 index >/dev/null 2>&1
if grep -q '^ssh hubx flock /srv/sessions/.stk.lock uv run .* python - /srv/sessions$' "$SSHLOG"; then ok "config AA8: index runs on the host under lock"; else ko "config AA8: remote index missing: $(cat "$SSHLOG")"; fi
: > "$SSHLOG"; t2 publish --no-push >/dev/null 2>&1
if grep -q "^ssh hubx flock /srv/sessions/.stk.lock bash -s -- /srv/sessions .* 0$" "$SSHLOG"; then ok "config AA8: publish commits on the host (canon_git=auto) and --no-push reaches the host"; else ko "config AA8: remote commit missing or --no-push lost: $(cat "$SSHLOG")"; fi
: > "$SSHLOG"; t2 publish >/dev/null 2>&1
if grep -q "^ssh hubx flock /srv/sessions/.stk.lock bash -s -- /srv/sessions .* 1$" "$SSHLOG"; then ok "config AA8: without --no-push the host gets the push"; else ko "config AA8: push not requested from the host: $(cat "$SSHLOG")"; fi
: > "$SSHLOG"; AAENV STK_LOCAL="$T/t2" STK_CANON_GIT=off XDG_CONFIG_HOME="$T/xdg-t2" bash "$STK" publish >/dev/null 2>&1
if grep -q '^ssh hubx flock /srv/sessions/.stk.lock uv run' "$SSHLOG" && ! grep -q 'bash -s --' "$SSHLOG"; then ok "config AA8: canon_git=off in ssh: index on the host, no git"; else ko "config AA8: off in ssh touched git or skipped the index: $(cat "$SSHLOG")"; fi
# `~/` in canon_path with ssh stays literal: it is the HOST's home that must expand it
mkdir -p "$T/xdg-t3/session-tracker"; printf 'canon_mode = ssh\ncanon_host = hubx\ncanon_path = ~/sessions\n' > "$T/xdg-t3/session-tracker/config"
: > "$SSHLOG"; AAENV STK_LOCAL="$T/t3" XDG_CONFIG_HOME="$T/xdg-t3" bash "$STK" index >/dev/null 2>&1
if grep -q '^ssh hubx flock ~/sessions/.stk.lock uv run .* python - ~/sessions$' "$SSHLOG"; then ok "config AA8: ~/ in canon_path with ssh is not expanded with the local home"; else ko "config AA8: ~/ expanded locally and sent to the host: $(cat "$SSHLOG")"; fi
: > "$SSHLOG"; t2 dashboard >/dev/null 2>&1
if grep -q '^ssh hubx .*python - /srv/sessions$' "$SSHLOG"; then ok "config AA8: dashboard runs on the host"; else ko "config AA8: remote dashboard missing"; fi
: > "$SSHLOG"; t2 sync pull >/dev/null 2>&1
if grep -q '^rsync -au hubx:/srv/sessions/testnode/ ' "$SSHLOG" && grep -q '^rsync -a --delete --exclude=.git hubx:/srv/sessions/ ' "$SSHLOG"; then ok "config AA8: sync pull downloads the node slice and the mirror from the host"; else ko "config AA8: incomplete remote pull: $(cat "$SSHLOG")"; fi
if [ ! -e "$T/t2/store" ] && [ ! -e "/srv/sessions/testnode" ]; then ok "config AA8: in ssh no local store"; else ko "config AA8: local store created in ssh mode"; fi
OUTT=$(t2 dashboard --triage 2>&1)
if printf '%s' "$OUTT" | grep -q 'run first: stk sync pull'; then ok "config AA8: triage without a mirror recommends stk sync pull"; else ko "config AA8: triage in ssh recommends something else: $OUTT"; fi

echo "== AB: hook clauses and naming policy from the config (defaults off, warn, overlay, naming_map, kb_tiers) =="
# environment of the cases: no STK_HOOK_*/STK_NAMING_* inherited from the suite, own XDG per case
ABENV(){ env -u STK_HOOK_ASK_INTENT -u STK_HOOK_PLACEMENT -u STK_HOOK_PRIMARY_CHECK -u STK_HOOK_TMUX_TAB -u STK_NAMING_POLICY -u STK_NAMING_MAP -u STK_HOOK_EXTRA_CONTEXT_FILE -u STK_CANON_PATH -u STK_CANON_HOST -u STK_CANON_GIT -u TMUX_PANE "$@"; }
abhook(){ # <xdg> <sid> <source> [cwd]: additionalContext (empty if the hook emits nothing)
  printf '{"session_id":"%s","source":"%s","cwd":"%s"}' "$2" "$3" "${4:-/x/foo-repo}" | ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$1" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty'; }
mkdir -p "$T/ab" "$T/xdg-none"; cp "$STK_LOCAL/naming-map.yaml" "$T/ab/naming-map.yaml"
AB=bbbb0000-0000-0000-0000-0000000000
# AB1: zero-config at startup: no intent, placement, primary-check, tmux window; the name proposal stays (warn)
OUTB=$(abhook "$T/xdg-none" "${AB}01" startup)
if has "$OUTB" 'stk note'; then ko "hook AB1: zero-config asks for the intent"; else ok "hook AB1: zero-config does not ask for the intent"; fi
if has "$OUTB" 'stk where'; then ko "hook AB1: zero-config has the placement clause"; else ok "hook AB1: zero-config without placement"; fi
if has "$OUTB" 'primary-check'; then ko "hook AB1: zero-config has the primary-check clause"; else ok "hook AB1: zero-config without primary-check"; fi
if has "$OUTB" '/rename wip-' && has "$OUTB" 'row `foo-repo: foo`'; then ok "hook AB1: zero-config proposes the name with the context (naming_policy=warn)"; else ko "hook AB1: name proposal missing by default: $OUTB"; fi
if has "$OUTB" 'but accepts it (naming_policy=warn)'; then ok "hook AB1: the text says that close reports and accepts"; else ko "hook AB1: the text does not state the warn policy: $OUTB"; fi
if has "$OUTB" 'rejects it if it does not respect'; then ko "hook AB1: the text says that close rejects (it is warn)"; else ok "hook AB1: the text does not promise a rejection"; fi
case "$OUTB" in "If the session title"*) ok "hook AB1: the context starts from the first clause that is on (no space or 'Finally')";; *) ko "hook AB1: the context starts badly: ${OUTB:0:40}";; esac
# AB1b: inside tmux by default the window is left alone (hook_tmux_tab=off), even if the fake says "never named"
OUTB=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AB}02" | ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" PATH="$T/ftmux:$PATH" FAKE_WIN="1 claude" TMUX_PANE="%1" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')
if has "$OUTB" 'rename-window' || has "$OUTB" 'A new window'; then ko "hook AB1b: hook_tmux_tab=off but the window clause is there"; else ok "hook AB1b: hook_tmux_tab=off, no window clause inside tmux"; fi
# AB2: naming_policy=off from the file + everything off: at startup the hook emits nothing, at resume only the branch
mkdir -p "$T/xdg-off/session-tracker"; printf 'naming_policy = off\n' > "$T/xdg-off/session-tracker/config"
OUTB=$(abhook "$T/xdg-off" "${AB}03" startup)
eq "hook AB2: everything off at startup -> no injection" "$OUTB" ""
if grep -q "^.*	${AB:0:8}	startup	skip:nothing-to-inject$" "$T/ab/hook.log"; then ok "hook AB2: the log says skip:nothing-to-inject"; else ko "hook AB2: log without the decision: $(tail -1 "$T/ab/hook.log")"; fi
OUTB=$(abhook "$T/xdg-off" "${AB}04" resume)
if has "$OUTB" 'stk branch --register' && ! has "$OUTB" '/rename'; then ok "hook AB2: at resume only the branch clause (core) remains"; else ko "hook AB2: resume with everything off: $OUTB"; fi
case "$OUTB" in "Finally, if this session"*) ok "hook AB2: no leading space when it is the only clause";; *) ko "hook AB2: starts with: ${OUTB:0:30}";; esac
# AB3: keys from the file: intent on, placement on, policy error -> clauses present and rejection text
mkdir -p "$T/xdg-on/session-tracker"; printf 'hook_ask_intent = on\nhook_placement = on\nnaming_policy = error\n' > "$T/xdg-on/session-tracker/config"
OUTB=$(abhook "$T/xdg-on" "${AB}05" startup)
if has "$OUTB" "stk note --session ${AB}05 --kind intent"; then ok "hook AB3: hook_ask_intent=on from the file"; else ko "hook AB3: intent missing: $OUTB"; fi
if has "$OUTB" 'stk where --current' && ! has "$OUTB" 'primary-check'; then ok "hook AB3: placement on, primary-check off"; else ko "hook AB3: wrong clauses: $OUTB"; fi
if has "$OUTB" 'rejects it if it does not respect'; then ok "hook AB3: with error the text says that close rejects"; else ko "hook AB3: text for error missing"; fi
case "$OUTB" in "No intent recorded"*) ok "hook AB3: the intent opens the context";; *) ko "hook AB3: starts with: ${OUTB:0:30}";; esac
# AB3b: primary-check on by itself: the clause stands without the placement one
mkdir -p "$T/xdg-pc/session-tracker"; printf 'hook_primary_check = on\nnaming_policy = off\n' > "$T/xdg-pc/session-tracker/config"
OUTB=$(abhook "$T/xdg-pc" "${AB}06" startup)
if has "$OUTB" 'If stk where --current' && has "$OUTB" 'primary-check --current --human' && ! has "$OUTB" 'Then assess the placement'; then ok "hook AB3b: primary-check alone names stk where and does not depend on the placement"; else ko "hook AB3b: primary-check clause: $OUTB"; fi
# placement on without intent: the clause does not refer to an intent that nobody asks for
mkdir -p "$T/xdg-pl/session-tracker"; printf 'hook_placement = on\nnaming_policy = off\n' > "$T/xdg-pl/session-tracker/config"
OUTB=$(abhook "$T/xdg-pl" "${AB}14" startup)
case "$OUTB" in "Assess the placement: run stk where --current"*) ok "hook AB3c: placement without intent starts by itself, without 'after recording the intent'";; *) ko "hook AB3c: placement without intent: ${OUTB:0:80}";; esac
if has "$OUTB" "recording the intent"; then ko "hook AB3c: refers to the intent that is not asked for"; else ok "hook AB3c: no reference to the intent"; fi
# AB4: value outside on|off -> counts as off, and the log says so; env wins over the file
mkdir -p "$T/xdg-typo/session-tracker"; printf 'hook_ask_intent = yes\nnaming_policy = off\n' > "$T/xdg-typo/session-tracker/config"
OUTB=$(abhook "$T/xdg-typo" "${AB}07" startup)
eq "hook AB4: hook_ask_intent=yes counts as off (no injection)" "$OUTB" ""
if grep -q 'warn:hook_ask_intent=yes invalid' "$T/ab/hook.log"; then ok "hook AB4: the log reports the invalid value"; else ko "hook AB4: typo not logged"; fi
OUTB=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AB}08" | ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-typo" STK_HOOK_ASK_INTENT=on bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$OUTB" 'stk note'; then ok "hook AB4: STK_HOOK_ASK_INTENT=on wins over the file"; else ko "hook AB4: env does not win: $OUTB"; fi
mkdir -p "$T/xdg-ptypo/session-tracker"; printf 'naming_policy = strict\n' > "$T/xdg-ptypo/session-tracker/config"
OUTB=$(abhook "$T/xdg-ptypo" "${AB}09" startup)
if has "$OUTB" 'but accepts it (naming_policy=warn)' && grep -q 'warn:naming_policy=strict invalid' "$T/ab/hook.log"; then ok "hook AB4: naming_policy with a typo -> the hook counts it as warn and logs it"; else ko "hook AB4: naming_policy=strict in the hook: $OUTB"; fi
# AB5: hook_extra_context_file: text at the end; unreadable file -> the rest passes and the log says so
printf 'LOCAL RULE: answer in Piedmontese.\n' > "$T/extra.txt"
mkdir -p "$T/xdg-extra/session-tracker"; printf 'hook_ask_intent = on\nhook_extra_context_file = %s\n' "$T/extra.txt" > "$T/xdg-extra/session-tracker/config"
OUTB=$(abhook "$T/xdg-extra" "${AB}10" startup)
case "$OUTB" in "No intent"*"LOCAL RULE: answer in Piedmontese.") ok "hook AB5: the overlay text closes the context";; *) ko "hook AB5: overlay missing or out of place: ${OUTB: -60}";; esac
printf 'hook_ask_intent = on\nhook_extra_context_file = %s/missing.txt\n' "$T" > "$T/xdg-extra/session-tracker/config"
OUTB=$(abhook "$T/xdg-extra" "${AB}11" startup)
if has "$OUTB" 'stk note' && grep -q "warn:hook_extra_context_file=$T/missing.txt unreadable" "$T/ab/hook.log"; then ok "hook AB5: unreadable overlay, the rest passes and the log says so"; else ko "hook AB5: unreadable overlay: $OUTB / $(tail -1 "$T/ab/hook.log")"; fi
printf 'naming_policy = off\nhook_extra_context_file = ~/extra-home.txt\n' > "$T/xdg-extra/session-tracker/config"
mkdir -p "$T/abhome"; printf 'FROM HOME\n' > "$T/abhome/extra-home.txt"
OUTB=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AB}12" | ABENV HOME="$T/abhome" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-extra" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
eq "hook AB5: ~/ in hook_extra_context_file expanded; alone it is the whole context" "$OUTB" "FROM HOME"
# overlay of only spaces and newlines, alone: it is not a context, the hook emits nothing
printf '   \n\n' > "$T/abhome/extra-home.txt"
OUTB=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AB}13" | ABENV HOME="$T/abhome" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-extra" bash "$STK" hook 2>/dev/null)
eq "hook AB5: overlay of only spaces, alone -> no injection" "$OUTB" ""
if grep -q "^.*	${AB:0:8}	startup	skip:nothing-to-inject$" "$T/ab/hook.log"; then ok "hook AB5: the log says skip:nothing-to-inject here too"; else ko "hook AB5: log for the empty overlay: $(tail -1 "$T/ab/hook.log")"; fi
# AB6: close --name according to naming_policy (the sessions have cwd /x/foo-repo in the transcript: subject foo)
abclose(){ ABERR=$(ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$1" bash "$STK" close --session "$2" --status done "${@:3}" 2>&1 >/dev/null); }
EPB=$(mkw "${AB}21" /x/foo-repo)
if abclose "$T/xdg-none" "${AB}21" --name bar-thing-fix; then ok "close AB6: default warn, wrong subject accepted"; else ko "close AB6: default warn rejected: $ABERR"; fi
if has "$ABERR" "NOT compliant" && has "$ABERR" "foo-repo: foo" && has "$ABERR" "naming_policy=warn: accepted"; then ok "close AB6: warn reports the violated rule and says it accepts"; else ko "close AB6: warn message: $ABERR"; fi
eq "close AB6: warn writes the record with the name" "$(fmget "$T/ab/shard/$EPB/${AB}21.md" name)" "bar-thing-fix"
mkw "${AB}22" /x/foo-repo >/dev/null
if abclose "$T/xdg-none" "${AB}22" --name foo-thing-fix && has "$ABERR" "compliant (naming-map.yaml contexts: foo-repo: foo"; then ok "close AB6: warn, compliant name confirmed with the rule"; else ko "close AB6: compliant in warn: $ABERR"; fi
mkw "${AB}23" /x/foo-repo >/dev/null
if abclose "$T/xdg-off" "${AB}23" --name bar-thing-fix && has "$ABERR" "not checked (naming_policy=off)"; then ok "close AB6: off accepts and says it did not check"; else ko "close AB6: off: $ABERR"; fi
# AB6-inv: the record invariants (wip-, characters outside the lexicon) are refused with warn too:
# a closed record named wip-... contradicts its status, a name with spaces breaks the single
# spelling of the index. The subject and the action stay "report and accept" (AB6 above).
EPB7=$(mkw "${AB}64" /x/foo-repo)
if abclose "$T/xdg-none" "${AB}64" --name wip-foo-thing-fix; then ko "close AB6-inv: default warn ACCEPTED wip-"; else ok "close AB6-inv: default warn refuses wip-"; fi
if has "$ABERR" "starts with 'wip-'" && has "$ABERR" "refused with naming_policy=warn"; then ok "close AB6-inv: the refusal names the wip- rule and says warn refuses it too"; else ko "close AB6-inv: wip- message: $ABERR"; fi
if [ -e "$T/ab/shard/$EPB7/${AB}64.md" ]; then ko "close AB6-inv: record written despite the refusal"; else ok "close AB6-inv: no write on the wip- refusal"; fi
mkw "${AB}65" /x/foo-repo >/dev/null
if abclose "$T/xdg-none" "${AB}65" --name 'Foo Thing'; then ko "close AB6-inv: default warn ACCEPTED a name outside the lexicon"; else ok "close AB6-inv: default warn refuses a name outside the lexicon"; fi
if has "$ABERR" "outside the lexicon" && has "$ABERR" "refused with naming_policy=warn"; then ok "close AB6-inv: the refusal names the lexicon rule and says warn refuses it too"; else ko "close AB6-inv: lexicon message: $ABERR"; fi
if [ -e "$T/ab/shard/$EPB7/${AB}65.md" ]; then ko "close AB6-inv: record written despite the lexicon refusal"; else ok "close AB6-inv: no write on the lexicon refusal"; fi
mkw "${AB}66" /x/foo-repo >/dev/null
if abclose "$T/xdg-none" "${AB}66" --name wip-foo-thing-fix --force; then ko "close AB6-inv: --force PASSED wip-"; else ok "close AB6-inv: --force does not pass the invariant either"; fi
if has "$ABERR" "with --force too" && [ ! -e "$T/ab/shard/$EPB7/${AB}66.md" ]; then ok "close AB6-inv: the --force refusal says so and writes nothing"; else ko "close AB6-inv: --force refusal: $ABERR"; fi
if abclose "$T/xdg-none" "${AB}66" --name bar-thing-fix --force && has "$ABERR" "(naming_policy=warn: accepted)"; then ok "close AB6-inv: control, --force with a wrong subject under warn is accepted"; else ko "close AB6-inv: --force wrong subject: $ABERR"; fi
if abclose "$T/xdg-off" "${AB}66" --name wip-foo-thing-fix && has "$ABERR" "not checked (naming_policy=off)"; then ok "close AB6-inv: off does not check the invariant either"; else ko "close AB6-inv: off: $ABERR"; fi
# AB6-inv MUTATION: a copy of stk whose warn branch ignores `invariant` must ACCEPT wip- with warn,
# or the checks above measure something else; with error the mutant still refuses (control:
# the error path is not what AB6-inv measures).
mkdir -p "$T/mut-inv/bin" "$T/xdg-error/session-tracker"; ln -sfn "$(cd "$H" && pwd)" "$T/mut-inv/helpers"
printf 'naming_policy = error\n' > "$T/xdg-error/session-tracker/config"
sed 's/^\( *\)1:\*:true:\*)  die/\1never-matches)  die/' "$STK" > "$T/mut-inv/bin/stk"; chmod +x "$T/mut-inv/bin/stk"
if ! grep -q '1:\*:true:\*)' "$T/mut-inv/bin/stk" && grep -q 'never-matches)' "$T/mut-inv/bin/stk"; then ok "mutation AB6-inv: the copy ignores the invariant flag"; else ko "mutation AB6-inv: sed did not change the branch"; fi
abclose_mut(){ ABERR=$(ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$1" bash "$T/mut-inv/bin/stk" close --session "$2" --status done "${@:3}" 2>&1 >/dev/null); }
mkw "${AB}67" /x/foo-repo >/dev/null
if abclose_mut "$T/xdg-none" "${AB}67" --name wip-foo-thing-fix && has "$ABERR" "naming_policy=warn: accepted"; then ok "mutation AB6-inv: without the invariant branch warn accepts wip- (AB6-inv measures that branch)"; else ko "mutation AB6-inv: the mutant still refuses wip- with warn: AB6-inv does not measure the invariant branch: $ABERR"; fi
mkw "${AB}70" /x/foo-repo >/dev/null
if abclose_mut "$T/xdg-error" "${AB}70" --name wip-foo-thing-fix --force && has "$ABERR" "(--force: accepted)"; then ok "mutation AB6-inv: without the invariant branch --force passes wip- (the --force check measures that branch)"; else ko "mutation AB6-inv: the mutant still refuses wip- with --force: $ABERR"; fi
mkw "${AB}68" /x/foo-repo >/dev/null
if abclose_mut "$T/xdg-error" "${AB}68" --name wip-foo-thing-fix; then ko "mutation AB6-inv: control, the mutant ACCEPTS wip- with error"; else ok "mutation AB6-inv: control, with error the mutant still refuses wip-"; fi
mkw "${AB}69" /x/foo-repo >/dev/null
if abclose "$T/xdg-error" "${AB}69" --name wip-foo-thing-fix; then ko "close AB6-inv: error ACCEPTED wip-"; else ok "close AB6-inv: error refuses wip- (unchanged)"; fi
# error + --force: the conventions pass (W13), the invariants do not
EPB9=$(mkw "${AB}71" /x/foo-repo)
if abclose "$T/xdg-error" "${AB}71" --name wip-foo-thing-fix --force; then ko "close AB6-inv: error + --force ACCEPTED wip-"; else ok "close AB6-inv: error + --force still refuses wip-"; fi
if abclose "$T/xdg-error" "${AB}71" --name 'Foo Thing' --force; then ko "close AB6-inv: error + --force ACCEPTED a name outside the lexicon"; else ok "close AB6-inv: error + --force still refuses a name outside the lexicon"; fi
if [ ! -e "$T/ab/shard/$EPB9/${AB}71.md" ]; then ok "close AB6-inv: nothing written by the two forced refusals"; else ko "close AB6-inv: record written by a forced refusal"; fi
# error + map declared but missing + --force: the guard cannot run and --force writes the name unchecked, saying so
mkdir -p "$T/xdg-missing-err/session-tracker"; printf 'naming_policy = error\nnaming_map = %s/no-such-map.yaml\n' "$T" > "$T/xdg-missing-err/session-tracker/config"
mkw "${AB}72" /x/foo-repo >/dev/null
if abclose "$T/xdg-missing-err" "${AB}72" --name foo-thing-fix; then ko "close AB6-inv: error with a missing declared map ACCEPTED without --force"; else ok "close AB6-inv: error with a missing declared map stops without --force"; fi
if abclose "$T/xdg-missing-err" "${AB}72" --name foo-thing-fix --force && has "$ABERR" "(--force: name not checked)"; then ok "close AB6-inv: error with a missing declared map, --force writes the name unchecked and says so"; else ko "close AB6-inv: error + missing map + --force: $ABERR"; fi
# a stderr line from the helper's process (a python or uv warning) must not break the verdict:
# a wrapper uv that prints to stderr, then the real one. Mutant: a copy of stk that captures
# 2>&1 as before lets wip- through with warn (jq fails, invariant reads false).
mkdir -p "$T/uv-noisy"; printf '#!/usr/bin/env bash\necho "warning: a line on stderr" >&2\nexec "%s" "$@"\n' "$(command -v uv)" > "$T/uv-noisy/uv"; chmod +x "$T/uv-noisy/uv"
EPB10=$(mkw "${AB}73" /x/foo-repo)
ABERR=$(ABENV PATH="$T/uv-noisy:$PATH" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" close --session "${AB}73" --status done --name wip-foo-thing-fix 2>&1 >/dev/null); ABRC=$?
if [ "$ABRC" -ne 0 ] && has "$ABERR" "starts with 'wip-'" && [ ! -e "$T/ab/shard/$EPB10/${AB}73.md" ]; then ok "close AB6-inv: a stderr line from the helper does not break the verdict, wip- still refused"; else ko "close AB6-inv: noisy stderr: rc=$ABRC $ABERR"; fi
ABERR=$(ABENV PATH="$T/uv-noisy:$PATH" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" close --session "${AB}73" --status done --name foo-thing-fix 2>&1 >/dev/null); ABRC=$?
if [ "$ABRC" -eq 0 ] && has "$ABERR" "compliant (naming-map.yaml contexts: foo-repo: foo"; then ok "close AB6-inv: control, with the noisy uv a compliant name is accepted and the rule cited"; else ko "close AB6-inv: noisy stderr control: rc=$ABRC $ABERR"; fi
mkdir -p "$T/mut-err/bin"; ln -sfn "$(cd "$H" && pwd)" "$T/mut-err/helpers"
sed 's/ 2>"\$errf") \&\& grc=0/ 2>\&1) \&\& grc=0/' "$STK" > "$T/mut-err/bin/stk"; chmod +x "$T/mut-err/bin/stk"
if grep -q ' 2>&1) && grc=0' "$T/mut-err/bin/stk" && ! grep -q ' 2>"$errf") && grc=0' "$T/mut-err/bin/stk"; then ok "mutation AB6-inv: the copy captures stderr with the verdict again"; else ko "mutation AB6-inv: sed did not change the capture"; fi
mkw "${AB}74" /x/foo-repo >/dev/null
if ABENV PATH="$T/uv-noisy:$PATH" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" bash "$T/mut-err/bin/stk" close --session "${AB}74" --status done --name wip-foo-thing-fix >/dev/null 2>&1; then ok "mutation AB6-inv: with 2>&1 the noisy stderr lets wip- through (the check above measures the capture)"; else ko "mutation AB6-inv: the 2>&1 mutant still refuses wip- with the noisy uv"; fi
mkw "${AB}75" /x/foo-repo >/dev/null
if ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" bash "$T/mut-err/bin/stk" close --session "${AB}75" --status done --name wip-foo-thing-fix >/dev/null 2>&1; then ko "mutation AB6-inv: control, the 2>&1 mutant with a quiet uv ACCEPTED wip-"; else ok "mutation AB6-inv: control, with a quiet uv the 2>&1 mutant still refuses wip-"; fi
# AB6-inv, map declared but missing: the guard "cannot run" (exit 2) and warn writes the name
# unchecked, but the invariants need no map: wip- is still refused, a compliant name still passes
# as "not checked". Mutant: a naming.py whose main() skips the early invariant check lets wip-
# through with warn (the test measures that call, not the one inside check_name).
mkdir -p "$T/xdg-missing/session-tracker"; printf 'naming_policy = warn\nnaming_map = %s/no-such-map.yaml\n' "$T" > "$T/xdg-missing/session-tracker/config"
EPB8=$(mkw "${AB}60" /x/foo-repo)
if abclose "$T/xdg-missing" "${AB}60" --name wip-foo-thing-fix; then ko "close AB6-inv: warn with a missing declared map ACCEPTED wip-"; else ok "close AB6-inv: warn with a missing declared map still refuses wip-"; fi
if has "$ABERR" "starts with 'wip-'" && [ ! -e "$T/ab/shard/$EPB8/${AB}60.md" ]; then ok "close AB6-inv: the refusal names the wip- rule and nothing is written"; else ko "close AB6-inv: missing map + wip-: $ABERR"; fi
mkw "${AB}61" /x/foo-repo >/dev/null
if abclose "$T/xdg-missing" "${AB}61" --name foo-thing-fix && has "$ABERR" "naming guard not runnable (exit 2)" && has "$ABERR" "name not checked"; then ok "close AB6-inv: control, with the map missing a lexicon-clean name is accepted as not checked"; else ko "close AB6-inv: missing map control: $ABERR"; fi
mkdir -p "$T/mut-nm/bin" "$T/mut-nm/helpers"; cp "$STK" "$T/mut-nm/bin/stk"; chmod +x "$T/mut-nm/bin/stk"
ln -sfn "$(cd "$H/../references" && pwd)" "$T/mut-nm/references"   # naming.md is read relative to helpers/
for hf in "$H"/*.py; do ln -sfn "$hf" "$T/mut-nm/helpers/$(basename "$hf")"; done
sed 's/^    inv = check_invariants(a.name, \[\])$/    inv = None/' "$H/naming.py" > "$T/mut-nm/helpers/naming.py.tmp" && rm -f "$T/mut-nm/helpers/naming.py" && mv "$T/mut-nm/helpers/naming.py.tmp" "$T/mut-nm/helpers/naming.py"
if ! grep -q 'inv = check_invariants(a.name, \[\])' "$T/mut-nm/helpers/naming.py" && grep -q '^    inv = None$' "$T/mut-nm/helpers/naming.py"; then ok "mutation AB6-inv: the naming.py copy skips the early invariant check"; else ko "mutation AB6-inv: sed did not change main()"; fi
abclose_nm(){ ABERR=$(ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$1" bash "$T/mut-nm/bin/stk" close --session "$2" --status done "${@:3}" 2>&1 >/dev/null); }
mkw "${AB}62" /x/foo-repo >/dev/null
if abclose_nm "$T/xdg-missing" "${AB}62" --name wip-foo-thing-fix && has "$ABERR" "name not checked"; then ok "mutation AB6-inv: without the early check a missing map lets wip- through (the test measures it)"; else ko "mutation AB6-inv: the mutant still refuses wip- with the map missing: $ABERR"; fi
mkw "${AB}63" /x/foo-repo >/dev/null
if abclose_nm "$T/xdg-none" "${AB}63" --name wip-foo-thing-fix; then ko "mutation AB6-inv: control, the mutant with the map present ACCEPTED wip-"; else ok "mutation AB6-inv: control, with the map present the mutant still refuses wip- (check_name)"; fi

mkw "${AB}24" /x/foo-repo >/dev/null
if abclose "$T/xdg-on" "${AB}24" --name bar-thing-fix; then ko "close AB6: error from the file ACCEPTS the wrong subject"; else ok "close AB6: error from the file rejects (control: the same call that warn accepts)"; fi
if [ -e "$T/ab/shard/$EPB/${AB}24.md" ]; then ko "close AB6: error wrote the record"; else ok "close AB6: error does not write"; fi
mkw "${AB}25" /x/foo-repo >/dev/null
if abclose "$T/xdg-ptypo" "${AB}25" --name foo-thing-fix; then ko "close AB6: naming_policy with a typo passes in close"; else ok "close AB6: naming_policy with a typo stops the close"; fi
if has "$ABERR" "invalid naming_policy 'strict'"; then ok "close AB6: the rejection names the value and the choices"; else ko "close AB6: message for the typo: $ABERR"; fi
if [ -e "$T/ab/shard/$EPB/${AB}25.md" ]; then ko "close AB6: record written with a broken config"; else ok "close AB6: broken config, no write"; fi
mkw "${AB}26" /x/foo-repo >/dev/null
if abclose "$T/xdg-ptypo" "${AB}26" --name foo-thing-fix --force && [ -e "$T/ab/shard/$EPB/${AB}26.md" ]; then ok "close AB6: --force passes even with a broken naming_policy"; else ko "close AB6: --force with a broken config: $ABERR"; fi
# warn with a guard that is not runnable (malformed map): reports and accepts; with error it stops
mkdir -p "$T/xdg-badmap/session-tracker"; printf 'contexts: [a, b\n' > "$T/ab-bad.yaml"
printf 'naming_map = %s\n' "$T/ab-bad.yaml" > "$T/xdg-badmap/session-tracker/config"
mkw "${AB}27" /x/foo-repo >/dev/null
if abclose "$T/xdg-badmap" "${AB}27" --name foo-thing-fix && has "$ABERR" "not runnable" && has "$ABERR" "name not checked"; then ok "close AB6: warn with a malformed map reports and accepts"; else ko "close AB6: warn with a malformed map: $ABERR"; fi
mkw "${AB}28" /x/foo-repo >/dev/null
if ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-badmap" STK_NAMING_POLICY=error bash "$STK" close --session "${AB}28" --status done --name foo-thing-fix >/dev/null 2>&1; then ko "close AB6: error with a malformed map PASSES"; else ok "close AB6: error with a malformed map stops (control of warn)"; fi
# AB7: naming_map from the file and from the env: hook and close read it; sync pull copies the canon's map there
mkdir -p "$T/xdg-map/session-tracker" "$T/abmaps"; printf 'contexts:\n  qq-repo: qq\n' > "$T/abmaps/custom.yaml"
printf 'naming_map = %s/abmaps/custom.yaml\nnaming_policy = error\n' "$T" > "$T/xdg-map/session-tracker/config"
OUTB=$(abhook "$T/xdg-map" "${AB}31" startup /x/qq-repo)
if has "$OUTB" 'row `qq-repo: qq`' && has "$OUTB" "$T/abmaps/custom.yaml"; then ok "hook AB7: the naming_map map is the one resolved and cited"; else ko "hook AB7: custom map not used: $OUTB"; fi
mkw "${AB}32" /x/qq-repo >/dev/null
if abclose "$T/xdg-map" "${AB}32" --name zz-thing-fix; then ko "close AB7: the guard does not read naming_map (zz accepted)"; else ok "close AB7: the guard reads naming_map (zz rejected on qq-repo)"; fi
if abclose "$T/xdg-map" "${AB}32" --name qq-thing-fix; then ok "close AB7: subject of the custom map accepted"; else ko "close AB7: qq rejected: $ABERR"; fi
# where without --naming-map reads the naming_map map (the subject comes from the custom map)
eq "where AB7: default --naming-map = naming_map of the config" "$(ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-map" bash "$STK" where --node testnode --cwd /x/qq-repo --index "$T/kn/empty.jsonl" | jq -r .current.subject)" "qq"
printf 'contexts:\n  qq-repo: ee\n' > "$T/abmaps/env.yaml"
mkw "${AB}33" /x/qq-repo >/dev/null
if ABENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-map" STK_NAMING_MAP="$T/abmaps/env.yaml" bash "$STK" close --session "${AB}33" --status done --name ee-thing-fix >/dev/null 2>&1; then ok "close AB7: STK_NAMING_MAP wins over the file"; else ko "close AB7: env does not win over the file"; fi
mkdir -p "$T/abstore"; printf 'contexts:\n  pulled: yes\n' > "$T/abstore/naming-map.yaml"
printf 'naming_map = ~/maps/pulled.yaml\ncanon_path = %s/abstore\n' "$T" > "$T/xdg-map/session-tracker/config"
ABENV HOME="$T/abhome" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-map" bash "$STK" sync pull >/dev/null 2>&1
if cmp -s "$T/abstore/naming-map.yaml" "$T/abhome/maps/pulled.yaml"; then ok "sync AB7: pull copies the canon's map into naming_map (~/ expanded, folder created)"; else ko "sync AB7: map not copied into naming_map"; fi
if cmp -s "$STK_LOCAL/naming-map.yaml" "$T/ab/naming-map.yaml"; then ok "sync AB7: the default path was not touched"; else ko "sync AB7: pull also wrote into the default"; fi
# ssh: the host's map goes into the naming_map path (fake rsync, measured on the log)
printf 'canon_mode = ssh\ncanon_host = hubx\ncanon_path = /srv/s\nnaming_map = %s/abmaps/ssh.yaml\n' "$T" > "$T/xdg-map/session-tracker/config"
: > "$SSHLOG"; AAENV STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-map" bash "$STK" sync pull >/dev/null 2>&1
if grep -q "^rsync -a hubx:/srv/s/naming-map.yaml $T/abmaps/ssh.yaml$" "$SSHLOG"; then ok "sync AB7: in ssh the host's map goes into naming_map"; else ko "sync AB7: destination of the map in ssh: $(grep naming-map "$SSHLOG")"; fi
PARB=$(ABENV HOME="$T/abhome" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" bash -c 'source "$1"; printf "%s|%s|%s|%s" "$STK_NAMING_MAP" "$STK_NAMING_POLICY" "$STK_HOOK_ASK_INTENT" "$STK_HOOK_EXTRA_CONTEXT_FILE"' _ "$CFGBLOCK")
PARP=$(ABENV HOME="$T/abhome" STK_LOCAL="$T/ab" XDG_CONFIG_HOME="$T/xdg-none" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; c=config.load(); print('|'.join([c['naming_map'], c['naming_policy'], c['hook_ask_intent'], c['hook_extra_context_file']]), end='')" "$H" 2>&1)
eq "config AB7: default bash = <data_dir>/naming-map.yaml|warn|off|(empty)" "$PARB" "$T/ab/naming-map.yaml|warn|off|"
eq "config AB7: bash/python parity on the new defaults" "$PARP" "$PARB"
PARP=$(ABENV HOME="$T/abhome" XDG_CONFIG_HOME="$T/xdg-extra" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; c=config.load(); print(c['hook_extra_context_file'], c['naming_policy'], end='')" "$H" 2>&1)
eq "config AB7: python expands ~/ in hook_extra_context_file and reads naming_policy from the file" "$PARP" "$T/abhome/extra-home.txt off"
mkdir -p "$T/xdg-tm/session-tracker"; printf 'naming_map = ~/maps/m.yaml\n' > "$T/xdg-tm/session-tracker/config"
PARP=$(ABENV HOME="$T/abhome" XDG_CONFIG_HOME="$T/xdg-tm" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; print(config.load()['naming_map'], end='')" "$H" 2>&1)
PARB=$(ABENV HOME="$T/abhome" XDG_CONFIG_HOME="$T/xdg-tm" bash -c 'source "$1"; printf "%s" "$STK_NAMING_MAP"' _ "$CFGBLOCK")
eq "config AB7: ~/ in naming_map expanded the same way in python and bash" "$PARP|$PARB" "$T/abhome/maps/m.yaml|$T/abhome/maps/m.yaml"
# AB8: kb_tiers from the map: without the section the kb-tier branch does not fire; malformed -> guard not runnable
printf 'contexts: {}\n' > "$T/notiers.yaml"
eq "naming AB8: map without kb_tiers -> wiki/alpha/x is not kb-tier" "$($PY "$H/naming.py" context --cwd /h/wiki/alpha/x --naming-map "$T/notiers.yaml" | jq -r .kind)" "unknown"
eq "naming AB8: kb_tiers declared -> kb-tier (suite fixture)" "$($PY "$H/naming.py" context --cwd /h/wiki/alpha/x --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '"\(.kind) \(.subject)"')" "kb-tier wk-al-x"
eq "naming AB8: folder not declared in the same map -> unknown" "$($PY "$H/naming.py" context --cwd /h/wiki/beta/x --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)" "unknown"
OUTB=$($PY "$H/naming.py" context --text --cwd /h/wiki/alpha/x --naming-map "$STK_LOCAL/naming-map.yaml")
if has "$OUTB" 'kb_tiers: alpha: al'; then ok "naming AB8: the text cites the applied kb_tiers row"; else ko "naming AB8: kb_tiers row not cited: $OUTB"; fi
# three-level path under the tier: the area is the folder under the tier, not the deepest one, and the text says the same as the subject
eq "naming AB8: area = folder under the tier (not the deepest level)" "$($PY "$H/naming.py" context --cwd /h/wiki/alpha/area1/deep2 --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '"\(.subject) \(.theme_hint)"')" "wk-al-area1 deep2"
OUTB=$($PY "$H/naming.py" context --text --cwd /h/wiki/alpha/area1/deep2 --naming-map "$STK_LOCAL/naming-map.yaml")
if has "$OUTB" '(here `area1`;' && ! has "$OUTB" 'here `deep2`'; then ok "naming AB8: the hook's text cites the subject's area, not the deep level"; else ko "naming AB8: text on the area: $OUTB"; fi
# exit 2 alone is not enough: a crash also exits 2. The reason must name kb_tiers (it measures the validation)
printf 'kb_tiers: [alpha]\n' > "$T/badtiers.yaml"
OUTB=$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wk-al-x-fix --naming-map "$T/badtiers.yaml" 2>/dev/null); RC=$?
eq "naming AB8: kb_tiers non-mapping -> exit 2" "$RC" "2"
if has "$OUTB" '`kb_tiers` is not a mapping'; then ok "naming AB8: the reason names kb_tiers (not a crash)"; else ko "naming AB8: exit 2 by another route: $OUTB"; fi
printf 'kb_tiers:\n  alpha: "A-1"\n' > "$T/badtiers2.yaml"
OUTB=$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wk-al-x-fix --naming-map "$T/badtiers2.yaml" 2>/dev/null); RC=$?
eq "naming AB8: kb_tiers token outside the lexicon -> exit 2" "$RC" "2"
if has "$OUTB" '`kb_tiers` is not a mapping'; then ok "naming AB8: here too the reason names kb_tiers"; else ko "naming AB8: exit 2 by another route: $OUTB"; fi

echo "== AC: pilot_commands in scan, relative paths, naming_map declared but missing, stk doctor, stk init =="
AC=cccc0000-0000-0000-0000-0000000000
# AC1: scan reads the pilot candidates from the commands listed in pilot_commands; empty list (default) = [] even with -u in the transcript
mkdir -p "$T/ac-claude/projects/-ac" "$T/ac-scan" "$T/xdg-ac-pilot/session-tracker"
printf '{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/ac","uuid":"u1","message":"pilotctl -u pilot-a send; pilotctl --user pilot-b read; other -u nope"}\n' > "$T/ac-claude/projects/-ac/${AC}01.jsonl"
acscan(){ ABENV STK_LOCAL="$T/ac-scan" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$1" "${@:2}" bash "$STK" scan --all 2>/dev/null | jq -c '.pilot_candidates'; }
eq "scan AC1: empty pilot_commands (default) -> no candidate even with -u in the transcript" "$(acscan "$T/xdg-none")" "[]"
printf 'pilot_commands = pilotctl\n' > "$T/xdg-ac-pilot/session-tracker/config"
eq "scan AC1: pilot_commands from the file -> alias after -u and --user, of that command only" "$(acscan "$T/xdg-ac-pilot")" '["pilot-a","pilot-b"]'
eq "scan AC1: STK_PILOT_COMMANDS wins over the file (comma list)" "$(acscan "$T/xdg-ac-pilot" STK_PILOT_COMMANDS="other, pilotctl")" '["nope","pilot-a","pilot-b"]'
ERRC=$(ABENV STK_LOCAL="$T/ac-scan" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_PILOT_COMMANDS="pilot ctl!" bash "$STK" scan --all 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ERRC" "invalid name 'ctl!'"; then ok "scan AC1: invalid name in pilot_commands stops scan and names it"; else ko "scan AC1: invalid name: rc=$RC $ERRC"; fi
PARP=$(ABENV XDG_CONFIG_HOME="$T/xdg-ac-pilot" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; print(','.join(config.load()['pilot_commands']), end='')" "$H" 2>&1)
eq "config AC1: python reads pilot_commands as a list" "$PARP" "pilotctl"
# a `*` in the list must not become the files of the current folder; a name is a whole word, not the tail of another
mkdir -p "$T/ac-cwd"; touch "$T/ac-cwd/leak"
OUTC=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ac-scan" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_PILOT_COMMANDS='*' bash "$STK" scan --all 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$OUTC" "invalid name '*'"; then ok "scan AC1: pilot_commands='*' is an invalid name, not the files of the folder"; else ko "scan AC1: glob in pilot_commands: rc=$RC $OUTC"; fi
printf '{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/ac","uuid":"u1","message":"xpilotctl -u zz; /opt/bin/pilotctl -u yy; a\\npilotctl -u nl; b\\tother -u tab"}\n' > "$T/ac-claude/projects/-ac/${AC}02.jsonl"
eq "scan AC1: the command name is a whole word (xpilotctl no, /opt/bin/pilotctl yes), and it holds after an encoded newline" "$(acscan "$T/xdg-ac-pilot" | tail -1)" '["nl","yy"]'
# separators like split_list in python: tab, double commas, spaces; the lexicon also holds in a UTF-8 locale (where bash's [A-Za-z] accepts accented letters)
printf 'pilot_commands = pilotctl\tother,,  \n' > "$T/xdg-ac-pilot/session-tracker/config"
eq "scan AC1: tabs and double commas in the list separate as in python" "$(acscan "$T/xdg-ac-pilot" | tail -1)" '["nl","tab","yy"]'
PARP=$(ABENV XDG_CONFIG_HOME="$T/xdg-ac-pilot" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; print(','.join(config.load()['pilot_commands']), end='')" "$H" 2>&1)
eq "config AC1: python reads the same list (tabs, double commas)" "$PARP" "pilotctl,other"
printf 'pilot_commands = pilotctl\n' > "$T/xdg-ac-pilot/session-tracker/config"
ERRC=$(ABENV LC_ALL=en_US.UTF-8 STK_LOCAL="$T/ac-scan" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_PILOT_COMMANDS="$(printf 'pilot\xc3\xa8')" bash "$STK" scan --all 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ERRC" "invalid name"; then ok "scan AC1: a name with an accented letter is rejected even in a UTF-8 locale"; else ko "scan AC1: accented letter in UTF-8 accepted: rc=$RC $ERRC"; fi
ACOUT=$(ABENV LC_ALL=en_US.UTF-8 XDG_CONFIG_HOME="$T/xdg-ac-init5" bash "$STK" init --node "$(printf 'pilot\xc3\xa8')" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && has "$ACOUT" "is not a slug" && [ ! -e "$T/xdg-ac-init5/session-tracker/config" ]; then ok "init AC5: slug with an accented letter rejected even in a UTF-8 locale"; else ko "init AC5: accented letter in UTF-8: rc=$RC $ACOUT"; fi

# AC2: relative paths in the config: sync pull and close stop, no copy of the map in the current folder
mkdir -p "$T/xdg-ac-rel/session-tracker" "$T/ac-store" "$T/ac-cwd" "$T/ac-rel"
cp "$STK_LOCAL/naming-map.yaml" "$T/ac-store/naming-map.yaml"
printf 'canon_path = %s/ac-store\nnaming_map = rel-map.yaml\n' "$T" > "$T/xdg-ac-rel/session-tracker/config"
ERRC=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" sync pull 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ERRC" "naming_map=rel-map.yaml relative"; then ok "sync AC2: relative naming_map stops sync pull and names the key"; else ko "sync AC2: pull with a relative naming_map: rc=$RC $ERRC"; fi
if [ -e "$T/ac-cwd/rel-map.yaml" ]; then ko "sync AC2: the map ended up in the current folder"; else ok "sync AC2: no copy of the map in the current folder"; fi
# control: with the absolute path the same pull copies the map
printf 'canon_path = %s/ac-store\nnaming_map = %s/ac-rel/maps/abs.yaml\n' "$T" "$T" > "$T/xdg-ac-rel/session-tracker/config"
(cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" sync pull >/dev/null 2>&1)
if cmp -s "$T/ac-store/naming-map.yaml" "$T/ac-rel/maps/abs.yaml"; then ok "sync AC2: control, with an absolute naming_map the same pull copies the map"; else ko "sync AC2: control fell, absolute map not copied"; fi
# close: every relative path stops before writing (also the ones close does not use: it is the config that is broken)
acclose(){ ACERR=$(ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$1" bash "$STK" close --session "$2" --status done "${@:3}" 2>&1 >/dev/null); }
EPC=$(mkw "${AC}11" /x/foo-repo)
for kv in "naming_map = rel-map.yaml" "hook_extra_context_file = rel.txt" "canon_path = rel-store"; do
    printf '%s\n' "$kv" > "$T/xdg-ac-rel/session-tracker/config"
    if acclose "$T/xdg-ac-rel" "${AC}11" --name foo-thing-fix; then ko "close AC2: '$kv' accepted"; else ok "close AC2: '$kv' stops the close"; fi
    if has "$ACERR" "${kv%% *}=${kv##* } relative"; then ok "close AC2: the message names ${kv%% *}"; else ko "close AC2: message for '$kv': $ACERR"; fi
done
if [ -e "$T/ac-rel/shard/$EPC/${AC}11.md" ]; then ko "close AC2: with a relative path the record was written"; else ok "close AC2: no write with a relative path"; fi
ACERR=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="rel-data" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" close --session "${AC}11" --status done 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ACERR" "data_dir=rel-data relative"; then ok "close AC2: relative data_dir (STK_LOCAL) stops the close"; else ko "close AC2: relative data_dir: rc=$RC $ACERR"; fi
if [ -e "$T/ac-cwd/rel-data" ]; then ko "close AC2: close created rel-data in the current folder"; else ok "close AC2: no rel-data folder created"; fi
# note (and the other writers) stop like close; the hook creates nothing in the current folder and its warn goes to stderr
ACERR=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="rel-data" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" note --session "${AC}11" --kind present "x" 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ACERR" "data_dir=rel-data relative" && [ ! -e "$T/ac-cwd/rel-data" ]; then ok "note AC2: relative data_dir stops note without creating anything"; else ko "note AC2: relative data_dir: rc=$RC $ACERR"; fi
ACERR=$(cd "$T/ac-cwd" && printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AC}13" | ABENV STK_LOCAL="rel-data" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" hook 2>&1 >/dev/null)
if [ ! -e "$T/ac-cwd/rel-data" ] && has "$ACERR" "warn:data_dir=rel-data relative"; then ok "hook AC2: relative data_dir, the hook does not create the folder and the warn goes to stderr"; else ko "hook AC2: relative data_dir: $(ls "$T/ac-cwd") / $ACERR"; fi
# relative overlay: the file in the current folder does NOT enter the context
printf 'TEXT-FROM-THE-CURRENT-REPO\n' > "$T/ac-cwd/overlay.txt"; printf 'hook_extra_context_file = overlay.txt\n' > "$T/xdg-ac-rel/session-tracker/config"
OUTC=$(cd "$T/ac-cwd" && printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AC}14" | ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$OUTC" "/rename wip-" && ! has "$OUTC" "TEXT-FROM-THE-CURRENT-REPO"; then ok "hook AC2: relative hook_extra_context_file is not read from the current folder"; else ko "hook AC2: relative overlay injected: $OUTC"; fi
# every other writer and primary-check: with a relative data_dir they stop without creating the folder
printf '## Node ownership\n- Primary: elsewhere (`/p`)\n- Secondaries: none\n' > "$T/ac-cwd/CLAUDE.local.md"; git -C "$T/ac-cwd" init -q 2>/dev/null
for sub in "sync pull" "sync publish" "publish" "index" "link --pilot ${AC}11 --piloted n:s" "branch --session ${AC}11 --name a-b-fix --child c" "hygiene" "primary-check --cwd $T/ac-cwd --node testnode"; do
    ACERR=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="rel-data" XDG_CONFIG_HOME="$T/xdg-none" STK_PRIMARY_CHECK_TTL=0 bash "$STK" $sub 2>&1 >/dev/null); RC=$?
    if [ "$RC" -ne 0 ] && has "$ACERR" "data_dir=rel-data relative" && [ ! -e "$T/ac-cwd/rel-data" ]; then ok "AC2: '${sub%% *}' with a relative data_dir stops and creates nothing"; else ko "AC2: '${sub%% *}' with a relative data_dir: rc=$RC $(ls "$T/ac-cwd" | tr '\n' ' ') $ACERR"; fi
done
# the hook does not read relative paths: a map with the same name in the cwd does not become the map, an events.jsonl in the cwd does not turn the hook off, and the context states the config error
printf 'contexts:\n  foo-repo: LEAKSUBJ\n' > "$T/ac-cwd/rel-map.yaml"; mkdir -p "$T/ac-cwd/rel-data/shard"
printf '{"session_id":"%s","event":"note","kind":"intent","text":"x"}\n' "${AC}15" > "$T/ac-cwd/rel-data/shard/events.jsonl"
printf 'naming_map = rel-map.yaml\n' > "$T/xdg-ac-rel/session-tracker/config"
OUTC=$(cd "$T/ac-cwd" && printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AC}15" | ABENV STK_LOCAL="rel-data" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if ! has "$OUTC" "LEAKSUBJ" && has "$OUTC" "/rename wip-"; then ok "hook AC2: the relative map with the same name in the cwd is not read, the name is proposed with the generic rules"; else ko "hook AC2: relative map read from the cwd or hook silent: $OUTC"; fi
case "$OUTC" in "Invalid session-tracker config"*"data_dir=rel-data relative"*"naming_map=rel-map.yaml relative"*) ok "hook AC2: the context opens with the config error and names both paths";; *) ko "hook AC2: context without the config error: ${OUTC:0:120}";; esac
if has "$OUTC" "/rename wip-"; then ok "hook AC2: the cwd's events.jsonl did not turn the hook off (a relative data_dir is not read)"; else ko "hook AC2: cwd's events.jsonl read"; fi
/bin/rm -rf "$T/ac-cwd/rel-data"
# mutation: the copy of stk without _paths_check in close must ACCEPT, otherwise AC2 measures something else
mkdir -p "$T/mut6/bin"; ln -s "$H" "$T/mut6/helpers"; ln -s "$H/../references" "$T/mut6/references"
sed 's/^    _paths_check   # a relative path in config stops the close.*$/    :/' "$STK" > "$T/mut6/bin/stk"
if grep -q 'stops the close before any write' "$T/mut6/bin/stk"; then ko "mutation AC2: sed did not remove the close check"; else ok "mutation AC2: the copy is without _paths_check in close (the other writers keep it)"; fi
printf 'naming_map = rel-map.yaml\n' > "$T/xdg-ac-rel/session-tracker/config"
ACERR=$(ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$T/mut6/bin/stk" close --session "${AC}11" --status done --name foo-thing-fix 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ -e "$T/ac-rel/shard/$EPC/${AC}11.md" ]; then ok "mutation AC2: without the check close writes (AC2 measures _paths_check)"; else ko "mutation AC2: the copy without the check rejects anyway: rc=$RC $ACERR"; fi
# index and dashboard go through the same _canon_check: with a relative canon_path they stop and name the key
printf 'canon_path = rel-store\n' > "$T/xdg-ac-rel/session-tracker/config"
for sub in index dashboard; do
    ACERR=$(ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" $sub 2>&1 >/dev/null); RC=$?
    if [ "$RC" -ne 0 ] && has "$ACERR" "canon_path=rel-store relative"; then ok "$sub AC2: relative canon_path stops $sub and names the key"; else ko "$sub AC2: relative canon_path: rc=$RC $ACERR"; fi
done
# canon_mode=ssh: canon_path belongs to the host, a relative one is not a config error (fake ssh and rsync)
printf 'canon_mode = ssh\ncanon_host = hubx\ncanon_path = rel/on/host\n' > "$T/xdg-ac-rel/session-tracker/config"
: > "$SSHLOG"; AAENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" sync pull >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -q "hubx:rel/on/host/" "$SSHLOG"; then ok "sync AC2: with canon_mode=ssh a relative canon_path belongs to the host and passes"; else ko "sync AC2: relative canon_path in ssh: rc=$RC $(head -1 "$SSHLOG")"; fi
# hook: does not stop, but the log says so
printf 'naming_map = rel-map.yaml\n' > "$T/xdg-ac-rel/session-tracker/config"
OUTC=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AC}12" | ABENV STK_LOCAL="$T/ac-rel" XDG_CONFIG_HOME="$T/xdg-ac-rel" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if grep -q "$(printf '\t%s\tstartup\twarn:naming_map=rel-map.yaml relative' "${AC:0:8}")" "$T/ac-rel/hook.log"; then ok "hook AC2: the relative path ends up in the hook's log"; else ko "hook AC2: log without the warn: $(tail -1 "$T/ac-rel/hook.log")"; fi
if has "$OUTC" "/rename wip-"; then ok "hook AC2: the hook does not stop for the relative path"; else ko "hook AC2: hook silent: $OUTC"; fi
PARP=$(ABENV XDG_CONFIG_HOME="$T/xdg-ac-rel" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; print(';'.join(config.path_errors(config.load())), end='')" "$H" 2>&1)
case "$PARP" in "naming_map=rel-map.yaml relative:"*) ok "config AC2: path_errors in python says the same thing";; *) ko "config AC2: path_errors python: $PARP";; esac

# AC3: naming_map declared but missing: with error close stops, with warn it says so; the missing default stays "no map"
mkdir -p "$T/xdg-ac-nm/session-tracker" "$T/ac-nm" "$T/ac-nodef"
printf 'naming_policy = error\nnaming_map = %s/ac-does-not-exist.yaml\n' "$T" > "$T/xdg-ac-nm/session-tracker/config"
nmclose(){ ACERR=$(ABENV STK_LOCAL="$T/ac-nm" XDG_CONFIG_HOME="$1" "${@:3}" bash "$STK" close --session "$2" --status done --name foo-thing-fix 2>&1 >/dev/null); }
EPN=$(mkw "${AC}21" /x/foo-repo)
if nmclose "$T/xdg-ac-nm" "${AC}21"; then ko "close AC3: naming_map declared but missing, error PASSES"; else ok "close AC3: naming_map declared but missing stops the close in error"; fi
if has "$ACERR" "naming_map declared but missing"; then ok "close AC3: the reason says the declared map is missing"; else ko "close AC3: reason: $ACERR"; fi
if [ -e "$T/ac-nm/shard/$EPN/${AC}21.md" ]; then ko "close AC3: record written"; else ok "close AC3: no write"; fi
# control: with the file in its place the same close passes (the defect was the missing file, not the name)
cp "$STK_LOCAL/naming-map.yaml" "$T/ac-does-not-exist.yaml"
if nmclose "$T/xdg-ac-nm" "${AC}21"; then ok "close AC3: control, with the file present the same name passes"; else ko "close AC3: control fell: $ACERR"; fi
mv "$T/ac-does-not-exist.yaml" "$T/ac-moved-away.yaml"
# declared from the env, without a config file: same thing
mkw "${AC}22" /x/foo-repo >/dev/null
if nmclose "$T/xdg-none" "${AC}22" STK_NAMING_POLICY=error STK_NAMING_MAP="$T/ac-nope.yaml"; then ko "close AC3: missing STK_NAMING_MAP passes"; else ok "close AC3: naming_map declared from the env and missing stops the close"; fi
# warn: reports the missing map and accepts the unchecked name
mkw "${AC}23" /x/foo-repo >/dev/null
if nmclose "$T/xdg-none" "${AC}23" STK_NAMING_MAP="$T/ac-nope.yaml" && has "$ACERR" "declared but missing" && has "$ACERR" "name not checked"; then ok "close AC3: in warn the declared and missing map is reported and the name passes unchecked"; else ko "close AC3: warn with a missing map: $ACERR"; fi
# missing default: no map, the generic rules apply (control that the declared-map error does not fire on the default)
mkw "${AC}24" /x/foo-repo >/dev/null
ACERR=$(ABENV STK_LOCAL="$T/ac-nodef" XDG_CONFIG_HOME="$T/xdg-none" STK_NAMING_POLICY=error bash "$STK" close --session "${AC}24" --status done --name bar-thing-fix 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 0 ] && has "$ACERR" "is not an entry of contexts"; then ok "close AC3: missing default map -> subject not verifiable, the name passes (as before)"; else ko "close AC3: missing default: rc=$RC $ACERR"; fi
# hook: declared and missing -> context NOT resolvable with the reason; missing default -> generic rules
OUTC=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AC}25" | ABENV STK_LOCAL="$T/ac-nm" XDG_CONFIG_HOME="$T/xdg-ac-nm" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$OUTC" "NOT resolvable" && has "$OUTC" "naming_map declared but missing ($T/ac-does-not-exist.yaml)"; then ok "hook AC3: the hook says the declared map is missing"; else ko "hook AC3: context: $OUTC"; fi
OUTC=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AC}26" | ABENV STK_LOCAL="$T/ac-nodef" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$OUTC" "ONLY the generic rules" && ! has "$OUTC" "NOT resolvable" && ! has "$OUTC" "the map row applied" && [ "$(grep -o naming-map.yaml <<<"$OUTC" | wc -l)" -eq 1 ]; then ok "hook AC3: missing default map -> generic rules, no error, no invitation to read the map"; else ko "hook AC3: missing default: $OUTC"; fi
OUTC=$($PY "$H/naming.py" check --cwd /x/foo-repo --name foo-thing-fix --naming-map "$T/ac-nope.yaml" --require-map 2>/dev/null); RC=$?
eq "naming AC3: --require-map on a missing file -> exit 2" "$RC" "2"
if has "$OUTC" "naming_map declared but missing"; then ok "naming AC3: the reason is that one (not a crash)"; else ko "naming AC3: reason: $OUTC"; fi
$PY "$H/naming.py" check --cwd /x/foo-repo --name foo-thing-fix --naming-map "$T/ac-nope.yaml" >/dev/null 2>&1; RC=$?
eq "naming AC3: without --require-map the same missing file is 'no map' (exit 0)" "$RC" "0"

# AC4: stk doctor says what is configured, warns about unknown keys, exits 1 on errors (out-of-domain values)
acdoc(){ ACOUT=$(ABENV STK_LOCAL="$T/ac-doc" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$1" "${@:2}" bash "$STK" doctor 2>&1); ACRC=$?; }
mkdir -p "$T/ac-doc"
acdoc "$T/xdg-none"
eq "doctor AC4: zero-config -> exit 0" "$ACRC" "0"
if has "$ACOUT" "missing: defaults apply"; then ok "doctor AC4: says the file is missing and the defaults apply"; else ko "doctor AC4: zero-config: $ACOUT"; fi
if has "$ACOUT" "ok     naming_map: default $T/ac-doc/naming-map.yaml missing"; then ok "doctor AC4: the missing default map is not an error"; else ko "doctor AC4: naming_map line: $(printf '%s' "$ACOUT" | grep naming_map)"; fi
if has "$ACOUT" "override the file: STK_LOCAL, STK_NODE" && ! has "$ACOUT" "STK_NAMING_MAP"; then ok "doctor AC4: lists only the STK_* that were in the environment, not the ones resolved by stk"; else ko "doctor AC4: env line: $(printf '%s' "$ACOUT" | grep override)"; fi
if has "$ACOUT" "warn   hook: $T/ac-claude/settings.json missing"; then ok "doctor AC4: without settings.json says the hook is not registered"; else ko "doctor AC4: hook line: $(printf '%s' "$ACOUT" | grep 'hook:')"; fi
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/.local/bin/stk hook 2>/dev/null || true"}]}]}}\n' "$T" > "$T/ac-claude/settings.json"
acdoc "$T/xdg-none"
if has "$ACOUT" "ok     hook: stk hook registered"; then ok "doctor AC4: hook registered in settings.json recognized"; else ko "doctor AC4: present hook not seen: $(printf '%s' "$ACOUT" | grep 'hook:')"; fi
# unknown or misspelled key: warn that names it and suggests the nearest key; exit stays 0
mkdir -p "$T/xdg-ac-typo/session-tracker"; printf 'naming_polcy = error\nfrobnicate = 1\n' > "$T/xdg-ac-typo/session-tracker/config"
acdoc "$T/xdg-ac-typo"
eq "doctor AC4: unknown keys -> exit 0 (warn)" "$ACRC" "0"
if has "$ACOUT" 'unknown key `naming_polcy` ignored (maybe `naming_policy`?'; then ok "doctor AC4: the typo is named with the nearest key"; else ko "doctor AC4: typo: $(printf '%s' "$ACOUT" | grep 'unknown key')"; fi
if has "$ACOUT" 'unknown key `frobnicate` ignored (no similar key)'; then ok "doctor AC4: the key without similar ones is named anyway"; else ko "doctor AC4: frobnicate: $(printf '%s' "$ACOUT" | grep frobnicate)"; fi
if has "$ACOUT" "ok     naming_policy: warn"; then ok "doctor AC4: with the typo the default warn applies, and doctor shows it"; else ko "doctor AC4: naming_policy with the typo: $(printf '%s' "$ACOUT" | grep 'naming_policy:')"; fi
mkdir -p "$T/xdg-ac-ok/session-tracker"; printf 'hook_ask_intent = on\nnaming_policy = error\n' > "$T/xdg-ac-ok/session-tracker/config"
acdoc "$T/xdg-ac-ok"
if [ "$ACRC" -eq 0 ] && has "$ACOUT" "(2 keys)" && ! has "$ACOUT" "unknown key"; then ok "doctor AC4: control, correct config with 2 keys: exit 0 and no key warning"; else ko "doctor AC4: control on a correct config: rc=$ACRC $(printf '%s' "$ACOUT" | grep -E 'keys|unknown key|error')"; fi
# error: relative path, declared map missing, out-of-domain values, ssh without host, malformed map
doc_err(){ # <config content> <fragment expected after "error  "> <label>
    mkdir -p "$T/xdg-ac-err/session-tracker"; printf '%b' "$1" > "$T/xdg-ac-err/session-tracker/config"
    acdoc "$T/xdg-ac-err"
    if [ "$ACRC" -eq 1 ] && has "$ACOUT" "error  $2"; then ok "doctor AC4: $3 -> exit 1 and the line says so"; else ko "doctor AC4: $3: rc=$ACRC $(printf '%s' "$ACOUT" | grep -E 'error|doctor:')"; fi
}
doc_err 'naming_map = rel-map.yaml\n' 'path: naming_map=rel-map.yaml relative:' 'relative naming_map'
doc_err "naming_policy = error\nnaming_map = $T/ac-nope.yaml\n" "naming_map: declared but missing ($T/ac-nope.yaml)" 'naming_map declared but missing'
doc_err 'canon_mode = ssh\ncanon_path = /srv/s\n' 'canon: canon_mode=ssh requires canon_host' 'ssh without canon_host'
doc_err 'naming_policy = strict\n' 'naming_policy: invalid value `strict`' 'out-of-domain naming_policy'
doc_err 'hook_ask_intent = yes\n' 'hook_ask_intent: invalid value `yes`' 'out-of-domain hook_*'
doc_err 'canon_git = maybe\n' 'canon_git: invalid value `maybe`' 'out-of-domain canon_git'
printf 'contexts: [a, b\n' > "$T/ac-bad.yaml"
doc_err "naming_map = $T/ac-bad.yaml\n" 'naming_map: naming-map.yaml unreadable' 'malformed map'
doc_err 'pilot_commands = ok, no!way\n' 'pilot_commands: invalid name `no!way`' 'pilot_commands with an invalid name'
printf 'naming_policy = off\nnaming_map = %s/ac-nope.yaml\n' "$T" > "$T/xdg-ac-err/session-tracker/config"; acdoc "$T/xdg-ac-err"
if [ "$ACRC" -eq 0 ] && has "$ACOUT" "warn   naming_map: declared but missing"; then ok "doctor AC4: declared map missing with naming_policy=off is only a warn"; else ko "doctor AC4: off + missing map: rc=$ACRC"; fi
printf 'hook_tmux_tab = on\nnaming_policy = off\n' > "$T/xdg-ac-err/session-tracker/config"; acdoc "$T/xdg-ac-err"
if [ "$ACRC" -eq 0 ] && has "$ACOUT" "warn   hook_tmux_tab: on with naming_policy=off"; then ok "doctor AC4: tmux window on without naming -> warn"; else ko "doctor AC4: tmux+off: rc=$ACRC"; fi
if ABENV XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" doctor extra >/dev/null 2>&1; then ko "doctor AC4: accepts arguments"; else ok "doctor AC4: rejects arguments"; fi

# AC5: stk init writes the config (keys passed active, the others commented out with the default), does not overwrite without --force, rejects out-of-domain values and relative paths
acinit(){ ACOUT=$(ABENV XDG_CONFIG_HOME="$1" bash "$STK" init "${@:2}" 2>&1); ACRC=$?; }
INI="$T/xdg-ac-init/session-tracker/config"
acinit "$T/xdg-ac-init" --node alpha --canon-mode ssh --canon-host hub --canon-path /srv/s --canon-git auto --naming-policy error
eq "init AC5: init with all the flags -> exit 0" "$ACRC" "0"
if [ -f "$INI" ]; then ok "init AC5: the file is written in XDG_CONFIG_HOME/session-tracker/config"; else ko "init AC5: file missing"; fi
PARP=$(ABENV -u STK_NODE XDG_CONFIG_HOME="$T/xdg-ac-init" $PY -c "import sys; sys.path.insert(0, sys.argv[1]); import config; c=config.load(); print('|'.join([c['node'], c['canon_mode'], c['canon_host'], c['canon_path'], c['canon_git'], c['naming_policy'], c['hook_ask_intent'], c['naming_map']]), end='')" "$H" 2>&1)
eq "init AC5: python rereads the values passed and the defaults for the rest" "$PARP" "alpha|ssh|hub|/srv/s|auto|error|off|$STK_LOCAL/naming-map.yaml"
PARB=$(ABENV -u STK_NODE XDG_CONFIG_HOME="$T/xdg-ac-init" bash -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s|%s|%s" "$STK_NODE" "$STK_CANON_MODE" "$STK_CANON_HOST" "$STK_CANON_PATH" "$STK_CANON_GIT" "$STK_NAMING_POLICY" "$STK_HOOK_ASK_INTENT" "$STK_NAMING_MAP"' _ "$CFGBLOCK")
eq "init AC5: bash reads the same file the same way" "$PARB" "$PARP"
eq "init AC5: the keys not passed are commented out (only the 6 passed are active)" "$(grep -c '^[a-z_]* = ' "$INI")" "6"
if grep -q '^# naming_map = <data_dir>/naming-map.yaml$' "$INI" && grep -q 'off: no name proposal' "$INI"; then ok "init AC5: the commented-out keys carry default and explanation (how to turn naming off included)"; else ko "init AC5: template: $(grep -c . "$INI") lines"; fi
cp "$INI" "$T/ac-init-copy"
acinit "$T/xdg-ac-init" --node beta
if [ "$ACRC" -ne 0 ] && has "$ACOUT" "already exists" && cmp -s "$INI" "$T/ac-init-copy"; then ok "init AC5: without --force it does not overwrite and says so"; else ko "init AC5: rerun: rc=$ACRC $ACOUT"; fi
acinit "$T/xdg-ac-init" --node beta --force
if [ "$ACRC" -eq 0 ] && grep -q '^node = beta$' "$INI" && grep -q '^# canon_mode = local$' "$INI"; then ok "init AC5: --force rewrites from scratch (previous ssh gone, new node)"; else ko "init AC5: --force: rc=$ACRC"; fi
acinit "$T/xdg-ac-init2"
if [ "$ACRC" -eq 0 ] && [ "$(grep -c '^[a-z_]* = ' "$T/xdg-ac-init2/session-tracker/config")" = "0" ]; then ok "init AC5: without flags it writes the commented-out template only"; else ko "init AC5: bare init: rc=$ACRC"; fi
ACOUT=$(ABENV STK_LOCAL="$T/ac-doc" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$T/xdg-ac-init2" bash "$STK" doctor 2>&1); ACRC=$?
if [ "$ACRC" -eq 0 ] && has "$ACOUT" "(0 keys)"; then ok "init AC5: doctor reads the template as a file without active keys, exit 0"; else ko "init AC5: doctor on the template: rc=$ACRC"; fi
for bad in "--canon-mode remote" "--canon-mode ssh --canon-host h" "--canon-path rel/x" "--node Alpha" "--canon-git yes" "--naming-policy strict" "--bogus 1"; do
    acinit "$T/xdg-ac-init3" $bad
    if [ "$ACRC" -ne 0 ] && [ ! -e "$T/xdg-ac-init3/session-tracker/config" ]; then ok "init AC5: '$bad' rejected, no file"; else ko "init AC5: '$bad' accepted: rc=$ACRC $ACOUT"; fi
done
acinit "$T/xdg-ac-init3" --canon-host "$(printf 'h\nnaming_policy = off')" --canon-mode ssh --canon-path /srv/s
if [ "$ACRC" -ne 0 ] && has "$ACOUT" "newline" && [ ! -e "$T/xdg-ac-init3/session-tracker/config" ]; then ok "init AC5: a newline in a value is rejected (it would write an extra key)"; else ko "init AC5: newline in the value: rc=$ACRC $ACOUT"; fi
acinit "$T/xdg-ac-init4" --canon-path "~/store"
if [ "$ACRC" -eq 0 ] && grep -q '^canon_path = ~/store$' "$T/xdg-ac-init4/session-tracker/config"; then ok "init AC5: ~/ accepted in canon_path"; else ko "init AC5: ~/store: rc=$ACRC $ACOUT"; fi

echo "== AD: plugin files (manifest, marketplace, hooks), shim (resolve, install) and doctor (plugin, hook, shim, --remote) =="
ADROOT=$(cd "$HERE/.." && pwd -P)
# AD1: the three plugin files and what the skill at the root requires (no skills/, no skills key)
if jq -e '.name=="session-tracker" and (has("skills")|not) and (.version|type=="string")' "$ADROOT/.claude-plugin/plugin.json" >/dev/null 2>&1; then ok "plugin AD1: plugin.json: name session-tracker, version, no skills key (the SKILL.md at the root loads by itself)"; else ko "plugin AD1: plugin.json"; fi
if jq -e '.name=="session-tracker-skill" and (.plugins|length)==1 and .plugins[0].name=="session-tracker" and .plugins[0].source=="./"' "$ADROOT/.claude-plugin/marketplace.json" >/dev/null 2>&1; then ok "plugin AD1: marketplace.json: session-tracker-skill with the session-tracker entry alone, source ./"; else ko "plugin AD1: marketplace.json"; fi
HCMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$ADROOT/hooks/hooks.json" 2>/dev/null)
if has "$HCMD" '"${CLAUDE_PLUGIN_ROOT}"/bin/stk hook' && [ "$(jq '.hooks.SessionStart|length' "$ADROOT/hooks/hooks.json")" = "1" ] && [ -z "$(jq -r '.hooks.SessionStart[0].matcher // empty' "$ADROOT/hooks/hooks.json")" ]; then ok "plugin AD1: hooks.json: a single SessionStart without matcher that calls \"\${CLAUDE_PLUGIN_ROOT}\"/bin/stk hook (stk decides by source)"; else ko "plugin AD1: hooks.json: [$HCMD]"; fi
eq "plugin AD1: the name in the SKILL.md at the root is the plugin's (otherwise the install names it like the cache folder)" "$(fmget "$ADROOT/SKILL.md" name)" "$(jq -r .name "$ADROOT/.claude-plugin/plugin.json")"
if [ ! -e "$ADROOT/skills" ]; then ok "plugin AD1: no skills/ folder at the root (with one, the SKILL.md at the root would not load)"; else ko "plugin AD1: skills/ exists"; fi
if [ -x "$ADROOT/bin/stk" ] && [ -x "$ADROOT/shim/stk" ] && [ "$(sed -n 2p "$ADROOT/shim/stk")" = "# session-tracker shim v1" ]; then ok "plugin AD1: bin/stk and shim/stk executable, shim marker on line 2"; else ko "plugin AD1: executables or marker"; fi
if command -v claude >/dev/null 2>&1; then
    mkdir -p "$T/ad-claude-cfg"
    if CLAUDE_CONFIG_DIR="$T/ad-claude-cfg" claude plugin validate "$ADROOT" >"$T/ad-validate.out" 2>&1; then ok "plugin AD1: claude plugin validate <root> exits 0 ($(claude --version 2>/dev/null | head -1))"; else ko "plugin AD1: claude plugin validate: $(tail -3 "$T/ad-validate.out")"; fi
    if CLAUDE_CONFIG_DIR="$T/ad-claude-cfg" claude plugin validate "$ADROOT/.claude-plugin/marketplace.json" >"$T/ad-validate2.out" 2>&1 && grep -q "Validation passed" "$T/ad-validate2.out"; then ok "plugin AD1: claude plugin validate marketplace.json passes"; else ko "plugin AD1: validate marketplace: $(tail -3 "$T/ad-validate2.out")"; fi
    # the predicate can say no: a broken manifest (skills key towards a missing path) must fail
    mkdir -p "$T/ad-bad/.claude-plugin"; printf '{"name":"session-tracker","skills":["./nope/"]}' > "$T/ad-bad/.claude-plugin/plugin.json"
    if CLAUDE_CONFIG_DIR="$T/ad-claude-cfg" claude plugin validate "$T/ad-bad" >/dev/null 2>&1; then ko "plugin AD1: validate accepts a manifest with a missing path"; else ok "plugin AD1: validate rejects a manifest with a missing path (the check can say no)"; fi
else
    skip "plugin AD1: claude is not in PATH: claude plugin validate not run (on the development node it must run)"
fi

# AD2: shim/stk resolves the current installation: pin, Claude's records (in-place folder > cache copy), next stk in PATH, nothing
ADP="$T/ad-claude/plugins"; mkdir -p "$ADP" "$T/ad-cache/bin" "$T/ad-mkt/.claude-plugin" "$T/ad-mkt/plug/bin" "$T/ad-other" "$T/ad-nostk"
# the fake bin/stk carry stk's header on line 2 (it is what shim install and doctor read to say "it is session-tracker")
printf '#!/usr/bin/env bash\n# stk — fake\nprintf "cache|%%s" "$*"\n' > "$T/ad-cache/bin/stk"; chmod +x "$T/ad-cache/bin/stk"
printf '#!/usr/bin/env bash\n# stk — fake\nprintf "inplace|%%s" "$*"\n' > "$T/ad-mkt/plug/bin/stk"; chmod +x "$T/ad-mkt/plug/bin/stk"
printf '#!/usr/bin/env bash\nprintf "other|%%s" "$*"\n' > "$T/ad-other/stk"; chmod +x "$T/ad-other/stk"
printf '{"name":"session-tracker-skill","owner":{"name":"t"},"plugins":[{"name":"session-tracker","source":"./plug"}]}' > "$T/ad-mkt/.claude-plugin/marketplace.json"
adrec(){ # <source type>: writes the two records; installPath is always the cache copy
  printf '{"version":2,"plugins":{"session-tracker@session-tracker-skill":[{"scope":"user","installPath":"%s","version":"0.9.0"}]}}' "$T/ad-cache" > "$ADP/installed_plugins.json"
  printf '{"session-tracker-skill":{"source":{"source":"%s","path":"%s"},"installLocation":"%s"}}' "$1" "$T/ad-mkt" "$T/ad-mkt" > "$ADP/known_marketplaces.json"; }
# minimal PATH without any stk but with python3 and bash: fallback 3 must find nothing
ADPATH="$(dirname "$(command -v python3)"):/usr/bin:/bin"
if PATH="$ADPATH" command -v stk >/dev/null 2>&1; then ko "shim AD2: precondition: there is an stk in $ADPATH ($(PATH="$ADPATH" command -v stk)), the PATH measures do not hold"; else ok "shim AD2: precondition: no stk in the test PATH"; fi
adres(){ env -i HOME="$HOME" PATH="${1:-$ADPATH}" CLAUDE_DIR="$T/ad-claude" "${@:2}" bash "$ADROOT/shim/stk" --stk-shim-resolve 2>/dev/null; }
adrec github
eq "shim AD2: github marketplace: resolves the cache copy (installPath)" "$(adres)" "$T/ad-cache/bin/stk"
adrec directory
eq "shim AD2: marketplace added from a path (directory): the folder read in place wins, not the cache copy" "$(adres)" "$T/ad-mkt/plug/bin/stk"
chmod -x "$T/ad-mkt/plug/bin/stk"
eq "shim AD2: in-place folder without an executable bin/stk: falls back to the cache (mutation on the predicate)" "$(adres)" "$T/ad-cache/bin/stk"
chmod +x "$T/ad-mkt/plug/bin/stk"
eq "shim AD2: STK_PLUGIN_ROOT wins over everything" "$(adres "$ADPATH" STK_PLUGIN_ROOT="$T/ad-mkt/plug")" "$T/ad-mkt/plug/bin/stk"
eq "shim AD2: without CLAUDE_DIR, CLAUDE_CONFIG_DIR moves the records folder (same resolution as stk)" "$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_CONFIG_DIR="$T/ad-claude" bash "$ADROOT/shim/stk" --stk-shim-resolve 2>/dev/null)" "$T/ad-mkt/plug/bin/stk"
rm -f "$ADP/installed_plugins.json" "$ADP/known_marketplaces.json"
eq "shim AD2: no record: the next stk in PATH that is not the shim" "$(adres "$T/ad-other:$ADPATH")" "$T/ad-other/stk"
# two copies of the shim in PATH and no record: neither must run the other (endless loop)
mkdir -p "$T/ad-two/a" "$T/ad-two/b"; install -m 755 "$ADROOT/shim/stk" "$T/ad-two/a/stk"; install -m 755 "$ADROOT/shim/stk" "$T/ad-two/b/stk"
env -i HOME="$HOME" PATH="$T/ad-two/a:$T/ad-two/b:$ADPATH" CLAUDE_DIR="$T/ad-claude" tmo 10 "$T/ad-two/a/stk" -h >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 127 ]; then ok "shim AD2: two shims in PATH without a record: exit 127, not a loop (timeout 10 s would give 124)"; else ko "shim AD2: two shims: rc=$RC"; fi
eq "shim AD2: two shims in PATH and another stk after: skips both copies and finds that one" "$(adres "$T/ad-two/a:$T/ad-two/b:$T/ad-other:$ADPATH")" "$T/ad-other/stk"
OUTAD=$(adres); RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUTAD" ]; then ok "shim AD2: no record, no stk in PATH: exit 1 and no output"; else ko "shim AD2: empty: rc=$RC out=[$OUTAD]"; fi
ERRAD=$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" bash "$ADROOT/shim/stk" scan 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 127 ] && has "$ERRAD" "plugin not found" && has "$ERRAD" "claude plugin install"; then ok "shim AD2: without a target it exits 127 and says how to install"; else ko "shim AD2: without a target: rc=$RC $ERRAD"; fi
# stk shim resolve performs the same resolution as the template
adrec github
eq "shim AD2: stk shim resolve = the template's resolution" "$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" shim resolve 2>/dev/null)" "$T/ad-cache/bin/stk"
# install: writes the file with the marker, the installed shim runs the target with the arguments intact
ADBIN="$T/ad-bin"; mkdir -p "$ADBIN"
adinst(){ ADOUT=$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" shim install "$@" 2>&1); ADRC=$?; }
adinst --dest "$ADBIN/stk"
if [ "$ADRC" -eq 0 ] && [ -x "$ADBIN/stk" ] && [ "$(sed -n 2p "$ADBIN/stk")" = "# session-tracker shim v1" ] && has "$ADOUT" "here it resolves $T/ad-cache/bin/stk" && has "$ADOUT" "is not in the PATH"; then ok "shim AD2: install writes the shim, says what it resolves and that the folder is not in the PATH"; else ko "shim AD2: install: rc=$ADRC $ADOUT"; fi
eq "shim AD2: the installed shim runs the target with the arguments intact (spaces included)" "$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" "$ADBIN/stk" note --kind 'a b' 'c d')" "cache|note --kind a b c d"
eq "shim AD2: the installed shim resolves like the template" "$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" "$ADBIN/stk" --stk-shim-resolve)" "$T/ad-cache/bin/stk"
adinst --dest "$ADBIN/stk"
if [ "$ADRC" -eq 0 ] && has "$ADOUT" "replaced shim"; then ok "shim AD2: rerun on its own shim replaces it without --force"; else ko "shim AD2: rerun: rc=$ADRC $ADOUT"; fi
echo "mine" > "$ADBIN/foreign"; adinst --dest "$ADBIN/foreign"
if [ "$ADRC" -ne 0 ] && [ "$(cat "$ADBIN/foreign")" = "mine" ] && has "$ADOUT" -- "--force"; then ok "shim AD2: another file is not touched without --force"; else ko "shim AD2: foreign: rc=$ADRC $(cat "$ADBIN/foreign")"; fi
adinst --dest "$ADBIN/foreign" --force
if [ "$ADRC" -eq 0 ] && [ "$(sed -n 2p "$ADBIN/foreign")" = "# session-tracker shim v1" ]; then ok "shim AD2: --force replaces it"; else ko "shim AD2: --force: rc=$ADRC"; fi
ln -sfn "$T/ad-cache/bin/stk" "$ADBIN/link"; adinst --dest "$ADBIN/link"
if [ "$ADRC" -eq 0 ] && [ ! -L "$ADBIN/link" ] && [ "$(sed -n 2p "$ADBIN/link")" = "# session-tracker shim v1" ] && [ "$(sed -n 3p "$T/ad-cache/bin/stk")" = 'printf "cache|%s" "$*"' ]; then ok "shim AD2: a symlink to a session-tracker bin/stk is replaced by a file, and the link's target stays intact"; else ko "shim AD2: symlink: rc=$ADRC link=$(ls -l "$ADBIN/link")"; fi
# a symlink to ANOTHER program that sits in a bin/ and is called stk (a name collision) is not ours
mkdir -p "$T/ad-foreign/bin"; printf '#!/usr/bin/env bash\necho foreign\n' > "$T/ad-foreign/bin/stk"; chmod +x "$T/ad-foreign/bin/stk"; ln -sfn "$T/ad-foreign/bin/stk" "$ADBIN/flink"; adinst --dest "$ADBIN/flink"
if [ "$ADRC" -ne 0 ] && [ -L "$ADBIN/flink" ] && has "$ADOUT" -- "--force"; then ok "shim AD2: a symlink to another program called stk in a bin/ is not touched without --force"; else ko "shim AD2: foreign symlink: rc=$ADRC $(ls -l "$ADBIN/flink")"; fi
# a working link is not replaced by a shim that here would resolve nothing (exit 127 in place of an stk that worked)
rm -f "$ADP/installed_plugins.json" "$ADP/known_marketplaces.json"; ln -sfn "$T/ad-cache/bin/stk" "$ADBIN/wlink"; adinst --dest "$ADBIN/wlink"
if [ "$ADRC" -ne 0 ] && [ -L "$ADBIN/wlink" ] && has "$ADOUT" "works, but here the shim would resolve"; then ok "shim AD2: without a record a working symlink stays: the shim must not replace an stk that works with an exit 127"; else ko "shim AD2: working link: rc=$ADRC $ADOUT"; fi
adinst --dest "$ADBIN/wlink" --force
if [ "$ADRC" -eq 0 ] && [ ! -L "$ADBIN/wlink" ]; then ok "shim AD2: --force replaces it anyway"; else ko "shim AD2: working link --force: rc=$ADRC"; fi
# the working link is called stk and its folder is in the PATH: the measure "what would the shim resolve" must not count it,
# not even when the folder appears in the PATH with a trailing slash (the comparison is by real path, not by string)
mkdir -p "$T/ad-wl"; ln -sfn "$T/ad-cache/bin/stk" "$T/ad-wl/stk"
ADOUT=$(env -i HOME="$HOME" PATH="$T/ad-wl:$ADPATH" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" shim install --dest "$T/ad-wl/stk" 2>&1); ADRC=$?
if [ "$ADRC" -ne 0 ] && [ -L "$T/ad-wl/stk" ]; then ok "shim AD2: working link called stk, its folder in the PATH: without a record it stays (it does not count itself)"; else ko "shim AD2: link in PATH: rc=$ADRC $ADOUT"; fi
ADOUT=$(env -i HOME="$HOME" PATH="$T/ad-wl/:$ADPATH" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" shim install --dest "$T/ad-wl/stk" 2>&1); ADRC=$?
if [ "$ADRC" -ne 0 ] && [ -L "$T/ad-wl/stk" ]; then ok "shim AD2: same with the folder in the PATH with a trailing slash"; else ko "shim AD2: trailing slash: rc=$ADRC $ADOUT"; fi
# its own shim is replaced even without a record: if it resolved nothing it did not work before either
install -m 755 "$ADROOT/shim/stk" "$ADBIN/own"; adinst --dest "$ADBIN/own"
if [ "$ADRC" -eq 0 ] && has "$ADOUT" "replaced shim"; then ok "shim AD2: its own shim without a record is replaced anyway"; else ko "shim AD2: own shim without a record: rc=$ADRC $ADOUT"; fi
# precedence CLAUDE_DIR > CLAUDE_CONFIG_DIR, the same for shim, stk shim resolve and doctor (records only under CLAUDE_DIR)
adrec github; mkdir -p "$T/ad-ccd-empty/plugins"
eq "shim AD2: with both CLAUDE_DIR and CLAUDE_CONFIG_DIR, the shim reads CLAUDE_DIR's records" "$(adres "$ADPATH" CLAUDE_CONFIG_DIR="$T/ad-ccd-empty")" "$T/ad-cache/bin/stk"
eq "shim AD2: stk shim resolve does the same" "$(env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" CLAUDE_CONFIG_DIR="$T/ad-ccd-empty" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" shim resolve 2>/dev/null)" "$T/ad-cache/bin/stk"
# without python3 the shim says so (not "plugin not found"), and the STK_PLUGIN_ROOT pin works anyway
mkdir -p "$T/ad-nopy"; for t in bash sed dirname; do ln -sfn "$(command -v "$t")" "$T/ad-nopy/$t"; done
ERRAD=$(env -i HOME="$HOME" PATH="$T/ad-nopy" CLAUDE_DIR="$T/ad-claude" "$T/ad-nopy/bash" "$ADROOT/shim/stk" scan 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 127 ] && has "$ERRAD" "python3 is required" && ! has "$ERRAD" "plugin not found"; then ok "shim AD2: without python3 it says python3 is needed, not that the plugin is missing"; else ko "shim AD2: without python3: rc=$RC $ERRAD"; fi
eq "shim AD2: without python3 the STK_PLUGIN_ROOT pin works" "$(env -i HOME="$HOME" PATH="$T/ad-nopy" STK_PLUGIN_ROOT="$T/ad-mkt/plug" "$T/ad-nopy/bash" "$ADROOT/shim/stk" --stk-shim-resolve 2>/dev/null)" "$T/ad-mkt/plug/bin/stk"
adinst --dest rel/stk; if [ "$ADRC" -ne 0 ]; then ok "shim AD2: relative --dest rejected"; else ko "shim AD2: relative dest accepted"; fi
adinst --dest "$ADBIN"; if [ "$ADRC" -ne 0 ] && has "$ADOUT" "directory"; then ok "shim AD2: --dest that is a directory rejected"; else ko "shim AD2: dest directory: rc=$ADRC"; fi
adinst --bogus; if [ "$ADRC" -ne 0 ]; then ok "shim AD2: unknown flag rejected"; else ko "shim AD2: --bogus accepted"; fi
if env -i HOME="$HOME" PATH="$ADPATH" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" shim >/dev/null 2>&1; then ko "shim AD2: 'stk shim' without a subcommand accepted"; else ok "shim AD2: 'stk shim' without a subcommand rejected with the usage"; fi

# AD3: doctor: installed plugin, origin of the hook (double injection), what `stk` finds in PATH, --remote
addoc(){ # <PATH> [VAR=val...]: doctor with CLAUDE_DIR=$T/ad-claude (records in $ADP, settings in $T/ad-claude/settings.json)
  ADOUT=$(ABENV -u STK_LOCAL PATH="$1" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" "${@:2}" bash "$ADROOT/bin/stk" doctor 2>&1); ADRC=$?; }
# PATH for doctor: only the tools it needs, as symlinks in a test folder. The
# folder of uv or jq on the host (~/.local/bin) may contain a real stk, and the measure
# "stk is not in PATH" would find it. /usr/bin and /bin stay for sed, grep and the rest.
ADTOOLS="$T/ad-tools"; mkdir -p "$ADTOOLS"
for t in uv jq python3 rsync git; do ln -sfn "$(command -v "$t")" "$ADTOOLS/$t"; done
ADPATH2="$ADTOOLS:/usr/bin:/bin"
if PATH="$ADPATH2" command -v stk >/dev/null 2>&1; then ko "doctor AD3: precondition: there is an stk in $ADPATH2 ($(PATH="$ADPATH2" command -v stk)), the PATH measures do not hold"; else ok "doctor AD3: precondition: no stk in the test PATH"; fi
rm -f "$T/ad-claude/settings.json"; adrec github
addoc "$ADPATH2"
if [ "$ADRC" -eq 0 ] && has "$ADOUT" "ok     plugin: session-tracker@session-tracker-skill ($T/ad-cache)" && has "$ADOUT" "ok     hook: stk hook comes from the plugin"; then ok "doctor AD3: plugin installed (record) and hook from the plugin, settings.json missing"; else ko "doctor AD3: plugin+hook: rc=$ADRC $(echo "$ADOUT" | grep -E 'plugin|hook:')"; fi
if has "$ADOUT" "warn   shim: stk is not in PATH"; then ok "doctor AD3: without stk in PATH it warns that ssh and the terminal do not find it"; else ko "doctor AD3: shim missing: $(echo "$ADOUT" | grep shim)"; fi
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/x/.local/bin/stk hook 2>/dev/null || true"}]}]}}' > "$T/ad-claude/settings.json"
addoc "$ADPATH2"
if has "$ADOUT" "warn   hook: stk hook comes from the plugin (hooks/hooks.json) AND from settings.json (1 in SessionStart"; then ok "doctor AD3: installed plugin + hook in settings.json = double injection (warn)"; else ko "doctor AD3: double injection: $(echo "$ADOUT" | grep 'hook:')"; fi
# plugin disabled: the record stays but its hook does not run, so the settings.json hook is the only one and must not be removed
printf '{"enabledPlugins":{"session-tracker@session-tracker-skill":false},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/x/.local/bin/stk hook 2>/dev/null || true"}]}]}}' > "$T/ad-claude/settings.json"
addoc "$ADPATH2"
if has "$ADOUT" "warn   plugin: session-tracker@session-tracker-skill disabled in enabledPlugins" && has "$ADOUT" "ok     hook: stk hook registered in SessionStart"; then ok "doctor AD3: plugin disabled in enabledPlugins: not a double injection, the settings.json hook is the only one"; else ko "doctor AD3: disabled: $(echo "$ADOUT" | grep -E 'plugin|hook:')"; fi
printf '{"enabledPlugins":{"session-tracker@session-tracker-skill":false}}' > "$T/ad-claude/settings.json"; addoc "$ADPATH2"
if has "$ADOUT" "warn   hook: no hook: the plugin is not active here"; then ok "doctor AD3: plugin disabled and nothing in settings.json: no hook, and it says so"; else ko "doctor AD3: disabled without hook: $(echo "$ADOUT" | grep 'hook:')"; fi
# project scope of another folder: not active here
printf '{"version":2,"plugins":{"session-tracker@session-tracker-skill":[{"scope":"project","projectPath":"/elsewhere/proj","installPath":"%s","version":"0.9.0"}]}}' "$T/ad-cache" > "$ADP/installed_plugins.json"; rm -f "$T/ad-claude/settings.json"; addoc "$ADPATH2"
if has "$ADOUT" "warn   plugin: session-tracker@session-tracker-skill scope project of /elsewhere/proj, not of this folder"; then ok "doctor AD3: project-scope record of another folder: not active here"; else ko "doctor AD3: project scope: $(echo "$ADOUT" | grep 'plugin')"; fi
adrec github
# CLAUDE_CONFIG_DIR alone moves settings.json AND the records: doctor reads them from the same home
mkdir -p "$T/ad-cfg2/plugins"; cp "$ADP/installed_plugins.json" "$T/ad-cfg2/plugins/"; printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/x/stk hook"}]}]}}' > "$T/ad-cfg2/settings.json"
ADOUT=$(ABENV -u STK_LOCAL -u CLAUDE_DIR PATH="$ADPATH2" CLAUDE_CONFIG_DIR="$T/ad-cfg2" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" doctor 2>&1)
if has "$ADOUT" "warn   hook: stk hook comes from the plugin (hooks/hooks.json) AND from settings.json (1 in SessionStart of $T/ad-cfg2/settings.json)"; then ok "doctor AD3: with CLAUDE_CONFIG_DIR alone settings.json and records come from the same folder"; else ko "doctor AD3: CLAUDE_CONFIG_DIR: $(echo "$ADOUT" | grep -E 'plugin|hook:')"; fi
# with `claude` in PATH and Claude's home equal to the records' one, the state comes from `claude plugin list --json` (all scopes)
mkdir -p "$T/ad-fakeclaude"; printf '#!/usr/bin/env bash\n[ "$1 $2 $3" = "plugin list --json" ] || exit 1\ncat "$FAKE_CLAUDE_LIST"\n' > "$T/ad-fakeclaude/claude"; chmod +x "$T/ad-fakeclaude/claude"
printf '[{"id":"session-tracker@session-tracker-skill","version":"0.9.0","scope":"local","enabled":false,"installPath":"%s"}]' "$T/ad-cache" > "$T/ad-list-off.json"
printf '[{"id":"session-tracker@session-tracker-skill","version":"0.9.0","scope":"user","enabled":true,"installPath":"%s"}]' "$T/ad-cache" > "$T/ad-list-on.json"
rm -f "$T/ad-claude/settings.json"; printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/x/stk hook"}]}]}}' > "$T/ad-claude/settings.json"
ADOUT=$(ABENV -u STK_LOCAL PATH="$T/ad-fakeclaude:$ADPATH2" CLAUDE_DIR="$T/ad-claude" CLAUDE_CONFIG_DIR="$T/ad-claude" FAKE_CLAUDE_LIST="$T/ad-list-off.json" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" doctor 2>&1)
if has "$ADOUT" "warn   plugin: session-tracker@session-tracker-skill disabled (enabled=false in claude plugin list)" && has "$ADOUT" "ok     hook: stk hook registered in SessionStart"; then ok "doctor AD3: claude plugin list says enabled=false (scope local): not active, the settings.json hook is the only one"; else ko "doctor AD3: list off: $(echo "$ADOUT" | grep -E 'plugin|hook:')"; fi
ADOUT=$(ABENV -u STK_LOCAL PATH="$T/ad-fakeclaude:$ADPATH2" CLAUDE_DIR="$T/ad-claude" CLAUDE_CONFIG_DIR="$T/ad-claude" FAKE_CLAUDE_LIST="$T/ad-list-on.json" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" doctor 2>&1)
if has "$ADOUT" "ok     plugin: session-tracker@session-tracker-skill ($T/ad-cache) (source: claude plugin list" && has "$ADOUT" "warn   hook: stk hook comes from the plugin (hooks/hooks.json) AND from settings.json"; then ok "doctor AD3: claude plugin list says enabled=true: active, and with the hook in settings.json it is a double injection"; else ko "doctor AD3: list on: $(echo "$ADOUT" | grep -E 'plugin|hook:')"; fi
# with CLAUDE_DIR different from the home that `claude` reads, the list does not count: it falls back to the records (and the line says so)
ADOUT=$(ABENV -u STK_LOCAL PATH="$T/ad-fakeclaude:$ADPATH2" CLAUDE_DIR="$T/ad-claude" CLAUDE_CONFIG_DIR="$T/ad-ccd-empty" FAKE_CLAUDE_LIST="$T/ad-list-off.json" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" doctor 2>&1)
if has "$ADOUT" "ok     plugin: session-tracker@session-tracker-skill ($T/ad-cache) (source: records in $ADP"; then ok "doctor AD3: CLAUDE_DIR different from claude's home: source is CLAUDE_DIR's records, not the list"; else ko "doctor AD3: doctor precedence: $(echo "$ADOUT" | grep 'plugin')"; fi
rm -f "$ADP/installed_plugins.json" "$ADP/known_marketplaces.json" "$T/ad-claude/settings.json"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/x/.local/bin/stk hook 2>/dev/null || true"}]}]}}' > "$T/ad-claude/settings.json"
addoc "$ADPATH2"
if has "$ADOUT" "ok     plugin: no installation record" && has "$ADOUT" "ok     hook: stk hook registered in SessionStart"; then ok "doctor AD3: without a record the settings.json hook alone is the good case (symlink or clone)"; else ko "doctor AD3: no record: $(echo "$ADOUT" | grep -E 'plugin|hook:')"; fi
# an installed_plugins.json that is present but broken is not "no record": doctor says so (the missing file, instead, is)
echo '{not json' > "$ADP/installed_plugins.json"; addoc "$ADPATH2"
if has "$ADOUT" "warn   plugin: $ADP/installed_plugins.json present but unreadable"; then ok "doctor AD3: unreadable plugin record: warn, not a false 'no record'"; else ko "doctor AD3: broken record: $(echo "$ADOUT" | grep plugin)"; fi
rm -f "$ADP/installed_plugins.json"
# what `stk` finds in PATH: the plugin's bin/ (only inside Claude), a symlink to this bin/stk, another installation, another program, the shim
addoc "$ADROOT/bin:$ADPATH2"
if has "$ADOUT" "warn   shim: stk in PATH is the plugin's bin/"; then ok "doctor AD3: stk found in the plugin's bin/: it is there only inside Claude"; else ko "doctor AD3: plugin bin: $(echo "$ADOUT" | grep shim)"; fi
mkdir -p "$T/ad-sym"; ln -sfn "$ADROOT/bin/stk" "$T/ad-sym/stk"; addoc "$T/ad-sym:$ADPATH2"
if has "$ADOUT" "warn   shim: $T/ad-sym/stk is a symlink or a copy of this installation"; then ok "doctor AD3: symlink to this bin/stk: does not follow updates"; else ko "doctor AD3: symlink: $(echo "$ADOUT" | grep shim)"; fi
mkdir -p "$T/ad-old/bin"; printf '#!/usr/bin/env bash\n# stk — session-tracker (old installation)\n' > "$T/ad-old/bin/stk"; chmod +x "$T/ad-old/bin/stk"; ln -sfn "$T/ad-old/bin/stk" "$T/ad-sym/stk"; addoc "$T/ad-sym:$ADPATH2"
if has "$ADOUT" "warn   shim: $T/ad-sym/stk is a symlink or a copy of another session-tracker installation ($(cd "$T/ad-old/bin" && pwd -P)/stk)"; then ok "doctor AD3: symlink to another session-tracker stk: names it as another installation"; else ko "doctor AD3: other installation: $(echo "$ADOUT" | grep shim)"; fi
addoc "$T/ad-other:$ADPATH2"
if has "$ADOUT" "warn   shim: \`stk\` in PATH is another program ($T/ad-other/stk)"; then ok "doctor AD3: another program called stk (a name collision)"; else ko "doctor AD3: other program: $(echo "$ADOUT" | grep shim)"; fi
addoc "$ADBIN:$ADPATH2" STK_PLUGIN_ROOT="$ADROOT"
if has "$ADOUT" "ok     shim: $ADBIN/stk -> $ADROOT/bin/stk (this installation)"; then ok "doctor AD3: the shim that resolves this installation is the only ok"; else ko "doctor AD3: shim ok: $(echo "$ADOUT" | grep shim)"; fi
addoc "$ADBIN:$ADPATH2" STK_PLUGIN_ROOT="$T/ad-mkt/plug"
if has "$ADOUT" "warn   shim: shim $ADBIN/stk resolves $T/ad-mkt/plug/bin/stk, but this stk runs from $ADROOT/bin/stk"; then ok "doctor AD3: shim that resolves another installation: two installations"; else ko "doctor AD3: shim elsewhere: $(echo "$ADOUT" | grep shim)"; fi
addoc "$ADBIN:$ADPATH2"
if has "$ADOUT" "warn   shim: shim $ADBIN/stk resolves no installation"; then ok "doctor AD3: shim without a target (no record, PATH without other stk)"; else ko "doctor AD3: empty shim: $(echo "$ADOUT" | grep shim)"; fi
# --remote: a fake ssh that RUNS the remote probe with sh, with a PATH per host ($T/ad-remote/<host>/bin): hubx has a session-tracker
# bin/stk (exit 0), broken a shim without a record (126), foreign another program called stk (125), nope nothing (127),
# down is unreachable (255). The hosts are remote_aliases + known_nodes minus this node, canon_host is NOT there (rsync, flock, uv and git run there, not stk)
mkdir -p "$T/ad-fakebin" "$T/ad-remote/hubx/bin" "$T/ad-remote/broken/bin" "$T/ad-remote/foreign/bin" "$T/ad-remote/nope/bin" "$T/ad-remote/down/bin"
printf '#!/usr/bin/env bash\n# stk — fake remote\n' > "$T/ad-remote/hubx/bin/stk"; chmod +x "$T/ad-remote/hubx/bin/stk"
install -m 755 "$ADROOT/shim/stk" "$T/ad-remote/broken/bin/stk"
printf '#!/usr/bin/env bash\necho other; exit 2\n' > "$T/ad-remote/foreign/bin/stk"; chmod +x "$T/ad-remote/foreign/bin/stk"
printf '#!/usr/bin/env bash\n# fake ssh: $5 is the host, $6 the command; the command really runs, in sh, with the PATH of that host\n[ "$5" = down ] && exit 255\nPATH="%s/ad-remote/$5/bin:%s" CLAUDE_DIR="%s/ad-nothing" sh -c "$6"\n' "$T" "$ADPATH" "$T" > "$T/ad-fakebin/ssh"; chmod +x "$T/ad-fakebin/ssh"
ADOUT=$(ABENV -u STK_LOCAL PATH="$T/ad-fakebin:$ADPATH2" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" STK_NODE=testnode STK_REMOTE_ALIASES="hubx, nope" STK_KNOWN_NODES="testnode, down, broken, foreign" STK_CANON_MODE=ssh STK_CANON_HOST=canonhost STK_CANON_PATH=/srv/s bash "$ADROOT/bin/stk" doctor --remote 2>&1); ADRC=$?
if has "$ADOUT" "ok     remotes: hubx: stk in $T/ad-remote/hubx/bin/stk" && has "$ADOUT" "warn   remotes: nope: stk is not in the ssh shell PATH (exit 127)" && has "$ADOUT" "warn   remotes: down: ssh cannot reach the host (exit 255)" && has "$ADOUT" "warn   remotes: broken: stk is there ($T/ad-remote/broken/bin/stk) but it is a shim that resolves no installation (exit 126)" && has "$ADOUT" "warn   remotes: foreign: \`stk\` in the ssh shell PATH is another program ($T/ad-remote/foreign/bin/stk)"; then ok "doctor AD3: --remote runs the probe on remote_aliases and known_nodes: bin/stk, missing, host down, shim without a record, other program"; else ko "doctor AD3: --remote: rc=$ADRC $(echo "$ADOUT" | grep remotes)"; fi
ADREM=$(echo "$ADOUT" | grep '^[a-z]*  *remotes:')
if ! has "$ADREM" "canonhost" && ! has "$ADREM" "testnode" && [ "$(echo "$ADREM" | wc -l | tr -d ' ')" = "5" ]; then ok "doctor AD3: --remote does not probe canon_host nor this node (5 remotes lines)"; else ko "doctor AD3: too many hosts: $ADREM"; fi
if grep -q "BatchMode=yes" "$ADROOT/helpers/doctor.py" && grep -q "ConnectTimeout=5" "$ADROOT/helpers/doctor.py"; then ok "doctor AD3: the --remote ssh is BatchMode with a connection timeout"; else ko "doctor AD3: ssh options"; fi
addoc "$ADPATH2" STK_REMOTE_ALIASES="hubx" STK_KNOWN_NODES="testnode, k2" STK_NODE=testnode
if has "$ADOUT" "ok     remotes: 2 hosts (hubx, k2): stk doctor --remote" && ! has "$ADOUT" "hubx: stk"; then ok "doctor AD3: without --remote no ssh, only the list of the hosts (aliases and known nodes minus this one)"; else ko "doctor AD3: without --remote: $(echo "$ADOUT" | grep remotes)"; fi
ADOUT=$(ABENV -u STK_LOCAL PATH="$T/ad-fakebin:$ADPATH2" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" doctor --remote 2>&1)
if has "$ADOUT" "ok     remotes: no alias"; then ok "doctor AD3: --remote without hosts says so"; else ko "doctor AD3: empty --remote: $(echo "$ADOUT" | grep remotes)"; fi
if ABENV PATH="$ADPATH2" CLAUDE_DIR="$T/ad-claude" XDG_CONFIG_HOME="$T/xdg-none" STK_LOCAL="$T/ad-local" bash "$ADROOT/bin/stk" doctor --bogus >/dev/null 2>&1; then ko "doctor AD3: --bogus accepted"; else ok "doctor AD3: unknown argument rejected"; fi

# AD5: CLAUDE_CONFIG_DIR applies to the whole of stk: scan reads the transcripts of that home, the open-tab guard its sessions/, and
# triage.py (via dashboard --triage) the same folders, because stk exports CLAUDE_DIR
AD5=dddd0000-0000-0000-0000-00000000dd01; mkdir -p "$T/ad5-cfg/projects/-ad5" "$T/ad5-cfg/sessions" "$T/ad5-empty/projects" "$T/ad5-empty/sessions" "$STK_CANON_PATH/testnode/-ad5"
printf '{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/ad5","uuid":"u1","sessionId":"%s"}\n' "$AD5" > "$T/ad5-cfg/projects/-ad5/$AD5.jsonl"
sleep 300 & AD5P=$!
printf '{"sessionId":"%s","pid":%s}' "$AD5" "$AD5P" > "$T/ad5-cfg/sessions/$AD5.json"
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nproject: ad5\nproject_path: /ad5\nencoded_project: "-ad5"\nstatus: active\nstatus_source: auto\nlast_activity_at: 2026-06-07T08:00:00Z\n---\n## extracted\n\n## user_notes\n' "$AD5" > "$STK_CANON_PATH/testnode/-ad5/$AD5.md"
bash "$STK" index >/dev/null 2>&1
ad5(){ env -u CLAUDE_DIR CLAUDE_CONFIG_DIR="$1" bash "$STK" "${@:2}"; }
if ad5 "$T/ad5-cfg" scan --all 2>/dev/null | jq -r .session_id | grep -q "^$AD5\$"; then ok "AD5: scan with CLAUDE_CONFIG_DIR alone reads the transcripts of that home"; else ko "AD5: scan with CLAUDE_CONFIG_DIR does not see the session"; fi
if ad5 "$T/ad5-empty" scan --all 2>/dev/null | jq -r .session_id | grep -q "^$AD5\$"; then ko "AD5: scan with an empty CLAUDE_CONFIG_DIR still sees the session (reads elsewhere)"; else ok "AD5: scan with an empty CLAUDE_CONFIG_DIR sees nothing (the check can say no)"; fi
if ad5 "$T/ad5-cfg" close --session "$AD5" --status done >/dev/null 2>&1; then ko "AD5: the open-tab guard does not read sessions/ of CLAUDE_CONFIG_DIR"; else ok "AD5: the open-tab guard reads sessions/ of CLAUDE_CONFIG_DIR and refuses"; fi
TRI=$(ad5 "$T/ad5-cfg" dashboard --triage 2>/dev/null | grep -o 'open now [0-9]*' | head -1)
eq "AD5: dashboard --triage sees the live tab in the same home (CLAUDE_DIR exported to the helpers)" "$TRI" "open now 1"
TRI=$(ad5 "$T/ad5-empty" dashboard --triage 2>/dev/null | grep -o 'open now [0-9]*' | head -1)
eq "AD5: with an empty home the triage sees no live tabs (the check can say no)" "$TRI" "open now 0"
kill "$AD5P" 2>/dev/null

echo "== AE: where reads the store index in local mode and requires a declared map; scan, merge.py and the lock refuse relative paths; doctor validates the slug and reports a relative data_dir once; the hook says when the naming context is degraded =="
AE=eeee0000-0000-0000-0000-0000000000
# AE1: canon_mode=local, no --index: the cluster comes from <store>/index.jsonl, not from the
# mirror canon/ (one round behind after `sync both`). The mirror holds a canary row on another node:
# if where read it, the candidate would be that node.
mkdir -p "$T/ae-local/store" "$T/ae-local/canon"; cp "$WNM" "$T/ae-local/naming-map.yaml"
printf '{"session_id":"ae-store-1","node":"alpha","project_path":"/home/u/code/acme-site","name":"acme-deploy-setup","name_source":"user","class":"task","status":"active","tags":["acme"],"last_activity_at":"2026-06-20T10:00:00Z","dormancy_risk":"low"}\n' > "$T/ae-local/store/index.jsonl"
printf '{"session_id":"ae-mirror-1","node":"mirrornode","project_path":"/home/u/code/acme-site","name":"acme-deploy-setup","name_source":"user","class":"task","status":"active","tags":["acme"],"last_activity_at":"2026-06-21T10:00:00Z","dormancy_risk":"low"}\n' > "$T/ae-local/canon/index.jsonl"
aew(){ ABENV STK_LOCAL="$T/ae-local" XDG_CONFIG_HOME="$T/xdg-none" "$@" bash "$STK" where --node bravo --cwd /Users/x/acme-site; }
J=$(aew); RC=$?
eq "where AE1: canon_mode=local without --index reads the store index (candidate on alpha, not the mirror's node)" "$(echo "$J"|jq -r '.candidates[0].node')" "alpha"
eq "where AE1: verdict elsewhere from the store" "$(echo "$J"|jq -r .verdict)" "elsewhere"
J=$(aew STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/s)
eq "where AE1: with canon_mode=ssh the mirror is the local copy and is read (the control can say no)" "$(echo "$J"|jq -r '.candidates[0].node')" "mirrornode"
J=$(ABENV STK_LOCAL="$T/ae-local" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" where --node bravo --cwd /Users/x/acme-site --index "$T/ae-local/canon/index.jsonl")
eq "where AE1: an explicit --index is taken as is, whatever the mode (the mirror's row)" "$(echo "$J"|jq -r '.candidates[0].node')" "mirrornode"
# AE2: a map declared in config (file or env) but missing stops where with exit 2 and names it;
# the default path missing is still "no map"; a relative map is a config error.
mkdir -p "$T/xdg-ae-nm/session-tracker" "$T/ae-nomap"; printf 'naming_map = %s/ae-nope.yaml\n' "$T" > "$T/xdg-ae-nm/session-tracker/config"
OUTW=$(ABENV STK_LOCAL="$T/ae-nomap" XDG_CONFIG_HOME="$T/xdg-ae-nm" bash "$STK" where --node bravo --cwd /x/foo-repo --index /dev/null 2>/dev/null); RC=$?
eq "where AE2: naming_map declared but missing -> exit 2" "$RC" "2"
if has "$OUTW" '"naming_map_error"' && has "$OUTW" "declared but missing ($T/ae-nope.yaml)"; then ok "where AE2: the JSON carries naming_map_error with the path"; else ko "where AE2: output: $OUTW"; fi
OUTW=$(ABENV STK_LOCAL="$T/ae-nomap" STK_NAMING_MAP="$T/ae-nope.yaml" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" where --node bravo --cwd /x/foo-repo --index /dev/null --human 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 2 ] && has "$OUTW" "where: naming_map declared but missing"; then ok "where AE2: declared by env, --human says it on stderr and exits 2"; else ko "where AE2: env + --human: rc=$RC $OUTW"; fi
J=$(ABENV STK_LOCAL="$T/ae-nomap" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" where --node bravo --cwd /x/foo-repo --index /dev/null); RC=$?
eq "where AE2: the default map path missing is 'no map' (exit 0)" "$RC" "0"
eq "where AE2: ... and the subject falls back to the folder name" "$(echo "$J"|jq -r .current.subject)" "foo-repo"
printf 'contexts: [a, b]\n' > "$T/ae-bad.yaml"
OUTW=$(ABENV STK_LOCAL="$T/ae-nomap" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" where --node bravo --cwd /x/foo-repo --index /dev/null --naming-map "$T/ae-bad.yaml" 2>/dev/null); RC=$?
if [ "$RC" -eq 2 ] && has "$OUTW" '"naming_map_error"'; then ok "where AE2: a malformed map is an error too (exit 2), not a map with no entries"; else ko "where AE2: malformed map: rc=$RC $OUTW"; fi
ERRW=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ae-nomap" STK_NAMING_MAP=rel-map.yaml XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" where --node bravo --cwd /x/foo-repo --index /dev/null 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ERRW" "naming_map=rel-map.yaml relative"; then ok "where AE2: a relative naming_map stops where before reading the map in the current folder"; else ko "where AE2: relative map: rc=$RC $ERRW"; fi
# AE3: scan, merge.py and the lock of index/publish refuse a relative path and create nothing in the cwd
ERRS=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="rel-data" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" scan --all 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 0 ] && has "$ERRS" "data_dir=rel-data relative" && [ ! -e "$T/ac-cwd/rel-data" ]; then ok "scan AE3: a relative data_dir stops scan and nothing is created in the cwd"; else ko "scan AE3: rc=$RC $ERRS $(ls "$T/ac-cwd" | tr '\n' ' ')"; fi
ERRM=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="rel-data" XDG_CONFIG_HOME="$T/xdg-none" $PY "$H/merge.py" 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 2 ] && has "$ERRM" "merge.py: data_dir=rel-data relative:" && [ ! -e "$T/ac-cwd/rel-data" ]; then ok "merge AE3: merge.py exits 2 on a relative data_dir before reading or writing"; else ko "merge AE3: rc=$RC $ERRM"; fi
ERRM=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ae-merge-abs" XDG_CONFIG_HOME="$T/xdg-none" $PY "$H/merge.py" 2>&1 >/dev/null); RC=$?
if [ "$RC" -ne 2 ] && has "$ERRM" "manifest.jsonl"; then ok "merge AE3: control, with an absolute data_dir merge.py gets past the check (and misses the manifest)"; else ko "merge AE3: control: rc=$RC $ERRM"; fi
mkdir -p "$T/ae-lock"
for sub in index publish; do
    ERRL=$(cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ae-lock" STK_CANON_LOCK=rel.lock XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" $sub 2>&1 >/dev/null); RC=$?
    if [ "$RC" -ne 0 ] && has "$ERRL" "STK_CANON_LOCK=rel.lock relative" && [ ! -e "$T/ac-cwd/rel.lock" ]; then ok "lock AE3: $sub refuses a relative STK_CANON_LOCK and creates no lockfile in the cwd"; else ko "lock AE3: $sub: rc=$RC $ERRL $(ls "$T/ac-cwd" | tr '\n' ' ')"; fi
done
if (cd "$T/ac-cwd" && ABENV STK_LOCAL="$T/ae-lock" STK_CANON_LOCK="$T/ae-abs.lock" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" index >/dev/null 2>&1) && [ -e "$T/ae-abs.lock" ]; then ok "lock AE3: control, an absolute STK_CANON_LOCK is used as is"; else ko "lock AE3: absolute lock refused or not created"; fi
# AE4: doctor validates the node slug with the lexicon of `stk init --node`, and a relative
# data_dir is one error, not three (canon_path and naming_map derived from it are not repeated)
aedoc(){ ACOUT=$(cd "$T/ac-cwd" && ABENV env -u STK_LOCAL -u STK_NODE CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$1" "${@:2}" bash "$STK" doctor 2>&1); ACRC=$?; }
mkdir -p "$T/xdg-ae-doc/session-tracker"
printf 'node = My Node\ndata_dir = %s/ae-doc\n' "$T" > "$T/xdg-ae-doc/session-tracker/config"
aedoc "$T/xdg-ae-doc"
if [ "$ACRC" -eq 1 ] && has "$ACOUT" 'error  node: `My Node` is not a slug'; then ok "doctor AE4: node that is not a slug -> error, exit 1"; else ko "doctor AE4: node 'My Node': rc=$ACRC $(printf '%s' "$ACOUT" | grep -E 'node|doctor:')"; fi
printf 'data_dir = %s/ae-doc\n' "$T" > "$T/xdg-ae-doc/session-tracker/config"; mkdir -p "$T/ae-doc"; printf 'Bad Slug\n' > "$T/ae-doc/node"
aedoc "$T/xdg-ae-doc"
if [ "$ACRC" -eq 1 ] && has "$ACOUT" 'error  node: `Bad Slug` is not a slug'; then ok "doctor AE4: the slug from the node file is checked too"; else ko "doctor AE4: node file: rc=$ACRC $(printf '%s' "$ACOUT" | grep -E 'node|doctor:')"; fi
printf 'node = my-node.1\ndata_dir = %s/ae-doc\n' "$T" > "$T/xdg-ae-doc/session-tracker/config"
aedoc "$T/xdg-ae-doc"
if [ "$ACRC" -eq 0 ] && has "$ACOUT" 'ok     node: my-node.1'; then ok "doctor AE4: control, a valid slug is ok"; else ko "doctor AE4: valid slug: rc=$ACRC $(printf '%s' "$ACOUT" | grep -E 'node|doctor:')"; fi
printf 'data_dir = rel-data\n' > "$T/xdg-ae-doc/session-tracker/config"
aedoc "$T/xdg-ae-doc"
NPE=$(printf '%s\n' "$ACOUT" | grep -c '^error  path:')
if [ "$ACRC" -eq 1 ] && [ "$NPE" = "1" ] && has "$ACOUT" 'error  path: data_dir=rel-data relative:' && [ ! -e "$T/ac-cwd/rel-data" ]; then ok "doctor AE4: a relative data_dir is reported once (derived canon_path and naming_map not repeated)"; else ko "doctor AE4: relative data_dir: rc=$ACRC path errors=$NPE"; fi
printf 'data_dir = rel-data\nnaming_map = rel-map.yaml\n' > "$T/xdg-ae-doc/session-tracker/config"
aedoc "$T/xdg-ae-doc"
NPE=$(printf '%s\n' "$ACOUT" | grep -c '^error  path:')
if [ "$NPE" = "2" ] && has "$ACOUT" 'error  path: naming_map=rel-map.yaml relative:'; then ok "doctor AE4: a naming_map the user wrote is still reported next to data_dir (the control can say no)"; else ko "doctor AE4: explicit relative map: path errors=$NPE"; fi
# AE5: without uv in the hook's PATH the hook injects the rest, the text says the naming context
# was not resolved, and the log says degraded; with a helper that fails the reason is its exit code
mkdir -p "$T/ae-hook" "$T/ae-fakeuv"; printf '#!/bin/sh\nexit 3\n' > "$T/ae-fakeuv/uv"; chmod +x "$T/ae-fakeuv/uv"
OUTH=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AE}51" | ABENV env PATH=/usr/bin:/bin STK_LOCAL="$T/ae-hook" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$OUTH" "Naming context NOT resolved" && has "$OUTH" "no-uv" && has "$OUTH" "/rename wip-"; then ok "hook AE5: without uv the hook still injects and says the naming context was not resolved"; else ko "hook AE5: no uv: ${OUTH:0:200}"; fi
if grep -q "	inject:startup degraded:naming-context:no-uv$" "$T/ae-hook/hook.log"; then ok "hook AE5: the log says inject ... degraded:naming-context:no-uv"; else ko "hook AE5: log: $(tail -1 "$T/ae-hook/hook.log")"; fi
OUTH=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AE}52" | ABENV env PATH="$T/ae-fakeuv:$PATH" STK_LOCAL="$T/ae-hook" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$OUTH" "Naming context NOT resolved" && has "$OUTH" "helper-rc=3" && grep -q "	inject:startup degraded:naming-context:helper-rc=3$" "$T/ae-hook/hook.log"; then ok "hook AE5: a helper that fails is degraded with its exit code, in the text and in the log"; else ko "hook AE5: failing helper: ${OUTH:0:200} / $(tail -1 "$T/ae-hook/hook.log")"; fi
OUTH=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AE}53" | ABENV STK_LOCAL="$T/ae-hook" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if ! has "$OUTH" "NOT resolved" && has "$OUTH" "/rename wip-" && grep -q "	inject:startup$" "$T/ae-hook/hook.log"; then ok "hook AE5: control, with uv the context is resolved and the log line has no degraded mark"; else ko "hook AE5: control: ${OUTH:0:200} / $(tail -1 "$T/ae-hook/hook.log")"; fi

# AE6 (kb_layout): the folder names of a knowledge base are data of the map, not literals of the
# resolver. The suite's map declares root wiki / orgs_dir teams / token wk: a folder tree under another
# root is NOT a kb, whatever its folders are called.
eq "naming AE6: a kb root with another name is not a kb (recognition comes from the map, not from a literal)" "$($PY "$H/naming.py" context --cwd /h/base/depts/acme/product --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)" "unknown"
eq "naming AE6: ... nor a tier under it" "$($PY "$H/naming.py" context --cwd /h/base/alpha/x --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)" "unknown"
# a root or an orgs folder with a name the map does not declare, next to the declared ones, must not be
# recognized either (only the map's names count)
eq "naming AE6: a root the map does not declare is not recognized next to the declared orgs folder" "$($PY "$H/naming.py" context --cwd /h/kb/teams/acme/product --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)" "unknown"
eq "naming AE6: an orgs folder the map does not declare is not recognized under the declared root" "$($PY "$H/naming.py" context --cwd /h/wiki/orgs/acme/product --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r .kind)" "unknown"
eq "naming AE6: control, the declared root resolves the org" "$($PY "$H/naming.py" context --cwd /h/wiki/teams/acme/product --naming-map "$STK_LOCAL/naming-map.yaml" | jq -r '"\(.kind) \(.subject)"')" "kb-org acme-kb-product"
printf 'contexts: {}\nkb_layout: {root: notes, orgs_dir: clients, token: nt}\nkb_tiers:\n  team: t\nkb_orgs:\n  acme:\n    umbrella: acme-notes\n    repos: {}\n' > "$T/ae-layout2.yaml"
eq "naming AE6: another layout resolves its own tier folder with its own token" "$($PY "$H/naming.py" context --cwd /h/notes/team/net --naming-map "$T/ae-layout2.yaml" | jq -r '"\(.kind) \(.subject)"')" "kb-tier nt-t-net"
eq "naming AE6: another layout resolves its own orgs folder" "$($PY "$H/naming.py" context --cwd /h/notes/clients/acme/docs --naming-map "$T/ae-layout2.yaml" | jq -r '"\(.kind) \(.subject)"')" "kb-org acme-notes"
eq "naming AE6: the guard accepts the name with that token" "$($PY "$H/naming.py" check --cwd /h/notes/team/net --name nt-t-net-router-check --naming-map "$T/ae-layout2.yaml" --naming-md "$H/../references/naming.md" >/dev/null 2>&1; echo $?)" "0"
eq "naming AE6: ... and rejects the token of the suite's map" "$($PY "$H/naming.py" check --cwd /h/notes/team/net --name wk-t-net-router-check --naming-map "$T/ae-layout2.yaml" --naming-md "$H/../references/naming.md" >/dev/null 2>&1; echo $?)" "1"
printf 'contexts: {}\nkb_tiers:\n  alpha: al\n' > "$T/ae-nolayout.yaml"
OUTK=$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wk-al-x-fix --naming-map "$T/ae-nolayout.yaml" 2>/dev/null); RC=$?
if [ "$RC" -eq 2 ] && has "$OUTK" '`kb_layout` (root, orgs_dir, token) is missing'; then ok "naming AE6: kb_tiers without kb_layout -> exit 2 and the reason names kb_layout (not a silent off)"; else ko "naming AE6: no layout: rc=$RC $OUTK"; fi
printf 'contexts: {}\nkb_layout: {root: wiki, orgs_dir: teams}\n' > "$T/ae-badlayout.yaml"
OUTK=$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wk-al-x-fix --naming-map "$T/ae-badlayout.yaml" 2>/dev/null); RC=$?
if [ "$RC" -eq 2 ] && has "$OUTK" '`kb_layout` is not a mapping'; then ok "naming AE6: kb_layout without token -> exit 2 and the reason names kb_layout"; else ko "naming AE6: bad layout: rc=$RC $OUTK"; fi
printf 'contexts: {}\nkb_layout: {root: wiki, orgs_dir: teams, token: WK}\n' > "$T/ae-badlayout2.yaml"
printf 'contexts: {}\nkb_layout: {root: wiki, orgs_dir: teams, token: wk, extra: x}\n' > "$T/ae-badlayout3.yaml"
eq "naming AE6: kb_layout with an unknown key (and a valid value) -> exit 2: the key set is checked, not only the values" "$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wk-al-x-fix --naming-map "$T/ae-badlayout3.yaml" >/dev/null 2>&1; echo $?)" "2"
# without kb_layout no folder name is a kb, whatever it is called: several candidate names, built from
# variables, so that a resolver falling back to a built-in layout when the section is absent is caught (the
# suite's own map always has the section, so the other AE6 checks cannot see that fallback)
printf 'contexts: {other: oth}\n' > "$T/ae-ctxonly.yaml"
for r in kb wiki; do for o in orgs teams; do
    mkdir -p "$T/h/$r/$o/other/fnx/.git"
    eq "naming AE6: no kb_layout -> <root>/<orgs>/<org>/<repo> is not a kb org (contexts-only map, candidate ${r:0:1}/${o:0:1})" "$($PY "$H/naming.py" context --cwd "$T/h/$r/$o/other/fnx" --naming-map "$T/ae-ctxonly.yaml" | jq -r '"\(.kind) \(.subject)"')" "unknown fnx"
done; done
eq "naming AE6: kb_layout token outside [a-z0-9] -> exit 2" "$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wk-al-x-fix --naming-map "$T/ae-badlayout2.yaml" >/dev/null 2>&1; echo $?)" "2"
printf 'contexts: {}\n' > "$T/ae-nokb.yaml"
eq "naming AE6: no kb sections at all: a folder under any root is unknown and a generic name passes" "$($PY "$H/naming.py" check --cwd /h/wiki/alpha/x --name wiki-thing-fix --naming-map "$T/ae-nokb.yaml" --naming-md "$H/../references/naming.md" >/dev/null 2>&1; echo $?)" "0"
if ABENV STK_LOCAL="$STK_LOCAL" CLAUDE_DIR="$T/ac-claude" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" doctor 2>&1 | grep -q 'kb_layout wiki/teams, token wk'; then ok "doctor AE6: the naming_map line shows the kb layout"; else ko "doctor AE6: layout not shown"; fi

# AE7: a bad hook_ask_intent value is logged once even when the placement clause (which reuses the answer) is on
mkdir -p "$T/ae-hook2"
printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "${AE}71" | ABENV STK_HOOK_ASK_INTENT=maybe STK_HOOK_PLACEMENT=on STK_LOCAL="$T/ae-hook2" XDG_CONFIG_HOME="$T/xdg-none" bash "$STK" hook >/dev/null 2>&1
eq "hook AE7: hook_ask_intent=maybe with placement on is logged once" "$(grep -c 'warn:hook_ask_intent=maybe' "$T/ae-hook2/hook.log")" "1"

echo "== AF: remote command quoting, -u alias lexicon, pull failures, frontmatter delimiter lines, YAML-safe note stub, children kept, link events, branch clause with an intent, push retry, exclusive temp files =="
AF=ffff0000-0000-0000-0000-0000000000
AFENV(){ env -u STK_CANON_MODE -u STK_CANON_HOST -u STK_CANON_PATH -u STK_CANON_GIT -u STK_NAMING_POLICY -u STK_NAMING_MAP -u STK_HOOK_ASK_INTENT -u STK_HOOK_PLACEMENT -u STK_HOOK_PRIMARY_CHECK -u STK_HOOK_TMUX_TAB -u TMUX_PANE "$@"; }
mkdir -p "$T/af-bin" "$T/af-host/srv" "$T/af-local" "$T/xdg-af"; AFLOG="$T/af-ssh.log"; : > "$AFLOG"
# fake ssh: records "ssh <host> <command>"; host `down` is unreachable (255); `test -e <path>` is evaluated under $T/af-host, the host's filesystem
cat > "$T/af-bin/ssh" <<EOF
#!/usr/bin/env bash
host=""; cmd=""; skip=0
for a in "\$@"; do if [ "\$skip" = 1 ]; then skip=0; continue; fi; case "\$a" in -o) skip=1;; *) if [ -z "\$host" ]; then host="\$a"; else cmd="\$a"; fi;; esac; done
printf 'ssh %s %s\n' "\$host" "\$cmd" >> "$AFLOG"
[ "\$host" = down ] && exit 255
case "\$cmd" in "p="*|"test -e "*) cmd=\${cmd//\/srv\//$T\/af-host\/srv\/}; sh -c "\$cmd"; exit \$?;; esac
exit 0
EOF
# fake rsync: a host:path operand is mapped to $T/af-host<path> (host `down`: 255), then the real rsync runs, so partial transfers keep their exit code
cat > "$T/af-bin/rsync" <<EOF
#!/usr/bin/env bash
args=(); for a in "\$@"; do case "\$a" in down:*) printf 'rsync %s\n' "\$*" >> "$AFLOG"; exit 255;; *:/*) args+=("$T/af-host\${a#*:}");; *) args+=("\$a");; esac; done
printf 'rsync %s\n' "\$*" >> "$AFLOG"
exec "$REAL_RSYNC" "\${args[@]}"
EOF
chmod +x "$T/af-bin/ssh" "$T/af-bin/rsync"
af(){ AFENV PATH="$T/af-bin:$PATH" STK_LOCAL="$T/af-local" XDG_CONFIG_HOME="$T/xdg-af" STK_NODE=testnode "$@"; }
afget(){ $PY -c "import yaml,sys,re;d=yaml.safe_load(re.split(r'(?m)^---[ \t]*\$\n?',open(sys.argv[1]).read(),2)[1]);print(d.get(sys.argv[2],''))" "$1" "$2" 2>&1; }
afdg(){ printf '{"session_id":"%s","lang":"en","goal":"g","summary":"s","done":[],"open":[],"decisions":[],"internal_branches":[],"pilot_candidates":[],"proposed_status":"active","tags":[]}\n' "$1"; }
# mkmut <name> <python-file-or-empty> <python replace old> <python replace new>: a copy of stk whose helpers/ links the real ones except one rewritten file
mkmut(){ mkdir -p "$T/mut-$1/bin" "$T/mut-$1/helpers"; cp "$STK" "$T/mut-$1/bin/stk"; chmod +x "$T/mut-$1/bin/stk"; ln -sfn "$(cd "$H/../references" && pwd)" "$T/mut-$1/references"
  for hf in "$H"/*.py; do cp "$hf" "$T/mut-$1/helpers/$(basename "$hf")"; done   # copies, not links: realpath(__file__) must stay in the mutant folder
  if [ -n "$2" ]; then rm -f "$T/mut-$1/helpers/$2"; $PY - "$H/$2" "$T/mut-$1/helpers/$2" "$3" "$4" <<'EOF'
import sys; src, dst, old, new = sys.argv[1:5]; s = open(src).read()
assert s.count(old) == 1, f"{src}: {s.count(old)} occurrences of the mutation target"
open(dst, "w").write(s.replace(old, new))
EOF
  fi; }
PATH="$T/af-bin:$PATH" ssh canary true; if grep -q '^ssh canary true$' "$AFLOG"; then ok "AF0: the fake ssh records"; else ko "AF0: fake ssh does not record"; fi
# AF1: canon_path, the lock and the commit message reach the host as single words (a `;` or a space is data, not a second command)
EPAF1=$(mkw "${AF}01" /x/foo-repo); af bash "$STK" note --session "${AF}01" --kind intent "af" >/dev/null 2>&1
: > "$AFLOG"; af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH='/srv/a b; id' bash "$STK" sync publish >/dev/null 2>&1
if grep -qF 'ssh hubx mkdir -p /srv/a\ b\;\ id/testnode' "$AFLOG" && ! grep -qF 'mkdir -p /srv/a b; id' "$AFLOG"; then ok "quote AF1: canon_path reaches the host as one word in the publish mkdir"; else ko "quote AF1: mkdir line: $(grep mkdir "$AFLOG")"; fi
: > "$AFLOG"; af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH='/srv/a b; id' bash "$STK" index >/dev/null 2>&1
if grep -qF 'flock /srv/a\ b\;\ id/.stk.lock uv run' "$AFLOG" && grep -qF 'python - /srv/a\ b\;\ id' "$AFLOG"; then ok "quote AF1: the lock and the path are quoted in the index command"; else ko "quote AF1: index line: $(grep flock "$AFLOG")"; fi
mkdir -p "$T/af-host/srv/a b; id/testnode"   # the fake rsync maps the slice here: it must exist for the git script to be reached
: > "$AFLOG"; af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH='/srv/a b; id' STK_CANON_GIT=auto bash "$STK" publish >/dev/null 2>&1
if grep -qF 'bash -s -- /srv/a\ b\;\ id data' "$AFLOG"; then ok "quote AF1: the git script receives the quoted path"; else ko "quote AF1: publish line: $(grep 'bash -s' "$AFLOG")"; fi
: > "$AFLOG"; af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH='~/x y' bash "$STK" index >/dev/null 2>&1
if grep -qF 'flock ~/x\ y/.stk.lock' "$AFLOG"; then ok "quote AF1: a leading ~/ stays bare for the host's shell, the rest is quoted"; else ko "quote AF1: tilde: $(grep flock "$AFLOG")"; fi
mkmut rq "" "" ""; sedi 's/^_rq() { .*$/_rq() { printf "%s" "$1"; }/' "$T/mut-rq/bin/stk"
if grep -q '^_rq() { printf "%s" "$1"; }$' "$T/mut-rq/bin/stk"; then ok "mutation AF1: the copy does not quote"; else ko "mutation AF1: sed did not change _rq"; fi
: > "$AFLOG"; af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH='/srv/a b; id' bash "$T/mut-rq/bin/stk" sync publish >/dev/null 2>&1
if grep -qF 'mkdir -p /srv/a b; id/testnode' "$AFLOG"; then ok "mutation AF1: without quoting the host would receive a second command (AF1 measures the quoting)"; else ko "mutation AF1: the mutant still quotes: $(grep mkdir "$AFLOG")"; fi
# AF2: the -u alias is also the remote STK_NODE inside the command string: the slug lexicon keeps it one word
: > "$AFLOG"; AFERR=$(af bash "$STK" -u 'alias; id' scan 2>&1 >/dev/null); AFRC=$?
if [ "$AFRC" -ne 0 ] && has "$AFERR" "is not a node slug" && [ ! -s "$AFLOG" ]; then ok "alias AF2: -u with an alias outside the slug lexicon stops before any ssh"; else ko "alias AF2: rc=$AFRC $AFERR log=$(cat "$AFLOG")"; fi
: > "$AFLOG"; af bash "$STK" -u hubx scan >/dev/null 2>&1
if grep -q '^ssh hubx STK_NODE=hubx stk scan' "$AFLOG"; then ok "alias AF2: control, a slug alias reaches ssh with STK_NODE"; else ko "alias AF2: control: $(cat "$AFLOG")"; fi
mkmut alias "" "" ""; sedi '/is not a node slug/d' "$T/mut-alias/bin/stk"
: > "$AFLOG"; af bash "$T/mut-alias/bin/stk" -u 'alias; id' scan >/dev/null 2>&1
if grep -qF '; id' "$AFLOG"; then ok "mutation AF2: without the lexicon check the alias reaches the command string (AF2 measures the check)"; else ko "mutation AF2: the mutant still stops: $(cat "$AFLOG")"; fi
# AF3: a pull that fails is an error; only the first round (no canon, no slice yet) is not
mkdir -p "$T/af-canon/testnode/-x-foo-repo"; for n in a b c; do printf -- '---\nschema: v0\nsession_id: %s\n---\n' "$n" > "$T/af-canon/testnode/-x-foo-repo/$n.md"; done; chmod 000 "$T/af-canon/testnode/-x-foo-repo/b.md"
AFERR=$(af env STK_CANON_MODE=local STK_CANON_PATH="$T/af-canon" STK_LOCAL="$T/af-local2" bash "$STK" sync pull 2>&1 >/dev/null); AFRC=$?
if [ "$AFRC" -ne 0 ] && has "$AFERR" "pull: the node's slice failed (rsync exit 23)"; then ok "pull AF3: a partial local pull exits non-zero and says which transfer failed"; else ko "pull AF3: partial local: rc=$AFRC $AFERR"; fi
chmod 644 "$T/af-canon/testnode/-x-foo-repo/b.md"
if af env STK_CANON_MODE=local STK_CANON_PATH="$T/af-canon" STK_LOCAL="$T/af-local2" bash "$STK" sync pull >/dev/null 2>&1 && [ -f "$T/af-local2/shard/-x-foo-repo/b.md" ]; then ok "pull AF3: control, the same pull passes once the record is readable"; else ko "pull AF3: control failed"; fi
: > "$AFLOG"; AFERR=$(af env STK_CANON_MODE=ssh STK_CANON_HOST=down STK_CANON_PATH=/srv/sessions STK_LOCAL="$T/af-local3" bash "$STK" sync pull 2>&1 >/dev/null); AFRC=$?
if [ "$AFRC" -ne 0 ] && has "$AFERR" "unreachable (ssh exit 255)" && ! grep -q '^rsync' "$AFLOG"; then ok "pull AF3: an unreachable canon host is an error, no rsync attempted"; else ko "pull AF3: down host: rc=$AFRC $AFERR $(cat "$AFLOG")"; fi
: > "$AFLOG"; AFOUT=$(af env STK_CANON_MODE=ssh STK_CANON_HOST=down STK_CANON_PATH=/srv/sessions STK_LOCAL="$T/af-local3" bash "$STK" sync both 2>&1); AFRC=$?
if [ "$AFRC" -ne 0 ] && ! has "$AFOUT" "publish ->" && ! grep -q 'mkdir' "$AFLOG"; then ok "pull AF3: sync both stops at the failed pull and does not publish"; else ko "pull AF3: both: rc=$AFRC $AFOUT"; fi
: > "$AFLOG"; AFOUT=$(af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/nothing STK_LOCAL="$T/af-local3" bash "$STK" sync pull 2>&1); AFRC=$?
if [ "$AFRC" -eq 0 ] && has "$AFOUT" "first round, nothing to pull"; then ok "pull AF3: no canon on the host yet is the first round, exit 0"; else ko "pull AF3: first round: rc=$AFRC $AFOUT"; fi
mkdir -p "$T/af-host/srv/sessions/othernode"; printf 'contexts: {foo-repo: foo}\n' > "$T/af-host/srv/sessions/naming-map.yaml"
: > "$AFLOG"; AFOUT=$(af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/sessions STK_LOCAL="$T/af-local3" bash "$STK" sync pull 2>&1); AFRC=$?
if [ "$AFRC" -eq 0 ] && has "$AFOUT" "first round for this node" && [ -d "$T/af-local3/canon/othernode" ] && [ -f "$T/af-local3/naming-map.yaml" ]; then ok "pull AF3: no slice for this node yet: exit 0, the mirror and the map still arrive"; else ko "pull AF3: node first round: rc=$AFRC $AFOUT $(ls "$T/af-local3" 2>&1 | tr '\n' ' ')"; fi
mkdir -p "$T/af-host/srv/sessions/testnode/-x-foo-repo"; printf -- '---\nschema: v0\n---\n' > "$T/af-host/srv/sessions/testnode/-x-foo-repo/z.md"; chmod 000 "$T/af-host/srv/sessions/testnode/-x-foo-repo/z.md"
AFERR=$(af env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/sessions STK_LOCAL="$T/af-local3" bash "$STK" sync pull 2>&1 >/dev/null); AFRC=$?
if [ "$AFRC" -ne 0 ] && has "$AFERR" "the node's slice failed (rsync exit 23)"; then ok "pull AF3: a partial remote pull is an error too"; else ko "pull AF3: remote partial: rc=$AFRC $AFERR"; fi
chmod 644 "$T/af-host/srv/sessions/testnode/-x-foo-repo/z.md"
mkmut rsync "" "" ""; sedi 's/^_rsync_or_die() { .*$/_rsync_or_die() { shift; "$@" || true; }/' "$T/mut-rsync/bin/stk"
chmod 000 "$T/af-canon/testnode/-x-foo-repo/b.md"
if grep -q '"$@" || true; }$' "$T/mut-rsync/bin/stk" && af env STK_CANON_MODE=local STK_CANON_PATH="$T/af-canon" STK_LOCAL="$T/af-local4" bash "$T/mut-rsync/bin/stk" sync pull >/dev/null 2>&1; then ok "mutation AF3: with the old || true the partial pull passes (AF3 measures the exit status)"; else ko "mutation AF3: the mutant still fails the partial pull"; fi
chmod 644 "$T/af-canon/testnode/-x-foo-repo/b.md"
# AF4: a --- inside a value is data: the frontmatter ends at a delimiter LINE (close, note, merge)
EPAF4=$(mkw "${AF}04" /x/foo-repo)
af env STK_NAMING_POLICY=off bash "$STK" close --session "${AF}04" --status done --name 'foo---bar' >/dev/null 2>&1
af bash "$STK" note --session "${AF}04" --kind future "n4" >/dev/null 2>&1
af bash "$STK" scan --all > "$T/af-local/manifest.jsonl" 2>/dev/null; afdg "${AF}04" > "$T/af-d4.jsonl"; af $PY "$H/merge.py" "$T/af-d4.jsonl" >/dev/null 2>&1; AFMRC=$?
if [ "$AFMRC" -eq 0 ] && [ "$(afget "$T/af-local/shard/$EPAF4/${AF}04.md" name)" = "foo---bar" ] && [ "$(afget "$T/af-local/shard/$EPAF4/${AF}04.md" status_source)" = "user" ] && grep -q 'n4' "$T/af-local/shard/$EPAF4/${AF}04.md"; then ok "fm AF4: a --- inside a value survives note and merge (delimiter lines only)"; else ko "fm AF4: $(grep -E '^name|^status' "$T/af-local/shard/$EPAF4/${AF}04.md" | tr '\n' ' ')"; fi
mkmut fm config.py 'parts = re.split(FRONTMATTER_RE, raw, maxsplit=2)' 'parts = raw.split("---", 2)'
EPAF4b=$(mkw "${AF}05" /x/foo-repo); af env STK_NAMING_POLICY=off bash "$STK" close --session "${AF}05" --status done --name 'foo---bar' >/dev/null 2>&1
af bash "$STK" scan --all > "$T/af-local/manifest.jsonl" 2>/dev/null; afdg "${AF}05" > "$T/af-d5.jsonl"; af $PY "$T/mut-fm/helpers/merge.py" "$T/af-d5.jsonl" >/dev/null 2>&1
if [ "$(afget "$T/af-local/shard/$EPAF4b/${AF}05.md" status_source)" != "user" ]; then ok "mutation AF4: with the old split the merge loses the user override (AF4 measures the delimiter rule)"; else ko "mutation AF4: the mutant keeps the override"; fi
# AF5: the note stub writes the cwd as a quoted YAML scalar
EPAF5=$(mkw "${AF}06" '/x/a: b'); af bash "$STK" note --session "${AF}06" --kind intent "i6" >/dev/null 2>&1
if [ "$(afget "$T/af-local/shard/$EPAF5/${AF}06.md" project_path)" = "/x/a: b" ] && [ "$(afget "$T/af-local/shard/$EPAF5/${AF}06.md" project)" = "a: b" ]; then ok "stub AF5: a cwd with ': ' is a quoted scalar in the note stub, the YAML stays valid"; else ko "stub AF5: $(sed -n 5,6p "$T/af-local/shard/$EPAF5/${AF}06.md" | tr '\n' ' ')"; fi
mkmut stub "" "" ""; $PY - "$T/mut-stub/bin/stk" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
old = 'echo "project_path: $(jq -nr --arg v "${cwd}" \'$v|@json\')"'
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, 'echo "project_path: ${cwd}"'))
EOF
EPAF5b=$(mkw "${AF}07" '/x/a: b'); af bash "$T/mut-stub/bin/stk" note --session "${AF}07" --kind intent "i7" >/dev/null 2>&1
if grep -qF 'echo "project_path: ${cwd}"' "$T/mut-stub/bin/stk" && [ "$(afget "$T/af-local/shard/$EPAF5b/${AF}07.md" project_path)" != "/x/a: b" ]; then ok "mutation AF5: the raw echo breaks the YAML (AF5 measures the quoting)"; else ko "mutation AF5: the mutant still parses: $(afget "$T/af-local/shard/$EPAF5b/${AF}07.md" project_path)"; fi
# AF6: children come from the whole manifest and are kept across passes
AFP="${AF}08"; AFC="${AF}09"; EPAF6=$(mkw "$AFP" /x/foo-repo); printf '{"type":"user","timestamp":"2026-06-07T08:00:00Z","cwd":"/x/foo-repo","uuid":"u1","sessionId":"%s","forkedFrom":{"sessionId":"%s"}}\n' "$AFC" "$AFP" > "$CLAUDE_DIR/projects/$EPAF6/$AFC.jsonl"
af bash "$STK" scan --all > "$T/af-local/manifest.jsonl" 2>/dev/null; afdg "$AFP" > "$T/af-d8.jsonl"; af $PY "$H/merge.py" "$T/af-d8.jsonl" >/dev/null 2>&1
if grep -q "session_id: $AFC" "$T/af-local/shard/$EPAF6/$AFP.md"; then ok "children AF6: the parent gets the child from the manifest even when only the parent has a digest"; else ko "children AF6: $(grep -A1 '^children' "$T/af-local/shard/$EPAF6/$AFP.md" | tr '\n' ' ')"; fi
jq -c "select(.session_id==\"$AFP\")" "$T/af-local/manifest.jsonl" > "$T/af-manifest-p.jsonl"; cp "$T/af-manifest-p.jsonl" "$T/af-local/manifest.jsonl"; af $PY "$H/merge.py" "$T/af-d8.jsonl" >/dev/null 2>&1; AFMRC=$?
if [ "$AFMRC" -eq 0 ] && grep -q "session_id: $AFC" "$T/af-local/shard/$EPAF6/$AFP.md"; then ok "children AF6: a later pass whose manifest lacks the child keeps the children"; else ko "children AF6: children dropped by an incremental pass"; fi
mkmut children merge.py 'chld = list(existing_fm.get("children") or [])' 'chld = []'
af $PY "$T/mut-children/helpers/merge.py" "$T/af-d8.jsonl" >/dev/null 2>&1
if ! grep -q "session_id: $AFC" "$T/af-local/shard/$EPAF6/$AFP.md"; then ok "mutation AF6: without the union the incremental pass drops the child (AF6 measures the union)"; else ko "mutation AF6: the mutant keeps the child"; fi
# AF7: stk link events materialize pilots on the pilot and piloted_by on a piloted session of this node
AFA="${AF}10"; AFB="${AF}11"; EPAF7=$(mkw "$AFA" /x/foo-repo); mkw "$AFB" /x/foo-repo >/dev/null
af bash "$STK" link --pilot "$AFA" --piloted "other:bbbb0000-0000-0000-0000-0000000000b1" >/dev/null 2>&1
af bash "$STK" link --pilot "$AFA" --piloted "testnode:$AFB" --confidence high >/dev/null 2>&1
af bash "$STK" scan --all > "$T/af-local/manifest.jsonl" 2>/dev/null; { afdg "$AFA"; afdg "$AFB"; } > "$T/af-d10.jsonl"; af $PY "$H/merge.py" "$T/af-d10.jsonl" >/dev/null 2>&1
if grep -q "node: other, session_id: bbbb0000-0000-0000-0000-0000000000b1" "$T/af-local/shard/$EPAF7/$AFA.md" && grep -q "session_id: $AFB" "$T/af-local/shard/$EPAF7/$AFA.md"; then ok "link AF7: the pilot's record lists both piloted sessions"; else ko "link AF7: pilots: $(grep -A2 '^pilots' "$T/af-local/shard/$EPAF7/$AFA.md" | tr '\n' ' ')"; fi
if grep -A1 '^piloted_by' "$T/af-local/shard/$EPAF7/$AFB.md" | grep -q "session_id: $AFA"; then ok "link AF7: the piloted session of this node gets piloted_by"; else ko "link AF7: piloted_by: $(grep -A1 '^piloted_by' "$T/af-local/shard/$EPAF7/$AFB.md" | tr '\n' ' ')"; fi
af $PY "$H/merge.py" "$T/af-d10.jsonl" >/dev/null 2>&1
eq "link AF7: a second pass does not duplicate the pilots" "$(grep -c "bbbb0000-0000-0000-0000-0000000000b1" "$T/af-local/shard/$EPAF7/$AFA.md")" "1"
mkmut link merge.py 'link_events_in = load_link_events(f"{SHARD}/events.jsonl")' 'link_events_in = []'
AFA2="${AF}12"; EPAF7b=$(mkw "$AFA2" /x/foo-repo); af bash "$STK" link --pilot "$AFA2" --piloted "other:bbbb0000-0000-0000-0000-0000000000b2" >/dev/null 2>&1
af bash "$STK" scan --all > "$T/af-local/manifest.jsonl" 2>/dev/null; afdg "$AFA2" > "$T/af-d12.jsonl"; af $PY "$T/mut-link/helpers/merge.py" "$T/af-d12.jsonl" >/dev/null 2>&1
if ! grep -q "bbbb0000-0000-0000-0000-0000000000b2" "$T/af-local/shard/$EPAF7b/$AFA2.md"; then ok "mutation AF7: without reading the events the link is not materialized (AF7 measures the read)"; else ko "mutation AF7: the mutant materializes the link"; fi
# AF8: an intent already recorded skips the clauses, but at resume/clear the branch registration still goes out
AFH="${AF}13"; mkw "$AFH" /x/foo-repo >/dev/null; af bash "$STK" note --session "$AFH" --kind intent "already" >/dev/null 2>&1
AFOUT=$(printf '{"session_id":"%s","source":"resume","cwd":"/x/foo-repo"}' "$AFH" | af bash "$STK" hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
if has "$AFOUT" "stk branch --register --current" && ! has "$AFOUT" "/rename" && grep -q "	resume	inject:resume:branch-only$" "$T/af-local/hook.log"; then ok "hook AF8: with an intent, resume injects the branch clause alone and logs it"; else ko "hook AF8: resume with intent: [$AFOUT] $(tail -1 "$T/af-local/hook.log")"; fi
AFOUT=$(printf '{"session_id":"%s","source":"startup","cwd":"/x/foo-repo"}' "$AFH" | af bash "$STK" hook 2>/dev/null)
if [ -z "$AFOUT" ] && grep -q "	startup	skip:intent-exists$" "$T/af-local/hook.log"; then ok "hook AF8: control, with an intent at startup nothing is injected"; else ko "hook AF8: startup with intent: [$AFOUT]"; fi
mkmut hook "" "" ""; sedi '/the intent is there, but a session resumed/,/^        fi$/d' "$T/mut-hook/bin/stk"
AFOUT=$(printf '{"session_id":"%s","source":"resume","cwd":"/x/foo-repo"}' "$AFH" | af bash "$T/mut-hook/bin/stk" hook 2>/dev/null)
if ! grep -q 'branch-only' "$T/mut-hook/bin/stk" && [ -z "$AFOUT" ]; then ok "mutation AF8: without the clause resume with an intent injects nothing (AF8 measures the clause)"; else ko "mutation AF8: $AFOUT"; fi
# AF9: a push that failed is retried by the next publish even without new changes
AF9="${AF}14"; mkw "$AF9" /x/foo-repo >/dev/null
git init -q -b main "$T/af-src" && git -C "$T/af-src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git clone -q --bare "$T/af-src" "$T/af-remote.git"
git clone -q "$T/af-remote.git" "$T/af-repo"; git -C "$T/af-repo" config user.email t@t; git -C "$T/af-repo" config user.name t; mkdir -p "$T/af-repo/store"
af bash "$STK" note --session "$AF9" --kind intent "p" >/dev/null 2>&1
mv "$T/af-remote.git" "$T/af-remote.away"; af env STK_CANON_PATH="$T/af-repo/store" STK_CANON_GIT=auto bash "$STK" publish >/dev/null 2>&1; AFRC=$?
mv "$T/af-remote.away" "$T/af-remote.git"
if [ "$AFRC" -ne 0 ] && [ "$(git -C "$T/af-repo" rev-list --count origin/main..main)" = "1" ]; then ok "push AF9: setup, the first publish committed and its push failed"; else ko "push AF9: setup: rc=$AFRC ahead=$(git -C "$T/af-repo" rev-list --count origin/main..main)"; fi
AFOUT=$(af env STK_CANON_PATH="$T/af-repo/store" STK_CANON_GIT=auto bash "$STK" publish 2>&1); AFRC=$?
git -C "$T/af-repo" fetch -q origin
if [ "$AFRC" -eq 0 ] && has "$AFOUT" "no changes to commit" && has "$AFOUT" "push ok (commits an earlier push had left behind)" && [ "$(git -C "$T/af-repo" rev-list --count origin/main..main)" = "0" ]; then ok "push AF9: the next publish without changes pushes the commits left behind"; else ko "push AF9: rc=$AFRC ahead=$(git -C "$T/af-repo" rev-list --count origin/main..main) $AFOUT"; fi
mkmut push "" "" ""; sedi '/a push that failed on an earlier publish left commits behind/,/^    fi$/d' "$T/mut-push/bin/stk"
af bash "$STK" note --session "$AF9" --kind future "p2" >/dev/null 2>&1
mv "$T/af-remote.git" "$T/af-remote.away"; af env STK_CANON_PATH="$T/af-repo/store" STK_CANON_GIT=auto bash "$STK" publish >/dev/null 2>&1; mv "$T/af-remote.away" "$T/af-remote.git"
af env STK_CANON_PATH="$T/af-repo/store" STK_CANON_GIT=auto bash "$T/mut-push/bin/stk" publish >/dev/null 2>&1; git -C "$T/af-repo" fetch -q origin
if ! grep -q 'left behind' "$T/mut-push/bin/stk" && [ "$(git -C "$T/af-repo" rev-list --count origin/main..main)" = "1" ]; then ok "mutation AF9: without the retry the remote stays behind (AF9 measures the retry)"; else ko "mutation AF9: ahead=$(git -C "$T/af-repo" rev-list --count origin/main..main)"; fi
# AF10: the helpers write through an exclusive temporary file: a planted symlink of the old predictable name is not followed
AF10="${AF}15"; EPAF10=$(mkw "$AF10" /x/foo-repo); mkdir -p "$T/af-local/shard/$EPAF10"; echo "CANARY-UNTOUCHED" > "$T/af-canary.txt"; ln -sfn "$T/af-canary.txt" "$T/af-local/shard/$EPAF10/$AF10.md.tmp"
af bash "$STK" close --session "$AF10" --status done >/dev/null 2>&1
if [ "$(cat "$T/af-canary.txt")" = "CANARY-UNTOUCHED" ] && [ -f "$T/af-local/shard/$EPAF10/$AF10.md" ]; then ok "tmp AF10: close writes the record and leaves the planted symlink's target alone"; else ko "tmp AF10: canary=$(head -c 30 "$T/af-canary.txt")"; fi
mkmut tmp close.py 'fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(a.md_path)}.", suffix=".tmp", dir=os.path.dirname(a.md_path))
with os.fdopen(fd, "w", encoding="utf-8") as fh:' 'tmp = a.md_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:'
AF10b="${AF}16"; EPAF10b=$(mkw "$AF10b" /x/foo-repo); mkdir -p "$T/af-local/shard/$EPAF10b"; echo "CANARY-UNTOUCHED" > "$T/af-canary2.txt"; ln -sfn "$T/af-canary2.txt" "$T/af-local/shard/$EPAF10b/$AF10b.md.tmp"
af bash "$T/mut-tmp/bin/stk" close --session "$AF10b" --status done >/dev/null 2>&1
if [ "$(cat "$T/af-canary2.txt")" != "CANARY-UNTOUCHED" ]; then ok "mutation AF10: the predictable name follows the symlink and overwrites the target (AF10 measures the exclusive file)"; else ko "mutation AF10: the mutant did not follow the symlink"; fi

# AF11: the probe tells a missing canon (first round) from an ancestor the account cannot traverse (a permission problem)
af2(){ AFENV PATH="$T/af-bin:$PATH" STK_LOCAL="$T/af-local5" XDG_CONFIG_HOME="$T/xdg-af" STK_NODE=testnode "$@"; }
mkdir -p "$T/af-host/srv/private/sessions/testnode"; chmod 000 "$T/af-host/srv/private"
AFERR=$(af2 env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/private/sessions bash "$STK" sync pull 2>&1 >/dev/null); AFRC=$?
if [ "$AFRC" -ne 0 ] && has "$AFERR" "cannot traverse"; then ok "probe AF11: an ancestor the account cannot traverse is an error, not a first round"; else ko "probe AF11: rc=$AFRC $AFERR"; fi
chmod 755 "$T/af-host/srv/private"
AFOUT=$(af2 env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/private/nothing bash "$STK" sync pull 2>&1); AFRC=$?
if [ "$AFRC" -eq 0 ] && has "$AFOUT" "first round, nothing to pull"; then ok "probe AF11: control, a missing canon under a traversable parent is still the first round"; else ko "probe AF11: control: rc=$AFRC $AFOUT"; fi
mkmut probe "" "" ""; sedi 's/^_canon_probe() { .*$/_canon_probe() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$STK_CANON_HOST" "test -e $(_rq "$1")"; }/' "$T/mut-probe/bin/stk"
chmod 000 "$T/af-host/srv/private"
AFOUT=$(af2 env STK_CANON_MODE=ssh STK_CANON_HOST=hubx STK_CANON_PATH=/srv/private/sessions bash "$T/mut-probe/bin/stk" sync pull 2>&1); AFRC=$?
if grep -q '"test -e $(_rq "$1")"' "$T/mut-probe/bin/stk" && [ "$AFRC" -eq 0 ] && has "$AFOUT" "first round"; then ok "mutation AF11: with a bare test -e the permission problem reads as a first round (AF11 measures the walk up)"; else ko "mutation AF11: rc=$AFRC $AFOUT"; fi
chmod 755 "$T/af-host/srv/private"
# AF12: the indexer and hygiene parse the frontmatter on delimiter lines too
mkdir -p "$T/af-canon12/testnode/-x-foo-repo"; AF12=ffff0000-0000-0000-0000-0000000000c1
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nproject: foo-repo\nproject_path: /x/foo-repo\nname: foo---bar\nname_source: user\nstatus: done\nstatus_source: user\nlast_activity_at: 2026-06-07T09:00:00Z\n---\n## extracted\n\n## user_notes\n' "$AF12" > "$T/af-canon12/testnode/-x-foo-repo/$AF12.md"
af env STK_CANON_MODE=local STK_CANON_PATH="$T/af-canon12" STK_LOCAL="$T/af-local12" bash "$STK" index >/dev/null 2>&1
eq "index AF12: a name with --- is indexed whole" "$(jq -r --arg s "$AF12" 'select(.session_id==$s) | "\(.name) \(.status)"' "$T/af-canon12/index.jsonl")" "foo---bar done"
mkmut index "" "" ""; sedi 's|fm = re.split(r"(?m)^---\[ \\t\]\*$\\n?", txt, maxsplit=2)\[1\]|fm = txt.split("---", 2)[1]|' "$T/mut-index/bin/stk"
af env STK_CANON_MODE=local STK_CANON_PATH="$T/af-canon12" STK_LOCAL="$T/af-local12" bash "$T/mut-index/bin/stk" index >/dev/null 2>&1
if grep -q 'fm = txt.split("---", 2)\[1\]' "$T/mut-index/bin/stk" && [ "$(jq -r --arg s "$AF12" 'select(.session_id==$s) | .name' "$T/af-canon12/index.jsonl")" != "foo---bar" ]; then ok "mutation AF12: the old split truncates the name in the index (AF12 measures the delimiter rule)"; else ko "mutation AF12: index mutant: $(jq -r --arg s "$AF12" 'select(.session_id==$s) | .name' "$T/af-canon12/index.jsonl")"; fi
# hygiene: an empty stub whose project_path carries --- is still recognized as empty
mkdir -p "$T/af-local13/shard/-x-a---b"; AF13=ffff0000-0000-0000-0000-0000000000c2
printf -- '---\nschema: v0\nsession_id: %s\nnode: testnode\nproject: a---b\nproject_path: /x/a---b\nstatus: unknown\nstatus_source: auto\nname: ""\nname_source: auto\nforked_from: null\n---\n## extracted\n\n## user_notes\n' "$AF13" > "$T/af-local13/shard/-x-a---b/$AF13.md"
AFOUT=$(AFENV STK_LOCAL="$T/af-local13" XDG_CONFIG_HOME="$T/xdg-af" STK_NODE=testnode $PY "$H/hygiene.py" 2>&1)
if has "$AFOUT" "$AF13"; then ok "hygiene AF12: an empty stub with --- in its path is listed"; else ko "hygiene AF12: $AFOUT"; fi
mkmut hygiene config.py 'parts = re.split(FRONTMATTER_RE, raw, maxsplit=2)' 'parts = raw.split("---", 2)'
AFOUT=$(AFENV STK_LOCAL="$T/af-local13" XDG_CONFIG_HOME="$T/xdg-af" STK_NODE=testnode $PY "$T/mut-hygiene/helpers/hygiene.py" 2>&1)
if ! has "$AFOUT" "$AF13"; then ok "mutation AF12: with the old split hygiene misses the stub (AF12 measures the shared parser)"; else ko "mutation AF12: hygiene mutant still lists it"; fi
# AF13: a rewritten record keeps its mode, a new one takes the umask's (mkstemp alone would leave 0600)
AF14=ffff0000-0000-0000-0000-0000000000c3; EPAF14=$(mkw "$AF14" /x/foo-repo)
af bash "$STK" close --session "$AF14" --status done >/dev/null 2>&1
AFMODE=$(fmode "$T/af-local/shard/$EPAF14/$AF14.md"); AFWANT=$(printf '%o' $(( 0666 & ~0$(umask) )))
eq "mode AF13: a new record takes the umask's mode" "$AFMODE" "$AFWANT"
chmod 640 "$T/af-local/shard/$EPAF14/$AF14.md"; af bash "$STK" close --session "$AF14" --status dropped >/dev/null 2>&1
eq "mode AF13: a rewritten record keeps its mode" "$(fmode "$T/af-local/shard/$EPAF14/$AF14.md")" "640"
mkmut mode close.py 'os.chmod(tmp, mode)
os.replace(tmp, a.md_path)' 'os.replace(tmp, a.md_path)'
chmod 640 "$T/af-local/shard/$EPAF14/$AF14.md"; af bash "$T/mut-mode/bin/stk" close --session "$AF14" --status done >/dev/null 2>&1
eq "mutation AF13: without the chmod the rewrite leaves mkstemp's 0600 (AF13 measures the chmod)" "$(fmode "$T/af-local/shard/$EPAF14/$AF14.md")" "600"

echo
echo "=== RESULT: $P passed, $F failed, $K skipped ==="
[ "$F" -eq 0 ]
