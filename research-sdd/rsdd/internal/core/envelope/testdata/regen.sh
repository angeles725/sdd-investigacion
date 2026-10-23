#!/usr/bin/env bash
# regen.sh — regenerate the envelope golden fixtures from REAL `--json` runs of the four kit instruments
# (sweep-retros, verify-registry, resume-state, retro-gate) plus jq's own rendering of the edge cases.
#
#   regen.sh                 generate into a scratch dir, and only when EVERY run succeeded move the files
#                            next to this script (an instrument failure leaves the committed goldens untouched)
#   regen.sh --out DIR       same, but into DIR
#   regen.sh --verify        generate twice into scratch dirs; fail unless the two runs are byte-identical to
#                            each other AND to the committed goldens (frozen-fixture check; nothing is written)
#
# HERMETIC: every corpus and repository is built in a mktemp dir from scratch (the layouts the kit suites
# sweep-retros.test.sh `jfix`, verify-registry-json.test.sh `rich_kit`/`clean_kit`, resume-state-json.test.sh
# and retro-gate.test.sh `mkjt` use). The instruments run under `env -i` with HOME/RESEARCH_HOME/TMPDIR
# pointing into that dir and git's global/system config disabled, so neither the live TARGETS.md nor any
# real corpus, repository, gh login or ambient RSDD_*/GIT_* variable is read. The temp dir is removed on EXIT.
#
# Every instrument run is checked: its exit code must be the expected one, stdout must be exactly one JSON
# document, and any failure aborts the whole run with the instrument's stderr (nothing is written).
# Run-specific values are normalised: sandbox paths -> @ROOT@/@KIT@, 40-hex shas -> @SHA@, generated_at -> @T@,
# retro ages -> 0 (the age depends on today's date; age_state stays "counted").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBELT="$(cd "$HERE/../../../../../toolbelt" && pwd)" || { echo "regen.sh: toolbelt dir not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"
for t in jq git sed mktemp cp mv cmp touch ln; do
  command -v "$t" >/dev/null 2>&1 || { echo "regen.sh: required tool missing: $t" >&2; exit 2; }
done
[ -n "$BASH_BIN" ] || { echo "regen.sh: bash not on PATH" >&2; exit 2; }

# fail <message...>: print and return 1 so a caller's `|| return 1` aborts the run.
fail() { echo "regen.sh: $*" >&2; return 1; }

