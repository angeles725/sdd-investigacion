#!/usr/bin/env bash
# doctrine-absence.test.sh -- retired-phrase absence walk over LIVE doctrine (kit issue #1703).
#
# Root class: a wording fix lands in one doctrine file while others keep the contradicted text. This suite
# walks the live-doctrine scope (CLAUDE.md, research-sdd/*.md, research-sdd/templates, research-sdd/skills,
# research-sdd/profiles, research-sdd/toolbelt/*.md) against tests/retired-phrases.txt and fails on any hit.
#
# The walk is the SUT of this file and is also exposed as a mode, so the teeth can mutate a copy of it:
#   doctrine-absence.test.sh --walk ROOT LIST     print one line per finding, exit 0 clean · 1 hit · 2 degraded
# Walk output lines (stdout):
#   RETIRED <file>:<line> <phrase>      a retired phrase is present (fails the walk)
#   WAIVED <file>:<line> <phrase>       the same, exempted by the list entry's waive=<path> field
#   NOTE waiver-unused <phrase> <path>  a waiver that matched nothing (informational, never fails)
#   NOTE scope-absent <path>            a scope directory/file does not exist under ROOT (informational)
#   doctrine-absence: files-read=N phrases=M hits=H waived=W
#   DEGRADED <reason> ...               the walk could not look (list-absent, list-empty, list-invalid, no-files,
#                                       grep-error, grep-output-unparsable, cd-failed, scope-find-error,
#                                       root-absent): absent / empty / no-match / could-not-run stay distinct and a
#                                       walk that read 0 files is a failure, never a pass (CLAUDE.md section 7).
# Exit: 0 all held · 1 regression · 2 harness failure.
#
# Usage: doctrine-absence.test.sh [--prove-teeth]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/doctrine-absence.test.sh"
export SUT="$SELF"   # default original for mutant_tooth
LIST_DEFAULT="$HERE/retired-phrases.txt"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

