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
#   VAR="$(cd [-P] "<expr>" [2>/dev/null] && pwd [-P])"
# is tracked as a "script-location-derived directory" (TAINTED) once <expr> contains the literal
# `dirname "$0"` or `BASH_SOURCE`, OR references an already-tainted variable by name (so a chain
# of two or more `cd`s — e.g. SELF_DIR from $0, then KIT_INSTALL from $SELF_DIR/../install, then
# KIT from $KIT_INSTALL/.. — stays tracked at every hop). A tainted assignment whose <expr> ALSO
# contains `..` (a CLIMB — in the same cd, or via a tainted var that itself required a climb) is
# flagged unless it uses `cd -P`: verified empirically (not merely asserted) that `cd -P` ALONE
# already makes bash track $PWD physically for the `pwd` call that follows in the same subshell
# — a following `pwd -P` is redundant and NOT required. Most fixed instances in this kit pair
# both anyway (one consistent, greppable idiom), but a bare `cd -P ... && pwd` (no `-P` on pwd)
# is equally correct and not flagged — e.g. kit issue #976/#984 (PR #1029)'s own fix to
# stage-retro.sh's KIT_REPO line, whose comment reaches the identical conclusion independently.
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
#
# ALLOW-MARKER: a flagged line, or the line immediately before it, carrying a comment
#   # LINT-CD-PHYSICAL-OK: <reason>
# is reported as an explicit, named exception (ALLOWED) rather than a failure (HIT) — an empty or
# missing reason after the marker does not count and the line still fails as a HIT.
#
# Anti-silent-zero (CLAUDE.md §7): absent-input (no scan directory found), empty-input (directory
# found, no *.sh files under it), no-match (files scanned, pattern never seen at all) are printed
# as distinct, named states on stderr — never a bare, unproven "0 findings".
#
# Usage: verify-cd-physical.sh [<dir> ...]
#   No args: scans this kit's own toolbelt/ and install/ (resolved from THIS script's own
#            physically-resolved location — see the -P this checker requires of everyone else).
# Exit: 0 clean (zero HITs; ALLOWED entries do not fail the run)
#       1 one or more un-allow-marked HITs
#       2 operational failure (no scan directory found, or no *.sh files under any given directory)
#
# READ-ONLY: never modifies any file.

set -uo pipefail

_SELF_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"

if [ "$#" -gt 0 ]; then
  dirs=("$@")
else
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
    find "$d" -type f -name '*.sh' 2>/dev/null
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
  local lineno=0 line stmt code var is_rooted is_climb cd_p tv

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Fast pre-filter with zero subprocess spawn: only lines that could possibly hold a
    # `cd ... && pwd` capture pay for the (rare) ';'-split below. This matters — the loop below
    # runs once per physical line of every scanned file.
    [[ "$line" == *cd* && "$line" == *pwd* ]] || continue

    # Each ';'-separated segment of the physical line is its own logical statement; taint from an
    # earlier segment on the SAME line is visible to a later one (scan-secrets.sh-style chaining).
    # Split with a bash parameter/array expansion (no subshell) rather than piping through
    # tr/process-substitution for every line — this function runs once per line of every file.
    local -a _stmts=()
    if [[ "$line" == *';'* ]]; then
      local _oldIFS="$IFS"
      IFS=';'
      # shellcheck disable=SC2206  # intentional word-splitting: ';'-separated statements
      _stmts=($line)
      IFS="$_oldIFS"
    else
      _stmts=("$line")
    fi

    for stmt in "${_stmts[@]}"; do
      code="${stmt%%#*}"  # strip a trailing comment before any pattern matching
      [[ "$code" == *cd* && "$code" == *pwd* ]] || continue
      [[ "$code" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
      var="${BASH_REMATCH[1]}"
      # Confirm this really is a `cd ... && pwd` capture (not e.g. an unrelated `cd`/`pwd` pair
      # elsewhere in a longer statement) — a `cd` must appear before the assignment's `pwd`.
      [[ "$code" == *"cd "* || "$code" == *'cd"'* || "$code" == *'cd-P'* ]] || continue

      is_rooted=0
      if [[ "$code" == *'dirname "$0"'* || "$code" == *'BASH_SOURCE'* ]]; then
        is_rooted=1
      else
        for tv in "${!tainted[@]}"; do
          if [[ "$code" == *'$'"$tv"* || "$code" == *'${'"$tv"* ]]; then
            is_rooted=1
            break
          fi
        done
      fi
      [ "$is_rooted" -eq 1 ] || continue

      is_climb=0
      [[ "$code" == *".."* ]] && is_climb=1

      if [ "$is_climb" -eq 1 ]; then
        # Only `cd -P` is load-bearing: it alone makes bash track $PWD physically for the
        # `pwd` call that immediately follows in the same subshell (verified empirically, not
        # asserted — see the header comment). A bare `cd -P ... && pwd` (no `-P` on pwd) is
        # therefore NOT flagged; kit issue #976/#984 (PR #1029)'s own fix to stage-retro.sh uses
        # exactly this shape, with a comment reaching the identical conclusion independently.
        cd_p=0
        [[ "$code" =~ cd[[:space:]]+-P([[:space:]]|\") ]] && cd_p=1
        if [ "$cd_p" -eq 0 ]; then
          printf '%d\tclimbing derivation lacks cd -P\n' "$lineno"
        fi
      fi

      tainted["$var"]=1
    done
  done < "$f"
}

hit_count=0
allowed_count=0
scanned=0
pattern_seen=0

for f in "${files[@]}"; do
  scanned=$((scanned + 1))
  while IFS=$'\t' read -r lineno reason; do
    [ -z "${lineno:-}" ] && continue
    pattern_seen=1
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
if [ "$pattern_seen" -eq 0 ]; then
  printf 'verify-cd-physical: no-match: no climbing dirname($0)/BASH_SOURCE-derived cd/pwd construct found under: %s\n' "${dirs[*]}" >&2
fi

[ "$hit_count" -eq 0 ] || exit 1
exit 0
