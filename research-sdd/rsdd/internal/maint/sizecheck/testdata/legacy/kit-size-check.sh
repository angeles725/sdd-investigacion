#!/usr/bin/env bash
# kit-size-check.sh — pre-RDD size guard (kit issue #2214).
#
# Measures the AUTHORED changed lines (additions + deletions) of `git diff --numstat <base>...<head>`,
# names mechanical-churn hotspots, and refuses or warns above the review budget BEFORE the diff goes to
# RDD / adversarial review. Read-only: it only runs `git diff` / `git rev-parse` and never writes to the repo.
#
# Usage: kit-size-check.sh --base <ref> [--head <ref>] [--budget N] [--hard-limit M] [--strict]
#                          [--format report|json]
#   --base REF      required; the diff is REF...HEAD (merge-base form, like a PR)
#   --head REF      default HEAD
#   --budget N      authored-line budget, default 400 (CLAUDE.md section 6)
#   --hard-limit M  refuse above M, default 2 x budget; M must be >= budget
#   --strict        over-budget exits 3 instead of 0
#   --format        report (default) or json
#
# Verdict (line `size: <state>`, JSON field "state") and exit code:
#   ok            0 < n <= budget                     exit 0
#   over-budget   budget < n <= hard-limit            exit 0, exit 3 with --strict; prints a split suggestion
#   refuse        n > hard-limit                      exit 3; prints a split suggestion
#   empty-input   the diff lists no file at all       exit 0  (distinct from all-excluded)
#   all-excluded  files changed, none measured, every one excluded data or binary  exit 0
#   unmeasured    nothing measured and nothing excluded: only binary files and/or pure renames
#                 (0 lines is NOT "small": the binaries were not read)   exit 0
#   degraded      no git, not a work tree, bad ref,   exit 2  (stderr: `degraded: kit-size-check: <why>`;
#                 no merge base, git diff failed,             also bad usage; never read as a zero)
#                 unsupported path
#
# Excluded from the count (printed as a separate total, never hidden): pure DATA under
# research-sdd/toolbelt/tests/fixtures/** (the *.json fixtures and the merge-gate workflow copy
# tests/fixtures/merge-gate/wf-real-toolbelt-tests.yml) and lockfiles (*.lock, package-lock.json,
# pnpm-lock.yaml, go.sum). Fixture *.sh / *.py / *.mjs (stubs, shims, helpers) are reviewed logic and ARE
# counted. Binary files (numstat `-`) are listed as unmeasured. Pure renames/moves are listed with 0 lines.
# The range is BASE...HEAD (merge-base form): commits that only advanced BASE after the fork are not counted.
#
# Split suggestion: units are packed first-fit in path order. A test pairs with the SUT of the same basename
# anywhere under research-sdd/toolbelt/ (maint/, lib/ too). A unit larger than the budget on its own gets a
# chunk marked `single-unit-over-budget`: the suggestion cannot split it, so that chunk exceeds the budget.
#
# Mechanical-churn hotspot: a measured file with > 40% of the authored lines, at least 10 non-blank added
# lines, where >= 80% of them are the same line after replacing quoted strings with S and digit runs with N.
# That shape is one repeated edit, not 400 lines of thought: prefer an env/config switch or a separate
# mechanical PR (kit #2200: the RSDD_INIT_WIRING switch kept a wiring change out of every hook file).
#
# Counted on the form git reports: a line edited in place counts as 1 deleted + 1 added.

set -uo pipefail

BUDGET=400
HARD=''
HARD_GIVEN=0
BASE=''
HEAD_REF='HEAD'
FORMAT='report'
STRICT=0
WORK=''
trap '[ -z "$WORK" ] || rm -rf -- "$WORK"' EXIT

# usage — the header comment block, verbatim, on stdout.
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# jesc — JSON string body: backslash, quote, \t \n \r escaped; any other control character becomes `?`.
jesc() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  s=${s//[[:cntrl:]]/?}
  printf '%s' "$s"
}