# BEGIN-WALK
# walk ROOT LIST -- see header for the output contract.
walk() {
  local root="$1" list="$2" line n=0 ph rest reason waive bad=0
  local -a phrases=() waives=() files=()
  if [ ! -f "$list" ] || [ ! -r "$list" ]; then   # SENTINEL-LIST-ABSENT
    echo "DEGRADED list-absent: $list"; return 2
  fi
  if [ ! -d "$root" ]; then
    echo "DEGRADED root-absent: $root"; return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '' | '#'*) continue ;; esac
    ph="${line%%$'\t'*}"
    if [ "$ph" = "$line" ]; then echo "DEGRADED list-invalid: line $n has no TAB-separated reason"; bad=1; continue; fi
    rest="${line#*$'\t'}"
    reason="${rest%%$'\t'*}"
    waive=""
    if [ "$reason" != "$rest" ]; then waive="${rest#*$'\t'}"; fi
    if [ -z "$ph" ] || [ -z "$reason" ]; then echo "DEGRADED list-invalid: line $n has an empty phrase or reason"; bad=1; continue; fi
    if [ -n "$waive" ]; then
      case "$waive" in
        waive=?*) waive="${waive#waive=}" ;;
        *) echo "DEGRADED list-invalid: line $n has an unknown third field '$waive'"; bad=1; continue ;;
      esac
    fi
    phrases+=("$ph"); waives+=("$waive")
  done < "$list"
  [ "$bad" -eq 0 ] || return 2
  if [ "${#phrases[@]}" -eq 0 ]; then   # SENTINEL-LIST-EMPTY
    echo "DEGRADED list-empty: $list has no active phrase"; return 2
  fi

  local spec dir depth f ftmp frc
  ftmp="$(mktemp)" || { echo "DEGRADED scope-find-error: mktemp failed"; return 2; }
  if [ -f "$root/CLAUDE.md" ]; then files+=("CLAUDE.md"); else echo "NOTE scope-absent CLAUDE.md"; fi
  for spec in research-sdd:1 research-sdd/templates:99 research-sdd/skills:99 research-sdd/profiles:99 research-sdd/toolbelt:1; do
    dir="${spec%%:*}"; depth="${spec##*:}"
    if [ ! -d "$root/$dir" ]; then echo "NOTE scope-absent $dir"; continue; fi
    # find runs to a temp file (not inside a pipe) so its exit status is observed: an untraversable scope
    # directory is a typed DEGRADED, never a silently smaller files-read (kit issue #1718).
    find "$root/$dir" -maxdepth "$depth" -type f -name '*.md' -print0 >"$ftmp" 2>"$ftmp.err"; frc=$?   # SENTINEL-SCOPE
    if [ "$frc" -ne 0 ]; then   # SENTINEL-FIND-RC
      echo "DEGRADED scope-find-error: rc=$frc dir=$dir: $(head -n 1 "$ftmp.err")"
      rm -f "$ftmp" "$ftmp.err"; return 2
    fi
    while IFS= read -r -d '' f; do files+=("${f#"$root"/}"); done < <(sort -z <"$ftmp")
  done
  rm -f "$ftmp" "$ftmp.err"
  if [ "${#files[@]}" -eq 0 ]; then   # SENTINEL-NO-FILES
    echo "DEGRADED no-files: files-read=0 under $root"; return 2
  fi

  local i out rc hits=0 waived=0 hit hf rl used
  for i in "${!phrases[@]}"; do
    ph="${phrases[$i]}"; waive="${waives[$i]}"; used=0
    # -a: a binary-looking file is searched as text, so GNU grep prints file:line instead of a bare
    # "binary file matches" notice (no line number) that would parse as a garbage hit (kit issue #1718).
    # exit 125 marks a failed cd: it must not alias grep's rc 1 (no match).
    out="$(cd "$root" || exit 125; grep -aHnF -e "$ph" -- "${files[@]}" </dev/null)"; rc=$?   # SENTINEL-MATCH
    if [ "$rc" -eq 125 ]; then echo "DEGRADED cd-failed: $root"; return 2; fi   # SENTINEL-CD-FAILED
    if [ "$rc" -gt 1 ]; then echo "DEGRADED grep-error: rc=$rc phrase=$ph"; return 2; fi
    while [ "$rc" -eq 0 ] && IFS= read -r hit; do
      if ! [[ "$hit" =~ ^[^:]+:[0-9]+: ]]; then   # SENTINEL-PARSE
        echo "DEGRADED grep-output-unparsable: phrase=$ph line=$hit"; return 2
      fi
      hf="${hit%%:*}"; rl="${hit#*:}"; rl="${rl%%:*}"
      if [ -n "$waive" ] && [ "$hf" = "$waive" ]; then   # SENTINEL-WAIVE
        echo "WAIVED $hf:$rl $ph"; waived=$((waived + 1)); used=1
      else
        echo "RETIRED $hf:$rl $ph"; hits=$((hits + 1))
      fi
    done <<<"$out"
    if [ -n "$waive" ] && [ "$used" -eq 0 ]; then echo "NOTE waiver-unused $ph $waive"; fi
  done
  echo "doctrine-absence: files-read=${#files[@]} phrases=${#phrases[@]} hits=$hits waived=$waived"
  [ "$hits" -eq 0 ] || return 1   # SENTINEL-EXIT
  return 0
}
# END-WALK

if [ "${1:-}" = "--walk" ]; then
  [ "$#" -eq 3 ] || { echo "usage: $0 --walk ROOT LIST" >&2; exit 2; }
  walk "$2" "$3"; exit $?
fi

pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
for _fn in mutant_chain mutant_tooth mutant_cleanup_register; do
  declare -F "$_fn" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_fn" >&2; exit 2; }
done
WORK="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
mutant_cleanup_register "$WORK" || { echo "FATAL: cleanup registration refused" >&2; exit 2; }

echo "== doctrine-absence.test.sh =="

