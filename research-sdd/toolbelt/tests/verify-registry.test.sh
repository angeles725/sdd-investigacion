#!/usr/bin/env bash
# verify-registry.test.sh — end-to-end harness for verify-registry.sh, which is a SHIM to `rsdd verify registry`
# (kit issues #2362/#2364). The script reconciles the MASTER registry (KIT/TARGETS.md) against the REAL corpora,
# WARN-only; a throwaway COPY of the shim runs inside a sandbox kit (KIT = the copy's toolbelt/..) against the
# real Go binary (RSDD_BIN, else one build into the temp dir).
#
# Contract pinned here, through the shim:
#   * claimed 'N md' vs the real on-disk block count (tolerance boundary, nested layouts, truncated '...' rows,
#     unresolvable corpora, catalog freshness, retro reconciliation, maturity-cell schema, hook claims, the
#     attention counter, the opt-in SessionStart budget check);
#   * operational failures (missing TARGETS.md, every registered directory absent) → exit 1; advisory findings → exit 0;
#   * the SHIM itself: its kit hand-off, argument pass-through, a missing lib and an unusable binary (cases S1-S5).
# The report is also pinned byte for byte against the frozen bash script by the Go differential tests
# (research-sdd/rsdd/internal/verify: registry_diff_test.go, registry_prod_diff_test.go), and the mutation gate of the
# Go source is `make teeth`. Cases that needed the old script's internals are gone with them, each with its Go
# counterpart: a broken or absent lib/ helper (cases 20-20e, 46, 48, 49: no helper is sourced any more), the awk-failure
# degraded script state (3t: TestRegistryHookSections "yes-script-degraded") and the stubbed session-budget readings
# (2129d/e/g: TestRegistrySessionBudget and TestRegistrySessionBudgetThroughRunner).
# --prove-teeth mutates the SHIM (each mutant must lose its case).
#
# Usage: verify-registry.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-registry.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  _vr_bin_dir="$(mktemp -d)"; trap 'rm -rf "${_vr_bin_dir:-}"' EXIT   # cleaned even when the build below fails
  ( cd "$HERE/../../rsdd" && go build -o "$_vr_bin_dir/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$_vr_bin_dir/rsdd"
fi
# The clean verdict line, anchored at line start.
VR_CLEAN='^Registry consistent with reality'
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "${_vr_bin_dir:-}"' EXIT
# HERMETICITY (kit issue #1140 round-2 review, Blocking 4): lib/hook-wiring.sh's git-root walk-up
# climbs from a target to `/` unless RSDD_HOOK_WIRING_CEILING is set. Fixture 3l and its mutation
# tooth `git init` a target under $ROOT; without this, a $TMPDIR that happens to sit inside a real
# repo (this kit checkout, for instance) would let an ENCLOSING repo's .git bleed into the fixture.
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"
export RSDD_HOOK_WIRING_CEILING
# HERMETICITY (kit issue #1157): the launch-history check reads ~/.claude/projects. Point it at a root
# that does not exist so every case sees launch state "unknown" (silent) unless it opts in via nsrun.
RSDD_CLAUDE_PROJECTS_DIR="$ROOT/no-claude-history"
export RSDD_CLAUDE_PROJECTS_DIR
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
# vr_bw_gate: usable | skip | fail (kit issue #2138). `fail` = RSDD_REQUIRE_BWRAP=1 but bwrap/timeout unusable.
vr_bw_gate() {
  if command -v bwrap >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && bwrap --ro-bind / / true >/dev/null 2>&1; then echo usable
  elif [ "${RSDD_REQUIRE_BWRAP:-}" = 1 ]; then echo fail; else echo skip; fi
}
# Probe-only self-invocation (see the 2129a gate self-test): print the gate state and exit before any case runs.
if [ -n "${VR_BW_GATE_PROBE:-}" ]; then _g="$(vr_bw_gate)"; echo "gate=$_g"; [ "$_g" = fail ] && exit 1; exit 0; fi


# mkkit <name> : lay down a runnable COPY of the SUT and its shared helper at <ROOT>/<name>/toolbelt/
# so KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  rsdd_stage_libs "$kit/toolbelt"   # every lib the SUT sources (retro-status, target-paths, block-files, state-files, corpus-markers, hook-wiring)
  cp "$SUT" "$kit/toolbelt/verify-registry.sh"
  printf '%s' "$kit"
}

# wire_hook <target-dir> : write a Stop-hook-wired .claude/settings.json under <target-dir>, so a
# fixture whose row claims 'hook yes' reconciles cleanly against the new hook-wiring check (#1108).
wire_hook() { mkdir -p "$1/.claude"; printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}' > "$1/.claude/settings.json"; }

# mkcorpus <corpus-dir> <nblocks> <prefix> : create a resolvable corpus — a RESEARCH-STATE.md at its
# root (the archive/verify-state anchor) plus <nblocks> canonical block files `<prefix>-block<i>.md`.
mkcorpus() {
  local dir="$1" n="$2" prefix="$3" i=0
  mkdir -p "$dir"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: %d\n<!-- /research-state.v1 -->\n' "$n" > "$dir/RESEARCH-STATE.md"
  while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '# Block %d\n' "$i" > "$dir/${prefix}-block${i}.md"; done
}

# write_targets <kit> <spec...> : minimal TARGETS.md. Each spec is "<path>::<claim>" where <claim> is a
# maturity phrase such as "5 md" (or "-" to omit the count). The path is backtick-wrapped (the only thing
# the SUT resolves out of the table).
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    # Row 0: kit self-registration (nc — not a corpus target). Claimed 0 md; real will be
    # 1 (TARGETS.md) → diff=1 ≤ tol=2 → no drift WARN. KIT-SELF-REG check finds the kit
    # path here and stays silent.
    printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
    local i=0 spec p claim
    for spec in "$@"; do
      i=$((i+1)); p="${spec%%::*}"; claim="${spec#*::}"
      if [ "$claim" = "-" ]; then
        printf '| %d | t%d | mature | `%s` |\n' "$i" "$i" "$p"
      else
        printf '| %d | t%d | mature (%s / git yes) | `%s` |\n' "$i" "$i" "$claim" "$p"
      fi
    done
  } > "$kit/TARGETS.md"
}

run() { OUT="$("$BASH_BIN" "$1/toolbelt/verify-registry.sh" 2>&1)"; RC=$?; }

echo "== verify-registry.test.sh (SUT: $(basename "$SUT")) =="

# 1 — MATCH: claimed 'N md' equals real block count → no drift WARN, 'consistent' summary, exit 0.
#      Target is OUTSIDE the kit sandbox so the kit nc row scan doesn't find RESEARCH-STATE.md.
kit="$(mkkit c1-match)"; tgt="$ROOT/c1-ext-tgt"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'refresh the row' <<<"$OUT" \
   && grep -q 'Summary: reconciled 2 target' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "1 claimed==real → no drift WARN, consistent" "(exit $RC)"
else
  no "1 claimed==real → no drift WARN, consistent" "exit=$RC out=[$OUT]"
fi

# 2 — DRIFT beyond tolerance: claim 40 md, real 5 → drift WARN naming target + both counts, exit 0.
kit="$(mkkit c2-drift)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::40 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA .* claims 40 md but the corpus has 5 real block' <<<"$OUT" \
   && grep -q '1 count drift' <<<"$OUT"; then
  ok "2 claim 40 vs real 5 → drift WARN, exit 0" "(exit $RC)"
else
  no "2 claim 40 vs real 5 → drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 3 — NESTED layout: corpus lives at <target>/corpus/ (research-sdd-init.sh's OWN canonical
#     nested convention — see lib/corpus-markers.sh). Row registers the ROOT path; the SUT must
#     resolve the corpus via corpus/RESEARCH-STATE.md and count the nested blocks. Claim matches
#     → no drift, proving nested resolution (a flat <target>/*.md count would see ZERO and false-drift).
#     Renamed from <target>/research/ (kit issue #1108): that shape is EXACTLY the three.js repro
#     — a registered path with no marker at $p or $p/corpus, resolvable only via the deep
#     maxdepth-3 search — so it now correctly WARNs (see test 3c below) and can no longer double
#     as "the canonical clean case". <target>/corpus/ carries a marker research-sdd-init.sh's own
#     --wire guard recognises, so this fixture stays a genuine no-WARN nested-resolution proof.
kit="$(mkkit c3-nested)"; tgt="$ROOT/c3-ext-tgt"
mkcorpus "$tgt/corpus" 6 "n"             # → $tgt/corpus/RESEARCH-STATE.md + 6 blocks
write_targets "$kit" "$tgt::6 md"        # registers the ROOT, not corpus/
run "$kit"
if [ "$RC" = 0 ] \
   && [ ! -e "$tgt/RESEARCH-STATE.md" ] \
   && ! grep -q 'refresh the row' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "3 nested corpus/ layout → resolved + counted (no false drift, no marker WARN)" "(exit $RC)"
else
  no "3 nested corpus/ layout → resolved + counted (no false drift, no marker WARN)" "exit=$RC out=[$OUT]"
fi

# 3b — NESTED + DRIFT: same nested layout but claim 99 md vs real 6 → the drift WARN fires with the NESTED
#      count (6), proving the resolver both walks into corpus/ AND recounts there (teeth on nested path).
kit="$(mkkit c3b-nesteddrift)"; tgt="$kit/targetN"
mkcorpus "$tgt/corpus" 6 "n"
write_targets "$kit" "$tgt::99 md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE 'WARN[[:space:]]+targetN .* claims 99 md but the corpus has 6 real block' <<<"$OUT"; then
  ok "3b nested + claim 99 → drift names nested count 6" "(exit $RC)"
else
  no "3b nested + claim 99 → drift names nested count 6" "exit=$RC out=[$OUT]"
fi

# --- kit issue #1108: REGISTERED-PATH MARKER CHECK -------------------------------------------------

# 3c — MARKER: three.js repro shape — corpus nested TWO levels down (<target>/sub/research/), the
#      registered path itself has NO marker at $p or $p/corpus. The deep maxdepth-3 resolver still
#      finds and counts the corpus correctly (no false drift), but the NEW marker WARN fires, and
#      the clean 'Registry consistent with reality' line is ABSENT (attention > 0).
kit="$(mkkit c3c-nomarker)"; tgt="$kit/targetA"
mkcorpus "$tgt/sub/research" 4 "a"       # → $tgt/sub/research/RESEARCH-STATE.md (2 levels deep)
write_targets "$kit" "$tgt::4 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA — registered path has no corpus marker' <<<"$OUT" \
   && grep -qF "no INDEX.md/CATALOG.md/RESEARCH-STATE*.md at ${tgt} or ${tgt}/corpus" <<<"$OUT" \
   && ! grep -q 'refresh the row' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "3c three.js-shape corpus (2 levels deep, no marker at \$p/\$p/corpus) → marker WARN, no false drift" "(exit $RC)"
else
  no "3c three.js-shape corpus (2 levels deep, no marker at \$p/\$p/corpus) → marker WARN, no false drift" "exit=$RC out=[$OUT]"
fi

# 3d — MARKER: nc-flagged row with NO corpus marker anywhere → the marker check is SKIPPED (nc
#      means "not a corpus" by definition — a tooling/production-app target legitimately has none).
kit="$(mkkit c3d-ncnomarker)"; tgt="$kit/targetA"
mkdir -p "$tgt"; printf 'x' > "$tgt/readme.md"   # no RESEARCH-STATE/INDEX/CATALOG anywhere
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | intermediate (1 md / nc / git no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'no corpus marker' <<<"$OUT"; then
  ok "3d nc row with no corpus marker → marker check skipped (nc exempt)" "(exit $RC)"
else
  no "3d nc row with no corpus marker → marker check skipped (nc exempt)" "exit=$RC out=[$OUT]"
fi

# --- kit issue #1108: HOOK-WIRING RECONCILIATION CHECK ----------------------------------------------

# 3e — HOOK-WIRING: row claims 'hook yes' and the target's Stop hook IS wired to retro-gate →
#      no hook-wiring WARN (positive control — proves the check is not unconditionally noisy).
kit="$(mkkit c3e-hookwired)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook is' <<<"$OUT"; then
  ok "3e hook yes + actually wired → no hook-wiring WARN" "(exit $RC)"
else
  no "3e hook yes + actually wired → no hook-wiring WARN" "exit=$RC out=[$OUT]"
fi

# 3f — HOOK-WIRING: row claims 'hook yes' but target has NO .claude/settings.json at all →
#      WARN naming the absent-settings state (kit issue #1108's own three.js repro: 'git yes /
#      hook yes' claimed, no .claude/ present at all).
kit="$(mkkit c3f-hookabsent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE "WARN[[:space:]]+targetA — row claims 'hook yes' but the Stop hook is absent-settings" <<<"$OUT"; then
  ok "3f hook yes + no .claude/settings.json → hook-wiring WARN names absent-settings" "(exit $RC)"
else
  no "3f hook yes + no .claude/settings.json → hook-wiring WARN names absent-settings" "exit=$RC out=[$OUT]"
fi

# 3g — HOOK-WIRING: row claims 'hook yes' but settings.json exists WITHOUT a retro-gate Stop
#      entry → WARN naming the unwired state (distinct from absent-settings, §7 three-state).
kit="$(mkkit c3g-hookunwired)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
mkdir -p "$tgt/.claude"; printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"some-other-hook.sh"}]}]}}' > "$tgt/.claude/settings.json"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE "WARN[[:space:]]+targetA — row claims 'hook yes' but the Stop hook is unwired" <<<"$OUT"; then
  ok "3g hook yes + settings.json without retro-gate → hook-wiring WARN names unwired" "(exit $RC)"
else
  no "3g hook yes + settings.json without retro-gate → hook-wiring WARN names unwired" "exit=$RC out=[$OUT]"
fi

# 3h — HOOK-WIRING: row claims 'hook no' and the target is genuinely unwired → NO hook-wiring
#      WARN (the check only reconciles the SPECIFIC 'hook yes' claim, per the TARGETS.md legend —
#      'hook no' never asserts active wiring, so there is nothing to contradict).
kit="$(mkkit c3h-hookno)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook is' <<<"$OUT"; then
  ok "3h hook no + unwired target → no hook-wiring WARN (claim never asserted wiring)" "(exit $RC)"
else
  no "3h hook no + unwired target → no hook-wiring WARN (claim never asserted wiring)" "exit=$RC out=[$OUT]"
fi

# 3i — HOOK-WIRING: row claims 'hook file yes / unregistered' (which ALREADY admits it is not
#      wired) and the target is unwired → NO hook-wiring WARN — this token starts with 'hook
#      file', not 'hook yes', so it must not be mistaken for the active-wiring claim.
kit="$(mkkit c3i-hookfileyes)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook file yes / unregistered) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook is' <<<"$OUT"; then
  ok "3i hook file yes / unregistered → no hook-wiring WARN (not the 'hook yes' claim)" "(exit $RC)"
else
  no "3i hook file yes / unregistered → no hook-wiring WARN (not the 'hook yes' claim)" "exit=$RC out=[$OUT]"
fi

# 3j — HOOK-WIRING: decorated claim form 'hook yes ×2' (legend-documented variant) still matches
#      the active-wiring assertion — unwired target still WARNs.
kit="$(mkkit c3j-hookyesx2)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes ×2) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE "WARN[[:space:]]+targetA — row claims 'hook yes ×2' but the Stop hook is absent-settings" <<<"$OUT"; then
  ok "3j decorated 'hook yes ×2' claim → still reconciled, hook-wiring WARN fires" "(exit $RC)"
else
  no "3j decorated 'hook yes ×2' claim → still reconciled, hook-wiring WARN fires" "exit=$RC out=[$OUT]"
fi

# 3k — HOOK-CLAIM word-boundary: 'hook yesterday' must NOT match the 'hook yes' claim (word
#      boundary after 'yes' — kit issue #1108 round 2: a mutant that drops the boundary class
#      still passed the suite, so this fixture is the negative control that pins it). Target is
#      unwired (no .claude/ at all); if the boundary were dropped, this would false-WARN.
kit="$(mkkit c3k-hookyesterday)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yesterday) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook is' <<<"$OUT"; then
  ok "3k 'hook yesterday' claim → word boundary rejects it, no hook-wiring WARN" "(exit $RC)"
else
  no "3k 'hook yesterday' claim → word boundary rejects it, no hook-wiring WARN" "exit=$RC out=[$OUT]"
fi

# 3l — kit issue #1135 (three.js shape): row claims 'hook yes' and settings.json IS Stop-scoped-
#      wired at the registered path, but that path is NOT its own git root (git root is a DIFFERENT,
#      higher directory) → a TAILORED wired-off-root WARN, distinct from the generic 'Stop hook is
#      <state>' wording 3f/3g/3j pin: it names the real cause (settings.json IS already wired) and
#      defers to the maintainer to confirm which directory sessions actually launch from (kit issue
#      #1140 round-2 review, Blocking 1 — an earlier revision prescribed "move the hook registration
#      to the git root", which is wrong for the one real case this has ever flagged: three.js
#      sessions launch from neither the registered path nor its git root).
kit="$(mkkit c3l-hookoffroot)"; gitroot="$kit/repo"; tgt="$gitroot/targetA"
mkcorpus "$tgt" 3 "a"
git init -q "$gitroot" >/dev/null 2>&1
wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE "WARN[[:space:]]+targetA — row claims 'hook yes' but ${tgt} is not its own git root" <<<"$OUT" \
   && grep -q 'Confirm which directory sessions actually launch from' <<<"$OUT" \
   && ! grep -q 'move the hook registration to the git root' <<<"$OUT" \
   && ! grep -qE "Stop hook is wired-off-root at" <<<"$OUT"; then
  ok "3l hook yes + wired-off-root → tailored WARN (not the generic 'Stop hook is <state>' wording, no prescribed fix)" "(exit $RC)"
