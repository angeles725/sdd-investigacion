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
STUB_STALE="$FIX/stub-status-stale.sh"
STUB_FAILING="$FIX/stub-status-failing.sh"

# --- fixture repos --------------------------------------------------------------------------
mkrepo "$ROOT/continue" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:20:00Z" "research(demo): B2 gap-b"

mkrepo "$ROOT/continue-poststop" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:20:00Z" "research(demo): B2 gap-b" \
  "2026-06-01T00:30:00Z" "research(demo): B3 gap-c"

mkrepo "$ROOT/compaction-survive" \
  "2026-05-31T23:50:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:10:00Z" "research(demo): B2 gap-b"

mkrepo "$ROOT/compaction-stall" \
  "2026-05-31T23:50:00Z" "research(demo): B1 gap-a"

mkrepo "$ROOT/one-block" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a"

# span [00:10,00:20] in out-of-span.jsonl; B1 before it, B2 inside it.
mkrepo "$ROOT/out-of-span-repo" \
  "2026-06-01T00:05:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:15:00Z" "research(demo): B2 gap-b"

# real-shape block-subject regression: a preamble before the block ref, an explicit
# B<n>-B<m> range (weight 3), and a retro that only CITES a prior range in a trailing
# parenthetical (must NOT be counted at all). Neutral synthetic subjects, not copied
# from any real corpus.
mkrepo "$ROOT/block-regex" \
  "2026-06-01T00:05:00Z" "research(demo/wb-vendor-ux): bootstrap focus + B1054 synthetic palette WB" \
  "2026-06-01T00:10:00Z" "research(demo/security-seams): B1161-B1163 SES10 — synthetic native RE" \
  "2026-06-01T00:15:00Z" "research(demo/module-mechanics): §18 full-run retro (B867-B891, MM1-MM25)"

mkdir -p "$ROOT/no-git"

# ============================================================================================
# Bad args / operational failures
# ============================================================================================
rc=$(bash "$SUT" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "missing --corpus: exit 2 (bad args)" || no "missing --corpus: exit 2, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/does-not-exist" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 1 ] && ok "corpus not found: exit 1 (operational)" || no "corpus not found: exit 1, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/no-git" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 1 ] && ok "corpus not a git repo: exit 1 (operational)" || no "corpus not a git repo: exit 1, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/continue" --transcript "$ROOT/nope.jsonl" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "missing --transcript file: exit 2 (bad args)" || no "missing --transcript file: exit 2, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/continue" --bogus-flag >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "unknown flag: exit 2 (bad args)" || no "unknown flag: exit 2, got $rc"

# git log itself failing (a bad --base-ref) must exit 1 with the error surfaced, not swallowed.
out="$(bash "$SUT" --corpus "$ROOT/continue" --base-ref not-a-real-ref 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "bad --base-ref: exit 1 (git failure surfaced)" || no "bad --base-ref: exit 1, got $rc"
echo "$out" | grep -qi "git log failed" && ok "bad --base-ref: stderr names the git failure" || no "bad --base-ref: stderr ($out)"

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
# Clean continuation — all four criteria pass. C3 is "no compaction" -> pass, not n/a.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "continue-clean: exit 0" || no "continue-clean: exit 0, got $rc"
echo "$out" | grep -qE '^C1 pass 2 block commits, 0 operator turns' && ok "continue-clean: C1 pass" || no "continue-clean: C1 ($out)"
echo "$out" | grep -qE '^C2 pass 0 of 1 final returns' && ok "continue-clean: C2 pass" || no "continue-clean: C2 ($out)"
echo "$out" | grep -qE '^C3 pass no compaction, 2 block\(s\)$' && ok "continue-clean: C3 pass (no compaction is the best outcome)" || no "continue-clean: C3 ($out)"
echo "$out" | grep -qE '^C4 pass STOP token present' && ok "continue-clean: C4 pass" || no "continue-clean: C4 ($out)"
echo "$out" | grep -qE '^SUMMARY pass=4 fail=0 n/a=0 degraded=0$' && ok "continue-clean: summary" || no "continue-clean: summary ($out)"

