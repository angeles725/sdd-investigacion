#!/usr/bin/env bash
# resume-render.test.sh — harness for resume-render.sh (kit issue #1274, slice 2).
#
# The tool renders a Markdown handoff FROM a research-sdd.resume-state/v1 document. Cases pin: every worktree
# field, missing directories, detached HEADs, loose branches, the PR states (ok list / ok empty / null + degraded
# status — an unknown list is never "no open PRs"), nulls rendered as "unknown" (never 0), typed input errors
# (absent, empty, malformed, wrong schema, wrong shape: rc 2), jq missing (DEGRADED rc 3), the self-run mode,
# and that nothing is written. --prove-teeth builds mutants of the SUT via lib/mutant.sh.
#
# Usage: resume-render.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../resume-render.sh"
FX="$HERE/fixtures/resume-render"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — got [$2] want [$3]"; fi; }
has(){ case "$OUT" in *"$2"*) ok "$1" ;; *) no "$1 — output lacks [$2]" ;; esac; }
lacks(){ case "$OUT" in *"$2"*) no "$1 — output has [$2]" ;; *) ok "$1" ;; esac; }
# run <args...>: stdout+stderr in OUT, rc in RC (stdin closed unless the case pipes one).
run(){ OUT="$(timeout 30 bash "$SUT" "$@" 2>&1 </dev/null)"; RC=$?; }

echo "-- resume-render.sh --"
run --json "$FX/state-degraded.json"
eq "1  exit 0" "$RC" 0
has "1a title" "# Resume handoff"
has "1b base ref and short sha" 'Base: `origin/main` @ aaaaaaa'
has "1c remote shown" 'git@example.com:o/kit.git'
has "1d worktree counts" 'dirty 3 · untracked 2 · ahead 4 · behind 1'
has "1e clean primary shows real zeros" 'dirty 0 · untracked 0 · ahead 0 · behind 0'
has "1f missing directory flagged + prunable hint" 'DIRECTORY MISSING (prunable: `git worktree prune`)'
has "1g missing directory counts unknown, not 0" 'DIRECTORY MISSING (prunable: `git worktree prune`) · dirty unknown · untracked unknown · ahead 1'
has "1h detached HEAD" 'detached HEAD @ ddddddd · dirty unknown'
has "1i null ahead/behind unknown" 'ahead unknown · behind unknown'
has "1j loose branches section" '## Loose branches (2)'
has "1k loose branch counts" '`loose/one` @ eeeeeee · ahead 2 · behind 5'
has "1l loose branch null counts" '`loose/two` @ fffffff · ahead unknown · behind unknown'
has "1m not-derived footer" 'no git source'

# 2. PR states
has "2  null prs + degraded status -> unknown with the status" 'PR list unknown: degraded:gh-timeout'
lacks "2a unknown list never reads as no PRs" "No open PRs"
run --json "$FX/state-prs-ok.json"
has "2b ok list rendered" '- #7 `feat/x` OPEN — https://example.com/pr/7'
has "2c no remote configured" 'remote none configured'
has "2d no loose branches message" 'None: every local branch is checked out in a worktree.'
lacks "2e ok list is not unknown" "PR list unknown"
run --json "$FX/state-prs-empty.json"
has "2f ok + empty -> authoritative none" 'No open PRs (gh answered with an empty list).'
has "2g no worktrees" 'None listed.'
jq '.prs_truncated=true' "$FX/state-prs-ok.json" > "$TMP/trunc.json"; run --json "$TMP/trunc.json"
has "2h truncated list is flagged" 'truncated at the gh limit'
jq '.prs_status="skipped"' "$FX/state-prs-ok.json" > "$TMP/incons.json"; run --json "$TMP/incons.json"
has "2i list present but status not ok is not trusted" 'PR list unknown: skipped (inconsistent'
jq 'del(.prs_status)|.prs=null' "$FX/state-prs-ok.json" > "$TMP/nostat.json"; run --json "$TMP/nostat.json"
has "2j missing status is named" 'PR list unknown: prs_status missing'

