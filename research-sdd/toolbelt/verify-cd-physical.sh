#!/usr/bin/env bash
# verify-cd-physical.sh — lint guard: script-dir/kit-root derivations must resolve PHYSICALLY.
#
# WHY (kit issue #1024 round 4, SYSTEMIC): a `dirname "$0"`/`BASH_SOURCE`-based directory
# derivation that later CLIMBS with `..` (in the same `cd` argument, or via a variable that
# itself came from such a derivation) uses bash's default LOGICAL `cd`/`pwd`, which tracks $PWD
# as a lexically-collapsed STRING rather than a kernel-resolved physical path. When the script is
# invoked through a SYMLINKED directory (e.g. a per-profile render dir's toolbelt/, kit issue
# #993 WU2 + #1024 F1's completion symlinks), the symlink component is never "spent" for `..`
# purposes: a later `..` cancels it out lexically and lands one level off from where physical
# resolution would land. This exact defect has recurred repeatedly: reconcile-issues.sh,
# stage-retro-issues.sh, verify-doc-consistency.sh (kit issue #1024 round 3), then
# verify-skill-drift.sh, verify-registry.sh, research-sdd-init.sh, render-profile.sh (round 4).
# This checker exists to stop it recurring "one script at a time".
#
# WHAT IT RECOGNISES: a variable assignment shaped
#   [local|export|declare|readonly] VAR="$(cd [-P] "<expr>" [2>/dev/null] && pwd [-P])"
# is tracked as a "script-location-derived directory" (TAINTED) once <expr> contains a literal
# `dirname "$0"` / `dirname -- "$0"` / `dirname "${0}"` reference (or `BASH_SOURCE`), OR
# references an already-tainted variable BY NAME AT A WORD BOUNDARY (so a chain of two or more
# `cd`s — e.g. SELF_DIR from $0, then KIT_INSTALL from $SELF_DIR/../install, then KIT from
# $KIT_INSTALL/.. — stays tracked at every hop, and `$KIT` does NOT falsely match a tainted `K`
# — kit issue #1024 round 5, Opus finding 2, §7 precision). A tainted assignment whose <expr>
# ALSO contains `..` in THE SAME `cd` INVOCATION (a CLIMB — checked per `&&`-separated segment,
# not "does `-P` appear anywhere on the line": `cd .. && cd -P .` is a HIT because the FIRST,
# climbing `cd` has no `-P` of its own, even though a second, non-climbing `cd -P` sits later on
# the same line — round 5, Opus finding 2) is flagged unless THAT climbing `cd` itself carries
# `-P`: verified empirically (not merely asserted) that `cd -P` ALONE already makes bash track
# $PWD physically for the `pwd` call that follows in the same subshell — a following `pwd -P` is
# redundant and NOT required. Most fixed instances in this kit pair both anyway (one consistent,
# greppable idiom), but a bare `cd -P ... && pwd` (no `-P` on pwd) is equally correct and not
# flagged — e.g. kit issue #976/#984 (PR #1029)'s own fix to stage-retro.sh's KIT_REPO line,
# whose comment reaches the identical conclusion independently.
#
# WHAT IT EXCLUDES (declared per CLAUDE.md §7 "an audit instrument must prove the coverage of its
# own enumerator" — false negatives destroy trust the same way false positives do):
#   - A NON-climbing tainted assignment (lands exactly on the script's own directory, no `..`) is
#     harmless even without -P: a filesystem lookup through an unresolved symlink component still
#     resolves correctly as long as nothing later cancels it with `..`. Flagging it would be
#     file-wide noise with no exploitable defect — over 70 toolbelt scripts use exactly this
#     harmless `HERE="$(cd "$(dirname "$0")" && pwd)"` idiom with no further climb. It IS still
#     tracked as tainted, since a LATER line may climb using it.
#   - `cd "$(dirname "$X")"` where $X is anything OTHER than $0/BASH_SOURCE/a tainted var (e.g. a
#     retro file path, a target directory) resolves an UNRELATED directory and is out of scope.
#   - A `cd`/`pwd` pair that is not part of a `VAR="$(...)"` assignment (e.g. a plain `cd` used to
#     change directory for a subsequent relative command, never captured into a path variable) is
#     not a "derivation" and is out of scope.
#   - Multiple assignments on one physical line, separated by a TOP-LEVEL `;`, are each analysed as
#     their own logical statement (taint from an earlier `;`-separated statement on the SAME line
#     carries forward), matching e.g. scan-secrets.sh's `here=...; KIT="$(cd "$here/.." ...)"`. The
#     split is quote/substitution-aware (kit issue #1921, `_cdp_split`): a `;` inside `$( )`, a
#     backtick pair, `${ }`, single or double quotes is DATA, so `K="$(cd "$(dirname "$0")/.."; pwd)"`
#     is one statement whose climbing `cd` is checked. Within a statement, every command (split on
#     `;` `&&` `||` `|` at any `$( )` nesting level) is judged on its OWN text: a nested `$( )` body is
#     masked out of its parent, so an inner `cd -P` never vouches for an outer bare `cd ..`.
#   - A `#` at a word start (outside quotes/substitutions) begins a comment: the rest of the line is
#     dropped before pattern matching, `;` inside it included (so a comment mentioning "dirname",
#     ".." or `; K="$(cd ...)"` never triggers a false positive) — but the comment is READ SEPARATELY
#     for the allow-marker below.
#   - NOT RECOGNISED at all (real gaps, not silently miscounted — a future rewrite, not this
#     lint's job to close blindly): an UNQUOTED `$0` (e.g. `dirname $0`); a `$(...)` command
#     substitution split across MULTIPLE physical lines (this is a line-by-line scanner); the
#     legacy backtick form `` `cd ...` `` as the WHOLE capture instead of `$(...)` (a backtick pair
#     NESTED inside `$(...)` is parsed, kit issue #1921); `HERE=$(dirname "$0")` assigned
#     WITHOUT an accompanying `cd`/`pwd` on that same statement, then climbed from on a LATER
#     line (HERE is never added to the tainted set, since tainting requires a `cd ... && pwd`
#     shape on the assignment itself); `pushd`/`popd`-based directory tracking; and an
#     assignment that does not START its `;`-separated statement, i.e. one preceded by `&&`,
#     `||`, `then`, `do`, `else` or `!` on the same statement (`[ -d x ] && K="$(cd ...)"`,
#     kit issue #1033 L1) — a case-arm prefix (`a) K="$(cd ...)" ;;`) is the same class: the stray `)`
#     makes the line UNCLASSIFIABLE (reported, see below), the assignment is not analysed. A file using any of these forms to derive a climbing kit-root path
#     gets a silent pass from this checker — grep the file by hand if one is suspected.
#
# RECOGNISED since kit issue #1033 L1 (formerly gaps; NOT part of the list above): a one-line
#   function head `f(){ local K=...; }`, keyword flags such as `declare -r` / `local -r` /
#   `declare -rx`, and a TAB after `cd`.
#
# ALLOW-MARKER: a flagged line, or the line immediately before it, carrying a comment
#   # LINT-CD-PHYSICAL-OK: <reason>
# is reported as an explicit, named exception (ALLOWED) rather than a failure (HIT) — an empty or
# missing reason after the marker does not count and the line still fails as a HIT.
#
# DEFAULT SCOPE prunes only the `*.test.sh` suites under tests/ (kit issue #1024 round 5, Opus
# finding 1; narrowed from the whole tests/ directory by kit issue #1033 L2): a suite's own
# mutation-tooth fixtures routinely hold the UNMARKED bad pattern as literal text inside a heredoc
# or a quoted string (proving detection, or reconstructing a "neutered" mutant) — the scanner is
# quote- and substitution-aware WITHIN a line (kit issue #1921) but not heredoc-aware, so heredoc
# body text still reads as source code to it. Test INFRASTRUCTURE (tests/run-all.sh, tests/lib/*.sh,
# tests/fixtures/**/*.sh) is NOT pruned: it derives real kit paths (run-all.sh's KIT_TREE=) and is
# linted like any other script. Passing an explicit tests/ directory (or any path) as an argument
# still scans it in full, `*.test.sh` included — this is a DEFAULT-SCOPE decision, not a capability limit.
# Fixture authors: build a deliberately bad cd fixture in $TMP at test time (as this suite does), or
# mark it `# LINT-CD-PHYSICAL-OK: <reason>` — a bad non-*.test.sh file under tests/fixtures/ now HITs.
#
# UNCLASSIFIABLE (kit issue #1921 review): a physical line holding `cd` and `pwd` whose quote /
# substitution context is still open at end of line, or that holds a `)` closing nothing (an
# apostrophe in heredoc text, `$'a\'b'`, `${x//(/y}`, a case-arm pattern, a multi-line `$( )`), is
# reported on stderr as `UNCLASSIFIABLE file:line` and counted as `unclassifiable=N` in the summary
# line. Report-only: the exit code is unchanged and the line's statements are still analysed
# best-effort. A nonzero count is a list to read by hand, never a proof the lines are clean.
#
# Anti-silent-zero (CLAUDE.md §7): absent-input (no scan directory found), empty-input (directory
# found, no *.sh files under it), no-match (files scanned, pattern never seen at all) are printed
# as distinct, named states on stderr — never a bare, unproven "0 findings".
#
# Usage: verify-cd-physical.sh [<dir> ...]
#   No args: scans this kit's own toolbelt/ and install/ (resolved from THIS script's own
#            physically-resolved location — see the -P this checker requires of everyone else),
#            EXCLUDING `*.test.sh` suites under tests/ (see DEFAULT SCOPE above).
# Exit: 0 clean (zero HITs; ALLOWED entries do not fail the run)
#       1 one or more un-allow-marked HITs
#       2 operational failure (no scan directory found, or no *.sh files under any given directory)
#
# READ-ONLY: never modifies any file.

