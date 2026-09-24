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
#   - Multiple assignments on one physical line, separated by `;`, are each analysed as their own
#     logical statement (taint from an earlier `;`-separated statement on the SAME line carries
#     forward), matching e.g. scan-secrets.sh's `here=...; KIT="$(cd "$here/.." ...)"`.
#   - Text after a `#` on a logical statement is stripped before pattern matching (so a comment
#     mentioning "dirname" or ".." never triggers a false positive) — but is READ SEPARATELY for
#     the allow-marker below.
#   - NOT RECOGNISED at all (real gaps, not silently miscounted — a future rewrite, not this
#     lint's job to close blindly): an UNQUOTED `$0` (e.g. `dirname $0`); a `$(...)` command
#     substitution split across MULTIPLE physical lines (this is a line-by-line scanner); the
#     legacy backtick form `` `cd ...` `` instead of `$(...)`; `HERE=$(dirname "$0")` assigned
#     WITHOUT an accompanying `cd`/`pwd` on that same statement, then climbed from on a LATER
#     line (HERE is never added to the tainted set, since tainting requires a `cd ... && pwd`
#     shape on the assignment itself); and `pushd`/`popd`-based directory tracking. A file using
#     any of these forms to derive a climbing kit-root path gets a silent pass from this checker
#     — grep the file by hand if one of these forms is suspected.
#
# ALLOW-MARKER: a flagged line, or the line immediately before it, carrying a comment
#   # LINT-CD-PHYSICAL-OK: <reason>
# is reported as an explicit, named exception (ALLOWED) rather than a failure (HIT) — an empty or
# missing reason after the marker does not count and the line still fails as a HIT.
#
# DEFAULT SCOPE excludes tests/ (kit issue #1024 round 5, Opus finding 1): a *.test.sh suite's own
# mutation-tooth fixtures routinely hold the UNMARKED bad pattern as literal text inside a heredoc
# or a quoted string (proving detection, or reconstructing a "neutered" mutant) — this checker has
# no string/heredoc-aware parser, so that literal text reads as source code to it. Excluding
# tests/ from the default (no-argument) scan keeps a bare `verify-cd-physical.sh` run clean on
# this kit's real, shipped scripts; passing an explicit tests/ directory (or any path) as an
# argument still scans it in full — this is a DEFAULT-SCOPE decision, not a capability limit.
#
# Anti-silent-zero (CLAUDE.md §7): absent-input (no scan directory found), empty-input (directory
# found, no *.sh files under it), no-match (files scanned, pattern never seen at all) are printed
# as distinct, named states on stderr — never a bare, unproven "0 findings".
#
# Usage: verify-cd-physical.sh [<dir> ...]
#   No args: scans this kit's own toolbelt/ and install/ (resolved from THIS script's own
#            physically-resolved location — see the -P this checker requires of everyone else),
#            EXCLUDING any tests/ subdirectory (see DEFAULT SCOPE above).
# Exit: 0 clean (zero HITs; ALLOWED entries do not fail the run)
#       1 one or more un-allow-marked HITs
#       2 operational failure (no scan directory found, or no *.sh files under any given directory)
#
# READ-ONLY: never modifies any file.

set -uo pipefail

_SELF_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"

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
      # DEFAULT SCOPE excludes tests/ — see the header comment. -path/-prune keeps this a single
      # find invocation rather than a separate filter pass.
      find "$d" -type d -name tests -prune -o -type f -name '*.sh' -print 2>/dev/null
    else
      find "$d" -type f -name '*.sh' 2>/dev/null
    fi
  done | sort -u
)

if [ "${#files[@]}" -eq 0 ]; then
  printf 'verify-cd-physical: empty-input: no *.sh files found under: %s\n' "${dirs[*]}" >&2
  exit 2
fi

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
    # `read -ra` word-splits on IFS WITHOUT pathname (glob) expansion — unlike an unquoted array
    # assignment (`_stmts=($line)`), which DOES glob-expand a literal `*`/`?`/`[...]` inside the
    # line — kit issue #1024 round 5, Opus finding 2 (RDD R4-unquoted-split-globs). A here-string
    # is used instead of a subshell/pipe to avoid a subprocess spawn per line.
    local -a _stmts=()
    local _oldIFS="$IFS"
    IFS=';'
    read -ra _stmts <<< "$line"
    IFS="$_oldIFS"

    for stmt in "${_stmts[@]}"; do
      code="${stmt%%#*}"  # strip a trailing comment before any pattern matching
      [[ "$code" == *cd* && "$code" == *pwd* ]] || continue
      # Recognises an optional local/export/declare/readonly prefix before the variable name
      # (kit issue #1024 round 5, Opus finding 2 "cheap shapes") — e.g.
      # `local KIT="$(cd "$(dirname "$0")/.." && pwd)"` was previously invisible to this regex.
      [[ "$code" =~ ^[[:space:]]*(local|export|declare|readonly)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
      var="${BASH_REMATCH[2]}"
      # Confirm this really is a `cd ... && pwd` capture (not e.g. an unrelated `cd`/`pwd` pair
      # elsewhere in a longer statement) — a `cd` must appear before the assignment's `pwd`.
      [[ "$code" == *"cd "* || "$code" == *'cd"'* || "$code" == *'cd-P'* ]] || continue

      is_rooted=0
      # dirname "$0" / dirname -- "$0" / dirname "${0}" (kit issue #1024 round 5, Opus finding 2
      # "cheap shapes" — `dirname -- "$0"` and the braced `"${0}"` form were previously invisible).
      if [[ "$code" == *'dirname "$0"'* || "$code" == *'dirname -- "$0"'* \
            || "$code" == *'dirname "${0}"'* || "$code" == *'dirname -- "${0}"'* \
            || "$code" == *'BASH_SOURCE'* ]]; then
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
      while IFS= read -r seg; do
        [[ "$seg" == *".."* ]] || continue
        [[ "$seg" =~ cd[[:space:]] || "$seg" == *'cd"'* || "$seg" == *'cd-P'* ]] || continue
        if [[ "$seg" =~ cd[[:space:]]+-P([[:space:]]|\") ]]; then
          printf '%d\tok\n' "$lineno"
        else
          printf '%d\tclimbing derivation lacks cd -P\n' "$lineno"
        fi
        break
      done <<< "${code//&&/$'\n'}"

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

for f in "${files[@]}"; do
  scanned=$((scanned + 1))
  while IFS=$'\t' read -r lineno reason; do
    [ -z "${lineno:-}" ] && continue
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

printf 'verify-cd-physical: scanned=%d files hit=%d allowed=%d\n' "$scanned" "$hit_count" "$allowed_count"
if [ "$climb_seen" -eq 0 ]; then
  # no-match (CLAUDE.md §7): files were genuinely scanned (files=() above proved that — see the
  # empty-input check) but the pattern this checker looks for was never seen in any of them —
  # not even as a correctly-fixed, compliant instance (see climb_seen's own comment above).
  printf 'verify-cd-physical: no-match: no climbing dirname($0)/BASH_SOURCE-derived cd/pwd construct found under: %s\n' "${dirs[*]}" >&2
fi

[ "$hit_count" -eq 0 ] || exit 1
exit 0