# 3. typed input errors
run --json "$TMP/absent.json"
eq "3  absent file rc" "$RC" 2; has "3a absent file message" "absent or unreadable"
: > "$TMP/empty.json"; run --json "$TMP/empty.json"
eq "3b empty file rc" "$RC" 2; has "3c empty file message" "empty input"
echo '{not json' > "$TMP/bad.json"; run --json "$TMP/bad.json"
eq "3d malformed rc" "$RC" 2; has "3e malformed message" "malformed JSON"
jq '.schema="research-sdd.resume-state/v0"' "$FX/state-prs-ok.json" > "$TMP/v0.json"; run --json "$TMP/v0.json"
eq "3f wrong schema rc" "$RC" 2; has "3g wrong schema message" "wrong schema"
echo '[]' > "$TMP/arr.json"; run --json "$TMP/arr.json"
eq "3h non-object rc" "$RC" 2
jq 'del(.worktrees)' "$FX/state-prs-ok.json" > "$TMP/nowt.json"; run --json "$TMP/nowt.json"
eq "3i missing worktrees rc" "$RC" 2; has "3j missing worktrees message" "malformed document"
run --bogus
eq "3k unknown arg rc" "$RC" 2
run --json
eq "3l --json without value rc" "$RC" 2
run --json "$FX/state-prs-ok.json" --no-gh
eq "3m --json + forwarded flag rejected rc" "$RC" 2

# 3n. element shapes: rc 2 AND empty stdout (nothing streamed before the failure)
P="$FX/state-prs-ok.json"
jq '.worktrees=[1]' "$P" > "$TMP/e1.json"; jq '.branches=["x"]' "$P" > "$TMP/e2.json"
jq '.prs=["x"]' "$P" > "$TMP/e3.json"; jq '.repo="s"' "$P" > "$TMP/e4.json"
jq '.prs={}' "$P" > "$TMP/e5.json"
for n in 1 2 3 4 5; do
  SO="$(timeout 30 bash "$SUT" --json "$TMP/e$n.json" 2>/dev/null </dev/null)"; RC=$?
  eq "3n$n bad element shape e$n rc 2" "$RC" 2; eq "3n$n stdout empty" "$SO" ""
done
run --json "$TMP/e1.json"; has "3o typed message" "malformed document"
jq '.worktrees[0]|=del(.exists)' "$FX/state-degraded.json" > "$TMP/noex.json"; run --json "$TMP/noex.json"
has "3p missing exists renders unknown, not present" 'existence unknown · dirty 0'
# shape-valid but the render itself dies (object where a string is expected): rc 2, stdout empty
REAL_JQ="$(command -v jq)"; mkdir -p "$TMP/badjq"
printf '#!/bin/sh\ncase "$2" in *"def cnt"*) echo "# Resume handoff"; echo "jq: error: boom" >&2; exit 5 ;; esac\nexec "%s" "$@"\n' "$REAL_JQ" > "$TMP/badjq/jq"
chmod +x "$TMP/badjq/jq"; cp "$P" "$TMP/e6.json"
SO="$(PATH="$TMP/badjq:$PATH" timeout 30 bash "$SUT" --json "$TMP/e6.json" 2>"$TMP/e6.err" </dev/null)"; RC=$?
eq "3q render failure rc" "$RC" 2; eq "3q render failure stdout empty" "$SO" ""
eq "3q typed message" "$(head -c 28 "$TMP/e6.err")" "resume-render.sh: malformed "

# 4. stdin
OUT="$(timeout 30 bash "$SUT" --json - 2>&1 <"$FX/state-prs-ok.json")"; RC=$?
eq "4  stdin render rc" "$RC" 0; has "4a stdin render output" '- #7'
OUT="$(printf '' | timeout 30 bash "$SUT" --json - 2>&1)"; RC=$?
eq "4b empty stdin rc" "$RC" 2; has "4c empty stdin message" "empty input"

# 5. jq missing -> DEGRADED rc 3
mkdir -p "$TMP/nojq"
for t in bash sh env cat sed mktemp rm dirname; do ln -sf "$(command -v "$t")" "$TMP/nojq/$t"; done
OUT="$(PATH="$TMP/nojq" "$(command -v bash)" "$SUT" --json "$FX/state-prs-ok.json" 2>&1 </dev/null)"; RC=$?
eq "5  jq missing rc 3" "$RC" 3; has "5a typed DEGRADED line" "DEGRADED: jq not found"

# 6. self-run mode against a throwaway repo (hermetic: no gh, no network)
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
R="$TMP/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b main . && echo a > a && git add a && G commit -q -m c1 && echo u > u ) >/dev/null 2>&1
run --cwd "$R" --no-gh
eq "6  self-run rc" "$RC" 0
has "6a self-run shows the repo" "$R"
has "6b --no-gh surfaces as unknown, not none" 'PR list unknown: skipped'
has "6c untracked file counted" 'untracked 1'
run --cwd "$TMP/not-a-dir" --no-gh
eq "6d resume-state failure -> rc 2" "$RC" 2; has "6e failure message" "resume-state.sh failed"