else
  no "3l hook yes + wired-off-root → tailored WARN" "exit=$RC out=[$OUT]"
fi

# --- kit issue #1157: REGISTERED-NEVER-LOADED — a Stop hook registered in settings.json whose script
#     does not exist can never load. It is its OWN finding kind, never folded into 'wired' (silent) or
#     the generic 'Stop hook is <state>' wording.
wire_hook_abs() { mkdir -p "$1/.claude"; printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"%s"}]}]}}' "$2" > "$1/.claude/settings.json"; }

# 3q — 'hook yes' + registered, script file ABSENT → tailored never-loaded WARN, counted as attention.
kit="$(mkkit c3q-neverloaded)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook_abs "$tgt" "$tgt/.claude/hooks/retro-gate-stop.sh"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE "WARN[[:space:]]+targetA — row claims 'hook yes' and the Stop hook is registered at ${tgt}/.claude/settings.json but EVERY registered retro-gate command names a script that does not exist" <<<"$OUT" \
   && grep -q 'registered-never-loaded' <<<"$OUT" \
   && ! grep -q 'Stop hook is wired' <<<"$OUT" && ! grep -qE "but the Stop hook is [a-z-]+ at" <<<"$OUT" \
   && ! grep -qE '· 0 attention\.' <<<"$OUT"; then
  ok "3q hook yes + registered but script missing → own registered-never-loaded WARN + attention" "(exit $RC)"
else
  no "3q hook yes + registered but script missing → own registered-never-loaded WARN" "exit=$RC out=[$OUT]"
fi

# 3r — positive control: same registration, script EXISTS → no never-loaded WARN.
kit="$(mkkit c3r-scriptpresent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; mkdir -p "$tgt/.claude/hooks"; : > "$tgt/.claude/hooks/retro-gate-stop.sh"
wire_hook_abs "$tgt" "\$CLAUDE_PROJECT_DIR/.claude/hooks/retro-gate-stop.sh"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'registered-never-loaded' <<<"$OUT" && ! grep -q 'Stop hook is' <<<"$OUT"; then
  ok "3r hook yes + script exists → no never-loaded WARN" "(exit $RC)"
else
  no "3r hook yes + script exists → no never-loaded WARN" "exit=$RC out=[$OUT]"
fi

# 3s' — 'hook no' + registered with a missing script: the row's claim (no usable hook) is consistent,
#       so the reverse check must NOT fire (it stays strict on a script that can load).
kit="$(mkkit c3s2-hookno-neverloaded)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook_abs "$tgt" "$tgt/.claude/hooks/retro-gate-stop.sh"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook IS wired' <<<"$OUT" && ! grep -q 'registered-never-loaded' <<<"$OUT"; then
  ok "3s2 hook no + registered-but-script-missing → no reverse WARN, no never-loaded WARN" "(exit $RC)"
else
  no "3s2 hook no + registered-but-script-missing → no reverse WARN" "exit=$RC out=[$OUT]"
fi

# 3s3 / 3s4 — the reverse-check skip needs a FIRM 'missing' (every entry resolved). An unverifiable
#      registration (spaces without quotes, unresolved variable) or missing + unverifiable must still
#      WARN the contradiction: absence of proof is not proof of absence.
for _c in "s3:bash $PWD/not quoted/retro-gate-stop.sh" "s4:\$UNKNOWN_DIR/retro-gate-stop.sh"; do
  kit="$(mkkit "c3${_c%%:*}-hookno-unverifiable")"; tgt="$kit/targetA"
  mkcorpus "$tgt" 3 "a"; wire_hook_abs "$tgt" "${_c#*:}"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | targetA | mature (3 md / git yes / hook no) | `%s` |\n' "$tgt"
  } > "$kit/TARGETS.md"
  run "$kit"
  if [ "$RC" = 0 ] && grep -q 'Stop hook IS wired' <<<"$OUT"; then
    ok "3${_c%%:*} hook no + unverifiable registration → reverse WARN still fires" "(exit $RC)"
  else
    no "3${_c%%:*} hook no + unverifiable registration → reverse WARN still fires" "exit=$RC out=[$OUT]"
  fi
done
kit="$(mkkit c3s5-hookno-mixed)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; mkdir -p "$tgt/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"%s/gone/retro-gate-a.sh"},{"command":"retro-gate-b"}]}]}}' "$tgt" > "$tgt/.claude/settings.json"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3s5 hook no + one missing + one unresolvable entry → reverse WARN still fires" "(exit $RC)"
else
  no "3s5 hook no + one missing + one unresolvable entry → reverse WARN still fires" "exit=$RC out=[$OUT]"
fi
# 3s6 — 'hook yes' + one missing + one present entry: any present wins → no never-loaded WARN.
kit="$(mkkit c3s6-anypresent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; mkdir -p "$tgt/.claude"; : > "$tgt/ok-retro-gate.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"%s/gone/retro-gate-a.sh"},{"command":"%s/ok-retro-gate.sh"}]}]}}' "$tgt" "$tgt" > "$tgt/.claude/settings.json"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'registered-never-loaded' <<<"$OUT"; then
  ok "3s6 hook yes + one missing + one present entry → no never-loaded WARN (any present wins)" "(exit $RC)"
else
  no "3s6 hook yes + one missing + one present entry → no never-loaded WARN" "exit=$RC out=[$OUT]"
fi


