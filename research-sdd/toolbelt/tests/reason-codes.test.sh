#!/usr/bin/env bash
# reason-codes.test.sh — coverage test for research-sdd/toolbelt/reason-codes.v1.md (kit issue #1704, slice 1).
#
# The registry is a closed table: one row per `degraded:` class emitted today, plus the three typed
# input classes, each row naming exactly one continuation. This suite extracts the emitted `degraded:`
# tokens from the five scanned scripts and proves the registry and the emitters agree:
#
#   - an emitted token that is not a registry code            -> FAIL (unlisted code)
#   - a registry degraded row that no scanned script emits    -> FAIL (stale row)
#   - an emitter that the row does not list                   -> FAIL (emitter mismatch)
#   - a listed emitter that never emits that code             -> FAIL (stale emitter; kit issue #1725 item 1)
#   - a non-comment line with `degraded: ` that is not a single-line echo/printf (continued line,
#     heredoc, variable assignment, helper, trailing-comment or quoted-hash mention) -> FAIL (unclassifiable; the extractor cannot read it, so a
#     clean result would be a silent zero; kit issue #1725 item 2)
#   - a row with an empty / placeholder continuation          -> FAIL
#   - malformed row, duplicate code, bad class, missing required input row -> FAIL
#   - registry or script absent, unreadable, or ZERO emit lines extracted -> typed DEGRADED, exit 2
#     (could-not-look is not clean: a zero that cannot prove it looked is the CLAUDE.md section 7 defect)
#
# EXTRACTION RULE (the same text is in reason-codes.v1.md, "How a code is derived"). For every
# non-comment line containing an `echo` or `printf` word AND the literal `degraded: `:
#   1. start at the first `degraded: `
#   2. replace shell expansions (${...}, $(...) without nested parentheses, $name, and the single-character
#      parameters $0-$9 $? $@ $# $* $! $$) and %s / %d with <v>, then collapse runs of <v>
#   3. cut at the first " — " (em dash), literal \n, or closing double quote
#   4. strip trailing whitespace and trailing <v>
# Comment lines, grep patterns (no echo/printf) and variable assignments are never emit lines.
#
# Usage: reason-codes.test.sh [--prove-teeth]
#        reason-codes.test.sh --check-only REGISTRY SCRIPT_DIR   (internal: the degraded checker alone, exit 0/1/2)
#        reason-codes.test.sh --check-input REGISTRY TOOLBELT_DIR (internal: the input-class scan alone, exit 0/1/2;
#          kit issue #1704 slice 2 — the scan, its recognised forms and its waivers are declared in reason-codes.v1.md)
# Exit: 0 all held · 1 any failure · 2 typed DEGRADED (could not look).
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"

SELF="${BASH_SOURCE[0]}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REGISTRY="$HERE/../reason-codes.v1.md"
TOOLBELT="$HERE/.."

SCRIPTS=(research-sdd-status.sh reconcile-issues.sh stage-retro-issues.sh stage-retro.sh research-sdd-init.sh migrate-backlogs.sh lib/rsdd-exec.sh)
REQUIRED_INPUT=(absent-input empty-input unclassifiable)

# A script that is only a rsdd-exec shim (kit issue #2435) emits its typed states from the Go command it runs. The Go
# sources of that command are scanned as part of the script, so every registry row stays verified against a real emitter:
# only the lines that CALL an emitter (GO_CALL_RE) are read, rewritten to `printf` so the shell rules above apply
# unchanged; `//` comment lines and `_test.go` files are never emitters. A degraded: line that is not such a call (and not
# a regexp.MustCompile pattern, which matches a state rather than emitting one) is reported (the extractor cannot read it).
# The shim itself is still scanned (rsdd-unavailable, the self-dir note).
#
# GO_SRC maps a script basename to its Go package, relative to the scanned toolbelt directory (kit issue #2583). The
# command -> package lookup is not derivable from the shim (`gate retro` and `gate merge` share internal/gate;
# `retro stage-issues` lives in internal/retro/stageissues), and a hand-written map re-breaks on the next port
# (CLAUDE.md section 7), so go_unmapped fails on every rsdd_exec shim that is neither mapped here nor declared in
# GO_NO_TYPED (shims checked to emit no registry state). An entry whose script is not a shim yet is ignored.
GO_SRC=(
  "stage-retro-issues.sh=../rsdd/internal/retro/stageissues"   # TOOTH-GOMAP
  "reconcile-issues.sh=../rsdd/internal/retro/reconcile"   # TOOTH-GOMAP2
  "sweep-audits.sh=../rsdd/internal/sweep"
  "sweep-audits-hook.sh=../rsdd/internal/sweep"
  "sweep-retros.sh=../rsdd/internal/sweep"   # retros.go / retrosjson.go print the absent-input / empty-input / no-match states (kit issue #2605)
  "sweep-retros-hook.sh=../rsdd/internal/sweep"
  "sweep-tools.sh=../rsdd/internal/sweep"
  "sweep-tools-hook.sh=../rsdd/internal/sweep"
  "sweep-breakthroughs.sh=../rsdd/internal/sweep"
  "sweep-breakthroughs-hook.sh=../rsdd/internal/sweep"
  "sweep-all.sh=../rsdd/internal/sweep"
  "retro-gate.sh=../rsdd/internal/gate"   # retrogateseed.go prints the absent-input / unclassifiable WARNs
  "verify-retro.sh=../rsdd/internal/retro/verifyretro"   # render.go prints the absent-input ERRORs
  "migrate-backlogs.sh=../rsdd/internal/corpus/migratebacklogs"   # run.go and scan.go print the degraded lines and the absent-input / empty-input states (kit issue #2684)
  "stage-retro.sh=../rsdd/internal/retro/stage"   # gitops.go, run.go and label.go print the degraded git and retro-not-readable lines (kit issue #2663)
  "verify-registry.sh=../rsdd/internal/verify"   # registry.go prints unclassifiable-blocks (kit issue #2364)
  "verify-corrections.sh=../rsdd/internal/verify/corrections"   # its own sub-package (kit issue #2625), so no GO_FILES glob is needed
  "check-gap-drift.sh=../rsdd/internal/verify/gapdrift"         # its own sub-package (kit issue #2645), so no GO_FILES glob is needed
  "score-loop-transcript.sh=../rsdd/internal/eval/scoreloop"   # c2.go and c4.go print the empty-input n/a reason (kit issue #993)
  "scan-secrets.sh=../rsdd/internal/core/secretscan"           # the engine behind rsdd secrets scan; its DEGRADED lines are typed there
  "clean-check.sh=../rsdd/internal/core/cleancheck"      # the engine behind rsdd hygiene clean-check; the ABSENT-* and DEGRADED-* lines are typed there (kit issue #2270)
  "kit-size-check.sh=../rsdd/internal/maint/sizecheck"  # classify.go names the empty-input state of the size verdict (kit issue #2212)
)
GO_NO_TYPED=(corroborate-java.sh corroborate-ghidra.sh corroborate-native.sh pcap-flows.sh corroborate-pcap.sh lint-block.sh
  decompile-java.sh corroborate-bacnet.sh corroborate-capa.sh corroborate-firmware.sh qnx6-read.sh corroborate-floss.sh
  verify-skill-drift.sh corroborate-kaitai.sh java-fidelity-experiment.sh ensure-remote.sh verify-kit-clean.sh scan-firmware.sh
  zip-metadata.sh merge-gate.sh palette-lexicon-agents.sh serial-frame-analyze.sh squashfs-extract.sh
  serial-frame-capture.sh verify-session-budget.sh zip-stored.sh research-sdd-archive.sh
  hook-wiring.sh kit-merge-train.sh kit-rdd-drive.sh kit-rdd-start.sh detect-tools.sh verify-state.sh
  kit-gate.sh kit-wait-merge.sh kit-pr-pipeline.sh
  resume-state.sh resume-render.sh verify-block.sh verify-registry-hook.sh)   # verify-registry-hook.sh emits only the envelope of verify-registry.sh's states
# The rsdd_exec_hook shims the scan newly sees (kit issue #2597), checked to emit no registry input state of their own.
GO_NO_TYPED+=(return-token-gate.sh verify-kit-clean-hook.sh verify-skill-drift-hook.sh)
# GO_SHARED lists degraded rows whose emitter is a shared Go package that several ports call, not one shim's package
# (kit issue #2563): `code|row emitter label|package dir|literal`. The row counts as emitted only while the literal is
# still in the package's non-test sources, so a removed emission turns it stale again.
GO_SHARED=("degraded: missing runtime dependency:|core/probe|../rsdd/internal/core/probe|missing runtime dependency: ")
# The emit calls the Go packages use: errf/outf (stageissues, gate), .degrade/.note/.fail (reconcile), fmt.* (sweep, reconcile).
GO_CALL_RE='(errf|outf|\.degrade|\.note|\.fail|fmt\.Fprintf|fmt\.Fprintln|fmt\.Sprintf|fmt\.Errorf)\('

