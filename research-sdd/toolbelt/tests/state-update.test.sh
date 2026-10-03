#!/usr/bin/env bash
# state-update.test.sh — harness for state-update.sh (kit issue #1284).
#
# The tool runs verify-state.sh, parses the recomputed values out of its FAIL/WARN lines and prints a
# unified diff of the owned envelope counters + the Stop-control prose number. Cases pin: the exit-code contract
# (0 / 1 / 2 / 3), the diff content, that hand-set lines are never in the diff, that the target is never
# written, multi-focus labelling, the envelope-less SKIP, the §7 absent / nothing-checked distinction,
# idempotence (apply the diff, re-run, rc 0) and the DEGRADED paths. --prove-teeth builds mutants of the
# SUT with lib/mutant.sh and requires each to flip a specific assertion.
#
# Usage: state-update.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/state-update.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# run <args...>: stdout+stderr in OUT, stdout alone in SOUT, exit code in RC.
run(){ SOUT="$(timeout 60 bash "$SUT" "$@" 2>"$TMP/stderr")"; RC=$?; OUT="$SOUT"$'\n'"$(cat "$TMP/stderr")"; }
has(){ grep -qF -- "$1" <<<"$OUT"; }
expect(){ local label="$1" want="$2"; shift 2; local miss=""
  [ "$RC" = "$want" ] || miss="rc=$RC(want $want) "
  for n in "$@"; do has "$n" || miss="${miss}[missing: $n] "; done
  if [ -z "$miss" ]; then ok "$label"; else no "$label — $miss| out: $(printf '%s' "$OUT" | tr '\n' '~' | cut -c1-400)"; fi; }
lacks(){ local label="$1"; shift; local hit=""
  for n in "$@"; do has "$n" && hit="${hit}[unexpected: $n] "; done
  if [ -z "$hit" ]; then ok "$label"; else no "$label — $hit| out: $(printf '%s' "$OUT" | tr '\n' '~' | cut -c1-400)"; fi; }

# state <file> <covered> <io> <stop-prose-n> [extra envelope line]: a 2-gap backlog (both pending).
# Truth for a corpus with two block files: covered_blocks=2 investigable_open=2 known_gaps=2 gaps_closed=0.
state(){ local f="$1" cb="$2" io="$3" sp="$4" extra="${5:-}"
  mkdir -p "$(dirname "$f")"
  { printf '# Research state\n\n> intro blockquote\n\n<!-- research-state.v1 -->\nschema: research-state.v1\n'
    printf 'covered_blocks: %s\ngaps_closed: 0\nknown_gaps: 2\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n' "$cb" "$io"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    printf '<!-- /research-state.v1 -->\n\n## Stop control\n\n- **Open gaps — read-only investigable**: %s\n- hand note: keep this line\n\n' "$sp"
    printf '## Gap-backlog\n\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| high | Gap one | x | pending |\n| low | Gap two | x | pending |\n'
  } > "$f"; }
blocks(){ local d="$1"; shift; mkdir -p "$d"; for n in "$@"; do printf '# block\n' > "$d/$n"; done; }
snap(){ (cd "$1" && find . -type f -exec sha1sum {} + | sort; find . | sort) 2>/dev/null; }

echo "-- state-update.sh --"

# 1. usage / absent-input (rc 2).
run;                     expect "1a no args exits 2 with usage" 2 "usage: state-update.sh"
run "$TMP/does-not-exist"; expect "1b nonexistent dir exits 2" 2 "usage: state-update.sh"
mkdir -p "$TMP/empty"; run "$TMP/empty"; expect "1c dir without a state file exits 2 and says so" 2 "no RESEARCH-STATE*.md"
run "$TMP/empty" extra;  expect "1d extra argument exits 2" 2 "usage: state-update.sh"

# 2. consistent corpus: rc 0, no diff on stdout, the summary proves it looked.
d="$TMP/clean"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2
run "$d"; expect "2  consistent envelope exits 0 and reports checked=1 changed=0" 0 "checked=1 skipped=0 changed=0"
[ -z "$SOUT" ] && ok "2b consistent corpus prints no diff on stdout" || no "2b unexpected stdout: $SOUT"

