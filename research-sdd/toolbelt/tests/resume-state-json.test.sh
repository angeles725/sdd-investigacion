#!/usr/bin/env bash
# resume-state-json.test.sh — opt-in --json envelope of resume-state.sh (kit issue #1711 slice 3,
# json-envelope.v1.md). Pins: (1) the DEFAULT document stays byte-identical (golden recorded from the
# pre-change script); (2) the envelope carries the CLAUDE.md §7 state enum, the documented counts and item
# kinds, and agrees with the default document; (3) a missing jq/git is a typed degraded envelope (rc 3), a
# failing jq is rc 2 with empty stdout, and operational failures (rc 2) print nothing in either mode.
#
# Env: RSJ_SUT=<path>        run against another copy of the script (used to execute RED against the
#                            pre-change SUT); default is ../resume-state.sh.
#      The golden is FROZEN from the pre-change script, never from the SUT under test. Re-record with:
#        git show 3b1e6c6bc408537969428563f903416a5e137314:research-sdd/toolbelt/resume-state.sh > /tmp/rs-main.sh
#        (the fixed pre-change commit, a build WITHOUT --json; origin/main gains --json once this merges)
#        RSJ_SUT=/tmp/rs-main.sh RSJ_REGEN_GOLDEN=1 bash resume-state-json.test.sh
#
# Usage: resume-state-json.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${RSJ_SUT:-$HERE/../resume-state.sh}"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the --json cases" >&2; exit 2; }
DOC="$HERE/../json-envelope.v1.md"
[ -f "$DOC" ] || { echo "FATAL: contract doc not found: $DOC" >&2; exit 2; }
GOLD="$HERE/fixtures/resume-state/json-envelope/default-output.golden"

ROOT="$(mktemp -d)"; ROOT="$(cd -P "$ROOT" && pwd)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# Ambient GIT_* variables (e.g. from a git hook) would redirect every fixture and SUT git call elsewhere.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_NAMESPACE
# Throwaway repo: origin/main exists; a dirty feature worktree, a prunable one, a detached one, two loose branches.
# Every step is checked: a failure aborts the suite with a typed FAIL naming the step (never a partial fixture).
R="$ROOT/r"; mkdir -p "$R"
step() { local name="$1"; shift; local out
  out="$("$@" 2>&1)" || { printf '  FAIL  fixture setup: step "%s" failed (rc %s): %s\n' "$name" "$?" "$(printf '%s' "$out" | head -c 300)"; exit 2; }; }
inR() { ( cd "$R" && "$@" ); }
inW() { local d="$1"; shift; ( cd "$d" && "$@" ); }
step init          inR git init -q .
step head-main     inR git symbolic-ref HEAD refs/heads/main
step c1            inR sh -c 'echo a > a && git add a'
step commit-c1     inR G commit -q -m c1
step bare-origin   git init -q --bare "$R.origin"
step add-remote    inR git remote add origin "$R.origin"
step push-c1       inR git push -q origin main
step fetch         inR git fetch -q origin
step wt-a          inR git worktree add -q -b feat/a "$ROOT/wt-a" main
step wt-a-files    inW "$ROOT/wt-a" sh -c 'echo x > x && git add x'
step wt-a-commit   inW "$ROOT/wt-a" G commit -q -m a1
step wt-a-dirty    inW "$ROOT/wt-a" sh -c 'echo dirty >> a && echo u1 > u1'
step m2-files      inR sh -c 'echo m > m && git add m'
step commit-m2     inR G commit -q -m m2
step push-m2       inR git push -q origin main
step br-loose      inR git branch loose main~1
step br-ahead1     inR git branch ahead1 main
step co-ahead1     inR git checkout -q ahead1
step z-files       inR sh -c 'echo z > z && git add z'
step commit-z1     inR G commit -q -m z1
step co-main       inR git checkout -q main
step wt-detached   inR git worktree add -q --detach "$ROOT/wt-d" main~1
step wt-p          inR git worktree add -q -b feat/p "$ROOT/wt-p" main
rm -rf "$ROOT/wt-p"   # prunable: directory gone, entry not pruned

