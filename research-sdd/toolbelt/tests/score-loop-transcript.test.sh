#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../score-loop-transcript.sh"
FIX="$HERE/fixtures/score-loop"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# --- repo builder: mkrepo <dir> [<iso-date> <subject>]... -------------------------------------
mkrepo() {
  local dir="$1"; shift
  git init -q "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  local n=0 ts subj
  while [ "$#" -ge 2 ]; do
    ts="$1"; subj="$2"; shift 2
    n=$((n+1))
    echo "$n" > "$dir/f.txt"
    git -C "$dir" add f.txt
    GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" git -C "$dir" commit -q -m "$subj" >/dev/null
  done
}

STUB_STOP="$FIX/stub-status-stop-empty.sh"
STUB_NOTSTOP="$FIX/stub-status-not-stop.sh"

# --- fixture repos --------------------------------------------------------------------------
# "continue" repo: B1@00:10, B2@00:20 — no commit at/after 00:25 (the STOP moment in
# continue-clean.jsonl). Backs C1-pass, C2-pass, C4-pass.
mkrepo "$ROOT/continue" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:20:00Z" "research(demo): B2 gap-b"

# "continue-poststop" repo: same as above plus a THIRD block commit after the STOP moment.
mkrepo "$ROOT/continue-poststop" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:20:00Z" "research(demo): B2 gap-b" \
  "2026-06-01T00:30:00Z" "research(demo): B3 gap-c"

# "compaction-survive" repo: B1 before the 00:00 compaction boundary, B2 after it.
mkrepo "$ROOT/compaction-survive" \
  "2026-05-31T23:50:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:10:00Z" "research(demo): B2 gap-b"

# "compaction-stall" repo: only a block commit BEFORE the compaction boundary.
mkrepo "$ROOT/compaction-stall" \
  "2026-05-31T23:50:00Z" "research(demo): B1 gap-a"

# "one-block" repo: a single block commit — fails the >=2 threshold outright.
mkrepo "$ROOT/one-block" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a"

# "no-git" — a plain directory, never `git init`'d.
mkdir -p "$ROOT/no-git"

# ============================================================================================
# Bad args / operational failures
# ============================================================================================
if ! bash "$SUT" >/dev/null 2>&1; then ok "missing --corpus exits non-zero"; else no "missing --corpus"; fi
rc=$(bash "$SUT" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "missing --corpus: exit 2 (bad args)" || no "missing --corpus: exit 2 (bad args), got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/does-not-exist" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 1 ] && ok "corpus not found: exit 1 (operational)" || no "corpus not found: exit 1, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/no-git" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 1 ] && ok "corpus not a git repo: exit 1 (operational)" || no "corpus not a git repo: exit 1, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/continue" --transcript "$ROOT/nope.jsonl" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "missing --transcript file: exit 2 (bad args)" || no "missing --transcript file: exit 2, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/continue" --bogus-flag >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "unknown flag: exit 2 (bad args)" || no "unknown flag: exit 2, got $rc"

# ============================================================================================
# Without a transcript — C1 still counts commits (n/a for the operator-input sub-check);
# C2/C3/C4 are all n/a (no transcript given at all).
# ============================================================================================
out="$(bash "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "no-transcript run: exit 0" || no "no-transcript run: exit 0, got $rc"
echo "$out" | grep -qE '^C1 n/a 2 block commits' && ok "no-transcript: C1 counts 2 block commits, n/a" || no "no-transcript: C1 count ($out)"
echo "$out" | grep -qE '^C2 n/a no transcript$' && ok "no-transcript: C2 n/a" || no "no-transcript: C2 n/a ($out)"
echo "$out" | grep -qE '^C3 n/a no transcript$' && ok "no-transcript: C3 n/a" || no "no-transcript: C3 n/a ($out)"
echo "$out" | grep -qE '^C4 n/a no transcript' && ok "no-transcript: C4 n/a" || no "no-transcript: C4 n/a ($out)"
echo "$out" | grep -qE '^SUMMARY pass=0 fail=0 n/a=4 degraded=0$' && ok "no-transcript: summary" || no "no-transcript: summary ($out)"

out="$(bash "$SUT" --corpus "$ROOT/one-block" 2>&1)"
echo "$out" | grep -qE '^C1 fail only 1 block commit' && ok "one-block corpus: C1 fail (below threshold)" || no "one-block corpus: C1 ($out)"