# 3. drift: every owned field shows in the diff, exit 1.
d="$TMP/drift"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 1 1 'undocumented_findings: 7'
run "$d"; expect "3  drifted counters exit 1 with a proposed diff" 1 "--- a/RESEARCH-STATE.md" "+++ b/RESEARCH-STATE.md" "changed=1"
has '-covered_blocks: 1'              && has '+covered_blocks: 2'              && ok "3b covered_blocks 1 -> 2 proposed" || no "3b covered_blocks hunk missing"
has '-investigable_open: 1'           && has '+investigable_open: 2'           && ok "3c investigable_open 1 -> 2 proposed" || no "3c investigable_open hunk missing"
has 'investigable**: 1' && has 'investigable**: 2'                             && ok "3d stop-control prose number 1 -> 2 proposed" || no "3d stop-control hunk missing"
lacks "3e hand-set undocumented_findings and prose notes are not in the diff" '-undocumented_findings' '+undocumented_findings' '-- hand note' '+- hand note'

# 4. propose-never-apply: the target tree is byte- and name-identical after a drifted run.
d="$TMP/ro"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 1 1
before="$(snap "$d")"; run "$d"; after="$(snap "$d")"
[ "$RC" = 1 ] && [ "$before" = "$after" ] && ok "4  target tree unchanged after a proposing run (no write, no stray temp file)" || no "4  target modified or rc=$RC"

# 5. idempotence: apply the diff to a copy, the re-run proposes nothing.
d="$TMP/idem"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 1 1
run "$d"; printf '%s\n' "$SOUT" > "$TMP/idem.patch"
if command -v patch >/dev/null 2>&1; then
  (cd "$d" && patch -s -p1 < "$TMP/idem.patch" >/dev/null 2>&1); run "$d"
  expect "5  after applying the proposed patch a re-run exits 0" 0 "changed=0"
else no "5  patch(1) not available — idempotence untested"; fi

# 6. multi-focus: both drifted state files appear, labelled by their relative path; clean sibling absent.
d="$TMP/multi"; blocks "$d" alpha-block1.md alpha-block2.md; blocks "$d/sub" beta-block1.md beta-block2.md
state "$d/RESEARCH-STATE-alpha.md" 1 2 2; state "$d/sub/RESEARCH-STATE-beta.md" 2 2 2; state "$d/RESEARCH-STATE-gamma.md" 0 2 2
blocks "$d" gamma-block1.md gamma-block2.md
run "$d"; expect "6  multi-focus: drifted focus proposed, relative labels, three files checked" 1 "--- a/RESEARCH-STATE-alpha.md" "--- a/RESEARCH-STATE-gamma.md" "checked=3" "changed=2"
lacks "6b clean nested focus (sub/RESEARCH-STATE-beta.md) is not in the diff" "a/sub/RESEARCH-STATE-beta.md"

# 7. envelope-less state: SKIP is named, and a corpus where NOTHING could be checked is DEGRADED, not a pass.
d="$TMP/noenv"; blocks "$d" proj-block1.md; printf '# state without an envelope\n\n## Gap-backlog\n' > "$d/RESEARCH-STATE.md"
run "$d"; expect "7  only envelope-less states: SKIP named, exit 3 (nothing examined is not 'no change')" 3 "SKIP RESEARCH-STATE.md" "DEGRADED" "checked=0 skipped=1"
d="$TMP/mixed"; blocks "$d" a-block1.md a-block2.md; state "$d/RESEARCH-STATE-a.md" 2 2 2; printf '# none\n' > "$d/RESEARCH-STATE-b.md"
run "$d"; expect "7b mixed: the envelope-less file is skipped, the other still checked, exit 0" 0 "SKIP RESEARCH-STATE-b.md" "checked=1 skipped=1"

# 8. absent Stop-control prose: no prose hunk, no error.
d="$TMP/noprose"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 2 2
sed -i '/read-only investigable/d' "$d/RESEARCH-STATE.md"
run "$d"; expect "8  state without the stop-control line still proposes the envelope fix" 1 "+covered_blocks: 2"
lacks "8b no stop-control hunk invented" "read-only investigable"

# 9. stop-control forms: bold-wrapped value keeps its markers; a number elsewhere on the line is not touched.
d="$TMP/forms"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 9
sed -i 's/investigable\*\*: 9/investigable**: **9** (G74 list, hits 0)/' "$d/RESEARCH-STATE.md"
run "$d"; expect "9  bold-wrapped value and trailing numbers: only the value changes" 1 '+- **Open gaps — read-only investigable**: **2** (G74 list, hits 0)'