# ---------- fixture helpers
TAB=$'\t'
mkroot() { # mkroot NAME -> prints dir with the full scope skeleton (clean files)
  local r="$WORK/$1"
  mkdir -p "$r/research-sdd/templates/sub" "$r/research-sdd/skills/s1/deep" "$r/research-sdd/profiles" \
           "$r/research-sdd/toolbelt/nested" "$r/retros"
  printf 'clean\n' > "$r/CLAUDE.md"
  printf 'clean\n' > "$r/research-sdd/METHODOLOGY.md"
  printf 'clean\n' > "$r/research-sdd/templates/sub/t.md"
  printf 'clean\n' > "$r/research-sdd/skills/s1/deep/SKILL.md"
  printf 'clean\n' > "$r/research-sdd/profiles/p.md"
  printf 'clean\n' > "$r/research-sdd/toolbelt/tool.v1.md"
  printf '%s\n' "$r"
}
put() { printf '%s\n' "$2" >> "$1"; } # put FILE LINE
mklist() { printf '%b' "$2" > "$1"; }  # mklist FILE CONTENT-with-\t-and-\n escapes
runw() { bash "$SELF" --walk "$1" "$2" 2>&1; }

# ---------- 1. the live tree
out="$(runw "$REPO_ROOT" "$LIST_DEFAULT")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "live doctrine tree: no retired phrase (rc 0)"; else no "live doctrine tree: expected rc 0" "rc=$rc out=$out"; fi
nread="$(sed -n 's/^doctrine-absence: files-read=\([0-9]*\) .*/\1/p' <<<"$out")"
if [ "${nread:-0}" -gt 0 ]; then ok "live walk read files (files-read > 0)" "files-read=$nread"; else no "live walk read 0 files" "out=$out"; fi
nph="$(sed -n 's/^doctrine-absence: .* phrases=\([0-9]*\) .*/\1/p' <<<"$out")"
if [ "${nph:-0}" -gt 0 ]; then ok "live walk loaded phrases (phrases > 0)" "phrases=$nph"; else no "live walk loaded 0 phrases" "out=$out"; fi

# ---------- 2. clean fixture
R="$(mkroot clean)"; L="$WORK/list.txt"; mklist "$L" "# c\nfoo bar${TAB}reason\n"
out="$(runw "$R" "$L")"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'files-read=6 phrases=1 hits=0 waived=0' <<<"$out"; then
  ok "clean fixture: rc 0, files-read=6 (every scope location counted)"
else no "clean fixture" "rc=$rc out=$out"; fi

# ---------- 3. a hit in EVERY scope location is reported with file:line
R="$(mkroot hits)"
put "$R/CLAUDE.md" "x foo bar y"
put "$R/research-sdd/METHODOLOGY.md" "foo bar"
put "$R/research-sdd/templates/sub/t.md" "foo bar"
put "$R/research-sdd/skills/s1/deep/SKILL.md" "foo bar"
put "$R/research-sdd/profiles/p.md" "foo bar"
put "$R/research-sdd/toolbelt/tool.v1.md" "foo bar"
out="$(runw "$R" "$L")"; rc=$?
miss=""
for f in CLAUDE.md:2 research-sdd/METHODOLOGY.md:2 research-sdd/templates/sub/t.md:2 research-sdd/skills/s1/deep/SKILL.md:2 \
         research-sdd/profiles/p.md:2 research-sdd/toolbelt/tool.v1.md:2; do
  grep -qxF "RETIRED $f foo bar" <<<"$out" || miss="$miss $f"
done
if [ "$rc" -eq 1 ] && [ -z "$miss" ]; then ok "hit in every scope location: rc 1 + RETIRED file:line phrase"; else no "scope hits" "rc=$rc missing=$miss out=$out"; fi

