#!/usr/bin/env bash
# pipefail-sigpipe-lint.test.sh — ONE shared lint that keeps the pipefail + early-exit-consumer idiom out of
# every shell file of the kit (kit issue #1444, batch D3; replaces the per-suite #1349 self-lints).
#
# The idiom: under `set -o pipefail`, `producer | grep -q PAT` (or any early-exiting consumer: `-m N`,
# `--quiet`, ...) fails with rc 141 whenever the consumer exits on its first match before the producer has
# finished writing (SIGPIPE) — a PASSING check reads as a failure, only under load. The fix is a
# here-string/redirect (`grep -q PAT <<<"$v"`), never a pipe.
#
# Modes
#   (default)                run the lint's own test cases (fixtures + mutation controls with
#                            --prove-teeth) and lint the REAL tree: this suite is the gate.
#   --scan FILE...           lint exactly FILE... and print the report
#   --scan-tree RESEARCH_DIR lint the declared corpora under RESEARCH_DIR and print the report
#   Exit (--scan, --scan-tree): 0 no violations · 1 violations · 2 operational failure (absent corpus,
#   empty corpus, zero files, unreadable file, no code lines seen) — a zero is never a silent pass (CLAUDE.md §7).
#
# What it recognises (anti-silent-zero: the forms are declared, see pfl_forms below).
# Exemptions are EXPLICIT: a trailing `# sigpipe-lint: allow <reason>` on the line (or on a comment-only line
# directly above it) marks a DELIBERATE reproduction of the idiom (mutant bodies, sed/heredoc text). A marker
# without a reason does not exempt. No path-based blanket exemption exists.
#
# The `| head` consumer family (kit issue #1145) is deliberately NOT linted — measured, not assumed (2026-10-07):
#   incidence  723 `| head` sites in 79 files, 65 sites in 20 production files (tests/ excluded). Enumerator, run from
#              research-sdd/: `grep -rnE '\| *head( |$)' --include='*.sh' toolbelt install` (then `| grep -v /tests/` for
#              production). Scope: *.sh under toolbelt/ and install/ only. It matches `|head` and `| head` at any
#              position on a physical line (including a continuation line that starts with `| head`); it does NOT see
#              `|& head`, `head` reached through a variable/xargs/eval, or scripts without a .sh extension.
#   mechanism  under pipefail a producer that writes more than the ~64 KB pipe buffer after `head` has exited gets
#              SIGPIPE and the pipeline rc becomes 141, but the captured VALUE is still correct: probe
#              `x="$(seq 1 300000 | head -1)"` under pipefail gave 200/200 rc=141 and 0/200 wrong values. So the
#              family can only hurt where the pipeline's RC is consumed (`||`, `if`, `set -e`, `$?`), unlike
#              `producer | grep -q`, where the rc IS the answer.
#   classes    (a) value captures and diagnostic `$(…)` failure messages — rc discarded (no errexit in 18 of the 20
#              production files); (b) `< <(… | head)` process substitutions — rc ignored by bash; (c) `|| true` /
#              `|| x=""` absorbers over tiny cache/grep producers (detect-tools, verify-retro); (d) the only two
#              production files with errexit (decompile-native.sh, scan-firmware.sh) read PIPESTATUS and accept 141
#              explicitly at all 3 of their `| head` sites (decompile-native.sh:26, :31 and scan-firmware.sh:24); (e) `sort | head -1` over `find` output (verify-sources,
#              scan-secrets, research-sdd-archive): sort may take the SIGPIPE, the rc is never read, the value is the
#              first line either way.
#   verdict    0 unguarded sites where a consumed rc sits behind a producer that can exceed 64 KB, so there is no
#              defect to gate. A lint on the bare shape would flag ~700 benign sites and force an allow marker on
#              each — noise that teaches operators to ignore the lint. Re-measure before adding a new rc-consuming
#              `| head`; if one appears, read PIPESTATUS (see scan-firmware.sh) or use a here-string/redirect.
#
# Exit (default mode): 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
# shellcheck disable=SC2034 # read by lib/mutant.sh (mutant_tooth) as the original each mutant is compared with
SUT="$SELF"
FIX="$HERE/fixtures/pipefail-sigpipe-lint"

pfl_forms() {
  cat <<'EOF'
forms recognised (consumer after an unquoted | or |&, optionally behind command/exec/builtin/env/nice/time/sudo
and/or a path prefix such as /usr/bin/): grep, egrep, fgrep, rg with ANY of
  -q  -qx  -iq  -Eq  -Eqi/  (a short-flag cluster containing q), a split -i -q, --quiet, --silent,
  -m N  -m1  -Em1  (a cluster containing m), --max-count N, --max-count=N
  in ANY argument position (before or after the pattern), in a quote-aware argument scan up to the next
  unquoted | ; & ) — `--` ends the flags
  a pipe at end of line with the consumer on the next code line (blank/comment lines between are skipped),
  and a backslash continuation (a trailing backslash before the pipe, or after it)