# 10. DEGRADED: verify-state stubs — failing (rc 3), missing, and one that prints no section for the file.
d="$TMP/deg"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 1 1
printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$TMP/stub-fail.sh"
STATE_UPDATE_VERIFY="$TMP/stub-fail.sh" run "$d"; expect "10 failing verify-state => DEGRADED naming the failure, exit 3" 3 "DEGRADED" "verify-state exited 3" "boom"
printf '#!/usr/bin/env bash\necho "== verify-state: SOMETHING-ELSE.md (target: x) =="\nexit 0\n' > "$TMP/stub-nosection.sh"
STATE_UPDATE_VERIFY="$TMP/stub-nosection.sh" run "$d"; expect "10b verify-state said nothing about the file => DEGRADED, exit 3 (no false 'no change')" 3 "printed no section for it"
STATE_UPDATE_VERIFY="$TMP/missing-verify.sh" run "$d"; expect "10c missing verify-state => DEGRADED, exit 3" 3 "DEGRADED — cannot find"
printf '#!/usr/bin/env bash\necho "== verify-state: RESEARCH-STATE.md (target: x) =="\necho boom >&2\nexit 3\n' > "$TMP/stub-fail2.sh"
STATE_UPDATE_VERIFY="$TMP/stub-fail2.sh" run "$d"; expect "10d verify-state exit 3 with a plausible section is still DEGRADED (rc is a verdict gate)" 3 "verify-state exited 3"
d="$TMP/dup"; blocks "$d/x" proj-block1.md proj-block2.md; blocks "$d/y" proj-block1.md proj-block2.md; state "$d/x/RESEARCH-STATE.md" 1 1 1; state "$d/y/RESEARCH-STATE.md" 1 1 1
run "$d"; expect "10e two state files sharing a basename => DEGRADED (verify-state sections are ambiguous)" 3 "share a basename"

# 11. DEGRADED outranks a proposed change: one file verify-state never mentions + one drifted file => exit 3, diff printed.
d="$TMP/prec"; blocks "$d" a-block1.md a-block2.md; state "$d/RESEARCH-STATE-a.md" 1 2 2; state "$d/RESEARCH-STATE-b.md" 2 2 2
cat > "$TMP/stub-half.sh" <<EOF
#!/usr/bin/env bash
bash "$TOOLBELT/verify-state.sh" "\$@" | awk '/^== verify-state: RESEARCH-STATE-b.md/{skip=1; next} /^== verify-state:/{skip=0} !skip'
EOF
STATE_UPDATE_VERIFY="$TMP/stub-half.sh" run "$d"; expect "11 one unmentioned file + one drifted file => exit 3 and the good diff is still printed" 3 "--- a/RESEARCH-STATE-a.md" "degraded=1" "changed=1"

# 12. non-block *.md siblings are not counted as blocks (verify-state's discriminator decides).
d="$TMP/names"; blocks "$d" proj-block1.md proj-block2.md notes.md README.md; state "$d/RESEARCH-STATE.md" 2 2 2
run "$d"; expect "12 non-block siblings are not counted as blocks" 0 "changed=0"

# 13. a LONE nested RESEARCH-STATE.md (the layout of most fleet targets: <target>/corpus/RESEARCH-STATE.md).
d="$TMP/nested"; blocks "$d/corpus" proj-block1.md proj-block2.md; state "$d/corpus/RESEARCH-STATE.md" 1 2 2
run "$d"; expect "13 lone nested root state is examined and its drift proposed" 1 "--- a/corpus/RESEARCH-STATE.md" "+covered_blocks: 2" "degraded=0"

# 14. hand-set envelope lines keep their text AND position (a re-render would move method: below the counters).
d="$TMP/method"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 2 2; sed -i '/<!-- research-state.v1 -->/a method: document-cycle' "$d/RESEARCH-STATE.md"
run "$d"; expect "14 drifted counter proposed, hand-set method: line absent from the diff" 1 "+covered_blocks: 2"
lacks "14b method: is untouched by the proposal" "-method:" "+method:"