set -uo pipefail

# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
_RSDD_SELF="$(cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
_SELF_DIR="$_RSDD_SELF"

_default_scope=0
if [ "$#" -gt 0 ]; then
  dirs=("$@")
else
  _default_scope=1
  _kit_root="$(cd -P "$_SELF_DIR/.." && pwd -P)"
  dirs=("$_kit_root/toolbelt" "$_kit_root/install")
fi

any_dir_found=0
for d in "${dirs[@]}"; do
  [ -d "$d" ] && any_dir_found=1
done
if [ "$any_dir_found" -eq 0 ]; then
  printf 'verify-cd-physical: absent-input: no scan directory found among: %s\n' "${dirs[*]}" >&2
  exit 2
fi

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    if [ "$_default_scope" -eq 1 ]; then
      # DEFAULT SCOPE prunes only `*.test.sh` files that live under a tests/ directory — see the header
      # comment (kit issue #1033 L2). One find invocation: a tests/-anchored path test, not a directory prune.
      find "$d" -type f -name '*.sh' -not \( -path '*/tests/*' -name '*.test.sh' \) -print 2>/dev/null
    else
      find "$d" -type f -name '*.sh' 2>/dev/null
    fi
  done | sort -u
)

if [ "${#files[@]}" -eq 0 ]; then
  printf 'verify-cd-physical: empty-input: no *.sh files found under: %s\n' "${dirs[*]}" >&2
  exit 2