# ============================================================================================
# Clean continuation — all four criteria pass.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "continue-clean: exit 0" || no "continue-clean: exit 0, got $rc"
echo "$out" | grep -qE '^C1 pass 2 block commits, 0 operator turns' && ok "continue-clean: C1 pass" || no "continue-clean: C1 ($out)"
echo "$out" | grep -qE '^C2 pass 0 of 1 final returns' && ok "continue-clean: C2 pass" || no "continue-clean: C2 ($out)"
echo "$out" | grep -qE '^C3 n/a no compaction event found' && ok "continue-clean: C3 n/a (no compaction in this fixture)" || no "continue-clean: C3 ($out)"
echo "$out" | grep -qE '^C4 pass STOP token present' && ok "continue-clean: C4 pass" || no "continue-clean: C4 ($out)"
echo "$out" | grep -qE '^SUMMARY pass=3 fail=0 n/a=1 degraded=0$' && ok "continue-clean: summary" || no "continue-clean: summary ($out)"

# ============================================================================================
# C1 fail — an operator turn lands between two block commits.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/operator-interrupt.jsonl" 2>&1)"
echo "$out" | grep -qE '^C1 fail 2 block commits but 1 of 1 gap' && ok "operator-interrupt: C1 fail" || no "operator-interrupt: C1 ($out)"

# ============================================================================================
# C2 fail — two final returns end in a question (both regex alternatives exercised:
# "Shall I ...?" and "... do you want ..." with no trailing '?').
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/question-ending.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 fail 2 of 2 final returns end in a question' && ok "question-ending: C2 fail" || no "question-ending: C2 ($out)"

# ============================================================================================
# C3 — compaction survived (blocks both before and after) vs. compaction stall (none after).
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-survive" \
  --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
echo "$out" | grep -qE '^C3 pass compaction detected; 1 block commit\(s\) before, 1 after' \
  && ok "compaction-survive: C3 pass" || no "compaction-survive: C3 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-stall" \
  --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
echo "$out" | grep -qE '^C3 fail compaction detected; 1 block commit\(s\) before, 0 after' \
  && ok "compaction-stall: C3 fail" || no "compaction-stall: C3 ($out)"

# ============================================================================================
# C4 fail paths — status disagrees, and a block commit lands after STOP.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_NOTSTOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 fail stop_token=present status_next=NOT-STOP' \
  && ok "continue-clean + not-stop status: C4 fail" || no "continue-clean + not-stop status: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue-poststop" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 fail stop_token=present status_next=STOP queue=empty commits_after_stop=1' \
  && ok "commit after STOP: C4 fail" || no "commit after STOP: C4 ($out)"

# ============================================================================================
# --base-ref / --since scoping — the window excludes B1 when scoped to start after it.
# ============================================================================================
b1_sha="$(git -C "$ROOT/continue" log --format='%H' --grep='^research(demo): B1' -- . | head -n1)"
out="$(bash "$SUT" --corpus "$ROOT/continue" --base-ref "$b1_sha" 2>&1)"
echo "$out" | grep -qE '^C1 fail only 1 block commit' && ok "--base-ref scopes the window (B1 excluded)" || no "--base-ref scoping ($out)"

out="$(bash "$SUT" --corpus "$ROOT/continue" --since "2026-06-01T00:15:00Z" 2>&1)"
echo "$out" | grep -qE '^C1 fail only 1 block commit' && ok "--since scopes the window (B1 excluded)" || no "--since scoping ($out)"

# ============================================================================================
# Degraded states — malformed transcript JSON, and dependencies absent.
# ============================================================================================
printf '{"type":"user","timestamp":"2026-06-01T00:00:00Z","message":{"role":"user","content":"hi"}}\nnot-json\n' \
  > "$ROOT/malformed.jsonl"
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$ROOT/malformed.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 degraded degraded: transcript did not parse cleanly' \
  && ok "malformed transcript: C2 degraded" || no "malformed transcript: C2 ($out)"
echo "$out" | grep -qE '^C1 degraded 2 block commits in window; degraded:' \
  && ok "malformed transcript: C1 degraded (commit count still reported)" || no "malformed transcript: C1 ($out)"