# ---------- 4. out-of-scope files are NOT walked
R="$(mkroot oos)"
put "$R/retros/old.md" "foo bar"
printf 'foo bar\n' > "$R/research-sdd/toolbelt/nested/deep.md"
printf 'foo bar\n' > "$R/research-sdd/toolbelt/note.txt"
out="$(runw "$R" "$L")"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'hits=0' <<<"$out"; then ok "retros/, toolbelt/nested/, non-md are out of scope (rc 0)"; else no "out-of-scope walk" "rc=$rc out=$out"; fi

# ---------- 5. degraded states are typed and fail (absent / empty / invalid / no files)
out="$(runw "$R" "$WORK/nope.txt")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED list-absent' <<<"$out"; then ok "absent list: rc 2 DEGRADED list-absent"; else no "absent list" "rc=$rc out=$out"; fi
mklist "$WORK/empty.txt" "# only comments\n\n"
out="$(runw "$R" "$WORK/empty.txt")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED list-empty' <<<"$out"; then ok "comment-only list: rc 2 DEGRADED list-empty"; else no "empty list" "rc=$rc out=$out"; fi
mklist "$WORK/zero.txt" ""
out="$(runw "$R" "$WORK/zero.txt")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED list-empty' <<<"$out"; then ok "zero-byte list: rc 2 DEGRADED list-empty"; else no "zero-byte list" "rc=$rc out=$out"; fi
mklist "$WORK/inv1.txt" "foo bar\n"
out="$(runw "$R" "$WORK/inv1.txt")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED list-invalid: line 1' <<<"$out"; then ok "entry without reason: rc 2 DEGRADED list-invalid"; else no "invalid list (no reason)" "rc=$rc out=$out"; fi
mklist "$WORK/inv2.txt" "foo bar${TAB}why${TAB}bogus\n"
out="$(runw "$R" "$WORK/inv2.txt")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF "unknown third field" <<<"$out"; then ok "unknown third field: rc 2 DEGRADED list-invalid"; else no "invalid list (third field)" "rc=$rc out=$out"; fi
mkdir -p "$WORK/bare"
out="$(runw "$WORK/bare" "$L")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED no-files: files-read=0' <<<"$out"; then ok "root with no scope files: rc 2 DEGRADED no-files"; else no "no files" "rc=$rc out=$out"; fi
out="$(runw "$WORK/missing-root" "$L")"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED root-absent' <<<"$out"; then ok "absent root: rc 2 DEGRADED root-absent"; else no "absent root" "rc=$rc out=$out"; fi

# ---------- 6. list edges: first / middle / last entry, last line without trailing newline
R="$(mkroot edges)"
put "$R/research-sdd/profiles/p.md" "alpha one"
put "$R/research-sdd/METHODOLOGY.md" "mid two"
put "$R/CLAUDE.md" "omega three"
mklist "$WORK/edges.txt" "alpha one${TAB}r1\n# c\nmid two${TAB}r2\nomega three${TAB}r3"
out="$(runw "$R" "$WORK/edges.txt")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'RETIRED research-sdd/profiles/p.md:2 alpha one' <<<"$out" \
   && grep -qF 'RETIRED research-sdd/METHODOLOGY.md:2 mid two' <<<"$out" \
   && grep -qF 'RETIRED CLAUDE.md:2 omega three' <<<"$out" && grep -qF 'hits=3' <<<"$out"; then
  ok "first/middle/last list entry all enforced (last has no trailing newline)"
else no "list edges" "rc=$rc out=$out"; fi
mklist "$WORK/single.txt" "omega three${TAB}r"
out="$(runw "$R" "$WORK/single.txt")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'phrases=1 hits=1' <<<"$out"; then ok "single-entry list enforced"; else no "single entry" "rc=$rc out=$out"; fi