# --- kit issue #1157: REGISTERED-NO-SESSIONS — the hook is registered and its script exists, but no
#     session was ever launched from exactly the target directory (project settings load from the launch
#     directory only), so it has never been loaded. History root = $RSDD_CLAUDE_PROJECTS_DIR (test seam,
#     exported absent at the top of this file → launch 'unknown' → silent for every older case).
# nsrun <history-root|-> <kit> : run the SUT with the history root pointed at a fixture ('-' = absent).
nsrun() { local h="$1"; [ "$h" = "-" ] && h="$ROOT/no-claude-history"; RSDD_CLAUDE_PROJECTS_DIR="$h" run "$2"; }
# nshist <history-root> <target> [transcript] : create the history root and (optionally) a transcript for target.
nshist() { mkdir -p "$1"; if [ -n "${3:-}" ]; then mkdir -p "$1/${2//[^A-Za-z0-9]/-}"; : > "$1/${2//[^A-Za-z0-9]/-}/s1.jsonl"; fi; }
# nsrow <kit> <target> <cell> : one-row TARGETS.md.
nsrow() { { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'; printf '| 1 | targetA | mature (%s) | `%s` |\n' "$3" "$2"; } > "$1/TARGETS.md"; }
# nsfix <name> : kit + target with a registered, EXISTING hook script; echoes nothing, sets kit/tgt.
nsfix() { kit="$(mkkit "$1")"; tgt="$kit/targetA"; mkcorpus "$tgt" 3 "a"; mkdir -p "$tgt/.claude/hooks"; : > "$tgt/.claude/hooks/retro-gate-stop.sh"; chmod +x "$tgt/.claude/hooks/retro-gate-stop.sh"; wire_hook_abs "$tgt" "\$CLAUDE_PROJECT_DIR/.claude/hooks/retro-gate-stop.sh"; }

# 3ns1 — 'hook yes' + registered + script exists + history root readable but no transcript for the target.
nsfix c3ns1; hist="$ROOT/h-ns1"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" '3 md / git yes / hook yes'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] \
   && grep -qE "WARN[[:space:]]+targetA — row claims 'hook yes' and the Stop hook is registered at ${tgt}/.claude/settings.json, but there is no retained Claude Code transcript for a session launched from exactly ${tgt}" <<<"$OUT" \
   && grep -q "hook file yes / registered-no-sessions" <<<"$OUT" \
   && ! grep -qE '· 0 attention\.' <<<"$OUT" && ! grep -q "$VR_CLEAN" <<<"$OUT"; then
  ok "3ns1 hook yes + registered + no sessions → registered-no-sessions WARN + attention" "(exit $RC)"
else no "3ns1 hook yes + registered + no sessions → registered-no-sessions WARN" "exit=$RC out=[$OUT]"; fi

# 3ns2 — same, with a transcript for the target → no WARN (the hook has loaded).
nsfix c3ns2; hist="$ROOT/h-ns2"; nshist "$hist" "$tgt" t; nsrow "$kit" "$tgt" '3 md / git yes / hook yes'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && ! grep -q 'registered-no-sessions' <<<"$OUT" && ! grep -q 'Stop hook is' <<<"$OUT"; then
  ok "3ns2 hook yes + registered + sessions exist → no registered-no-sessions WARN" "(exit $RC)"
else no "3ns2 hook yes + sessions exist → no WARN" "exit=$RC out=[$OUT]"; fi

# 3ns3 — launch 'unknown' (history root absent) → NO claim (a machine without Claude history must not WARN).
nsfix c3ns3; nsrow "$kit" "$tgt" '3 md / git yes / hook yes'; nsrun - "$kit"
if [ "$RC" = 0 ] && ! grep -q 'registered-no-sessions' <<<"$OUT"; then
  ok "3ns3 hook yes + history root absent (launch unknown) → silent, no claim" "(exit $RC)"
else no "3ns3 launch unknown → silent" "exit=$RC out=[$OUT]"; fi

# 3ns4 — 'hook yes' + script MISSING + no sessions: only registered-never-loaded (the stronger fact).
kit="$(mkkit c3ns4)"; tgt="$kit/targetA"; mkcorpus "$tgt" 3 "a"; wire_hook_abs "$tgt" "$tgt/.claude/hooks/retro-gate-stop.sh"
hist="$ROOT/h-ns4"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" '3 md / git yes / hook yes'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && grep -q 'registered-never-loaded' <<<"$OUT" && ! grep -q 'registered-no-sessions' <<<"$OUT"; then
  ok "3ns4 hook yes + script missing + no sessions → only registered-never-loaded" "(exit $RC)"
else no "3ns4 script missing + no sessions → only never-loaded" "exit=$RC out=[$OUT]"; fi

# 3ns5 — wired-off-root + no sessions: BOTH the structural off-root WARN and the no-sessions WARN (additive).
kit="$(mkkit c3ns5)"; gitroot="$kit/repo"; tgt="$gitroot/targetA"; mkcorpus "$tgt" 3 "a"; git init -q "$gitroot" >/dev/null 2>&1
mkdir -p "$tgt/.claude/hooks"; : > "$tgt/.claude/hooks/retro-gate-stop.sh"; wire_hook_abs "$tgt" "$tgt/.claude/hooks/retro-gate-stop.sh"
hist="$ROOT/h-ns5"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" '3 md / git yes / hook yes'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && grep -q 'is not its own git root' <<<"$OUT" && grep -q 'registered-no-sessions' <<<"$OUT"; then
  ok "3ns5 hook yes + off-root + no sessions → off-root WARN and registered-no-sessions WARN" "(exit $RC)"
else no "3ns5 off-root + no sessions → both WARNs" "exit=$RC out=[$OUT]"; fi

# 3ns6 — 'hook file yes / unregistered' + hook IS registered + no sessions → unregistered-stale naming
#        'registered-no-sessions'; the token order inside the cell (first / middle / last) is irrelevant.
for _cell in 'hook file yes / unregistered / git yes' '3 md / hook file yes / unregistered / git yes' '3 md / git yes / hook file yes / unregistered'; do
  nsfix c3ns6; hist="$ROOT/h-ns6"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" "$_cell"; nsrun "$hist" "$kit"
  if [ "$RC" = 0 ] \
     && grep -qE "WARN[[:space:]]+targetA — row claims 'unregistered' but the Stop hook IS registered at ${tgt}/.claude/settings.json" <<<"$OUT" \
     && grep -q "the accurate token is 'registered-no-sessions'" <<<"$OUT" && ! grep -q "accurate claim is likely 'hook yes'" <<<"$OUT" \
     && ! grep -q "$VR_CLEAN" <<<"$OUT"; then
    ok "3ns6 [$_cell] → unregistered-stale, cure registered-no-sessions" "(exit $RC)"
  else no "3ns6 [$_cell] → unregistered-stale, cure registered-no-sessions" "exit=$RC out=[$OUT]"; fi
done

# 3ns7 — same row, sessions exist → cure is 'hook yes'.
nsfix c3ns7; hist="$ROOT/h-ns7"; nshist "$hist" "$tgt" t; nsrow "$kit" "$tgt" '3 md / git yes / hook file yes / unregistered'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && grep -q "a retained Claude Code transcript exists for a session launched from exactly ${tgt}" <<<"$OUT" && grep -q "accurate claim is likely 'hook yes'" <<<"$OUT"; then
  ok "3ns7 unregistered row + registered + sessions exist → cure is hook yes" "(exit $RC)"
else no "3ns7 unregistered + sessions → hook yes" "exit=$RC out=[$OUT]"; fi

# 3ns8 — same row, launch unknown → still a WARN (the registration alone contradicts 'unregistered'), naming launch unknown.
nsfix c3ns8; nsrow "$kit" "$tgt" '3 md / git yes / hook file yes / unregistered'; nsrun - "$kit"
if [ "$RC" = 0 ] && grep -q 'launch unknown' <<<"$OUT" && grep -q "row claims 'unregistered' but the Stop hook IS registered" <<<"$OUT"; then
  ok "3ns8 unregistered row + registered + launch unknown → WARN naming launch unknown" "(exit $RC)"
else no "3ns8 unregistered + launch unknown → WARN" "exit=$RC out=[$OUT]"; fi

# 3ns9 — 'unregistered' row whose hook is genuinely NOT registered (no settings) → silent, consistent.
kit="$(mkkit c3ns9)"; tgt="$kit/targetA"; mkcorpus "$tgt" 3 "a"; hist="$ROOT/h-ns9"; nshist "$hist" "$tgt"
nsrow "$kit" "$tgt" '3 md / git yes / hook file yes / unregistered'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && ! grep -q "row claims 'unregistered'" <<<"$OUT" && ! grep -q 'nonconform\|not in schema' <<<"$OUT"; then
  ok "3ns9 unregistered row + hook genuinely unregistered → silent" "(exit $RC)"
else no "3ns9 unregistered + unregistered → silent" "exit=$RC out=[$OUT]"; fi

# 3ns10 — 'unregistered' row + registered but script MISSING → silent (not this finding's claim).
kit="$(mkkit c3ns10)"; tgt="$kit/targetA"; mkcorpus "$tgt" 3 "a"; wire_hook_abs "$tgt" "$tgt/.claude/hooks/retro-gate-stop.sh"
hist="$ROOT/h-ns10"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" '3 md / git yes / hook file yes / unregistered'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && ! grep -q "row claims 'unregistered'" <<<"$OUT"; then
  ok "3ns10 unregistered row + registered-but-script-missing → silent" "(exit $RC)"
else no "3ns10 unregistered + script missing → silent" "exit=$RC out=[$OUT]"; fi

# 3ns11 — 'hook file yes' WITHOUT unregistered/registered-no-sessions, registered → out of scope, silent.
nsfix c3ns11; hist="$ROOT/h-ns11"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" '3 md / git yes / hook file yes'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && ! grep -q 'registered-no-sessions\|row claims' <<<"$OUT"; then
  ok "3ns11 bare 'hook file yes' + registered → out of scope, silent" "(exit $RC)"
else no "3ns11 bare hook file yes → silent" "exit=$RC out=[$OUT]"; fi

# 3ns12 — the NEW token is accepted by the maturity-cell schema, and a consistent row is clean.
nsfix c3ns12; hist="$ROOT/h-ns12"; nshist "$hist" "$tgt"; nsrow "$kit" "$tgt" '3 md / git yes / hook file yes / registered-no-sessions'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && ! grep -q 'not in schema' <<<"$OUT" && ! grep -q 'no-sessions-stale\|row claims' <<<"$OUT" && ! grep -qE '^WARN[[:space:]]+targetA' <<<"$OUT"; then
  ok "3ns12 registered-no-sessions row + registered + no sessions → schema-accepted, no WARN on the target" "(exit $RC)"
else no "3ns12 consistent registered-no-sessions row → clean" "exit=$RC out=[$OUT]"; fi

# 3ns13 — a registered-no-sessions row, but sessions now exist → stale.
nsfix c3ns13; hist="$ROOT/h-ns13"; nshist "$hist" "$tgt" t; nsrow "$kit" "$tgt" 'hook file yes / registered-no-sessions / 3 md'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && grep -qE "WARN[[:space:]]+targetA — row claims 'registered-no-sessions' but a retained Claude Code transcript now exists" <<<"$OUT" && ! grep -q "$VR_CLEAN" <<<"$OUT"; then
  ok "3ns13 registered-no-sessions row + sessions exist → stale WARN" "(exit $RC)"
else no "3ns13 registered-no-sessions + sessions → stale" "exit=$RC out=[$OUT]"; fi

# 3ns14 — a registered-no-sessions row, but the hook is no longer registered → stale.
kit="$(mkkit c3ns14)"; tgt="$kit/targetA"; mkcorpus "$tgt" 3 "a"; hist="$ROOT/h-ns14"; nshist "$hist" "$tgt"
nsrow "$kit" "$tgt" '3 md / git yes / hook file yes / registered-no-sessions'; nsrun "$hist" "$kit"
if [ "$RC" = 0 ] && grep -qE "row claims 'registered-no-sessions' but the Stop hook is not registered with a loadable script" <<<"$OUT" && grep -q 'wiring absent-settings' <<<"$OUT"; then
  ok "3ns14 registered-no-sessions row + hook not registered → stale WARN naming the wiring state" "(exit $RC)"
else no "3ns14 registered-no-sessions + unregistered → stale" "exit=$RC out=[$OUT]"; fi

# --- kit issue #1128: SYMMETRIC HOOK-WIRING RECONCILIATION — the inverse direction of #1108 -----------
# A row claiming 'hook no' (no hook file at all) whose Stop hook IS actually wired is registry drift
# the OTHER way: the row UNDER-claims. 'hook file yes' claims are out of this check's scope (kit issue
# #1141 round 3; see 3n). WARN-only, propose-never-apply; TARGETS.md is never auto-edited — the
# maintainer refreshes the row by hand.

# 3m — REVERSE HOOK-WIRING: row claims 'hook no' but the target's Stop hook IS actually wired to
#      retro-gate → WARN naming the mismatch. Also asserts the 'attention' summary count and the
#      absence of the clean-verdict line (kit issue #1141 round-2 review, Blocking 2: manually
#      deleting the reverse check's 'attention=$((attention + 1))' left this suite green at 99/99 —
#      a fleet whose ONLY drift is reverse drift would then print "Registry consistent with
#      reality" underneath its own WARN. The target is placed OUTSIDE the sandbox kit dir (sibling
#      under $ROOT, not nested under $kit) and the kit registers ITSELF via write_targets, so
#      KIT-SELF-REG-CHECK and the nc-corpus-marker check both stay silent — the ONLY possible
#      source of 'attention' or an unresolved corpus-marker WARN in this fixture is the reverse
#      check itself, making 'exactly 1 attention, no consistent line' an unconfounded assertion.
kit="$(mkkit c3m-hooknowired)"; tgt="$ROOT/c3m-hooknowired-tgt/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
write_targets "$kit" "${tgt}::3 md / hook no"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE "WARN[[:space:]]+targetA — row claims 'hook no' but the Stop hook IS wired" <<<"$OUT" \
   && grep -qF '1 attention.' <<<"$OUT" \
   && ! grep -qF 'Registry consistent with reality' <<<"$OUT"; then
  ok "3m hook no + actually wired → reverse hook-wiring WARN fires, attention=1, not 'consistent'" "(exit $RC)"
else
  no "3m hook no + actually wired → reverse hook-wiring WARN fires, attention=1, not 'consistent'" "exit=$RC out=[$OUT]"
fi

# 3n — REVERSE HOOK-WIRING negative control (kit issue #1141 round-3 review, Blocking 1 —
#      INVERTED from a positive control in round 2): row claims 'hook file yes / unregistered'
#      and the target's Stop hook IS actually wired at its own path (own git root — plain
#      'wired', not 'wired-off-root') → must NOT WARN. 'hook file yes' claims are now entirely
#      out of the reverse check's scope (narrowed to 'hook no' only): per the TARGETS.md legend,
#      'hook file yes / unregistered' asserts the hook FILE exists but does not FIRE, which
#      depends on launch site (kit issue #1134) — a decision this tool does not make. Kit issue
#      #1147 deliberately set exactly this shape for 3 real fleet rows (fluke-177x-datos,
#      nave-panccadia, panccadia-3d-viewer); the round-2 version of this check WARNed on all 3,
#      each a false positive the maintainer could never clear (see kit issue #1157 for the
#      tracked follow-up on covering 'hook file yes' with a doctrine change first, per §6).
kit="$(mkkit c3n-hookfileyesnowarn)"; tgt="$ROOT/c3n-hookfileyesnowarn-tgt/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
write_targets "$kit" "${tgt}::3 md / hook file yes / unregistered"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3n hook file yes / unregistered + actually wired (own git root) → no reverse WARN (out of scope, not drift)" "(exit $RC)"
else
  no "3n hook file yes / unregistered + actually wired (own git root) → no reverse WARN (out of scope, not drift)" "exit=$RC out=[$OUT]"
fi

# 3o — REVERSE HOOK-WIRING negative control: row claims 'hook no' and the target is genuinely
#      unwired (no .claude/settings.json at all) → NO reverse WARN (positive control — proves the
#      check is not unconditionally noisy, symmetric to 3e).
kit="$(mkkit c3o-hooknounwired)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3o hook no + genuinely unwired → no reverse hook-wiring WARN" "(exit $RC)"
else
  no "3o hook no + genuinely unwired → no reverse hook-wiring WARN" "exit=$RC out=[$OUT]"
fi

# 3p — REVERSE HOOK-WIRING negative control: row claims 'hook yes' (the FORWARD claim, not 'hook
#      no') and is actually wired → the reverse check must NOT also fire (it would
#      be a nonsensical double-WARN for a row that is already consistent).
kit="$(mkkit c3p-hookyeswired)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3p hook yes + actually wired → no reverse hook-wiring WARN (row already consistent)" "(exit $RC)"
else
  no "3p hook yes + actually wired → no reverse hook-wiring WARN (row already consistent)" "exit=$RC out=[$OUT]"
fi

# 3q — REVERSE HOOK-CLAIM word-boundary: 'hook nonexistent' must NOT match the 'hook no' claim
#      (word boundary after 'no' — mirrors 3k's forward-direction pin). Target IS wired; if the
#      boundary were dropped, this would false-WARN.
kit="$(mkkit c3q-hooknonexistent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook nonexistent) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3q 'hook nonexistent' claim → word boundary rejects it, no reverse hook-wiring WARN" "(exit $RC)"
else
  no "3q 'hook nonexistent' claim → word boundary rejects it, no reverse hook-wiring WARN" "exit=$RC out=[$OUT]"
fi

# 3r — REVERSE HOOK-CLAIM inner whitespace (kit issue #1158 item 2): the old 3r fixture ('hook files
#      yes', a boundary control for the 'hook file yes' scope) became unfailable once the reverse
#      check was narrowed to 'hook no' only, and its comment was false. Replaced by a positive
#      control for the one whitespace shape the extraction still owns: 'hook   no' (several spaces
#      between the words, matched by '[[:space:]]+') on a wired target must still WARN.
kit="$(mkkit c3r-hookmultispace)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook   no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3r 'hook   no' (multi-space) claim → reverse hook-wiring WARN still fires" "(exit $RC)"
else
  no "3r 'hook   no' (multi-space) claim → reverse hook-wiring WARN still fires" "exit=$RC out=[$OUT]"
fi

# 3s — kit issue #1141 round-2 review, Blocking 1 (three.js shape), row claim UPDATED in round 3
#      to stay in the reverse check's now-narrower scope: a NESTED target — registered path is NOT
#      its own git root (git root is the PARENT directory) — whose settings.json IS Stop-scoped-
#      wired at the nested path, with the row claiming 'hook no'. Pins that the off-root exclusion
#      (strict '= "wired"', never 'wired-off-root') still applies now that the check only examines
#      'hook no' claims: this check does not decide where sessions actually launch from (kit issue
#      #1134), so a wired-off-root target stays out of scope the same way a wired-at-root one would
#      be IN scope. (Distinct from 3n above, which pins the separate 'hook file yes' scope
#      exclusion at a plain, own-git-root wired target.)
#
# Depended on kit issue #1135 (PR #1140, merged as b49c22e): lib/hook-wiring.sh's 'wired-off-root'
# state is what makes this fixture hold — hook_stop_wiring_state reports 'wired-off-root' (not
# plain 'wired') for a Stop-wired target whose registered path is not its own git root, and the
# reverse check's guard (verify-registry.sh's HOOK-WIRING-REVERSE-CHECK) is the strict '= "wired"'
# equality that excludes it.
kit="$(mkkit c3s-hookoffrootnowarn)"; gitroot="$kit/repo"; tgt="$gitroot/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
git init -q "$gitroot" >/dev/null 2>&1
write_targets "$kit" "${tgt}::3 md / hook no"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'Stop hook IS wired' <<<"$OUT"; then
  ok "3s nested off-git-root target, wired, 'hook no' claim → no reverse WARN (off-root exclusion still applies)" "(exit $RC)"
else
  no "3s nested off-git-root target, wired, 'hook no' claim → no reverse WARN (off-root exclusion still applies)" "exit=$RC out=[$OUT]"
fi

# 3t0 — POSITIVE CONTROL for 3t's negative check (kit issue #1696): the old 'HOOK NO' (uppercase)
#      row DOES trip NONCONFORM-FIELD-CHECK ('not in schema'), so 3t's `! grep 'not in schema'`
#      provably bites — without this a renamed WARN would leave 3t passing vacuously.
kit="$(mkkit c3t0-hooknouppercase-control)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / HOOK NO) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if grep -q 'not in schema' <<<"$OUT"; then
  ok "3t0 'HOOK NO' (uppercase) row → NONCONFORM 'not in schema' WARN (positive control for 3t)" "(exit $RC)"
else
  no "3t0 'HOOK NO' (uppercase) row → NONCONFORM 'not in schema' WARN (positive control for 3t)" "exit=$RC out=[$OUT]"
fi

# 3t — REVERSE HOOK-CLAIM case-insensitivity (kit issue #1141 round-3 review nit): row claims
#      'hook NO' (uppercase value) but the target's Stop hook IS actually wired → WARN still fires.
#      Case-insensitivity previously had no dedicated fixture or mutation tooth — 'grep -iE' →
#      'grep -E' left the suite fully green, so it was untested, not merely low-value. The token
#      is 'hook NO', not 'HOOK NO' (kit issue #1158 item 4): the maturity-schema check matches
#      '^hook[[:space:]]' case-sensitively, so 'HOOK NO' also tripped NONCONFORM-FIELD-CHECK and
#      the case-insensitivity was only ever exercised on a schema-rejected row. This row is
#      schema-clean, which the assertion below pins.
kit="$(mkkit c3t-hooknouppercase)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"; wire_hook "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature (3 md / git yes / hook NO) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Stop hook IS wired' <<<"$OUT" && ! grep -q 'not in schema' <<<"$OUT"; then
  ok "3t 'hook NO' claim → reverse hook-wiring WARN still fires (case-insensitive, schema-clean row)" "(exit $RC)"
else
  no "3t 'hook NO' claim → reverse hook-wiring WARN still fires (case-insensitive, schema-clean row)" "exit=$RC out=[$OUT]"
fi

# 4 — TRUNCATED '...' path → dropped, PARTIAL WARN names its basename; a real target alongside still reconciles.
kit="$(mkkit c4-truncated)"; tgtA="$kit/targetA"; tgtDots="/home/x/Honeywell/.../niagara-help"
mkcorpus "$tgtA" 4 "a"
write_targets "$kit" "$tgtA::4 md" "$tgtDots::12 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'Summary: reconciled 2 target' <<<"$OUT" \
   && grep -qE 'WARN: 1 target\(s\) skipped .* PARTIAL' <<<"$OUT" \
   && grep -q 'niagara-help' <<<"$OUT"; then
  ok "4 truncated '...' path → dropped, PARTIAL WARN names it" "(exit $RC)"
else
  no "4 truncated '...' path → dropped, PARTIAL WARN names it" "exit=$RC out=[$OUT]"
fi

# 5 — TOLERANCE boundary (default tol=2). claim 7 vs real 5 → diff 2 == tol → QUIET (no drift). claim 8 vs
#     real 5 → diff 3 > tol → WARN. Pins the '-gt tol' guard (negative control for the drift assertion).
kit="$(mkkit c5-tolq)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::7 md"
run "$kit"
quiet_ok=0
[ "$RC" = 0 ] && ! grep -qi 'drift.*targetA\|targetA.*drift' <<<"$OUT" && ! grep -qE 'WARN[[:space:]]+targetA' <<<"$OUT" && quiet_ok=1
kit2="$(mkkit c5-tolw)"; tgt2="$kit2/targetA"
mkcorpus "$tgt2" 5 "a"
write_targets "$kit2" "$tgt2::8 md"
OUT2="$("$BASH_BIN" "$kit2/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
warn_ok=0
[ "$RC2" = 0 ] && grep -qF 'drift 3 > tol 2' <<<"$OUT2" && grep -qE 'WARN[[:space:]]+targetA' <<<"$OUT2" && warn_ok=1
if [ "$quiet_ok" = 1 ] && [ "$warn_ok" = 1 ]; then
  ok "5 tol boundary: diff==2 quiet, diff==3 WARNs" "(exit $RC/$RC2)"
else
  no "5 tol boundary: diff==2 quiet, diff==3 WARNs" "quiet=$quiet_ok warn=$warn_ok out1=[$OUT] out2=[$OUT2]"
fi

# 6 — NON-RESOLVABLE: target dir exists but carries NO RESEARCH-STATE → 'corpus layout not resolvable' WARN,
#     counted as unresolvable, exit 0. (A row whose corpus predates the RESEARCH-STATE convention.)
kit="$(mkkit c6-noresolve)"; tgt="$kit/targetA"
mkdir -p "$tgt"; printf '# Block 1\n' > "$tgt/a-block1.md"   # blocks but no RESEARCH-STATE
write_targets "$kit" "$tgt::9 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+.*targetA — corpus layout not resolvable' <<<"$OUT" \
   && grep -q '1 unresolvable' <<<"$OUT"; then
  ok "6 no RESEARCH-STATE → 'not resolvable' WARN, exit 0" "(exit $RC)"
else
  no "6 no RESEARCH-STATE → 'not resolvable' WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 7 — MISSING TARGETS.md → operational failure: exit 1, prints 'cannot find', no Summary.
#     Updated from the old exit-0 WARN-only contract in issue #140: verify-registry now matches
#     the sibling scripts (sweep-retros, sweep-audits). A missing registry cannot be surfaced
#     as an advisory finding; it is an operational failure that aborts the instrument.
kit="$(mkkit c7-notargets)"   # no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'cannot find' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "7 missing TARGETS.md → exit 1 (operational), 'cannot find', no summary" "(exit $RC)"
else
  no "7 missing TARGETS.md → exit 1 (operational), 'cannot find', no summary" "exit=$RC out=[$OUT]"
fi

# 8 — ENV override RSDD_REGISTRY_TOL: with tol=50, claim 40 vs real 5 (diff 35) is now WITHIN tolerance → quiet.
kit="$(mkkit c8-tolenv)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::40 md"
OUT="$(RSDD_REGISTRY_TOL=50 "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! grep -qi 'drift.*targetA' <<<"$OUT" && grep -q '0 count drift' <<<"$OUT"; then
  ok "8 RSDD_REGISTRY_TOL=50 → diff 35 within tol, quiet" "(exit $RC)"
else
  no "8 RSDD_REGISTRY_TOL=50 → diff 35 within tol, quiet" "exit=$RC out=[$OUT]"
fi

# 9 — ROW HYGIENE lint: a master-table row with an oversized cell (> RSDD_ROW_MAXLEN, default 200) → a
#     WARN naming the target + the char count; a normal one-line row → NO such WARN. WARN-only, exit 0.
kit="$(mkkit c9-rowlint)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
big="$(printf 'x%.0s' $(seq 1 300))"    # a 300-char blob crammed into the maturity cell
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature 5 md %s | `%s` |\n' "$big" "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE 'WARN[[:space:]]+TARGETS row targetA master cell is [0-9]+ chars \(> 200\)' <<<"$OUT"; then
  ok "9 oversized master cell → row-hygiene WARN, exit 0" "(exit $RC)"
else
  no "9 oversized master cell → row-hygiene WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 9b — NEGATIVE control: a normal one-line row (all cells short) → NO row-hygiene WARN, and the env
#      override RSDD_ROW_MAXLEN is honored (set very low → even a short cell now WARNs).
kit="$(mkkit c9b-rowok)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::5 md"
run "$kit"
norm_ok=0; [ "$RC" = 0 ] && ! grep -q 'master cell is' <<<"$OUT" && norm_ok=1
OUT2="$(RSDD_ROW_MAXLEN=5 "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
# write_targets labels the name column t<N>, so the WARN names 't1' (the row's name cell, not the path).
env_ok=0; [ "$RC2" = 0 ] && grep -qE 'WARN[[:space:]]+TARGETS row t1 master cell is [0-9]+ chars \(> 5\)' <<<"$OUT2" && env_ok=1
if [ "$norm_ok" = 1 ] && [ "$env_ok" = 1 ]; then
  ok "9b normal row quiet · RSDD_ROW_MAXLEN=5 WARNs" "(exit $RC/$RC2)"
else
  no "9b normal row quiet · RSDD_ROW_MAXLEN=5 WARNs" "norm=$norm_ok env=$env_ok out=[$OUT] out2=[$OUT2]"
fi

# 10 — LOCAL-GENERATOR AUTHORITY (Fix #37). A corpus with its OWN generator (<corpus>/tools/gen-catalog.py)
#      plus a CATALOG.md whose "Total: N" differs from the raw canonical discriminator must reconcile against
#      that CATALOG total, not the discriminator (niagara: CATALOG 239 vs discriminator 237). Fixture: 5 real
#      block files (discriminator=5) but CATALOG says Total 40. (a) claim 40 md → matches CATALOG → QUIET;
#      (b) claim 5 md → matches the discriminator but NOT the CATALOG → now DRIFTS naming real=40 — proving
#      the CATALOG total (not the raw 5) drives the comparison when the local generator is present.
kit="$(mkkit c10-catalog)"; tgt="$ROOT/c10-ext/targetA"
mkdir -p "$(dirname "$tgt")"
mkcorpus "$tgt" 5 "a"                                   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalogo de bloques\n\nTotal: **40 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  for _ci in $(seq 1 40); do printf '| %d | f%d.md | T%d |\n' "$_ci" "$_ci" "$_ci"; done
} > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::40 md"                      # claim matches the CATALOG total
run "$kit"
match_ok=0
# FRESHNESS WARN fires (disc=5 vs CATALOG=40, diff 35>tol) → attention=1 → no clean line.
# The key assertion: no DRIFT WARN fires when claimed=40 matches CATALOG=40 (proving CATALOG is
# authoritative); FRESHNESS WARN confirms CATALOG was used (not disc=5) and flags possible staleness.
[ "$RC" = 0 ] \
  && ! grep -qE 'WARN[[:space:]]+targetA .* claims 40 md but' <<<"$OUT" \
  && grep -q 'CATALOG may be stale' <<<"$OUT" \
  && match_ok=1
kit2="$(mkkit c10b-catalog-drift)"; tgt2="$kit2/targetA"
mkcorpus "$tgt2" 5 "a"
mkdir -p "$tgt2/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt2/tools/gen-catalog.py"
{ printf '# Catalogo de bloques\n\nTotal: **40 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  for _ci in $(seq 1 40); do printf '| %d | f%d.md | T%d |\n' "$_ci" "$_ci" "$_ci"; done
} > "$tgt2/CATALOG.md"
write_targets "$kit2" "$tgt2::5 md"                     # claim matches the discriminator, NOT the CATALOG
OUT2="$("$BASH_BIN" "$kit2/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
drift_ok=0
[ "$RC2" = 0 ] && grep -qE 'WARN[[:space:]]+targetA .* claims 5 md but the corpus has 40 real block' <<<"$OUT2" \
  && grep -q 'CATALOG.md total via local gen-catalog.py' <<<"$OUT2" && drift_ok=1
if [ "$match_ok" = 1 ] && [ "$drift_ok" = 1 ]; then
  ok "10 local gen-catalog.py → CATALOG total (40) is authoritative, not discriminator (5)" "(exit $RC/$RC2)"
else
  no "10 local gen-catalog.py → CATALOG total (40) is authoritative, not discriminator (5)" "match=$match_ok drift=$drift_ok out=[$OUT] out2=[$OUT2]"
fi

# 11 — NC-EXEMPT: a target row with '/ nc' flag and NO RESEARCH-STATE.md is legitimately non-corpus.
#      The verifier must NOT emit 'corpus layout not resolvable'; instead it checks the root-level
#      .md count (maxdepth 1). A matching claim → no WARN, 'consistent' summary, exit 0.
kit="$(mkkit c11-nc-exempt)"; tgt="$ROOT/c11-nc-ext-tgt"
mkdir -p "$tgt"
printf '# README\n' > "$tgt/README.md"
printf '# ROADMAP\n' > "$tgt/ROADMAP.md"
printf '# GAPS\n'   > "$tgt/GAPS.md"   # 3 root-level .md, no RESEARCH-STATE
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  # Row 0: kit self-registration — keeps KIT-SELF-REG and attention counter at zero.
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
  printf '| 1 | targetNC | intermediate (3 md / nc / git no / remote no / hook no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'corpus layout not resolvable' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetNC' <<<"$OUT" \
   && grep -q 'Summary: reconciled 2 target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "11 nc-marked no-RESEARCH-STATE + claim matches → no warn, consistent" "(exit $RC)"
else
  no "11 nc-marked no-RESEARCH-STATE + claim matches → no warn, consistent" "exit=$RC out=[$OUT]"
fi

# 12 — NC-DRIFT: nc-marked target with 3 root-level .md but claim 40 md → drift WARN naming the
#      target + the counts; no 'corpus layout not resolvable' WARN (the nc path ran, not the fallback).
kit="$(mkkit c12-nc-drift)"; tgt="$kit/targetNC"
mkdir -p "$tgt"
printf '# README\n' > "$tgt/README.md"
printf '# ROADMAP\n' > "$tgt/ROADMAP.md"
printf '# GAPS\n'   > "$tgt/GAPS.md"   # 3 root-level .md, no RESEARCH-STATE
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC | intermediate (40 md / nc / git no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'corpus layout not resolvable' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+targetNC .* claims 40 md but the non-corpus target has 3' <<<"$OUT"; then
  ok "12 nc-marked claim 40 vs real 3 root-level → drift WARN, no 'not resolvable'" "(exit $RC)"
else
  no "12 nc-marked claim 40 vs real 3 root-level → drift WARN, no 'not resolvable'" "exit=$RC out=[$OUT]"
fi

# 13 — NC-MIXED: nc-marked target alongside an UNMARKED no-RESEARCH-STATE target in one registry.
#      nc target → silent (no WARN); unmarked target → 'corpus not resolvable' WARN still fires.
#      This is the anti-blank-silencer gate: nc MUST NOT suppress the fallback for unmarked rows.
kit="$(mkkit c13-nc-mixed)"; tgtA="$kit/targetNC"; tgtB="$kit/targetPlain"
mkdir -p "$tgtA" "$tgtB"
printf '# README\n' > "$tgtA/README.md"     # nc: 1 root .md
printf '# block\n' > "$tgtB/foo-block1.md"  # plain: blocks but NO RESEARCH-STATE, NO nc
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC    | intermediate (1 md / nc / git no) | `%s` |\n' "$tgtA"
  printf '| 2 | targetPlain | intermediate (1 md / git no) | `%s` |\n' "$tgtB"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qE 'WARN[[:space:]]+.*targetNC' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+.*targetPlain — corpus layout not resolvable' <<<"$OUT"; then
  ok "13 nc mixed: nc silent, unmarked still 'corpus not resolvable' (anti-blank-silencer)" "(exit $RC)"
else
  no "13 nc mixed: nc silent, unmarked still 'corpus not resolvable' (anti-blank-silencer)" "exit=$RC out=[$OUT]"
fi

# 14 — NC-CONTRADICTION: nc-marked row + resolvable RESEARCH-STATE.md under the target →
#      contradiction WARN fires; the nc assertion contradicts disk and must be flagged so the
#      operator can correct either the row or the repository. Prevents a false nc certification
#      from hiding a real corpus target.
kit="$(mkkit c14-nc-contradiction)"; tgt="$kit/targetNC"
mkcorpus "$tgt" 3 "nc"   # RESEARCH-STATE.md + 3 nc-block*.md at $tgt root
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC | intermediate (3 md / nc / git no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetNC.*RESEARCH-STATE' <<<"$OUT"; then
  ok "14 nc + resolvable RESEARCH-STATE → contradiction WARN, exit 0" "(exit $RC)"
else
  no "14 nc + resolvable RESEARCH-STATE → contradiction WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 15 — EXCLUDED-ONLY RETROS (B2): a target with blocks AND a §18-excluded retro (carrying
#      '<!-- kit-retro: exclude -->') is still effectively retro-free from the §18 perspective.
#      The '§18 feedback not wired' INFO must STILL fire — excluded files are not §18 kit retros.
#      RED before wiring retro_is_excluded: the old find|grep-q. sees the excluded file and
#      suppresses the INFO (false negative — the target looks wired when it is not).
kit="$(mkkit c15-excluded-only-retros)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '<!-- kit-retro: exclude -->\n# client retro — not §18\nbody\n' > "$tgt/retros/client.md"
write_targets "$kit" "$tgt::4 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO[[:space:]]+targetA — [0-9]+ block\(s\) on disk but no retros' <<<"$OUT"; then
  ok "15 only-excluded retros → §18 feedback not wired INFO still fires (B2 wiring)" "(exit $RC)"
else
  no "15 only-excluded retros → §18 feedback not wired INFO still fires (B2 wiring)" "exit=$RC out=[$OUT]"
fi

# 16 — RED FIRST: bare `block<N>.md` files (no canonical prefix) → canonical discriminator
#      returns 0; the counter is SILENT and neither the drift guard nor the §18 INFO can fire.
#      After the fix, a WARN naming the count and reason fires instead of silence, and §18 fires
#      too — a target with 13 unclassifiable blocks and no retro must not be exempted by its
#      own non-canonical naming.
kit="$(mkkit c16-unclassifiable)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 13\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
for i in $(seq 1 13); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
# Claim 13 md (what the operator believes) so the unclaimed-count branch does not short-circuit
# and both the unclassifiable guard and the §18 check remain reachable.
write_targets "$kit" "$tgt::13 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA.*unclassifiable' <<<"$OUT" \
   && grep -qE 'INFO[[:space:]]+targetA.*13 candidate block file\(s\) \(unclassifiable\)' <<<"$OUT"; then
  ok "16 bare block<N>.md → unclassifiable WARN + §18 INFO fire (anti-silent-zero)" "(exit $RC)"
else
  no "16 bare block<N>.md → unclassifiable WARN + §18 INFO fire (anti-silent-zero)" "exit=$RC out=[$OUT]"
fi

# 17 — CANONICAL regression guard: foo-block1.md..foo-block5.md → discriminator counts 5,
#      NO unclassifiable diagnostic emitted, behaviour unchanged from before this fix.
#      A retro is provided so §18 INFO does not confuse the assertion.
kit="$(mkkit c17-canonical-nochange)"; tgt="$ROOT/c17-ext-tgt"
mkcorpus "$tgt" 5 "foo"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01-retro.md"
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'unclassifiable' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "17 canonical foo-block<N>.md → no unclassifiable diagnostic, counted correctly" "(exit $RC)"
else
  no "17 canonical foo-block<N>.md → no unclassifiable diagnostic, counted correctly" "exit=$RC out=[$OUT]"
fi

# 18 — EMPTY corpus: no block files and no block-like candidates → no unclassifiable WARN.
#      Ensures the guard does not false-alarm when real=0 AND no candidates exist.
kit="$(mkkit c18-empty)"; tgt="$ROOT/c18-ext-tgt"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 0\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
write_targets "$kit" "$tgt::0 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'unclassifiable' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "18 empty corpus → no unclassifiable diagnostic, no false alarm" "(exit $RC)"
else
  no "18 empty corpus → no unclassifiable diagnostic, no false alarm" "exit=$RC out=[$OUT]"
fi

# 19 — FALSE-POSITIVE GUARD: ordinary corpus docs (README.md, INDEX.md, CATALOG.md,
#      RESEARCH-STATE.md, SOURCES.md) carry no 'block'/'bloque' in their names and must
#      NOT trigger the unclassifiable diagnostic. This guard matters most: a noisy false
#      alarm on every session trains operators to ignore the signal, defeating its purpose.
#
#      Extended with boundary names that exercise the new matching rule: these are plausible
#      corpus documents (especially in Spanish-authored corpora) that the OLD regex fired on,
#      causing false alarms. All four must remain silent under the fixed rule:
#        blocking-issues.md   — 'block' in name, but followed by a letter, not a digit
#        block-diagram.md     — 'block' in name, followed by '-d', no digit after separator
#        bloques-pendientes.md — 'bloque' in name, followed by 's', not a digit
#        roadblock.md         — does NOT start with block/bloque; '/' appears before 'roadblock'
#      The old comment INCORRECTLY named roadblock.md as the false-positive surface; in reality
#      it never fired (path separator is before 'roadblock', not before 'block').
kit="$(mkkit c19-fp-guard)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 0\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
printf '# README\n'  > "$tgt/README.md"
printf '# INDEX\n'   > "$tgt/INDEX.md"
printf '# CATALOG\n' > "$tgt/CATALOG.md"
printf '# SOURCES\n' > "$tgt/SOURCES.md"
# Boundary names that fire under the old '/(block|bloque)' regex but must not fire after the fix.
printf '# blocking issues\n' > "$tgt/blocking-issues.md"
printf '# block diagram\n'   > "$tgt/block-diagram.md"
printf '# pendientes\n'      > "$tgt/bloques-pendientes.md"
printf '# roadblock\n'       > "$tgt/roadblock.md"
write_targets "$kit" "$tgt::0 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'unclassifiable' <<<"$OUT"; then
  ok "19 ordinary docs + boundary names (blocking-issues/block-diagram/bloques-pendientes/roadblock) → no false alarm" "(exit $RC)"
else
  no "19 ordinary docs + boundary names (blocking-issues/block-diagram/bloques-pendientes/roadblock) → no false alarm" "exit=$RC out=[$OUT]"
fi


# 21 — \$RESEARCH_HOME path form resolves. A TARGETS.md row written as \`\$RESEARCH_HOME/sub\`
#      was invisible to the old backtick+slash grep; after the retrofit it expands and the corpus
#      directory IS walked (not "corpus layout not resolvable"). Note: the row-lookup inside
#      verify-registry.sh uses the EXPANDED path as needle, but TARGETS.md stores the literal
#      \`\$RESEARCH_HOME/...\` form, so the claimed-count row is empty → "no claimed N md" WARN fires.
#      That is a pre-existing row-lookup limitation, NOT a regression of this retrofit.
#      The key assertion: 1 target reconciled AND corpus was found (not "not resolvable").
#      RED before retrofit: old grep sees nothing, Summary: 0 targets (or zero-paths guard fires).
kit="$(mkkit c21-rh-path)"
_rh_base_vr="$ROOT/rh_base_vr_$$"
mkdir -p "$_rh_base_vr"
tgt="$_rh_base_vr/rh_corpus"
mkcorpus "$tgt" 4 "r"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (4 md / git yes) | `$RESEARCH_HOME/rh_corpus` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_vr" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_vr
if [ "$RC" = 0 ] \
   && grep -q 'reconciled 1 target' <<<"$OUT" \
   && ! grep -q 'corpus layout not resolvable' <<<"$OUT"; then
  ok "21 \$RESEARCH_HOME path → expanded, corpus found (not 'not resolvable'), 1 target reconciled" "(exit $RC)"
else
  no "21 \$RESEARCH_HOME path → expanded, corpus found (not 'not resolvable'), 1 target reconciled" "exit=$RC out=[$OUT]"
fi

# 22 — ANTI-SILENT-ZERO (WARN-only): TARGETS.md with no backtick paths → loud ERROR message,
#      exit 0 (WARN-only contract), no Summary line.
#      RED before retrofit: inline grep returns empty, run exits 0 with "reconciled 0 targets."
kit="$(mkkit c22-zeropaths)"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' \
  > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'ERROR.*no usable target paths' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "22 no usable paths → exit 0 (WARN-only), ERROR message, no summary" "(exit $RC)"
else
  no "22 no usable paths → exit 0 (WARN-only), ERROR message, no summary" "exit=$RC out=[$OUT]"
fi

# 23 — $RESEARCH_HOME path: row uses `$RESEARCH_HOME/...` form, corpus on disk, claimed count
#      matches real count → row IS found via the raw (as-written) token, count IS reconciled,
#      "no claimed 'N md' count" WARN does NOT fire, "Registry consistent with reality" IS present.
#      RED before fix: verify-registry uses the EXPANDED path as needle → grep misses the raw
#      `$RESEARCH_HOME/...` form in TARGETS.md → claimed="" → "no claimed" WARN fires.
kit="$(mkkit c23-rh-rowlookup)"
_rh_base_vr23="$ROOT/rh_base_vr23_$$"
mkdir -p "$_rh_base_vr23"
tgt="$_rh_base_vr23/rh_corpus"
mkcorpus "$tgt" 5 "r"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  # Row 0: kit self-registration (absolute path) — keeps KIT-SELF-REG and attention at zero.
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
  printf '| 1 | t1 | mature (5 md / git yes) | `$RESEARCH_HOME/rh_corpus` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_vr23" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_vr23
if [ "$RC" = 0 ] \
   && grep -q 'reconciled 2 target' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT" \
   && ! grep -qE 'no claimed.*md.*count' <<<"$OUT"; then
  ok "23 \$RESEARCH_HOME row: raw token lookup, count reconciled, no 'no claimed' warn" "(exit $RC)"
else
  no "23 \$RESEARCH_HOME row: raw token lookup, count reconciled, no 'no claimed' warn" "exit=$RC out=[$OUT]"
fi

# ---- KIT-SELF-REGISTRATION GATE (kit-sup #6) -------------------------------------------------------
# verify-registry.sh must warn when the kit repo itself is NOT listed as a target in its own
# TARGETS.md. A kit that supervises other corpora without supervising itself is the exact gap
# kit-sup #6 closes.

# 24 — kit IS in its own TARGETS.md → NO self-reg WARN.
#      The kit row carries nc (no corpus) to avoid the contradiction check; the target is placed
#      OUTSIDE the kit dir so the nc search can't see the target's RESEARCH-STATE.md.
kit="$(mkkit c24-selfreg-ok)"
tgt24="$ROOT/c24-selfreg-tgt"   # sibling of kit — not a subdir of kit
mkcorpus "$tgt24" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (3 md / git yes) | `%s` |\n' "$tgt24"
  printf '| 2 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT"; then
  ok "24 kit IS in own TARGETS.md → no self-reg WARN" "(exit $RC)"
else
  no "24 kit in TARGETS.md → self-reg WARN should not fire" "exit=$RC out=[$OUT]"
fi

# 25 — kit ABSENT from its own TARGETS.md → self-reg WARN fires, exit still 0 (WARN-only).
#      Uses a hand-written TARGETS.md without the kit row so KIT-SELF-REG fires intentionally.
#      (write_targets now adds the kit row automatically, so this test needs its own custom TARGETS.md.)
kit="$(mkkit c25-selfreg-absent)"; tgt="$ROOT/c25-ext-tgt"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (3 md / git yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"   # kit dir is NOT included in TARGETS.md — intentional
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT"; then
  ok "25 kit ABSENT from TARGETS.md → self-reg WARN fires (exit 0)" "(exit $RC)"
else
  no "25 kit absent → expected self-reg WARN but not found" "exit=$RC out=[$OUT]"
fi

# 26 — FALSE-POSITIVE: kit row registers the REPO ROOT (dirname $KIT), not the kit subdir.
#      In sdd-investigacion, TARGETS.md row 22 registers /home/.../sdd-investigacion (repo root)
#      while $KIT resolves to .../sdd-investigacion/research-sdd (the kit subdirectory).
#      Both conventions are valid; the gate must accept either and NOT fire the self-reg WARN.
repo26="$ROOT/c26-repo"          # the "repo root" that TARGETS.md will register
kit26="$repo26/research-sdd"     # KIT resolves here: dirname(verify-registry.sh)/..
mkdir -p "$repo26"; rsdd_stage_libs "$kit26/toolbelt"
cp "$SUT" "$kit26/toolbelt/verify-registry.sh"
# Register the repo root with nc + 0 md → count check trivially passes (0 == 0), no other noise.
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | sdd-investigacion | intermediate (0 md / nc / git yes) | `%s` |\n' "$repo26"
} > "$kit26/TARGETS.md"
OUT="$("$BASH_BIN" "$kit26/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT"; then
  ok "26 kit registered as REPO ROOT (dirname \$KIT) → no false-positive self-reg WARN" "(exit $RC)"
else
  no "26 kit registered as REPO ROOT → self-reg WARN fired (false positive)" "exit=$RC out=[$OUT]"
fi

# ---- kit issue #1024 round 4, MEDIUM: symlinked toolbelt (render dir) ------------------------------
# KIT used to be derived via `cd "$(dirname "$0")/.." && pwd` WITHOUT -P. Invoked through a render
# dir's symlinked toolbelt/ (kit issue #993 WU2 + #1024 F1's completion symlinks), KIT collapsed
# onto the render dir instead of the real kit root, so TARGETS_MD pointed at a path that does not
# exist there — a false "kit repo is NOT in its own TARGETS.md" WARN (kit-sup #6 gate misfiring on
# a correctly self-registered kit). Mirrors reconcile-issues.test.sh's own SYMLINK-TOOLBELT test
# (kit issue #1024 round 3) — a hand-made symlink over a synthetic mini-kit, never the real
# toolbelt/.
kit27="$(mkkit c27-symlink-toolbelt)"
mkdir -p "$kit27/profile/general"
ln -s "$kit27/toolbelt" "$kit27/profile/general/toolbelt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit27"
} > "$kit27/TARGETS.md"
# F1 completion (kit issue #993 WU2 + #1024 F1) symlinks TARGETS.md into the render dir too, same
# as toolbelt/ — matches the true render shape.
ln -s "$kit27/TARGETS.md" "$kit27/profile/general/TARGETS.md"
OUT27="$("$BASH_BIN" "$kit27/profile/general/toolbelt/verify-registry.sh" 2>&1)"; RC27=$?
if [ "$RC27" = 0 ] && ! grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT27"; then
  ok "27 SYMLINK-TOOLBELT: invoked through a symlinked toolbelt/, self-reg WARN does not false-fire" "(exit $RC27)"
else
  no "27 SYMLINK-TOOLBELT: self-reg WARN false-fired through a symlinked toolbelt/" "exit=$RC27 out=[$OUT27]"
fi


# 27 — CATALOG-FRESHNESS STALE: gen-catalog.py + CATALOG.md present; CATALOG claims 5 but
#      discriminator counts 8 (diff 3 > tol 2) → freshness WARN fires naming the counts + diff.
#      WARN-only: drift comparison (claimed=5 vs CATALOG=5) still passes → exit 0, no drift WARN.
kit="$(mkkit c27-catalog-stale)"; tgt="$kit/targetA"
mkcorpus "$tgt" 8 "a"   # 8 real block files → discriminator=8
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalogo\n\nTotal: **5 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  printf '| 1 | f1.md | T1 |\n| 2 | f2.md | T2 |\n| 3 | f3.md | T3 |\n| 4 | f4.md | T4 |\n| 5 | f5.md | T5 |\n'
} > "$tgt/CATALOG.md"   # CATALOG claims 5, table has 5 rows (self-consistent)
write_targets "$kit" "$tgt::5 md"   # claim matches the CATALOG total
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA.*CATALOG.*5.*discriminator 8' <<<"$OUT" \
   && grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetA.*refresh the row' <<<"$OUT"; then
  ok "27 stale CATALOG (disc=8 vs CATALOG=5, diff 3>tol) → freshness WARN, no drift WARN, exit 0" "(exit $RC)"
else
  no "27 stale CATALOG (disc=8 vs CATALOG=5, diff 3>tol) → freshness WARN, no drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 28 — CATALOG-FRESHNESS FRESH: gen-catalog.py + CATALOG.md present; CATALOG claims 6 and
#      discriminator counts 5 (diff 1 ≤ tol 2) → NO freshness WARN fires; drift=0, consistent.
#      Negative control: a within-tolerance difference must NOT trigger a staleness alarm.
kit="$(mkkit c28-catalog-fresh)"; tgt="$ROOT/c28-ext-tgt"
mkcorpus "$tgt" 5 "a"   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalogo\n\nTotal: **6 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  printf '| 1 | f1.md | T1 |\n| 2 | f2.md | T2 |\n| 3 | f3.md | T3 |\n| 4 | f4.md | T4 |\n| 5 | f5.md | T5 |\n| 6 | f6.md | T6 |\n'
} > "$tgt/CATALOG.md"   # diff=1 ≤ tol=2 → fresh; 6 rows matches header=6 (self-consistent)
write_targets "$kit" "$tgt::6 md"   # claim matches CATALOG total
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -q 'freshness undeterminable' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "28 fresh CATALOG (disc=5 vs CATALOG=6, diff 1≤tol) → no freshness WARN, drift=0" "(exit $RC)"
else
  no "28 fresh CATALOG (disc=5 vs CATALOG=6, diff 1≤tol) → no freshness WARN, drift=0" "exit=$RC out=[$OUT]"
