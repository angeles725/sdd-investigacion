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

# --- stub bin dir: gentle-ai and gh ------------------------------------------------------------
STUBS="$ROOT/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/gentle-ai" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:-/dev/null}"
[ -n "${STUB_JSON:-}" ] && cat "$STUB_JSON"
[ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUB
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_LOG:-/dev/null}"
case "$1 $2" in
  "pr view") echo "${STUB_PR_HEAD:-}"; exit 0 ;;
  "pr merge") exit "${STUB_MERGE_RC:-0}" ;;
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

OUT=""; RC=0
# run <sut> <json> [sut args...]   (stubs first on PATH)
run() {
  local sut="$1" json="$2"; shift 2
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$json" STUB_LOG="$ROOT/log" bash "$sut" "$@" 2>"$ROOT/err")"; RC=$?
}
# runenv <sut> <json> <pr-head> <merge-rc> [sut args...]   (for --merge cases)
runenv() {
  local sut="$1" json="$2" prh="$3" mrc="$4"; shift 4
  OUT="$(PATH="$STUBS:$PATH" STUB_JSON="$json" STUB_PR_HEAD="$prh" STUB_MERGE_RC="$mrc" STUB_LOG="$ROOT/log" bash "$sut" "$@" 2>"$ROOT/err")"; RC=$?
}
expect() { # expect <label> <rc> <regex-on-stdout>
  if [ "$RC" -eq "$2" ] && printf '%s' "$OUT" | grep -Eq "$3"; then ok "$1"
  else no "$1 (rc=$RC want $2; out: $OUT)"; fi
}
ARGS=(--cwd "$REPO" --base-ref base)

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
mutate M01-refuse-exits-zero      's/^  exit 1$/  exit 0/'
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
mutate M12-pr-head-read-unchecked 's/^\[ -n "\$pr_head" \] || degraded.*/:/'
mutate M13-bool-unchecked         's/^case "\$due" in true|false) ;; \*) degraded.*/:/'
mutate M14-reason-missing-ok      's/^\[ -n "\$reason" \] || degraded.*/:/'
mutate M15-merge-failure-ignored  's/ || degraded "gh pr merge failed.*/ || true/'
mutate M16-pr-number-unchecked    's/^case "\$pr" in .*/:/'
mutate M17-committed-only-dropped 's/ --committed-only//'
mutate M19-stderr-dropped         's/\${err_line:+: \$err_line}//'
mutate M18-unparseable-passes     's/^printf .%s. "\$assess_out" | jq -e \. .*/:/'
echo "== $pass passed · $fail failed · mutants $MUT_PASS detected · $MUT_FAIL missed =="
[ "$fail" -eq 0 ] && [ "$MUT_FAIL" -eq 0 ]