# ---------- 7. literal matching: multi-byte en dash, '+' and '.' are not regex
R="$(mkroot lit)"
put "$R/CLAUDE.md" "Read 1–3 files and 44 files and axb"
mklist "$WORK/lit.txt" "1–3 files${TAB}r\n4+ files${TAB}r\na.b${TAB}r\n"
out="$(runw "$R" "$WORK/lit.txt")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'RETIRED CLAUDE.md:2 1–3 files' <<<"$out" && ! grep -qF '4+ files' <<<"$out" \
   && ! grep -qF 'RETIRED CLAUDE.md:2 a.b' <<<"$out" && grep -qF 'hits=1' <<<"$out"; then
  ok "literal match: en dash hits; '4+ files' !~ '44 files'; 'a.b' !~ 'axb'"
else no "literal matching" "rc=$rc out=$out"; fi

# ---------- 8. waivers: scoped to the named file, visible, unused ones noted but never failing
R="$(mkroot waive)"
put "$R/CLAUDE.md" "foo bar"
mklist "$WORK/w1.txt" "foo bar${TAB}r${TAB}waive=CLAUDE.md\n"
out="$(runw "$R" "$WORK/w1.txt")"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'WAIVED CLAUDE.md:2 foo bar' <<<"$out" && grep -qF 'hits=0 waived=1' <<<"$out"; then
  ok "waived hit: rc 0 and printed as WAIVED"
else no "waived hit" "rc=$rc out=$out"; fi
put "$R/research-sdd/METHODOLOGY.md" "foo bar"
out="$(runw "$R" "$WORK/w1.txt")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'RETIRED research-sdd/METHODOLOGY.md:2 foo bar' <<<"$out"; then
  ok "waiver does not cover a different file (rc 1)"
else no "waiver scope" "rc=$rc out=$out"; fi
R2="$(mkroot waive2)"
out="$(runw "$R2" "$WORK/w1.txt")"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'NOTE waiver-unused foo bar CLAUDE.md' <<<"$out"; then
  ok "unused waiver: rc 0 + NOTE waiver-unused"
else no "unused waiver" "rc=$rc out=$out"; fi

# ---------- 9. the shipped list is well formed (every entry parses; walking an empty-hit root is clean)
out="$(runw "$WORK/waive2" "$LIST_DEFAULT")"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'hits=0' <<<"$out"; then ok "shipped list parses (clean fixture, rc 0)"; else no "shipped list parse" "rc=$rc out=$out"; fi

# ---------- 10. could-not-run states stay typed (kit issue #1718)
# 10a. untraversable scope directory -> DEGRADED scope-find-error (needs a non-root user: root ignores mode 000)
R="$(mkroot unread)"
mkdir -p "$R/research-sdd/templates/locked"; printf 'foo bar\n' > "$R/research-sdd/templates/locked/l.md"
chmod 000 "$R/research-sdd/templates/locked"
if [ "$(id -u)" -eq 0 ] || [ -r "$R/research-sdd/templates/locked" ]; then
  UNREAD_SKIP=1; printf '  SKIP  %-60s %s\n' "untraversable scope dir: DEGRADED scope-find-error" "running as root / mode 000 not enforced"
else
  UNREAD_SKIP=0
  out="$(runw "$R" "$L")"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED scope-find-error' <<<"$out" && ! grep -qF 'doctrine-absence: files-read' <<<"$out"; then
    ok "untraversable scope dir: rc 2 DEGRADED scope-find-error (no shrunken files-read)"
  else no "untraversable scope dir" "rc=$rc out=$out"; fi
fi
chmod 755 "$R/research-sdd/templates/locked"

# 10b. grep rc>1 -> DEGRADED grep-error (a grep shim exits 2, so this also runs as root)
FBE="$WORK/fakegrep-err"; mkdir -p "$FBE"; printf '#!/bin/sh\necho "grep: simulated failure" >&2\nexit 2\n' > "$FBE/grep"; chmod +x "$FBE/grep"
R="$(mkroot clean2)"
out="$(PATH="$FBE:$PATH" bash "$SELF" --walk "$R" "$L" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED grep-error: rc=2 phrase=foo bar' <<<"$out"; then ok "grep rc 2: rc 2 DEGRADED grep-error"; else no "grep-error" "rc=$rc out=$out"; fi

