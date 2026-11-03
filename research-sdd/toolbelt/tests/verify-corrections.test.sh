#!/usr/bin/env bash
# verify-corrections.test.sh — harness for verify-corrections.sh (§14 reciprocal-backlink lint), a SHIM to
# `rsdd verify corrections` (kit issue #2625): the cases run through the shim against the real Go binary (RSDD_BIN,
# else one build into the temp dir). The report is pinned byte for byte against the frozen bash script by the Go
# differential tests (research-sdd/rsdd/internal/verify/corrections) and the rules by Go unit tests; the mutation gate
# of the Go source is `make teeth`. The old case 7b (every `${_vc_targets[@]}` expansion is nounset-safe) was a static
# check of the bash source and is gone with it; its behaviour half (a corpus with no verb at all runs to its ok line)
# stays. --prove-teeth mutates the SHIM (each mutant must lose its case).
#
# The load-bearing behaviour (retro delta): §14 says a correcting block must add a "corrected in BN" note to
# the block it corrects (keep the original text, add the note). Today only the FORWARD half is written by
# habit (the correcting block declares "Corrects [Block N]"); the reciprocal backlink is silently skipped —
# and a self-report can even CLAIM it happened when the git diff proves the target file was never touched.
# This lint mechanizes the reciprocal check: a one-directional correction (declared, not back-linked) FAILs.
# The discriminating case declares a correction whose target lacks the backlink and asserts exit 1; the
# boundary cases (backlink present; a bare [Block N] connection with no correction verb) assert exit 0 so the
# FAIL is provably gated on a real one-directional correction, not on any [Block N] mention. --prove-teeth
# neuters the FAIL and asserts the one-directional fixture then passes, proving the check is not theater.
#
# Usage: verify-corrections.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness (SUT missing).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-corrections.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  _vc_bin_dir="$(mktemp -d)"; trap 'rm -rf "${_vc_bin_dir:-}"' EXIT   # cleaned even when the build below fails
  ( cd "$HERE/../../rsdd" && go build -o "$_vc_bin_dir/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$_vc_bin_dir/rsdd"
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "${_vc_bin_dir:-}"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "$SUT" "$1" 2>/dev/null; }
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }

echo "== verify-corrections.test.sh (SUT: $(basename "$SUT")) =="

# 1 — no block files under the target → exit 2 (nothing to lint).
d="$TMP/empty"; mkdir -p "$d"; printf '# not a block\n' > "$d/notes.md"
if [ "$(code "$d")" = 2 ]; then ok "no block files → exit 2"; else no "empty: got $(code "$d") (want 2)"; fi

# 2 — RECIPROCATED correction: B33 declares 'Corrects [Block 8]' AND block-8 carries 'corrected in B33' → exit 0.
d="$TMP/ok"; mkdir -p "$d"
printf '# Block 33\n\n> Corrects [Block 8] §2 on Docker.\n\nBody.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n\n> Note: corrected in B33 (new citation sources/x.pdf).\n' > "$d/t-block8.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +every declared correction' <<<"$out"; then
  ok "reciprocated correction (B33→B8, B8 has 'corrected in B33') → exit 0 + ok line"
else no "ok-case: exit $(code "$d") :: $(grep -iE 'fail|ok ' <<<"$out" | head -1)"; fi

# 3 — CORE (retro delta): B33 declares 'Corrects [Block 8]' but block-8 has NO 'corrected in B33' backlink
#     → FAIL exit 1. This is the exact B33→B8 gap the retro caught (the correcting commit never touched B8).
d="$TMP/onedir"; mkdir -p "$d"
printf '# Block 33\n\n> Corrects [Block 8] §2 on Docker.\n\nBody.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal Docker claim, never annotated.\n' > "$d/t-block8.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*B33 corrects \[Block 8\].*reciprocal' <<<"$out"; then
  ok "one-directional correction (B8 lacks 'corrected in B33') → FAIL exit 1"
else no "onedir: exit $(code "$d") :: $(grep -iE 'fail' <<<"$out" | head -1)"; fi

# 4 — NEGATIVE CONTROL: a bare '[Block 8]' CONNECTION (no correction verb) must NOT fire — proves the FAIL is
#     gated on a real correction declaration, not on any [Block N] reference.
d="$TMP/connection"; mkdir -p "$d"
printf '# Block 33\n\n## Connections\n- **[Block 8]** — extends its Docker discussion.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n' > "$d/t-block8.md"
if [ "$(code "$d")" = 0 ]; then ok "bare [Block 8] connection (no 'corrects' verb) → exit 0 (no false FAIL)"
else no "connection: exit $(code "$d") (want 0 — false FAIL on a plain connection)"; fi

# 5 — 'correct' the ADJECTIVE must not trip the verb detector: 'the correct value [Block 8]' → exit 0.
d="$TMP/adjective"; mkdir -p "$d"
printf '# Block 33\n\nThe correct value is 5 V, matching [Block 8].\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n' > "$d/t-block8.md"
if [ "$(code "$d")" = 0 ]; then ok "adjective 'correct value' + [Block 8] → exit 0 (verb-anchored, no false FAIL)"
else no "adjective: exit $(code "$d") (want 0 — 'correct' adjective wrongly treated as a correction)"; fi