# 7. read-only: rendering a fixture writes nothing next to it
before="$(find "$FX" -type f | sort | xargs sha1sum 2>/dev/null)"
run --json "$FX/state-degraded.json"
after="$(find "$FX" -type f | sort | xargs sha1sum 2>/dev/null)"
eq "7  fixtures untouched" "$after" "$before"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: resume-render mutants --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MUT="$(mktemp -d)"; trap 'rm -rf "$TMP" "$MUT"' EXIT
  mk(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  D="$FX/state-degraded.json"
  mk unknown-as-none "$SUT" "$MUT/m1.sh" 's/if \.prs == null or (\.prs|type) != "array" or \.prs_status != "ok" then/if false then/' \
    && tt unknown-as-none 0 0 "$MUT/m1.sh" --good-has 'PR list unknown: degraded:gh-timeout' --bad-lacks 'PR list unknown' -- bash @SUT@ --json "$D"
  mk null-as-zero "$SUT" "$MUT/m2.sh" 's/if v == null then l + " unknown"/if v == null then l + " 0"/' \
    && tt null-as-zero 0 0 "$MUT/m2.sh" --good-has "ahead unknown" --bad-lacks "ahead unknown" -- bash @SUT@ --json "$D"
  mk no-schema-check "$SUT" "$MUT/m3.sh" 's/^\[ "\$got" = "\$SCHEMA" \] ||.*$/:/' \
    && tt no-schema-check 2 0 "$MUT/m3.sh" --good-has 'wrong schema' -- bash @SUT@ --json "$TMP/v0.json"
  mk no-shape-check "$SUT" "$MUT/m4.sh" 's/^  || { echo "resume-render.sh: malformed document.*$/  || true/' \
    && tt no-shape-check 2 0 "$MUT/m4.sh" --good-has 'malformed document' --bad-lacks 'malformed document' -- bash @SUT@ --json "$TMP/nowt.json"
  mk no-empty-guard "$SUT" "$MUT/m5.sh" 's/^\[ -s "\$tmp" \] ||.*$/:/' \
    && tt no-empty-guard 2 2 "$MUT/m5.sh" --good-has 'empty input' --bad-lacks 'empty input' -- bash @SUT@ --json "$TMP/empty.json"
  mk no-jq-probe "$SUT" "$MUT/m6.sh" 's/^command -v jq >\/dev\/null 2>&1 ||.*$/:/' \
    && tt no-jq-probe 3 2 "$MUT/m6.sh" --good-has 'DEGRADED: jq' --bad-lacks 'DEGRADED' -- env PATH="$TMP/nojq" "$(command -v bash)" @SUT@ --json "$FX/state-prs-ok.json"
  mk streams-directly "$SUT" "$MUT/m11.sh" 's/^\(.*\)'"'"' "\$tmp" > "\$out" 2> "\$out.err"; rc=\$?$/\1'"'"' "$tmp" 2> "$out.err"; rc=$?/' \
    && tt streams-directly 2 2 "$MUT/m11.sh" --good-has 'malformed element' --bad-has 'Resume handoff' -- env PATH="$TMP/badjq:$PATH" bash @SUT@ --json "$TMP/e6.json"
  mk exists-missing-as-present "$SUT" "$MUT/m12.sh" 's/if \.exists != false and \.exists != true then/if false then/' \
    && tt exists-missing-as-present 0 0 "$MUT/m12.sh" --good-has 'existence unknown' --bad-lacks 'existence unknown' -- bash @SUT@ --json "$TMP/noex.json"
  mk empty-list-wording "$SUT" "$MUT/m7.sh" 's/elif (\.prs|length) == 0 then "No open PRs (gh answered with an empty list)\."/elif (.prs|length) == 0 then "No open PRs"/' \
    && tt empty-list-wording 0 0 "$MUT/m7.sh" --good-has 'gh answered with an empty list' --bad-lacks 'gh answered' -- bash @SUT@ --json "$FX/state-prs-empty.json"
  mk missing-dir-hidden "$SUT" "$MUT/m8.sh" 's/if \.exists == false/if false/' \
    && tt missing-dir-hidden 0 0 "$MUT/m8.sh" --good-has 'DIRECTORY MISSING' --bad-lacks 'DIRECTORY MISSING' -- bash @SUT@ --json "$D"
  mk truncation-hidden "$SUT" "$MUT/m9.sh" 's/if \.prs_truncated == true then/if false then/' \
    && tt truncation-hidden 0 0 "$MUT/m9.sh" --good-has 'truncated at the gh limit' --bad-lacks 'truncated at the gh limit' -- bash @SUT@ --json "$TMP/trunc.json"
  mk status-ignored "$SUT" "$MUT/m10.sh" 's/ or \.prs_status != "ok" then/ then/' \
    && tt status-ignored 0 0 "$MUT/m10.sh" --good-has 'PR list unknown: skipped' --bad-lacks 'PR list unknown' -- bash @SUT@ --json "$TMP/incons.json"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