gen() {  # gen <outdir> ; every step is checked, the first failure aborts
  local out="$1" ROOT W ENVV GITV KITDIR
  KITDIR="$(cd "$TOOLBELT/.." && pwd)" || return 1
  mkdir -p "$out" || return 1
  ROOT="$(mktemp -d)" || return 1
  ROOT="$(cd -P "$ROOT" && pwd)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$ROOT'" RETURN
  W="$ROOT/w"; mkdir -p "$W" "$ROOT/home" "$ROOT/tmp" "$ROOT/gh" || return 1
  # A gh that always fails: a gate verdict must never reach the real GitHub seeder.
  printf '#!/bin/sh\nexit 1\n' > "$ROOT/gh/gh" && chmod +x "$ROOT/gh/gh" || return 1

  # RSDD_RETRO_AGE_DAYS=99999 turns the sweep's "ESCALATED" age tag off: a retro is escalated once older than
  # this many days, which would make the golden depend on today's date (the kit suites pin the same value).
  ENVV=(env -i PATH="$PATH" HOME="$ROOT/home" RESEARCH_HOME="$ROOT/home" TMPDIR="$ROOT/tmp"
    RSDD_HOOK_WIRING_CEILING="$ROOT" RSDD_CLAUDE_PROJECTS_DIR=/nonexistent/rsdd-claude-history
    RSDD_RETRO_AGE_DAYS=99999 LC_ALL=C
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1)
  GITV=("${ENVV[@]}" git -c user.name=tester -c user.email=t@example.com -c commit.gpgsign=false)

  # run_json <label> <expected_rc> <stdin-file|-> <cmd...> : RAW = file holding stdout.
  run_json() {
    local label="$1" want="$2" in="$3" rc; shift 3
    RAW="$ROOT/raw.$label"
    if [ "$in" = - ]; then "$@" >"$RAW" 2>"$ROOT/err.$label" </dev/null; else "$@" >"$RAW" 2>"$ROOT/err.$label" <"$in"; fi
    rc=$?
    if [ "$rc" != "$want" ]; then
      echo "regen.sh: $label exited $rc, want $want; stderr follows" >&2; sed 's/^/  | /' "$ROOT/err.$label" >&2; return 1
    fi
    [ -s "$RAW" ] || fail "$label printed nothing on stdout" || return 1
    jq -s -e 'length == 1' "$RAW" >/dev/null 2>&1 || fail "$label stdout is not exactly one JSON document" || return 1
  }
  # The gate's block reason cites the kit checkout (its retro template) and today's date in the suggested file
  # name; both are run-specific, so they are normalised like the sandbox paths.
  norm_paths() { sed -E -e "s#$KITDIR#@KITDIR@#g" -e 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}-<focus>/@DATE@-<focus>/g' -e "s#$ROOT/home#@ROOT@/home#g" -e "s#$W/[^/ \"]*-ext/#@ROOT@/EXT/#g" -e "s#$W/[^/ \"]*/#@KIT@/#g" -e "s#$ROOT#@ROOT@#g"; }

  mkkit() {  # mkkit <name> <script> <lib...> : a runnable COPY of the script and its libs; echoes the kit dir
    local kit="$W/$1" s="$2" l; shift 2
    mkdir -p "$kit/toolbelt/lib" && cp "$TOOLBELT/$s" "$kit/toolbelt/$s" || return 1
    for l in "$@"; do cp "$TOOLBELT/lib/$l.sh" "$kit/toolbelt/lib/$l.sh" || return 1; done
    printf '%s' "$kit"
  }
  mkretro() {  # mkretro <target> <file> <marker|-> <ndeltas>
    local tgt="$1" f="$2" marker="$3" nd="$4" i=0
    mkdir -p "$tgt/retros" || return 1
    { [ "$marker" = "-" ] || printf '%s\n' "$marker"
      printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
      while [ "$i" -lt "$nd" ]; do i=$((i+1)); printf '| %d | delta %d | because |\n' "$i" "$i"; done
    } > "$tgt/retros/$f"
  }
  wire_target() {
    mkdir -p "$1/.claude" || return 1
    printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}\n' > "$1/.claude/settings.json"
  }
  mkcorpus() {  # mkcorpus <dir> <n> <prefix>
    local dir="$1" n="$2" prefix="$3" i=0
    mkdir -p "$dir" || return 1
    printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: %d\n<!-- /research-state.v1 -->\n' "$n" > "$dir/RESEARCH-STATE.md" || return 1
    while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '# Block %d\n' "$i" > "$dir/${prefix}-block${i}.md" || return 1; done
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

  local kit tgt ext

  # --- sweep-retros: one pending (3 deltas), one applied, one unmarked, plus an absent target (state ok)
  kit="$(mkkit sr sweep-retros.sh retro-status target-paths block-files retro-grammar hook-wiring)" || return 1; tgt="$kit/targetA"
  mkretro "$tgt" p1.md "<!-- review-status: pending -->" 3 && mkretro "$tgt" a1.md "<!-- review-status: applied 2026-01-01 -->" 2 \
    && mkretro "$tgt" n1.md "-" 1 || return 1
  touch -d '2026-01-02 00:00:00 UTC' "$tgt/retros/p1.md" && touch -d '2026-01-03 00:00:00 UTC' "$tgt/retros/n1.md" || return 1
  wire_target "$tgt" && sr_targets "$kit" "$tgt" "$kit/targetB-absent" || return 1
  run_json sr-ok 0 - "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" --json || return 1
  norm_paths < "$RAW" | sed -E 's/"age_days": [0-9]+/"age_days": 0/' > "$out/sweep-retros-ok.golden" || return 1

  # --- sweep-retros: every target absent (state absent-input, reason set, items empty)
  kit="$(mkkit sr-abs sweep-retros.sh retro-status target-paths block-files retro-grammar hook-wiring)" || return 1
  sr_targets "$kit" "$kit/gone" || return 1
  run_json sr-abs 0 - "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" --json || return 1
  norm_paths < "$RAW" > "$out/sweep-retros-absent.golden" || return 1

  # --- verify-registry: rich fixture (many finding kinds, state ok)
  kit="$(mkkit vr-rich verify-registry.sh retro-status target-paths block-files state-files corpus-markers hook-wiring)" || return 1; ext="$W/vr-rich-ext"
  mkcorpus "$ext/tA" 5 a && mkdir -p "$ext/tB" && mkcorpus "$ext/tD" 3 d || return 1
  vr_targets "$kit" "$ext/tA::40 md / 2 retros / bogus thing" "$ext/tB::3 md" "$ext/tC-gone::4 md" \
    "$ext/tD::3 md / hook yes" "$ext/trunc...ated::1 md" || return 1
  printf '| 9 | long | %s |\n' "$(printf 'x%.0s' $(seq 1 260))" >> "$kit/TARGETS.md" || return 1
  run_json vr-ok 0 - "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json || return 1
  norm_paths < "$RAW" > "$out/verify-registry-ok.golden" || return 1

  # --- verify-registry: clean registry (state no-match, reason set, items empty)
  kit="$(mkkit vr-clean verify-registry.sh retro-status target-paths block-files state-files corpus-markers hook-wiring)" || return 1; ext="$W/vr-clean-ext"
  mkcorpus "$ext/tA" 5 a && mkdir -p "$ext/tA/retros" && printf '# r\n' > "$ext/tA/retros/r1.md" || return 1
  vr_targets "$kit" "$ext/tA::5 md" || return 1
  run_json vr-nomatch 0 - "${ENVV[@]}" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json || return 1
  norm_paths < "$RAW" > "$out/verify-registry-nomatch.golden" || return 1

  # --- resume-state: a throwaway repo with origin/main, a dirty worktree, a prunable one, a detached one and
  #     two loose branches (the resume-state-json.test.sh fixture), run with --no-gh (no network, PRs unknown).
  local R="$W/rs/r"
  mkdir -p "$R" || return 1
  (
    set -e
    G() { "${GITV[@]}" "$@"; }
    cd "$R"
    G init -q .; G symbolic-ref HEAD refs/heads/main
    echo a > a; G add a; G commit -q -m c1
    G init -q --bare "$R.origin"; G remote add origin "$R.origin"; G push -q origin main; G fetch -q origin
    G worktree add -q -b feat/a "$W/rs/wt-a" main
    ( cd "$W/rs/wt-a"; echo x > x; G add x; G commit -q -m a1; echo dirty >> a; echo u1 > u1 )
    echo m > m; G add m; G commit -q -m m2; G push -q origin main
    G branch loose main~1; G branch ahead1 main
    G checkout -q ahead1; echo z > z; G add z; G commit -q -m z1; G checkout -q main
    G worktree add -q --detach "$W/rs/wt-d" main~1
    G worktree add -q -b feat/p "$W/rs/wt-p" main
    rm -rf "$W/rs/wt-p"
  ) >"$ROOT/err.rs-setup" 2>&1 || { echo "regen.sh: resume-state fixture setup failed:" >&2; sed 's/^/  | /' "$ROOT/err.rs-setup" >&2; return 1; }
  run_json rs-ok 0 - "${ENVV[@]}" "$BASH_BIN" "$TOOLBELT/resume-state.sh" --cwd "$R" --no-gh --json || return 1
  norm_paths < "$RAW" | sed -E -e 's/[0-9a-f]{40}/@SHA@/g' -e 's/("generated_at": )"[^"]*"/\1"@T@"/' > "$out/resume-state-ok.golden" || return 1

  # --- retro-gate: a block (blocks edited since the session start, no retro) and a no-change allow
  mkjt() {  # mkjt <dir> <sid> <block|none> : the retro-gate.test.sh mkjt fixture
    local d="$1" sid="$2" mode="$3"
    mkdir -p "$d" || return 1
    (
      set -e
      cd "$d"
      "${GITV[@]}" init -q -b main
      touch .gitkeep; "${GITV[@]}" add -A
      GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" "${GITV[@]}" commit -q -m init
      mkdir -p .claude; "${GITV[@]}" rev-parse HEAD > ".claude/.rsdd-session-$sid"
      if [ "$mode" = block ]; then
        touch -t 202609050800 ".claude/.rsdd-session-$sid"
        printf '# Block — test\n\nContent.\n' > niagara-block1.md
        "${GITV[@]}" add niagara-block1.md
        GIT_AUTHOR_DATE="2026-09-05T10:00:00" GIT_COMMITTER_DATE="2026-09-05T10:00:00" "${GITV[@]}" commit -q -m "add niagara-block1.md"
        touch -t 202609051000 niagara-block1.md
      fi
    ) >"$ROOT/err.mkjt" 2>&1 || { echo "regen.sh: retro-gate fixture setup failed:" >&2; sed 's/^/  | /' "$ROOT/err.mkjt" >&2; return 1; }
  }
  local hook gate_env=("${ENVV[@]}")
  gate_env[2]="PATH=$ROOT/gh:$PATH"   # env -i PATH=... : the failing-gh shim goes first
  for kind in block none; do
    mkjt "$W/rg-$kind/target" "j1-sess" "$kind" || return 1
    printf '%s' '{"session_id":"j1-sess","stop_hook_active":false,"hook_event_name":"Stop","cwd":"/tmp"}' > "$ROOT/hook.json"
    run_json "rg-$kind" 0 "$ROOT/hook.json" "${gate_env[@]}" "$BASH_BIN" "$TOOLBELT/retro-gate.sh" --json "$W/rg-$kind/target" || return 1
    norm_paths < "$RAW" > "$out/retro-gate-$kind.golden" || return 1
  done

  # --- degraded envelopes: jq missing from PATH, each instrument prints its hand-built single line, exit 3
  local nojq="$ROOT/nojq" t p
  mkdir -p "$nojq" || return 1
  for t in bash sh env cat date sed awk grep tr sort head mktemp rm timeout dirname basename wc uname git cut; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$nojq/$t"
  done
  local nojq_env=("${ENVV[@]}"); nojq_env[2]="PATH=$nojq"
  kit="$(mkkit dg-sr sweep-retros.sh retro-status target-paths block-files retro-grammar hook-wiring)" || return 1
  run_json dg-sr 3 - "${nojq_env[@]}" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" --json || return 1
  cp "$RAW" "$out/sweep-retros-degraded.compact.golden" || return 1
  kit="$(mkkit dg-vr verify-registry.sh retro-status target-paths block-files state-files corpus-markers hook-wiring)" || return 1
  run_json dg-vr 3 - "${nojq_env[@]}" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json || return 1
  cp "$RAW" "$out/verify-registry-degraded.compact.golden" || return 1
  run_json dg-rs 3 - "${nojq_env[@]}" "$BASH_BIN" "$TOOLBELT/resume-state.sh" --cwd "$R" --no-gh --json || return 1
  cp "$RAW" "$out/resume-state-degraded.compact.golden" || return 1

  # --- edge: jq's own rendering of the escape / nesting edge cases (the input is committed, static)
  jq . "$HERE/edge.in.json" > "$out/edge.golden" || fail "jq failed on edge.in.json" || return 1

  # --- invalid UTF-8: what jq -Rs does with each byte string of utf8.in (retro-gate's block reason path).
  #     Line format of the golden: <hex input> TAB <jq output, a JSON string>
  : > "$out/utf8-replace.golden" || return 1
  local hex esc
  while IFS= read -r hex; do
    [ -n "$hex" ] || continue
    esc="$(printf '%s' "$hex" | sed 's/../\\x&/g')" || return 1
    # shellcheck disable=SC2059
    printf '%s\t%s\n' "$hex" "$(printf "$esc" | jq -Rs .)" >> "$out/utf8-replace.golden" || return 1
  done < "$HERE/utf8.in"
}