forms NOT recognised (known limits): a consumer behind xargs/sh -c/eval, a flag cluster glued to an -e/-f
  argument (-eqx is read as a cluster), a quoted multi-line string whose line looks like code (it is scanned
  as code — mark deliberate text with the allow marker), a consumer other than grep/egrep/fgrep/rg
comment-only lines are skipped; `||`, grep -c, grep -o and grep without a quiet/max-count flag do not match
EOF
}

PFL_AWK="$(cat <<'AWKEOF'
BEGIN { maxtok = 1000000  # SENTINEL-PFL-MAXTOK
        inb = 0; ncode = 0; prevmark = "" }

function markreason(s,   r) {
  if (match(s, /# sigpipe-lint: allow[ \t]+[^ \t]/)) {
    r = substr(s, RSTART)
    sub(/^# sigpipe-lint: allow[ \t]+/, "", r)
    return r
  }
  return ""
}

# 1 = quiet/max-count flag, 2 = end of flags (--), 0 = anything else
function flagkind(t,   cl) {
  if (t == "--") return 2
  if (t ~ /^--(quiet|silent|max-count)(=.*)?$/) return 1
  if (match(t, /^-[A-Za-z0-9]+/)) {
    cl = substr(t, 1, RLENGTH)
    if (cl ~ /[qm]/) return 1
  }
  return 0
}

# Scan one logical line for `| [wrapper] grep|egrep|fgrep|rg ... <quiet/max-count flag>`.
function check(text, startline, reason,   kind, i, n, pc, nc, rest, args, m, j, ch, tok, q, intok, fin, hit, k, exempt) {
  n = length(text)
  for (i = 1; i <= n; i++) {
    if (substr(text, i, 1) != "|") continue
    pc = (i > 1) ? substr(text, i - 1, 1) : ""
    nc = substr(text, i + 1, 1)
    if (pc == "|" || pc == "\\" || nc == "|") continue
    rest = substr(text, i + 1)
    sub(/^&/, "", rest)
    sub(/^[ \t]+/, "", rest)
    while (match(rest, /^(command|exec|builtin|nice|time|sudo|env)[ \t]+(-[A-Za-z-]+[ \t]+)*/)) rest = substr(rest, RLENGTH + 1)
    if (!match(rest, /^([^ \t|;&()]*\/)?(grep|egrep|fgrep|rg)([ \t]|$)/)) continue
    args = rest
    sub(/^([^ \t|;&()]*\/)?(grep|egrep|fgrep|rg)/, "", args)
    m = length(args); tok = ""; q = ""; intok = 0; fin = 0; hit = 0; k = 0
    for (j = 1; j <= m + 1; j++) {
      ch = (j <= m) ? substr(args, j, 1) : " "
      if (q == "" && (ch == "|" || ch == ";" || ch == "&" || ch == ")")) fin = 1
      if (fin || (q == "" && (ch == " " || ch == "\t"))) {
        if (intok) {
          k++
          kind = flagkind(tok)
          if (kind == 2) break
          if (kind == 1) { hit = 1; break }
          tok = ""; intok = 0
          if (k >= maxtok) break
        }
        if (fin) break
        continue
      }
      if (q == "" && ch == "\\") { tok = tok ch substr(args, j + 1, 1); j++; intok = 1; continue }
      if (q == "\"" && ch == "\\") { tok = tok ch substr(args, j + 1, 1); j++; continue }
      if (q == "" && (ch == "'" || ch == "\"")) { q = ch; tok = tok ch; intok = 1; continue }
      if (q != "" && ch == q) { q = ""; tok = tok ch; continue }
      tok = tok ch; intok = 1
    }
    if (hit) {
      exempt = (reason != "")  # SENTINEL-PFL-EXEMPT
      gsub(/[ \t]+/, " ", text)
      if (exempt) printf "E\t%s\t%d\t%s\n", bufname, startline, reason
      else printf "V\t%s\t%d\t%s\n", bufname, startline, substr(text, 1, 160)
      return
    }
  }
}

function finish() {
  inb = 0
  check(buf, bufstart, reason)
  buf = ""; reason = ""
}

FNR == 1 { if (inb) finish(); prevmark = "" }

{
  line = $0
  sub(/\r$/, "", line)
  r = markreason(line)
  if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) {
    prevmark = (line ~ /^[ \t]*#/) ? r : ""
    next
  }
  ncode++
  if (!inb) { inb = 1; bufstart = FNR; bufname = FILENAME; buf = ""; reason = prevmark }
  if (r != "") reason = r
  prevmark = ""
  t = line
  sub(/[ \t]+$/, "", t)
  if (t ~ /\\$/) { sub(/\\$/, "", t); buf = buf t " "; next }
  if (t ~ /[^|]\|$/ || t == "|") { buf = buf t " "; next }  # SENTINEL-PFL-MULTILINE
  buf = buf t
  finish()
}

END { if (inb) finish(); printf "S\t%d\n", ncode }
AWKEOF
)"

# pfl_main FILE... — lint exactly these files; prints the report; rc 0/1/2 (see header).
pfl_main() {
  [ "$#" -gt 0 ] || { echo "ERROR: no files to scan (zero files scanned is never a pass)" >&2; return 2; }  # SENTINEL-PFL-ZERO-FILES
  local f out arc ncode nv ne
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "ERROR: absent or unreadable input: $f" >&2; return 2; }
  done
  out="$(awk "$PFL_AWK" "$@" </dev/null)"; arc=$?
  [ "$arc" -eq 0 ] || { echo "ERROR: awk failed (exit $arc)" >&2; return 2; }
  ncode="$(awk -F'\t' '$1=="S" { print $2 }' <<<"$out")"
  [ "${ncode:-0}" -gt 0 ] || { echo "ERROR: scanned $# file(s) but saw no code lines — the lint could not look at anything" >&2; return 2; }  # SENTINEL-PFL-CODE-LINES
  nv="$(awk -F'\t' '$1=="V" { n++ } END { print n+0 }' <<<"$out")"
  ne="$(awk -F'\t' '$1=="E" { n++ } END { print n+0 }' <<<"$out")"
  echo "files scanned: $# (code lines: $ncode)"
  pfl_forms
  echo "violations: $nv"
  awk -F'\t' '$1=="V" { printf "  VIOLATION %s:%s: %s\n", $2, $3, $4 }' <<<"$out"
  echo "exempt sites: $ne"
  awk -F'\t' '$1=="E" { printf "  EXEMPT %s:%s: %s\n", $2, $3, $4 }' <<<"$out"
  [ "$nv" -eq 0 ]
}