# PATH scenarios: stub gh variants, and tool-symlink dirs without jq / without git.
STUB="$ROOT/stub"; mkdir -p "$STUB/ok" "$STUB/bad"
printf '#!/bin/sh\necho '"'"'[{"number":7,"headRefName":"feat/a","state":"OPEN","url":"https://x/7"},{"number":9,"headRefName":"loose","state":"OPEN","url":"https://x/9"}]'"'"'\n' > "$STUB/ok/gh"
printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$STUB/bad/gh"
chmod +x "$STUB"/*/gh
mkpath() { local d="$1"; shift; mkdir -p "$d"; local t p; for t in "$@"; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"; done; }
BASE_TOOLS="bash sh env cat date sed awk grep tr sort head mktemp rm timeout dirname basename wc uname"
# shellcheck disable=SC2086
mkpath "$ROOT/nojq" git $BASE_TOOLS
# shellcheck disable=SC2086
mkpath "$ROOT/nogit" jq $BASE_TOOLS
# a jq that works for everything except the --slurpfile envelope build
mkdir -p "$ROOT/badjq"; REAL_JQ="$(command -v jq)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --slurpfile ] && exit 5; done\nexec "%s" "$@"\n' "$REAL_JQ" > "$ROOT/badjq/jq"; chmod +x "$ROOT/badjq/jq"
# shellcheck disable=SC2086
mkpath "$ROOT/badjq-p" git bash $BASE_TOOLS; ln -sf "$ROOT/badjq/jq" "$ROOT/badjq-p/jq"
PATH_ORIG="$PATH"

# rs <sut> [args...] : OUT = stdout, ERR = stderr, RC; PATH override through RS_PATH.
rs() { local sut="$1"; shift; local ef; ef="$(mktemp "$ROOT/err.XXXXXX")"
  OUT="$(PATH="${RS_PATH:-$PATH_ORIG}" "$BASH_BIN" "$sut" "$@" 2>"$ef")"; RC=$?; ERR="$(cat "$ef")"; rm -f "$ef"; }
jq_f() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
gold_norm() { jq '.generated_at="@T@"' | sed -e "s#$ROOT#@ROOT@#g" -E -e 's/[0-9a-f]{40}/@SHA@/g'; }

echo "== resume-state-json.test.sh (SUT: $SUT) =="

# 1 — GOLDEN: the default (no flag) document of the rich fixture is byte-identical to the recorded pre-change one.
rs "$SUT" --cwd "$R" --no-gh
if [ -n "${RSJ_REGEN_GOLDEN:-}" ]; then mkdir -p "$(dirname "$GOLD")"; printf '%s\n' "$OUT" | gold_norm > "$GOLD"; fi
if [ -f "$GOLD" ] && [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | gold_norm)" = "$(cat "$GOLD")" ]; then
  ok "golden: default (no flag) document byte-identical to the recorded pre-change one" "(rc $RC)"
else no "golden: default document drifted from $GOLD" "rc=$RC $(diff <(printf '%s\n' "$OUT" | gold_norm) "$GOLD" 2>&1 | head -5)"; fi

# Case functions take the SUT path (rc 0 = the case holds) so the teeth can re-run them on a mutant.
jt_rich() { rs "$1" --cwd "$R" --no-gh --json; [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -s length 2>/dev/null)" = 1 ] \
  && [ "$(jq_f '[.schema,.state,(.reason|type),(.counts|type),(.items|type)]|join(",")')" = "research-sdd.resume-state/v1,ok,null,object,array" ]; }
jt_optin() { rs "$1" --cwd "$R" --no-gh; [ "$RC" = 0 ] && [ "$(jq_f 'has("items")')" = false ] && [ "$(jq_f 'has("worktrees")')" = true ] \
  && rs "$1" --cwd "$R" --no-gh --json && [ "$(jq_f 'has("worktrees")')" = false ]; }
jt_kindsets() { rs "$1" --cwd "$R" --no-gh --json; [ "$(jq_f '[.items[].kind]|unique|join(",")')" = "branch,repo,worktree" ] \
  && [ "$(jq_f '[.items[]|select(.kind=="repo")]|length')" = 1 ] && [ "$(jq_f '[.items[]|select(.kind=="worktree")]|length')" = 4 ] \
  && [ "$(jq_f '[.items[]|select(.kind=="branch")|.name]|sort|join(",")')" = "ahead1,loose" ]; }
jt_repo() { rs "$1" --cwd "$R" --no-gh --json; [ "$(jq_f '.items[0]|[.kind,.toplevel,.base_ref,.prs_status,(.prs_truncated|type),.remote]|join(",")')" = "repo,$R,origin/main,skipped,null,$R.origin" ]; }
# the envelope agrees with the default document: same worktree/branch entries, minus the kind tag
jt_agree() { local d w b; rs "$1" --cwd "$R" --no-gh; d="$OUT"; rs "$1" --cwd "$R" --no-gh --json
  w="$(jq -c '[.items[]|select(.kind=="worktree")|del(.kind)]' <<<"$OUT")"; b="$(jq -c '[.items[]|select(.kind=="branch")|del(.kind)]' <<<"$OUT")"
  [ "$w" = "$(jq -c .worktrees <<<"$d")" ] && [ "$b" = "$(jq -c .branches <<<"$d")" ]; }
jt_counts() { rs "$1" --cwd "$R" --no-gh --json
  [ "$(jq_f '.counts|[.worktrees,.worktrees_missing,.worktrees_dirty,.branches,.prs,.prs_unknown]|join(",")')" = "4,1,1,2,0,1" ] \
  && [ "$(jq_f '(.counts.worktrees)==([.items[]|select(.kind=="worktree")]|length)')" = true ]; }
jt_dirty() { rs "$1" --cwd "$R" --no-gh --json; [ "$(jq_f '.counts.worktrees_dirty')" = 1 ]; }   # only wt-a has tracked changes
jt_prs() { RS_PATH="$STUB/ok:$PATH_ORIG" rs "$1" --cwd "$R" --json; local r1="$RC" a b
  a="$(jq_f '[.counts.prs,.counts.prs_unknown,.items[0].prs_status,.items[0].prs_truncated]|map(tostring)|join(",")')"
  b="$(jq_f '[.items[]|select(.kind=="pr")|[.number,.branch,.state,.url]|map(tostring)|join("|")]|join(",")')"
  [ "$r1" = 0 ] && [ "$a" = "2,0,ok,false" ] && [ "$b" = "7|feat/a|OPEN|https://x/7,9|loose|OPEN|https://x/9" ]; }
jt_prsunk() { RS_PATH="$STUB/bad:$PATH_ORIG" rs "$1" --cwd "$R" --json
  [ "$RC" = 0 ] && [ "$(jq_f '[.counts.prs,.counts.prs_unknown,.items[0].prs_status,.state]|map(tostring)|join(",")')" = "0,1,degraded:gh-failed,ok" ]; }
jt_degr() { RS_PATH="$ROOT/nojq" rs "$1" --cwd "$R" --no-gh --json; local a; a="$RC|$(printf "%s" "$ERR" | grep -c DEGRADED)|$(printf "%s" "$OUT" | grep -c "\"state\":\"degraded\"")"
  RS_PATH="$ROOT/nogit" rs "$1" --cwd "$R" --no-gh --json
  [ "$a" = "3|1|1" ] && [ "$RC" = 3 ] && [ "$(jq_f '[.schema,.state,(.reason|type),(.counts|length),(.items|length)]|map(tostring)|join(",")')" = "research-sdd.resume-state/v1,degraded,string,0,0" ]; }
jt_degr_plain() { RS_PATH="$ROOT/nojq" rs "$1" --cwd "$R" --no-gh; [ "$RC" = 3 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; }
jt_jqfail() { RS_PATH="$ROOT/badjq-p" rs "$1" --cwd "$R" --no-gh --json; [ "$RC" = 2 ] && [ -z "$OUT" ] && [[ "$ERR" == *'envelope build failed'* ]]; }
jt_oper() { rs "$1" --cwd "$R" --no-gh --json --base-ref no-such-ref; local a="$RC|${#OUT}"
  mkdir -p "$ROOT/plain"; rs "$1" --cwd "$ROOT/plain" --json; [ "$a" = "2|0" ] && [ "$RC" = 2 ] && [ -z "$OUT" ]; }
jt_flagpos() { rs "$1" --json --cwd "$R" --no-gh; local a="$OUT"; rs "$1" --cwd "$R" --no-gh --json; [ "$(jq -c 'del(.items[0].generated_at)' <<<"$a")" = "$(jq -c 'del(.items[0].generated_at)' <<<"$OUT")" ] && [ "$(jq_f .state)" = ok ]; }
jt_human() { rs "$1" --cwd "$R" --no-gh; [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | gold_norm)" = "$(cat "$GOLD")" ]; }
jt_base() { rs "$1" --cwd "$R" --no-gh --json --base-ref loose; [ "$(jq_f '.items[0]|[.base_ref,.base_sha]|join(",")')" = "loose,$(git -C "$R" rev-parse loose)" ]; }
# every scalar field of the default document (top level + repo.*) reaches the envelope's repo item with the same value:
# a field added to one jq call and not the other cannot slip through (generated_at is a per-run clock: format only).
jt_fields() { local d e miss
  RS_PATH="$STUB/ok:$PATH_ORIG" rs "$1" --cwd "$R" --base-ref loose; d="$OUT"
  RS_PATH="$STUB/ok:$PATH_ORIG" rs "$1" --cwd "$R" --base-ref loose --json; e="$OUT"
  [ -n "$d" ] && [ -n "$e" ] || return 1
  miss="$(jq -rn --argjson d "$d" --argjson e "$e" '
    (($d|del(.schema,.repo,.worktrees,.branches,.prs,.generated_at)) + $d.repo) as $want | $e.items[0] as $got
    | [($want|keys[]) as $k | select(($got|has($k)|not) or $got[$k] != $want[$k]) | $k]
    + (if ($got.generated_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and ($d.generated_at|type)=="string" then [] else ["generated_at"] end)
    | join(",")' 2>/dev/null)" || return 1
  # non-vacuous: the compared key set is exactly the documented default fields
  [ -z "$miss" ] && [ "$(jq -rn --argjson d "$d" '($d|del(.schema,.repo,.worktrees,.branches,.prs,.generated_at)) + $d.repo|keys|join(",")')" = "base_ref,base_sha,prs_status,prs_truncated,remote,toplevel" ]; }

run_case() { local label="$1" fn="$2" detail="$3"
  if "$fn" "$SUT"; then ok "$label" "$detail"; else no "$label" "rc=$RC err=[$(printf '%s' "$ERR" | head -c 120)] out=[$(printf '%s' "$OUT" | head -c 160)]"; fi; }
if [ -z "${RSJ_SKIP_JSON_CASES:-}" ]; then
run_case "json: one envelope, schema/state/reason/counts/items present"      jt_rich ""
run_case "json: --json is opt-in (default has worktrees, no items; json the reverse)" jt_optin ""
run_case "json: item kinds repo/worktree/branch, 4 worktrees, branches exclude worktree ones" jt_kindsets ""
run_case "json: repo item carries toplevel, remote, base, prs_status"        jt_repo ""
run_case "json: items equal the default document's worktrees and branches"   jt_agree ""
run_case "json: counts (worktrees 4, missing 1, dirty 1, branches 2, prs 0, prs_unknown 1)" jt_counts ""
run_case "json: gh ok -> pr items and counts.prs 2, prs_unknown 0"           jt_prs ""
run_case "json: gh failing -> prs 0 beside prs_unknown 1 (never a bare zero)" jt_prsunk ""
run_case "json: jq/git missing -> rc 3 + typed degraded envelope"            jt_degr ""
run_case "default: jq missing keeps rc 3 and empty stdout"                   jt_degr_plain ""
run_case "json: a failing jq envelope build -> rc 2, empty stdout"           jt_jqfail ""
run_case "json: operational failures (bad ref, not a repo) -> rc 2, empty stdout" jt_oper ""
run_case "json: flag position does not matter"                               jt_flagpos ""
run_case "json: --base-ref honoured in the repo item"                        jt_base ""
run_case "json: every default-document field reaches the envelope repo item"   jt_fields ""
fi

# 2 — STRUCTURAL: the item kinds the SUT can emit == the kinds json-envelope.v1.md documents (both directions).
kinds_check() {
  local sut="$1" doc="$2" code docd
  code="$(grep -oE '\{kind:"[a-z-]+"' "$sut" | sed -E 's/\{kind:"([a-z-]+)"/\1/' | sort -u)"
  docd="$(awk '/^### `research-sdd.resume-state\/v1`/{f=1;next} f&&/^### /{f=0} f' "$doc" \
            | sed -nE 's/^\| `([a-z][a-z-]*)` \| .*/\1/p' | grep -vx 'kind' | sort -u)"
  [ -n "$code" ] && [ -n "$docd" ] && [ "$code" = "$docd" ]
}
if kinds_check "$SUT" "$DOC"; then ok "kinds: SUT item kinds == documented kinds (both directions)" "($(grep -oE '\{kind:"[a-z-]+"' "$SUT" | sort -u | wc -l) kinds)"
else no "kinds: code/doc kind sets differ" "code=[$(grep -oE '\{kind:"[a-z-]+"' "$SUT" | sort -u | tr '\n' ' ')]"; fi
jt_kinds() { kinds_check "$1" "$DOC"; }