# publish <scratch> : move a complete generated set next to this script, atomically per file.
publish() {
  local src="$1" dest="$2" f b
  mkdir -p "$dest" || return 1
  for f in "$src"/*.golden; do
    [ -e "$f" ] || { echo "regen.sh: generation produced no goldens" >&2; return 1; }
    b="$(basename "$f")"
    cp "$f" "$dest/.$b.tmp" && mv "$dest/.$b.tmp" "$dest/$b" || return 1
  done
}

case "${1:-}" in
  "" | --out)
    DEST="$HERE"; [ "${1:-}" = --out ] && { [ -n "${2:-}" ] || { echo "usage: regen.sh [--out DIR | --verify]" >&2; exit 2; }; DEST="$2"; }
    S="$(mktemp -d)" || exit 2; trap 'rm -rf "$S"' EXIT
    gen "$S/new" || { echo "regen.sh: generation failed; nothing was written" >&2; exit 1; }
    for f in "$S"/new/*.golden; do
      b="$(basename "$f")"
      if [ -f "$DEST/$b" ] && cmp -s "$f" "$DEST/$b"; then :; else echo "regen.sh: updating $b"; fi
    done
    publish "$S/new" "$DEST" || exit 1 ;;
  --verify)
    S="$(mktemp -d)" || exit 2; trap 'rm -rf "$S"' EXIT
    gen "$S/a" && gen "$S/b" || { echo "regen.sh: generation failed" >&2; exit 1; }
    n=0; rc=0
    for f in "$S"/a/*.golden; do
      b="$(basename "$f")"; n=$((n+1))
      [ -s "$f" ] || { echo "FAIL empty: $b" >&2; rc=1; }
      cmp -s "$f" "$S/b/$b" || { echo "FAIL run1 != run2: $b" >&2; rc=1; }
      cmp -s "$f" "$HERE/$b" || { echo "FAIL differs from committed: $b" >&2; rc=1; }
    done
    for f in "$HERE"/*.golden; do
      [ -e "$S/a/$(basename "$f")" ] || { echo "FAIL committed golden not produced by regen: $(basename "$f")" >&2; rc=1; }
    done
    [ "$n" -gt 0 ] || { echo "FAIL: no goldens generated" >&2; exit 1; }
    [ "$rc" = 0 ] && echo "regen.sh --verify: $n goldens, two runs byte-identical and equal to committed"
    exit "$rc" ;;
  *) echo "usage: regen.sh [--out DIR | --verify]" >&2; exit 2 ;;
esac