# 10c. grep exits 0 with output that is not file:line:text -> DEGRADED grep-output-unparsable, never a garbage hit
FBU="$WORK/fakegrep-unparsable"; mkdir -p "$FBU"; printf '#!/bin/sh\necho "Binary file x.md matches"\nexit 0\n' > "$FBU/grep"; chmod +x "$FBU/grep"
out="$(PATH="$FBU:$PATH" bash "$SELF" --walk "$R" "$L" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED grep-output-unparsable' <<<"$out" && ! grep -q '^RETIRED' <<<"$out"; then
  ok "unparsable grep output: rc 2 DEGRADED grep-output-unparsable (no RETIRED)"
else no "unparsable grep output" "rc=$rc out=$out"; fi

# 10d. a cd failure must not alias grep's no-match (rc 1): a BASH_ENV shim makes cd into R fail
printf 'cd() { if [ "${1:-}" = "%s" ]; then return 1; fi; builtin cd "$@"; }\n' "$R" > "$WORK/cdshim.sh"
out="$(BASH_ENV="$WORK/cdshim.sh" bash "$SELF" --walk "$R" "$L" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'DEGRADED cd-failed' <<<"$out" && ! grep -qF 'hits=0' <<<"$out"; then
  ok "cd failure: rc 2 DEGRADED cd-failed (not a clean no-match)"
else no "cd failure" "rc=$rc out=$out"; fi

# 10e. a binary-looking file (NUL byte) is searched as text and reported with file:line
R="$(mkroot binary)"; printf 'ab\0foo bar\n' > "$R/research-sdd/profiles/bin.md"
out="$(runw "$R" "$L")"; rc=$?
if [ "$rc" -eq 1 ] && grep -qxF 'RETIRED research-sdd/profiles/bin.md:1 foo bar' <<<"$out"; then
  ok "NUL-bearing .md: RETIRED file:line (binary match is not a garbage hit)"
else no "binary match" "rc=$rc out=$out"; fi