fi

# _cdp_split <stmt|seg> <text> — quote/substitution-aware splitter (kit issue #1921). Fills the global
# array _CDP_PARTS. A character-level scan with a context stack: s = '...', d = "...", c = ${...},
# p = $(...) / (...) / a backtick pair (a nested CODE level). `;` and friends are separators only in
# CODE context, never inside quotes or ${...}.
#   stmt: split ONLY at a top-level `;` (stack empty), so `K="$(cd X; pwd)"` stays one statement.
#   seg:  split at `;` `&&` `||` `|` in any code level; each nested `$( )` body is its own level whose
#         commands are emitted separately, and the enclosing command sees it masked as `$(…)`, so an
#         outer `cd` is judged on its own text (an inner `cd -P` cannot vouch for it).
# A `#` at a word start in top-level code begins a comment: the rest of the text is DROPPED.
# Unbalanced input (a $( ) spanning lines) simply ends at the end of the text — this is a line scanner.
_CDP_PARTS=()   # masked command text (nested substitution bodies replaced by a placeholder)
_CDP_RAW=()     # the SAME commands, UNMASKED: nested bodies kept verbatim (parallel to _CDP_PARTS)
_CDP_OPEN=0     # 1 when the text ended with an open context or held a stray `)` (unclassifiable)
_CDP_B=(); _CDP_U=(); _CDP_L=0   # scan state: masked/raw buffer per code level, current level
# _cdp_put <masked> [<raw>] — append to the current level's masked buffer, and the raw text to every
# enclosing level's unmasked buffer.
_cdp_put() {
  local m="$1" r="${2-$1}" k
  _CDP_B[_CDP_L]+="$m"
  for ((k = 0; k <= _CDP_L; k++)); do _CDP_U[k]+="$r"; done
}
_cdp_emit() { _CDP_PARTS+=("${_CDP_B[_CDP_L]}"); _CDP_RAW+=("${_CDP_U[_CDP_L]}"); }
# _cdp_sep <text> — a separator at the current level: emit the command, keep the separator text in the
# enclosing levels' raw buffers.
_cdp_sep() {
  local k
  _cdp_emit; _CDP_B[_CDP_L]=""; _CDP_U[_CDP_L]=""
  for ((k = 0; k < _CDP_L; k++)); do _CDP_U[k]+="$1"; done
}
_cdp_open() { # <masked placeholder> <raw opener>
  _cdp_put "$1" "$2"
  _CDP_L=$((_CDP_L + 1)); _CDP_B[_CDP_L]=""; _CDP_U[_CDP_L]=""
}
_cdp_close() { # <raw closer>
  local k
  _cdp_emit; unset '_CDP_B[_CDP_L]' '_CDP_U[_CDP_L]'; _CDP_L=$((_CDP_L - 1))
  for ((k = 0; k <= _CDP_L; k++)); do _CDP_U[k]+="$1"; done
}
_cdp_split() {
  local mode="$1" s="$2"
  _CDP_PARTS=(); _CDP_RAW=(); _CDP_OPEN=0; _CDP_B=(""); _CDP_U=(""); _CDP_L=0
  local stack="" i=0 n=${#s} c nx top prev=" "
  while (( i < n )); do
    c="${s:i:1}"; nx="${s:i+1:1}"; top="${stack: -1}"
    if [ "$top" = s ]; then
      _cdp_put "$c"; [ "$c" = "'" ] && stack="${stack%?}"
      prev="$c"; i=$((i + 1)); continue
    fi
    if [ "$c" = '\' ]; then
      _cdp_put "$c$nx"; prev="$nx"; i=$((i + 2)); continue
    fi
    if [ "$c" = '"' ]; then
      if [ "$top" = d ]; then stack="${stack%?}"; else stack+=d; fi
      _cdp_put "$c"; prev="$c"; i=$((i + 1)); continue
    fi
    if [ "$c" = "'" ] && [ "$top" != d ]; then
      stack+=s; _cdp_put "$c"; prev="$c"; i=$((i + 1)); continue
    fi
    if [ "$c" = '$' ] && [ "$nx" = '(' ]; then
      stack+=p; i=$((i + 2)); prev="("
      if [ "$mode" = seg ]; then _cdp_open '$(…)' '$('; else _cdp_put '$('; fi
      continue
    fi
    if [ "$c" = '$' ] && [ "$nx" = '{' ]; then
      stack+=c; _cdp_put '${'; prev="{"; i=$((i + 2)); continue
    fi
    if [ "$c" = '`' ]; then
      if [ "$top" = b ]; then
        stack="${stack%?}"
        if [ "$mode" = seg ]; then _cdp_close '`'; else _cdp_put "$c"; fi
      else
        stack+=b
        if [ "$mode" = seg ]; then _cdp_open '`…`' '`'; else _cdp_put "$c"; fi
      fi
      prev="$c"; i=$((i + 1)); continue
    fi
    if [ "$top" = d ]; then _cdp_put "$c"; prev="$c"; i=$((i + 1)); continue; fi
    # ── CODE context (stack empty, or top is p / b / c) ──
    if [ "$c" = '(' ]; then
      stack+=p
      if [ "$mode" = seg ]; then _cdp_open '(…)' '('; else _cdp_put "$c"; fi
      prev="$c"; i=$((i + 1)); continue
    fi
    if [ "$c" = ')' ] && [ "$top" = p ]; then
      stack="${stack%?}"
      if [ "$mode" = seg ]; then _cdp_close ')'; else _cdp_put "$c"; fi
      prev="$c"; i=$((i + 1)); continue
    fi
    # A `)` that closes nothing (case-arm pattern, `$(case … a) …;; esac)`): the scan can no longer
    # trust its own context stack for this line — typed unclassifiable, never a silent pass.
    [ "$c" = ')' ] && _CDP_OPEN=1
    if [ "$c" = '}' ] && [ "$top" = c ]; then
      stack="${stack%?}"; _cdp_put "$c"; prev="$c"; i=$((i + 1)); continue
    fi
    if [ "$c" = '#' ] && [ -z "$stack" ] && [[ "$prev" == [[:space:]\;] ]]; then
      break  # comment: drop the rest
    fi
    if [ "$top" != c ]; then
      if [ "$mode" = stmt ]; then
        if [ "$c" = ';' ] && [ -z "$stack" ]; then
          _cdp_sep ";"; prev="$c"; i=$((i + 1)); continue
        fi
      elif [ "$c" = ';' ]; then
        _cdp_sep ";"; prev="$c"; i=$((i + 1)); continue
      elif [ "$c" = '&' ] && [ "$nx" = '&' ]; then
        _cdp_sep "&&"; prev="&"; i=$((i + 2)); continue
      elif [ "$c" = '|' ]; then
        if [ "$nx" = '|' ]; then _cdp_sep "||"; i=$((i + 1)); else _cdp_sep "|"; fi
        prev="|"; i=$((i + 1)); continue
      fi
    fi
    _cdp_put "$c"; prev="$c"; i=$((i + 1))
  done
  # An open context at end of text (apostrophe in a heredoc/multi-line string, `$'a\'b'`,
  # `${x//(/y}`, a $( ) spanning lines) is typed, not silently dropped.
  [ -n "$stack" ] && _CDP_OPEN=1
  # Flush every still-open level, innermost first.
  while (( _CDP_L >= 0 )); do
    _cdp_emit; unset '_CDP_B[_CDP_L]' '_CDP_U[_CDP_L]'; _CDP_L=$((_CDP_L - 1))
  done
  _CDP_L=0
}

# _lint_scan_file <file> — prints one "lineno<TAB>reason" line per CLIMBING, non-`-P` tainted
# derivation found in <file>. Pure-bash taint tracking (no gawk-specific capture-group reliance,
# to stay portable across the coreutils this kit already depends on).
_lint_scan_file() {
  local f="$1"
  local -A tainted=()
  local lineno=0 line stmt code var is_rooted tv seg boundary_re

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Fast pre-filter with zero subprocess spawn: only lines that could possibly hold a
    # `cd ... && pwd` capture pay for the (rare) ';'-split below. This matters — the loop below
    # runs once per physical line of every scanned file.
    [[ "$line" == *cd* && "$line" == *pwd* ]] || continue

    # Each ';'-separated segment of the physical line is its own logical statement; taint from an
    # earlier segment on the SAME line is visible to a later one (scan-secrets.sh-style chaining).
    # The split never glob-expands the line (kit issue #1024 round 5, RDD R4-unquoted-split-globs): the
    # parts are assigned from a QUOTED array expansion, never from an unquoted `($line)`.
    # Kit issue #1921: the split is quote/substitution-aware (_cdp_split), NOT a bare `;` split, so a
    # `;` inside `$( )`, backticks or quotes (`K="$(cd X/..; pwd)"`) no longer cuts the statement
    # before the cd/pwd derivation is seen. It also drops a `#` comment (and any `;` inside it).
    _cdp_split stmt "$line"
    local -a _stmts=("${_CDP_PARTS[@]}")
    # Typed state (CLAUDE.md §7): the line ended with an open context or held a stray `)` — the scan
    # could not classify it reliably. Report-only; the statements are still analysed best-effort.
    [ "$_CDP_OPEN" -eq 1 ] && printf '%d\tunclassifiable\n' "$lineno"

    for stmt in "${_stmts[@]}"; do
      code="$stmt"  # _cdp_split already dropped any trailing comment
      [[ "$code" == *cd* && "$code" == *pwd* ]] || continue
      # Recognises an optional local/export/declare/readonly prefix before the variable name
      # (kit issue #1024 round 5, Opus finding 2 "cheap shapes") — e.g.
      # `local KIT="$(cd "$(dirname "$0")/.." && pwd)"` was previously invisible to this regex.
      # Also recognised (kit issue #1033 L1): an optional one-line function head `f(){ ` before the
      # assignment, and keyword flags (`declare -r`, `local -r`, `declare -rx`). Groups: [6] = VAR.
      [[ "$code" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)[[:space:]]*)?(\{[[:space:]]*)?((local|export|declare|readonly)([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
      var="${BASH_REMATCH[6]}"
      # Confirm this really is a `cd ... && pwd` capture (not e.g. an unrelated `cd`/`pwd` pair
      # elsewhere in a longer statement) — a `cd` must appear before the assignment's `pwd`.
      # `[[:space:]]` (not a literal space) so a TAB after `cd` is recognised (kit issue #1033 L1).
      [[ "$code" =~ cd[[:space:]] || "$code" == *'cd"'* || "$code" == *'cd-P'* ]] || continue

      is_rooted=0
      # dirname "$0" / dirname -- "$0" / dirname "${0}" (kit issue #1024 round 5, Opus finding 2
      # "cheap shapes" — `dirname -- "$0"` and the braced `"${0}"` form were previously invisible).
      if [[ "$code" == *'dirname "$0"'* || "$code" == *'dirname -- "$0"'* \
            || "$code" == *'dirname "${0}"'* || "$code" == *'dirname -- "${0}"'* \
            || "$code" == *'BASH_SOURCE'* ]]; then   # lib-resolution-ok: pattern literals the scanner matches, not a resolution (kit #1675)
        is_rooted=1
      else
        for tv in "${!tainted[@]}"; do
          # Word-boundary match (kit issue #1024 round 5, Opus finding 2, §7 precision): a plain
          # substring check would let `$KX` count as a reference to a tainted `K`. Require the
          # character immediately after the variable name to be absent or not a valid identifier
          # character (so `$KIT_INSTALL` never falsely matches a tainted `KIT`).
          boundary_re='\$\{?'"$tv"'([^A-Za-z0-9_]|$)'
          if [[ "$code" =~ $boundary_re ]]; then
            is_rooted=1
            break
          fi
        done
      fi
      [ "$is_rooted" -eq 1 ] || continue

      # Per-`&&`-segment climb + -P check (kit issue #1024 round 5, Opus finding 2, §7 precision):
      # "does `-P` appear ANYWHERE on the line" let `cd .. && cd -P .` slip through as a false
      # negative — the SECOND, non-climbing `cd` supplied the `-P` that "covered" the FIRST,
      # climbing `cd`, which has none of its own. Split on the fixed `&&` delimiter via pattern
      # substitution (no word-splitting, no glob risk) and require `-P` on the SAME segment that
      # contains the climbing `cd`. A COMPLIANT climb (has its own `-P`) still emits a line, tagged
      # "ok" — the caller needs to know a rooted, climbing derivation was SEEN at all (even when
      # every instance is correctly fixed), never only "seen when it was a violation": the latter
      # is exactly the `pattern_seen`/no-match confusion this checker corrected in round 5 (a fully
      # -P'd codebase must never be reported as "no climbing construct found").
      # EVERY climbing segment is checked (kit issue #1033 follow-up: stopping at the first one let a
      # later bare `cd ..` after a compliant `cd -P ..` escape). One line is emitted per statement: the
      # first non-compliant climb wins ("climbing derivation lacks cd -P"); otherwise "ok" if at
      # least one climb was seen and all were compliant.
      local _climb_ok=0 _climb_bad=0
      # Commands come from _cdp_split seg: split on `;`, `&&`, `||` and `|` in every code level (`cd -P ..
      # || cd ..` runs the bare climb whenever the -P'd one fails — kit issue #1033 review), with each
      # nested `$( )` body judged as its own command and masked out of its parent (kit issue #1921), so a
      # `;` inside `$( )` neither hides a climb nor lets an inner `cd -P` vouch for an outer bare `cd ..`.
      # The `..` test reads the UNMASKED text (a `..` that reaches `cd` through a nested substitution,
      # `cd "$(echo "$(dirname "$0")/..")"`, is still this cd's climb); the cd/-P tests read the command's
      # own MASKED text, so an inner `cd -P` cannot vouch for it.
      _cdp_split seg "$code"
      local _si
      for _si in "${!_CDP_PARTS[@]}"; do
        seg="${_CDP_PARTS[$_si]}"
        [[ "${_CDP_RAW[$_si]}" == *".."* ]] || continue
        [[ "$seg" =~ cd[[:space:]] || "$seg" == *'cd"'* || "$seg" == *'cd-P'* ]] || continue
        if [[ "$seg" =~ cd[[:space:]]+-P([[:space:]]|\") ]]; then
          _climb_ok=1
        else
          _climb_bad=1
          break
        fi
      done
      if [ "$_climb_bad" -eq 1 ]; then
        printf '%d\tclimbing derivation lacks cd -P\n' "$lineno"
      elif [ "$_climb_ok" -eq 1 ]; then
        printf '%d\tok\n' "$lineno"
      fi

      tainted["$var"]=1
    done
  done < "$f"
}

hit_count=0
allowed_count=0
scanned=0
# climb_seen (kit issue #1024 round 5, general cleanup — was misleadingly named `pattern_seen`
# while only ever being set on a VIOLATION or an ALLOWED exception, never on a compliant `-P`'d
# climb): true once ANY rooted, climbing derivation is observed, whether it passes or fails. A
# codebase where every such derivation is correctly fixed must still report climb_seen=1 — the
# no-match state below means "this pattern genuinely never occurs here", not "every occurrence
# happened to be fixed".
climb_seen=0
# unclassifiable_count: physical lines (holding `cd` and `pwd`) whose quote/substitution context did not
# balance — an apostrophe inside a heredoc, `$'a\'b'`, `${x//(/y}`, a case-arm `)`, a $( ) spanning
# lines. Report-only (exit code unchanged); a nonzero count is a list to read by hand, not a pass.
unclassifiable_count=0

for f in "${files[@]}"; do
  scanned=$((scanned + 1))
  while IFS=$'\t' read -r lineno reason; do
    [ -z "${lineno:-}" ] && continue
    if [ "$reason" = "unclassifiable" ]; then
      unclassifiable_count=$((unclassifiable_count + 1))
      printf 'UNCLASSIFIABLE %s:%s  quote/substitution context did not balance (heredoc text, $'"'"'..'"'"', case-arm, multi-line $( )) — read this line by hand\n' "$f" "$lineno" >&2
      continue
    fi
    climb_seen=1
    [ "$reason" = "ok" ] && continue  # compliant climb — counted above, not a HIT/ALLOWED
    line_text="$(sed -n "${lineno}p" "$f")"
    prev_text=""
    [ "$lineno" -gt 1 ] && prev_text="$(sed -n "$((lineno - 1))p" "$f")"
    marker_text="$(printf '%s\n%s' "$prev_text" "$line_text" | grep -oE '# *LINT-CD-PHYSICAL-OK:.*' | tail -1)"
    marker_reason="$(printf '%s' "$marker_text" | sed -E 's/^# *LINT-CD-PHYSICAL-OK: *//')"
    if [ -n "$marker_text" ] && [ -n "$marker_reason" ]; then
      allowed_count=$((allowed_count + 1))
      printf 'ALLOWED  %s:%s  %s  — reason: %s\n' "$f" "$lineno" "$reason" "$marker_reason"
    else
      hit_count=$((hit_count + 1))
      printf 'HIT      %s:%s  %s  (add "# LINT-CD-PHYSICAL-OK: <reason>" on this line or the one before it if intentional)\n' \
        "$f" "$lineno" "$reason" >&2
    fi
  done < <(_lint_scan_file "$f")
done

printf 'verify-cd-physical: scanned=%d files hit=%d allowed=%d unclassifiable=%d\n' "$scanned" "$hit_count" "$allowed_count" "$unclassifiable_count"
if [ "$climb_seen" -eq 0 ]; then
  # no-match (CLAUDE.md §7): files were genuinely scanned (files=() above proved that — see the
  # empty-input check) but the pattern this checker looks for was never seen in any of them —
  # not even as a correctly-fixed, compliant instance (see climb_seen's own comment above).
  printf 'verify-cd-physical: no-match: no climbing dirname($0)/BASH_SOURCE-derived cd/pwd construct found under: %s\n' "${dirs[*]}" >&2
fi

[ "$hit_count" -eq 0 ] || exit 1
exit 0