fi

# 29 — CATALOG-FRESHNESS UNDETERMINABLE: gen-catalog.py present + CATALOG.md present but CATALOG
#      has no parseable total → freshness-undeterminable WARN fires; discriminator count is used.
#      The four states (absent/fresh/stale/undeterminable) must all produce distinct output.
kit="$(mkkit c29-catalog-noparse)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo\n\n(no total line here)\n' > "$tgt/CATALOG.md"   # no parseable total
write_targets "$kit" "$tgt::5 md"   # claim matches discriminator → no drift
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'freshness undeterminable' <<<"$OUT" \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetA.*refresh the row' <<<"$OUT"; then
  ok "29 CATALOG no parseable total → freshness-undeterminable WARN, no drift WARN, exit 0" "(exit $RC)"
else
  no "29 CATALOG no parseable total → freshness-undeterminable WARN, no drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 30 — CATALOG-DISC-ZERO: gen-catalog.py + CATALOG.md present; discriminator finds 0 (bare
#      block<N>.md, no canonical <prefix>- component) while CATALOG claims 5. WARN must name BOTH
#      candidate causes (non-canonical naming + stale CATALOG) and must NOT assert "CATALOG may be
#      stale" alone. The unclassifiable guard must also fire, providing file-level evidence.
#      No drift WARN (claimed=5 matches CATALOG=5). Exit 0.
#      RED before fix: current code emits "CATALOG may be stale" (wrong cause) and suppresses
#      the unclassifiable guard by setting cat_authority (wrong evidence chain).
kit="$(mkkit c30-catalog-disc-zero)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 5\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
for i in $(seq 1 5); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done  # bare naming, not canonical
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalogo\n\nTotal: **5 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  printf '| 1 | f1.md | T1 |\n| 2 | f2.md | T2 |\n| 3 | f3.md | T3 |\n| 4 | f4.md | T4 |\n| 5 | f5.md | T5 |\n'
} > "$tgt/CATALOG.md"   # self-consistent: header=5 matches 5 data rows
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'non-canonical block naming' <<<"$OUT" \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+targetA.*unclassifiable' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetA.*refresh the row' <<<"$OUT"; then
  ok "30 disc=0 vs CATALOG=5 → both-candidate WARN, unclassifiable fires, no drift WARN, exit 0" "(exit $RC)"