# 15. known_gaps / gaps_closed are NOT owned: verify-state only checks their declared identity. A declared
#     value that disagrees with the backlog table is never proposed.
d="$TMP/kg"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2; sed -i 's/^known_gaps: 2/known_gaps: 9/; s/^gaps_closed: 0/gaps_closed: 7/' "$d/RESEARCH-STATE.md"
run "$d"; expect "15 declared known_gaps/gaps_closed that disagree are not proposed" 0 "changed=0"
lacks "15b no known_gaps / gaps_closed hunk" "-known_gaps" "+known_gaps" "-gaps_closed" "+gaps_closed"

# 16. shared-global focus with no attributed B<n> ids: verify-state says INFO unverifiable, so a declared
#     covered_blocks is never rewritten (a seeder-style 0 would be "could not look", not a count).
d="$TMP/sg"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 8 2 2 'block_scope: shared-global'
run "$d"; expect "16 shared-global with no attributed ids: covered_blocks=8 is left alone" 0 "changed=0"
lacks "16b no covered_blocks hunk" "covered_blocks"

# 17. verify-state FAIL lines this tool does not own are COUNTED, not hidden: rc stays 0 but the summary says so.
d="$TMP/unp"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2; sed -i 's/^| high | Gap one | x | pending |/| bogus | Gap one | x | pending |/' "$d/RESEARCH-STATE.md"
run "$d"; expect "17 an unparseable backlog is surfaced as unproposed>=1, nothing invented" 0 "unproposed=1" "not recomputable counters"
lacks "17b no diff for an unparseable backlog" "--- a/"

# 18. the remaining owned fields, each driven by its own verify-state message form.
d="$TMP/blk"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2
printf '\n## Blocked gaps\n\n- Gap X — needs: vendor data\n- Gap Y — needs: operator access\n' >> "$d/RESEARCH-STATE.md"
run "$d"; expect "18a blocked_open 0 -> 2 (CHECK C) proposed" 1 "-blocked_open: 0" "+blocked_open: 2"
d="$TMP/def"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2
printf '| deferred | Gap Z | x | parked |\n' >> "$d/RESEARCH-STATE.md"
run "$d"; expect "18b deferred_open 0 -> 1 (CHECK F) proposed" 1 "-deferred_open: 0" "+deferred_open: 1"
d="$TMP/defmiss"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2; sed -i '/^deferred_open:/d' "$d/RESEARCH-STATE.md"
printf '| deferred | Gap Z | x | parked |\n' >> "$d/RESEARCH-STATE.md"
run "$d"; expect "18c deferred_open absent while a deferred row exists: line appended inside the fence" 1 "+deferred_open: 1"
d="$TMP/req"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2
sed -i 's/^| low | Gap two | x | pending |/| low | Gap two | x | requires-execution |/; s/^investigable_open: 2/investigable_open: 1/' "$d/RESEARCH-STATE.md"
sed -i 's/investigable\*\*: 2/investigable**: 1/' "$d/RESEARCH-STATE.md"
run "$d"; expect "18d requires_execution_open 0 -> 1 (CHECK E) proposed" 1 "-requires_execution_open: 0" "+requires_execution_open: 1"

d="$TMP/reqwarn"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2
sed -i 's/^| low | Gap two | x | pending |/| low | Gap two | x | requires-execution |/; s/^investigable_open: 2/investigable_open: 1/; s/^requires_execution_open: 0/requires_execution_open: 5/; s/investigable\*\*: 2/investigable**: 1/' "$d/RESEARCH-STATE.md"
run "$d"; expect "18e requires_execution_open 5 -> 1 (CHECK E mirror WARN form) proposed" 1 "-requires_execution_open: 5" "+requires_execution_open: 1"

# 19. a legacy envelope without deferred_open and no deferred row: nothing is added (verify-state is silent).
d="$TMP/legacy"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2; sed -i '/^deferred_open:/d' "$d/RESEARCH-STATE.md"
run "$d"; expect "19 consistent legacy envelope (no deferred_open) proposes nothing" 0 "changed=0"

# 20. CRLF envelope: the substituted value keeps the line ending.
d="$TMP/crlf"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 2 2; sed -i 's/$/\r/' "$d/RESEARCH-STATE.md"
run "$d"; PROP="$(printf '%s' "$SOUT" | grep -c '^+covered_blocks: 2'$'\r''$')"
[ "$RC" = 1 ] && [ "$PROP" = 1 ] && ok "20 CRLF envelope: proposed line keeps its CR" || no "20 CRLF line ending lost (rc=$RC, matches=$PROP)"

