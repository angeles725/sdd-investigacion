#!/usr/bin/env bash
# state-files.sh — enumerate every RESEARCH-STATE*.md in a corpus directory.
# Shared by research-sdd-archive.sh, research-sdd-status.sh, and any future consumer
# that needs ALL state files for a corpus.
#
#   list_state_files <dir>
#     Prints the absolute (or dir-relative) sorted paths of every
#     RESEARCH-STATE*.md under <dir> (maxdepth 3, *.template.md excluded,
#     .git excluded), one per line. Returns 0; prints nothing if none found.
#
#   resolve_state_file [-H] <dir> [--focus <slug>]
#     Picks THE one state file a consumer should act on (kit issue #1818). Prints its path.
#     Candidates: list_state_files' set (maxdepth 3, *.template.md and .git excluded);
#     with --focus <slug> only RESEARCH-STATE-<slug>.md. Ranking: shallowest depth first, and
#     within one depth the un-suffixed root RESEARCH-STATE.md beats every RESEARCH-STATE-<focus>.md
#     (a lexical sort would put RESEARCH-STATE-auth.md BEFORE RESEARCH-STATE.md — '-' < '.').
#     Among equal-rank files in ONE directory (a flat multi-focus corpus with no root) the
#     C-locale-first path wins, as it always did. -H follows a symlinked <dir> (find -H), for
#     consumers whose target may be a symlink (verify-state.sh).
#     Return: 0 found (path on stdout) · 1 absent (nothing found; prints nothing) ·
#             2 ambiguous: equal-rank candidates in DIFFERENT directories (a split layout, one
#               corpus dir per focus). stdout still carries the C-locale-first pick so a caller that
#               accepts a split layout can proceed; a caller that cannot MUST treat 2 as a refusal.
#               The state is typed, never folded into 0. · 3 usage / <dir> not a directory.
#     Absent, ambiguous and unusable-input are three distinct states (CLAUDE.md §7).
#
# Drift hazard: this file is the SINGLE definition of the "enumerate state files"
# incantation for gate/aggregation consumers. Do NOT copy-paste the find command
# into a new consumer; source this library instead. The find flags here MUST match
# the canonical pattern in verify-state.sh:33, which predates this library and is
# the authoritative reference for the exclusion set.
#
# Scope of this rule: every consumer that enumerates (list_state_files: --sync-state seeding,
# --next multi-focus scan, archive enumeration) or picks (resolve_state_file: the one file to act
# on, including research-sdd-status.sh's startup pick and its --focus <slug> selection) state
# files. There is no exception: status.sh sources this library before it picks.
#
# Idempotent: safe to source more than once (multiple consumers may pull it in
# the same shell; declare -F guard prevents double-definition). Follow the pattern
# of lib/retro-status.sh and lib/focus-prefix.sh.

# shellcheck disable=SC2148   # intentionally no shebang guard — always sourced, never executed
if ! declare -F list_state_files >/dev/null 2>&1; then
  list_state_files() {
    local corpus="$1"
    find "$corpus" -maxdepth 3 \
      -name 'RESEARCH-STATE*.md' \
      -not -name '*.template.md' \
      -not -path '*/.git/*' \
      2>/dev/null | sort
  }
fi

if ! declare -F resolve_state_file >/dev/null 2>&1; then
  resolve_state_file() {
    local follow="" dir slug="" pat found ranked line key0="" path dir0="" first="" amb=0 tab=$'\t'
    if [ "${1:-}" = "-H" ]; then follow="-H"; shift; fi
    dir="${1:-}"; [ "$#" -gt 0 ] && shift
    [ -n "$dir" ] && [ -d "$dir" ] || return 3
    if [ "${1:-}" = "--focus" ]; then
      slug="${2:-}"; [ -n "$slug" ] || return 3
      shift 2
    fi
    [ "$#" -eq 0 ] || return 3
    if [ -n "$slug" ]; then pat="RESEARCH-STATE-${slug}.md"; else pat='RESEARCH-STATE*.md'; fi
    # No -e / no status check on find: a non-zero from an unreadable subtree is discarded (same
    # contract as list_state_files); the candidates it did see are still correct.
    # shellcheck disable=SC2086   # $follow is empty or exactly -H
    found="$(find $follow "$dir" -maxdepth 3 -name "$pat" -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null)"
    [ -n "$found" ] || return 1
    # Rank lines are "<depth>\t<0 if root else 1>\t<path>"; one sort, no `| head` (SIGPIPE-safe).
    ranked="$(printf '%s\n' "$found" | LC_ALL=C awk -v n="${#dir}" '
      { r = substr($0, n + 1); depth = gsub("/", "/", r); b = $0; sub(".*/", "", b)
        printf "%d\t%d\t%s\n", depth, (b == "RESEARCH-STATE.md") ? 0 : 1, $0 }' \
      | LC_ALL=C sort -t "$tab" -k1,1n -k2,2n -k3,3)"  # RSF-RANK
    while IFS= read -r line; do
      path="${line#*"$tab"*"$tab"}"
      if [ -z "$key0" ]; then
        key0="${line%"$tab"*}"; first="$path"; dir0="${path%/*}"
      elif [ "${line%"$tab"*}" = "$key0" ] && [ "${path%/*}" != "$dir0" ]; then
        amb=1
      fi
    done <<<"$ranked"
    if [ "$amb" = 1 ]; then printf '%s\n' "$first"; return 2; fi  # RSF-AMBIGUOUS-RC
    printf '%s\n' "$first"
  }
fi
