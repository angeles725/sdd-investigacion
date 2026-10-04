#!/usr/bin/env bash
# reason-codes.test.sh — coverage test for research-sdd/toolbelt/reason-codes.v1.md (kit issue #1704, slice 1).
#
# The registry is a closed table: one row per `degraded:` class emitted today, plus the three typed
# input classes, each row naming exactly one continuation. This suite extracts the emitted `degraded:`
# tokens from the four scanned scripts and proves the registry and the emitters agree:
#
#   - an emitted token that is not a registry code            -> FAIL (unlisted code)
#   - a registry degraded row that no scanned script emits    -> FAIL (stale row)
#   - an emitter that the row does not list                   -> FAIL (emitter mismatch)
#   - a row with an empty / placeholder continuation          -> FAIL
#   - malformed row, duplicate code, bad class, missing required input row -> FAIL
#   - registry or script absent, unreadable, or ZERO emit lines extracted -> typed DEGRADED, exit 2
#     (could-not-look is not clean: a zero that cannot prove it looked is the CLAUDE.md section 7 defect)
#
# EXTRACTION RULE (the same text is in reason-codes.v1.md, "How a code is derived"). For every
# non-comment line containing an `echo` or `printf` word AND the literal `degraded: `:
#   1. start at the first `degraded: `
#   2. replace shell expansions (${...}, $name) and %s / %d with <v>, then collapse runs of <v>
#   3. cut at the first " — " (em dash), literal \n, or closing double quote
#   4. strip trailing whitespace and trailing <v>
# Comment lines, grep patterns (no echo/printf) and variable assignments are never emit lines.
#
# Usage: reason-codes.test.sh [--prove-teeth]
#        reason-codes.test.sh --check-only REGISTRY SCRIPT_DIR   (internal: the checker alone, exit 0/1/2)
# Exit: 0 all held · 1 any failure · 2 typed DEGRADED (could not look).
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REGISTRY="$HERE/../reason-codes.v1.md"
TOOLBELT="$HERE/.."

SCRIPTS=(research-sdd-status.sh reconcile-issues.sh stage-retro-issues.sh research-sdd-init.sh)
REQUIRED_INPUT=(absent-input empty-input unclassifiable)

# The extraction rule as an awk program (kept in one place; teeth mutate individual lines of it).
EXTRACT_AWK='
/^[[:space:]]*#/ {next}                                                    # TOOTH-COMMENT
/(^|[^[:alnum:]_])(echo|printf)[[:space:]]/ && index($0, "degraded: ") {
  s = substr($0, index($0, "degraded: "))
  gsub(/\$\{[^}]*\}/, "<v>", s)
  gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "<v>", s)                               # TOOTH-VARSUB
  gsub(/%[sd]/, "<v>", s)
  i = index(s, " — "); if (i) s = substr(s, 1, i - 1)                      # TOOTH-EMDASH
  i = index(s, "\\n"); if (i) s = substr(s, 1, i - 1)
  i = index(s, "\""); if (i) s = substr(s, 1, i - 1)
  while (gsub(/<v><v>/, "<v>", s));
  while (sub(/([[:space:]]+|<v>)$/, "", s));
  print s
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
  local reg="$1" dir="$2" rows s f toks t i n
  local -a codes=() classes=() emits=() used=()
  local c cl em ct lc
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

  for t in "${REQUIRED_INPUT[@]}"; do
    f=0
    for ((i = 0; i < n; i++)); do
      if [ "${codes[$i]}" = "$t" ] && [ "${classes[$i]}" = "input" ]; then f=1; fi
    done
    if [ "$f" -eq 0 ]; then finding "required input-class row missing: $t"; fi   # TOOTH-REQINPUT
  done

  for s in "${SCRIPTS[@]}"; do
    f="$dir/$s"
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf 'DEGRADED: scanned script absent or unreadable: %s\n' "$f"; return 2
    fi
    toks="$(awk "$EXTRACT_AWK" "$f")" || { printf 'DEGRADED: awk failed reading %s\n' "$f"; return 2; }
    if [ -z "$toks" ]; then                                                 # TOOTH-ZEROEXTRACT
      printf 'DEGRADED: extracted zero degraded emit lines from %s (could not look)\n' "$s"; return 2
    fi
    while IFS= read -r t; do
      f=-1
      for ((i = 0; i < n; i++)); do
        if [ "${codes[$i]}" = "$t" ]; then f=$i; fi
      done
      if [ "$f" -lt 0 ]; then
        finding "unlisted code emitted by $s: $t"                           # TOOTH-UNLISTED
        continue
      fi
      used[f]=1
      em="$(printf '%s' "${emits[$f]}" | tr -d ' ')"
      case ",$em," in
        *",$s,"*) ;;
        *) finding "emitter mismatch: $s emits '$t' but the row lists '${emits[$f]}'" ;;   # TOOTH-EMITTER
      esac
    done <<<"$toks"
  done

  for ((i = 0; i < n; i++)); do
    if [ "${classes[$i]}" = "degraded" ] && [ -z "${used[$i]:-}" ]; then
      finding "stale row: degraded code never emitted by a scanned script: ${codes[$i]}"   # TOOTH-STALE
    fi
  done

  [ "$nfind" -eq 0 ]
}

