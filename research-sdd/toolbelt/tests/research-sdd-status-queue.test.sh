#!/usr/bin/env bash
# research-sdd-status-queue.test.sh — `--next --queue` honours a declared `next_session_queue` (kit issue #1614).
#
# Design (accepted on the issue, 2026-10-07): the state file's header carries `next_session_queue: G1, G2`. `--next --queue`
# returns the FIRST queued gap still pending (and not blocked); when none remains it falls back to the normal priority
# order with a typed `queue-exhausted` note. The queue never bypasses STALE / RETRO-DUE / ISSUES-DUE; one queue per focus.
#
# Anti-silent-zero (CLAUDE.md §7): queue ABSENT / DECLARED-EMPTY / ALL-DONE (exhausted) / UNKNOWN gap id / MALFORMED field /
# PROSE-ONLY header are distinct, typed stderr notes. Without --queue the output is byte-identical to before.
#
# Fixture shape: backlog is high G1 (priority order would pick it), medium G2, low G3 — the queue reorders, so a mutant
# that ignores the queue is visible. List edges: queue of first / middle / last / single item.
#
# Usage: research-sdd-status-queue.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT_UNDER_TEST:-$HERE/../research-sdd-status.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TB="$HERE/.."
FX="$HERE/fixtures/status-queue"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-queue.test.sh =="