# pfl_tree RESEARCH_DIR — declared corpora; an absent or empty corpus is rc 2, never a pass.
pfl_tree() {
  local root="$1" c d g f files=() n
  [ -d "$root" ] || { echo "ERROR: absent corpus root: $root" >&2; return 2; }
  # corpus declaration: <dir relative to the root>
  for c in toolbelt toolbelt/lib toolbelt/tests toolbelt/tests/lib install install/tests; do
    d="$root/$c"
    [ -d "$d" ] || { echo "ERROR: absent corpus directory: $c/ (expected $d)" >&2; return 2; }
    n=0
    for f in "$d"/*.sh; do
      [ -f "$f" ] || continue
      files+=("$f"); n=$((n+1))
    done
    [ "$n" -gt 0 ] || { echo "ERROR: empty corpus (no *.sh files): $c/" >&2; return 2; }
    echo "corpus $c/*.sh: $n file(s)"
  done
  g=0
  pfl_main "${files[@]}" | sed "s|$root/||"; g=${PIPESTATUS[0]}
  return "$g"
}

case "${1:-}" in
  --scan) shift; pfl_main "$@"; exit $? ;;
  --scan-tree) shift; pfl_tree "${1:-}"; exit $? ;;
esac

# ---------------------------------------------------------------------------------------------------------
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== pipefail-sigpipe-lint.test.sh =="

[ -f "$SELF" ] || { echo "FATAL: cannot locate $SELF" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: fixture dir missing: $FIX" >&2; exit 2; }

# scan_case LABEL EXPECT_RC EXPECT_VIOLATIONS EXPECT_EXEMPT EXPECT_VLINES FILE...
# EXPECT_VLINES: space-separated violation line numbers ("-" = do not assert). Runs the lint as a child
# process so a mutant copy of this suite can be dropped in for $SELF.
scan_case() {
  local label="$1" erc="$2" ev="$3" ee="$4" el="$5"; shift 5
  local out rc gv ge gl
  out="$(bash "$SELF" --scan "$@" 2>&1)"; rc=$?
  gv="$(sed -n 's/^violations: //p' <<<"$out")"
  ge="$(sed -n 's/^exempt sites: //p' <<<"$out")"
  gl="$(sed -n 's/^  VIOLATION [^:]*:\([0-9]*\):.*/\1/p' <<<"$out" | tr '\n' ' ')"; gl="${gl% }"
  if [ "$rc" != "$erc" ]; then no "$label: exit $rc, expected $erc — $(head -c 300 <<<"$out" | tr '\n' ' ')"
  elif [ "$gv" != "$ev" ] || [ "$ge" != "$ee" ]; then no "$label: violations='$gv' exempt='$ge', expected $ev / $ee"
  elif [ "$el" != "-" ] && [ "$gl" != "$el" ]; then no "$label: violation lines '$gl', expected '$el'"
  else ok "$label"; fi
}

