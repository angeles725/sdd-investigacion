#!/usr/bin/env bash
# regen.sh — regenerate the envelope golden fixtures from REAL `--json` runs of the kit instruments.
#
#   regen.sh                 write the goldens next to this script
#   regen.sh --out DIR       write them to DIR instead
#   regen.sh --verify        generate twice into scratch dirs; fail unless the two runs are byte-identical
#                            to each other AND to the committed goldens (frozen-fixture check)
#
# HERMETIC: every corpus is built in a mktemp dir from scratch (the layout the kit suites
# sweep-retros.test.sh `jfix` and verify-registry-json.test.sh `rich_kit`/`clean_kit` use), the instruments
# run under `env -i` with HOME/RESEARCH_HOME/TMPDIR pointing into that dir, so neither the live TARGETS.md
# nor any real corpus or ambient RSDD_* variable is read. The temp dir is removed on EXIT.
# Run-specific values are normalised: sandbox paths -> @ROOT@/@KIT@, retro ages -> 0 (the age depends on
# today's date; age_state stays "counted").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBELT="$(cd "$HERE/../../../../../toolbelt" && pwd)"
BASH_BIN="$(type -P bash)"
command -v jq >/dev/null 2>&1 || { echo "regen.sh: jq is required" >&2; exit 2; }