# go_dir SCRIPT_PATH TOOLBELT_DIR — the mapped Go package directory of the script; rc 1 when unmapped
go_dir() {
  local b e
  b="$(basename "$1")"
  for e in "${GO_SRC[@]}"; do
    if [ "${e%%=*}" = "$b" ]; then printf '%s/%s\n' "$2" "${e#*=}"; return 0; fi
  done
  return 1
}
# The one shim pattern: a script is a rsdd shim when a non-comment line calls rsdd_exec or rsdd_exec_hook (kit issue #2597:
# the hook form was read as bash, so its GO_SRC entry was never used and go_unmapped could not flag it).
GO_SHIM_RE='^[^#]*rsdd_exec(_hook)? '
# The registry input tokens, in one place: the Go assign/return rule (go_view) and the shell classifier (IC_AWK) share them.
INPUT_TOKENS='absent-input|empty-input|unclassifiable|no-match'
# go_is_shim SCRIPT_PATH — 0 when the script calls rsdd_exec / rsdd_exec_hook on a non-comment line
go_is_shim() { grep -Eq "$GO_SHIM_RE" "$1" 2>/dev/null; }
# go_shim SCRIPT_PATH — 0 when it is mapped in GO_SRC and a shim
go_shim() { go_dir "$1" . >/dev/null && go_is_shim "$1"; }
# go_unmapped DIR — one line per rsdd_exec shim under DIR (. lib maint) that is neither in GO_SRC nor in GO_NO_TYPED
go_unmapped() {
  local p b e ok
  for p in "$1"/*.sh "$1"/lib/*.sh "$1"/maint/*.sh; do
    [ -f "$p" ] || continue
    b="$(basename "$p")"
    [ "$b" = rsdd-exec.sh ] && continue
    go_is_shim "$p" || continue
    ok=0
    for e in "${GO_SRC[@]}"; do [ "${e%%=*}" = "$b" ] && ok=1; done   # TOOTH-GOUNMAPPED
    for e in "${GO_NO_TYPED[@]}"; do [ "$e" = "$b" ] && ok=1; done
    [ "$ok" -eq 0 ] && printf '%s\n' "${p#"$1"/}"
  done
  return 0
}
# GO_FILES narrows a mapped package to some of its files, `script=glob` (kit issue #2597): internal/sweep holds the audits
# AND the retros port, and a package-wide scan made sweep-audits.sh "emit" what retrosjson.go emits. An unlisted script
# reads every non-test file of its package. A glob that matches no file is the same typed absent-input as an absent dir.
GO_FILES=("sweep-audits.sh=audits*.go" "sweep-audits-hook.sh=audits*.go" "verify-registry.sh=registry*.go" "sweep-retros.sh=retros*.go" "sweep-retros-hook.sh=retros*.go" "sweep-tools.sh=tools*.go" "sweep-tools-hook.sh=tools*.go" "sweep-breakthroughs.sh=breakthroughs*.go" "sweep-breakthroughs-hook.sh=breakthroughs*.go" "sweep-all.sh=all*.go")   # TOOTH-GOFILES
# go_glob SCRIPT_PATH — the file glob of the script's Go sources
go_glob() {
  local b e
  b="$(basename "$1")"
  for e in "${GO_FILES[@]}"; do
    if [ "${e%%=*}" = "$b" ]; then printf '%s\n' "${e#*=}"; return 0; fi
  done
  printf '%s\n' '*.go'
}
# go_files DIR [GLOB] — the non-test Go sources of the command, one per line
go_files() {
  local f g="${2:-*.go}"
  for f in "$1"/$g; do
    [ -f "$f" ] || continue
    case "$f" in *_test.go) continue ;; esac   # TOOTH-GOTESTFILE
    printf '%s\n' "$f"
  done
}
# A Go port can also state an input class by assigning it (`state, reason = "no-match", ...`, `state := "..."`) or by
# returning it (`return "absent-input", ...`), with no emit call around it (kit issue #2597). Such a non-comment line,
# where the quoted token directly follows `=` or `return`, is kept verbatim (a `==` / `!=` comparison is kept too, and IC_AWK
# classifies it as a consumer, so the one comparison rule lives in the awk classifier).
GO_ASSIGN_RE="=[[:space:]]*\"($INPUT_TOKENS)\"|(^|[^[:alnum:]_])return[[:space:]]+\"($INPUT_TOKENS)\""
# go_view DIR — the emit lines of those sources as shell `printf` lines (calls), plus the assign/return lines as they are
go_view() {   # DIR [GLOB]
  local f
  while IFS= read -r f; do
    sed -nE "/^[[:space:]]*\/\//d; /regexp\.MustCompile/d; /$GO_CALL_RE/ { s/$GO_CALL_RE/ printf /; s/%[-+# 0-9.]*[vsdqxXtTcUeEfFgGbpow]/%s/g; p; b; }; /$GO_ASSIGN_RE/p" "$f" || return 2   # TOOTH-GOCALLS (the %s rewrite: TOOTH-GOVERBS)
  done < <(go_files "$1" "${2:-}")
}
# go_stray DIR — non-comment lines carrying `degraded: ` that are not an emit call: LINENO:text per file
go_stray() {   # DIR [GLOB]
  local f
  while IFS= read -r f; do
    F="$(basename "$f")" RE="$GO_CALL_RE" awk 'BEGIN { F = ENVIRON["F"]; RE = ENVIRON["RE"] } /^[[:space:]]*\/\// {next} /regexp\.MustCompile/ {next} index($0, "degraded: ") && $0 !~ RE { print F ":" NR ":" $0 }' "$f" || return 2   # TOOTH-GOSTRAYRE
  done < <(go_files "$1" "${2:-}")
}

# The extraction rule as an awk program (kept in one place; teeth mutate individual lines of it).
EXTRACT_AWK='
/^[[:space:]]*#/ {next}                                                    # TOOTH-COMMENT
/(^|[^[:alnum:]_])(echo|printf)[[:space:]]/ && index($0, "degraded: ") {
  s = substr($0, index($0, "degraded: "))
  gsub(/\$\{[^}]*\}/, "<v>", s)
  gsub(/\$\([^)]*\)/, "<v>", s)                                           # TOOTH-CMDSUB
  gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "<v>", s)                               # TOOTH-VARSUB
  gsub(/\$[0-9?@#*!$]/, "<v>", s)                                          # TOOTH-SPECIALSUB
  gsub(/%[sd]/, "<v>", s)
  i = index(s, " — "); if (i) s = substr(s, 1, i - 1)                      # TOOTH-EMDASH
  i = index(s, "\\n"); if (i) s = substr(s, 1, i - 1)
  i = index(s, "\""); if (i) s = substr(s, 1, i - 1)
  while (gsub(/<v><v>/, "<v>", s));
  while (sub(/([[:space:]]+|<v>)$/, "", s));
  print s
}'

# Lines the extractor cannot classify: non-comment lines carrying `degraded: ` that are not a single-line
# echo/printf. ONLY a line that starts with a comment is excluded: a ` #` before the token (even inside a
# quoted string, e.g. "see #2 degraded: x") is NOT a comment boundary here. Output: LINENO:text.
UNCLASS_AWK='
/^[[:space:]]*#/ {next}
{
  p = index($0, "degraded: "); if (!p) next
  if ($0 ~ /(^|[^[:alnum:]_])(echo|printf)[[:space:]]/) next
  print NR ":" $0
}'

# Registry rows: lines whose first cell is a backticked code. Header/separator/prose tables have no
# backticked first cell and are ignored. Output: code US class US emitters US continuation (US = \037),
# or MALFORMED US <line> when the row is not exactly five cells.
ROWS_AWK='
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
/^\| `/ {
  if (NF != 7) { print "MALFORMED\037" $0; next }
  c = trim($2); sub(/^`/, "", c); sub(/`$/, "", c)
  print c "\037" trim($3) "\037" trim($4) "\037" trim($6)
}'

nfind=0
finding() { printf 'FINDING: %s\n' "$*"; nfind=$((nfind + 1)); }

# rc_check REGISTRY SCRIPT_DIR — prints FINDING:/DEGRADED: lines; rc 0 clean · 1 findings · 2 degraded.
rc_check() {
  local reg="$1" dir="$2" rows s path toks tok req found idx i n
  local -a codes=() classes=() emits=() used=()
  local c cl em ct lc pairs=';' uc e gdir gglob gtoks
  nfind=0

  if [ ! -f "$reg" ] || [ ! -r "$reg" ]; then
    printf 'DEGRADED: registry absent or unreadable: %s\n' "$reg"; return 2
  fi
  rows="$(awk -F'|' "$ROWS_AWK" "$reg")" || { printf 'DEGRADED: awk failed reading registry %s\n' "$reg"; return 2; }
  if [ -z "$rows" ]; then                                                  # TOOTH-ZEROROWS
    printf 'DEGRADED: registry %s has zero parsable rows\n' "$reg"; return 2
  fi

  n=0
  while IFS=$'\037' read -r c cl em ct; do
    if [ "$c" = "MALFORMED" ]; then
      finding "malformed registry row (need exactly five cells): $cl"; continue
    fi
    if [ -z "$c" ]; then finding "registry row with an empty code"; continue; fi
    for ((i = 0; i < ${#codes[@]}; i++)); do
      if [ "${codes[$i]}" = "$c" ]; then finding "duplicate code: $c"; fi        # TOOTH-DUP
    done
    codes[n]="$c"; classes[n]="$cl"; emits[n]="$em"; n=$((n + 1))
    case "$cl" in
      degraded) case "$c" in "degraded: "*) ;; *) finding "degraded-class code does not start with 'degraded: ': $c" ;; esac ;;
      input) ;;
      *) finding "unknown class '$cl' for code: $c" ;;                      # TOOTH-CLASS
    esac
    if [ -z "$ct" ]; then finding "empty continuation for code: $c"; fi       # TOOTH-EMPTYCONT
    lc="$(printf '%s' "$ct" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in
      -|n/a|tbd|todo|none) finding "placeholder continuation '$ct' for code: $c" ;;   # TOOTH-PLACEHOLDER
    esac
    if [ -z "$em" ]; then finding "empty emitters for code: $c"; fi
  done <<<"$rows"

  for req in "${REQUIRED_INPUT[@]}"; do
    found=0
    for ((i = 0; i < n; i++)); do
      if [ "${codes[$i]}" = "$req" ] && [ "${classes[$i]}" = "input" ]; then found=1; fi
    done
    if [ "$found" -eq 0 ]; then finding "required input-class row missing: $req"; fi   # TOOTH-REQINPUT
  done

  for s in "${SCRIPTS[@]}"; do
    path="$dir/$s"
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      printf 'DEGRADED: scanned script absent or unreadable: %s\n' "$path"; return 2
    fi
    toks="$(awk "$EXTRACT_AWK" "$path")" || { printf 'DEGRADED: awk failed reading %s\n' "$path"; return 2; }
    if [ -z "$toks" ]; then                                                 # TOOTH-ZEROEXTRACT
      printf 'DEGRADED: extracted zero degraded emit lines from %s (could not look)\n' "$s"; return 2
    fi
    if go_shim "$path"; then
      gdir="$(go_dir "$path" "$dir")"
      gglob="$(go_glob "$path")"
      if [ -z "$(go_files "$gdir" "$gglob")" ]; then
        printf 'DEGRADED: absent-input: %s is a rsdd shim but its Go source is absent or empty: %s\n' "$s" "$gdir"; return 2   # TOOTH-GOABSENT
      fi
      gtoks="$(go_view "$gdir" "$gglob" | awk "$EXTRACT_AWK")" || { printf 'DEGRADED: could not read the Go source %s\n' "$gdir"; return 2; }
      if [ -z "$gtoks" ]; then
        printf 'DEGRADED: extracted zero degraded emit lines from the Go source of %s (could not look)\n' "$s"; return 2
      fi
      toks="$toks"$'\n'"$gtoks"   # TOOTH-GOEMIT
      while IFS= read -r e; do
        [ -n "$e" ] && finding "unclassifiable degraded: line in $s Go source ${e%%:*}:${e#*:} (not a recognised emit call)"   # TOOTH-GOSTRAY
      done < <(go_stray "$gdir" "$gglob")
    fi
    uc="$(awk "$UNCLASS_AWK" "$path")" || { printf 'DEGRADED: awk failed reading %s\n' "$path"; return 2; }
    if [ -n "$uc" ]; then
      while IFS= read -r e; do
        finding "unclassifiable degraded: line in $s:${e%%:*} (not a single-line echo/printf): ${e#*:}"   # TOOTH-UNCLASS
      done <<<"$uc"
    fi
    while IFS= read -r tok; do
      idx=-1
      for ((i = 0; i < n; i++)); do
        if [ "${codes[$i]}" = "$tok" ]; then idx=$i; fi
      done
      if [ "$idx" -lt 0 ]; then
        finding "unlisted code emitted by $s: $tok"                           # TOOTH-UNLISTED
        continue
      fi
      used[idx]=1
      pairs="$pairs$idx:$s;"
      em="$(printf '%s' "${emits[$idx]}" | tr -d ' ')"
      case ",$em," in
        *",$s,"*) ;;
        *) finding "emitter mismatch: $s emits '$tok' but the row lists '${emits[$idx]}'" ;;   # TOOTH-EMITTER
      esac
    done <<<"$toks"
  done
  while IFS= read -r e; do   # an rsdd_exec shim the map does not know cannot be verified: never a silent skip (#2583)
    [ -n "$e" ] && finding "rsdd shim with no GO_SRC entry and not in GO_NO_TYPED: $e"   # TOOTH-GOUNMAPPED-FINDING
  done < <(go_unmapped "$dir")
  local sh scode slabel sdir slit grc
  for sh in "${GO_SHARED[@]}"; do
    IFS='|' read -r scode slabel sdir slit <<<"$sh"
    idx=-1
    for ((i = 0; i < n; i++)); do
      if [ "${codes[$i]}" = "$scode" ]; then idx=$i; fi
    done
    [ "$idx" -ge 0 ] || continue
    grc=0; grep -rqF --include='*.go' --exclude='*_test.go' -- "$slit" "$dir/$sdir" 2>/dev/null || grc=$?
    if [ "$grc" -eq 0 ]; then
      used[idx]=1; pairs="$pairs$idx:$slabel;"   # TOOTH-GOSHARED
    elif [ "$grc" -ne 1 ] || [ ! -d "$dir/$sdir" ]; then
      printf 'DEGRADED: absent-input: shared Go emitter %s for %s is not readable (%s)\n' "$slabel" "$scode" "$dir/$sdir"; return 2
    fi
  done

  for ((i = 0; i < n; i++)); do
    if [ "${classes[$i]}" = "degraded" ] && [ -z "${used[$i]:-}" ]; then
      finding "stale row: degraded code never emitted by a scanned script: ${codes[$i]}"   # TOOTH-STALE
    fi
  done

  # Reverse direction (kit issue #1725 item 1): every emitter a degraded row lists must emit that code.
  for ((i = 0; i < n; i++)); do
    [ "${classes[$i]}" = "degraded" ] || continue
    [ -n "${used[$i]:-}" ] || continue   # a never-emitted row is already reported as stale
    for e in $(printf '%s' "${emits[$i]}" | tr ',' ' '); do
      case "$pairs" in
        *";$i:$e;"*) ;;
        *) finding "stale emitter: row lists $e but $e never emits '${codes[$i]}'" ;;   # TOOTH-STALEEMIT
      esac
    done
  done

  [ "$nfind" -eq 0 ]
}

# --- input-class scan (kit issue #1704, slice 2) -------------------------------------------------
# The vocabulary is closed: these four tokens are the typed input states (CLAUDE.md section 7). A new token
# needs the scanner AND the registry updated together; an input-class registry row outside this list is
# reported "not scannable" so a row can never be added that nothing could ever verify.
IC_TOKENS=(absent-input empty-input unclassifiable no-match)

# Prose mentions that look like an emission but are not one. Each waiver is `file|substring|count|reason` and
# silences exactly `count` occurrences on lines of `file` containing `substring`. Fewer matches (stale) or more
# (a new real emission now hiding behind the substring) are both findings, so the list cannot become a blanket
# ignore and cannot swallow a later emission. Line numbers are not used: they drift with every edit.
IC_WAIVERS=(
  'verify-sources.sh|empty-input digests|2|names the empty-input DIGEST check (a hash of empty input), a different concept'
)

# Classifier: one record per occurrence of a token on a non-comment line, tab separated:
#   FILE LINENO TOKEN CLASS TEXT
# A token is a word-bounded occurrence (a hyphen or alphanumeric neighbour makes it a different word, so
# unclassifiable-items / -row / -blocks are NOT occurrences). `\t` / `\n` escapes are blanked first so
# `%d\tunclassifiable` is seen. Each line is also MASKED with a small quote-state machine (single quotes,
# double quotes with backslash escapes, a ` #` outside both starts a comment): quoted characters become Q and the
# comment tail becomes C, so "is this outside quotes" questions are answered on the mask. CLASS, first match wins:
#   counter       TOKEN= , $TOKEN , ${TOKEN , or inside $(( .. )) arithmetic: a variable, not a state
#   comment       the token sits in a trailing comment (outside BOTH quote kinds)
#   emit-jq       a jq state literal: then "TOKEN" / else "TOKEN"
#   consumer      the token is the argument of a matcher:
#                   - an UNQUOTED grep/egrep/fgrep or case command (command position) earlier on the line
#                   - ==, != or =~ immediately before it (shell [[ ]] / jq tests)
#                   - a single = before it, only when an unquoted [ or [[ opens earlier on the line
#                   - a case-pattern line (starts with *, the token before the closing paren)
#                   - an awk pattern line (starts with /, the token before the closing slash, then { or end)
#   emit-echo     the line is an echo/printf
#   emit-assign   an assignment: x=TOKEN, x="TOKEN", jq .f = "TOKEN"
#   emit-marker   a parenthesised marker `(TOKEN` in a string on any other line (helper calls)
#   UNCLASSIFIED  none of the above: the scanner cannot read it
IC_AWK='
BEGIN {
  re = "(^|[^A-Za-z0-9_-])(@INPUT_TOKENS@)([^A-Za-z0-9_-]|$)"
  q_assign = "=[ \t]*[\"\047]?$"
  q_ret = "(^|[^[:alnum:]_])return[ \t]+[\"\047]?$"
  q_eq = "(==|!=|=~)[ \t]*[\"\047]?$"
  q_brk = "[^=!<>][ \t]=[ \t]*[\"\047]?$"
  re_br = "(^|[^[:alnum:]_])\\[\\[?[ \t]"
  cmdre = "(^|[;&|({!]|(^|[[:space:]])(if|then|elif|while|until|do)[[:space:]])[[:space:]]*"
  re_grep = cmdre "(grep|egrep|fgrep)[[:space:]]"
  re_case = cmdre "case[[:space:]]"
}
# lastseg: the part of a masked prefix after its last unquoted command separator (; && || | then do else, or the
# ) that ends a case pattern), i.e. the simple command the token belongs to.
function lastseg(p,   r) {
  r = p
  gsub(/.*(;|&&|\|\||\||[[:space:]](then|do|else)[[:space:]]|\))/, "", r)
  return r
}
function mask(p,   i, n, ch, st, out, prev) {
  n = length(p); st = ""; out = ""; prev = " "
  for (i = 1; i <= n; i++) {
    ch = substr(p, i, 1)
    if (st == "s") {
      if (ch == "\047") { st = ""; out = out ch } else out = out "Q"
    } else if (st == "d") {
      if (ch == "\\") { out = out "Q"; if (i < n) { out = out "Q"; i++ } }
      else if (ch == "\"") { st = ""; out = out ch }
      else out = out "Q"
    } else {
      if (ch == "\\") { out = out ch; if (i < n) { out = out substr(p, i + 1, 1); i++ } }
      else if (ch == "\047") { st = "s"; out = out ch }   # TOOTH-IC-SQ
      else if (ch == "\"") { st = "d"; out = out ch }   # TOOTH-IC-DQ
      else if (ch == "#" && prev ~ /[ \t]/) { while (i <= n) { out = out "C"; i++ } break }   # TOOTH-IC-HASH
      else out = out ch
    }
    prev = ch
  }
  return out
}
/^[[:space:]]*#/ { next }
{
  line = $0; scan = line; gsub(/\\[tn]/, "  ", scan); s = scan; off = 0   # TOOTH-IC-ESCAPE
  mk = mask(scan)
  while (match(s, re)) {
    m = substr(s, RSTART, RLENGTH); rs = RSTART
    pre = ""; if (m !~ /^[a-z]/) { pre = substr(m, 1, 1); m = substr(m, 2) }
    post = ""; if (m ~ /[^a-z]$/) { post = substr(m, length(m)); m = substr(m, 1, length(m) - 1) }
    pl = (pre != "" ? 1 : 0)
    tokstart = off + rs + pl
    off += rs + pl + length(m) - 1
    s = substr(s, rs + pl + length(m))
    prefix = substr(scan, 1, tokstart - 1)
    mp = substr(mk, 1, tokstart - 1)
    sg = lastseg(mp)   # TOOTH-IC-SEG
    c = ""
    if (post == "=") c = "counter"   # TOOTH-IC-CTR-EQ
    if (c == "" && pre == "$") c = "counter"   # TOOTH-IC-CTR-DOLLAR
    if (c == "" && pre == "{") c = "counter"   # TOOTH-IC-CTR-BRACE
    if (c == "" && prefix ~ /\$\(\([^)]*$/) c = "counter"   # TOOTH-IC-CTR-ARITH
    if (c == "" && substr(mk, tokstart, 1) == "C") c = "comment"   # TOOTH-IC-COMMENT
    if (c == "" && pre == "\"" && prefix ~ /(then|else)[ \t]+"$/) c = "emit-jq"   # TOOTH-IC-JQ
    if (c == "" && sg ~ re_grep) c = "consumer"   # TOOTH-IC-CONS-GREP
    if (c == "" && sg ~ re_case) c = "consumer"   # TOOTH-IC-CONS-CASE
    if (c == "" && prefix ~ q_eq) c = "consumer"   # TOOTH-IC-CONS-EQ
    if (c == "" && prefix ~ q_brk && mp ~ re_br) c = "consumer"   # TOOTH-IC-CONS-BRK
    if (c == "" && prefix ~ /^[[:space:]]*\*/ && prefix !~ /\)/ && scan ~ /\)/) c = "consumer"   # TOOTH-IC-CONS-STAR
    if (c == "" && prefix ~ /^[[:space:]]*\// && prefix !~ /\{/ && scan ~ /\/[[:space:]]*(\{|$)/) c = "consumer"   # TOOTH-IC-CONS-SLASH
    if (c == "" && scan ~ /(^|[^[:alnum:]_])(echo|printf)[[:space:]]/) c = "emit-echo"
    if (c == "" && prefix ~ q_assign) c = "emit-assign"   # TOOTH-IC-ASSIGN
    if (c == "" && prefix ~ q_ret) c = "emit-return"   # TOOTH-IC-RETURN (a Go port returning a typed state)
    if (c == "" && pre == "(") c = "emit-marker"   # TOOTH-IC-MARKER
    if (c == "") c = "UNCLASSIFIED"
    gsub(/\t/, " ", line)
    printf "%s\t%d\t%s\t%s\t%s\n", F, NR, m, c, line
  }
}'