# ============================================================================================
# False-positive-noise regression (item 1): tool_result, task-notification, peer, /loop
# re-fires, and hook-feedback tags sit between the two block commits. None of them are a
# genuine operator turn (origin.kind != "human"), so C1 must still pass.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/false-positive-noise.jsonl" 2>&1)"
echo "$out" | grep -qE '^C1 pass 2 block commits, 0 operator turns' \
  && ok "false-positive-noise: C1 pass (noise correctly excluded)" || no "false-positive-noise: C1 ($out)"
echo "$out" | grep -qE '^C4 pass' && ok "false-positive-noise: C4 pass" || no "false-positive-noise: C4 ($out)"

# ============================================================================================
# C1 fail — a genuine (origin.kind=human) operator turn lands between two block commits.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/operator-interrupt.jsonl" 2>&1)"
echo "$out" | grep -qE '^C1 fail 2 block commits but 1 of 1 gap' && ok "operator-interrupt: C1 fail" || no "operator-interrupt: C1 ($out)"

# ============================================================================================
# C2 — markdown-wrapped endings, final-paragraph scan (not just the physical last line), and
# a Spanish ¿...? pair anywhere in the final paragraph.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/question-ending.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 fail 2 of 2 final returns end in a question' && ok "question-ending: C2 fail" || no "question-ending: C2 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/question-paragraph.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 fail 2 of 2 final returns end in a question' \
  && ok "question-paragraph: C2 fail (mid-paragraph question + ¿...? both caught)" \
  || no "question-paragraph: C2 ($out)"

# ============================================================================================
# C3 — structural compaction detection only (compact_boundary / isCompactSummary), and the
# "no compaction found" outcome is a pass, not n/a.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-survive" \
  --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
echo "$out" | grep -qE '^C3 pass compaction detected; 1 block commit\(s\) before, 1 after' \
  && ok "compaction-survive: C3 pass" || no "compaction-survive: C3 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-stall" \
  --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
echo "$out" | grep -qE '^C3 fail compaction detected; 1 block commit\(s\) before, 0 after' \
  && ok "compaction-stall: C3 fail" || no "compaction-stall: C3 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-survive" \
  --transcript "$FIX/compaction-structural.jsonl" 2>&1)"
echo "$out" | grep -qE '^C3 (pass|fail) compaction detected' \
  && ok "compaction-structural: isCompactSummary-carrying record alone is detected as compaction" \
  || no "compaction-structural: C3 ($out)"

# ============================================================================================
# C4 — markdown-wrapped STOP token; status disagrees; a block commit lands after STOP;
# research-sdd-status.sh missing/failing/STALE all degrade rather than false-passing.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/stop-wrapped.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 pass STOP token present' \
  && ok "stop-wrapped: C4 pass (bold-wrapped STOP: tolerated)" || no "stop-wrapped: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_NOTSTOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 fail stop_token=present status_next=NOT-STOP' \
  && ok "continue-clean + not-stop status: C4 fail" || no "continue-clean + not-stop status: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue-poststop" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 fail stop_token=present status_next=STOP queue=empty commits_after_stop=1' \
  && ok "commit after STOP: C4 fail" || no "commit after STOP: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STALE" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 degraded research-sdd-status.sh --next reports STALE' \
  && ok "STALE status: C4 degraded (not a false pass)" || no "STALE status: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_FAILING" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 degraded research-sdd-status.sh failed' \
  && ok "failing status script: C4 degraded" || no "failing status script: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$ROOT/no-such-status.sh" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C4 degraded research-sdd-status.sh not found' \
  && ok "missing status script: C4 degraded" || no "missing status script: C4 ($out)"

# ============================================================================================
# Transcript span (item 2): a block commit outside [first_ts, last_ts] degrades C1 and C3,
# reporting the out-of-span count — never a silent false pass or fail.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/out-of-span-repo" \
  --transcript "$FIX/out-of-span.jsonl" 2>&1)"