# --- TEETH (--prove-teeth): each mutant of the SUT must break the case that pins it.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain || exit 2
  # jteeth <label> <case-fn> <sed-expr>... : the case must HOLD on the unmutated SUT first (else vacuous), then break on the mutant.
  jteeth() {
    local label="$1" fn="$2" mut; shift 2
    "$fn" "$SUT" || { no "teeth JSON-$label: case FAILS on the unmutated SUT — tooth is vacuous" ""; return; }
    mut="$ROOT/jt-$label.sh"
    mutant_chain "teeth JSON-$label" "$SUT" "$mut" "$@" || { fail=$((fail+1)); return; }
    if "$fn" "$mut"; then no "teeth JSON-$label: mutant survived — case is THEATER" ""; else ok "teeth JSON-$label: mutant breaks the case (has teeth)" "()"; fi
  }
  jteeth optin    jt_optin    's/--json) json=1; shift ;;/--json) shift ;;/'
  jteeth kindrepo jt_kinds    's/{kind:"repo"/{kind:"repox"/'
  jteeth kindwt   jt_kinds    's/{kind:"worktree"}/{kind:"worktreex"}/'
  jteeth kindbr   jt_kindsets 's/{kind:"branch"}/{kind:"branchx"}/'
  jteeth kindpr   jt_prs      's/{kind:"pr"}/{kind:"prx"}/'
  jteeth state    jt_rich     's/state:"ok", reason:null/state:"ok", reason:"x"/'
  jteeth repo     jt_repo     's/prs_status:\$prs_status, prs_truncated:\$prs_truncated}\]/prs_status:"ok", prs_truncated:$prs_truncated}]/'
  jteeth wtcount  jt_counts   's/counts:{worktrees:(\$wt|length)/counts:{worktrees:0/'
  jteeth missing  jt_counts   's/worktrees_missing:(\$wt|map(select(.exists==false))|length)/worktrees_missing:0/'
  jteeth dirty    jt_dirty    's/(\.dirty \/\/ 0) > 0/(.dirty \/\/ 0) >= 0/'
  jteeth brcount  jt_counts   's/branches:(\$br|length)/branches:0/'
  jteeth prcount  jt_prs      's/prs:(\$p|length)/prs:0/'
  jteeth prsunk   jt_prsunk   's/if \$prs\[0\]==null then 1 else 0 end/0/'
  jteeth degr     jt_degr     's/\[ "\$json" = 1 \] && printf/false \&\& printf/'
  jteeth degrmark jt_degr     's/"state":"degraded"/"state":"ok"/'
  jteeth jqfail   jt_jqfail   's/envelope build failed" >&2; exit 2/envelope build failed" >\&2; exit 0/'
  jteeth agree    jt_agree    's/(\$wt|map({kind:"worktree"} + \.))/($wt|map({kind:"worktree"} + .)|reverse)/'
  jteeth human    jt_human    's/exists:\$exists, prunable:\$prunable/prunable:$prunable, exists:$exists/'
  jteeth fbase    jt_fields   's/base_ref:\$base_ref, base_sha:\$base_sha, prs_status/base_ref:$base_ref, base_sha:$base_ref, prs_status/'
  jteeth fremote  jt_fields   's/toplevel:\$top, remote:(if \$remote=="" then null else \$remote end),/toplevel:$top,/'
  jteeth flagpos  jt_flagpos  's/--json) json=1; shift ;;/--json) json=1; shift; json=0 ;;/'
  # Doc-side teeth: a documented kind removed / an undocumented kind added must break kinds_check against the SUT.
  _dm1="$ROOT/doc-drop.md"; _dm2="$ROOT/doc-extra.md"
  sed '/^| `branch` |/d' "$DOC" > "$_dm1"
  sed 's/^| `branch` |/| `ghost-kind` | invented |\n| `branch` |/' "$DOC" > "$_dm2"
  if ! cmp -s "$DOC" "$_dm1" && ! kinds_check "$SUT" "$_dm1"; then ok "teeth JSON-docdrop: a kind missing from the doc breaks the structural case" "()"; else no "teeth JSON-docdrop: mutant survived — structural case is THEATER" ""; fi
  if ! cmp -s "$DOC" "$_dm2" && ! kinds_check "$SUT" "$_dm2"; then ok "teeth JSON-docextra: an undocumented-in-code kind in the doc breaks the structural case" "()"; else no "teeth JSON-docextra: mutant survived — structural case is THEATER" ""; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