else
  no "30 disc=0 vs CATALOG=5 → both-candidate WARN, unclassifiable fires, no drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# ---- RETRO RECONCILIATION + MATURITY CELL SCHEMA VALIDATION -----------------------------------------
# Tests 31–36: new functionality added in the registry-maturity-schema work unit.
# Helper: write a TARGETS.md row with an explicit maturity parenthetical (claim is the full parens
# content, not just the block count), so retro fields and unknown fields can be injected precisely.
# write_targets_custom <kit> <target> <paren_content>
write_targets_custom() {
  local kit="$1" tgt="$2" paren="$3"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    # Row 0: kit self-registration — keeps KIT-SELF-REG silent in all custom-maturity tests.
    printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
    printf '| 1 | targetA | mature (%s) | `%s` |\n' "$paren" "$tgt"
  } > "$kit/TARGETS.md"
}

# 31 — RETRO-MATCH: row declares N retros that matches the real non-excluded count → no retro WARN.
kit="$(mkkit c31-retro-match)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# retro 1\nbody\n' > "$tgt/retros/2026-01-01.md"
printf '# retro 2\nbody\n' > "$tgt/retros/2026-01-02.md"
write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "31 retro declared, matches disk (2==2) → no retro WARN" "(exit $RC)"
else
  no "31 retro declared, matches disk (2==2) → no retro WARN" "exit=$RC out=[$OUT]"
fi

# 32 — RETRO-DRIFT: row claims N retros but the real count differs → WARN naming both counts, exit 0.
kit="$(mkkit c32-retro-drift)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
for i in 1 2 3 4 5; do printf '# retro %d\nbody\n' "$i" > "$tgt/retros/2026-01-0${i}.md"; done
write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'WARN[[:space:]]+targetA.*2 retro.*5 non-excluded|WARN[[:space:]]+targetA.*5 non-excluded.*2 retro' <<<"$OUT"; then
  ok "32 retro claimed 2 vs real 5 → WARN naming both, exit 0" "(exit $RC)"
else
  no "32 retro claimed 2 vs real 5 → WARN naming both, exit 0" "exit=$RC out=[$OUT]"
fi

# 33 — RETRO-ABSENT: no retro field in the cell → no retro WARN (absent is legal, not a violation).
kit="$(mkkit c33-retro-absent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 md / git yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "33 no retro field in cell → no retro WARN (absent is legal)" "(exit $RC)"
else
  no "33 no retro field in cell → no retro WARN (absent is legal)" "exit=$RC out=[$OUT]"
fi

# 34 — RETRO-MALFORMED: cell contains a retro-shaped token that is not 'N retros' →
#      surfaced as non-conforming field WARN (distinct from case 33's silence for absent).
#      'retros: many' does not match ^[0-9]+ retros? and is not any other known pattern.
kit="$(mkkit c34-retro-malformed)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / retros: many / git yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*retros: many" <<<"$OUT"; then
  ok "34 malformed retro token 'retros: many' → non-conforming WARN (distinct from absent)" "(exit $RC)"
else
  no "34 malformed retro token 'retros: many' → non-conforming WARN (distinct from absent)" "exit=$RC out=[$OUT]"
fi