# degrade <why> — typed degraded state, exit 2. JSON mode prints a JSON document on stdout.
degrade() {
  printf 'degraded: kit-size-check: %s\n' "$1" >&2
  if [ "$FORMAT" = json ]; then
    printf '{"state":"degraded","reason":"%s"}\n' "$(jesc "$1")"
  else
    printf 'size: degraded\n'
  fi
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || degrade "--base needs a value"; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || degrade "--head needs a value"; HEAD_REF="$2"; shift 2 ;;
    --budget) [ $# -ge 2 ] || degrade "--budget needs a value"; BUDGET="$2"; shift 2 ;;
    --hard-limit) [ $# -ge 2 ] || degrade "--hard-limit needs a value"; HARD="$2"; HARD_GIVEN=1; shift 2 ;;
    --format) [ $# -ge 2 ] || degrade "--format needs a value"; FORMAT="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; degrade "unknown argument: $1" ;;
  esac
done
case "$FORMAT" in report|json) ;; *) FORMAT=report; degrade "--format must be report or json" ;; esac
[ -n "$BASE" ] || { usage >&2; degrade "--base is required"; }
# Digits only, at most 9 (no overflow), forced to base 10: `08` / `010` are 8 / 10, never an octal error.
case "$BUDGET" in ''|*[!0-9]*) degrade "--budget must be a positive integer: $BUDGET" ;; esac
[ "${#BUDGET}" -le 9 ] || degrade "--budget must be a positive integer of at most 9 digits: $BUDGET"
BUDGET=$((10#$BUDGET))
[ "$BUDGET" -ge 1 ] || degrade "--budget must be a positive integer: $BUDGET"
if [ "$HARD_GIVEN" -eq 1 ]; then
  case "$HARD" in ''|*[!0-9]*) degrade "--hard-limit must be a positive integer: $HARD" ;; esac
  [ "${#HARD}" -le 9 ] || degrade "--hard-limit must be a positive integer of at most 9 digits: $HARD"
  HARD=$((10#$HARD))
else
  HARD=$((BUDGET * 2))
fi
[ "$HARD" -ge "$BUDGET" ] || degrade "--hard-limit ($HARD) must be >= --budget ($BUDGET)"

command -v git >/dev/null 2>&1 || degrade "git is not installed"
command -v awk >/dev/null 2>&1 || degrade "awk is not installed"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || degrade "not inside a git work tree"
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null || degrade "base ref does not resolve to a commit: $BASE"
git rev-parse --verify --quiet "${HEAD_REF}^{commit}" >/dev/null || degrade "head ref does not resolve to a commit: $HEAD_REF"
git merge-base "$BASE" "$HEAD_REF" >/dev/null 2>&1 || degrade "no merge base between $BASE and $HEAD_REF"

RANGE="$BASE...$HEAD_REF"
# A bash variable cannot hold the NULs of `-z` output, so the numstat goes through a temp file.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kit-size-check.XXXXXX")" || degrade "mktemp failed"
git diff --no-ext-diff -M --numstat -z "$RANGE" >"$WORK/numstat" 2>/dev/null || degrade "git diff failed for $RANGE"

is_excluded() {
  case "$1" in
    # Fixture logic (stubs, shims, helper scripts) is reviewed code: only pure data is excluded.
    research-sdd/toolbelt/tests/fixtures/*.sh|research-sdd/toolbelt/tests/fixtures/*.py|research-sdd/toolbelt/tests/fixtures/*.mjs) return 1 ;;
    research-sdd/toolbelt/tests/fixtures/*) return 0 ;;
    *.lock|*/package-lock.json|package-lock.json|*/pnpm-lock.yaml|pnpm-lock.yaml|*/go.sum|go.sum) return 0 ;;
  esac
  return 1
}

# Parse `-z` numstat: "A\tD\tpath\0" or, for a rename, "A\tD\t\0old\0new\0".
TOKS=()
while IFS= read -r -d '' t; do TOKS+=("$t"); done <"$WORK/numstat"
P_path=(); P_old=(); P_add=(); P_del=()
nentries=0; tok_i=0
while [ "$tok_i" -lt "${#TOKS[@]}" ]; do
  t="${TOKS[$tok_i]}"; tok_i=$((tok_i + 1))
  a=${t%%$'\t'*}; rest=${t#*$'\t'}; d=${rest%%$'\t'*}; p=${rest#*$'\t'}
  old=''
  if [ -z "$p" ]; then
    [ $((tok_i + 2)) -le "${#TOKS[@]}" ] || degrade "malformed rename record in numstat"
    old="${TOKS[$tok_i]}"; p="${TOKS[$((tok_i + 1))]:-}"; tok_i=$((tok_i + 2))
    [ -n "$p" ] || degrade "malformed rename record in numstat"
  fi
  case "$p$old" in *[[:cntrl:]]*) degrade "unsupported path (control character: tab, newline, CR...) in diff" ;; esac
  P_path+=("$p"); P_old+=("$old"); P_add+=("$a"); P_del+=("$d")
  nentries=$((nentries + 1))
done

M_rows=()      # lines<TAB>added<TAB>deleted<TAB>path<TAB>oldpath
X_rows=()      # excluded: lines<TAB>path
U_paths=()     # unmeasured (binary)
R_rows=()      # pure renames: old -> new
authored=0; adds=0; dels=0; ex_lines=0; ex_files=0
for ((i = 0; i < nentries; i++)); do
  p="${P_path[$i]}"; a="${P_add[$i]}"; d="${P_del[$i]}"; old="${P_old[$i]}"
  if is_excluded "$p"; then
    n=0; [ "$a" = - ] || n=$((a + d))
    ex_lines=$((ex_lines + n)); ex_files=$((ex_files + 1)); X_rows+=("$n"$'\t'"$p"); continue
  fi
  if [ "$a" = - ] || [ "$d" = - ]; then U_paths+=("$p"); continue; fi
  if [ -n "$old" ] && [ "$a" -eq 0 ] && [ "$d" -eq 0 ]; then R_rows+=("$old -> $p"); continue; fi
  n=$((a + d)); authored=$((authored + n)); adds=$((adds + a)); dels=$((dels + d))
  M_rows+=("$n"$'\t'"$a"$'\t'"$d"$'\t'"$p"$'\t'"$old")
done

if [ "$nentries" -eq 0 ]; then state=empty-input
elif [ "${#M_rows[@]}" -eq 0 ] && [ "$ex_files" -gt 0 ] && [ "${#R_rows[@]}" -eq 0 ]; then state=all-excluded
elif [ "${#M_rows[@]}" -eq 0 ]; then state=unmeasured
elif [ "$authored" -le "$BUDGET" ]; then state=ok
elif [ "$authored" -le "$HARD" ]; then state=over-budget
else state=refuse; fi

SORTED=()
if [ "${#M_rows[@]}" -gt 0 ]; then
  while IFS= read -r l; do SORTED+=("$l"); done < <(printf '%s\n' "${M_rows[@]}" | LC_ALL=C sort -t$'\t' -k1,1nr -k4,4)
fi

# Hotspots: files holding > 40% of the authored lines whose added lines are one repeated edit.
H_rows=()   # path<TAB>lines<TAB>pct<TAB>share<TAB>pattern
H_unchecked=()   # candidate files whose hotspot diff failed: reported, never read as "no churn"
for row in ${SORTED[@]+"${SORTED[@]}"}; do
  IFS=$'\t' read -r n a d p old <<<"$row"
  [ $((n * 100)) -gt $((authored * 40)) ] || continue
  specs=("$p"); [ -z "$old" ] || specs+=("$old")
  if ! git --literal-pathspecs diff --no-ext-diff -M --unified=0 "$RANGE" -- "${specs[@]}" >"$WORK/hotspot.diff" 2>/dev/null; then
    H_unchecked+=("$p"); continue
  fi
  hs="$(awk -v q="'" '
    /^diff / { inh = 0 }
    /^@@/ { inh = 1; next }
    inh && /^\+/ {
      s = substr($0, 2); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
      if (s == "") next
      t = s; gsub(/"[^"]*"/, "S", t); gsub(q "[^" q "]*" q, "S", t); gsub(/[0-9]+/, "N", t)
      tot++; c[t]++
    }
    END {
      if (tot == 0) exit
      best = 0; bk = ""
      for (k in c) if (c[k] > best || (c[k] == best && k < bk)) { best = c[k]; bk = k }
      printf "%d\t%d\t%s\n", tot, best, bk
    }' "$WORK/hotspot.diff")"
  [ -n "$hs" ] || continue
  IFS=$'\t' read -r tot best pat <<<"$hs"
  [ "$tot" -ge 10 ] && [ $((best * 100)) -ge $((tot * 80)) ] || continue
  H_rows+=("$p"$'\t'"$n"$'\t'$((n * 100 / authored))$'\t'$((best * 100 / tot))$'\t'"$pat")
done

# Split suggestion (over-budget / refuse): test+SUT pairs stay together, neighbours by directory, <= budget.
# A toolbelt test pairs with the SUT of the same basename ANYWHERE under research-sdd/toolbelt/ (maint/, lib/ too).
unit_key() {
  local p="$1" d b
  b=${p##*/}
  case "$p" in
    research-sdd/toolbelt/tests/*.test.sh) printf 'research-sdd/toolbelt/%s' "${b%.test.sh}" ;;
    research-sdd/toolbelt/tests/*) d=${p%/*}; printf '%s/%s' "$d" "${b%.*}" ;;
    research-sdd/toolbelt/*) printf 'research-sdd/toolbelt/%s' "${b%.*}" ;;
    */tests/*.test.sh) d=${p%/tests/*}; printf '%s/%s' "$d" "${b%.test.sh}" ;;
    *) d=${p%/*}; [ "$d" != "$p" ] || d=.; printf '%s/%s' "$d" "${b%.*}" ;;
  esac
}
SPLIT=()    # C<TAB>idx<TAB>lines<TAB>note   |   F<TAB>idx<TAB>lines<TAB>path
if [ "$state" = over-budget ] || [ "$state" = refuse ]; then
  units=""
  for row in "${SORTED[@]}"; do
    IFS=$'\t' read -r n a d p old <<<"$row"
    units+="$(unit_key "$p")"$'\t'"$n"$'\t'"$p"$'\n'
  done
  while IFS= read -r l; do SPLIT+=("$l"); done < <(printf '%s' "$units" | LC_ALL=C sort -t$'\t' -k1,1 -k3,3 | awk -F'\t' -v B="$BUDGET" '
    { k = $1; if (!(k in tot)) order[++nu] = k; tot[k] += $2; files[k] = files[k] $3 "\t" $2 "\n" }
    END {
      idx = 1; cur = 0
      for (i = 1; i <= nu; i++) {
        k = order[i]
        if (cur > 0 && cur + tot[k] > B) { idx++; cur = 0 }
        cur += tot[k]; csum[idx] = cur; if (tot[k] > B) over[idx] = 1
        nf = split(files[k], fl, "\n")
        for (j = 1; j < nf; j++) { split(fl[j], pr, "\t"); print "F\t" idx "\t" pr[2] "\t" pr[1] }
        if (tot[k] > B) { idx++; cur = 0 }
      }
      for (c = 1; c <= idx; c++) if (c in csum) print "C\t" c "\t" csum[c] "\t" ((c in over) ? "single-unit-over-budget" : "")
    }')
fi

exitcode=0
case "$state" in
  refuse) exitcode=3 ;;
  over-budget) [ "$STRICT" -eq 0 ] || exitcode=3 ;;
esac

if [ "$FORMAT" = json ]; then
  printf '{"state":"%s","base":"%s","head":"%s","budget":%s,"hard_limit":%s,"strict":%s,' \
    "$state" "$(jesc "$BASE")" "$(jesc "$HEAD_REF")" "$BUDGET" "$HARD" "$([ "$STRICT" -eq 1 ] && echo true || echo false)"
  printf '"authored":%s,"added":%s,"deleted":%s,"excluded_lines":%s,"excluded_files":%s,' "$authored" "$adds" "$dels" "$ex_lines" "$ex_files"
  printf '"files":['; sep=''
  for row in ${SORTED[@]+"${SORTED[@]}"}; do
    IFS=$'\t' read -r n a d p old <<<"$row"
    printf '%s{"path":"%s","added":%s,"deleted":%s,"lines":%s}' "$sep" "$(jesc "$p")" "$a" "$d" "$n"; sep=','
  done
  printf '],"excluded":['; sep=''
  for row in ${X_rows[@]+"${X_rows[@]}"}; do
    IFS=$'\t' read -r n p <<<"$row"; printf '%s{"path":"%s","lines":%s}' "$sep" "$(jesc "$p")" "$n"; sep=','
  done
  printf '],"unmeasured":['; sep=''
  for p in ${U_paths[@]+"${U_paths[@]}"}; do printf '%s"%s"' "$sep" "$(jesc "$p")"; sep=','; done
  printf '],"renames":['; sep=''
  for r in ${R_rows[@]+"${R_rows[@]}"}; do printf '%s"%s"' "$sep" "$(jesc "$r")"; sep=','; done
  printf '],"hotspots":['; sep=''
  for row in ${H_rows[@]+"${H_rows[@]}"}; do
    IFS=$'\t' read -r p n pct share pat <<<"$row"
    printf '%s{"path":"%s","lines":%s,"percent_of_total":%s,"pattern_share_percent":%s,"pattern":"%s"}' "$sep" "$(jesc "$p")" "$n" "$pct" "$share" "$(jesc "$pat")"; sep=','
  done
  printf '],"hotspots_unchecked":['; sep=''
  for p in ${H_unchecked[@]+"${H_unchecked[@]}"}; do printf '%s"%s"' "$sep" "$(jesc "$p")"; sep=','; done
  printf '],"split":['; sep=''
  for row in ${SPLIT[@]+"${SPLIT[@]}"}; do
    IFS=$'\t' read -r kind idx n x <<<"$row"
    [ "$kind" = C ] || continue
    printf '%s{"chunk":%s,"lines":%s,"note":"%s","files":[' "$sep" "$idx" "$n" "$(jesc "$x")"; sep=','; fs=''
    for r2 in "${SPLIT[@]}"; do
      IFS=$'\t' read -r k2 i2 n2 p2 <<<"$r2"
      [ "$k2" = F ] && [ "$i2" = "$idx" ] || continue
      printf '%s"%s"' "$fs" "$(jesc "$p2")"; fs=','
    done
    printf ']}'
  done
  printf ']}\n'
  exit "$exitcode"
fi

printf 'kit-size-check: %s (base %s, head %s; budget %s, hard-limit %s)\n' "$RANGE" "$BASE" "$HEAD_REF" "$BUDGET" "$HARD"
printf 'authored changed lines: %s (+%s -%s) in %s file(s)\n' "$authored" "$adds" "$dels" "${#M_rows[@]}"
printf 'excluded (generated/fixture/lockfile, not counted): %s line(s) in %s file(s)\n' "$ex_lines" "$ex_files"
shown=0
for row in ${X_rows[@]+"${X_rows[@]}"}; do
  [ "$shown" -lt 10 ] || break
  IFS=$'\t' read -r n p <<<"$row"; printf '  excluded  %6s  %s\n' "$n" "$p"; shown=$((shown + 1))
done
[ "$ex_files" -le 10 ] || printf '  ... and %s more excluded file(s) (all counted in the total above)\n' $((ex_files - 10))
printf 'unmeasured (binary): %s file(s)\n' "${#U_paths[@]}"
for p in ${U_paths[@]+"${U_paths[@]}"}; do printf '  unmeasured  %s\n' "$p"; done
printf 'pure renames (0 lines): %s file(s)\n' "${#R_rows[@]}"
for r in ${R_rows[@]+"${R_rows[@]}"}; do printf '  rename  %s\n' "$r"; done
if [ "${#SORTED[@]}" -gt 0 ]; then
  printf 'per-file (largest first):\n'
  shown=0
  for row in "${SORTED[@]}"; do
    [ "$shown" -lt 25 ] || break
    IFS=$'\t' read -r n a d p old <<<"$row"; printf '  %6s  +%s -%s  %s\n' "$n" "$a" "$d" "$p"; shown=$((shown + 1))
  done
  [ "${#SORTED[@]}" -le 25 ] || printf '  ... and %s more file(s)\n' $((${#SORTED[@]} - 25))
fi
for row in ${H_rows[@]+"${H_rows[@]}"}; do
  IFS=$'\t' read -r p n pct share pat <<<"$row"
  printf 'mechanical churn: %s holds %s%% of the lines (%s) and %s%% of its added lines repeat one pattern: %s\n' "$p" "$pct" "$n" "$share" "$pat"
  printf '  consider an env/config switch or a separate mechanical PR (e.g. #2200: the RSDD_INIT_WIRING switch)\n'
done
for p in ${H_unchecked[@]+"${H_unchecked[@]}"}; do printf 'hotspot: unchecked %s (the churn diff failed; not read as "no churn")\n' "$p"; done
if [ "${#SPLIT[@]}" -gt 0 ]; then
  printf 'split suggestion (test+SUT pairs kept together, <= %s lines per chunk):\n' "$BUDGET"
  for row in "${SPLIT[@]}"; do
    IFS=$'\t' read -r kind idx n x <<<"$row"
    [ "$kind" = C ] || continue
    printf '  chunk %s: %s lines%s\n' "$idx" "$n" "${x:+ ($x)}"
    for r2 in "${SPLIT[@]}"; do
      IFS=$'\t' read -r k2 i2 n2 p2 <<<"$r2"
      [ "$k2" = F ] && [ "$i2" = "$idx" ] || continue
      printf '    %6s  %s\n' "$n2" "$p2"
    done
  done
fi
printf 'size: %s\n' "$state"
exit "$exitcode"