scan_case "position first line of file: 1 violation" 1 1 0 "1" "$FIX/pos-first.txt"
scan_case "position middle line of file: 1 violation" 1 1 0 "2" "$FIX/pos-middle.txt"
scan_case "position last line, no trailing newline: 1 violation" 1 1 0 "2" "$FIX/pos-last.txt"
scan_case "single-line file, no trailing newline: 1 violation" 1 1 0 "1" "$FIX/pos-single.txt"
scan_case "every flag form in forms.txt is flagged (23 lines, each reported)" 1 23 0 "$(seq -s ' ' 1 23)" "$FIX/forms.txt"
scan_case "split flags (-i -q, -E -i -q, -F -m 1) are flagged" 1 3 0 "1 2 3" "$FIX/split.txt"
scan_case "multi-line pipe, comment between, backslash forms (5 sites at their first line)" 1 5 0 "1 3 6 8 10" "$FIX/multiline.txt"
# A buffer left open by the last line of a file (trailing backslash) must be reported under ITS file and line.
out="$(bash "$SELF" --scan "$FIX/multi-a.txt" "$FIX/multi-b.txt" 2>&1)"
if grep -q 'VIOLATION .*multi-a\.txt:2:' <<<"$out" && ! grep -q 'multi-b\.txt:[0-9]*: ' <<<"$out"; then ok "multi-file: dangling last line of A is reported under multi-a.txt:2 (A then B)"
else no "multi-file forward order misattributed: $(grep VIOLATION <<<"$out" | head -3)"; fi
out="$(bash "$SELF" --scan "$FIX/multi-b.txt" "$FIX/multi-a.txt" 2>&1)"
if grep -q 'VIOLATION .*multi-a\.txt:2:' <<<"$out" && ! grep -q 'multi-b\.txt:[0-9]*: ' <<<"$out"; then ok "multi-file: reverse order (B then A) still names multi-a.txt:2"
else no "multi-file reverse order misattributed: $(grep VIOLATION <<<"$out" | head -3)"; fi
scan_case "comment-only, ||, -c, -o, -v, plain grep, no-pipe, here-string, awk are NOT flagged" 0 0 0 "" "$FIX/nomatch.txt"
scan_case "exemptions: marker same line / line above / multi-line consumer exempt; no-reason, blank-separated and unmarked flagged" 1 3 3 "6 9 10" "$FIX/exempt.txt"

# --- anti-silent-zero: operational failures are rc 2, never a pass ------------------------------------
out="$(bash "$SELF" --scan 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no files to scan' <<<"$out"; then ok "zero files → exit 2 with a 'no files' message"
else no "zero files: exit $rc, output: $(head -c 200 <<<"$out")"; fi
out="$(bash "$SELF" --scan "$FIX/does-not-exist.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "absent input file → exit 2"; else no "absent input file: exit $rc"; fi
out="$(bash "$SELF" --scan "$FIX/empty.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no code lines' <<<"$out"; then ok "an empty file (nothing to look at) → exit 2, never a silent pass"
else no "empty file: exit $rc, output: $(head -c 200 <<<"$out")"; fi
out="$(bash "$SELF" --scan-tree "$FIX/no-such-root" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'absent corpus' <<<"$out"; then ok "absent corpus root → exit 2"
else no "absent corpus root: exit $rc, output: $(head -c 200 <<<"$out")"; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/toolbelt"
out="$(bash "$SELF" --scan-tree "$TMP/root" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'empty corpus' <<<"$out"; then ok "a corpus dir with no *.sh files → exit 2"
else no "empty corpus dir: exit $rc, output: $(head -c 200 <<<"$out")"; fi
out="$(bash "$SELF" --scan-tree "$HERE/../.." 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^violations: 0$' <<<"$out"; then ok "REAL TREE: 0 violations across the declared corpora"
else no "REAL TREE lint failed (exit $rc): $(grep -E 'ERROR|VIOLATION' <<<"$out" | head -20 | tr '\n' ';')"; fi
# Report shape (§7): corpus counts, files scanned, forms, violations and exempt sites must all be printed.
for pat in '^corpus toolbelt/\*\.sh: [1-9]' '^corpus install/tests/\*\.sh: [1-9]' '^files scanned: [1-9]' '^forms recognised' '^forms NOT recognised' '^exempt sites: [0-9]'; do
  if grep -qE -- "$pat" <<<"$out"; then ok "report prints: $pat"; else no "report is missing: $pat"; fi