echo "$out" | grep -qE '^C1 degraded 1 of 2 block commit\(s\) outside transcript span' \
  && ok "out-of-span: C1 degraded" || no "out-of-span: C1 ($out)"
echo "$out" | grep -qE '^C3 degraded 1 of 2 block commit\(s\) outside transcript span' \
  && ok "out-of-span: C3 degraded" || no "out-of-span: C3 ($out)"
echo "$out" | grep -qE '^C2 pass' && ok "out-of-span: C2 unaffected" || no "out-of-span: C2 ($out)"
echo "$out" | grep -qE '^C4 pass' && ok "out-of-span: C4 unaffected" || no "out-of-span: C4 ($out)"

# ============================================================================================
# Block-commit regex (item 8): a preamble before the block ref, a B<n>-B<m> range weighted as
# (m-n+1) blocks, and a retro's trailing parenthetical range citation excluded entirely.
# ============================================================================================
out="$(bash "$SUT" --corpus "$ROOT/block-regex" 2>&1)"
echo "$out" | grep -qE '^C1 n/a 4 block commits in window' \
  && ok "block-regex: 1 (preamble) + 3 (range) + 0 (retro citation excluded) = 4" \
  || no "block-regex: C1 ($out)"

# ============================================================================================
# Degraded states — malformed transcript JSON, and dependencies absent.
# ============================================================================================
printf '{"type":"user","origin":{"kind":"human"},"timestamp":"2026-06-01T00:00:00Z","message":{"role":"user","content":"hi"}}\nnot-json\n' \
  > "$ROOT/malformed.jsonl"
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$ROOT/malformed.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 degraded degraded: transcript did not parse cleanly' \
  && ok "malformed transcript: C2 degraded" || no "malformed transcript: C2 ($out)"
echo "$out" | grep -qE '^C1 degraded 2 block commits in window; degraded:' \
  && ok "malformed transcript: C1 degraded (commit count still reported)" || no "malformed transcript: C1 ($out)"

real_git="$(command -v git)"
real_date="$(command -v date)"
real_sort="$(command -v sort)"
real_grep="$(command -v grep)"
real_mktemp="$(command -v mktemp)"
real_cat="$(command -v cat)"
real_printf="$(command -v printf)"
real_tail="$(command -v tail)"
real_bash="$(command -v bash)"

mkdir -p "$ROOT/bin-nojq"
for pair in "git:$real_git" "date:$real_date" "sort:$real_sort" "grep:$real_grep" \
            "mktemp:$real_mktemp" "cat:$real_cat" "printf:$real_printf" "tail:$real_tail"; do
  name="${pair%%:*}"; target="${pair#*:}"
  [ -n "$target" ] && ln -sf "$target" "$ROOT/bin-nojq/$name"
done
out="$(PATH="$ROOT/bin-nojq" RSDD_STATUS_SCRIPT="$STUB_STOP" \
  "$real_bash" "$SUT" --corpus "$ROOT/continue" --transcript "$FIX/continue-clean.jsonl" 2>&1)"
echo "$out" | grep -qE '^C2 degraded degraded: jq not found in PATH' \
  && ok "jq absent (isolated PATH, git present): C2 degraded" || no "jq absent: C2 ($out)"
echo "$out" | grep -qE '^C1 degraded 2 block commits in window; degraded: jq not found' \
  && ok "jq absent: C1 degraded (commit count still reported)" || no "jq absent: C1 ($out)"

mkdir -p "$ROOT/bin-nogit"
for pair in "date:$real_date" "sort:$real_sort" "grep:$real_grep" "mktemp:$real_mktemp" \
            "cat:$real_cat" "printf:$real_printf" "tail:$real_tail"; do
  name="${pair%%:*}"; target="${pair#*:}"
  [ -n "$target" ] && ln -sf "$target" "$ROOT/bin-nogit/$name"