# 21. un-suffixed root beside a focus sibling, no FOCUSES.md prefix: verify-state counts the corpus-wide total
#     for it, which is not the focus's number — covered_blocks is withheld (NOTE), the sibling is still checked.
d="$TMP/rootcw"; blocks "$d" proj-block1.md proj-block2.md x-block1.md x-block2.md
state "$d/RESEARCH-STATE.md" 1 2 2; state "$d/RESEARCH-STATE-x.md" 2 2 2
run "$d"; expect "21 root of a multi-state corpus: corpus-wide covered_blocks withheld, NOTE names it, and it is COUNTED (#1534)" 0 "changed=0" "covered_blocks withheld" "unproposed=1"
lacks "21b no covered_blocks hunk for the root" "-covered_blocks" "+covered_blocks"

# 22. verify-state flags a stale stop-control number but no rewritable line exists: counted, never dropped.
d="$TMP/prosegone"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 2 2 2; sed -i '/read-only investigable/d' "$d/RESEARCH-STATE.md"
printf '#!/usr/bin/env bash\necho "== verify-state: RESEARCH-STATE.md (target: x) =="\necho "   FAIL   stop-control prose '"'"'read-only-investigable: 1'"'"' but backlog derives 2 investigable gap(s) — refresh"\nexit 1\n' > "$TMP/stub-prose.sh"
STATE_UPDATE_VERIFY="$TMP/stub-prose.sh" run "$d"; expect "22 unrewritable stop-control prose => NOTE and unproposed=1, no diff" 0 "unproposed=1" "no rewritable"
lacks "22b no diff hunk" "--- a/"