# 6 — TIGHT VERB→REFERENCE BINDING (retro delta): a correction verb governs ONLY the FIRST [Block N] that
#     FOLLOWS it. B33 says 'Corrects [Block 8] §2; cf. [Block 12].' — it corrects 8 (which HAS its backlink)
#     and merely CROSS-REFERENCES 12. The trailing `cf. [Block 12]` must NOT be treated as a correction
#     target, so block-12 needs NO backlink → exit 0. RED before the fix: the loop iterated EVERY bracketed
#     ref on the verb line, demanding a 'corrected in B33' backlink in block-12 → false FAIL exit 1.
d="$TMP/cfref"; mkdir -p "$d"
printf '# Block 33\n\n> Corrects [Block 8] §2; cf. [Block 12].\n\nBody.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n\n> Note: corrected in B33.\n' > "$d/t-block8.md"
printf '# Block 12\n\nUnrelated cross-referenced block, no backlink.\n' > "$d/t-block12.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +every declared correction' <<<"$out"; then
  ok "verb governs only the first ref: 'Corrects [8] … cf. [12]' → 12 not a target → exit 0"
else no "cfref: exit $(code "$d") :: $(grep -iE 'fail' <<<"$out" | head -1)"; fi

d="$TMP/noverb"; mkdir -p "$d"
printf '# Block 1\n\nNothing declared here.\n' > "$d/t-block1.md"; printf '# Block 2\n\nNor here.\n' > "$d/t-block2.md"
out="$(bash "$SUT" "$d" 2>&1)"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +every declared correction' <<<"$out" && ! grep -q 'unbound variable' <<<"$out"; then
  ok "corpus with no correction verb at all → ok line, no 'unbound variable' (empty-array path)"
else no "noverb: exit $(code "$d") :: $(tr '\n' '|' <<<"$out")"; fi

# 7 — NO VERB AT ALL (#1840) above: most block files have no correction verb; the corpus runs to its ok line. The
#     old static half (every ${_vc_targets[@]} expansion is nounset-safe) checked the bash source and is gone with it.

# 8 — the SHIM contract: arguments, exit code and report pass through the binary unchanged (usage → 2; no target → 2).
out="$(bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'usage: verify-corrections.sh <target-dir>' <<<"$out"; then
  ok "shim: no argument → usage on stderr, exit 2 (the binary's contract, unchanged)"
else no "shim usage: exit $rc :: $out"; fi

# NEGATIVE CONTROLS — mutate the SHIM; each mutant must lose the case that owns the property.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built by lib/mutant.sh (kit #1299), sourced ONLY on this path. It refuses an empty,
  # byte-identical, syntax-broken or live-tree mutant; mutant_chain also refuses a sed stage that matches
  # nothing. A refused build is counted exactly once (mk_mut) and its tooth is skipped.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ mutant_chain_or_count fail "$@" || return 1; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # A bad side that is only an exit code must not be a crash: these never read as a bite.
  CRASH="$(mutant_crash_re bash cmd tb)" || exit 2
  # The mutants sit in $TMP beside a copy of rsdd-exec.sh (the shim sources lib/rsdd-exec.sh at its own dir).
  mkdir -p "$TMP/lib"; cp "$HERE/../lib/rsdd-exec.sh" "$TMP/lib/rsdd-exec.sh"   # stage-libs-ok: the shim's one helper
  d="$TMP/onedir"   # case 3's one-directional fixture: original exit 1 (FAIL)

  echo "-- teeth: the shim drops the caller's arguments; the target is lost (usage, exit 2) --"
  mutant="$TMP/verify-corrections.ARGS.sh"
  if mk_mut "teeth: args dropped" "$SUT" "$mutant" 's/^rsdd_exec verify corrections "\$@"$/rsdd_exec verify corrections/'; then
    tt "teeth: args-dropping shim loses the one-directional verdict (exit 2, not 1) → case 3 has teeth" 1 2 "$mutant" --orig "$SUT" \
      --good-has '^ *FAIL' --bad-lacks '^ *FAIL' --bad-lacks "$CRASH" -- bash @SUT@ "$d"
  fi

  echo "-- teeth: the shim swallows the binary's exit code (exit 0 after a FAIL) --"
  mutant="$TMP/verify-corrections.RC.sh"
  if mk_mut "teeth: rc swallowed" "$SUT" "$mutant" 's/^rsdd_exec verify corrections "\$@"$/rsdd_exec verify corrections "$@"; exit 0/'; then
    tt "teeth: rc-swallowing shim reports success on a one-directional correction (exit 0) → case 3 has teeth" 1 0 "$mutant" --orig "$SUT" \
      --good-has '^ *FAIL' --bad-has '^ *FAIL' --bad-lacks "$CRASH" -- bash @SUT@ "$d"
  fi

  echo "-- teeth: the shim runs another command (verify registry) --"
  mutant="$TMP/verify-corrections.CMD.sh"
  if mk_mut "teeth: wrong command" "$SUT" "$mutant" 's/^rsdd_exec verify corrections /rsdd_exec verify registry /'; then
    tt "teeth: wrong-command shim does not produce the corrections report → case 3 has teeth" 1 2 "$mutant" --orig "$SUT" \
      --good-has '^ *FAIL' --bad-lacks '^ *FAIL' --bad-lacks "$CRASH" -- bash @SUT@ "$d"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