# mk_q FILE BSR HEADER_TEXT ROW... — a derived-consistent state; ROW is "prio|gap|status"; HEADER_TEXT is raw header lines.
mk_q() {
  local f="$1" bsr="$2" hdr="$3" r p g s io=0; shift 3
  for r in "$@"; do IFS='|' read -r p g s <<<"$r"; [ "${s%% *}" = "pending" ] && io=$((io+1)); done
  mkdir -p "$(dirname "$f")"
  {
    echo "# Q — Research State"; echo
    [ -n "$hdr" ] && printf '%b\n\n' "$hdr"
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\nblocks_since_retro: %s\n<!-- /research-state.v1 -->\n\n' "$io" "$bsr"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    for r in "$@"; do IFS='|' read -r p g s <<<"$r"; echo "| $p | $g | web | $s |"; done
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: $io"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$f"
}
ROWS=("high|G1 first gap|pending" "medium|G2 second gap|pending" "low|G3 third gap|pending")
mkd() { local d="$TMP/$1"; mk_q "$d/RESEARCH-STATE.md" "${3:-0}" "$2" "${ROWS[@]}"; printf '%s' "$d"; }

# nq SUT DIR ARGS... -> stdout verdict in $out, stderr in $err, exit code not kept
nq() { local s="$1" d="$2"; shift 2; out="$(bash "$s" "$d" --next "$@" 2>"$TMP/err")"; err="$(cat "$TMP/err")"; }
want() { # LABEL WANT_OUT [ERR_REGEX]
  if [ "$out" = "$2" ]; then ok "$1 -> [$2]"; else no "$1: want [$2], got [$out] (err: $err)"; fi
  if [ -n "${3:-}" ]; then if grep -qE -- "$3" <<<"$err"; then ok "$1: stderr carries /$3/"; else no "$1: stderr lacks /$3/ — got [$err]"; fi; fi; }

# --- 1. serve order & list edges ----------------------------------------------------------------
d="$(mkd q-first 'next_session_queue: G3, G1, G2')"; nq "$SUT" "$d" --queue; want "1a queue head (first item)" "NEXT | low | G3 third gap"
d="$(mkd q-mid 'next_session_queue: G2, G3')";       nq "$SUT" "$d" --queue; want "1b queue of 2 (head is the middle-priority gap)" "NEXT | medium | G2 second gap"
d="$(mkd q-single 'next_session_queue: G3')";        nq "$SUT" "$d" --queue; want "1c single-item queue" "NEXT | low | G3 third gap"
d="$(mkd q-hdrbullet '- next_session_queue: G2')";   nq "$SUT" "$d" --queue; want "1d list-marker form" "NEXT | medium | G2 second gap"
mk_q "$TMP/q-last/RESEARCH-STATE.md" 0 'next_session_queue: G1, G2, G3' "high|G1 first gap|covered" "medium|G2 second gap|done" "low|G3 third gap|pending"
nq "$SUT" "$TMP/q-last" --queue; want "1e LAST queued item is the only pending one" "NEXT | low | G3 third gap"
mk_q "$TMP/q-midp/RESEARCH-STATE.md" 0 'next_session_queue: G1, G2, G3' "high|G1 first gap|covered" "medium|G2 second gap|pending" "low|G3 third gap|pending"
nq "$SUT" "$TMP/q-midp" --queue; want "1f MIDDLE queued item served after a done head" "NEXT | medium | G2 second gap"
mk_q "$TMP/q-bound/RESEARCH-STATE.md" 0 'next_session_queue: G1' "high|G10 ten|pending" "medium|G1-b sub|pending" "low|G1 real|pending"
nq "$SUT" "$TMP/q-bound" --queue; want "1g id G1 does not match G10 or G1-b" "NEXT | low | G1 real"
mk_q "$TMP/q-blk/RESEARCH-STATE.md" 0 'next_session_queue: G1, G2' "high|G1 first gap|blocked (requires-hardware)" "medium|G2 second gap|pending"
nq "$SUT" "$TMP/q-blk" --queue; want "1h blocked queued gap skipped, next queued served" "NEXT | medium | G2 second gap"
# a pending row listed in the ## Blocked gaps section is blocked too (is_blocked, the same set resolve_next honours)
mk_q "$TMP/q-blk2/RESEARCH-STATE.md" 0 'next_session_queue: G1, G2' "high|G1 first gap|pending" "medium|G2 second gap|pending"
printf '\n## Blocked gaps (each tagged with what it needs)\n\n- G1 first gap — needs: hardware\n' >> "$TMP/q-blk2/RESEARCH-STATE.md"
sed -i 's/^investigable_open: .*/investigable_open: 1/; s/^blocked_open: .*/blocked_open: 1/; s/read-only investigable\*\*: 2/read-only investigable**: 1/' "$TMP/q-blk2/RESEARCH-STATE.md"
nq "$SUT" "$TMP/q-blk2" --queue; want "1h2 pending-but-in-Blocked-section queued gap skipped" "NEXT | medium | G2 second gap"
nq "$SUT" "$TMP/q-first"; want "1i no --queue: priority order, field ignored" "NEXT | high | G1 first gap"
[ -z "$err" ] && ok "1i no --queue: no queue note on stderr" || no "1i stderr must stay empty without --queue, got [$err]"

# --- 2. typed states ------------------------------------------------------------------------------
d="$(mkd q-absent '')";                       nq "$SUT" "$d" --queue; want "2a ABSENT -> priority order" "NEXT | high | G1 first gap" 'INFO: queue-absent'
d="$(mkd q-empty 'next_session_queue:')";     nq "$SUT" "$d" --queue; want "2b DECLARED-EMPTY -> priority order" "NEXT | high | G1 first gap" 'INFO: queue-empty'
d="$(mkd q-none 'next_session_queue: none')"; nq "$SUT" "$d" --queue; want "2b2 'none' is declared-empty" "NEXT | high | G1 first gap" 'INFO: queue-empty'
mk_q "$TMP/q-done/RESEARCH-STATE.md" 0 'next_session_queue: G1, G2' "high|G1 first gap|covered" "medium|G2 second gap|done" "low|G3 third gap|pending"
nq "$SUT" "$TMP/q-done" --queue; want "2c ALL-DONE -> priority order + queue-exhausted" "NEXT | low | G3 third gap" 'INFO: queue-exhausted.*2 done'
d="$(mkd q-unk 'next_session_queue: G9, G2')";    nq "$SUT" "$d" --queue; want "2d UNKNOWN id warned (never silent), next queued served" "NEXT | medium | G2 second gap" 'WARN: queue-unknown-gap.*G9'
d="$(mkd q-unkonly 'next_session_queue: G9')";    nq "$SUT" "$d" --queue; want "2e only-unknown queue -> exhausted with unknown count" "NEXT | high | G1 first gap" 'queue-exhausted.*1 unknown'
d="$(mkd q-mal1 'next_session_queue: G1, , G2')"; nq "$SUT" "$d" --queue; want "2f MALFORMED (empty item) -> field ignored" "NEXT | high | G1 first gap" 'WARN: queue-malformed'
d="$(mkd q-mal2 'next_session_queue: G2 then G3')"; nq "$SUT" "$d" --queue; want "2g MALFORMED (prose item) -> field ignored" "NEXT | high | G1 first gap" 'WARN: queue-malformed'
d="$(mkd q-mal3 'next_session_queue: G3\nnext_session_queue: G2')"; nq "$SUT" "$d" --queue; want "2h MALFORMED (declared twice) -> field ignored" "NEXT | high | G1 first gap" 'WARN: queue-malformed.*more than once'
nq "$SUT" "$FX/prose-only" --queue; want "2i PROSE-ONLY header (real niagara5 form) -> priority order" "NEXT | high | G1 decompile fidelity" 'INFO: queue-prose-only'
mk_q "$TMP/q-late/RESEARCH-STATE.md" 0 '' "${ROWS[@]}"; printf '\nnext_session_queue: G3\n' >> "$TMP/q-late/RESEARCH-STATE.md"
nq "$SUT" "$TMP/q-late" --queue; want "2j field below the header zone is not read" "NEXT | high | G1 first gap" 'queue-absent'

# the shipped template's explanatory header comment (it names the field) is neither a declaration nor prose
d="$(mkd q-tplcomment '<!-- OPTIONAL: add a line\n     `next_session_queue: <gap-id>, ...` starting at column 0\n     (next session queue) -->')"
nq "$SUT" "$d" --queue; want "2k template comment naming the field -> absent, not prose-only/malformed" "NEXT | high | G1 first gap" 'INFO: queue-absent'
# a header line that merely CONTAINS the field text (indented) is not a declaration
d="$(mkd q-indent '    next_session_queue: G3')"
nq "$SUT" "$d" --queue; want "2l indented mention is not a declaration" "NEXT | high | G1 first gap" 'queue-(absent|prose-only)'

# --- 2m. closed / parked / in-progress queued gaps are KNOWN, counted by class (never queue-unknown-gap) -----------------
CROWS=("high|G1 first gap|pending" "~~high~~|G5 struck-priority gap|~~covered~~" "high|~~G6 struck-name gap~~|covered" "deferred|G7 parked closed|✅ done" "deferred|G8 parked open|parked" "medium|G9 half done|in-progress" "—|G10 emdash closed|covered")
mk_q "$TMP/q-cls/RESEARCH-STATE.md" 0 'next_session_queue: G5, G6, G7, G8, G9, G10' "${CROWS[@]}"
nq "$SUT" "$TMP/q-cls" --queue
if [ "$out" = "NEXT | high | G1 first gap" ]; then ok "2m falls back to priority order"; else no "2m want G1 fallback, got [$out] (err: $err)"; fi
grep -q 'queue-unknown-gap' <<<"$err" && no "2m closed/parked/em-dash/struck queued gaps must be KNOWN, got [$err]" || ok "2m no queue-unknown-gap for closed-class rows"
grep -q 'queue-exhausted.*(6 ids: 4 done, 1 deferred, 0 blocked, 1 in-progress, 0 unknown)' <<<"$err" && ok "2m counts: 4 done (struck priority, struck name, closed deferred, em-dash) · 1 deferred · 1 in-progress" || no "2m counts wrong: [$err]"
for k in "G5:struck-priority" "G6:struck-name" "G7:closed-deferred" "G8:open-deferred" "G9:in-progress" "G10:em-dash"; do
  mk_q "$TMP/q-cls1/RESEARCH-STATE.md" 0 "next_session_queue: ${k%%:*}" "${CROWS[@]}"
  nq "$SUT" "$TMP/q-cls1" --queue
  if grep -q 'queue-unknown-gap' <<<"$err"; then no "2m ${k##*:}: queued ${k%%:*} reported unknown [$err]"; else ok "2m ${k##*:}: queued ${k%%:*} is known"; fi
done
# a queued gap that is in progress is not served (only 'pending' is)
mk_q "$TMP/q-prog/RESEARCH-STATE.md" 0 'next_session_queue: G9, G2' "${ROWS[@]:0:1}" "medium|G9 half done|in-progress" "low|G2 later|pending"
nq "$SUT" "$TMP/q-prog" --queue; want "2n in-progress queued gap skipped, next served" "NEXT | low | G2 later"

# --- 2t. open deferred rows: 5-column tables and Gap-backlog sections only (a bolded `**deferred**` priority is STALE in the kit, so unreachable) --------------------------------
mk5="$TMP/q-5col"; mkdir -p "$mk5"
cat > "$mk5/RESEARCH-STATE.md" <<'EOT'
# Q5 — Research State

next_session_queue: G8

<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 0
gaps_closed: 0
known_gaps: 0
investigable_open: 1
requires_execution_open: 0
blocked_open: 0
<!-- /research-state.v1 -->

## Gap-backlog (prioritized)

| Priority | ID | Gap | Artifact type / source | Status |
|---|---|---|---|---|
| high | G1 | first gap | web | pending |
| deferred | G8 | parked thing | web | parked |

## Stop control

- **Open gaps — read-only investigable**: 1
- **Open gaps — requires-execution**: 0
- **Open gaps — blocked**: 0
EOT
nq "$SUT" "$mk5" --queue
if grep -q 'queue-unknown-gap' <<<"$err"; then no "2t 5-column open deferred row must be KNOWN [$err]"; else ok "2t 5-column open deferred row is known"; fi
grep -q '1 deferred' <<<"$err" && ok "2t 5-column deferred counted as deferred" || no "2t counts [$err]"
mk_q "$TMP/q-oob/RESEARCH-STATE.md" 0 'next_session_queue: G11' "high|G1 first gap|pending"
printf '\n## Notes\n\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| deferred | G11 not a backlog row | web | parked |\n' >> "$TMP/q-oob/RESEARCH-STATE.md"
nq "$SUT" "$TMP/q-oob" --queue; want "2v a deferred row outside a Gap-backlog section is NOT a backlog row (unknown, loud)" "NEXT | high | G1 first gap" 'WARN: queue-unknown-gap.*G11'

# --- 2w. several rows match one queued id: warned, a servable one still wins ------------------------------------------------
mk_q "$TMP/q-amb1/RESEARCH-STATE.md" 0 'next_session_queue: G4' "high|G4 old attempt|covered" "medium|G4 reopened|pending"
nq "$SUT" "$TMP/q-amb1" --queue; want "2w closed row first, pending second -> pending served" "NEXT | medium | G4 reopened" 'WARN: queue-ambiguous-id.*G4.*2 rows'
mk_q "$TMP/q-amb2/RESEARCH-STATE.md" 0 'next_session_queue: G4' "high|G4 reopened|pending" "medium|G4 old attempt|covered"
nq "$SUT" "$TMP/q-amb2" --queue; want "2w pending row first, closed second -> same warning, pending served" "NEXT | high | G4 reopened" 'WARN: queue-ambiguous-id.*G4.*2 rows'
nq "$SUT" "$FX/closed-plus-pending" --queue; want "2x closed G1 + pending G1-b -> G1 exhausted, priority order" "NEXT | high | G1-b follow-up of G1" 'queue-exhausted.*1 done'
if grep -q 'queue-ambiguous-id' <<<"$err"; then no "2x G1-b must not make G1 ambiguous [$err]"; else ok "2x no ambiguity warning for a prefix sibling"; fi

# --- 2o. field-parser edges -------------------------------------------------------------------------------------------
d="$(mkd q-trail 'next_session_queue: G3, G2,')"; nq "$SUT" "$d" --queue; want "2o trailing comma is malformed (like ,,)" "NEXT | high | G1 first gap" 'WARN: queue-malformed.*trailing comma'
d="$(mkd q-dup 'next_session_queue: G3, G3, G2')"; nq "$SUT" "$d" --queue; want "2p duplicate id warned, served once" "NEXT | low | G3 third gap" 'WARN: queue-duplicate-id.*G3'
d="$(mkd q-NONE 'next_session_queue: NONE')"; nq "$SUT" "$d" --queue; want "2q NONE is declared-empty (case-insensitive)" "NEXT | high | G1 first gap" 'INFO: queue-empty'
d="$(mkd q-glob 'next_session_queue: G*')"; nq "$SUT" "$d" --queue; want "2r glob item is malformed, never expanded" "NEXT | high | G1 first gap" 'WARN: queue-malformed.*G\*'
d="$(mkd q-cmt '<!-- note\nnext_session_queue: G3\n-->')"; nq "$SUT" "$d" --queue; want "2s column-0 declaration inside a multi-line HTML comment is not read" "NEXT | high | G1 first gap" 'queue-(absent|prose-only)'

# --- 3. the queue never bypasses the gates ---------------------------------------------------------
d="$(mkd q-stale 'next_session_queue: G3')"; sed -i 's/^investigable_open: .*/investigable_open: 1/' "$d/RESEARCH-STATE.md"
nq "$SUT" "$d" --queue; case "$out" in "STALE |"*) ok "3a STALE precedes the queue -> [$out]" ;; *) no "3a want STALE, got [$out]" ;; esac
d="$(mkd q-retro 'next_session_queue: G3' 11)"
nq "$SUT" "$d" --queue; case "$out" in "RETRO-DUE |"*) ok "3b RETRO-DUE precedes the queue -> [$out]" ;; *) no "3b want RETRO-DUE, got [$out]" ;; esac
mk_kit() { # DIR  — a kit copy whose reconcile-issues.sh reports one untracked delta
  local k="$1"; mkdir -p "$k/lib" "$k/bin"
  printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; issue) exit 0 ;; *) exit 1 ;; esac\n' > "$k/bin/gh"; chmod +x "$k/bin/gh"
  printf '#!/usr/bin/env bash\nexport PATH="%s/bin:$PATH"\nexec bash "%s/_sut.sh" "$@"\n' "$k" "$k" > "$k/research-sdd-status.sh"; chmod +x "$k/research-sdd-status.sh"
  cp "$SUT" "$k/_sut.sh"; cp "$TB/verify-state.sh" "$k/"; cp "$TB"/lib/*.sh "$k/lib/"
  printf '#!/usr/bin/env bash\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' > "$k/reconcile-issues.sh"; chmod +x "$k/reconcile-issues.sh"
}
mk_kit "$TMP/kit-u"
mk_q "$TMP/q-idg/RESEARCH-STATE.md" 0 'next_session_queue: G1' "high|G1 first gap|covered"; mkdir -p "$TMP/q-idg/retros"; touch "$TMP/q-idg/retros/2026-09-01-retro-x.md"
nq "$TMP/kit-u/research-sdd-status.sh" "$TMP/q-idg" --queue; case "$out" in "ISSUES-DUE |"*) ok "3c ISSUES-DUE still fires when the queue is exhausted" ;; *) no "3c want ISSUES-DUE, got [$out]" ;; esac
grep -q 'queue-exhausted' <<<"$err" && ok "3c queue-exhausted note accompanies the fall-through" || no "3c missing queue-exhausted note [$err]"

# --- 4. one queue per focus -----------------------------------------------------------------------
mk_q "$TMP/q-foc/RESEARCH-STATE.md" 0 'next_session_queue: G3' "${ROWS[@]}"
mk_q "$TMP/q-foc/RESEARCH-STATE-act.md" 0 'next_session_queue: G2' "${ROWS[@]}"
nq "$SUT" "$TMP/q-foc" --queue --focus act; want "4a --focus act reads act's own queue" "NEXT | medium | G2 second gap"
nq "$SUT" "$TMP/q-foc" --queue --root;      want "4b --root reads the root queue" "NEXT | low | G3 third gap"
nq "$SUT" "$TMP/q-foc" --queue;             want "4c aggregate: the first active focus (act) serves its OWN queue" "NEXT | medium | G2 second gap"
mk_q "$TMP/q-foc2/RESEARCH-STATE.md" 0 '' "${ROWS[@]}"; mk_q "$TMP/q-foc2/RESEARCH-STATE-act.md" 0 'next_session_queue: G3' "${ROWS[@]}"
nq "$SUT" "$TMP/q-foc2" --queue --root; want "4d a sibling focus's queue does not steer the root" "NEXT | high | G1 first gap" 'queue-absent'

# --- 5. flag plumbing -----------------------------------------------------------------------------
bash "$SUT" "$TMP/q-first" --queue >/dev/null 2>&1; [ $? -eq 2 ] && ok "5a --queue without --next -> exit 2" || no "5a --queue without --next must exit 2"
bash "$SUT" "$TMP/q-first" --sync-state --queue >/dev/null 2>&1; [ $? -eq 2 ] && ok "5b --queue with --sync-state -> exit 2" || no "5b must exit 2"
out="$(bash "$SUT" "$TMP/q-first" --next --queue --emit-token 2>/dev/null)"
[ "$(tail -1 <<<"$out")" = "return-token: next: G3 third gap" ] && ok "5c --emit-token forwards --queue (token names the queued gap)" || no "5c emit-token got [$out]"

# --- 6. no declared field -> stdout byte-identical with and without --queue ---------------------------
for d in "$TMP/q-absent" "$TMP/q-empty" "$FX/prose-only"; do
  a="$(bash "$SUT" "$d" --next 2>/dev/null)"; b="$(bash "$SUT" "$d" --next --queue 2>/dev/null)"
  if [ "$a" = "$b" ]; then ok "6 $(basename "$d"): stdout byte-identical with/without --queue"; else no "6 $(basename "$d"): [$a] vs [$b]"; fi
done

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for --next --queue --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  mutate() { local t; t="$(mk_tree "$1")"
    if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" "$2" >/dev/null 2>&1; then MUT="$t/research-sdd-status.sh"; return 0; fi
    no "teeth $1: mutant could not be built (anchor absent / refused by lib/mutant.sh)"; return 1; }
  # A: the queue is never consulted -> 1a goes red
  if mutate A 's/^    queue_next; _rq_rc=\$?$/    _rq_rc=1/'; then
    nq "$MUT" "$TMP/q-first" --queue
    [ "$out" = "NEXT | high | G1 first gap" ] && ok "teeth A: queue ignored -> priority verdict -> 1a has teeth" || no "teeth A: want the priority verdict, got [$out] — THEATER/crash"; fi
  # B: pending test dropped (a covered queued gap is served) -> 2c goes red
  if mutate B 's/^\(             closed|.*) c=\)terminal ;;$/\1serve ;;/'; then
    nq "$MUT" "$TMP/q-done" --queue
    [ "$out" = "NEXT | high | G1 first gap" ] && ok "teeth B: done gap served -> 2c has teeth" || no "teeth B: want the done head served, got [$out] — THEATER/crash"; fi
  # C: blocked check dropped -> 1h2 goes red
  if mutate C 's/^\(             pending) \)is_blocked "\$gap"; _qn_ib=\$?$/\1_qn_ib=1/'; then
    nq "$MUT" "$TMP/q-blk2" --queue
    [ "$out" = "NEXT | high | G1 first gap" ] && ok "teeth C: blocked head served -> 1h2 has teeth" || no "teeth C: want the blocked head served, got [$out] — THEATER/crash"; fi
  # D: the id-boundary guard dropped (prefix match) -> 1g goes red
  if mutate D 's/^      case "\$lead" in "\$id") ;; "\$id"\[!A-Za-z0-9._-\]\*) ;; \*) continue ;; esac$/      case "$lead" in "$id"*) ;; *) continue ;; esac/'; then
    nq "$MUT" "$TMP/q-bound" --queue
    [ "$out" = "NEXT | high | G10 ten" ] && ok "teeth D: prefix match -> G10 served -> 1g has teeth" || no "teeth D: want G10 served, got [$out] — THEATER/crash"; fi
  # E: unknown-id WARN dropped -> 2d goes red
  if mutate E 's/^    if \[ "\$found" = 0 \]; then$/    if false; then/'; then
    nq "$MUT" "$TMP/q-unk" --queue
    if [ "$out" = "NEXT | medium | G2 second gap" ] && ! grep -q 'queue-unknown-gap' <<<"$err"; then ok "teeth E: unknown id silently skipped -> 2d has teeth"; else no "teeth E: want serve without WARN, got [$out] [$err]"; fi; fi
  # F: malformed items accepted (id grammar check dropped) -> 2f goes red
  if mutate F 's/^    if ! grep -qE .\^\[A-Za-z0-9\]\[A-Za-z0-9._-\]\*\$. <<<"\$id"; then$/    if false; then/'; then
    nq "$MUT" "$TMP/q-mal1" --queue
    if ! grep -q 'queue-malformed' <<<"$err"; then ok "teeth F: malformed field accepted silently -> 2f has teeth"; else no "teeth F: mutant still reported malformed [$err]"; fi; fi
  # G: the header-zone bound dropped (field read from anywhere) -> 2j goes red
  if mutate G 's|raw="\$(awk ./\^## /{exit} /|raw="$(awk '"'"'/^ZZZ-NEVER/{exit} /|'; then
    nq "$MUT" "$TMP/q-late" --queue
    [ "$out" = "NEXT | low | G3 third gap" ] && ok "teeth G: field read below the header -> 2j has teeth" || no "teeth G: want the late field honoured, got [$out] — THEATER/crash"; fi
  # H: the scoped path ignores the queue -> 4a goes red
  if mutate H 's/^    _rn_out="\$(resolve_next_q)"$/    _rn_out="$(resolve_next)"/'; then
    nq "$MUT" "$TMP/q-foc" --queue --focus act
    [ "$out" = "NEXT | high | G1 first gap" ] && ok "teeth H: scoped path ignores the queue -> 4a has teeth" || no "teeth H: want priority verdict, got [$out] — THEATER/crash"; fi
  # I: the closed-class rows are not requested (backlog_rows without the closed-class arg) -> struck-priority / em-dash read unknown
  if mutate I 's/backlog_rows 1)"\$.\\n.\"/backlog_rows)"$'"'"'\\n'"'"'"/'; then
    nq "$MUT" "$TMP/q-cls1" --queue; mk_q "$TMP/q-cls1/RESEARCH-STATE.md" 0 'next_session_queue: G10' "${CROWS[@]}"; nq "$MUT" "$TMP/q-cls1" --queue
    grep -q 'queue-unknown-gap' <<<"$err" && ok "teeth I: closed-class rows unread -> em-dash gap reads unknown -> 2m has teeth" || no "teeth I: mutant still knew the em-dash gap [$err]"; fi
  # J: open deferred rows not read -> a queued parked gap reads unknown
  if mutate J 's/if (pr!="deferred" || (NF!=6 \&\& NF!=7)) next/next/'; then
    mk_q "$TMP/q-cls1/RESEARCH-STATE.md" 0 'next_session_queue: G8' "${CROWS[@]}"; nq "$MUT" "$TMP/q-cls1" --queue
    grep -q 'queue-unknown-gap' <<<"$err" && ok "teeth J: open-deferred unread -> unknown -> 2m has teeth" || no "teeth J: mutant still knew the parked gap [$err]"; fi
  # K: in-progress counted as done -> the exhausted counts are wrong
  if mutate K 's/^             \*) c=inprogress ;;$/             *) c=terminal ;;/'; then
    nq "$MUT" "$TMP/q-cls" --queue
    grep -q '5 done, 1 deferred, 0 blocked, 0 in-progress' <<<"$err" && ok "teeth K: in-progress folded into done -> 2m counts have teeth" || no "teeth K: counts unchanged [$err]"; fi
  # L: the aggregate (no --root/--focus) call site ignores the queue -> 4c goes red
  if mutate L 's/^      _r="\$(resolve_next_q)"$/      _r="$(resolve_next)"/'; then
    nq "$MUT" "$TMP/q-foc" --queue
    [ "$out" = "NEXT | high | G1 first gap" ] && ok "teeth L: aggregate call site ignores the queue -> 4c has teeth" || no "teeth L: want priority verdict, got [$out] — THEATER/crash"; fi
  # M: declared-twice check dropped -> 2h goes red
  if mutate M 's/-gt 1 \]; then$/-gt 99 ]; then/'; then
    nq "$MUT" "$TMP/q-mal3" --queue
    ! grep -q 'declared more than once' <<<"$err" && ok "teeth M: declared-twice unnoticed -> 2h has teeth" || no "teeth M: still reported [$err]"; fi
  # N: declared-empty branch dropped -> 2b goes red
  if mutate N "s/^  case \"\\\${val,,}\" in ''|none|'\\[\\]')/  case \"\\\${val,,}\" in 'zzz-never')/"; then
    nq "$MUT" "$TMP/q-empty" --queue
    ! grep -q 'queue-empty' <<<"$err" && ok "teeth N: declared-empty branch dropped -> 2b has teeth" || no "teeth N: still queue-empty [$err]"; fi
  # O: prose detection dropped -> 2i goes red
  if mutate O 's/tolower(\$0) ~ \/next/tolower($0) ~ \/zznever/'; then
    nq "$MUT" "$FX/prose-only" --queue
    ! grep -q 'queue-prose-only' <<<"$err" && ok "teeth O: prose-only detection dropped -> 2i has teeth" || no "teeth O: still prose-only [$err]"; fi
  # P: HTML comment skip dropped from the field parser -> 2s goes red
  if mutate P 's/c{if (\/-->\/) c=0; next} \/\^(-/\/^(-/'; then
    nq "$MUT" "$TMP/q-cmt" --queue
    [ "$out" = "NEXT | low | G3 third gap" ] && ok "teeth P: comment field honoured -> 2s has teeth" || no "teeth P: want the comment field honoured, got [$out]"; fi
  # Q: duplicate-id WARN dropped -> 2p goes red
  if mutate Q 's/if \[ "\$dup" = 1 \]; then printf/if false; then printf/'; then
    nq "$MUT" "$TMP/q-dup" --queue
    ! grep -q 'queue-duplicate-id' <<<"$err" && ok "teeth Q: duplicate unnoticed -> 2p has teeth" || no "teeth Q: still warned [$err]"; fi
  # R: trailing-comma check dropped -> 2o goes red
  if mutate R 's/^  case "\$val" in \*,) printf/  case "$val" in zzz-never) printf/'; then
    nq "$MUT" "$TMP/q-trail" --queue
    [ "$out" = "NEXT | low | G3 third gap" ] && ok "teeth R: trailing comma accepted -> 2o has teeth" || no "teeth R: want accepted, got [$out]"; fi
  # S: NONE matched case-sensitively -> 2q goes red
  if mutate S 's/case "\${val,,}" in/case "${val}" in/'; then
    nq "$MUT" "$TMP/q-NONE" --queue
    ! grep -q 'queue-empty' <<<"$err" && ok "teeth S: case-sensitive none -> 2q has teeth" || no "teeth S: still queue-empty [$err]"; fi
  # T: open-deferred scan not limited to Gap-backlog sections -> 2v goes red
  if mutate T 's/^      ib { pr=tolower/      { pr=tolower/'; then
    nq "$MUT" "$TMP/q-oob" --queue
    ! grep -q 'queue-unknown-gap' <<<"$err" && ok "teeth T: deferred row outside the backlog read -> 2v has teeth" || no "teeth T: still unknown [$err]"; fi
  # U: 5-column open deferred rows dropped -> 2t goes red
  if mutate U 's/(NF!=6 \&\& NF!=7)/(NF!=6)/'; then
    nq "$MUT" "$mk5" --queue
    grep -q 'queue-unknown-gap' <<<"$err" && ok "teeth U: 5-col deferred unread -> 2t has teeth" || no "teeth U: mutant still knew it [$err]"; fi
  # W: ambiguity warning dropped -> 2w goes red
  if mutate W 's/if \[ "\$nmatch" -gt 1 \]; then/if [ "$nmatch" -gt 99 ]; then/'; then
    nq "$MUT" "$TMP/q-amb1" --queue
    ! grep -q 'queue-ambiguous-id' <<<"$err" && ok "teeth W: ambiguity unreported -> 2w has teeth" || no "teeth W: still warned [$err]"; fi
  # X: scan stops at the first servable row -> a second match is not counted (pending-first order) -> 2w goes red
  if mutate X 's/cls=serve; continue$/cls=serve; break/'; then
    nq "$MUT" "$TMP/q-amb2" --queue
    ! grep -q 'queue-ambiguous-id' <<<"$err" && ok "teeth X: break at the served row hides a second match -> 2w has teeth" || no "teeth X: still warned [$err]"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