IC_AWK="${IC_AWK//@INPUT_TOKENS@/"$INPUT_TOKENS"}"   # one token list for the awk classifier and the Go rule

IC_REPORT=''
# ic_check REGISTRY TOOLBELT_DIR — scans DIR/*.sh and DIR/lib/*.sh and DIR/maint/*.sh (maint tools are IN scope: a typed state they emit needs a registry row, prose mentions need a stale-detected waiver; maint/ may be absent, the report says how many files it held). rc 0 clean · 1 findings · 2 degraded.
# Sets IC_REPORT to the coverage declaration (what was traversed, how each occurrence was classified).
ic_check() {
  local reg="$1" dir="$2" rows p rel f ln tok cls txt w wf ws wr
  local c cl em ct i n nfiles=0 nocc=0 key lst row_i e gdir gglob
  local n_counter=0 n_comment=0 n_consumer=0 n_emit=0 n_waived=0 n_py=0 n_maint_files=0
  local -a codes=() classes=() emits=() files=() usedw=() wv=()
  local pairs=';' all='' n_uncl=0
  nfind=0; IC_REPORT=''

  # Waivers: the built-in list, or (test hook) the lines of $RC_IC_WAIVERS_FILE when that variable is set.
  if [ -n "${RC_IC_WAIVERS_FILE:-}" ]; then
    if [ ! -r "$RC_IC_WAIVERS_FILE" ]; then printf 'DEGRADED: waiver file unreadable: %s\n' "$RC_IC_WAIVERS_FILE"; return 2; fi
    while IFS= read -r w || [ -n "$w" ]; do [ -n "$w" ] && wv+=("$w"); done < "$RC_IC_WAIVERS_FILE"
  else
    wv=("${IC_WAIVERS[@]}")
  fi

  if [ ! -f "$reg" ] || [ ! -r "$reg" ]; then
    printf 'DEGRADED: registry absent or unreadable: %s\n' "$reg"; return 2
  fi
  rows="$(awk -F'|' "$ROWS_AWK" "$reg")" || { printf 'DEGRADED: awk failed reading registry %s\n' "$reg"; return 2; }
  if [ -z "$rows" ]; then printf 'DEGRADED: registry %s has zero parsable rows\n' "$reg"; return 2; fi
  n=0
  while IFS=$'\037' read -r c cl em ct; do
    [ "$c" = "MALFORMED" ] && continue   # rc_check owns row-shape findings
    codes[n]="$c"; classes[n]="$cl"; emits[n]="$em"; n=$((n + 1))
  done <<<"$rows"

  if [ ! -d "$dir" ]; then printf 'DEGRADED: scan directory absent: %s\n' "$dir"; return 2; fi
  for p in "$dir"/*.sh "$dir"/lib/*.sh "$dir"/maint/*.sh; do   # SENTINEL-IC-MAINT
    [ -f "$p" ] || continue
    case "$p" in "$dir"/maint/*) n_maint_files=$((n_maint_files + 1)) ;; esac
    if [ ! -r "$p" ]; then printf 'DEGRADED: scanned file unreadable: %s\n' "$p"; return 2; fi
    files+=("$p")
  done
  if [ "${#files[@]}" -eq 0 ]; then                                          # TOOTH-IC-ZEROFILES
    printf 'DEGRADED: no *.sh files found under %s or %s/lib (could not look)\n' "$dir" "$dir"; return 2
  fi
  for p in "${files[@]}"; do
    nfiles=$((nfiles + 1))
    rel="${p#"$dir"/}"
    f="$(awk -v F="$rel" "$IC_AWK" "$p")" || { printf 'DEGRADED: awk failed reading %s\n' "$p"; return 2; }
    if [ -n "$f" ]; then all="$all$f"$'\n'; fi
  done
  for p in "${files[@]}"; do
    go_shim "$p" || continue
    rel="${p#"$dir"/}"
    gdir="$(go_dir "$p" "$dir")"
    gglob="$(go_glob "$p")"
    if [ -z "$(go_files "$gdir" "$gglob")" ]; then
      printf 'DEGRADED: absent-input: %s is a rsdd shim but its Go source is absent or empty: %s\n' "$rel" "$gdir"; return 2
    fi
    nfiles=$((nfiles + 1))
    f="$(go_view "$gdir" "$gglob" | awk -v F="$rel" "$IC_AWK")" || { printf 'DEGRADED: could not read the Go source %s\n' "$gdir"; return 2; }
    if [ -n "$f" ]; then all="$all$f"$'\n'; fi   # TOOTH-IC-GOOCC
  done
  while IFS= read -r p; do   # an rsdd_exec shim the map does not know cannot be verified: never a silent skip (#2583)
    [ -n "$p" ] && finding "rsdd shim with no GO_SRC entry and not in GO_NO_TYPED: $p"   # TOOTH-IC-GOUNMAPPED
  done < <(go_unmapped "$dir")
  for p in "$dir"/*.py "$dir"/lib/*.py; do
    [ -f "$p" ] || continue
    grep -qE "($INPUT_TOKENS)" "$p"; i=$?
    if [ "$i" -gt 1 ]; then printf 'DEGRADED: grep failed reading %s\n' "$p"; return 2; fi
    if [ "$i" -eq 0 ]; then n_py=$((n_py + 1)); fi
  done
  if [ -z "$all" ]; then                                                     # TOOTH-IC-ZEROOCC
    printf 'DEGRADED: found zero input-state occurrences under %s (could not look)\n' "$dir"; return 2
  fi

  while IFS=$'\t' read -r f ln tok cls txt; do
    [ -n "$f" ] || continue
    nocc=$((nocc + 1))
    case "$cls" in
      counter) n_counter=$((n_counter + 1)); continue ;;
      comment) n_comment=$((n_comment + 1)); continue ;;
      consumer) n_consumer=$((n_consumer + 1)); continue ;;
    esac
    wr=''
    for ((i = 0; i < ${#wv[@]}; i++)); do
      w="${wv[$i]}"; wf="${w%%|*}"; ws="${w#*|}"; ws="${ws%%|*}"
      if [ "$wf" = "$f" ] && [[ "$txt" == *"$ws"* ]]; then wr=1; usedw[i]=$(( ${usedw[$i]:-0} + 1 )); break; fi
    done
    if [ -n "$wr" ]; then n_waived=$((n_waived + 1)); continue; fi
    if [ "$cls" = "UNCLASSIFIED" ]; then
      n_uncl=$((n_uncl + 1))
      finding "unclassifiable input-state occurrence in $f:$ln ($tok), not a recognised emit or consumer form: $txt"   # TOOTH-IC-UNCLASS
      continue
    fi
    n_emit=$((n_emit + 1))
    case "$pairs" in *";$tok:$f;"*) ;; *) pairs="$pairs$tok:$f;" ;; esac
  done <<<"$all"

  for ((i = 0; i < ${#wv[@]}; i++)); do
    w="${wv[$i]}"; ws="${w#*|}"; ws="${ws#*|}"; ws="${ws%%|*}"   # the count field
    wr="${usedw[$i]:-0}"
    if [ "$wr" -eq 0 ]; then finding "stale waiver (matches no occurrence): $w"; fi   # TOOTH-IC-STALEWAIVER
    if [ "$wr" -ne 0 ] && [ "$wr" -ne "$ws" ]; then finding "waiver matched $wr occurrence(s), expected $ws (a new emission may be hiding behind it): $w"; fi   # TOOTH-IC-WAIVERCOUNT
  done

  # registry input rows the scanner could never verify
  for ((i = 0; i < n; i++)); do
    [ "${classes[$i]}" = "input" ] || continue
    key=0
    for tok in "${IC_TOKENS[@]}"; do [ "$tok" = "${codes[$i]}" ] && key=1; done
    if [ "$key" -eq 0 ]; then finding "input-class code not scannable (not in the scanner vocabulary): ${codes[$i]}"; fi
  done

  for tok in "${IC_TOKENS[@]}"; do
    row_i=-1
    for ((i = 0; i < n; i++)); do
      if [ "${codes[$i]}" = "$tok" ] && [ "${classes[$i]}" = "input" ]; then row_i=$i; fi
    done
    lst="$(printf '%s' "$pairs" | tr ';' '\n' | awk -F: -v t="$tok" '$1 == t {print $2}')"
    if [ "$row_i" -lt 0 ]; then
      if [ -n "$lst" ]; then finding "unlisted input-class code emitted: $tok (by $(printf '%s' "$lst" | tr '\n' ' '))"; fi   # TOOTH-IC-UNLISTED
      continue
    fi
    if [ -z "$lst" ]; then finding "stale row: input code never emitted by a scanned script: $tok"; continue; fi   # TOOTH-IC-STALEROW
    em="$(printf '%s' "${emits[$row_i]}" | tr -d ' ')"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case ",$em," in
        *",$f,"*) ;;
        *) finding "emitter mismatch: $f emits '$tok' but the row lists '${emits[$row_i]}'" ;;   # TOOTH-IC-EMITTER
      esac
    done <<<"$lst"
    for e in $(printf '%s' "$em" | tr ',' ' '); do
      case $'\n'"$lst"$'\n' in
        *$'\n'"$e"$'\n'*) ;;
        *) finding "stale emitter: row lists $e but $e never emits '$tok'" ;;   # TOOTH-IC-STALEEMIT
      esac
    done
  done

  IC_REPORT="scanned $nfiles shell files (*.sh, lib/*.sh and maint/*.sh; under maint/: $n_maint_files); $nocc token occurrences: $n_emit emit, $n_consumer consumer, $n_counter counter, $n_comment trailing-comment, $n_waived waived, $n_uncl unclassified; $n_py python file(s) mention a token and are out of scope (not shell)"
  printf 'COVERAGE: %s\n' "$IC_REPORT"
  [ "$nfind" -eq 0 ]
}

if [ "${1:-}" = "--check-only" ]; then
  rc_check "${2:?registry}" "${3:?script dir}"
  exit $?
fi
if [ "${1:-}" = "--check-input" ]; then
  ic_check "${2:?registry}" "${3:?toolbelt dir}"
  exit $?
fi

pass=0; fail=0
tmp=''
trap 'rm -rf "$tmp"' EXIT
tmp="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
echo "== reason-codes.test.sh =="

# --- fixtures -----------------------------------------------------------------------------------
# edit FILE SED_EXPR — in-place edit without GNU-only sed -i.
edit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }

# mkfix NAME — a good registry + five scanned scripts under $tmp/NAME. Every script ends WITHOUT a
# trailing newline (last-line edge) and the registry's last row has none either.
mkfix() {
  local d="$tmp/$1"
  mkdir -p "$d/scripts"
  printf '%s\n' '# comment line mentioning degraded: nothing' \
    'echo "degraded: remote-visibility: gh not found — cannot verify"' \
    'echo "degraded: remote-visibility: $r url empty or unreadable — unverified"' \
    '[ -n "$x" ] || echo "degraded: jq not found on PATH — x"' > "$d/scripts/research-sdd-status.sh"
  # last line carries no newline
  printf '%s' 'echo "degraded: remote-visibility: gh not found — again"' >> "$d/scripts/research-sdd-status.sh"
  printf '%s\n' 'printf '"'"'degraded: --issues-cache file not readable: %s\n'"'"' "$c" >&2' > "$d/scripts/reconcile-issues.sh"
  printf '%s' 'echo "degraded: gh not found on PATH — install gh" >&2' >> "$d/scripts/reconcile-issues.sh"
  printf '%s' 'echo "degraded: gh not found on PATH — install gh" >&2' > "$d/scripts/stage-retro-issues.sh"
  printf '%s' 'echo "degraded: git fetch origin failed — cannot verify" >&2' > "$d/scripts/stage-retro.sh"
  printf '%s' 'echo "degraded: jq failed on $f — refusing"' > "$d/scripts/research-sdd-init.sh"
  printf '%s\n' 'echo "degraded: migrate-backlogs: mktemp failed" >&2' \
    'echo "degraded: migrate-backlogs: cannot read $f — proposal not computed" >&2' > "$d/scripts/migrate-backlogs.sh"
  printf '%s' 'echo "degraded: migrate-backlogs: mktemp failed" >&2' >> "$d/scripts/migrate-backlogs.sh"
  mkdir -p "$d/scripts/lib"
  printf '%s' 'printf '"'"'degraded: rsdd-unavailable — %s\n'"'"' "$1" >&2' > "$d/scripts/lib/rsdd-exec.sh"
  {
    printf '%s\n' '# fixture registry' '' \
      '| code | class | emitters | meaning | continuation |' \
      '|---|---|---|---|---|' \
      '| `degraded: remote-visibility: gh not found` | degraded | research-sdd-status.sh | m1 | install gh |' \
      '| `degraded: remote-visibility: <v> url empty or unreadable` | degraded | research-sdd-status.sh | m2 | fix the url |' \
      '| `degraded: jq not found on PATH` | degraded | research-sdd-status.sh | m3 | install jq |' \
      '| `degraded: --issues-cache file not readable:` | degraded | reconcile-issues.sh | m4 | pass a readable file |' \
      '| `degraded: gh not found on PATH` | degraded | reconcile-issues.sh, stage-retro-issues.sh | m5 | install gh |' \
      '| `degraded: jq failed on` | degraded | research-sdd-init.sh | m6 | fix settings.json |' \
      '| `degraded: git fetch origin failed` | degraded | stage-retro.sh | m13 | fix the remote |' \
      '| `degraded: migrate-backlogs: mktemp failed` | degraded | migrate-backlogs.sh | m10 | free TMPDIR space |' \
      '| `degraded: migrate-backlogs: cannot read` | degraded | migrate-backlogs.sh | m11 | fix the permissions |' \
      '| `degraded: rsdd-unavailable` | degraded | lib/rsdd-exec.sh | m12 | install go |' \
      '| `absent-input` | input | many | m7 | fix the path |' \
      '| `empty-input` | input | many | m8 | confirm emptiness |'
    printf '%s' '| `unclassifiable` | input | many | m9 | inspect by hand |'
  } > "$d/reg.md"
}

# expect LABEL WANT_RC REG DIR [GREP_RE] — run the checker, require the exact rc and (optionally) a line.
expect() {
  local label="$1" want="$2" reg="$3" dir="$4" re="${5:-}" out rc
  out="$(rc_check "$reg" "$dir")"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    no "$label (rc=$rc want=$want)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  if [ -n "$re" ] && ! grep -Eq -- "$re" <<<"$out"; then
    no "$label (rc ok, output lacks /$re/)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  ok "$label"
}

# --- 1. the real registry against the real scripts ---------------------------------------------
out="$(rc_check "$REGISTRY" "$TOOLBELT")"; rc=$?
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$out"
  echo "DEGRADED: the registry or a scanned script could not be read — nothing was verified" >&2
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  ok "real registry covers every emitted degraded: token and every row has a continuation"
else
  no "real registry vs real scripts"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- 1b. input-class scan: the real registry against the real toolbelt (kit issue #1704, slice 2) ----
out="$(ic_check "$REGISTRY" "$TOOLBELT")"; rc=$?
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$out"
  echo "DEGRADED: the input-class scan could not look — nothing was verified" >&2
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  ok "real registry input rows match the scanned input-state emitters in both directions"
else
  no "real registry input rows vs real toolbelt"; printf '%s\n' "$out" | sed 's/^/        /'
fi
printf '  INFO  input-class coverage: %s\n' "$(printf '%s\n' "$out" | sed -n 's/^COVERAGE: //p')"

# --- 2. extraction rule on a literal fixture ---------------------------------------------------
cat > "$tmp/extract.sh" <<'EOF'
echo "degraded: a b $x c — tail"
printf 'degraded: p q: %s\n' "$z"
echo "degraded: r${_em:+ — }${_em}" >&2
# echo "degraded: commented"
x=1 # not an emit degraded: foo
echo "degraded: sub $1 rc=$? at $(date +%s) end"
grep -qE '^degraded:' file
echo "NOTE: degraded: iconv bad — z"
EOF
want="$(printf '%s\n' 'degraded: a b <v> c' 'degraded: p q:' 'degraded: r' 'degraded: sub <v> rc=<v> at <v> end' 'degraded: iconv bad')"
got="$(awk "$EXTRACT_AWK" "$tmp/extract.sh")"
if [ "$got" = "$want" ]; then ok "extraction rule: placeholders, em-dash/\\n/quote cuts, comment and non-emit lines skipped"
else no "extraction rule"; printf '        got:\n%s\n' "$got" | sed 's/^/        /'; fi

# --- 3. fixtures: good, then each defect --------------------------------------------------------
mkfix good
expect "fixture good registry is clean" 0 "$tmp/good/reg.md" "$tmp/good/scripts"

# expansions beyond ${..}/$name: $(..), $1, $? all normalise to <v> (kit issue #1725 item 3)
mkfix good_sub
printf '\n%s\n%s' 'echo "degraded: cmd $(date +%s) end"' 'echo "degraded: pos $1 rc=$? end"' >> "$tmp/good_sub/scripts/research-sdd-init.sh"
edit "$tmp/good_sub/reg.md" 's/^| `absent-input`/| `degraded: cmd <v> end` | degraded | research-sdd-init.sh | s1 | go |\
| `degraded: pos <v> rc=<v> end` | degraded | research-sdd-init.sh | s2 | go |\
| `absent-input`/'
expect "fixture with \$(..), \$1, \$? expansions is clean" 0 "$tmp/good_sub/reg.md" "$tmp/good_sub/scripts"

# unlisted code: first line, last line (no trailing newline), single-line script
mkfix unl_first
{ printf '%s\n' 'echo "degraded: brand new first"'; cat "$tmp/unl_first/scripts/research-sdd-status.sh"; } > "$tmp/unl_first/s" \
  && mv "$tmp/unl_first/s" "$tmp/unl_first/scripts/research-sdd-status.sh"
expect "unlisted code on the FIRST line fails" 1 "$tmp/unl_first/reg.md" "$tmp/unl_first/scripts" 'unlisted code emitted by research-sdd-status.sh: degraded: brand new first'
mkfix unl_last
printf '\n%s' 'echo "degraded: brand new last"' >> "$tmp/unl_last/scripts/research-sdd-init.sh"
expect "unlisted code on the LAST line (no trailing newline) fails" 1 "$tmp/unl_last/reg.md" "$tmp/unl_last/scripts" 'unlisted code emitted by research-sdd-init.sh: degraded: brand new last'
mkfix unl_single
printf '%s' 'echo "degraded: only unknown one"' > "$tmp/unl_single/scripts/stage-retro-issues.sh"
expect "unlisted code in a single-line script fails" 1 "$tmp/unl_single/reg.md" "$tmp/unl_single/scripts" 'unlisted code emitted by stage-retro-issues.sh: degraded: only unknown one'

# migrate-backlogs.sh is a scanned script (kit issue #1704 slice 3): the same guards apply to it
mkfix unl_mb
printf '\n%s' 'echo "degraded: migrate-backlogs: brand new reason" >&2' >> "$tmp/unl_mb/scripts/migrate-backlogs.sh"
expect "unlisted migrate-backlogs code fails" 1 "$tmp/unl_mb/reg.md" "$tmp/unl_mb/scripts" 'unlisted code emitted by migrate-backlogs.sh: degraded: migrate-backlogs: brand new reason'
# a registry with no migrate-backlogs rows and a script that emits one: only the SCRIPTS membership catches it
mkfix mb_scanned
grep -v 'migrate-backlogs' "$tmp/mb_scanned/reg.md" > "$tmp/mb_scanned/r" && mv "$tmp/mb_scanned/r" "$tmp/mb_scanned/reg.md"
printf '%s' 'echo "degraded: migrate-backlogs: only reason" >&2' > "$tmp/mb_scanned/scripts/migrate-backlogs.sh"
expect "a script missing from the scanned list would hide its codes: scanned, so unlisted fails" 1 "$tmp/mb_scanned/reg.md" "$tmp/mb_scanned/scripts" 'unlisted code emitted by migrate-backlogs.sh'
# lib/rsdd-exec.sh is a scanned script (kit issue #2275): a lib/ path resolves under the scripts dir; same guards
mkfix unl_rsdd
printf '\n%s' 'echo "degraded: rsdd-brand-new — x" >&2' >> "$tmp/unl_rsdd/scripts/lib/rsdd-exec.sh"
expect "unlisted lib/rsdd-exec.sh code fails" 1 "$tmp/unl_rsdd/reg.md" "$tmp/unl_rsdd/scripts" 'unlisted code emitted by lib/rsdd-exec.sh: degraded: rsdd-brand-new'
mkfix rsdd_scanned
grep -v 'rsdd-unavailable' "$tmp/rsdd_scanned/reg.md" > "$tmp/rsdd_scanned/r" && mv "$tmp/rsdd_scanned/r" "$tmp/rsdd_scanned/reg.md"
expect "lib/rsdd-exec.sh missing from the scanned list would hide its code: scanned, so unlisted fails" 1 "$tmp/rsdd_scanned/reg.md" "$tmp/rsdd_scanned/scripts" 'unlisted code emitted by lib/rsdd-exec.sh: degraded: rsdd-unavailable'
mkfix rsdd_absent
rm -f "$tmp/rsdd_absent/scripts/lib/rsdd-exec.sh"
expect "lib/rsdd-exec.sh absent -> DEGRADED rc 2 (not a clean pass)" 2 "$tmp/rsdd_absent/reg.md" "$tmp/rsdd_absent/scripts" 'DEGRADED: scanned script absent or unreadable: .*lib/rsdd-exec.sh'
mkfix stale_mb
edit "$tmp/stale_mb/reg.md" 's/^| `absent-input`/| `degraded: migrate-backlogs: ghost reason` | degraded | migrate-backlogs.sh | g | go |\
| `absent-input`/'
expect "registered migrate-backlogs code that is never emitted fails (stale row)" 1 "$tmp/stale_mb/reg.md" "$tmp/stale_mb/scripts" 'stale row: degraded code never emitted by a scanned script: degraded: migrate-backlogs: ghost reason'
mkfix mb_emitter
printf '\n%s' 'echo "degraded: migrate-backlogs: mktemp failed" >&2' >> "$tmp/mb_emitter/scripts/reconcile-issues.sh"
edit "$tmp/mb_emitter/reg.md" 's/| migrate-backlogs.sh | m10 |/| reconcile-issues.sh | m10 |/'
expect "migrate-backlogs code whose row lists another emitter fails" 1 "$tmp/mb_emitter/reg.md" "$tmp/mb_emitter/scripts" 'emitter mismatch: migrate-backlogs.sh emits'
mkfix mb_absent
rm -f "$tmp/mb_absent/scripts/migrate-backlogs.sh"
expect "migrate-backlogs.sh absent -> DEGRADED rc 2 (not a clean pass)" 2 "$tmp/mb_absent/reg.md" "$tmp/mb_absent/scripts" 'DEGRADED: scanned script absent or unreadable: .*migrate-backlogs.sh'
mkfix mb_zero
printf '%s\n' '# degraded: only in a comment' 'echo "no typed state here"' > "$tmp/mb_zero/scripts/migrate-backlogs.sh"
expect "migrate-backlogs.sh with zero extracted emit lines -> DEGRADED rc 2" 2 "$tmp/mb_zero/reg.md" "$tmp/mb_zero/scripts" 'DEGRADED: extracted zero degraded emit lines from migrate-backlogs.sh'

# empty continuation: first row, middle row, last row, single-row registry
mkfix cont_first
edit "$tmp/cont_first/reg.md" 's/| install gh |$/| |/'
expect "empty continuation in the FIRST row fails" 1 "$tmp/cont_first/reg.md" "$tmp/cont_first/scripts" 'empty continuation for code: degraded: remote-visibility: gh not found'
mkfix cont_mid
edit "$tmp/cont_mid/reg.md" 's/| m5 | install gh |$/| m5 |  |/'
expect "empty continuation in a MIDDLE row fails" 1 "$tmp/cont_mid/reg.md" "$tmp/cont_mid/scripts" 'empty continuation for code: degraded: gh not found on PATH'
mkfix cont_last
edit "$tmp/cont_last/reg.md" 's/| inspect by hand |$/| |/'
expect "empty continuation in the LAST row (no trailing newline) fails" 1 "$tmp/cont_last/reg.md" "$tmp/cont_last/scripts" 'empty continuation for code: unclassifiable'
mkfix cont_single
printf '%s' '| `degraded: jq failed on` | degraded | research-sdd-init.sh | m | |' > "$tmp/cont_single/reg.md"
expect "empty continuation in a SINGLE-row registry fails" 1 "$tmp/cont_single/reg.md" "$tmp/cont_single/scripts" 'empty continuation for code: degraded: jq failed on'
mkfix cont_ph
edit "$tmp/cont_ph/reg.md" 's/| fix the path |$/| n\/a |/'
expect "placeholder continuation (n/a) fails" 1 "$tmp/cont_ph/reg.md" "$tmp/cont_ph/scripts" "placeholder continuation 'n/a'"

# stale row, emitter mismatch, duplicate, class, malformed, required input
mkfix stale
edit "$tmp/stale/reg.md" 's/^| `absent-input`/| `degraded: ghost code` | degraded | research-sdd-init.sh | g | go |\
| `absent-input`/'
expect "stale degraded row (never emitted) fails" 1 "$tmp/stale/reg.md" "$tmp/stale/scripts" 'stale row: .*ghost code'
mkfix emitter
edit "$tmp/emitter/reg.md" 's/| reconcile-issues.sh, stage-retro-issues.sh |/| reconcile-issues.sh |/'
expect "emitter missing from the row's emitters fails" 1 "$tmp/emitter/reg.md" "$tmp/emitter/scripts" 'emitter mismatch: stage-retro-issues.sh'
mkfix dup
edit "$tmp/dup/reg.md" 's/^| `absent-input`/| `absent-input` | input | many | d | go |\
| `absent-input`/'
expect "duplicate code fails" 1 "$tmp/dup/reg.md" "$tmp/dup/scripts" 'duplicate code: absent-input'
mkfix badclass
edit "$tmp/badclass/reg.md" 's/^| `absent-input`/| `weird` | mystery | many | w | go |\
| `absent-input`/'
expect "unknown class fails" 1 "$tmp/badclass/reg.md" "$tmp/badclass/scripts" "unknown class 'mystery'"
mkfix malformed
edit "$tmp/malformed/reg.md" 's/| m8 | confirm emptiness |/| confirm emptiness |/'
expect "malformed row (four cells) fails" 1 "$tmp/malformed/reg.md" "$tmp/malformed/scripts" 'malformed registry row'
mkfix reqinput
edit "$tmp/reqinput/reg.md" '/`empty-input`/d'
expect "missing required input-class row fails" 1 "$tmp/reqinput/reg.md" "$tmp/reqinput/scripts" 'required input-class row missing: empty-input'

# comment lines are not emit lines
mkfix commented
printf '\n%s' '# echo "degraded: ghost in a comment"' >> "$tmp/commented/scripts/reconcile-issues.sh"
expect "a commented-out emit line is ignored" 0 "$tmp/commented/reg.md" "$tmp/commented/scripts"

# stale emitter (reverse direction): a row lists a scanned script that never emits the code
mkfix stale_emit
edit "$tmp/stale_emit/reg.md" 's/| research-sdd-init.sh | m6 |/| research-sdd-init.sh, reconcile-issues.sh | m6 |/'
expect "a listed emitter that never emits the code fails (stale emitter)" 1 "$tmp/stale_emit/reg.md" "$tmp/stale_emit/scripts" "stale emitter: row lists reconcile-issues.sh but reconcile-issues.sh never emits 'degraded: jq failed on'"

# unclassifiable emit forms: continued echo, heredoc, assignment-then-echo (each must be reported, never silent)
mkfix unc_cont
printf '\n%s\n%s' 'echo \' '  "degraded: split across lines"' >> "$tmp/unc_cont/scripts/reconcile-issues.sh"
expect "echo continued onto the next line is reported unclassifiable" 1 "$tmp/unc_cont/reg.md" "$tmp/unc_cont/scripts" 'unclassifiable degraded: line in reconcile-issues.sh:[0-9]+'
mkfix unc_here
printf '\n%s\n%s\n%s' 'cat <<EOF' 'degraded: from a heredoc' 'EOF' >> "$tmp/unc_here/scripts/stage-retro-issues.sh"
expect "heredoc body carrying degraded: is reported unclassifiable" 1 "$tmp/unc_here/reg.md" "$tmp/unc_here/scripts" 'unclassifiable degraded: line in stage-retro-issues.sh:[0-9]+'
mkfix unc_assign
printf '\n%s' 'msg="degraded: via variable"' >> "$tmp/unc_assign/scripts/research-sdd-init.sh"
expect "assignment carrying degraded: is reported unclassifiable" 1 "$tmp/unc_assign/reg.md" "$tmp/unc_assign/scripts" 'unclassifiable degraded: line in research-sdd-init.sh:[0-9]+'
mkfix unc_trailing
printf '\n%s' 'x=1 # trailing note degraded: not an emit' >> "$tmp/unc_trailing/scripts/research-sdd-init.sh"
expect "a trailing-comment mention is reported (only whole-line comments are excluded)" 1 "$tmp/unc_trailing/reg.md" "$tmp/unc_trailing/scripts" 'unclassifiable degraded: line in research-sdd-init.sh:[0-9]+'
mkfix unc_hash
printf '\n%s' 'msg="see #2 degraded: via quoted hash"' >> "$tmp/unc_hash/scripts/research-sdd-init.sh"
expect "a quoted ' #' before degraded: is reported unclassifiable (not read as a comment)" 1 "$tmp/unc_hash/reg.md" "$tmp/unc_hash/scripts" 'unclassifiable degraded: line in research-sdd-init.sh:[0-9]+'

# --- 3b. input-class scan fixtures ------------------------------------------------------------------
# mkifix NAME — a good registry (reg.md) + a two-file toolbelt (tb/a.sh, tb/lib/b.sh) covering every recognised
# form: echo, printf with a \t escape, a jq state literal, a parenthesised marker, plus the non-emit classes
# (counter, trailing comment, case matcher). The last line of each script has no trailing newline.
mkifix() {
  local d="$tmp/$1"
  mkdir -p "$d/tb/lib"
  cat > "$d/tb/a.sh" <<'FIXEOF'
# comment: echo "absent-input: never emitted from a comment"
echo "absent-input: $x not found" >&2
printf 'subject: empty-input (0 units)\n'
unclassifiable=0; n=$((unclassifiable + 1))   # trailing note about absent-input
[ "$unclassifiable" -gt 0 ] || :
x="${unclassifiable}"
grep -q 'no-match' "$f"
case "$o" in *unclassifiable:*) : ;; esac
jq -e '.state == "no-match"' "$f" >/dev/null
[ "$s" = "unclassifiable" ] || :
*no-match:*) : ;;
/^INFO: no-match/ { next }
st=empty-input
jq '.state = "empty-input"' "$f"
echo "path: $p"
FIXEOF
  printf '%s' 'echo "x" # no trailing newline' >> "$d/tb/a.sh"
  printf '%s\n' "jq -n '(if \$a then \"ok\" else \"no-match\" end)'" \
    'emit C1 n/a "no rows (empty-input)"' > "$d/tb/lib/b.sh"
  printf '%s' "printf '%d\\tunclassifiable\\n' \"\$n\"" >> "$d/tb/lib/b.sh"
  : > "$d/waivers.txt"
  {
    printf '%s\n' '# fixture registry' '' \
      '| code | class | emitters | meaning | continuation |' \
      '|---|---|---|---|---|' \
      '| `degraded: x` | degraded | a.sh | m0 | go |' \
      '| `absent-input` | input | a.sh | m1 | fix the path |' \
      '| `empty-input` | input | a.sh, lib/b.sh | m2 | confirm emptiness |' \
      '| `unclassifiable` | input | lib/b.sh | m3 | inspect by hand |'
    printf '%s' '| `no-match` | input | lib/b.sh | m4 | widen the filter |'
  } > "$d/reg.md"
}

# expect_ic LABEL WANT_RC FIXTURE [GREP_RE] — run the input-class scan with the fixture's own waiver file.
expect_ic() {
  local label="$1" want="$2" fx="$3" re="${4:-}" out rc
  out="$(RC_IC_WAIVERS_FILE="$tmp/$fx/waivers.txt" ic_check "$tmp/$fx/reg.md" "$tmp/$fx/tb")"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    no "$label (rc=$rc want=$want)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  if [ -n "$re" ] && ! grep -Eq -- "$re" <<<"$out"; then
    no "$label (rc ok, output lacks /$re/)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  ok "$label"
}

mkifix i_good
expect_ic "input scan: good fixture is clean (all forms recognised, non-emit classes skipped)" 0 i_good

# toolbelt/maint/ is IN the scan: a maint/ emitter must be a registry row, and the report counts maint/ files.
expect_ic "input scan: the report counts maint/ files (0 when maint/ is absent)" 0 i_good 'under maint/: 0\)'
mkifix i_maint_bad
mkdir -p "$tmp/i_maint_bad/tb/maint"; printf '%s\n' 'echo "empty-input: run-level note"' > "$tmp/i_maint_bad/tb/maint/m.sh"
expect_ic "input scan: a maint/ emitter missing from the registry row fails (emitter mismatch)" 1 i_maint_bad "emitter mismatch: maint/m.sh emits 'empty-input'"
mkifix i_maint
mkdir -p "$tmp/i_maint/tb/maint"; cp "$tmp/i_maint_bad/tb/maint/m.sh" "$tmp/i_maint/tb/maint/m.sh"
edit "$tmp/i_maint/reg.md" 's#`empty-input` | input | a.sh, lib/b.sh |#`empty-input` | input | a.sh, lib/b.sh, maint/m.sh |#'
expect_ic "input scan: listing the maint/ emitter in the row makes it clean, and the report counts it" 0 i_maint 'under maint/: 1\)'
mkifix i_unlisted
edit "$tmp/i_unlisted/reg.md" '/`no-match`/d'
expect_ic "input scan: emitted code with no registry row fails (unlisted)" 1 i_unlisted 'unlisted input-class code emitted: no-match'

mkifix i_staleemit
edit "$tmp/i_staleemit/reg.md" 's/| lib\/b.sh | m4 |/| lib\/b.sh, a.sh | m4 |/'
expect_ic "input scan: a listed emitter that never emits the code fails (stale emitter)" 1 i_staleemit "stale emitter: row lists a.sh but a.sh never emits 'no-match'"

mkifix i_emitter
edit "$tmp/i_emitter/reg.md" 's/| a.sh | m1 |/| lib\/b.sh | m1 |/'
expect_ic "input scan: an emitter missing from the row fails (emitter mismatch)" 1 i_emitter "emitter mismatch: a.sh emits 'absent-input'"

# single-defect twins of the two fixtures above (the originals carry several findings at once, which a
# mutation of one guard cannot isolate)
mkifix i_emitter1
edit "$tmp/i_emitter1/reg.md" 's/| a.sh, lib\/b.sh | m2 |/| lib\/b.sh | m2 |/'
expect_ic "input scan: exactly one emitter missing from a row fails (emitter mismatch, isolated)" 1 i_emitter1 "emitter mismatch: a.sh emits 'empty-input'"
mkifix i_stalerow1
printf '%s\n' "jq -n '(if \$a then \"ok\" else \"x\" end)'" 'emit C1 n/a "no rows (empty-input)"' > "$tmp/i_stalerow1/tb/lib/b.sh"
printf '%s' "printf '%d\\tunclassifiable\\n' \"\$n\"" >> "$tmp/i_stalerow1/tb/lib/b.sh"
expect_ic "input scan: a row nothing emits fails (stale row, isolated)" 1 i_stalerow1 'stale row: input code never emitted by a scanned script: no-match'

mkifix i_notscan
printf '\n%s' '| `weird-input` | input | a.sh | w | go |' >> "$tmp/i_notscan/reg.md"
expect_ic "input scan: an input row outside the scanner vocabulary fails (not scannable)" 1 i_notscan 'not scannable.*weird-input'
mkifix i_norow_emit
printf '%s\n' 'echo "ok"' > "$tmp/i_norow_emit/tb/lib/b.sh"
expect_ic "input scan: a registry row nothing emits fails (stale row)" 1 i_norow_emit 'stale row: input code never emitted by a scanned script: no-match'

mkifix i_uncl
printf '\n%s' 'msg="the absent-input case"' >> "$tmp/i_uncl/tb/a.sh"
expect_ic "input scan: an occurrence in no recognised form is reported, never silent" 1 i_uncl 'unclassifiable input-state occurrence in a.sh:[0-9]+ \(absent-input\)'

mkifix i_waived
printf '\n%s' 'msg="the absent-input case"' >> "$tmp/i_waived/tb/a.sh"
printf '%s\n' 'a.sh|the absent-input case|1|fixture prose' > "$tmp/i_waived/waivers.txt"
expect_ic "input scan: a waiver with the right count silences its prose occurrence" 0 i_waived
mkifix i_stalewaiver
printf '%s\n' 'a.sh|matches nothing at all|1|fixture' > "$tmp/i_stalewaiver/waivers.txt"
expect_ic "input scan: a waiver that matches nothing fails (stale waiver)" 1 i_stalewaiver 'stale waiver'
# a second, genuine emission that happens to contain the waived substring must not be swallowed
mkifix i_waivercount
printf '\n%s\n%s' 'msg="the absent-input case"' 'echo "unclassifiable: the absent-input case"' >> "$tmp/i_waivercount/tb/a.sh"
printf '%s\n' 'a.sh|the absent-input case|1|fixture prose' > "$tmp/i_waivercount/waivers.txt"
expect_ic "input scan: a waiver matching more occurrences than its count fails (cannot swallow a new emission)" 1 i_waivercount 'waiver matched [0-9]+ occurrence\(s\), expected 1'

# hazards: lines that LOOK like consumers/comments/counters but are emissions. a.sh is not a listed emitter of
# `unclassifiable` or `no-match`, so each line must surface as an emitter mismatch.
# haz NAME LINE TOKEN
haz() {
  mkifix "$1"
  printf '\n%s' "$2" >> "$tmp/$1/tb/a.sh"
  expect_ic "input scan: emission not mistaken for a non-emit — $2" 1 "$1" "emitter mismatch: a.sh emits '$3'"
}
haz h_eqmsg   'echo "state=no-match"' no-match
haz h_grepmsg "printf 'no-match: grep found 0 rows\\n'" no-match
haz h_casemsg 'echo "unclassifiable: in this case x"' unclassifiable
haz h_jqassign "jq '.state = \"no-match\"' \"\$f\"" no-match
haz h_shassign 'st=no-match' no-match
haz h_slash "/usr/bin/printf 'no-match: x\\n'" no-match
haz h_star '*) echo "no-match: x" ;;' no-match
haz h_sqhash "echo 'item #3 unclassifiable'" unclassifiable
haz h_dqhash 'echo "item #3 unclassifiable"' unclassifiable
# a grep/case earlier on the line does not make a later command's token a consumer
haz h_seg_or 'grep -q pat "$f" || echo "no-match: $f"' no-match
haz h_seg_then 'if grep -q x "$f"; then echo "no-match"; fi' no-match
haz h_seg_case 'case "$x" in "") echo "unclassifiable: $p" ;; esac' unclassifiable

mkifix i_counter
printf '\n%s' 'echo "n=$no_match_count unclassifiable=$n unclassifiable-items: 0 unclassifiable-row: 1"' >> "$tmp/i_counter/tb/a.sh"
expect_ic "input scan: counters and hyphen-extended compounds are not occurrences" 0 i_counter

# list edges: a new emitter on the FIRST line of the first file and on the LAST line (no newline) of the last file
mkifix i_first
{ printf '%s\n' 'echo "unclassifiable: first line"'; cat "$tmp/i_first/tb/a.sh"; } > "$tmp/i_first/s" && mv "$tmp/i_first/s" "$tmp/i_first/tb/a.sh"
expect_ic "input scan: an emit on the FIRST line of a file is seen" 1 i_first "emitter mismatch: a.sh emits 'unclassifiable'"
mkifix i_last
printf '\n%s' 'echo "no-match: last line"' >> "$tmp/i_last/tb/lib/b.sh"
expect_ic "input scan: an emit on the LAST line (no trailing newline) is still scanned" 0 i_last

mkifix i_zero
rm -f "$tmp/i_zero/tb/a.sh" "$tmp/i_zero/tb/lib/b.sh"
expect_ic "input scan: zero shell files -> DEGRADED rc 2" 2 i_zero 'DEGRADED: no \*\.sh files'
mkifix i_zeroocc
printf '%s\n' 'echo "nothing typed here"' > "$tmp/i_zeroocc/tb/a.sh"; printf '%s\n' 'true' > "$tmp/i_zeroocc/tb/lib/b.sh"
expect_ic "input scan: files but zero occurrences -> DEGRADED rc 2" 2 i_zeroocc 'DEGRADED: found zero input-state occurrences'
mkifix i_nodir
rm -rf "$tmp/i_nodir/tb"
expect_ic "input scan: absent scan directory -> DEGRADED rc 2" 2 i_nodir 'DEGRADED: scan directory absent'

# --- 4. could-not-look is typed DEGRADED (rc 2), never clean ------------------------------------
mkfix d_noreg
expect "registry absent -> DEGRADED rc 2" 2 "$tmp/d_noreg/missing.md" "$tmp/d_noreg/scripts" 'DEGRADED: registry absent'
mkfix d_noscript
rm -f "$tmp/d_noscript/scripts/stage-retro-issues.sh"
expect "scanned script absent -> DEGRADED rc 2" 2 "$tmp/d_noscript/reg.md" "$tmp/d_noscript/scripts" 'DEGRADED: scanned script absent'
mkfix d_zero
printf '%s\n' '# degraded: only in a comment' 'echo "no typed state here"' > "$tmp/d_zero/scripts/reconcile-issues.sh"
expect "zero extracted emit lines -> DEGRADED rc 2" 2 "$tmp/d_zero/reg.md" "$tmp/d_zero/scripts" 'DEGRADED: extracted zero degraded emit lines from reconcile-issues.sh'
mkfix d_norows
printf '%s\n' '# registry with prose only' '| code | class |' > "$tmp/d_norows/reg.md"
expect "registry with zero parsable rows -> DEGRADED rc 2" 2 "$tmp/d_norows/reg.md" "$tmp/d_norows/scripts" 'DEGRADED: registry .* zero parsable rows'
mkfix d_empty
: > "$tmp/d_empty/scripts/research-sdd-init.sh"
expect "empty scanned script -> DEGRADED rc 2" 2 "$tmp/d_empty/reg.md" "$tmp/d_empty/scripts" 'extracted zero'

# --- Go emitters (kit issue #2435): stage-retro-issues.sh is a shim; the typed states come from rsdd retro stage-issues
# mkgofix NAME — the good fixture with a shim for stage-retro-issues.sh and a Go source next to it (scripts/ and rsdd/ siblings,
# exactly like toolbelt/ and rsdd/ in the kit). The Go source emits the one code the fixture registry lists for it.
mkgofix() {
  local d="$tmp/$1" g
  mkfix "$1"
  g="$d/rsdd/internal/retro/stageissues"; mkdir -p "$g"
  printf '%s\n' '#!/usr/bin/env bash' 'rsdd_exec retro stage-issues --toolbelt "$_RSDD_SELF" "$@"' > "$d/scripts/stage-retro-issues.sh"
  printf '%s\n' 'package stageissues' '' \
    '// a comment naming degraded: a ghost that is never an emission' \
    'func f(a *app) {' \
    '	a.errf("degraded: gh not found on PATH — install gh\n")' \
    '	a.errf("degraded: jq failed on %s — refusing\n", f)' \
    '	a.outf("planned: %s\n", x)' \
    '}' > "$g/run.go"
  edit "$d/reg.md" 's#^\(| `degraded: rsdd-unavailable` | degraded | lib/rsdd-exec.sh\) |#\1, stage-retro-issues.sh |#'
  edit "$d/reg.md" 's#^\(| `degraded: jq failed on` | degraded | research-sdd-init.sh\) |#\1, stage-retro-issues.sh |#'
  printf '%s\n' 'printf '"'"'degraded: rsdd-unavailable — %s\n'"'"' "$1" >&2' >> "$d/scripts/stage-retro-issues.sh"
}
mkgofix go_good
expect "Go emitter: the code emitted from the Go source is verified against the row" 0 "$tmp/go_good/reg.md" "$tmp/go_good/scripts"
mkgofix go_shared; mkdir -p "$tmp/go_shared/rsdd/internal/core/probe"
printf '%s\n' 'package probe' 'func (d *D) msg() string { return "missing runtime dependency: " + d.Tool }' > "$tmp/go_shared/rsdd/internal/core/probe/probe.go"
edit "$tmp/go_shared/reg.md" '/^| `degraded: rsdd-unavailable`/a | `degraded: missing runtime dependency:` | degraded | core/probe | a required tool is absent | install the named dependency, then re-run the tool |'
expect "Go shared emitter: a row emitted only by core/probe is verified against its source" 0 "$tmp/go_shared/reg.md" "$tmp/go_shared/scripts"
mkgofix go_shared_gone; mkdir -p "$tmp/go_shared_gone/rsdd/internal/core/probe"; cp "$tmp/go_shared/reg.md" "$tmp/go_shared_gone/reg.md"
printf '%s\n' 'package probe' 'func f() {}' > "$tmp/go_shared_gone/rsdd/internal/core/probe/probe.go"
expect "Go shared emitter: the literal gone from core/probe makes the row stale" 1 "$tmp/go_shared_gone/reg.md" "$tmp/go_shared_gone/scripts" "stale row: degraded code never emitted by a scanned script: degraded: missing runtime dependency:"
mkgofix go_shared_absent; cp "$tmp/go_shared/reg.md" "$tmp/go_shared_absent/reg.md"
expect "Go shared emitter: an absent core/probe is a typed degraded, never a silent stale" 2 "$tmp/go_shared_absent/reg.md" "$tmp/go_shared_absent/scripts" "DEGRADED: absent-input: shared Go emitter core/probe"
mkgofix go_drop
printf '%s\n' 'package stageissues' 'func f(a *app) { a.errf("degraded: jq failed on %s — refusing\n", f) }' > "$tmp/go_drop/rsdd/internal/retro/stageissues/run.go"
expect "Go emitter: a code dropped from the Go source fails (stale emitter)" 1 "$tmp/go_drop/reg.md" "$tmp/go_drop/scripts" "stale emitter: row lists stage-retro-issues.sh but stage-retro-issues.sh never emits 'degraded: gh not found on PATH'"
mkgofix go_unlisted
printf '%s\n' 'func g(a *app) { a.errf("degraded: brand new go code — x\n") }' >> "$tmp/go_unlisted/rsdd/internal/retro/stageissues/run.go"
expect "Go emitter: a new code in the Go source must be a registry row (unlisted)" 1 "$tmp/go_unlisted/reg.md" "$tmp/go_unlisted/scripts" 'unlisted code emitted by stage-retro-issues.sh: degraded: brand new go code'
# go_solo: the registry does not list the script for the Go-emitted codes, so only the Go scan can find the new code
mkgofix go_solo
edit "$tmp/go_solo/reg.md" 's#^\(| `degraded: gh not found on PATH` | degraded | reconcile-issues.sh\), stage-retro-issues.sh |#\1 |#'
edit "$tmp/go_solo/reg.md" 's#^\(| `degraded: jq failed on` | degraded | research-sdd-init.sh\), stage-retro-issues.sh |#\1 |#'
printf '%s\n' 'package stageissues' 'func g(a *app) { a.errf("degraded: only the go scan sees this — x\n") }' > "$tmp/go_solo/rsdd/internal/retro/stageissues/run.go"
expect "Go emitter: the Go scan alone finds an unlisted code" 1 "$tmp/go_solo/reg.md" "$tmp/go_solo/scripts" 'unlisted code emitted by stage-retro-issues.sh: degraded: only the go scan sees this'
mkgofix go_test_only
printf '%s\n' 'package stageissues' 'func g(a *app) { a.errf("degraded: only in a test file — x\n") }' > "$tmp/go_test_only/rsdd/internal/retro/stageissues/run_test.go"
expect "Go emitter: _test.go files are not emitters" 0 "$tmp/go_test_only/reg.md" "$tmp/go_test_only/scripts"
mkgofix go_stray
printf '%s\n' 'var msg = "degraded: via a variable"' >> "$tmp/go_stray/rsdd/internal/retro/stageissues/run.go"
expect "Go emitter: a degraded: line that is not an errf/outf call is unclassifiable" 1 "$tmp/go_stray/reg.md" "$tmp/go_stray/scripts" 'unclassifiable degraded: line in stage-retro-issues.sh'
mkgofix go_absent; rm -rf "$tmp/go_absent/rsdd"
expect "Go emitter: shim without its Go source is DEGRADED, never a clean pass" 2 "$tmp/go_absent/reg.md" "$tmp/go_absent/scripts" 'Go source'
# input-class scan: the Go emit lines count as occurrences of the script
mkgoifix() {
  local d="$tmp/$1" g
  mkifix "$1"
  g="$d/rsdd/internal/retro/stageissues"; mkdir -p "$g"
  printf '%s\n' '#!/usr/bin/env bash' 'rsdd_exec retro stage-issues --toolbelt "$_RSDD_SELF" "$@"' > "$d/tb/stage-retro-issues.sh"
  printf '%s\n' 'package stageissues' '' '// absent-input is only a comment here' \
    'func f(a *app) {' '	a.errf("absent-input: retro not found: %s\n", x)' '	a.uncN++' '}' > "$g/run.go"
  edit "$d/reg.md" 's#^\(| `absent-input` | input | a.sh\) |#\1, stage-retro-issues.sh |#'
}
mkgoifix i_go
expect_ic "input scan: an input state emitted from the Go source is verified against the row" 0 i_go
mkgoifix i_go_drop; printf '%s\n' 'package stageissues' 'func f() {}' > "$tmp/i_go_drop/rsdd/internal/retro/stageissues/run.go"
expect_ic "input scan: a state dropped from the Go source fails (stale emitter)" 1 i_go_drop "stale emitter: row lists stage-retro-issues.sh but stage-retro-issues.sh never emits 'absent-input'"

# --- Go emitters beyond errf/outf (kit issue #2583): reconcile-issues.sh emits via r.degrade / fmt.Errorf, mapped in GO_SRC
mkgofix2() {
  local d="$tmp/$1" g
  mkfix "$1"
  g="$d/rsdd/internal/retro/reconcile"; mkdir -p "$g"
  printf '%s\n' '#!/usr/bin/env bash' 'rsdd_exec retro reconcile-issues --toolbelt "$_RSDD_SELF" "$@"' > "$d/scripts/reconcile-issues.sh"
  printf '%s\n' 'package reconcile' '' \
    'var reCode = regexp.MustCompile(`^degraded: (gh|jq)`)' \
    'func f(r *run) error {' \
    '	r.degrade("degraded: gh not found on PATH — install gh")' \
    '	s := fmt.Sprintf("degraded: jq failed on %s — refusing", p)' \
    '	r.degrade("degraded: git could not be run in %s (%v) — cannot verify", p, s)' \
    '	return fmt.Errorf("degraded: --issues-cache file not readable: %s — pass a file", s)' \
    '}' > "$g/run.go"
  edit "$d/reg.md" 's#^\(| `degraded: jq failed on` | degraded | research-sdd-init.sh\) |#\1, reconcile-issues.sh |#'
  edit "$d/reg.md" '/^| `degraded: jq failed on` /a\
| `degraded: git could not be run in <v> (<v>)` | degraded | reconcile-issues.sh | m13 | fix git |'
  edit "$d/reg.md" 's#^\(| `degraded: rsdd-unavailable` | degraded | lib/rsdd-exec.sh\) |#\1, reconcile-issues.sh |#'
  printf '%s\n' 'printf '"'"'degraded: rsdd-unavailable — %s\n'"'"' "$1" >&2' >> "$d/scripts/reconcile-issues.sh"
}
mkgofix2 go2_good
expect "Go emitter: r.degrade / fmt.Errorf calls of a mapped shim are verified against the rows" 0 "$tmp/go2_good/reg.md" "$tmp/go2_good/scripts"
mkgofix2 go2_unlisted
printf '%s\n' 'func g(r *run) string { return fmt.Sprintf("degraded: new reconcile code %s — x", r.x) }' >> "$tmp/go2_unlisted/rsdd/internal/retro/reconcile/run.go"
expect "Go emitter: a fmt.Sprintf code in a mapped package must be a registry row" 1 "$tmp/go2_unlisted/reg.md" "$tmp/go2_unlisted/scripts" 'unlisted code emitted by reconcile-issues.sh: degraded: new reconcile code'
mkgofix2 go2_fprintf
printf '%s\n' 'func g(out io.Writer) { fmt.Fprintf(out, "degraded: only fprintf sees this — x\n") }' >> "$tmp/go2_fprintf/rsdd/internal/retro/reconcile/run.go"
expect "Go emitter: fmt.Fprintf is a recognised emit call" 1 "$tmp/go2_fprintf/reg.md" "$tmp/go2_fprintf/scripts" 'unlisted code emitted by reconcile-issues.sh: degraded: only fprintf sees this'
mkgofix2 go2_absent; rm -rf "$tmp/go2_absent/rsdd"
expect "Go emitter: a mapped shim whose Go dir is absent is DEGRADED absent-input" 2 "$tmp/go2_absent/reg.md" "$tmp/go2_absent/scripts" 'DEGRADED: absent-input: reconcile-issues.sh is a rsdd shim'
mkgofix2 go2_unmapped
printf '%s\n' '#!/usr/bin/env bash' 'rsdd_exec brand new-port "$@"' > "$tmp/go2_unmapped/scripts/brand-new-port.sh"
expect "Go emitter: an rsdd_exec shim with no map entry fails, named" 1 "$tmp/go2_unmapped/reg.md" "$tmp/go2_unmapped/scripts" 'rsdd shim with no GO_SRC entry and not in GO_NO_TYPED: brand-new-port.sh'
# the input-class scan reads the same mapped packages (sweep-audits.sh via fmt.Fprintf)
mkgoifix2() {
  local d="$tmp/$1" g
  mkifix "$1"
  g="$d/rsdd/internal/sweep"; mkdir -p "$g"
  printf '%s\n' '#!/usr/bin/env bash' 'rsdd_exec sweep audits "$@"' > "$d/tb/sweep-audits.sh"
  printf '%s\n' 'package sweep' 'func f(out io.Writer, p string) {' \
    '	fmt.Fprintf(out, "INFO: corpus not found (absent-input): %s\n", p)' \
    '	fmt.Fprintln(out, "INFO: nothing to audit (empty-input)")' \
    '	r.note("no-match: no audit matched — x")' \
    '	r.fail("unclassifiable: 3 items")' '}' > "$g/audits.go"
  edit "$d/reg.md" 's#^\(| `absent-input` | input | a.sh\) |#\1, sweep-audits.sh |#'
  edit "$d/reg.md" 's#^\(| `empty-input` | input | a.sh, lib/b.sh\) |#\1, sweep-audits.sh |#'
  edit "$d/reg.md" 's#^\(| `unclassifiable` | input | lib/b.sh\) |#\1, sweep-audits.sh |#'
  edit "$d/reg.md" 's#^\(| `no-match` | input | lib/b.sh\) |#\1, sweep-audits.sh |#'
}
mkgoifix2 i_go2
expect_ic "input scan: a fmt.Fprintf state of a mapped package is verified against the row" 0 i_go2
mkgoifix2 i_go2_unmapped
printf '%s\n' '#!/usr/bin/env bash' 'rsdd_exec brand new-port "$@"' > "$tmp/i_go2_unmapped/tb/brand-new-port.sh"
expect_ic "input scan: an rsdd_exec shim with no map entry fails, named" 1 i_go2_unmapped 'rsdd shim with no GO_SRC entry and not in GO_NO_TYPED: brand-new-port.sh'
mkgoifix2 i_go2_absent; rm -rf "$tmp/i_go2_absent/rsdd"
expect_ic "input scan: a mapped shim without its Go dir is DEGRADED absent-input" 2 i_go2_absent 'DEGRADED: absent-input: sweep-audits.sh is a rsdd shim'

# --- Go ports beyond calls (kit issue #2597): an rsdd_exec_hook shim, and a typed state ASSIGNED (or returned) in Go
# mkgoifix3 NAME SHIM CMD ROW GOLINE... — an input-scan fixture: tb/SHIM runs CMD, internal/sweep holds GOLINEs, and the
# registry row ROW (an input code) lists SHIM as an emitter
mkgoifix3() {
  local d="$tmp/$1" shim="$2" cmd="$3" row="$4" g
  mkifix "$1"
  g="$d/rsdd/internal/sweep"; mkdir -p "$g"
  printf '%s\n' '#!/usr/bin/env bash' "$cmd" > "$d/tb/$shim"
  shift 4
  printf '%s\n' 'package sweep' 'func f() (state string, reason *string) {' "$@" '	return' '}' > "$g/audits.go"
  [ "$row" = "-" ] || edit "$d/reg.md" "s#^\\(| \`$row\` | input | [^|]*[^ |]\\) |#\\1, $shim |#"   # row "-": the registry lists no row for the shim
}
HOOKCMD='rsdd_exec_hook sweep sweep audits --hook --kit "$_RSDD_SELF/.." "$@"'
SHIMCMD='rsdd_exec sweep audits "$@"'
STALE_NM="stale emitter: row lists sweep-audits.sh but sweep-audits.sh never emits 'no-match'"
mkgoifix3 i_hook_emit sweep-audits-hook.sh "$HOOKCMD" empty-input '	fmt.Fprintln(out, "INFO: nothing to audit (empty-input)")'
expect_ic "input scan: an rsdd_exec_hook shim mapped in GO_SRC is the row's emitter (#2597)" 0 i_hook_emit
mkgoifix3 i_hook_stale sweep-audits-hook.sh "$HOOKCMD" empty-input '	_ = 1'
expect_ic "input scan: a mapped rsdd_exec_hook shim whose Go dir stops emitting is a stale emitter (#2597)" 1 i_hook_stale "stale emitter: row lists sweep-audits-hook.sh but sweep-audits-hook.sh never emits 'empty-input'"
mkgoifix3 i_hook_unmapped brand-new-hook.sh 'rsdd_exec_hook brand new-hook "$@"' empty-input '	_ = 1'
expect_ic "input scan: an rsdd_exec_hook shim with no map entry fails, named (#2597)" 1 i_hook_unmapped 'rsdd shim with no GO_SRC entry and not in GO_NO_TYPED: brand-new-hook.sh'
mkgoifix3 i_go_assign sweep-audits.sh "$SHIMCMD" no-match '	state = "no-match"'
expect_ic "input scan: a Go assignment of a typed state is an emit (#2597)" 0 i_go_assign
mkgoifix3 i_go_assign_multi sweep-audits.sh "$SHIMCMD" no-match '	state, reason = "no-match", str("none matched")'
expect_ic "input scan: a Go multi-assign of a typed state is an emit (#2597)" 0 i_go_assign_multi
mkgoifix3 i_go_define sweep-audits.sh "$SHIMCMD" no-match '	state := "no-match"'
expect_ic "input scan: a Go := definition of a typed state is an emit (#2597)" 0 i_go_define
mkgoifix3 i_go_return sweep-audits.sh "$SHIMCMD" no-match '	return "no-match", str("none matched")'
expect_ic "input scan: a Go return of a typed state is an emit (#2597)" 0 i_go_return
mkgoifix3 i_go_assign_drop sweep-audits.sh "$SHIMCMD" no-match '	state = ""'
expect_ic "input scan: the Go assignment dropped makes the row a stale emitter (#2597)" 1 i_go_assign_drop "$STALE_NM"
mkgoifix3 i_go_assign_comment sweep-audits.sh "$SHIMCMD" no-match '	// state = "no-match"'
expect_ic "input scan: a commented-out Go assignment is not an emit (#2597)" 1 i_go_assign_comment "$STALE_NM"
mkgoifix3 i_go_compare sweep-audits.sh "$SHIMCMD" no-match '	if state == "no-match" { state = "" }'
expect_ic "input scan: a Go == comparison of a typed state is not an emit (#2597)" 1 i_go_compare "$STALE_NM"
# an unmapped hook shim that the registry does not list, so the unmapped finding is the only thing that can fail the scan
mkgoifix3 i_hook_unmapped_solo brand-new-hook.sh 'rsdd_exec_hook brand new-hook "$@"' - '	_ = 1'
expect_ic "input scan: an unmapped rsdd_exec_hook shim alone still fails the scan (#2597)" 1 i_hook_unmapped_solo 'rsdd shim with no GO_SRC entry and not in GO_NO_TYPED: brand-new-hook.sh'
# GO_FILES: a sibling file of the same package (the retros port) is not an emitter of the audits shim
mkgoifix3 i_go_files sweep-audits.sh "$SHIMCMD" empty-input '	fmt.Fprintln(out, "INFO: nothing to audit (empty-input)")'
printf '%s\n' 'package sweep' 'func g() (string, *string) { return "no-match", nil }' > "$tmp/i_go_files/rsdd/internal/sweep/retrosjson.go"
expect_ic "input scan: GO_FILES keeps a sibling file of the package out of the audits shim (#2597)" 0 i_go_files
mkgoifix3 i_go_files_absent sweep-audits.sh "$SHIMCMD" empty-input '	_ = 1'
mv "$tmp/i_go_files_absent/rsdd/internal/sweep/audits.go" "$tmp/i_go_files_absent/rsdd/internal/sweep/other.go"
expect_ic "input scan: a GO_FILES glob matching no file is DEGRADED absent-input (#2597)" 2 i_go_files_absent 'DEGRADED: absent-input: sweep-audits.sh is a rsdd shim'

# --- 5. teeth: mutate the CHECKER (a copy of this suite) and require each defect to go unnoticed ----
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  mkdir -p "$tmp/mut"
  CRASH="$(mutant_crash_re bash py)" || exit 2
  # tooth NAME FIXTURE GOOD_RC BAD_RC SED_EXPR — the checker (--check-only) on FIXTURE must exit GOOD_RC
  # as written and BAD_RC once SED_EXPR has disabled the guarded line. A refused build counts once.
  tooth() {
    local name="$1" fx="$2" good="$3" bad="$4" expr="$5" m="$tmp/mut/$1.sh" line
    local mode="${TOOTH_MODE:---check-only}" sub="${TOOTH_SUB:-scripts}"
    mutant_chain_or_count fail "$name" "$SELF" "$m" "$expr" || return 1
    if line="$(mutant_tooth "teeth $name" "$good" "$bad" "$m" --orig "$SELF" --bad-lacks "$CRASH" \
        -- bash @SUT@ "$mode" "$tmp/$fx/reg.md" "$tmp/$fx/$sub")"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
    printf '%s\n' "$line"
  }
  tooth unlisted     unl_first  1 0 '/# TOOTH-UNLISTED/s/finding /: /'
  tooth emptycont    cont_first 1 0 '/# TOOTH-EMPTYCONT/s/finding /: /'
  tooth placeholder  cont_ph    1 0 '/# TOOTH-PLACEHOLDER/s/finding /: /'
  tooth stale        stale      1 0 '/# TOOTH-STALE/s/finding /: /'
  tooth emitter      emitter    1 0 '/# TOOTH-EMITTER/s/finding /: /'
  tooth duplicate    dup        1 0 '/# TOOTH-DUP/s/finding /: /'
  tooth badclass     badclass   1 0 '/# TOOTH-CLASS/s/finding /: /'
  tooth reqinput     reqinput   1 0 '/# TOOTH-REQINPUT/s/finding /: /'
  tooth staleemit    stale_emit 1 0 '/# TOOTH-STALEEMIT/s/finding /: /'
  tooth unclass      unc_cont   1 0 '/# TOOTH-UNCLASS/s/finding /: /'
  tooth unclass-hash unc_hash   1 0 '/^  p = index(\$0, "degraded: "); if (!p) next/a\
  c = index($0, " #"); if (c \&\& c < p) next'
  tooth mb-unlisted   unl_mb     1 0 '/# TOOTH-UNLISTED/s/finding /: /'
  tooth mb-stale      stale_mb   1 0 '/# TOOTH-STALE/s/finding /: /'
  tooth mb-scanned    mb_scanned    1 0 '/^SCRIPTS=(/s/ migrate-backlogs.sh / /'
  tooth rsdd-scanned rsdd_scanned 1 0 '/^SCRIPTS=(/s/ lib\/rsdd-exec.sh)/)/'
  tooth mb-emitter    mb_emitter 1 0 '/# TOOTH-EMITTER/s/finding /: /'
  # Go emitters: dropping one code from the Go source must fail, and each guard of the Go scan has teeth
  tooth go-staleemit go_drop    1 0 '/# TOOTH-STALEEMIT/s/finding /: /'
  tooth go-shared    go_shared  0 1 '/# TOOTH-GOSHARED/s/^.*$/      :/'
  tooth go-unlisted  go_unlisted 1 0 '/# TOOTH-UNLISTED/s/finding /: /'
  tooth go-stray     go_stray   1 0 '/# TOOTH-GOSTRAY/s/finding /: /'
  tooth go-absent    go_absent  2 0 '/# TOOTH-GOABSENT/s/return 2/return 0/'
  tooth go-emit      go_solo    1 0 '/# TOOTH-GOEMIT/s/^\( *\)/\1: /'
  tooth go-testfile  go_test_only 0 1 '/# TOOTH-GOTESTFILE/d'
  # Go emitters, kit issue #2583: the map, the unmapped-shim guard, and one tooth per emit-call alternative
  tooth go-map       go_good    0 1 '/# TOOTH-GOMAP$/d'
  tooth go-map2      go2_good   0 1 '/# TOOTH-GOMAP2$/d'
  tooth go-map-absent go2_absent 2 1 '/# TOOTH-GOMAP2$/d'
  tooth go-unmapped  go2_unmapped 1 0 '/# TOOTH-GOUNMAPPED-FINDING/s/finding /: /'
  tooth go-call-degrade  go2_good 0 1 '/^GO_CALL_RE=/s/|\\.degrade//'
  tooth go-call-errorf   go2_good 0 1 '/^GO_CALL_RE=/s/|fmt\\.Errorf//'
  tooth go-call-sprintf  go2_good 0 1 '/^GO_CALL_RE=/s/|fmt\\.Sprintf//'
  tooth go-call-errf     go_good  0 2 '/^GO_CALL_RE=/s/errf|//'
  tooth go-verbs     go2_good   0 1 '/# TOOTH-GOCALLS/s,s/%\[-+# 0-9.\]\*\[vsdqxXtTcUeEfFgGbpow\]/%s/g; ,,'
  tooth go-regexp-skip  go2_good 0 1 '/# TOOTH-GOSTRAYRE/s,/regexp\\.MustCompile/ {next} ,,'
  tooth zeroextract  d_zero     2 1 '/# TOOTH-ZEROEXTRACT/s/\[ -z "\$toks" \]/false/'
  tooth zerorows     d_norows   2 1 '/# TOOTH-ZEROROWS/s/\[ -z "\$rows" \]/false/'
  tooth comment-skip commented  0 1 '/# TOOTH-COMMENT/d'
  tooth var-subst    good       0 1 '/# TOOTH-VARSUB/d'
  tooth cmdsub       good_sub   0 1 '/# TOOTH-CMDSUB/d'
  tooth specialsub   good_sub   0 1 '/# TOOTH-SPECIALSUB/d'
  tooth emdash-cut   good       0 1 '/# TOOTH-EMDASH/d'
  # input-class scan teeth: the same helper, pointed at --check-input with the fixture's own (empty) waiver file
  ictooth() { RC_IC_WAIVERS_FILE="$tmp/$2/waivers.txt" TOOTH_MODE=--check-input TOOTH_SUB=tb tooth "$@"; }
  ictooth ic-unlisted    i_unlisted    1 0 '/# TOOTH-IC-UNLISTED/s/finding /: /'
  # maint/ is scanned: drop it from the glob and the unlisted maint/ emitter is no longer found
  ictooth ic-maint-scanned i_maint_bad 1 0 's#"\$dir"/lib/\*\.sh "\$dir"/maint/\*\.sh; do#"$dir"/lib/*.sh; do#'
  ictooth ic-staleemit   i_staleemit   1 0 '/# TOOTH-IC-STALEEMIT/s/finding /: /'
  ictooth ic-emitter     i_emitter1    1 0 '/# TOOTH-IC-EMITTER/s/finding /: /'
  ictooth ic-stalerow    i_stalerow1   1 0 '/# TOOTH-IC-STALEROW/s/finding /: /'
  ictooth ic-go-emit     i_go         0 1 '/# TOOTH-IC-GOOCC/s/then all=/then : /'
  ictooth ic-go-unmapped i_go2_unmapped 1 0 '/# TOOTH-IC-GOUNMAPPED/s/finding /: /'
  ictooth ic-go-fprintf  i_go2        0 1 '/^GO_CALL_RE=/s/|fmt\\.Fprintf//'
  ictooth ic-go-fprintln i_go2        0 1 '/^GO_CALL_RE=/s/|fmt\\.Fprintln//'
  ictooth ic-go-note     i_go2        0 1 '/^GO_CALL_RE=/s/|\\.note//'
  ictooth ic-go-fail     i_go2        0 1 '/^GO_CALL_RE=/s/|\\.fail//'
  ictooth ic-go-map      i_go2        0 1 '/"sweep-audits.sh=/d'
  # Go ports beyond calls (kit issue #2597): the hook pattern, the assign / return rule, the comment filter, the file glob
  ictooth ic-hook-shim   i_hook_emit  0 1 '/^GO_SHIM_RE=/s/(_hook)?//'
  ictooth ic-hook-unmapped i_hook_unmapped_solo 1 0 '/^GO_SHIM_RE=/s/(_hook)?//'
  ictooth ic-go-assign   i_go_assign  0 1 '/^GO_ASSIGN_RE=/s/=\[\[:space:\]\]\*\\"(/=ZZ\\"(/'
  ictooth ic-go-return   i_go_return  0 1 '/^GO_ASSIGN_RE=/s/return\[\[:space:\]\]+/returnZZ/'
  ictooth ic-go-return-awk i_go_return 0 1 '/# TOOTH-IC-RETURN/s/prefix ~ q_ret/prefix ~ "ZZ"/'
  # a Go == comparison is rejected by the awk consumer rule (q_eq), whose teeth are ic-cons-eq / ic-haz-eq above; a Go-only tooth
  # cannot isolate it because the shell consumer lines of the fixture flip under the same mutation
  ictooth ic-go-comment  i_go_assign_comment 1 0 '/# TOOTH-GOCALLS/s,/^\[\[:space:\]\]\*\\/\\//d; ,,'
  ictooth ic-go-files    i_go_files   0 1 '/# TOOTH-GOFILES/s/^GO_FILES=(.*)   #/GO_FILES=()   #/'
  ictooth ic-go-files-absent i_go_files_absent 2 1 '/# TOOTH-GOFILES/s/^GO_FILES=(.*)   #/GO_FILES=()   #/'
  ictooth ic-unclass     i_uncl        1 0 '/# TOOTH-IC-UNCLASS/s/finding /: /'
  ictooth ic-stalewaiver i_stalewaiver 1 0 '/# TOOTH-IC-STALEWAIVER/s/finding /: /'
  # ic-zerofiles mutates TWO guards on purpose: with only the zero-files guard off, the scan still reaches the
  # zero-occurrences guard and exits 2 for the same input, so the mutant would be indistinguishable. Disabling
  # both lets the empty scan fall through to the row checks (stale rows), which is the observable difference.
  ictooth ic-zerofiles  i_zero        2 1 '/# TOOTH-IC-ZEROFILES/s/-eq 0/-eq -1/;/# TOOTH-IC-ZEROOCC/s/\[ -z "\$all" \]/false/'
  ictooth ic-zeroocc     i_zeroocc     2 1 '/# TOOTH-IC-ZEROOCC/s/\[ -z "\$all" \]/false/'
  ictooth ic-waivercount i_waivercount 1 0 '/# TOOTH-IC-WAIVERCOUNT/s/finding /: /'
  # one tooth per counter alternative: each fixture line below is caught by exactly that alternative
  ictooth ic-ctr-eq      i_good        0 1 '/# TOOTH-IC-CTR-EQ/s/post == "="/post == "ZZ"/'
  ictooth ic-ctr-dollar  i_good        0 1 '/# TOOTH-IC-CTR-DOLLAR/s/pre == "\$"/pre == "ZZ"/'
  ictooth ic-ctr-brace   i_good        0 1 '/# TOOTH-IC-CTR-BRACE/s/pre == "{"/pre == "ZZ"/'
  ictooth ic-ctr-arith   i_good        0 1 '/# TOOTH-IC-CTR-ARITH/s/prefix ~ \//prefix ~ \/ZZ/'
  ictooth ic-comment     i_good        0 1 '/# TOOTH-IC-COMMENT/s/== "C"/== "ZZ"/'
  ictooth ic-hash        i_good        0 1 '/# TOOTH-IC-HASH/s/ch == "#"/ch == "ZZ"/'
  # one tooth per consumer alternative (positive: the line must stay a non-emit)
  ictooth ic-cons-grep   i_good        0 1 '/# TOOTH-IC-CONS-GREP/s/sg ~ re_grep/mp ~ "ZZ"/'
  ictooth ic-cons-case   i_good        0 1 '/# TOOTH-IC-CONS-CASE/s/sg ~ re_case/mp ~ "ZZ"/'
  ictooth ic-cons-eq     i_good        0 1 '/# TOOTH-IC-CONS-EQ/s/prefix ~ q_eq/prefix ~ "ZZ"/'
  ictooth ic-cons-brk    i_good        0 1 '/# TOOTH-IC-CONS-BRK/s/prefix ~ q_brk/prefix ~ "ZZ"/'
  ictooth ic-cons-star   i_good        0 1 '/# TOOTH-IC-CONS-STAR/s/prefix ~ \/^\[\[:space:\]\]\*\\\*\//prefix ~ \/ZZ\//'
  ictooth ic-cons-slash  i_good        0 1 '/# TOOTH-IC-CONS-SLASH/s/prefix ~ \/^\[\[:space:\]\]\*\\\/\//prefix ~ \/ZZ\//'
  ictooth ic-assign      i_good        0 1 '/# TOOTH-IC-ASSIGN/s/prefix ~ q_assign/prefix ~ "ZZ"/'
  # negative: the over-broad consumer/comment rules this scanner used to have, reintroduced one at a time,
  # must make the matching hazard fixture go clean (rc 1 -> 0), proving the hazard fixtures bite
  ictooth ic-haz-grep    h_grepmsg     1 0 '/# TOOTH-IC-CONS-GREP/s|sg ~ re_grep|scan ~ /grep[[:space:]]/|'
  ictooth ic-haz-case    h_casemsg     1 0 '/# TOOTH-IC-CONS-CASE/s|sg ~ re_case|scan ~ /case[[:space:]]/|'
  ictooth ic-haz-eq      h_eqmsg       1 0 '/# TOOTH-IC-CONS-EQ/s|prefix ~ q_eq|prefix ~ q_assign|'
  ictooth ic-haz-shassign h_shassign   1 0 '/# TOOTH-IC-CONS-EQ/s|prefix ~ q_eq|prefix ~ q_assign|'
  ictooth ic-haz-jqassign h_jqassign   1 0 '/# TOOTH-IC-CONS-BRK/s/ && mp ~ re_br/ \&\& 1/'
  ictooth ic-haz-slash   h_slash       1 0 '/# TOOTH-IC-CONS-SLASH/s/(\\{|\$)/(.|$)/'
  ictooth ic-haz-star    h_star        1 0 '/# TOOTH-IC-CONS-STAR/s/prefix !~ \/\\)\//1/'
  ictooth ic-haz-sqhash  h_sqhash      1 0 '/# TOOTH-IC-SQ/s/st = "s"/st = ""/'
  ictooth ic-haz-dqhash  h_dqhash      1 0 '/# TOOTH-IC-DQ/s/st = "d"/st = ""/'
  ictooth ic-haz-seg-or   h_seg_or     1 0 '/# TOOTH-IC-SEG/s/lastseg(mp)/mp/'
  ictooth ic-haz-seg-then h_seg_then   1 0 '/# TOOTH-IC-SEG/s/lastseg(mp)/mp/'
  ictooth ic-haz-seg-case h_seg_case   1 0 '/# TOOTH-IC-SEG/s/lastseg(mp)/mp/'
  ictooth ic-jq          i_good        0 1 '/# TOOTH-IC-JQ/s/(then|else)/(thenX|elseX)/'
  ictooth ic-escape      i_good        0 1 '/# TOOTH-IC-ESCAPE/s/\[tn\]/[zz]/'
  ictooth ic-marker     i_good        0 1 '/# TOOTH-IC-MARKER/s/pre == "("/pre == "Z"/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
