#!/usr/bin/env bash
# Test suite for merge-gate.sh (kit issue #1272).
# gentle-ai and gh are STUBBED via PATH with canned output — this suite never calls the real
# `gentle-ai review start`, the real assess, or real GitHub. Fixtures are built in a temp root
# (kit issue #1156): nothing is written into the live tree.
#   merge-gate.test.sh                 run the suite
#   merge-gate.test.sh --prove-teeth   run the suite + mutation controls
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../merge-gate.sh"
[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# --- hermetic repo: base commit + head commit --------------------------------------------------
REPO="$ROOT/repo"
git init -q "$REPO" \
  && git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t \
  && echo a > "$REPO/a" && git -C "$REPO" add a && git -C "$REPO" commit -qm base \
  && git -C "$REPO" tag base \
  && echo b > "$REPO/b" && git -C "$REPO" add b && git -C "$REPO" commit -qm head \
  || { echo "FATAL: cannot build fixture repo" >&2; exit 2; }
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
BASE_SHA="$(git -C "$REPO" rev-parse base)"

gc() { git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$2"; }
# R2: main moved ahead of the branch point (unrelated work); feat is checked out
R2="$ROOT/r2"
{ git init -q -b main "$R2" && gc "$R2" c0 && C0_R2="$(git -C "$R2" rev-parse HEAD)" \
  && git -C "$R2" checkout -q -b feat && gc "$R2" f1 && git -C "$R2" checkout -q main && gc "$R2" m1 \
  && git -C "$R2" checkout -q feat; } || { echo "FATAL: cannot build R2" >&2; exit 2; }
# R3: dangerous commit d1 then a harmless d2 on top of c0 (narrow-base repro)
R3="$ROOT/r3"
{ git init -q -b main "$R3" && gc "$R3" c0 && C0_R3="$(git -C "$R3" rev-parse HEAD)" \
  && gc "$R3" d1-danger && gc "$R3" d2-docs; } || { echo "FATAL: cannot build R3" >&2; exit 2; }
HEAD_R3="$(git -C "$R3" rev-parse HEAD)"
# R0: unborn HEAD
R0="$ROOT/r0"; git init -q "$R0" || { echo "FATAL: cannot build R0" >&2; exit 2; }

# --- stub bin dir: gentle-ai and gh ------------------------------------------------------------
STUBS="$ROOT/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/gentle-ai" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
[ -n "${STUB_JSON:-}" ] && cat "$STUB_JSON"
[ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
[ -n "${STUB_MOVE:-}" ] && git -C "$STUB_MOVE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved
exit "${STUB_RC:-0}"
STUB
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $* cwd:$PWD" >> "${STUB_LOG:-/dev/null}"
case "$1 $2" in
  "pr view")
    # mimic gh 2.45: baseRefOid is NOT a pr-view JSON field -> field drift must show up
    for f in $(printf '%s' "$*" | sed -n 's/.*--json \([^ ]*\).*/\1/p' | tr ',' ' '); do
      case "$f" in headRefOid|baseRefName|number|state|title|url) ;; *) echo "Unknown JSON field: \"$f\"" >&2; exit 1 ;; esac
    done
    printf '{"headRefOid":"%s","baseRefName":"main"}\n' "${STUB_PR_HEAD:-}"; exit 0 ;;
  "api repos/{owner}/{repo}/commits/"*"/check-runs"*)
    # REST check-runs for ONE commit sha. Only --paginate is accepted: any --json/--jq (field-name
    # drift) or other flag fails loudly. A sha other than the PR head gets an EMPTY set, so a gate bound
    # to the wrong sha shows up as ci_pending, never as a lucky pass.
    ckpath="$2"; shift 2
    pag=""; for a in "$@"; do case "$a" in --paginate) pag=1 ;; *) echo "stub gh: unsupported api argument: $a" >&2; exit 1 ;; esac; done
    [ -n "$pag" ] || { echo "stub gh: check-runs read without --paginate (would silently truncate at one page)" >&2; exit 1; }
    [ -n "${STUB_CHECKS_FAIL:-}" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    cksha="${ckpath#repos/\{owner\}/\{repo\}/commits/}"; cksha="${cksha%%/*}"
    if [ "$cksha" != "${STUB_PR_HEAD:-}" ]; then echo '{"total_count":0,"check_runs":[]}'; exit 0; fi
    if [ -n "${STUB_CHECKS_JSON:-}" ]; then cat "$STUB_CHECKS_JSON"; exit 0; fi
    echo '{"total_count":3,"check_runs":[{"name":"shellcheck","status":"completed","conclusion":"success"},{"name":"toolbelt-tests","status":"completed","conclusion":"success"},{"name":"pr-validation","status":"completed","conclusion":"success"}]}'
    exit 0 ;;
  "api repos/{owner}/{repo}/pulls/"*|api\ repos/*)
    [ -n "${STUB_API_FAIL:-}" ] && exit 1
    printf '{"headRefOid":"%s","baseRefOid":"%s","baseRefName":"main"}\n' "${STUB_PR_HEAD:-}" "${STUB_PR_BASE:-}"; exit 0 ;;
  "pr merge") [ -n "${STUB_MERGE_ERR:-}" ] && echo "$STUB_MERGE_ERR" >&2; exit "${STUB_MERGE_RC:-0}" ;;
esac
exit 9
STUB
chmod +x "$STUBS/gentle-ai" "$STUBS/gh"

# restricted PATH dir carrying only the named tools (absent-binary cases)
mkminimal() { # mkminimal <dir> <tool...>
  local d="$1" t; shift; mkdir -p "$d"
  for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
}

mkjson() { # mkjson <file> <due:true|false> <reason>
  printf '{"schema":"gentle-ai.review-assessment/v1","risk":"high","review_due":%s,"review_due_reason":"%s"}\n' "$2" "$3" > "$1"
}
mkdir -p "$ROOT/j"
mkjson "$ROOT/j/passive.json" false passive
mkjson "$ROOT/j/already.json" false already_reviewed
mkjson "$ROOT/j/under.json" false under_budget
mkjson "$ROOT/j/high.json" true high_risk
mkjson "$ROOT/j/slice.json" true slice_budget_reached
mkjson "$ROOT/j/weird.json" false something_new
echo '{not json' > "$ROOT/j/malformed.json"
printf '{"schema":"other/v9","review_due":false,"review_due_reason":"passive"}\n' > "$ROOT/j/badschema.json"
printf '{"schema":"gentle-ai.review-assessment/v1","review_due":"no","review_due_reason":"passive"}\n' > "$ROOT/j/badbool.json"
printf '{"schema":"gentle-ai.review-assessment/v1","review_due":false}\n' > "$ROOT/j/noreason.json"

OUT=""; RC=0; PRB="$BASE_SHA"
# run <sut> <json> [sut args...]   (stubs first on PATH)
run() {
  local sut="$1" json="$2"; shift 2
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$json" STUB_LOG="$ROOT/log" bash "$sut" "$@" 2>"$ROOT/err")"; RC=$?
}
# runenv <sut> <json> <pr-head> <merge-rc> [sut args...]   (for --merge cases)
runenv() {
  local sut="$1" json="$2" prh="$3" mrc="$4"; shift 4
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$json" STUB_PR_HEAD="$prh" STUB_PR_BASE="$PRB" STUB_MERGE_RC="$mrc" STUB_LOG="$ROOT/log" bash "$sut" "$@" 2>"$ROOT/err")"; RC=$?
}
expect() { # expect <label> <rc> <regex-on-stdout>
  if [ "$RC" -eq "$2" ] && <<<"$OUT" grep -Eq "$3"; then ok "$1"
  else no "$1 (rc=$RC want $2; out: $OUT)"; fi
}
ARGS=(--cwd "$REPO" --base-ref base)

# --- CI-gate helpers (kit issue #1426) ---------------------------------------------------------
# mkchecks <file> <name:status:conclusion>...   (conclusion may be empty for an unfinished run)
mkchecks() {
  local f="$1" a; shift
  for a in "$@"; do printf '%s\n' "$a"; done | jq -Rsc '
    (split("\n") | map(select(length > 0) | split(":") | {name: .[0], status: .[1], conclusion: (if .[2] == "" then null else .[2] end)}
      + (if (.[3] // "") != "" then {app: {id: (.[3] | tonumber)}} else {} end)
      + (if (.[4] // "") != "" then {started_at: .[4]} else {started_at: null} end)
      + (if (.[5] // "") != "" then {id: (.[5] | tonumber)} else {} end))) as $r
    | {total_count: ($r | length), check_runs: $r}' > "$f"
}
# CKREQ: the MERGE_GATE_REQUIRED_CHECKS env for runck; the literal UNSET leaves the default in force.
CKREQ="shellcheck,toolbelt-tests"
# runck <sut> <checks-file> [extra sut args]   (a --merge 7 run whose PR head equals the checked HEAD)
runck() {
  local sut="$1" cj="$2"; shift 2
  OUT="$( if [ "$CKREQ" = UNSET ]; then unset MERGE_GATE_REQUIRED_CHECKS; else export MERGE_GATE_REQUIRED_CHECKS="$CKREQ"; fi
    PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=0 \
      STUB_CHECKS_JSON="$cj" STUB_CHECKS_FAIL="${CKFAIL:-}" STUB_LOG="$ROOT/log" bash "$sut" "${ARGS[@]}" --merge 7 "$@" 2>"$ROOT/err")"; RC=$?
}
mkdir -p "$ROOT/ck"

suite() { # suite <sut> — the whole behavioural suite, reusable against mutants
  local S="$1"
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}"; expect "allow passive" 0 '^merge-gate: allow: passive'
  run "$S" "$ROOT/j/already.json" "${ARGS[@]}"; expect "allow already_reviewed" 0 '^merge-gate: allow: already_reviewed'
  run "$S" "$ROOT/j/under.json" "${ARGS[@]}"; expect "allow under_budget" 0 '^merge-gate: allow: under_budget'
  run "$S" "$ROOT/j/high.json" "${ARGS[@]}"; expect "refuse review_due high_risk" 1 '^merge-gate: refuse: review_due \(high_risk\)'
  run "$S" "$ROOT/j/slice.json" "${ARGS[@]}"; expect "refuse review_due slice_budget_reached" 1 '^merge-gate: refuse: review_due \(slice_budget_reached\)'
  run "$S" "$ROOT/j/weird.json" "${ARGS[@]}"; expect "degraded unknown not-due reason" 3 '^merge-gate: degraded: unknown not-due reason'
  run "$S" "$ROOT/j/malformed.json" "${ARGS[@]}"; expect "degraded malformed JSON" 3 '^merge-gate: degraded: assess output is unparseable'
  run "$S" "$ROOT/j/badschema.json" "${ARGS[@]}"; expect "degraded wrong schema" 3 '^merge-gate: degraded: unexpected assess schema'
  run "$S" "$ROOT/j/badbool.json" "${ARGS[@]}"; expect "degraded non-boolean review_due" 3 '^merge-gate: degraded: assess review_due is missing or not a boolean'
  run "$S" "$ROOT/j/noreason.json" "${ARGS[@]}"; expect "degraded missing reason" 3 '^merge-gate: degraded: assess review_due_reason is missing'
  run "$S" "" "${ARGS[@]}"; expect "degraded empty assess output" 3 '^merge-gate: degraded: assess output is unparseable'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_RC=1 bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "degraded assess non-zero exit even with allow-shaped JSON" 3 '^merge-gate: degraded: gentle-ai review assess failed'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/high.json" STUB_RC=1 STUB_ERR="Error: untracked files require an explicit declaration" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "degraded surfaces gentle-ai's own error line" 3 'assess failed \(exit 1\): Error: untracked files require'
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}" --head "$HEAD_SHA"; expect "allow with matching --head" 0 '^merge-gate: allow'
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}" --head "$BASE_SHA"; expect "refuse head mismatch" 1 '^merge-gate: refuse: head_mismatch'
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}" --head deadbeefnotacommit; expect "degraded unresolvable --head" 3 '^merge-gate: degraded: --head does not resolve'
  run "$S" "$ROOT/j/passive.json" --cwd "$REPO" --base-ref no-such-ref; expect "degraded unresolvable base-ref" 3 '^merge-gate: degraded: base-ref does not resolve'
  run "$S" "$ROOT/j/passive.json" --cwd "$ROOT/not-a-repo" --base-ref base; expect "degraded cwd not a repo" 3 '^merge-gate: degraded: --cwd is not a git repo'
  run "$S" "$ROOT/j/passive.json" --base-ref base; expect "usage: --cwd required" 2 '^merge-gate: usage'
  run "$S" "$ROOT/j/passive.json" --cwd "$REPO"; expect "usage: --base-ref required" 2 '^merge-gate: usage'
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}" --bogus; expect "usage: unknown flag" 2 '^merge-gate: usage'
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}" --merge abc; expect "usage: --merge needs a number" 2 '^merge-gate: usage'
  # assess invocation shape: read-only assess only, never review start; default run never calls gh
  : > "$ROOT/log"; run "$S" "$ROOT/j/passive.json" "${ARGS[@]}"
  if grep -q '^review assess ' "$ROOT/log" && grep -q -- '--committed-only' "$ROOT/log" \
     && grep -q -- '--json' "$ROOT/log" && ! grep -q 'review start' "$ROOT/log"; then ok "calls only read-only assess with --committed-only --json"
  else no "assess invocation shape ($(cat "$ROOT/log"))"; fi
  if ! grep -q '^gh ' "$ROOT/log"; then ok "default run never calls gh"; else no "default run called gh"; fi
  # absent binaries (restricted PATH)
  mkminimal "$ROOT/nojq" git bash env cat dirname mktemp rm; cp "$STUBS/gentle-ai" "$ROOT/nojq/"
  OUT="$(PATH="$ROOT/nojq" STUB_JSON="$ROOT/j/passive.json" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "degraded jq missing" 3 '^merge-gate: degraded: jq not found'
  mkminimal "$ROOT/nogent" git jq bash env cat dirname mktemp rm
  OUT="$(PATH="$ROOT/nogent" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "degraded gentle-ai missing" 3 '^merge-gate: degraded: gentle-ai not found'
  mkminimal "$ROOT/nogit" jq bash env cat dirname mktemp rm; cp "$STUBS/gentle-ai" "$ROOT/nogit/"
  OUT="$(PATH="$ROOT/nogit" STUB_JSON="$ROOT/j/passive.json" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "degraded git missing" 3 '^merge-gate: degraded: git not found'
  # --merge
  : > "$ROOT/log"
  runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  expect "merge after allow" 0 '^merge-gate: merged: PR #7'
  if grep -q "^gh pr merge 7 --squash --match-head-commit $HEAD_SHA" "$ROOT/log"; then ok "merge pins the reviewed head via --match-head-commit"; else no "merge args ($(cat "$ROOT/log"))"; fi
  : > "$ROOT/log"
  runenv "$S" "$ROOT/j/high.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  expect "no merge on refuse" 1 '^merge-gate: refuse: review_due'
  if ! grep -q 'pr merge' "$ROOT/log"; then ok "refuse never calls gh pr merge"; else no "gh pr merge ran on refuse"; fi
  : > "$ROOT/log"
  runenv "$S" "$ROOT/j/malformed.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  expect "no merge on degraded" 3 '^merge-gate: degraded'
  if ! grep -q 'pr merge' "$ROOT/log"; then ok "degraded never calls gh pr merge"; else no "gh pr merge ran on degraded"; fi
  : > "$ROOT/log"
  runenv "$S" "$ROOT/j/passive.json" "$BASE_SHA" 0 "${ARGS[@]}" --merge 7
  expect "refuse when PR head differs from reviewed head" 1 '^merge-gate: refuse: head_mismatch \(PR #7'
  if ! grep -q 'pr merge' "$ROOT/log"; then ok "PR head mismatch never calls gh pr merge"; else no "gh pr merge ran on PR head mismatch"; fi
  runenv "$S" "$ROOT/j/passive.json" "" 0 "${ARGS[@]}" --merge 7
  expect "degraded when PR head unreadable" 3 '^merge-gate: degraded: cannot read PR #7 head'
  runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 1 "${ARGS[@]}" --merge 7
  expect "degraded when gh pr merge fails" 3 '^merge-gate: degraded: gh pr merge failed'
  # --- fix-first round (B1/B2/N1-N5) ---
  # B2: assessed from the merge-base, never the moving ref
  : > "$ROOT/log"; run "$S" "$ROOT/j/passive.json" --cwd "$R2" --base-ref main
  expect "B2 allow when main moved ahead (assessed from merge-base)" 0 "^merge-gate: allow: passive .*merge_base=$C0_R2"
  if grep -q -- "--base-ref $C0_R2 " "$ROOT/log" && ! grep -q -- "--base-ref main" "$ROOT/log"; then ok "B2 assess is invoked with the merge-base sha, not the moving ref"; else no "B2 assess base ($(cat "$ROOT/log"))"; fi
  run "$S" "$ROOT/j/passive.json" --cwd "$R2" --base-ref feat; expect "N4 degraded on empty range (base == HEAD)" 3 '^merge-gate: degraded: empty range'
  rm -rf "$ROOT/orphan"; git init -q "$ROOT/orphan" && gc "$ROOT/orphan" o0 && git -C "$ROOT/orphan" fetch -q "$R2" feat:other 2>/dev/null
  run "$S" "$ROOT/j/passive.json" --cwd "$ROOT/orphan" --base-ref other; expect "degraded when no common ancestor" 3 '^merge-gate: degraded: no common ancestor'
  # B1: narrow --base-ref cannot hide earlier PR commits when merging
  PRB="$C0_R3"; : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref HEAD~1 --merge 7; PRB="$BASE_SHA"
  expect "B1 refuse base_excludes_pr_commits (dangerous commit + narrow base + --merge)" 1 '^merge-gate: refuse: base_excludes_pr_commits'
  if ! grep -q 'pr merge' "$ROOT/log"; then ok "B1 refuse never calls gh pr merge"; else no "B1 merged despite narrow base"; fi
  PRB="$C0_R3"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref "$C0_R3" --merge 7; PRB="$BASE_SHA"
  expect "B1 allow+merge when base is the PR branch point" 0 '^merge-gate: merged: PR #7'
  PRB="$C0_R3"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref HEAD~1; PRB="$BASE_SHA"
  expect "B1 narrow base without --merge stays a pure check (allow)" 0 '^merge-gate: allow'
  PRB="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref "$C0_R3" --merge 7; PRB="$BASE_SHA"
  expect "degraded when PR base commit is absent locally" 3 '^merge-gate: degraded: PR #7 base .* not present locally'
  PRB=""; runenv "$S" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref "$C0_R3" --merge 7; PRB="$BASE_SHA"
  expect "degraded when PR base unreadable" 3 '^merge-gate: degraded: cannot read PR #7 base'
  # N1: gh is bound to --cwd
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  if grep -q "^gh api repos/.* cwd:$REPO\$" "$ROOT/log" && grep -q "^gh pr merge .* cwd:$REPO\$" "$ROOT/log"; then ok "N1 gh runs inside --cwd"; else no "N1 gh cwd ($(cat "$ROOT/log"))"; fi
  case "$OUT" in *"cwd=$REPO"*) ok "N1 merged line names the repo dir";; *) no "N1 merged line ($OUT)";; esac
  # N2: HEAD moving during assess
  rm -rf "$ROOT/r4"; git clone -q "$REPO" "$ROOT/r4"
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_MOVE="$ROOT/r4" bash "$S" --cwd "$ROOT/r4" --base-ref "$BASE_SHA" 2>/dev/null)"; RC=$?
  expect "N2 degraded when HEAD moves during assess" 3 '^merge-gate: degraded: HEAD moved during assess'
  # N3: gh pr merge failure surfaces gh's line; head rejection is a refuse
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=1 STUB_MERGE_ERR="X Pull request is not mergeable" bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "N3 degraded surfaces gh's own first line" 3 'gh pr merge failed for PR #7: X Pull request is not mergeable'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=1 STUB_MERGE_ERR="Head branch was modified. Review and try the merge again." bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "N3 --match-head-commit rejection is refuse head_mismatch" 1 '^merge-gate: refuse: head_mismatch \(PR #7 head changed before merge'
  # N5: own hint for untracked files
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/high.json" STUB_RC=1 STUB_ERR="Error: untracked files require an explicit declaration" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "N5 own hint to clean or ignore untracked files" 3 'clean or ignore untracked files'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/high.json" STUB_RC=1 STUB_ERR="Error: something else" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  if [ "$RC" -eq 3 ] && ! <<<"$OUT" grep -q 'untracked'; then ok "N5 no untracked hint on unrelated assess errors"; else no "N5 hint leaked ($OUT)"; fi
  # teeth gaps: --merge without gh, gh pr view failing, unborn HEAD, mktemp failure
  mkminimal "$ROOT/nogh" git jq bash env cat dirname mktemp rm head cut grep; cp "$STUBS/gentle-ai" "$ROOT/nogh/"
  OUT="$(PATH="$ROOT/nogh" STUB_JSON="$ROOT/j/passive.json" bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "degraded --merge without gh" 3 '^merge-gate: degraded: gh not found'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_API_FAIL=1 bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "degraded when gh api fails" 3 '^merge-gate: degraded: cannot read PR #7 \(gh api failed\)'
  run "$S" "$ROOT/j/passive.json" --cwd "$R0" --base-ref HEAD; expect "degraded unborn HEAD" 3 '^merge-gate: degraded: cannot resolve HEAD'
  mkminimal "$ROOT/nomktemp" git jq bash env cat dirname rm head cut grep; cp "$STUBS/gentle-ai" "$ROOT/nomktemp/"
  OUT="$(PATH="$ROOT/nomktemp" STUB_JSON="$ROOT/j/passive.json" bash "$S" "${ARGS[@]}" 2>/dev/null)"; RC=$?
  expect "degraded mktemp missing" 3 '^merge-gate: degraded: mktemp failed'
  # --squash must be part of the merge call
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  if grep -q '^gh pr merge 7 --squash ' "$ROOT/log"; then ok "merge uses --squash"; else no "merge lacks --squash ($(cat "$ROOT/log"))"; fi
  # --- round 3: F1 (REST read), F2 (--pr check-only, range-only wording), N-a ---
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  if grep -q '^gh api repos/{owner}/{repo}/pulls/7 ' "$ROOT/log" && ! grep -q '^gh pr view' "$ROOT/log"; then ok "F1 PR head/base read via gh api REST, not gh pr view"; else no "F1 gh calls ($(cat "$ROOT/log"))"; fi
  # F2: pure run states its scope; --pr binds without merging
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}"
  expect "F2 pure run says range-only / not bound to a PR" 0 'allow: passive .*\(range-only; not bound to a PR — use --pr N or --merge N\)'
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 0 "${ARGS[@]}" --pr 7
  expect "F2 --pr allow is PR-bound" 0 'allow: passive .*\(bound to PR #7'
  if ! <<<"$OUT" grep -q 'range-only'; then ok "F2 --pr allow does not claim range-only"; else no "F2 --pr line still range-only ($OUT)"; fi
  if grep -q '^gh api ' "$ROOT/log" && ! grep -q 'pr merge' "$ROOT/log"; then ok "F2 --pr reads the PR but never merges"; else no "F2 --pr gh calls ($(cat "$ROOT/log"))"; fi
  case "$OUT" in *merged:*) no "F2 --pr printed merged";; *) ok "F2 --pr prints no merged line";; esac
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$BASE_SHA" 0 "${ARGS[@]}" --pr 7
  expect "F2 --pr refuses a PR head mismatch" 1 '^merge-gate: refuse: head_mismatch \(PR #7'
  PRB="$C0_R3"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref HEAD~1 --pr 7; PRB="$BASE_SHA"
  expect "F2 --pr refuses a narrow base (base_excludes_pr_commits)" 1 '^merge-gate: refuse: base_excludes_pr_commits'
  run "$S" "$ROOT/j/passive.json" "${ARGS[@]}" --pr abc; expect "usage: --pr needs a number" 2 '^merge-gate: usage'
  OUT="$(PATH="$ROOT/nogh" STUB_JSON="$ROOT/j/passive.json" bash "$S" "${ARGS[@]}" --pr 7 2>/dev/null)"; RC=$?
  expect "degraded --pr without gh" 3 '^merge-gate: degraded: gh not found'
  # stub self-check: an unknown pr-view field is rejected (so field drift is visible)
  if ! PATH="$STUBS:$PATH" gh pr view 1 --json headRefOid,baseRefOid >/dev/null 2>&1; then ok "stub rejects unknown gh pr view --json field baseRefOid"; else no "stub accepts baseRefOid"; fi
  # N-a: deprecation noise must not replace the real merge error; head rejection found anywhere
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=1 STUB_MERGE_ERR="$(printf 'GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience\nX Pull request is not mergeable')" bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "N-a deprecation line skipped when picking gh's error" 3 'gh pr merge failed for PR #7: X Pull request is not mergeable'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=1 STUB_MERGE_ERR="$(printf 'GraphQL: Projects (classic) is being deprecated\nHead branch was modified. Review and try the merge again.')" bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "N-a head rejection matched even behind a deprecation line" 1 '^merge-gate: refuse: head_mismatch \(PR #7 head changed before merge: Head branch was modified'
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=1 STUB_MERGE_ERR="$(printf 'X Merge failed\nHead branch was modified. Review and try the merge again.')" bash "$S" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?
  expect "N-a head rejection matched on a later line of gh output" 1 '^merge-gate: refuse: head_mismatch'
  # --- #1426: --merge refuses on pending / failed / missing CI checks bound to the exact head ---
  ck_nomerge() { if ! grep -q 'pr merge' "$ROOT/log"; then ok "$1 never calls gh pr merge"; else no "$1 merged anyway"; fi; }
  CKREQ="shellcheck,toolbelt-tests"
  mkchecks "$ROOT/ck/pass.json" shellcheck:completed:success toolbelt-tests:completed:success pr-validation:completed:success
  : > "$ROOT/log"; runck "$S" "$ROOT/ck/pass.json"
  expect "CI all pass -> merges" 0 '^merge-gate: merged: PR #7'
  if grep -q "^gh api repos/{owner}/{repo}/commits/$HEAD_SHA/check-runs" "$ROOT/log"; then ok "CI check-runs read for the exact head sha"; else no "CI gh calls ($(cat "$ROOT/log"))"; fi
  mkchecks "$ROOT/ck/pass2.json" shellcheck:completed:success toolbelt-tests:completed:skipped pr-validation:completed:neutral
  runck "$S" "$ROOT/ck/pass2.json"; expect "CI skipped/neutral count as pass" 0 '^merge-gate: merged: PR #7'
  # one case per bad state, offender FIRST / MIDDLE / LAST of three reported checks, plus single element
  for st in pending:queued: pending:in_progress: pending:waiting: failed:completed:failure failed:completed:cancelled failed:completed:timed_out failed:completed:action_required; do
    tok="${st%%:*}"; rest="${st#*:}"; bs="${rest%%:*}"; bc="${rest#*:}"; want="ci_$tok"
    for pos in first middle last; do
      case "$pos" in
        first)  mkchecks "$ROOT/ck/x.json" "shellcheck:$bs:$bc" toolbelt-tests:completed:success pr-validation:completed:success ;;
        middle) mkchecks "$ROOT/ck/x.json" shellcheck:completed:success "toolbelt-tests:$bs:$bc" pr-validation:completed:success ;;
        last)   mkchecks "$ROOT/ck/x.json" shellcheck:completed:success toolbelt-tests:completed:success "pr-validation:$bs:$bc" ;;
      esac
      : > "$ROOT/log"; runck "$S" "$ROOT/ck/x.json"
      expect "CI $want ($bs/${bc:-none}) offender $pos" 1 "^merge-gate: refuse: $want "
      ck_nomerge "CI $want offender $pos"
    done
    mkchecks "$ROOT/ck/x.json" "shellcheck:$bs:$bc"; CKREQ="shellcheck"; : > "$ROOT/log"; runck "$S" "$ROOT/ck/x.json"
    expect "CI $want ($bs/${bc:-none}) single element" 1 "^merge-gate: refuse: $want "; CKREQ="shellcheck,toolbelt-tests"
  done
  # a failure outranks a pending check reported alongside it
  mkchecks "$ROOT/ck/x.json" shellcheck:in_progress: toolbelt-tests:completed:failure
  runck "$S" "$ROOT/ck/x.json"; expect "CI failed outranks pending" 1 '^merge-gate: refuse: ci_failed '
  # the refusal names the offending check
  mkchecks "$ROOT/ck/x.json" shellcheck:completed:success toolbelt-tests:in_progress: pr-validation:completed:success
  runck "$S" "$ROOT/ck/x.json"; expect "CI refusal names the offending check" 1 'ci_pending \(toolbelt-tests\)'
  # missing: the absent required check FIRST / MIDDLE / LAST of a three-name list, and single element
  mkchecks "$ROOT/ck/x.json" b:completed:success c:completed:success; CKREQ="a,b,c"; runck "$S" "$ROOT/ck/x.json"
  expect "CI ci_missing required absent FIRST" 1 '^merge-gate: refuse: ci_missing \(a\)'
  mkchecks "$ROOT/ck/x.json" a:completed:success c:completed:success; runck "$S" "$ROOT/ck/x.json"
  expect "CI ci_missing required absent MIDDLE" 1 '^merge-gate: refuse: ci_missing \(b\)'
  mkchecks "$ROOT/ck/x.json" a:completed:success b:completed:success; : > "$ROOT/log"; runck "$S" "$ROOT/ck/x.json"
  expect "CI ci_missing required absent LAST" 1 '^merge-gate: refuse: ci_missing \(c\)'; ck_nomerge "CI ci_missing"
  mkchecks "$ROOT/ck/x.json" other:completed:success; CKREQ="a"; runck "$S" "$ROOT/ck/x.json"
  expect "CI ci_missing single-element required list" 1 '^merge-gate: refuse: ci_missing \(a\)'
  mkchecks "$ROOT/ck/x.json" axb:completed:success; CKREQ="a.b"; runck "$S" "$ROOT/ck/x.json"
  expect "CI required names match literally, not as regex" 1 '^merge-gate: refuse: ci_missing \(a.b\)'
  mkchecks "$ROOT/ck/x.json" shellcheck:completed:success toolbelt-tests:completed:success; CKREQ=" shellcheck , toolbelt-tests ,"; runck "$S" "$ROOT/ck/x.json"
  expect "CI required list tolerates spaces and a trailing comma" 0 '^merge-gate: merged: PR #7'
  CKREQ="shellcheck,toolbelt-tests"
  # explicitly empty list = opt-out of REQUIRED names only (doc-only PRs); reported checks must still be green
  mkchecks "$ROOT/ck/doc.json" pr-validation:completed:success
  CKREQ=""; runck "$S" "$ROOT/ck/doc.json"; expect "CI empty env list + only PR-validation passing -> merges" 0 '^merge-gate: merged: PR #7'
  CKREQ="shellcheck,toolbelt-tests"; runck "$S" "$ROOT/ck/doc.json" --required-checks ""
  expect "CI empty --required-checks overrides env and merges" 0 '^merge-gate: merged: PR #7'
  CKREQ=UNSET; runck "$S" "$ROOT/ck/doc.json"; expect "CI default required set refuses doc-only checks (ci_missing)" 1 '^merge-gate: refuse: ci_missing \(shellcheck,toolbelt-tests\)'
  runck "$S" "$ROOT/ck/pass.json"; expect "CI default required set passes when both present" 0 '^merge-gate: merged: PR #7'
  CKREQ=""; mkchecks "$ROOT/ck/x.json" pr-validation:in_progress:; runck "$S" "$ROOT/ck/x.json"
  expect "CI empty list still refuses a pending reported check" 1 '^merge-gate: refuse: ci_pending '
  mkchecks "$ROOT/ck/x.json" pr-validation:completed:failure; runck "$S" "$ROOT/ck/x.json"
  expect "CI empty list still refuses a failed reported check" 1 '^merge-gate: refuse: ci_failed '
  printf '{"total_count":0,"check_runs":[]}\n' > "$ROOT/ck/none.json"; runck "$S" "$ROOT/ck/none.json"
  expect "CI empty list + zero reported checks -> ci_pending (cannot prove CI ran)" 1 '^merge-gate: refuse: ci_pending \(no check runs reported'
  CKREQ="shellcheck,toolbelt-tests"; runck "$S" "$ROOT/ck/pass.json" --required-checks "shellcheck"
  expect "CI --required-checks flag overrides env" 0 '^merge-gate: merged: PR #7'
  runck "$S" "$ROOT/ck/pass.json" --required-checks "shellcheck,nope"; expect "CI --required-checks flag adds a required name" 1 '^merge-gate: refuse: ci_missing \(nope\)'
  OUT="$(PATH="$STUBS:$PATH" bash "$S" "${ARGS[@]}" --required-checks 2>/dev/null)"; RC=$?; expect "usage: --required-checks needs a value" 2 '^merge-gate: usage'
  # unreadable checks are degraded, never a merge
  : > "$ROOT/log"; CKFAIL=1 runck "$S" "$ROOT/ck/pass.json"
  expect "CI gh checks error -> degraded" 3 '^merge-gate: degraded: cannot read check runs'; ck_nomerge "CI gh error"
  expect "CI gh checks error surfaces gh stderr (#1433)" 3 'degraded: cannot read check runs.*HTTP 502'
  echo '{not json' > "$ROOT/ck/bad.json"; : > "$ROOT/log"; runck "$S" "$ROOT/ck/bad.json"
  expect "CI malformed JSON -> degraded" 3 '^merge-gate: degraded: .*check'; ck_nomerge "CI malformed JSON"
  echo '{"total_count":1}' > "$ROOT/ck/bad.json"; runck "$S" "$ROOT/ck/bad.json"
  expect "CI off-shape JSON (no check_runs array) -> degraded" 3 '^merge-gate: degraded: .*check'
  echo '{"check_runs":[{"status":"completed","conclusion":"success"}]}' > "$ROOT/ck/bad.json"; runck "$S" "$ROOT/ck/bad.json"
  expect "CI check run without a name -> degraded" 3 '^merge-gate: degraded: .*check'
  : > "$ROOT/empty.json"; runck "$S" "$ROOT/empty.json"; expect "CI empty gh output -> degraded" 3 '^merge-gate: degraded: .*check'
  # the CI gate is a --merge gate: --pr alone never reads check runs; review_due refuses before any read
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/passive.json" "$HEAD_SHA" 0 "${ARGS[@]}" --pr 7
  if ! grep -q 'check-runs' "$ROOT/log"; then ok "CI --pr check-only never reads check runs"; else no "CI --pr read check runs"; fi
  : > "$ROOT/log"; runenv "$S" "$ROOT/j/high.json" "$HEAD_SHA" 0 "${ARGS[@]}" --merge 7
  if ! grep -q 'check-runs' "$ROOT/log"; then ok "CI review_due refuse happens before any check-runs read"; else no "CI read after review_due"; fi
  # --- #1426 fix-first: latest run per (name, app.id) wins; two-page --paginate slurp ---
  # fields: name:status:conclusion:app:started_at:id  (started_at is parsed but never used for ordering; id compares as a number; empty = null)
  CKREQ="shellcheck"
  for pos in first middle last; do
    old="shellcheck:completed:failure:1:t1:10"; new="shellcheck:completed:success:1:t2:20"
    pad1="pr-validation:completed:success:1:t0:1"; pad2="other:completed:success:1:t0:2"
    case "$pos" in
      first)  l1="$old"; l2="$pad1"; l3="$new" ;;
      middle) l1="$pad1"; l2="$old"; l3="$new" ;;
      last)   l1="$pad1"; l2="$pad2"; l3="$old" ;;
    esac
    if [ "$pos" = last ]; then mkchecks "$ROOT/ck/d.json" "$l1" "$l2" "$l3" "$new"; else mkchecks "$ROOT/ck/d.json" "$l1" "$l2" "$l3"; fi
    runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: older failed + newer success same name -> merges (listed $pos)" 0 '^merge-gate: merged: PR #7'
    # newer listed BEFORE older: listing order must not decide
    mkchecks "$ROOT/ck/d.json" "$new" "$pad1" "$old"; runck "$S" "$ROOT/ck/d.json"
    expect "CI dedup: newer success listed before older failed -> merges ($pos pass)" 0 '^merge-gate: merged: PR #7'
  done
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:success:1:t1:10 shellcheck:completed:failure:1:t2:20
  : > "$ROOT/log"; runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: older success + newer failed -> ci_failed" 1 '^merge-gate: refuse: ci_failed \(shellcheck\)'; ck_nomerge "CI dedup newer failed"
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1:t2:20 shellcheck:completed:success:1:t1:10
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: newer failed listed first -> ci_failed" 1 '^merge-gate: refuse: ci_failed \(shellcheck\)'
  mkchecks "$ROOT/ck/d.json" pr-validation:completed:success:1:t0:1 shellcheck:completed:success:1:t1:10 shellcheck:in_progress::1:t2:20
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: older success + newer pending -> ci_pending" 1 '^merge-gate: refuse: ci_pending \(shellcheck\)'
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1:t1:10 shellcheck:in_progress::1:t2:20
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: older failed + newer pending -> ci_pending (stale failure ignored)" 1 '^merge-gate: refuse: ci_pending \(shellcheck\)'
  # same name from two different apps are two checks: both considered
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:success:1:t2:20 shellcheck:completed:failure:2:t1:10
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: same name, two apps, one failed -> ci_failed (app.id is part of the key)" 1 '^merge-gate: refuse: ci_failed \(shellcheck\)'
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1:t1:10 shellcheck:completed:success:1:t2:20 shellcheck:completed:success:2:t1:11
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: two apps, each latest green -> merges" 0 '^merge-gate: merged: PR #7'
  # started_at null: ordering is the highest check-run id only (started_at is never consulted)
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1::3 shellcheck:completed:success:1::5
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: started_at null, higher id success wins -> merges" 0 '^merge-gate: merged: PR #7'
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:success:1::3 shellcheck:completed:failure:1::5
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: started_at null, higher id failed wins -> ci_failed" 1 '^merge-gate: refuse: ci_failed \(shellcheck\)'
  # latest = highest check-run id, NEVER started_at: a fresh QUEUED rerun has null started_at and a higher id
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:success:1:t1:10 shellcheck:queued::1::20
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: older success + newer QUEUED rerun (null started_at, higher id) -> ci_pending" 1 '^merge-gate: refuse: ci_pending \(shellcheck\)'
  mkchecks "$ROOT/ck/d.json" shellcheck:queued::1::20 shellcheck:completed:success:1:t1:10
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: newer queued rerun listed first -> ci_pending" 1 '^merge-gate: refuse: ci_pending \(shellcheck\)'
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1:t1:10 shellcheck:queued::1::20
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: older failure + newer queued null-started rerun -> ci_pending" 1 '^merge-gate: refuse: ci_pending \(shellcheck\)'
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1:t2:10 shellcheck:completed:success:1:t1:20
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: higher id beats later started_at -> merges" 0 '^merge-gate: merged: PR #7'
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:success:1:t2:10 shellcheck:completed:failure:1:t1:20
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: higher id failed beats later started_at success -> ci_failed" 1 '^merge-gate: refuse: ci_failed \(shellcheck\)'
  # ids compare as numbers, not strings (9 < 10)
  mkchecks "$ROOT/ck/d.json" shellcheck:completed:failure:1::9 shellcheck:completed:success:1::10
  runck "$S" "$ROOT/ck/d.json"; expect "CI dedup: ids compare numerically (10 beats 9)" 0 '^merge-gate: merged: PR #7'
  # two-page --paginate output: two JSON objects concatenated; a gate that reads only page 1 must not pass
  printf '%s\n%s\n' '{"total_count":3,"check_runs":[{"name":"pr-validation","status":"completed","conclusion":"success"}]}' \
    '{"total_count":3,"check_runs":[{"name":"shellcheck","status":"completed","conclusion":"success"}]}' > "$ROOT/ck/pages.json"
  runck "$S" "$ROOT/ck/pages.json"; expect "CI two-page paginate: required check only on page 2 -> merges" 0 '^merge-gate: merged: PR #7'
  printf '%s\n%s\n' '{"total_count":2,"check_runs":[{"name":"shellcheck","status":"completed","conclusion":"success"}]}' \
    '{"total_count":2,"check_runs":[{"name":"toolbelt-tests","status":"completed","conclusion":"failure"}]}' > "$ROOT/ck/pages.json"
  CKREQ="shellcheck"; runck "$S" "$ROOT/ck/pages.json"; expect "CI two-page paginate: failure only on page 2 -> ci_failed" 1 '^merge-gate: refuse: ci_failed \(toolbelt-tests\)'
  CKREQ="shellcheck,toolbelt-tests"
}

echo "-- merge-gate behavioural suite --"
suite "$SUT"

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]; exit $?
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

# ---------------------------------------------------------------------------
echo "-- teeth: merge-gate mutation controls --"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
MUT_PASS=0; MUT_FAIL=0
MD="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$MD"' EXIT
# mutate <name> <sed-expr>: the mutated SUT must make the suite report at least one FAIL line.
mutate() {
  local name="$1" expr="$2" mut="$MD/$1.sh" rcm n pass_save fail_save
  mutant_sed "$SUT" "$mut" "$expr"; rcm=$?
  if [ "$rcm" -ne 0 ]; then echo "  FAIL(mut)  $name: mutant refused (rc=$rcm)"; MUT_FAIL=$((MUT_FAIL+1)); return; fi
  chmod +x "$mut"
  pass_save="$pass"; fail_save="$fail"
  suite "$mut" >"$MD/$name.out" 2>&1
  n="$(grep -c '^  FAIL  ' "$MD/$name.out")"
  pass="$pass_save"; fail="$fail_save"   # suite() bumps the globals; keep the real-suite totals
  if [ "$n" -gt 0 ]; then echo "  PASS(mut)  $name detected ($n failing cases)"; MUT_PASS=$((MUT_PASS+1))
  else echo "  FAIL(mut)  $name: suite stayed green"; MUT_FAIL=$((MUT_FAIL+1)); fi
}
# M01 (kit issue #1367): the old single mutant `s/^  exit 1$/  exit 0/` matched exactly ONE of the five
# `exit 1` refuse sites (the review_due one), so the other four exits had no mutant that flipped them.
# One tooth per exit site (plus the --cwd not-a-repo branch), each pinning the exact GOOD verdict on the
# original SUT and the specific BAD verdict on the mutant. A tooth fails when the original does not give
# the GOOD verdict, when the mutant is refused, or when the mutant does not give the BAD verdict.
sc_head_mismatch()  { run "$1" "$ROOT/j/passive.json" "${ARGS[@]}" --head "$BASE_SHA"; }
sc_pr_head_mismatch() { runenv "$1" "$ROOT/j/passive.json" "$BASE_SHA" 0 "${ARGS[@]}" --merge 7; }
sc_base_excludes()  { PRB="$C0_R3"; runenv "$1" "$ROOT/j/passive.json" "$HEAD_R3" 0 --cwd "$R3" --base-ref HEAD~1 --pr 7; PRB="$BASE_SHA"; }
sc_review_due()     { run "$1" "$ROOT/j/high.json" "${ARGS[@]}"; }
sc_merge_head_rej() { OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$ROOT/j/passive.json" STUB_PR_HEAD="$HEAD_SHA" STUB_PR_BASE="$BASE_SHA" STUB_MERGE_RC=1 STUB_MERGE_ERR="Head branch was modified. Review and try the merge again." bash "$1" "${ARGS[@]}" --merge 7 2>/dev/null)"; RC=$?; }
sc_cwd_not_repo()   { run "$1" "$ROOT/j/passive.json" --cwd "$ROOT/not-a-repo" --base-ref base; }
# tooth <name> <sed-expr> <scenario> <good-rc> <good-regex> <bad-rc> <bad-regex>
tooth() {
  local name="$1" expr="$2" sc="$3" grc="$4" gre="$5" brc="$6" bre="$7" mut="$MD/$1.sh" rcm
  "$sc" "$SUT"
  if [ "$RC" -ne "$grc" ] || ! <<<"$OUT" grep -Eq "$gre"; then
    echo "  FAIL(mut)  $name: original gave rc=$RC out=[$OUT], wanted rc=$grc /$gre/"; MUT_FAIL=$((MUT_FAIL+1)); return; fi
  mutant_sed "$SUT" "$mut" "$expr"; rcm=$?
  if [ "$rcm" -ne 0 ]; then echo "  FAIL(mut)  $name: mutant refused (rc=$rcm)"; MUT_FAIL=$((MUT_FAIL+1)); return; fi
  chmod +x "$mut"; "$sc" "$mut"
  if [ "$RC" -eq "$brc" ] && <<<"$OUT" grep -Eq "$bre"; then
    echo "  PASS(mut)  $name: good rc=$grc -> mutant rc=$RC"; MUT_PASS=$((MUT_PASS+1))
  else echo "  FAIL(mut)  $name: mutant gave rc=$RC out=[$OUT], wanted rc=$brc /$bre/"; MUT_FAIL=$((MUT_FAIL+1)); fi
}
tooth M01a-head-mismatch-exit   '/refuse: head_mismatch (--head/{n;s/exit 1/exit 0/;}' sc_head_mismatch 1 '^merge-gate: refuse: head_mismatch \(--head' 0 '^merge-gate: refuse: head_mismatch \(--head'
tooth M01b-pr-head-mismatch-exit '/refuse: head_mismatch (PR #\$pr head \$pr_head/{n;s/exit 1/exit 0/;}' sc_pr_head_mismatch 1 '^merge-gate: refuse: head_mismatch \(PR #7 head' 0 '^merge-gate: refuse: head_mismatch \(PR #7 head'
tooth M01c-base-excludes-exit   '/say "refuse: base_excludes_pr_commits/{n;s/exit 1/exit 0/;}' sc_base_excludes 1 '^merge-gate: refuse: base_excludes_pr_commits' 0 '^merge-gate: refuse: base_excludes_pr_commits'
tooth M01d-review-due-exit      '/say "refuse: review_due (/{n;s/exit 1/exit 0/;}' sc_review_due 1 '^merge-gate: refuse: review_due \(high_risk\)' 0 '^merge-gate: refuse: review_due \(high_risk\)'
tooth M01e-merge-head-rej-exit  '/refuse: head_mismatch (PR #\$pr head changed/{n;s/exit 1/exit 0/;}' sc_merge_head_rej 1 '^merge-gate: refuse: head_mismatch \(PR #7 head changed' 0 '^merge-gate: refuse: head_mismatch \(PR #7 head changed'
# --cwd not-a-repo branch: without the degraded the run falls through to the NEXT probe (HEAD resolution).
tooth M01f-cwd-not-repo-ok      's/|| degraded "--cwd is not a git repo[^"]*"/|| :/' sc_cwd_not_repo 3 '^merge-gate: degraded: --cwd is not a git repo' 3 '^merge-gate: degraded: cannot resolve HEAD'
mutate M02-already-reviewed-gone  's/passive|already_reviewed|under_budget) ;;/passive|under_budget) ;;/'
mutate M03-unknown-reason-allowed 's/^  \*) degraded "unknown not-due.*/  *) ;;/'
mutate M04-assess-rc-ignored      's/^if \[ "\$assess_rc" -ne 0 \]; then/if false; then/'
mutate M05-schema-unchecked       's/^\[ "\$schema" = .*/:/'
mutate M06-head-mismatch-ignored  's/if \[ "\$want_full" != "\$head" \]; then/if false; then/'
mutate M07-pr-head-unchecked      's/if \[ "\$pr_head" != "\$head" \]; then/if false; then/'
mutate M08-merge-unpinned         's/--match-head-commit "\$head"/--auto/'
mutate M09-jq-probe-removed       's/^command -v jq .*/:/'
mutate M10-gentle-probe-removed   's/^command -v gentle-ai .*/:/'
mutate M11-git-probe-removed      's/^command -v git .*/:/'
mutate M12-pr-head-read-unchecked 's/^  \[ -n "\$pr_head" \] || degraded.*/  :/'
mutate M13-bool-unchecked         's/^case "\$due" in true|false) ;; \*) degraded.*/:/'
mutate M14-reason-missing-ok      's/^\[ -n "\$reason" \] || degraded.*/:/'
mutate M15-merge-failure-ignored  's/^  degraded "gh pr merge failed.*/  :/'
mutate M16-pr-number-unchecked    's/^case "\$pr" in .*/:/'
mutate M17-committed-only-dropped 's/ --committed-only//'
mutate M20-base-unresolvable-ok   's/^git -C "\$cwd" rev-parse --verify --quiet "\${base}\^{commit}".*/:/'
mutate M21-assess-from-moving-ref 's/--base-ref "\$mb"/--base-ref "\$base"/'
mutate M22-narrow-base-allowed    's/^  if ! git -C "\$cwd" merge-base --is-ancestor.*/  if false; then/'
mutate M23-empty-range-ok         's/^\[ "\$ahead" -gt 0 \] || degraded.*/:/'
mutate M24-head-move-ignored      's/^\[ "\$head_after" = "\$head" \] || degraded.*/:/'
mutate M25-gh-not-bound-to-cwd    's/(cd "\$cwd" \&\& gh "\$@")/gh "\$@"/'
mutate M26-no-squash              's/ --squash//'
mutate M27-merge-reject-degraded  's/grep -Eqi .head branch was modified|match-head-commit|head sha./grep -Eqi "NEVER-MATCHES-XYZ"/'
mutate M28-untracked-hint-dropped 's/^  if grep -qi .untracked. "\$err_file".*/  if false; then hint=""; fi/'
mutate M29-merge-err-dropped      's/\${merge_line:+: \$merge_line}//'
mutate M30-pr-view-unchecked      's/^  \[ -n "\$pr_json" \] || degraded.*/  :/'
mutate M31-pr-base-presence       's/^  git -C "\$cwd" cat-file -e .*/  :/'
mutate M32-no-ancestor-unchecked  's/^mb="\$(git -C "\$cwd" merge-base HEAD "\$base" 2>\/dev\/null)" || degraded.*/mb="$(git -C "$cwd" merge-base HEAD "$base" 2>\/dev\/null)"/;s/^\[ -n "\$mb" \] || degraded.*/:/'
mutate M33-mktemp-unchecked       's/^err_file="\$(mktemp 2>\/dev\/null)" || degraded.*/err_file="$(mktemp 2>\/dev\/null)"/'
mutate M34-unborn-head-ok         's/^head="\$(git -C "\$cwd" rev-parse --verify HEAD 2>\/dev\/null)" || degraded.*/head="$(git -C "$cwd" rev-parse --verify HEAD 2>\/dev\/null)"/'
mutate M35-gh-probe-removed       's/^if \[ -n "\$pr" \]; then command -v gh.*/:/'
mutate M36-rest-read-reverted     's/ghr api "repos\/{owner}\/{repo}\/pulls\/\$pr" --jq .{headRefOid:.head.sha, baseRefOid:.base.sha, baseRefName:.base.ref}./ghr pr view "$pr" --json headRefOid,baseRefName,baseRefOid/'
mutate M37-always-range-only      's/^if \[ -z "\$pr" \]; then/if true; then/'
mutate M38-pr-implies-merge       's/^\[ -n "\$do_merge" \] || exit 0/:/'
mutate M39-pr-flag-ignored        's/^    --pr) .*/    --pr) shift 2 ;;/'
mutate M40-deprecation-not-skipped 's/grep -Evi .deprecat|\^warning./cat/'
mutate M41-head-reject-first-line-only 's/printf .%s. "\$merge_out" | grep -Eqi/printf "%s" "$merge_line" | grep -Eqi/'
sc_ci_stderr() { CKREQ="shellcheck"; : > "$ROOT/log"; CKFAIL=1 runck "$1" "$ROOT/ck/pass.json"; }
tooth M19b-ci-stderr-dropped 's/\${ci_err:+: \$ci_err}//' sc_ci_stderr 3 'HTTP 502' 3 '^merge-gate: degraded: cannot read check runs for head [0-9a-f]+ \(gh api failed\)$'
mutate M19-stderr-dropped         's/\${err_line:+: \$err_line}//'
mutate M18-unparseable-passes     's/^printf .%s. "\$assess_out" | jq -e \. .*/:/'
# #1426 CI-gate mutants. sc_ci_* run on the check files written below (and by the suite) under $ROOT/ck.
sc_ci_pending() { CKREQ="shellcheck,toolbelt-tests"; runck "$1" "$ROOT/ck/x_pending.json"; }
sc_ci_failed()  { CKREQ="shellcheck,toolbelt-tests"; runck "$1" "$ROOT/ck/x_failed.json"; }
sc_ci_missing() { CKREQ="shellcheck,toolbelt-tests"; runck "$1" "$ROOT/ck/doc.json"; }
mkchecks "$ROOT/ck/x_pending.json" shellcheck:completed:success toolbelt-tests:in_progress:
mkchecks "$ROOT/ck/x_failed.json" shellcheck:completed:success toolbelt-tests:completed:failure
tooth M50-ci-pending-exit  '/CI for this exact head must be green/{n;s/exit 1/exit 0/;}' sc_ci_pending 1 '^merge-gate: refuse: ci_pending' 0 '^merge-gate: refuse: ci_pending'
tooth M51-ci-failed-exit   '/CI for this exact head must be green/{n;s/exit 1/exit 0/;}' sc_ci_failed 1 '^merge-gate: refuse: ci_failed' 0 '^merge-gate: refuse: ci_failed'
tooth M52-ci-gate-skipped  's/^if \[ -n "\$do_merge" \]; then$/if false; then/' sc_ci_missing 1 '^merge-gate: refuse: ci_missing' 0 '^merge-gate: merged'
tooth M53-pending-as-pass  's/elif (\$pending | length) > 0 then/elif false then/' sc_ci_pending 1 '^merge-gate: refuse: ci_pending' 0 '^merge-gate: merged'
tooth M54-missing-dropped  's/elif (\$missing | length) > 0 then/elif false then/' sc_ci_missing 1 '^merge-gate: refuse: ci_missing' 0 '^merge-gate: merged'
tooth M55-failed-dropped   's/if (\$failed | length) > 0 then/if false then/' sc_ci_failed 1 '^merge-gate: refuse: ci_failed' 0 '^merge-gate: merged'
mutate M56-only-failure-conclusion-fails 's/((\.conclusion \/\/ "") | IN("success", "skipped", "neutral") | not)/((.conclusion \/\/ "") == "failure")/'
mutate M57-default-required-emptied      's/^required="shellcheck,toolbelt-tests"/required=""/'
mutate M58-env-required-ignored          's/^\[ -z "\${MERGE_GATE_REQUIRED_CHECKS+x}" \] || required=.*/:/'
mutate M59-flag-required-ignored         's/required="\$2"; shift 2 ;;/shift 2 ;;/'
mutate M60-checks-not-bound-to-head      's/commits\/\$head\/check-runs/commits\/HEAD\/check-runs/'
mutate M61-required-not-trimmed          's/map(gsub("^\\\\s+|\\\\s+\$"; ""))/./'
mutate M62-zero-reported-ok              's/elif length == 0 then .*/elif length == 0 then "ok"/'
mutate M63-gh-error-ignored              's/^    degraded "cannot read check runs for head[^"]*"/    :/'
mutate M64-shape-unchecked               's/error("shape")/[]/g'
mutate M66-unpaginated-single-page       's/ --paginate//'
mutate M67-required-flag-usage-unchecked 's/^    --required-checks) \[ \$# -ge 2 \] || usage[^;]*;/    --required-checks)/'
mutate M68-dedup-removed                 's/^    | group_by(\[\.name, \.app_id\]) | map(max_by(\.id))/    | .   /'
mutate M69-dedup-picks-oldest            's/map(max_by(\.id))/map(min_by(.id))/'
mutate M70-app-id-ignored-in-key         's/group_by(\[\.name, \.app_id\])/group_by([.name])/'
mutate M71-order-by-started-at-first     's/id: (\.id? \/\/ 0)/id: (.id? \/\/ 0), started_at: (.started_at? \/\/ "")/;s/map(max_by(\.id))/map(max_by([.started_at, .id]))/'
mutate M72-id-compared-as-string         's/id: (\.id? \/\/ 0)/id: ((.id? \/\/ 0) | tostring)/'
mutate M73-first-page-only               's/\[\.\[\]\.check_runs\[\]\]/[.[0].check_runs[]]/'
echo "mutants: $MUT_PASS detected · $MUT_FAIL missed"
echo "== $pass passed · $((fail + MUT_FAIL)) failed =="
[ "$fail" -eq 0 ] && [ "$MUT_FAIL" -eq 0 ]