# ==========================================================================
# TEETH -- mutant verification (--prove-teeth only)
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  CRASH='integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError'
  M="$WORK/mut"; mkdir -p "$M"
  mk() { # mk NAME EXPR... -> mutant copy of the walk SUT; a refusal counts ONE failure
    local name="$1" msg; shift
    msg="$(mutant_chain "teeth: $name" "$SELF" "$M/$name.sh" "$@")" || { printf '%s\n' "$msg"; return 1; }
  }
  tt() { if mutant_tooth "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
  tooth() { # tooth NAME GOOD_RC BAD_RC SED_EXPR GOOD_HAS BAD_LACKS -- WALK-ARGS (original must show GOOD_HAS, mutant must not show BAD_LACKS)
    local name="$1" grc="$2" brc="$3" expr="$4" ghas="$5" blacks="$6"; shift 6
    if mk "$name" "$expr"; then
      tt "teeth-$name" "$grc" "$brc" "$M/$name.sh" --good-has "$ghas" --bad-lacks "$CRASH|$blacks" "$@"
    else fail=$((fail + 1)); fi
  }
  # Fixtures reused by the teeth: a hit root, a clean root, the two lists.
  TH="$WORK/hits"; TC="$WORK/clean"; TL="$WORK/list.txt"

  echo "-- teeth: hits must fail the walk --"
  tooth no-fail-on-hit 1 0 's/\[ "\$hits" -eq 0 \] || return 1   # SENTINEL-EXIT/true/' 'RETIRED CLAUDE.md:2 foo bar' 'NEVER-PRESENT-TOKEN' -- bash @SUT@ --walk "$TH" "$TL"

  echo "-- teeth: absent list must be typed --"
  tooth absent-list 2 2 '/SENTINEL-LIST-ABSENT/s/if .*; then/if false; then/' 'DEGRADED list-absent' 'DEGRADED list-absent' -- bash @SUT@ --walk "$TC" "$WORK/nope.txt"

  echo "-- teeth: empty list must be typed --"
  tooth empty-list 2 0 '/SENTINEL-LIST-EMPTY/s/-eq 0/-eq 99/' 'DEGRADED list-empty' 'DEGRADED list-empty' -- bash @SUT@ --walk "$TC" "$WORK/empty.txt"

  echo "-- teeth: zero files read must fail --"
  tooth no-files 2 0 '/SENTINEL-NO-FILES/s/-eq 0/-eq 99/' 'DEGRADED no-files' 'DEGRADED no-files' -- bash @SUT@ --walk "$WORK/bare" "$TL"

  echo "-- teeth: matching must stay literal --"
  tooth literal 1 1 '/SENTINEL-MATCH/s/grep -aHnF/grep -aHnE/' 'hits=1 ' 'hits=1 ' -- bash @SUT@ --walk "$WORK/lit" "$WORK/lit.txt"

  echo "-- teeth: a waiver must stay scoped to its file --"
  tooth waive-scope 1 0 '/SENTINEL-WAIVE/s/\[ "\$hf" = "\$waive" \]/true/' 'RETIRED research-sdd/METHODOLOGY.md:2 foo bar' 'RETIRED research-sdd/METHODOLOGY.md:2 foo bar' -- bash @SUT@ --walk "$WORK/waive" "$WORK/w1.txt"

  echo "-- teeth: toolbelt must stay in scope --"
  tooth scope-toolbelt 1 1 's|research-sdd/toolbelt:1||' 'RETIRED research-sdd/toolbelt/tool.v1.md:2 foo bar' 'RETIRED research-sdd/toolbelt/tool.v1.md:2 foo bar' -- bash @SUT@ --walk "$TH" "$TL"

  echo "-- teeth: could-not-run states (kit issue #1718) --"
  if [ "$UNREAD_SKIP" -eq 1 ]; then
    printf '  SKIP  %-60s %s\n' "teeth-find-rc" "running as root / mode 000 not enforced"
  else
    chmod 000 "$WORK/unread/research-sdd/templates/locked"
    tooth find-rc 2 0 '/SENTINEL-FIND-RC/s/-ne 0/-eq 99/' 'DEGRADED scope-find-error' 'DEGRADED scope-find-error' -- bash @SUT@ --walk "$WORK/unread" "$TL"
    chmod 755 "$WORK/unread/research-sdd/templates/locked"
  fi
  tooth cd-failed 2 0 '/SENTINEL-MATCH/s/cd "\$root" || exit 125;/cd "$root" \&\&/' 'DEGRADED cd-failed' 'DEGRADED cd-failed' -- env BASH_ENV="$WORK/cdshim.sh" bash @SUT@ --walk "$WORK/clean2" "$TL"
  tooth binary-text 1 2 '/SENTINEL-MATCH/s/grep -aHnF/grep -HnF/' 'RETIRED research-sdd/profiles/bin.md:1 foo bar' 'RETIRED research-sdd/profiles/bin.md:1 foo bar' -- bash @SUT@ --walk "$WORK/binary" "$TL"
  tooth parse-guard 2 1 '/SENTINEL-PARSE/s/! \[\[ "\$hit" =~ \^\[\^:\]+:\[0-9\]+: \]\]/false/' 'DEGRADED grep-output-unparsable' 'DEGRADED grep-output-unparsable' -- env PATH="$FBU:$PATH" bash @SUT@ --walk "$WORK/clean2" "$TL"
  tooth grep-error 2 0 '/DEGRADED grep-error/s/-gt 1/-gt 99/' 'DEGRADED grep-error' 'DEGRADED grep-error' -- env PATH="$FBE:$PATH" bash @SUT@ --walk "$WORK/clean2" "$TL"
fi

# ---------- footer
printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "FATAL: zero tests executed" >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