if [ "${1:-}" = "--check-only" ]; then
  rc_check "${2:?registry}" "${3:?script dir}"
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

# mkfix NAME — a good registry + four scanned scripts under $tmp/NAME. Every script ends WITHOUT a
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
  printf '%s' 'echo "degraded: jq failed on $f — refusing"' > "$d/scripts/research-sdd-init.sh"
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

# --- 2. extraction rule on a literal fixture ---------------------------------------------------
cat > "$tmp/extract.sh" <<'EOF'
echo "degraded: a b $x c — tail"
printf 'degraded: p q: %s\n' "$z"
echo "degraded: r${_em:+ — }${_em}" >&2
# echo "degraded: commented"
x=1 # not an emit degraded: foo
grep -qE '^degraded:' file
echo "NOTE: degraded: iconv bad — z"
EOF
want="$(printf '%s\n' 'degraded: a b <v> c' 'degraded: p q:' 'degraded: r' 'degraded: iconv bad')"
got="$(awk "$EXTRACT_AWK" "$tmp/extract.sh")"
if [ "$got" = "$want" ]; then ok "extraction rule: placeholders, em-dash/\\n/quote cuts, comment and non-emit lines skipped"
else no "extraction rule"; printf '        got:\n%s\n' "$got" | sed 's/^/        /'; fi

# --- 3. fixtures: good, then each defect --------------------------------------------------------
mkfix good
expect "fixture good registry is clean" 0 "$tmp/good/reg.md" "$tmp/good/scripts"

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

# --- 5. teeth: mutate the CHECKER (a copy of this suite) and require each defect to go unnoticed ----
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
    || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth ($HERE/lib/mutant.sh)" >&2; exit 2; }
  mkdir -p "$tmp/mut"
  CRASH='integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError'
  # tooth NAME FIXTURE GOOD_RC BAD_RC SED_EXPR — the checker (--check-only) on FIXTURE must exit GOOD_RC
  # as written and BAD_RC once SED_EXPR has disabled the guarded line. A refused build counts once.
  tooth() {
    local name="$1" fx="$2" good="$3" bad="$4" expr="$5" m="$tmp/mut/$1.sh" line
    mutant_chain "$name" "$SELF" "$m" "$expr" || { fail=$((fail + 1)); return 1; }
    if line="$(mutant_tooth "teeth $name" "$good" "$bad" "$m" --orig "$SELF" --bad-lacks "$CRASH" \
        -- bash @SUT@ --check-only "$tmp/$fx/reg.md" "$tmp/$fx/scripts")"; then
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
  tooth zeroextract  d_zero     2 1 '/# TOOTH-ZEROEXTRACT/s/\[ -z "\$toks" \]/false/'
  tooth zerorows     d_norows   2 1 '/# TOOTH-ZEROROWS/s/\[ -z "\$rows" \]/false/'
  tooth comment-skip commented  0 1 '/# TOOTH-COMMENT/d'
  tooth var-subst    good       0 1 '/# TOOTH-VARSUB/d'
  tooth emdash-cut   good       0 1 '/# TOOTH-EMDASH/d'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