# 34b — BLOCK-VARIANT ACCEPTANCE: 'N md', 'N blocks', 'N blocks @date' must all be accepted
#       without triggering a non-conforming field WARN. None should generate a schema WARN.
kit="$(mkkit c34b-block-variants)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
# Three sub-cases: each as its own TARGETS.md. Share the same kit/corpus, rewrite TARGETS.md.
write_targets_custom "$kit" "$tgt" "4 md / git yes"
run "$kit"; md_ok=0; [ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && md_ok=1
write_targets_custom "$kit" "$tgt" "4 blocks / git yes"
run "$kit"; blocks_ok=0; [ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && blocks_ok=1
write_targets_custom "$kit" "$tgt" "4 blocks @2026-07-30 / git yes"
run "$kit"; date_ok=0; [ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && date_ok=1
if [ "$md_ok" = 1 ] && [ "$blocks_ok" = 1 ] && [ "$date_ok" = 1 ]; then
  ok "34b block variants (N md / N blocks / N blocks @date) → all accepted, no schema WARN" "(all 3 sub-cases)"
else
  no "34b block variants → not all accepted" "md=$md_ok blocks=$blocks_ok date=$date_ok"
fi

# 35 — UNKNOWN-FIELD: a maturity cell token that matches no known schema pattern is surfaced
#      verbatim in a WARN. The token 'widget yes' is not block/run/retro/git/remote/hook/nc/…
kit="$(mkkit c35-unknown-field)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / widget yes / git yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*widget yes" <<<"$OUT"; then
  ok "35 unknown field 'widget yes' → non-conforming WARN verbatim" "(exit $RC)"
else
  no "35 unknown field 'widget yes' → non-conforming WARN verbatim" "exit=$RC out=[$OUT]"
fi

# 36 — EXCLUDED-RETROS-NOT-COUNTED: row claims 1 retro; disk has 1 real + 1 excluded → only the
#      real one counts → declared count matches → NO drift WARN. Proves excluded retros are filtered.
kit="$(mkkit c36-excluded-retro)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# real retro\nbody\n' > "$tgt/retros/2026-01-01-real.md"
printf '<!-- kit-retro: exclude -->\n# client retro\nbody\n' > "$tgt/retros/2026-01-02-client.md"
write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "36 excluded retro not counted: 1 real + 1 excluded vs claim 1 → no drift WARN" "(exit $RC)"
else
  no "36 excluded retro not counted: 1 real + 1 excluded vs claim 1 → no drift WARN" "exit=$RC out=[$OUT]"
fi

# 37 — BLOCKING 1 (last-position token): garbage in the LAST cell token must fire the schema
#      WARN. The tokenizer bug (`printf '%s'` without trailing newline) causes `read` to return
#      non-zero for the unterminated last line, silently dropping it.
#      RED before fix: 'mature (4 md / git yes / ABSOLUTE NONSENSE LAST TOKEN)' emits NO WARN.
kit="$(mkkit c37-last-token)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / git yes / ABSOLUTE NONSENSE LAST TOKEN"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*ABSOLUTE NONSENSE LAST TOKEN" <<<"$OUT"; then
  ok "37 garbage in LAST position → schema WARN fires (tokenizer last-token fix)" "(exit $RC)"
else
  no "37 garbage in LAST position → NO schema WARN (tokenizer drops last token — BLOCKING 1)" "exit=$RC out=[$OUT]"
fi

# 38 — BLOCKING 1 (single-token cell): a cell with exactly ONE garbage token must also be
#      caught. With the bug, even a single-token cell is silently dropped because `printf '%s'`
#      emits no trailing newline, making `read` fail immediately and skip the loop body.
kit="$(mkkit c38-single-token)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "COMPLETE GARBAGE ONLY TOKEN"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*COMPLETE GARBAGE" <<<"$OUT"; then
  ok "38 single garbage token → schema WARN fires (tokenizer single-token fix)" "(exit $RC)"
else
  no "38 single garbage token → NO schema WARN (tokenizer drops single token — BLOCKING 1)" "exit=$RC out=[$OUT]"
fi

# 39 — BLOCKING 2 (unreadable retros dir): a target whose retros/ dir exists but is chmod 000
#      must produce an OPERATIONAL WARN about inaccessibility, not a false retro count drift.
#      RED before fix: find ... 2>/dev/null silently returns 0 retros → false 'claims N but 0' drift.
kit="$(mkkit c39-unreadable-retros)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# real retro 1\nbody\n' > "$tgt/retros/2026-01-01.md"
printf '# real retro 2\nbody\n' > "$tgt/retros/2026-01-02.md"
write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes"
chmod 000 "$tgt/retros"
run "$kit"
chmod 755 "$tgt/retros"   # restore so cleanup works
if [ "$RC" = 0 ] \
   && grep -qiE 'WARN[[:space:]]+targetA.*(not accessible|permission)' <<<"$OUT" \
   && ! grep -qiE 'WARN[[:space:]]+targetA.*[0-9]+ retro.*found' <<<"$OUT"; then
  ok "39 unreadable retros/ → operational WARN, no false count drift (BLOCKING 2)" "(exit $RC)"
else
  no "39 unreadable retros/ → expected operational WARN but got false drift (BLOCKING 2 unfixed)" "exit=$RC out=[$OUT]"
fi

# 40 — MAJOR 4 (maxdepth 4): retro at depth 3 (<target>/research/retros/*.md) must be found.
#      RED before fix: maxdepth 2 only reaches depth-2 retros; depth-3 retros are invisible.
# kit issue #1108: sandbox name deliberately avoids the substring 'retro' — the new marker-check
# WARN echoes the registered path (and $path/corpus) back verbatim, and a temp-dir name containing
# 'retro' would make it accidentally satisfy this test's own 'WARN.*targetA.*retro' assertion,
# masking a real MAJOR-4 regression as a false PASS.
kit="$(mkkit c40-depth3)"; tgt="$kit/targetA"
mkcorpus "$tgt/research" 4 "a"   # corpus at depth 1 (research/); RESEARCH-STATE.md is there
mkdir -p "$tgt/research/retros"
printf '# retro at depth 3\nbody\n' > "$tgt/research/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "40 retro at depth 3 (research/retros/) → found (maxdepth 4), no drift WARN" "(exit $RC)"
else
  no "40 retro at depth 3 → NOT found (maxdepth 2 misses it — MAJOR 4 unfixed)" "exit=$RC out=[$OUT]"
fi

# 41 — BLOCKING 3 (anchored retro pattern): trailing garbage after 'N retros' must trigger NONCONFORM.
#      Unanchored '^[0-9]+[[:space:]]+retros?' passes '3 retrograde motion'.
kit="$(mkkit c41-retro-anchor)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / 3 retrograde motion / git yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*retrograde" <<<"$OUT"; then
  ok "41 '3 retrograde motion' → schema WARN fires (anchored retro pattern)" "(exit $RC)"
else
  no "41 '3 retrograde motion' → no WARN (unanchored retro pattern — BLOCKING 3)" "exit=$RC out=[$OUT]"
fi

# 42 — BLOCKING 3 (anchored block @date pattern): loose '(@.*)?' passes garbage after @.
#      '4 md @garbage not a date' must trigger NONCONFORM.
kit="$(mkkit c42-block-date-anchor)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md @garbage not a date / git yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema" <<<"$OUT"; then
  ok "42 block '@garbage not a date' → schema WARN fires (tightened @date pattern)" "(exit $RC)"
else
  no "42 block '@garbage not a date' → no WARN (loose @date pattern — BLOCKING 3)" "exit=$RC out=[$OUT]"
fi

# 42b — BLOCKING 3 negative control: valid @date forms must still pass after pattern tightening.
#       'N blocks @YYYY-MM-DD' and 'N blocks @YYYY-MM-DD, ACTIVE' both documented in the legend.
kit="$(mkkit c42b-block-date-ok)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 blocks @2026-07-30 / git yes"
run "$kit"; date_ok=0
[ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && date_ok=1
write_targets_custom "$kit" "$tgt" "4 blocks @2026-07-30, ACTIVE / git yes"
run "$kit"; active_ok=0
[ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && active_ok=1
if [ "$date_ok" = 1 ] && [ "$active_ok" = 1 ]; then
  ok "42b valid @date and @date,ACTIVE → both accepted, no schema WARN" "(date=$date_ok active=$active_ok)"
else
  no "42b valid @date forms → not all accepted after pattern tightening" "date=$date_ok active=$active_ok out=[$OUT]"
fi

# 43 — MINOR 5 (singular focus): '1 focus' must be accepted without a schema WARN.
#      Pattern 'focuses?' expands to 'focuse?' (matches 'focuse' or 'focuses'), NOT 'focus'.
kit="$(mkkit c43-singular-focus)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 md / 1 focus / git yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE "WARN[[:space:]]+targetA.*not in schema.*focus" <<<"$OUT"; then
  ok "43 '1 focus' (singular) → accepted, no schema WARN (MINOR 5 fix)" "(exit $RC)"
else
  no "43 '1 focus' (singular) → schema WARN fires (pattern 'focuses?' misses singular — MINOR 5)" "exit=$RC out=[$OUT]"
fi

# 44 — MINOR 6 (separate retro drift counter): a retro drift must appear in the summary as
#      'N retro drift(s)', not as a count drift. Before fix, retro_drift increments `drift`.
kit="$(mkkit c44-retro-drift-counter)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
for i in 1 2 3; do printf '# retro %d\nbody\n' "$i" > "$tgt/retros/2026-01-0${i}.md"; done
write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q '1 retro drift' <<<"$OUT"; then
  ok "44 retro drift → 0 count drift + 1 retro drift in summary (separate counters)" "(exit $RC)"
else
  no "44 retro drift → separate retro drift counter missing in summary (MINOR 6)" "exit=$RC out=[$OUT]"
fi


# 45 — OPERATIONAL FAILURE: TARGETS.md missing → exit 1, explicit diagnostic, no summary.
#      Before issue #140 fix, verify-registry exited 0 (old WARN-only contract). After the fix
#      it must match the sibling scripts (sweep-retros, sweep-audits): a missing input is not an
#      advisory finding, it is an operational failure that aborts the instrument.
#      RED before fix: current code exits 0 (the SUT has 'exit 0' at the TARGETS.md guard).
kit="$(mkkit c45-notargets-exit1)"   # no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'cannot find' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "45 missing TARGETS.md → exit 1 (operational), 'cannot find' msg, no summary" "(exit $RC)"
else
  no "45 missing TARGETS.md → exit 1 (operational), 'cannot find' msg, no summary" "exit=$RC out=[$OUT]"
fi


# 47 — REGRESSION GUARD: advisory findings (drift, maturity schema) still exit 0 after the fix.
#      The fix must only change operational-failure exit codes, not over-convert advisory WARNs.
#      Sub-case a: drifted row → exit 0 + WARN (regression guard; passes before AND after fix).
#      Sub-case b: clean kit  → exit 0 (regression guard for the happy path).
#      NOTE: both sub-cases pass against the pre-fix code — this is a regression guard, not a RED case.
kit="$(mkkit c47-drift-still-exit0)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::40 md"   # drift > tol
run "$kit"
drift_ok=0
[ "$RC" = 0 ] && grep -qE 'WARN.*targetA.*drift' <<<"$OUT" && drift_ok=1
kit2="$(mkkit c47b-clean-exit0)"; tgt2="$kit2/targetA"
mkcorpus "$tgt2" 5 "a"
write_targets "$kit2" "$tgt2::5 md"  # clean
OUT2="$("$BASH_BIN" "$kit2/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
clean_ok=0; [ "$RC2" = 0 ] && clean_ok=1
if [ "$drift_ok" = 1 ] && [ "$clean_ok" = 1 ]; then
  ok "47 advisory drift/clean still exit 0 after op-failure fix (regression guard)" "(drift_ok=$drift_ok clean_ok=$clean_ok)"
else
  no "47 advisory drift/clean regression guard failed" "drift_ok=$drift_ok drift_out=[$OUT] clean_ok=$clean_ok clean_out=[$OUT2]"
fi




# 50 — ALL-ABSENT OPERATIONAL FAILURE: TARGETS.md has backtick paths but every resolved path is
#      a non-existent directory. paths IS non-empty (passes the [ -z "$paths" ] guard), but the
#      per-target [ -d ] check skips every entry, leaving checked == 0 and dir_reached == 0.
#      Current code exits 0 with "Registry consistent with reality" — a false PASS (§7).
#      After fix: exit 1 AND no "consistent with reality" in output.
#      RED before fix: exits 0 + "consistent".
kit="$(mkkit c50-all-absent)"
nonexistent50="$kit/corpus-that-does-not-exist"
# Intentionally hand-written TARGETS.md with NO kit row and ONLY a nonexistent path, so that
# every resolved path is absent and the ALL-ABSENT guard fires. (write_targets now adds the kit
# row which would be a real directory, defeating the all-absent scenario.)
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (5 md / git yes) | `%s` |\n' "$nonexistent50"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 1 ] \
   && ! grep -qi 'consistent with reality' <<<"$OUT"; then
  ok "50 all paths absent → exit 1, no 'consistent' (anti-silent-zero operational)" "(exit $RC)"
else
  no "50 all paths absent → should exit 1 but got exit 0 + 'consistent' (DEFECT)" "exit=$RC out=[$OUT]"
fi

# 51 — REGRESSION GUARD: at least one path reconciles → exit 0, normal verdict. The new guard
#      must NOT over-fire when dir_reached >= 1 (i.e. when at least one dir exists on disk).
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger that would
#      suppress the clean line via unresolved>0.
#      Passes before AND after the fix (regression guard, not a RED case).
kit="$(mkkit c51-one-reconciles)"; tgt="$ROOT/c51-ext-tgt"
mkcorpus "$tgt" 4 "a"
write_targets "$kit" "$tgt::4 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'Registry consistent with reality' <<<"$OUT" \
   && grep -q 'reconciled 2 target' <<<"$OUT"; then
  ok "51 one target reconciles → exit 0 + normal verdict (guard does not over-fire)" "(exit $RC)"
else
  no "51 one reconciled target → regression guard failed" "exit=$RC out=[$OUT]"
fi


# 52 — CATALOG-DISC-ZERO attention gate: disc=0 vs CATALOG>0 fires the CATALOG-DISC-ZERO WARN →
#      attention becomes nonzero → clean line ABSENT (claimed=5=CATALOG → no drift WARN).
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger: a RESEARCH-STATE.md
#      inside $kit would be found by the nc-scan (find $kit -maxdepth 3) → unresolved++ → clean line absent
#      on BOTH pre-fix and post-fix SUT, masking the attention gate and making the test vacuous theater.
#      RED before fix: pre-fix SUT (no attention counter) prints "Registry consistent with reality" despite the WARN.
kit="$(mkkit c52-attn-disc-zero)"; tgt="$ROOT/c52-ext-tgt"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 5\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
for i in $(seq 1 5); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalogo\n\nTotal: **5 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  printf '| 1 | f1.md | T1 |\n| 2 | f2.md | T2 |\n| 3 | f3.md | T3 |\n| 4 | f4.md | T4 |\n| 5 | f5.md | T5 |\n'
} > "$tgt/CATALOG.md"   # self-consistent: header=5 matches 5 data rows
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'non-canonical block naming' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "52 CATALOG-DISC-ZERO fires → attention++ → clean line ABSENT (exit 0)" "(exit $RC)"
else
  no "52 CATALOG-DISC-ZERO fires → clean line ABSENT — FAILED (attention gate missing)" "exit=$RC out=[$OUT]"
fi

# 53 — CATALOG-FRESHNESS attention gate: stale CATALOG (disc=8, CATALOG=5, diff=3>tol) fires
#      the freshness WARN → attention++ → clean line ABSENT (claimed=5=CATALOG → no drift WARN).
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger.
#      RED before fix: pre-fix SUT (no attention counter) prints "Registry consistent with reality" despite the WARN.
kit="$(mkkit c53-attn-freshness)"; tgt="$ROOT/c53-ext-tgt"
mkcorpus "$tgt" 8 "a"
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalogo\n\nTotal: **5 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  printf '| 1 | f1.md | T1 |\n| 2 | f2.md | T2 |\n| 3 | f3.md | T3 |\n| 4 | f4.md | T4 |\n| 5 | f5.md | T5 |\n'
} > "$tgt/CATALOG.md"   # self-consistent: header=5 matches 5 data rows; disc=8 → freshness WARN fires
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "53 CATALOG-FRESHNESS fires → attention++ → clean line ABSENT (exit 0)" "(exit $RC)"
else
  no "53 CATALOG-FRESHNESS fires → clean line ABSENT — FAILED (attention gate missing)" "exit=$RC out=[$OUT]"
fi

# 54 — CATALOG-NOPARSE attention gate: CATALOG.md present but no parseable total fires the
#      NOPARSE WARN → attention++ → clean line ABSENT (disc count used, claimed=disc → no drift WARN).
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger.
#      RED before fix: pre-fix SUT (no attention counter) prints "Registry consistent with reality" despite the WARN.
kit="$(mkkit c54-attn-noparse)"; tgt="$ROOT/c54-ext-tgt"
mkcorpus "$tgt" 5 "a"
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo\n\n(no total line)\n' > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'freshness undeterminable' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "54 CATALOG-NOPARSE fires → attention++ → clean line ABSENT (exit 0)" "(exit $RC)"
else
  no "54 CATALOG-NOPARSE fires → clean line ABSENT — FAILED (attention gate missing)" "exit=$RC out=[$OUT]"
fi

# 55 — RETRO-UNREADABLE attention gate: retros/ dir chmod 000 fires the inaccessible WARN →
#      attention++ → clean line ABSENT. Non-root guard: root bypasses perms (§7 hazard).
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger.
#      Uses $ROOT/c55-ext/targetA so basename stays "targetA" (WARN message uses basename).
#      RED before fix: pre-fix SUT (no attention counter) prints "Registry consistent with reality" despite the WARN.
if [ "$EUID" -eq 0 ]; then
  echo "  SKIP  55 RETRO-UNREADABLE attention gate — running as root; chmod 000 bypassed (§7 guard)"
else
  kit="$(mkkit c55-attn-unreadable)"; tgt="$ROOT/c55-ext/targetA"
  mkcorpus "$tgt" 4 "a"
  mkdir -p "$tgt/retros"
  printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
  printf '# retro\nbody\n' > "$tgt/retros/2026-01-02.md"
  write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes"
  chmod 000 "$tgt/retros"
  run "$kit"
  chmod 755 "$tgt/retros"
  if [ "$RC" = 0 ] \
     && grep -qiE 'WARN[[:space:]]+targetA.*(not accessible|permission)' <<<"$OUT" \
     && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
    ok "55 RETRO-UNREADABLE fires → attention++ → clean line ABSENT (exit 0)" "(exit $RC)"
  else
    no "55 RETRO-UNREADABLE fires → clean line ABSENT — FAILED (attention gate missing)" "exit=$RC out=[$OUT]"
  fi
fi

# 56 — UNCLASSIFIABLE attention gate: bare block<N>.md (no canonical prefix) fires the
#      unclassifiable WARN → attention++ → clean line ABSENT.
#      Fixture: claimed=0 md so discriminator=0 matches claimed=0 (no drift contamination).
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger.
#      Uses $ROOT/c56-ext/targetA so basename stays "targetA" (WARN message uses basename).
#      The UNCLASSIFIABLE WARN fires because 5 bare block*.md files are present but unclassifiable.
#      RED before fix: pre-fix SUT (no attention counter) prints "Registry consistent with reality" despite the WARN.
kit="$(mkkit c56-attn-unclassifiable)"; tgt="$ROOT/c56-ext/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 0\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
for i in $(seq 1 5); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
write_targets "$kit" "$tgt::0 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA.*unclassifiable' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "56 UNCLASSIFIABLE fires → attention++ → clean line ABSENT (exit 0)" "(exit $RC)"
else
  no "56 UNCLASSIFIABLE fires → clean line ABSENT — FAILED (attention gate missing)" "exit=$RC out=[$OUT]"
fi

# 57 — KIT-SELF-REG attention gate: kit NOT in TARGETS.md fires self-reg WARN →
#      attention++ → clean line ABSENT. Same fixture as test 25 (which proved the WARN fires).
kit="$(mkkit c57-attn-kit-self-reg)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (3 md / git yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "57 KIT-SELF-REG fires → attention++ → clean line ABSENT (exit 0)" "(exit $RC)"
else
  no "57 KIT-SELF-REG fires → clean line ABSENT — FAILED (attention gate missing)" "exit=$RC out=[$OUT]"
fi

# 58 — INVERSE CONTROL: clean fleet (all counters zero) → clean line PRESENT.
#      Kit IS in TARGETS.md (nc row) so KIT-SELF-REG does not fire.
#      Target is OUTSIDE the kit sandbox so the nc scan of $kit cannot see its RESEARCH-STATE.md
#      (otherwise the nc-contradiction WARN would fire, suppressing the clean line via unresolved).
#      §7 guard: if the gate fires on a genuinely clean fleet this control goes RED.
kit="$(mkkit c58-attn-clean-inverse)"; tgt="$ROOT/c58-ext-tgt"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
  printf '| 1 | t1 | mature (4 md / 1 retros / git yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qiE '^WARN' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "58 clean fleet (kit in TARGETS.md, no WARNs) → clean line PRESENT (inverse control)" "(exit $RC)"
else
  no "58 clean fleet → clean line PRESENT — FAILED (always-attention inverse defect)" "exit=$RC out=[$OUT]"
fi

# 59 — PARTIAL attention gate: skipped_count>0 (truncated '...' path) → clean line ABSENT
#      even when drift=retro_drift=unresolved=rowlint=attention=0.
#      Target is OUTSIDE the kit sandbox (sibling in $ROOT) to avoid the nc-contradiction false trigger.
#      RED before fix: current gate only checks drift/retro_drift/unresolved; PARTIAL still prints clean.
kit="$(mkkit c59-attn-partial)"; tgtA="$ROOT/c59-ext-tgt"
mkcorpus "$tgtA" 4 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
  printf '| 1 | t1 | mature (4 md / git yes) | `%s` |\n' "$tgtA"
  printf '| 2 | t2 | mature (9 md / git yes) | `$RESEARCH_HOME/some/path/...` |\n'
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN: 1 target\(s\) skipped' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "59 PARTIAL (skipped_count>0) → clean line ABSENT" "(exit $RC)"
else
  no "59 PARTIAL (skipped_count>0) → clean line ABSENT — FAILED (skipped_count not gated)" "exit=$RC out=[$OUT]"
fi

# 60 — L154 no-regression CONTROL: NONCONFORM-FIELD fires → unresolved++ (not attention++).
#      Clean line absent via unresolved>0. attention stays 0 — no double-count.
#      The summary surfaces attention count so we can observe it directly.
#      Target is OUTSIDE the kit sandbox to avoid the nc-contradiction false trigger.
#      Mutation control (teeth): if attention++ were injected at L154, summary would show "1 attention".
kit="$(mkkit c60-l154-noregress)"; tgt="$ROOT/c60-ext/targetA"
mkdir -p "$(dirname "$tgt")"
mkcorpus "$tgt" 4 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
  printf '| 1 | targetA | mature (4 md / GARBAGE UNKNOWN FIELD / git yes) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'WARN[[:space:]]+targetA.*not in schema' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT" \
   && grep -q '0 attention' <<<"$OUT"; then
  ok "60 L154 NONCONFORM → unresolved++ (not attention++); clean absent via unresolved; attention=0 in summary" "(exit $RC)"
else
  no "60 L154 NONCONFORM → attention=0 in summary — FAILED (gate or double-count)" "exit=$RC out=[$OUT]"
fi

# 61 — CATALOG SELF-CONSISTENT (cat_total == cat_rows, disc ≠ cat_total): CATALOG.md header (17)
#      equals its own table row count (17), but disc=5. Self-consistency gate MUST adopt CATALOG total
#      as real=17 (not disc=5). No stale-header WARN fires. FRESHNESS WARN may fire (diff=12>tol).
#      No drift WARN (claimed=17 matches CATALOG=17).
kit="$(mkkit c61-catalog-selfcons)"; tgt="$ROOT/c61-ext-tgt"
mkcorpus "$tgt" 5 "a"   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalog\n\nTotal: **17 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  for _ci in $(seq 1 17); do printf '| %d | f%d.md | T%d |\n' "$_ci" "$_ci" "$_ci"; done
} > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::17 md"   # claim matches CATALOG total (17), not disc=5
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'stale header' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+[a-z0-9_A-Z-]*.*refresh the row' <<<"$OUT"; then
  ok "61 self-consistent CATALOG (cat_total=17==cat_rows, disc=5) → CATALOG adopted, no stale-header WARN, no drift WARN" "(exit $RC)"
else
  no "61 self-consistent CATALOG (cat_total=17==cat_rows, disc=5) → CATALOG adopted, no stale-header WARN, no drift WARN" "exit=$RC out=[$OUT]"
fi

# 62 — STALE CATALOG HEADER (cat_total ≠ cat_rows): header claims 722 but table has only 3 data
#      rows (cat_rows=3). disc=5 canonical block files. Self-consistency gate MUST reject CATALOG total;
#      real stays at disc=5. STALE-HEADER WARN fires naming 722 and 3. No drift WARN (claimed=5=real=5).
kit="$(mkkit c62-catalog-stalehdr)"; tgt="$ROOT/c62-ext-tgt"
mkcorpus "$tgt" 5 "a"   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalog\n\nTotal: **722 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  for _ci in $(seq 1 3); do printf '| %d | f%d.md | T%d |\n' "$_ci" "$_ci" "$_ci"; done
} > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::5 md"   # claim matches disc=5 (not stale header=722)
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'stale header' <<<"$OUT" \
   && grep -q '722' <<<"$OUT" \
   && grep -q ' 3 ' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+[a-z0-9_A-Z-]*.*refresh the row' <<<"$OUT"; then
  ok "62 stale CATALOG header (cat_total=722, cat_rows=3, disc=5) → stale-header WARN, real=5, no drift WARN" "(exit $RC)"
else
  no "62 stale CATALOG header (cat_total=722, cat_rows=3, disc=5) → stale-header WARN, real=5, no drift WARN" "exit=$RC out=[$OUT]"
fi

# 63 — FULLY-AGREEING (cat_total == cat_rows == disc): header=17, table rows=17, disc=17.
#      Behavior must be IDENTICAL to before the fix — CATALOG adopted, no stale-header WARN, no drift
#      WARN, clean line present (diff=0≤tol → fresh, no attention, all counters zero).
kit="$(mkkit c63-catalog-allagree)"; tgt="$ROOT/c63-ext-tgt"
mkcorpus "$tgt" 17 "a"   # 17 real block files → discriminator=17
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
{ printf '# Catalog\n\nTotal: **17 bloques**\n\n| # | file | title |\n|---|---|---|\n'
  for _ci in $(seq 1 17); do printf '| %d | f%d.md | T%d |\n' "$_ci" "$_ci" "$_ci"; done
} > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::17 md"   # claim matches everything
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'stale header' <<<"$OUT" \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+[a-z0-9_A-Z-]*.*refresh the row' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "63 fully-agreeing (cat_total=17==cat_rows==disc) → no stale-header WARN, no drift, clean line" "(exit $RC)"
else
  no "63 fully-agreeing (cat_total=17==cat_rows==disc) → no stale-header WARN, no drift, clean line" "exit=$RC out=[$OUT]"
fi

# 64 — ABSENT-PATHS gate: a registered target whose path does not exist on disk is counted and
#      reported as "N registered target(s) absent" (INFO line). The clean line must be ABSENT.
#      The Summary must carry the "· N absent target(s) ·" field. Exit stays 0 (advisory).
#      RED before fix: pre-fix SUT says "path(s)" not "target(s)" and has no Summary absent field.
#      Target REAL exists on disk; target ABSENT does not — write_targets registers both.
kit="$(mkkit c64-absent-path)"; tgt_real="$ROOT/c64-real-tgt"; tgt_absent="$ROOT/c64-absent-tgt"
mkcorpus "$tgt_real" 3 "a"
# tgt_absent is NOT created — registered but absent on disk.
write_targets "$kit" "$tgt_real::3 md" "$tgt_absent::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && grep -qE '\· [0-9]+ absent target' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "64 absent registered target → INFO, · N absent target in Summary, no clean line, exit 0" "(exit $RC)"
else
  no "64 absent registered target → expected INFO + Summary field + no clean line" "exit=$RC out=[$OUT]"
fi

# 65 — SLUG in present row does NOT count as absent: a row with a present corpus path PLUS a
#      backtick artifact token like /mrdoob/three.js (which fails [ -d ]) must not be flagged as
#      absent. The per-row rule: a row is absent only when NONE of its backtick paths is a directory.
kit="$(mkkit c65-slug-present-row)"; tgt_real2="$ROOT/c65-real-tgt"
mkcorpus "$tgt_real2" 2 "b"
# Row has BOTH a present corpus path AND a /slug/form token that is not a directory.
{ printf '# targets\n\n| # | name | maturity | path | artifact |\n|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - |\n' "$kit"
  printf '| 1 | tgt | mature (2 md / git yes) | `%s` | `/slug/form-token` |\n' "$tgt_real2"
} > "$kit/TARGETS.md"
run "$kit"
# /slug/form-token fails [ -d ] but the row has a present corpus path → row is NOT absent.
if [ "$RC" = 0 ] \
   && ! grep -qE 'INFO.*registered target.*absent' <<<"$OUT" \
   && grep -qE '\· 0 absent target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "65 slug in present row → row NOT absent, 0 absent targets, clean line present" "(exit $RC)"
else
  no "65 slug in present row → expected 0 absent targets, clean line" "exit=$RC out=[$OUT]"
fi

# 66 — SINGLE absent target (list-edge: single): only one user target and it is absent.
#      Kit self-registration row is present; user target is absent. absent_paths=1, exit 0.
kit="$(mkkit c66-single-absent)"; absent_single="$ROOT/c66-single-absent-tgt"
# absent_single NOT created
write_targets "$kit" "$absent_single::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && grep -qE '· 1 absent target' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "66 single absent target → absent_paths=1, INFO, Summary field, exit 0" "(exit $RC)"
else
  no "66 single absent target → expected absent_paths=1" "exit=$RC out=[$OUT]"
fi

# 67 — PER-ROW DEDUP: a row with TWO absent backtick-path tokens is counted ONCE per row,
#      not once per token. Documents that dedup prevents double-counting multi-token rows.
#      Test 65 covers a row with a present path + a slug; this covers a row with TWO absent paths.
kit="$(mkkit c67-dedup-two-absent)"; tgt_real3="$ROOT/c67-real-tgt"
mkcorpus "$tgt_real3" 2 "c"
{ printf '# targets\n\n| # | name | maturity | path | artifact |\n|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - |\n' "$kit"
  printf '| 1 | tgt | mature (2 md / git yes) | `%s` | - |\n' "$tgt_real3"
  # Row with TWO absent backtick /... paths (path column + artifact column).
  printf '| 2 | multi | mature (5 md / git yes) | `/absent/multi-path-A` | `/absent/multi-path-B` |\n'
} > "$kit/TARGETS.md"
run "$kit"
# Must count the "multi" row exactly ONCE as absent (not twice), so absent_paths=1.
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && grep -qE '· 1 absent target' <<<"$OUT"; then
  ok "67 two absent tokens same row → counted ONCE (dedup prevents double-count)" "(exit $RC)"
else
  no "67 two absent tokens same row → expected exactly 1 absent" "exit=$RC out=[$OUT]"
fi

# 68 — ABSENT FIRST (list-edge: first): absent target sorts first alphabetically among targets.
#      Verifies the dedup string is correctly seeded on the first entry.
kit="$(mkkit c68-absent-first)"; real_z="$ROOT/c68z-real"; absent_a="$ROOT/c68a-absent"
mkcorpus "$real_z" 2 "z"
# absent_a sorts before real_z alphabetically ('a' < 'z'); NOT created.
write_targets "$kit" "$absent_a::5 md" "$real_z::2 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "68 absent target sorts FIRST → counted correctly (first dedup entry)" "(exit $RC)"
else
  no "68 absent target FIRST → expected 1 absent" "exit=$RC out=[$OUT]"
fi

# 69 — ABSENT MIDDLE (list-edge: middle): absent target sorts between two present targets.
kit="$(mkkit c69-absent-middle)"; real_a="$ROOT/c69a-real"; absent_m="$ROOT/c69m-absent"; real_z="$ROOT/c69z-real2"
mkcorpus "$real_a" 2 "a"
mkcorpus "$real_z" 3 "z"
# absent_m ('m') sorts between 'a' and 'z'; NOT created.
write_targets "$kit" "$real_a::2 md" "$absent_m::4 md" "$real_z::3 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "69 absent target MIDDLE → counted correctly" "(exit $RC)"
else
  no "69 absent target MIDDLE → expected 1 absent" "exit=$RC out=[$OUT]"
fi

# 70 — RH-COMPANION (issue #1039): a row whose ONLY present corpus path is written in
#      `$RESEARCH_HOME/...` form, plus a companion non-path backtick token (e.g. a GitHub slug like
#      `/mrdoob/three.js`), must NOT be counted absent. The per-row any-dir check (ABSENT-PATHS-CHECK)
#      only recognised literal `/abs` tokens, so it never saw the $RESEARCH_HOME token at all and
#      false-counted the row absent even though target_paths_pairs already resolved a real directory.
#      RED before fix: absent_paths=1, INFO "1 registered target ... absent", no clean line.
kit="$(mkkit c70-rh-slug-companion)"
_rh_base_70="$ROOT/rh_base_70_$$"
mkdir -p "$_rh_base_70"
tgt="$_rh_base_70/rh_corpus"
mkcorpus "$tgt" 3 "t"
{ printf '# targets\n\n| # | name | maturity | path | artifact |\n|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - |\n' "$kit"
  printf '| 1 | tgt | mature (3 md / git yes) | `$RESEARCH_HOME/rh_corpus` | `/slug/companion-token` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_70" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_70
if [ "$RC" = 0 ] \
   && ! grep -qE 'INFO.*registered target.*absent' <<<"$OUT" \
   && grep -qE '\· 0 absent target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "70 \$RESEARCH_HOME real dir + /slug companion → row NOT absent (issue #1039)" "(exit $RC)"
else
  no "70 \$RESEARCH_HOME real dir + /slug companion → row NOT absent (issue #1039)" "exit=$RC out=[$OUT]"
fi

# 71 — LIST-EDGE (FIRST): the real `$RESEARCH_HOME/...` token is the FIRST of three backtick
#      tokens in the row (real, slug, slug). The any-dir loop must still find it (it breaks on the
#      first hit, so a first-position real token is the easiest case — pinned as the list-edge start).
kit="$(mkkit c71-rh-first)"
_rh_base_71="$ROOT/rh_base_71_$$"
mkdir -p "$_rh_base_71"
tgt="$_rh_base_71/rh_corpus71"
mkcorpus "$tgt" 2 "f"
{ printf '# targets\n\n| # | name | maturity | path | artifact | extra |\n|---|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - | - |\n' "$kit"
  printf '| 1 | tgt | mature (2 md / git yes) | `$RESEARCH_HOME/rh_corpus71` | `/slug/x1` | `/slug/y1` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_71" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_71
if [ "$RC" = 0 ] \
   && grep -qE '\· 0 absent target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "71 real \$RESEARCH_HOME token FIRST among 3 row tokens → row NOT absent" "(exit $RC)"
else
  no "71 real \$RESEARCH_HOME token FIRST among 3 row tokens → row NOT absent" "exit=$RC out=[$OUT]"
fi

# 72 — LIST-EDGE (MIDDLE): the real token sits between two absent slug tokens.
kit="$(mkkit c72-rh-middle)"
_rh_base_72="$ROOT/rh_base_72_$$"
mkdir -p "$_rh_base_72"
tgt="$_rh_base_72/rh_corpus72"
mkcorpus "$tgt" 4 "m"
{ printf '# targets\n\n| # | name | maturity | path | artifact | extra |\n|---|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - | - |\n' "$kit"
  printf '| 1 | tgt | mature (4 md / git yes) | `/slug/x2` | `$RESEARCH_HOME/rh_corpus72` | `/slug/y2` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_72" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_72
if [ "$RC" = 0 ] \
   && grep -qE '\· 0 absent target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "72 real \$RESEARCH_HOME token MIDDLE among 3 row tokens → row NOT absent" "(exit $RC)"
else
  no "72 real \$RESEARCH_HOME token MIDDLE among 3 row tokens → row NOT absent" "exit=$RC out=[$OUT]"
fi

# 73 — LIST-EDGE (LAST): the real token is the LAST of three backtick tokens — the shape the
#      any-dir loop must walk furthest to reach (list-edge companion to test 71's FIRST case).
kit="$(mkkit c73-rh-last)"
_rh_base_73="$ROOT/rh_base_73_$$"
mkdir -p "$_rh_base_73"
tgt="$_rh_base_73/rh_corpus73"
mkcorpus "$tgt" 1 "l"
{ printf '# targets\n\n| # | name | maturity | path | artifact | extra |\n|---|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - | - |\n' "$kit"
  printf '| 1 | tgt | mature (1 md / git yes) | `/slug/x3` | `/slug/y3` | `$RESEARCH_HOME/rh_corpus73` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_73" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_73
if [ "$RC" = 0 ] \
   && grep -qE '\· 0 absent target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "73 real \$RESEARCH_HOME token LAST among 3 row tokens → row NOT absent" "(exit $RC)"
else
  no "73 real \$RESEARCH_HOME token LAST among 3 row tokens → row NOT absent" "exit=$RC out=[$OUT]"
fi

# 74 — BRACED FORM: the real corpus token is written `${RESEARCH_HOME}/...` (braced) alongside a
#      slug companion. Both the unbraced and braced forms must be recognised by the any-dir check.
kit="$(mkkit c74-rh-braced)"
_rh_base_74="$ROOT/rh_base_74_$$"
mkdir -p "$_rh_base_74"
tgt="$_rh_base_74/rh_corpus74"
mkcorpus "$tgt" 2 "b"
{ printf '# targets\n\n| # | name | maturity | path | artifact |\n|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - |\n' "$kit"
  printf '| 1 | tgt | mature (2 md / git yes) | `${RESEARCH_HOME}/rh_corpus74` | `/slug/z4` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_74" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_74
if [ "$RC" = 0 ] \
   && grep -qE '\· 0 absent target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "74 braced \${RESEARCH_HOME} real token + /slug companion → row NOT absent" "(exit $RC)"
else
  no "74 braced \${RESEARCH_HOME} real token + /slug companion → row NOT absent" "exit=$RC out=[$OUT]"
fi

# 75 — ALL-ABSENT SURVIVES with a $RESEARCH_HOME token in the mix (§7 guard must not regress): a
#      row whose tokens are a NONEXISTENT `$RESEARCH_HOME/...` path plus a nonexistent `/abs` path —
#      neither resolves — must still be counted absent exactly ONCE (row-level dedup), not silently
#      cleared by the wider token recognition and not double-counted per token.
kit="$(mkkit c75-rh-all-absent)"
_rh_base_75="$ROOT/rh_base_75_$$"
mkdir -p "$_rh_base_75"
{ printf '# targets\n\n| # | name | maturity | path | artifact |\n|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - |\n' "$kit"
  printf '| 1 | tgt | mature (5 md / git yes) | `$RESEARCH_HOME/nope-75` | `/absent/nope-75b` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_75" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_75
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && grep -qE '· 1 absent target' <<<"$OUT" \
   && ! grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "75 \$RESEARCH_HOME token + absent slug, both absent → counted ONCE (§7 guard survives)" "(exit $RC)"
else
  no "75 \$RESEARCH_HOME token + absent slug, both absent → expected exactly 1 absent" "exit=$RC out=[$OUT]"
fi

# 76 — NARROW-REGEX CONTROL (kit issue #1044 item 2): the ABSENT-PATHS-CHECK token regex accepts
#      ONLY `/abs`, `$RESEARCH_HOME/rest` and `${RESEARCH_HOME}/rest`. A row whose registered path
#      is absent plus a companion `$OTHER_VAR/real` token must stay ABSENT even when a directory
#      literally named `$OTHER_VAR/real` exists relative to the CWD: only $RESEARCH_HOME is
#      expanded, so a widened alternation (`\$[^/`]*/`) would test that literal directory and
#      silently clear the row. The fixture creates the literal directory so widening is observable.
kit="$(mkkit c76-other-var)"
_rh_base_76="$ROOT/rh_base_76_$$"
_cwd_76="$ROOT/cwd_76_$$"
mkdir -p "$_rh_base_76" "$_cwd_76"'/$OTHER_VAR/real'
{ printf '# targets\n\n| # | name | maturity | path | artifact |\n|---|---|---|---|---|\n'
  printf '| 0 | kit | active (0 md / nc / git yes) | `%s` | - |\n' "$kit"
  printf '| 1 | tgt | mature (5 md / git yes) | `$RESEARCH_HOME/nope-76` | `$OTHER_VAR/real` |\n'
} > "$kit/TARGETS.md"
OUT="$(cd "$_cwd_76" && RESEARCH_HOME="$_rh_base_76" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && grep -qE 'INFO.*1 registered target.*absent' <<<"$OUT" \
   && grep -qE '· 1 absent target' <<<"$OUT"; then
  ok "76 \$OTHER_VAR token (literal dir exists) is NOT a row path → row stays absent (#1044)" "(exit $RC)"
else
  no "76 \$OTHER_VAR token (literal dir exists) is NOT a row path → row stays absent (#1044)" "exit=$RC out=[$OUT]"
fi


# ---- kit issue #1818: the state file is picked by lib/state-files.sh resolve_state_file (root beats
# focus, shallowest first), NOT by a lexical sort. verify-registry reads the corpus DIRECTORY of the
# picked file, so the fixtures put root and focus file in DIFFERENT same-depth directories with different
# block counts: the old lexical `sort | head -1` picked a/RESEARCH-STATE-x.md (1 block), the resolver
# picks b/RESEARCH-STATE.md (6 blocks).
mk1818() { # <dir>  -> a/ = focus file + 1 block, b/ = root + 6 blocks
  mkdir -p "$1/a"; printf '# focus state\n' > "$1/a/RESEARCH-STATE-x.md"; printf '# B\n' > "$1/a/a-block1.md"
  mkcorpus "$1/b" 6 "b"
}
# 1818a — root beats a lexically-earlier focus file: claim 6 md == the root's corpus (6) → no drift.
kit="$(mkkit c1818a-rootpref)"; tgt="$ROOT/c1818a-ext-tgt"; mk1818 "$tgt"
write_targets "$kit" "$tgt::6 md"
run "$kit"
if [ "$RC" = 0 ] && grep -q '0 count drift' <<<"$OUT" && ! grep -q 'refresh the row' <<<"$OUT" && ! grep -q 'not resolvable' <<<"$OUT"; then
  ok "1818a root + focus in sibling dirs → the ROOT's corpus is read (claim 6 == 6, no drift)" "(exit $RC)"
else
  no "1818a root + focus in sibling dirs → the ROOT's corpus is read" "exit=$RC out=[$OUT]"
fi
# 1818a2 — the converse: claiming the FOCUS dir's count (1) must now drift against the root's 6.
kit="$(mkkit c1818a2-rootpref)"; tgt="$ROOT/c1818a2-ext-tgt"; mk1818 "$tgt"
write_targets "$kit" "$tgt::1 md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE 'claims 1 md but the corpus has 6 real block' <<<"$OUT"; then
  ok "1818a2 claim 1 vs the root's 6 → drift names 6 (not the focus dir's 1)" "(exit $RC)"
else
  no "1818a2 claim 1 vs the root's 6 → drift names 6" "exit=$RC out=[$OUT]"
fi
# 1818b — SPLIT layout (two dirs, each with a root): resolver rc 2 tie → the C-locale-first pick (a/, 2 blocks)
# is used; no crash, no 'not resolvable', no dropped target.
kit="$(mkkit c1818b-split)"; tgt="$ROOT/c1818b-ext-tgt"
mkcorpus "$tgt/a" 2 "a"; mkcorpus "$tgt/b" 6 "b"
write_targets "$kit" "$tgt::2 md"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Summary: reconciled 2 target' <<<"$OUT" && grep -q '0 count drift' <<<"$OUT" && ! grep -q 'not resolvable' <<<"$OUT"; then
  ok "1818b split layout tie → first pick (a/, 2 blocks) used, target not dropped" "(exit $RC)"
else
  no "1818b split layout tie → first pick used, target not dropped" "exit=$RC out=[$OUT]"
fi
# 1818c — nc-contradiction site reads the SAME resolver: the WARN names the ROOT file, not the focus file.
kit="$(mkkit c1818c-nc)"; tgt="$kit/targetNC"; mk1818 "$tgt"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC | intermediate (6 md / nc / git no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE 'a RESEARCH-STATE.md was found at .*/b/RESEARCH-STATE\.md' <<<"$OUT"; then
  ok "1818c nc-contradiction names the ROOT file (b/RESEARCH-STATE.md), not the focus file" "(exit $RC)"
else
  no "1818c nc-contradiction names the ROOT file" "exit=$RC out=[$OUT]"
fi

# 2129 — SessionStart budget WARNs (opt-in RSDD_REGISTRY_SESSION_BUDGET=1; the check RUNS hooks).
mk2129() { # <kit-name>  -> a kit whose one target wires an 10,500-char SessionStart hook
  kit="$(mkkit "$1")"; tgt="$kit/targetB"; mkcorpus "$tgt" 3 "a"; mkdir -p "$tgt/.claude/hooks"
  printf '#!/usr/bin/env bash\ncat >/dev/null; head -c 10500 /dev/zero | tr "\\0" x\n' > "$tgt/.claude/hooks/big.sh"; chmod +x "$tgt/.claude/hooks/big.sh"
  printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/big.sh"}]}]}}\n' > "$tgt/.claude/settings.json"
  cp "$HERE/../verify-session-budget.sh" "$kit/toolbelt/verify-session-budget.sh"
  # verify-session-budget.sh is an rsdd shim (kit issue #2364): the stub kit needs lib/rsdd-exec.sh and a
  # prebuilt rsdd (built once into $ROOT, never into the tree), since the stub kit has no rsdd/ source.
  mkdir -p "$kit/toolbelt/lib"; cp "$HERE/../lib/rsdd-exec.sh" "$kit/toolbelt/lib/rsdd-exec.sh"   # stage-libs-ok: one shim lib for the stub kit of case 2129a, not a lib set
  if [ "${_vr2129_bw:-}" = usable ] && { [ -z "${RSDD_BIN:-}" ] || [ ! -x "${RSDD_BIN:-}" ]; }; then
    RSDD_BIN="$ROOT/rsdd"
    ( cd "$HERE/../../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$RSDD_BIN" ./cmd/rsdd ) >"$ROOT/rsdd-build.log" 2>&1 \
      || no "2129 cannot build rsdd for the verify-session-budget shim" "$(tail -n 5 "$ROOT/rsdd-build.log")"
    export RSDD_BIN
  fi
  nsrow "$kit" "$tgt" '3 md / git yes'
}
# The sandbox-dependent case 2129a needs a USABLE unprivileged bwrap (probed once); otherwise a typed SKIP (FAIL under RSDD_REQUIRE_BWRAP=1). 2129d uses a stub budget script and needs no bwrap.
_vr2129_bw="$(vr_bw_gate)"
# Gate self-test (kit issue #2138): a failing bwrap shim first on PATH makes bwrap unusable; the probe-only
# self-invocation must report fail (exit 1) with RSDD_REQUIRE_BWRAP=1 and skip (exit 0) without it.
_vr_shim="$ROOT/vr-shim-bw"; mkdir -p "$_vr_shim"; printf '#!/bin/sh\nexit 1\n' > "$_vr_shim/bwrap"; chmod +x "$_vr_shim/bwrap"
_o="$(PATH="$_vr_shim:$PATH" VR_BW_GATE_PROBE=1 RSDD_REQUIRE_BWRAP=1 "$BASH_BIN" "$HERE/verify-registry.test.sh" 2>&1)"; _rc=$?
if [ "$_rc" = 1 ] && [ "$_o" = "gate=fail" ]; then ok "2129 gate: unusable bwrap + RSDD_REQUIRE_BWRAP=1 -> fail, exit 1"; else no "2129 gate require-flag" "rc=$_rc out=[$_o]"; fi
_o="$(PATH="$_vr_shim:$PATH" VR_BW_GATE_PROBE=1 RSDD_REQUIRE_BWRAP=0 "$BASH_BIN" "$HERE/verify-registry.test.sh" 2>&1)"; _rc=$?
if [ "$_rc" = 0 ] && [ "$_o" = "gate=skip" ]; then ok "2129 gate: unusable bwrap without the flag -> skip, exit 0"; else no "2129 gate skip path" "rc=$_rc out=[$_o]"; fi
mk2129 c2129a
OUT="$(RSDD_REGISTRY_SESSION_BUDGET=1 "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$_vr2129_bw" = fail ]; then no "2129a RSDD_REQUIRE_BWRAP=1 but no usable bwrap/timeout (case would SKIP)"
elif [ "$_vr2129_bw" != usable ]; then printf '  SKIP  2129a opt-in budget WARNs (no usable bwrap)\n'
elif [ "$RC" = 0 ] && grep -qE 'WARN[[:space:]]+targetB — a SessionStart hook emits more than 10,000 characters' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+targetB — SessionStart hooks total 10500 characters, over the kit.*worst session source: startup' <<<"$OUT"; then
  ok "2129a opt-in + 10,500-char SessionStart hook → truncation and over-budget WARNs" "(exit $RC)"
else no "2129a opt-in budget WARNs" "exit=$RC out=[$OUT]"; fi
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'SessionStart' <<<"$OUT"; then
  ok "2129b default (opt-in off) → hooks are NOT run, no budget finding" "(exit $RC)"
else no "2129b default run must not execute hooks" "exit=$RC out=[$OUT]"; fi
mk2129 c2129f
rm -f "$kit/toolbelt/verify-session-budget.sh"
OUT="$(RSDD_REGISTRY_SESSION_BUDGET=1 "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -qE 'WARN[[:space:]]+targetB — SessionStart budget check could not run' <<<"$OUT"; then
  ok "2129c opt-in with the budget script missing → degraded WARN, not a silent zero" "(exit $RC)"
else no "2129c missing budget script → degraded" "exit=$RC out=[$OUT]"; fi

# ---- the SHIM itself (cases S1-S5) ------------------------------------------------------------------------------
# A drift fixture shared by S1 and the teeth: claim 40 md, real 5 → one drift WARN naming targetA.
S_kit="$(mkkit s-drift)"; S_tgt="$ROOT/s-ext-tgt"; mkcorpus "$S_tgt" 5 "a"; write_targets "$S_kit" "$S_tgt::40 md"
S_DRIFT='WARN[[:space:]]+s-ext-tgt — TARGETS.md row claims 40 md but the corpus has 5 real block file'   # names the sandbox's own target
S_OUT="$("$BASH_BIN" "$S_kit/toolbelt/verify-registry.sh" 2>&1)"; S_RC=$?
# S1 — the shim hands the binary ITS kit: the sandbox kit's own TARGETS.md is reconciled (exit 0, drift named).
if [ "$S_RC" = 0 ] && grep -qE "$S_DRIFT" <<<"$S_OUT"; then
  ok "S1 the shim reconciles the TARGETS.md beside its own toolbelt (sandbox kit, its own drift named)" "(exit $S_RC)"
else no "S1 kit hand-off" "exit=$S_RC out=[$S_OUT]"; fi
# S2 — arguments pass through: --json prints the envelope, an unknown argument is a usage error (exit 2, usage on stderr only).
S_J="$("$BASH_BIN" "$S_kit/toolbelt/verify-registry.sh" --json 2>"$ROOT/s2.err")"; S_JRC=$?
S_U="$("$BASH_BIN" "$S_kit/toolbelt/verify-registry.sh" --bogus 2>"$ROOT/s2u.err")"; S_URC=$?
if [ "$S_JRC" = 0 ] && grep -q '"schema": "research-sdd.verify-registry/v1"' <<<"$S_J" \
   && [ "$S_URC" = 2 ] && [ -z "$S_U" ] && grep -q '^verify-registry: unknown argument: --bogus$' "$ROOT/s2u.err" && grep -q '^usage: verify-registry.sh \[--json\]$' "$ROOT/s2u.err"; then
  ok "S2 --json reaches the binary (envelope) and an unknown argument is a usage error (exit 2)" "()"
else no "S2 argument pass-through" "json rc=$S_JRC usage rc=$S_URC out=[$S_U] err=[$(cat "$ROOT/s2u.err")]"; fi
# S3 — the shim's own lib missing → a typed degraded line, rc 2, nothing on stdout (never a silent pass).
mkdir -p "$ROOT/s3"; cp "$SUT" "$ROOT/s3/verify-registry.sh"
S3_OUT="$("$BASH_BIN" "$ROOT/s3/verify-registry.sh" 2>"$ROOT/s3.err")"; S3_RC=$?
if [ "$S3_RC" = 2 ] && [ -z "$S3_OUT" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $ROOT/s3/verify-registry.sh\$" "$ROOT/s3.err"; then
  ok "S3 missing rsdd-exec.sh → typed degraded line, rc 2" "()"
else no "S3 missing lib" "rc=$S3_RC out=[$S3_OUT] err=[$(cat "$ROOT/s3.err")]"; fi
# S4 — an unusable RSDD_BIN → typed degraded line, rc 2: the measurement could not run, which is not a pass.
S4_OUT="$(RSDD_BIN="$ROOT/does-not-exist" "$BASH_BIN" "$S_kit/toolbelt/verify-registry.sh" 2>"$ROOT/s4.err")"; S4_RC=$?
if [ "$S4_RC" = 2 ] && [ -z "$S4_OUT" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$ROOT/s4.err"; then
  ok "S4 unusable RSDD_BIN → typed degraded line, rc 2" "()"
else no "S4 unusable binary" "rc=$S4_RC out=[$S4_OUT] err=[$(cat "$ROOT/s4.err")]"; fi
# S5 — run through a symlink (the idiom installed corpora use): the shim still finds its lib and ITS kit.
ln -s "$S_kit/toolbelt/verify-registry.sh" "$ROOT/s5-link.sh"
S5_OUT="$("$BASH_BIN" "$ROOT/s5-link.sh" 2>&1)"; S5_RC=$?
if [ "$S5_RC" = "$S_RC" ] && [ "$S5_OUT" = "$S_OUT" ]; then ok "S5 a symlinked shim resolves its own directory and kit (same report)" "()"
else no "S5 symlinked shim" "rc=$S5_RC out=[$S5_OUT]"; fi

# NEGATIVE CONTROL — each shim mutation must lose the case that pins it (the Go source has its own mutation gate).
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut() { rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  # mut_kit <name> <mutant-script> : a sandbox kit like s-drift whose shim is the mutant.
  mut_kit() { local k; k="$(mkkit "$1")"; write_targets "$k" "$S_tgt::40 md"; cp "$2" "$k/toolbelt/verify-registry.sh"; printf '%s' "$k"; }
  echo "-- teeth: each shim mutation must lose its case --"
  # Control first: the UNMUTATED shim, run the same way, must show each fragment, so a mutant that merely crashes or
  # finds no binary can never read as a bite (an absence only counts when the original shows the fragment).
  O_kit="$(mut_kit tm-O "$SUT")"
  grep -qE "$S_DRIFT" <<<"$("$BASH_BIN" "$O_kit/toolbelt/verify-registry.sh" 2>&1)" \
    || { no "teeth control: the unmutated shim does not report the sandbox drift (teeth A/C would be vacuous)"; }
  grep -q 'research-sdd.verify-registry/v1' <<<"$("$BASH_BIN" "$O_kit/toolbelt/verify-registry.sh" --json 2>&1)" \
    || { no "teeth control: the unmutated shim prints no --json envelope (teeth B would be vacuous)"; }
  mkdir -p "$ROOT/mO"; cp "$SUT" "$ROOT/mO/verify-registry.sh"; "$BASH_BIN" "$ROOT/mO/verify-registry.sh" >/dev/null 2>"$ROOT/errO"
  grep -q 'rsdd-exec.sh missing beside' "$ROOT/errO" \
    || { no "teeth control: the unmutated shim does not announce a missing lib (teeth D would be vacuous)"; }
  # A: the kit hand-off dropped → the binary reconciles some other kit (or none): S1 loses the sandbox's drift.
  if mk_mut "teeth A: --kit dropped" "$SUT" "$ROOT/mutA.sh" 's/ --kit "\$KIT"//'; then
    A_kit="$(mut_kit tm-A "$ROOT/mutA.sh")"; A_OUT="$("$BASH_BIN" "$A_kit/toolbelt/verify-registry.sh" 2>&1)"
    if ! grep -qE "$S_DRIFT" <<<"$A_OUT"; then ok "teeth A: no --kit → the sandbox kit's drift is not reported, S1 would go RED"; else no "teeth A: mutant still reconciles the sandbox kit"; fi
  fi
  # B: the arguments dropped → --json ignored: S2 loses the envelope.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$ROOT/mutB.sh" 's/ "\$@"$//'; then
    B_kit="$(mut_kit tm-B "$ROOT/mutB.sh")"; B_OUT="$("$BASH_BIN" "$B_kit/toolbelt/verify-registry.sh" --json 2>&1)"
    if ! grep -q 'research-sdd.verify-registry/v1' <<<"$B_OUT"; then ok "teeth B: arguments dropped → --json prints no envelope, S2 would go RED"; else no "teeth B: mutant still prints the envelope"; fi
  fi
  # C: the wrong command → no report: S1 loses its drift.
  if mk_mut "teeth C: wrong command" "$SUT" "$ROOT/mutC.sh" 's/verify registry/verify registryx/'; then
    C_kit="$(mut_kit tm-C "$ROOT/mutC.sh")"; C_OUT="$("$BASH_BIN" "$C_kit/toolbelt/verify-registry.sh" 2>&1)"; C_RC=$?
    if [ "$C_RC" != 0 ] && ! grep -qE "$S_DRIFT" <<<"$C_OUT"; then ok "teeth C: wrong command → no report and a failing exit, S1 would go RED"; else no "teeth C: mutant rc=$C_RC still reports"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line: S3 loses it.
  if mk_mut "teeth D: guard removed" "$SUT" "$ROOT/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$ROOT/mD"; cp "$ROOT/mutD.sh" "$ROOT/mD/verify-registry.sh"
    "$BASH_BIN" "$ROOT/mD/verify-registry.sh" >/dev/null 2>"$ROOT/errD"
    if ! grep -q 'rsdd-exec.sh missing beside' "$ROOT/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib, S3 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