done
out="$(PATH="$ROOT/bin-nogit" "$real_bash" "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "git absent: exit 3 (degraded)" || no "git absent: exit 3, got $rc"
echo "$out" | grep -qE '^C1 degraded git-not-found$' && ok "git absent: C1 degraded git-not-found" || no "git absent: C1 ($out)"
echo "$out" | grep -qE '^C4 degraded git-not-found$' && ok "git absent: C4 degraded git-not-found" || no "git absent: C4 ($out)"

# A `date` on PATH that cannot parse ISO-8601 with -d (e.g. BSD/macOS date) must degrade
# the whole instrument (exit 3), not silently mis-parse every timestamp as unusable.
mkdir -p "$ROOT/bin-nogitdate"
cat > "$ROOT/bin-nogitdate/date" <<'FAKE_DATE'
#!/usr/bin/env bash
# Synthetic non-GNU `date`: ignores -d and always fails to produce an epoch.
exit 1
FAKE_DATE
chmod +x "$ROOT/bin-nogitdate/date"
for pair in "git:$real_git" "sort:$real_sort" "grep:$real_grep" "mktemp:$real_mktemp" \
            "cat:$real_cat" "printf:$real_printf" "tail:$real_tail"; do
  name="${pair%%:*}"; target="${pair#*:}"
  [ -n "$target" ] && ln -sf "$target" "$ROOT/bin-nogitdate/$name"
done
out="$(PATH="$ROOT/bin-nogitdate" "$real_bash" "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "date -d unsupported: exit 3 (degraded)" || no "date -d unsupported: exit 3, got $rc"
echo "$out" | grep -qE '^C1 degraded date-not-supported$' \
  && ok "date -d unsupported: C1 degraded date-not-supported" || no "date -d unsupported: C1 ($out)"

# ============================================================================================
# Mutation self-test (--prove-teeth): flip one matching seam per criterion, plus the two
# round-2 seams explicitly called out (the operator origin.kind filter and the span check),
# and confirm the assertion above goes red against the exact SUT bytes that would ship each
# broken behavior.
# ============================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  mutant() {
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

  echo "-- teeth-C3: neutralise compaction detection; expect C3 to flip to 'no compaction' pass --"
  m="$(mutant c3 's/"\$is_cx" == "true"/"$is_cx" == "MUTANT_NEVER"/')"
  if grep -qF 'MUTANT_NEVER' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/compaction-survive" \
      --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
    if echo "$mo" | grep -qE '^C3 pass no compaction'; then
      ok "teeth-C3: compaction detection neutralised → C3 falsely reports no compaction"
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

  echo "-- teeth-operator-filter: drop the origin.kind clause; expect the false-positive noise to count as operator input again (item 9) --"
  m="$(mutant operator-filter 's/(\.origin\.kind \/\/ \\"\\")==\\"human\\"/true/')"
  if grep -qF '(.type==\"user\") and (true)' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/false-positive-noise.jsonl" 2>&1)"
    if echo "$mo" | grep -qE '^C1 fail'; then
      ok "teeth-operator-filter: origin.kind clause dropped → task-notification/tool_result noise wrongly counts as operator input again"
    else
      no "teeth-operator-filter: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-operator-filter: mutant build failed (source line not found)"
  fi

  echo "-- teeth-span: neutralise the out-of-span degrade check; expect C1 to fall through to a normal (wrong) verdict --"
  m="$(mutant span 's/"\$oos" -gt 0/"$oos" -gt 999999/g')"
  if [ "$(grep -c '"\$oos" -gt 999999' "$m")" -ge 2 ]; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/out-of-span-repo" \
      --transcript "$FIX/out-of-span.jsonl" 2>&1)"
    if echo "$mo" | grep -qE '^C1 fail 2 block commits but 1 of 1 gap'; then
      ok "teeth-span: span check neutralised → C1 falls through to an unwarranted fail instead of degraded"
    else
      no "teeth-span: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-span: mutant build failed (both source lines not found)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
