#!/usr/bin/env bash
# verify-block-possibility.test.sh — RED-FIRST harness for the POSSIBILITY-FIRST lint in verify-block.sh
# (METHODOLOGY §1 trait · kit issues #1263/#1264/#1265/#1266).
#
# Contract under test: a defeatist feasibility verdict ("not possible", "cannot be determined", "no way to",
# "out of reach", "not determinable", "no se puede" …) must sit in a section that carries a ROUTE LADDER
# (>=3 list items / table rows labelled `route`, plus a `cheapest` next step). Otherwise verify-block.sh
# prints a `WARN    possibility-first` line (advisory: exit code unchanged, like P6/P9). Measurement language
# ("physically impossible value") must NOT fire. `--possibility-sweep <dir>` lists every bare verdict in a
# corpus (propose-never-apply: read-only, exit 0) so existing "can't" verdicts can be reopened as child gaps.
#
# Usage: verify-block-possibility.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-block.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "${2:-$SUT}" "$1" 2>/dev/null; }
mk(){ # mk <file> <body-lines...> : header legend + body
  local f="$1"; shift
  { echo "# Block 1 — t"; echo; echo "> Type: evidence. Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }

echo "== verify-block-possibility.test.sh =="

# 1 — bare English verdict → WARN.
mk "$TMP/bare.md" "## 1.1 Feasibility" "It is not possible to recover the key from the firmware."
out="$(run "$TMP/bare.md")"
if grep -qE 'WARN +possibility-first' <<<"$out"; then ok "bare verdict → WARN possibility-first"
else no "bare verdict not flagged :: $(grep -i possib <<<"$out")"; fi

# 2 — verdict followed by a >=3-route ladder + cheapest step in the same section → no WARN.
mk "$TMP/ladder.md" "## 1.1 Feasibility" "Cannot be determined from static code alone." "" \
  "- Route 1 (own-surface §21.2): grep the sibling module. Cost: 5 min. Needs: source tree. [INFER] proposed" \
  "- Route 2 (dynamic §12): read the live slot. Cost: 20 min. Needs: station access. [INFER] proposed" \
  "- Route 3 (decomposition): split into parse vs. decrypt sub-goals. Cost: 1 h. Needs: nothing. [INFER] proposed" \
  "Cheapest viable next step: Route 1."
out="$(run "$TMP/ladder.md")"
if ! grep -qE 'WARN +possibility-first' <<<"$out"; then ok "verdict + 3-route ladder + cheapest → no WARN"
else no "ladder section wrongly flagged :: $(grep -i 'WARN.*possib' <<<"$out")"; fi

# 3 — a ladder with only 2 routes is still bare.
mk "$TMP/two.md" "## 1.1 Feasibility" "There is no way to read the value." \
  "- Route 1: probe it. Cost: low." "- Route 2: ask the operator. Cost: low." "Cheapest: Route 1."
out="$(run "$TMP/two.md")"
if grep -qE 'WARN +possibility-first' <<<"$out"; then ok "2-route ladder is insufficient → WARN"
else no "2-route ladder accepted"; fi

# 4 — §11a measurement language must not fire.
mk "$TMP/meas.md" "## 1.1 Data checks" \
  "A physically impossible value (-300 C) was flagged." \
  "Impossible values across records indicate a scale error." \
  "The check rejects an impossible reading and an impossible timestamp."
out="$(run "$TMP/meas.md")"
if ! grep -qE 'WARN +possibility-first' <<<"$out"; then ok "§11a measurement language does not fire"
else no "false positive on measurement language :: $(grep -i possib <<<"$out")"; fi

# 5 — Spanish verdict detected.
mk "$TMP/es.md" "## 1.1 Viabilidad" "No se puede leer el valor desde el binario."
out="$(run "$TMP/es.md")"
if grep -qE 'WARN +possibility-first' <<<"$out"; then ok "Spanish 'no se puede' → WARN"
else no "Spanish verdict not flagged"; fi

# 6 — the legal form 'not with <route>, measured' is not a verdict on the goal.
mk "$TMP/legal.md" "## 1.1 Result" "Not with the strings route, measured: 0 hits in 4 MB."
out="$(run "$TMP/legal.md")"
if ! grep -qE 'WARN +possibility-first' <<<"$out"; then ok "'not with <route>, measured' is legal"
else no "legal measured-negative flagged"; fi

# 7 — a ladder in ANOTHER section does not excuse a bare verdict.
mk "$TMP/othersec.md" "## 1.1 A" "Not determinable from here." "## 1.2 B" \
  "- Route 1: x." "- Route 2: y." "- Route 3: z." "Cheapest: Route 1."
out="$(run "$TMP/othersec.md")"
if grep -qE 'WARN +possibility-first' <<<"$out"; then ok "ladder must be in the SAME section"
else no "cross-section ladder wrongly excused the verdict"; fi

# 8 — advisory: exit code unchanged (WARN-only, like P6/P9).
bash "$SUT" "$TMP/bare.md" >/dev/null 2>&1; rc=$?
if [ "$rc" = "0" ]; then ok "WARN-only: exit stays 0"; else no "exit code changed to $rc"; fi

# 9 — fenced code is ignored.
mk "$TMP/fence.md" "## 1.1 Code" '```' "// not possible to reach here" '```'
out="$(run "$TMP/fence.md")"
if ! grep -qE 'WARN +possibility-first' <<<"$out"; then ok "fenced code ignored"; else no "fenced code flagged"; fi

# 10 — sweep: lists bare verdicts (file:line + phrase), skips laddered/measurement ones, exit 0, read-only.
mkdir -p "$TMP/corpus/sub"
cp "$TMP/bare.md" "$TMP/corpus/bloque1.md"; cp "$TMP/ladder.md" "$TMP/corpus/bloque2.md"
cp "$TMP/es.md" "$TMP/corpus/sub/bloque3.md"; cp "$TMP/meas.md" "$TMP/corpus/bloque4.md"
before="$(find "$TMP/corpus" -type f -exec md5sum {} + | sort)"
out="$(bash "$SUT" --possibility-sweep "$TMP/corpus" 2>/dev/null)"; rc=$?
after="$(find "$TMP/corpus" -type f -exec md5sum {} + | sort)"
if [ "$rc" = "0" ] && grep -q 'bloque1.md:' <<<"$out" && grep -q 'bloque3.md:' <<<"$out" \
   && ! grep -q 'bloque2.md:' <<<"$out" && ! grep -q 'bloque4.md:' <<<"$out" \
   && grep -qE 'bare verdicts: 2' <<<"$out" && [ "$before" = "$after" ]; then
  ok "sweep lists exactly the 2 bare verdicts, read-only, exit 0"
else no "sweep output wrong (rc=$rc) :: $out"; fi

# 11 — sweep line shape carries the reopen hint (child gap, §14 back-pointer).
if grep -qE 'bloque1\.md:[0-9]+: .*(not possible)' <<<"$out" && grep -qi 'child gap' <<<"$out"; then
  ok "sweep line = file:line: phrase, with child-gap reopen hint"
else no "sweep line shape :: $out"; fi

# 12 — sweep with a bad dir → exit 2.
bash "$SUT" --possibility-sweep "$TMP/nope" >/dev/null 2>&1; rc=$?
if [ "$rc" = "2" ]; then ok "sweep bad dir → exit 2"; else no "sweep bad dir rc=$rc"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built by lib/mutant.sh (kit #1299), sourced ONLY on this path. It refuses an empty,
  # byte-identical, syntax-broken or live-tree mutant; mutant_chain also refuses a sed stage that matches
  # nothing. A refused build is counted exactly once (mk_mut) and its tooth is skipped.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  for _mf in mutant_chain mutant_tooth; do
    declare -F "$_mf" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_mf" >&2; exit 2; }
  done
  mk_mut(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # A bad side that is only an exit code must not be a crash: these never read as a bite.
  CRASH='integer expression expected|syntax error|unbound variable|command not found|Traceback'
  echo "-- teeth: neuter the ladder acceptance; the laddered fixture must start to WARN --"
  mut="$TMP/verify-block.mut-ladder.sh"
  if grep -q '# PF-LADDER-ACCEPT' "$SUT"; then
    if mk_mut "teeth-ladder" "$SUT" "$mut" '/# PF-LADDER-ACCEPT/ s/routes >= 3/routes >= 99/'; then
      # Advisory lint: exit 0 on both sides; the original must stay silent, the mutant must print the typed WARN line.
      tt "teeth-ladder: neutered threshold → ladder fixture flagged" 0 0 "$mut" --orig "$SUT" \
        --good-lacks 'WARN +possibility-first' --bad-has '^ *WARN +possibility-first' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/ladder.md"
    fi
  else no "teeth-ladder: PF-LADDER-ACCEPT sentinel missing"; fi
  echo "-- teeth: neuter the measurement exclusion; the §11a fixture must start to WARN --"
  mut2="$TMP/verify-block.mut-meas.sh"
  if grep -q '# PF-MEASURE-EXCLUDE' "$SUT"; then
    if mk_mut "teeth-meas" "$SUT" "$mut2" '/# PF-MEASURE-EXCLUDE/ s/.*/      l = l  # PF-MEASURE-EXCLUDE [NEUTERED]/'; then
      tt "teeth-meas: neutered exclusion → measurement fixture flagged" 0 0 "$mut2" --orig "$SUT" \
        --good-lacks 'WARN +possibility-first' --bad-has '^ *WARN +possibility-first' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/meas.md"
    fi
  else no "teeth-meas: PF-MEASURE-EXCLUDE sentinel missing"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