# 23. the state-file listing helper fails: DEGRADED (never "no state files"), exit 3.
mkdir -p "$TMP/hf/lib"; cp "$SUT" "$TMP/hf/"; cp "$TOOLBELT/verify-state.sh" "$TOOLBELT/check-gap-drift.sh" "$TMP/hf/" 2>/dev/null; cp "$TOOLBELT"/lib/*.sh "$TMP/hf/lib/"
printf 'list_state_files() { echo "boom" >&2; return 1; }\n' > "$TMP/hf/lib/state-files.sh"
OUT="$(bash "$TMP/hf/state-update.sh" "$TMP/clean" 2>&1)"; RC=$?
[ "$RC" = 3 ] && grep -qF "could not enumerate state files" <<<"$OUT" && ok "23 failing listing helper => DEGRADED exit 3" || no "23 helper failure masked (rc=$RC): $OUT"

# 24. the summary is ALWAYS emitted and is the LAST stderr line, on every exit path.
last_is_summary(){ local l; l="$(tail -n 1 "$TMP/stderr")"
  [[ "$l" =~ ^state-update:\ checked=[0-9]+\ skipped=[0-9]+\ changed=[0-9]+\ degraded=[0-9]+\ unproposed=[0-9]+\  ]]; }
for spec in "usage:" "absent:$TMP/empty" "clean:$TMP/clean" "drift:$TMP/drift" "noenv:$TMP/noenv" "dup:$TMP/dup"; do
  n="${spec%%:*}"; a="${spec#*:}"; if [ -n "$a" ]; then run "$a"; else run; fi
  last_is_summary && ok "24 summary is the last stderr line ($n, rc=$RC)" || no "24 summary missing/not last ($n): $(tail -n 2 "$TMP/stderr" | tr '\n' '~')"
done
STATE_UPDATE_VERIFY="$TMP/stub-fail.sh" run "$TMP/deg"; last_is_summary && ok "24 summary last on a verify-state failure (rc=$RC)" || no "24 summary not last on verify failure"
OUT="$(bash "$TMP/hf/state-update.sh" "$TMP/clean" 2>&1 >/dev/null)"; grep -q 'checked=' <<<"$OUT" && ok "24 summary emitted on the listing-failure path" || no "24 no summary on listing failure"

# 25. (#1534) a required tool missing is a typed DEGRADED, cmp included; a diff/cmp that errors is never read
#     as "no change" or as an empty diff.
mkdir -p "$TMP/nocmp"; for _t in dirname basename grep sort uniq tr head mktemp awk diff rm cat sed find; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$TMP/nocmp/$_t"; done
SOUT="$(PATH="$TMP/nocmp" "$BASH" "$SUT" "$TMP/drift" 2>"$TMP/stderr")"; RC=$?; OUT="$SOUT"$'\n'"$(cat "$TMP/stderr")"
expect "25a missing cmp => DEGRADED naming the tool, exit 3" 3 "required tool 'cmp' not found"
mkdir -p "$TMP/baddiff"; printf '#!/bin/sh\necho diffboom >&2\nexit 2\n' > "$TMP/baddiff/diff"; chmod +x "$TMP/baddiff/diff"
PATH="$TMP/baddiff:$PATH" run "$TMP/drift"; expect "25b diff exiting 2 => DEGRADED (never a silent empty proposal), exit 3" 3 "diff failed (rc=2)" "changed=0 degraded=1 unproposed="
mkdir -p "$TMP/badcmp"; printf '#!/bin/sh\nexit 2\n' > "$TMP/badcmp/cmp"; chmod +x "$TMP/badcmp/cmp"
PATH="$TMP/badcmp:$PATH" run "$TMP/drift"; expect "25c cmp exiting 2 => DEGRADED, exit 3" 3 "cmp failed (rc=2)" "changed=0 degraded=1 unproposed="
mkdir -p "$TMP/diff0"; printf '#!/bin/sh\nexit 0\n' > "$TMP/diff0/diff"; chmod +x "$TMP/diff0/diff"
PATH="$TMP/diff0:$PATH" run "$TMP/drift"; expect "25d diff exiting 0 while cmp said differ => typed DEGRADED, not an empty proposal" 3 "diff failed (rc=0)" "changed=0 degraded=1 unproposed="

# 26. (#1534) the shared-global detector must see a TAB-indented block_scope line (grep ERE: \t inside [] is not a tab).
#     verify-state is stubbed to flag covered_blocks on the un-suffixed root of a 2-state corpus; because the root
#     IS shared-global the #906 withholding must NOT apply and the value is proposed.
d="$TMP/sgtab"; blocks "$d" proj-block1.md proj-block2.md x-block1.md x-block2.md
state "$d/RESEARCH-STATE.md" 1 2 2 $'\tblock_scope: shared-global'; state "$d/RESEARCH-STATE-x.md" 2 2 2
printf '#!/usr/bin/env bash\necho "== verify-state: RESEARCH-STATE.md (target: x) =="\necho "   FAIL   envelope covered_blocks=1 != 4 attributed block(s) under shared-global"\necho "== verify-state: RESEARCH-STATE-x.md (target: x) =="\nexit 1\n' > "$TMP/stub-sg.sh"
STATE_UPDATE_VERIFY="$TMP/stub-sg.sh" run "$d"; expect "26 tab-indented shared-global root: covered_blocks proposed, not withheld" 1 "+covered_blocks: 4"
lacks "26b no withholding NOTE for a shared-global root" "covered_blocks withheld"

# --- mutation controls ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: state-update.sh mutants --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MUT="$TMP/mut"; mkdir -p "$MUT/lib"
  cp "$TOOLBELT/verify-state.sh" "$TOOLBELT/check-gap-drift.sh" "$MUT/" 2>/dev/null; cp "$TOOLBELT"/lib/*.sh "$MUT/lib/" 2>/dev/null
  # tt <label> <sed-expr> <fixture> <good rc> <bad rc> [mutant_tooth options]: the mutant is a copy of the SUT
  # placed beside copies of the real helpers, never in the live tree; mutant_tooth requires the original to
  # exit GOOD and the mutant to exit BAD (a crashing mutant is THEATER, not teeth).
  tt(){ local label="$1" expr="$2" fx="$3" grc="$4" brc="$5"; shift 5
    local m="$MUT/state-update.sh"
    if ! mutant_chain "$label" "$SUT" "$m" "$expr"; then fail=$((fail+1)); return; fi
    if mutant_tooth "$label" "$grc" "$brc" "$m" "$@" -- bash @SUT@ "$fx"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

  tt exit-code-on-change   's/^\[ "\$changed" -eq 0 \] || exit 1$/true/' "$TMP/drift" 1 0
  tt skip-envelope-less    '/SU-NO-ENVELOPE/s/^  if .*; then/  if false; then/' "$TMP/mixed" 0 0 --bad-has 'checked=2'
  tt nothing-checked-gate  's/^if \[ "\$checked" -eq 0 \]; then/if false; then/' "$TMP/noenv" 3 0
  STATE_UPDATE_VERIFY="$TMP/stub-half.sh" tt degraded-precedence '/SU-DEGRADED-EXIT/s/^if .*; fi/true/' "$TMP/prec" 3 1
  tt absent-state-rc       's/under \$target" >&2; exit 2$/under $target" >\&2; exit 0/' "$TMP/empty" 2 0
  STATE_UPDATE_VERIFY="$TMP/stub-fail2.sh" tt verify-rc-gate '/^if \[ "\$vrc" -ge 2 \]; then/s/.*/if false; then/' "$TMP/deg" 3 0
  STATE_UPDATE_VERIFY="$TMP/stub-nosection.sh" tt absent-section-guard '/SU-ABSENT-SECTION/s/^  if .*; then/  if false; then/' "$TMP/deg" 3 0
  tt prose-rewrite         's/^    prose != "" \&\& !pdone/    0 \&\& !pdone/' "$TMP/forms" 1 0
  tt field-covered         's/kv\[1\]=="covered_blocks" || //' "$TMP/drift" 1 1 --bad-lacks '[+]covered_blocks: 2'
  tt field-blocked         's/kv\[1\]=="blocked_open" || //' "$TMP/blk" 1 0
  tt field-deferred        's/ || kv\[1\]=="deferred_open") {/) {/' "$TMP/def" 1 0
  tt field-req-fail        's/$3 == "requires_execution_open=0"/$3 == "never"/' "$TMP/req" 1 0
  tt field-req-warn        's/kv\[1\]=="requires_execution_open" || //' "$TMP/reqwarn" 1 0
  tt unproposed-count      's/^    if (\$1 == "FAIL") print "UNPROPOSED\\t" f/    if (0) print "UNPROPOSED\\t" f/' "$TMP/unp" 0 0 --good-has 'not recomputable counters' --bad-lacks 'not recomputable counters'
  tt append-missing-key    's/if (!(order\[i\] in seen)) print order\[i\] ": " nv\[order\[i\]\]/if (0) print order[i]/' "$TMP/defmiss" 1 0
  tt prose-extract         's/sub(\/^backlog derives \/, "", s)/sub(\/^backlog derives \/, "9", s)/' "$TMP/forms" 1 1 --good-has '[*][*]2[*][*] [(]G74' --bad-lacks '[*][*]2[*][*] [(]G74'
  tt crlf-preserve         's/cr=(\$0 ~ \/\\r\$\/) ? "\\r" : ""/cr=""/' "$TMP/crlf" 1 1 --good-has $'[+]covered_blocks: 2\r' --bad-lacks $'[+]covered_blocks: 2\r'
  tt root-corpus-wide      's/\[ "\${#states\[@\]}" -gt 1 \] \&\& \[ -z "\$(derive_focus_prefix "\$s")" \]/false \&\& [ -z "$(derive_focus_prefix "$s")" ]/' "$TMP/rootcw" 0 1 --bad-has '[+]covered_blocks: 4'
  STATE_UPDATE_VERIFY="$TMP/stub-prose.sh" tt prose-unmatched-count '/SU-PROSE-UNMATCHED/,/^  fi$/s/unproposed=\$((unproposed+1))/true/' "$TMP/prosegone" 0 0 --good-has 'unproposed=1' --bad-lacks 'unproposed=1'
  tt summary-trap          's/^trap _summary EXIT$/trap : EXIT/' "$TMP/empty" 2 2 --good-has 'checked=' --bad-lacks 'checked='
  tt dup-basename          's/^if \[ -n "\$dups" \]; then/if false; then/' "$TMP/dup" 3 1
  # (#1534) withheld-counted (case 21), cmp-probe (25a), diff-rc-gate (25b, 25d), cmp-rc-gate (25c), sg-tab-class (26): each mutant removes one guard and its named case must notice.
  tt withheld-counted      '/SU-WITHHELD-COUNTED/d' "$TMP/rootcw" 0 0 --good-has 'unproposed=1' --bad-lacks 'unproposed=1'
  STATE_UPDATE_VERIFY="$TMP/stub-sg.sh" tt sg-tab-class 's/\^\[\[:space:\]\]\*block_scope:\[\[:space:\]\]\*/^[ \\t]*block_scope:[ \\t]*/' "$TMP/sgtab" 1 0
  m="$MUT/state-update.sh"
  if mutant_chain cmp-probe "$SUT" "$m" 's/for _t in diff mktemp awk cmp; do/for _t in diff mktemp awk; do/'; then
    PATH="$TMP/nocmp" "$BASH" "$m" "$TMP/drift" >/dev/null 2>"$TMP/stderr"
    if ! grep -qF "required tool 'cmp' not found" "$TMP/stderr"; then ok "teeth cmp-probe: without the probe the typed missing-tool message is gone"; else no "teeth cmp-probe: mutant still names the missing tool — THEATER"; fi
  else fail=$((fail+1)); fi
  if mutant_chain diff-rc-gate "$SUT" "$m" 's/if \[ "\$drc" -ne 1 \]; then/if false; then/'; then
    PATH="$TMP/baddiff:$PATH" bash "$m" "$TMP/drift" >/dev/null 2>&1; mrc=$?
    if [ "$mrc" != 3 ]; then ok "teeth diff-rc-gate: without the gate a failing diff is not DEGRADED (rc $mrc)"; else no "teeth diff-rc-gate: mutant still rc 3 — THEATER"; fi
  else fail=$((fail+1)); fi
  if mutant_chain cmp-rc-gate "$SUT" "$m" 's/elif \[ "\$crc" -ne 0 \]; then/elif false; then/'; then
    PATH="$TMP/badcmp:$PATH" bash "$m" "$TMP/drift" >/dev/null 2>&1; mrc=$?
    if [ "$mrc" != 3 ]; then ok "teeth cmp-rc-gate: without the gate a failing cmp is not DEGRADED (rc $mrc)"; else no "teeth cmp-rc-gate: mutant still rc 3 — THEATER"; fi
  else fail=$((fail+1)); fi
  # list-fail-gate: the failing-helper tree from case 23 with the rc gate removed must stop reading DEGRADED.
  m="$TMP/hf/state-update-m.sh"
  if mutant_chain list-fail-gate "$SUT" "$m" 's/^if \[ "\$lrc" -ne 0 \] || /if false || /'; then
    bash "$m" "$TMP/clean" >/dev/null 2>&1; mrc=$?
    if [ "$mrc" = 2 ]; then ok "teeth list-fail-gate: without the rc gate the failing helper reads as 'no state files' (rc 2)"; else no "teeth list-fail-gate: mutant rc=$mrc — THEATER"; fi
  else fail=$((fail+1)); fi
  # summary-not-last: a stray line printed after the summary must be caught by the case-24 predicate.
  m="$MUT/state-update.sh"
  if mutant_chain summary-not-last "$SUT" "$m" 's/^  \[ -n "\$work" \] && rm -rf "\$work"$/  [ -n "$work" ] \&\& rm -rf "$work"; echo trailing >\&2/'; then
    bash "$m" "$TMP/clean" >/dev/null 2>"$TMP/stderr"
    if last_is_summary; then no "teeth summary-not-last: mutant still ends with the summary — THEATER"; else ok "teeth summary-not-last: a trailing line defeats the last-line predicate"; fi
  else fail=$((fail+1)); fi
  # never-write: run the seeder-equivalent write path on the live target — here, make the rewrite land on "$s".
  m="$MUT/state-update.sh"
  if mutant_chain never-write "$SUT" "$m" 's#> "\$work/proposed" 2> "\$work/awk.err"#> "$s.new" 2> "$work/awk.err" \&\& mv "$s.new" "$s"#'; then
    d="$TMP/ro2"; blocks "$d" proj-block1.md proj-block2.md; state "$d/RESEARCH-STATE.md" 1 1 1
    before="$(snap "$d")"; bash "$m" "$d" >/dev/null 2>&1; after="$(snap "$d")"
    if [ "$before" != "$after" ]; then ok "teeth never-write: mutant modifies the target, so case 4 bites"; else no "teeth never-write: mutant left the target unchanged — THEATER"; fi
  else fail=$((fail+1)); fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]