gen() {  # gen <outdir>
  local out="$1" ROOT W
  mkdir -p "$out" || return 2
  ROOT="$(mktemp -d)" || return 2
  ROOT="$(cd "$ROOT" && pwd -P)"
  trap 'rm -rf "$ROOT"' RETURN
  W="$ROOT/w"; mkdir -p "$W" "$ROOT/home" "$ROOT/tmp"

  local -a ENVV=(env -i PATH="$PATH" HOME="$ROOT/home" RESEARCH_HOME="$ROOT/home" TMPDIR="$ROOT/tmp"
    RSDD_HOOK_WIRING_CEILING="$ROOT" RSDD_CLAUDE_PROJECTS_DIR=/nonexistent/rsdd-claude-history
    RSDD_RETRO_AGE_DAYS=99999 LC_ALL=C)

  mkkit() {  # mkkit <name> <script> <lib...>
    local kit="$W/$1" s="$2" l; shift 2
    mkdir -p "$kit/toolbelt/lib"
    cp "$TOOLBELT/$s" "$kit/toolbelt/$s"
    for l in "$@"; do cp "$TOOLBELT/lib/$l.sh" "$kit/toolbelt/lib/$l.sh"; done
    printf '%s' "$kit"
  }
  mkretro() {  # mkretro <target> <file> <marker|-> <ndeltas>
    local tgt="$1" f="$2" marker="$3" nd="$4" i=0
    mkdir -p "$tgt/retros"
    { [ "$marker" = "-" ] || printf '%s\n' "$marker"
      printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
      while [ "$i" -lt "$nd" ]; do i=$((i+1)); printf '| %d | delta %d | because |\n' "$i" "$i"; done
    } > "$tgt/retros/$f"
  }
  wire_target() {
    mkdir -p "$1/.claude"
    printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}\n' > "$1/.claude/settings.json"
  }
  mkcorpus() {  # mkcorpus <dir> <n> <prefix>
    local dir="$1" n="$2" prefix="$3" i=0
    mkdir -p "$dir"
    printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: %d\n<!-- /research-state.v1 -->\n' "$n" > "$dir/RESEARCH-STATE.md"
    while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '# Block %d\n' "$i" > "$dir/${prefix}-block${i}.md"; done
  }
  sr_targets() {  # sr_targets <kit> <path...>
    local kit="$1"; shift
    { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
      local i=0 t; for t in "$@"; do i=$((i+1)); printf '| %d | t%d | `%s` |\n' "$i" "$i" "$t"; done
    } > "$kit/TARGETS.md"
  }
  vr_targets() {  # vr_targets <kit> <path::claim...>
    local kit="$1"; shift
    { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
      printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
      local i=0 spec p claim
      for spec in "$@"; do
        i=$((i+1)); p="${spec%%::*}"; claim="${spec#*::}"
        printf '| %d | t%d | mature (%s / git yes) | `%s` |\n' "$i" "$i" "$claim" "$p"
      done
    } > "$kit/TARGETS.md"
  }

  # --- sweep-retros: one pending (3 deltas), one applied, one unmarked, plus an absent target (state ok)
  local kit tgt ext
  kit="$(mkkit sr sweep-retros.sh retro-status target-paths block-files retro-grammar hook-wiring)"; tgt="$kit/targetA"
  mkretro "$tgt" p1.md "<!-- review-status: pending -->" 3
  mkretro "$tgt" a1.md "<!-- review-status: applied 2026-01-01 -->" 2
  mkretro "$tgt" n1.md "-" 1
  touch -d '2026-01-02 00:00:00 UTC' "$tgt/retros/p1.md"; touch -d '2026-01-03 00:00:00 UTC' "$tgt/retros/n1.md"
  wire_target "$tgt"; sr_targets "$kit" "$tgt" "$kit/targetB-absent"
  "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" --json 2>/dev/null \
    | sed -e "s#$W/[^/\"]*/#@KIT@/#g" -e 's/"age_days": [0-9][0-9]*/"age_days": 0/' > "$out/sweep-retros-ok.golden"

  # --- sweep-retros: every target absent (state absent-input, reason set, items empty)
  kit="$(mkkit sr-abs sweep-retros.sh retro-status target-paths block-files retro-grammar hook-wiring)"
  sr_targets "$kit" "$kit/gone"
  "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" --json 2>/dev/null \
    | sed -e "s#$W/[^/\"]*/#@KIT@/#g" > "$out/sweep-retros-absent.golden"

  # --- verify-registry: rich fixture (many finding kinds, state ok)
  kit="$(mkkit vr-rich verify-registry.sh retro-status target-paths block-files state-files corpus-markers hook-wiring)"; ext="$W/vr-rich-ext"
  mkcorpus "$ext/tA" 5 a; mkdir -p "$ext/tB"; mkcorpus "$ext/tD" 3 d
  vr_targets "$kit" "$ext/tA::40 md / 2 retros / bogus thing" "$ext/tB::3 md" "$ext/tC-gone::4 md" \
    "$ext/tD::3 md / hook yes" "$ext/trunc...ated::1 md"
  printf '| 9 | long | %s |\n' "$(printf 'x%.0s' $(seq 1 260))" >> "$kit/TARGETS.md"
  local vnorm=(-e "s#$ROOT/home#@ROOT@/home#g" -e "s#$W/[^/ \"]*-ext/#@ROOT@/EXT/#g" -e "s#$W/[^/ \"]*/#@KIT@/#g" -e "s#$ROOT#@ROOT@#g")
  "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json 2>/dev/null | sed "${vnorm[@]}" > "$out/verify-registry-ok.golden"

  # --- verify-registry: clean registry (state no-match, reason set, items empty)
  kit="$(mkkit vr-clean verify-registry.sh retro-status target-paths block-files state-files corpus-markers hook-wiring)"; ext="$W/vr-clean-ext"
  mkcorpus "$ext/tA" 5 a; mkdir -p "$ext/tA/retros"; printf '# r\n' > "$ext/tA/retros/r1.md"
  vr_targets "$kit" "$ext/tA::5 md"
  "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json 2>/dev/null | sed "${vnorm[@]}" > "$out/verify-registry-nomatch.golden"

  # --- edge: jq's own rendering of the escape / nesting edge cases (input is committed, static)
  jq . "$HERE/edge.in.json" > "$out/edge.golden"
}

case "${1:-}" in
  "") gen "$HERE" ;;
  --out) [ -n "${2:-}" ] || { echo "usage: regen.sh [--out DIR | --verify]" >&2; exit 2; }; gen "$2" ;;
  --verify)
    S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
    gen "$S/a" && gen "$S/b" || { echo "regen.sh: generation failed" >&2; exit 1; }
    n=0; rc=0
    for f in "$S"/a/*.golden; do
      b="$(basename "$f")"; n=$((n+1))
      [ -s "$f" ] || { echo "FAIL empty: $b" >&2; rc=1; }
      cmp -s "$f" "$S/b/$b" || { echo "FAIL run1 != run2: $b" >&2; rc=1; }
      cmp -s "$f" "$HERE/$b" || { echo "FAIL differs from committed: $b" >&2; rc=1; }
    done
    [ "$n" -gt 0 ] || { echo "FAIL: no goldens generated" >&2; exit 1; }
    [ "$rc" = 0 ] && echo "regen.sh --verify: $n goldens, two runs byte-identical and equal to committed"
    exit "$rc" ;;
  *) echo "usage: regen.sh [--out DIR | --verify]" >&2; exit 2 ;;
esac