real_git="$(command -v git)"
mkdir -p "$ROOT/bin-nojq"
ln -s "$real_git" "$ROOT/bin-nojq/git"
out="$(PATH="$ROOT/bin-nojq:/usr/bin:/bin" RSDD_STATUS_SCRIPT="$STUB_STOP" \
  bash "$SUT" --corpus "$ROOT/continue" --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 degraded degraded: jq not found in PATH' \
  && ok "jq absent: C2 degraded" || no "jq absent: C2 ($out)"
echo "$out" | grep -qE '^C1 degraded 2 block commits in window; degraded: jq not found' \
  && ok "jq absent: C1 degraded (commit count still reported)" || no "jq absent: C1 ($out)"

real_bash="$(command -v bash)"
mkdir -p "$ROOT/bin-nogit"
for tool in date sort mktemp grep cat printf bash; do
  t="$(command -v "$tool")"
  [ -n "$t" ] && ln -sf "$t" "$ROOT/bin-nogit/$tool"
done
out="$(PATH="$ROOT/bin-nogit" "$real_bash" "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "git absent: exit 3 (degraded)" || no "git absent: exit 3, got $rc"
echo "$out" | grep -qE '^C1 degraded git-not-found$' && ok "git absent: C1 degraded git-not-found" || no "git absent: C1 ($out)"
echo "$out" | grep -qE '^C4 degraded git-not-found$' && ok "git absent: C4 degraded git-not-found" || no "git absent: C4 ($out)"

# ============================================================================================
# Mutation self-test (--prove-teeth): flip one matching seam per criterion and confirm the
# assertion above goes red against the exact SUT bytes that would ship a broken criterion.
# ============================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  mutant() {
    # mutant <name> <sed-expr> — writes a mutated copy of the SUT, prints its path.
    local name="$1" expr="$2"
    local out="$ROOT/score-loop-transcript.MUTANT-$name.sh"
    sed "$expr" "$SUT" > "$out"
    printf '%s' "$out"
  }

  echo "-- teeth-C1: neutralise the block-commit regex match; expect C1 to report 0 commits --"
  m="$(mutant c1 's/"\$subj" =~ \$BLOCK_COMMIT_REGEX/"$subj" =~ ^NEVERMATCH_MUTANT_XYZ$/')"
  if grep -qF 'NEVERMATCH_MUTANT_XYZ' "$m"; then
    mo="$(bash "$m" --corpus "$ROOT/continue" 2>&1)"
    if echo "$mo" | grep -qE '^C1 fail 0 block commits'; then
      ok "teeth-C1: block-commit match neutralised → C1 collapses to 0 commits"
    else
      no "teeth-C1: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-C1: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C2: neutralise the question regex match; expect C2 to flip to pass --"
  m="$(mutant c2 's/"\$line" =~ \$QUESTION_REGEX/"$line" =~ ^NEVERMATCH_MUTANT_XYZ$/')"
  if grep -qF 'NEVERMATCH_MUTANT_XYZ' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/question-ending.jsonl" 2>&1)"
    if echo "$mo" | grep -qE '^C2 pass 0 of 2'; then
      ok "teeth-C2: question match neutralised → C2 falsely reports pass"
    else
      no "teeth-C2: mutant did not flip C2 — no teeth ($mo)"
    fi
  else
    no "teeth-C2: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C3: neutralise compaction detection; expect C3 to flip to n/a --"
  m="$(mutant c3 's/"\$is_cx" == "true"/"$is_cx" == "MUTANT_NEVER"/')"
  if grep -qF 'MUTANT_NEVER' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/compaction-survive" \
      --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
    if echo "$mo" | grep -qE '^C3 n/a no compaction event found'; then
      ok "teeth-C3: compaction detection neutralised → C3 falsely reports n/a"
    else
      no "teeth-C3: mutant did not flip C3 — no teeth ($mo)"
    fi
  else
    no "teeth-C3: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C4: neutralise the STOP-token regex match; expect C4 to flip to fail --"
  m="$(mutant c4 's/"\$stop_line" =~ \$STOP_TOKEN_REGEX/"$stop_line" =~ ^NEVERMATCH_MUTANT_XYZ$/')"
  if grep -qF 'NEVERMATCH_MUTANT_XYZ' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/continue-clean.jsonl" 2>&1)"
    if echo "$mo" | grep -qE '^C4 fail stop_token=absent'; then
      ok "teeth-C4: STOP-token match neutralised → C4 falsely reports fail"
    else
      no "teeth-C4: mutant did not flip C4 — no teeth ($mo)"
    fi
  else
    no "teeth-C4: mutant build failed (source line not found)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