done
printf '%s\n' "$out" | sed -n '/^corpus /p;/^files scanned/p;/^violations:/p;/^exempt sites:/,$p'

# ---- Teeth (mutation proof) -------------------------------------------------
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth || exit 2
mk_sed() {
  local out="$2"
  mkdir -p "$(dirname "$out")"
  mutant_chain "$1" "$SELF" "$out" "${@:3}" || { fail=$((fail+1)); return 1; }
}
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  M='pipefail-sigpipe-lint.test.sh'
  echo "-- teeth: each detector facet must be load-bearing --"

  # Tooth 1: only the first argument token is inspected → a split flag (-i -q) is missed.
  mk_sed "teeth split-flag" "$MUT/split/$M" 's/^BEGIN { maxtok = 1000000  # SENTINEL-PFL-MAXTOK/BEGIN { maxtok = 1  # SENTINEL-PFL-MAXTOK/' \
    && tooth "teeth split-flag: only the first token inspected → split flags missed" 1 0 "$MUT/split/$M" \
         --good-has 'violations: 3' --bad-has 'violations: 0' -- bash @SUT@ --scan "$FIX/split.txt"

  # Tooth 2: the allow marker is ignored → deliberate reproductions are reported as violations.
  mk_sed "teeth marker" "$MUT/marker/$M" 's/^      exempt = (reason != "")  # SENTINEL-PFL-EXEMPT/      exempt = 0  # SENTINEL-PFL-EXEMPT/' \
    && tooth "teeth marker: allow marker ignored → exempt sites become violations" 1 1 "$MUT/marker/$M" \
         --good-has 'exempt sites: 3' --bad-has 'exempt sites: 0' --bad-lacks 'exempt sites: 3' -- bash @SUT@ --scan "$FIX/exempt.txt"

  # Tooth 3: the zero-files guard removed → an empty file list no longer reports its own emptiness.
  mk_sed "teeth zero-files" "$MUT/zero/$M" '/^  \[ "\$#" -gt 0 \] || .*# SENTINEL-PFL-ZERO-FILES$/ s/.*/  :/' \
    && tooth "teeth zero-files: guard removed → the 'no files' message is gone" 2 2 "$MUT/zero/$M" \
         --good-has 'no files to scan' --bad-lacks 'no files to scan' --bad-has 'no code lines' -- bash @SUT@ --scan

  # Tooth 4: the no-code-lines guard removed → an empty file reads as a clean pass.
  mk_sed "teeth code-lines" "$MUT/code/$M" '/^  \[ "\${ncode:-0}" -gt 0 \] || .*# SENTINEL-PFL-CODE-LINES$/ s/.*/  :/' \
    && tooth "teeth code-lines: guard removed → an empty file passes silently" 2 0 "$MUT/code/$M" \
         --good-has 'no code lines' --bad-has 'violations: 0' -- bash @SUT@ --scan "$FIX/empty.txt"

  # Tooth 5: multi-line detection dropped → a pipe at end of line is no longer joined to its consumer.
  mk_sed "teeth multiline" "$MUT/multi/$M" '/^  if (t ~ .*# SENTINEL-PFL-MULTILINE$/ s/if ([^{]*) {/if (0) {/' \
    && tooth "teeth multiline: end-of-line pipe not joined → multi-line sites missed" 1 1 "$MUT/multi/$M" \
         --good-has 'violations: 5' --bad-lacks 'violations: 5' --bad-has 'violations: [0-4]' -- bash @SUT@ --scan "$FIX/multiline.txt"

  # Tooth 6: report under FILENAME instead of the name stored when the buffer opened → a dangling last line
  # of file A is attributed to file B.
  mk_sed "teeth bufname" "$MUT/bufname/$M" '/^      else printf "V/ s/bufname/FILENAME/' \
    && tooth "teeth bufname: FILENAME at flush time → violation of A reported under B" 1 1 "$MUT/bufname/$M" \
         --good-has 'multi-a\.txt:2:' --bad-lacks 'multi-a\.txt:2:' -- bash @SUT@ --scan "$FIX/multi-a.txt" "$FIX/multi-b.txt"

  rm -rf "$MUT"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
