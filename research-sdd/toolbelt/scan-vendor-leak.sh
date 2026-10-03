#!/usr/bin/env bash
# scan-vendor-leak.sh — vendor-code LEAK guard for public targets (kit issue #1271, slice 1).
#
# WHY: scan-secrets.sh looks for secret VALUES and excludes decompiled trees by design, so a decompiled
# vendor source tree or a vendor binary committed to a target that is (or will be) public is invisible to
# it (evidence: niagara5-research b8eebcd). This scanner is the separate guard: it reports git-tracked or
# staged files that are vendor binaries, live under a declared vendor path, or declare a vendor package.
# The declaration contract (what a target must write, and what this tool cannot see) is in
# scan-vendor-leak.v1.md — read it before trusting a clean run.
#
# Usage: scan-vendor-leak.sh <target-dir> [--tracked|--staged]
#   --tracked  (default) every file git tracks in <target-dir>; content is read from the INDEX.
#   --staged   only files added/copied/modified/renamed in the index (what a commit would send).
# Output (stdout, one line each):
#   LEAK <binary|path|package> <path>[:<line>] <reason>
#   ABSENT-CONF / EMPTY-CONF / EMPTY-INPUT / BAD-CONF  — typed non-finding states
#   SUMMARY scanned=N allowed=N findings=N conf=present|absent prefixes=N paths=N allows=N mode=M
# Exit: 0 no findings · 1 findings · 2 usage / not a git repo / bad conf · 3 DEGRADED (git missing).
# READ-ONLY: only `git ls-files|diff|show|rev-parse` run against the target; nothing is written.
set -uo pipefail

mode=tracked
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tracked) mode=tracked ;;
    --staged) mode=staged ;;
    -*) echo "usage: scan-vendor-leak.sh <target-dir> [--tracked|--staged] (unknown flag: $1)" >&2; exit 2 ;;
    *) if [ -z "$target" ]; then target="$1"; else echo "usage: scan-vendor-leak.sh <target-dir> [--tracked|--staged]" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: scan-vendor-leak.sh <target-dir> [--tracked|--staged]" >&2; exit 2; }

# A missing dependency is a typed degraded state, never a pass.
command -v git >/dev/null 2>&1 || { echo "DEGRADED: git not found — scan-vendor-leak.sh needs git" >&2; exit 3; }
git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "usage: $target is not inside a git work tree" >&2; exit 2; }

shopt -u nocasematch

PREFIXES=(); PATHS=(); ALLOWS=()
conf="$target/.research-sdd/vendor-leak.conf"
conf_state=absent
bad_conf=0
if [ -f "$conf" ]; then
  conf_state=present
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    dir="${line%%[[:space:]]*}"
    arg=""
    [ "$dir" != "$line" ] && arg="${line#"$dir"}"
    arg="${arg#"${arg%%[![:space:]]*}"}"
    case "$dir" in
      prefix|path|allow)
        if [ -z "$arg" ]; then
          echo "BAD-CONF $conf: directive '$dir' needs an argument"
          bad_conf=1
          continue
        fi
        case "$dir" in
          prefix) PREFIXES+=("$arg") ;;
          path) PATHS+=("$arg") ;;
          allow) ALLOWS+=("$arg") ;;
        esac ;;
      *)
      echo "BAD-CONF unknown directive '$dir' in $conf (expected prefix|path|allow)"
      bad_conf=1 ;;
    esac
  done < "$conf"
fi
[ "$bad_conf" = 0 ] || exit 2

if [ "$conf_state" = absent ]; then
  echo "ABSENT-CONF $conf — no vendor declaration; only the built-in binary rule runs"
elif [ $(( ${#PREFIXES[@]} + ${#PATHS[@]} + ${#ALLOWS[@]} )) -eq 0 ]; then
  echo "EMPTY-CONF $conf — conf has no directives; only the built-in binary rule runs"
fi

# matches_any <path> <glob>... — bash pattern match; `*` crosses `/`, so `dir/**` covers a whole tree.
matches_any() {
  local p="$1" g; shift
  for g in "$@"; do
    # shellcheck disable=SC2053  # the glob is meant to be a pattern
    [[ "$p" == $g ]] && return 0
  done
  return 1
}
is_allowed() {
  [ "${#ALLOWS[@]}" -gt 0 ] || return 1
  matches_any "$1" "${ALLOWS[@]}"
}

findings=0; scanned=0; allowed=0
emit() { # emit <kind> <path-with-optional-:line> <reason>
  local loc="${2//$'\n'/\\n}"
  printf 'LEAK %s %s %s\n' "$1" "$loc" "$3"
  findings=$((findings+1))
}

list_files() {
  if [ "$mode" = staged ]; then
    git -C "$target" diff --cached --name-only --relative -z --diff-filter=ACMR
  else
    git -C "$target" ls-files -z
  fi
}

files_tmp="$(mktemp)" || { echo "DEGRADED: mktemp failed" >&2; exit 3; }
trap 'rm -f "$files_tmp"' EXIT
list_files > "$files_tmp" || { echo "DEGRADED: git could not list files ($mode)" >&2; exit 3; }

while IFS= read -r -d '' p; do
  scanned=$((scanned+1))
  if is_allowed "$p"; then
    allowed=$((allowed+1))
    continue
  fi
  lc="${p,,}"
  case "$lc" in
    *.class|*.jar|*.dll|*.so|*.exe) emit binary "$p" "vendor binary artifact (built-in rule)" ;;
  esac
  if [ "${#PATHS[@]}" -gt 0 ] && matches_any "$p" "${PATHS[@]}"; then
    emit path "$p" "matches declared vendor path"
  fi
  if [ "${#PREFIXES[@]}" -gt 0 ]; then
    case "$lc" in
      *.java|*.kt|*.scala|*.groovy)
        content="$(git -C "$target" show ":./$p" 2>/dev/null)" || content=""
        ln=0
        while IFS= read -r l || [ -n "$l" ]; do
          ln=$((ln+1))
          if [[ "$l" =~ ^[[:space:]]*package[[:space:]]+([A-Za-z_][A-Za-z0-9_.]*) ]]; then
            pkg="${BASH_REMATCH[1]}"
            for pre in "${PREFIXES[@]}"; do
              if [[ "$pkg" == "$pre" || "$pkg" == "$pre".* ]]; then
                emit package "$p:$ln" "package $pkg is under declared vendor prefix $pre"
                break
              fi
            done
            break
          fi
        done <<<"$content" ;;
    esac
  fi
done < "$files_tmp"

[ "$scanned" -gt 0 ] || echo "EMPTY-INPUT no files in scope for mode=$mode — a zero here means nothing was looked at"
note=""
[ "$conf_state" = present ] || note=" — path/package rules NOT evaluated (no conf); only the built-in binary rule ran"
echo "SUMMARY scanned=$scanned allowed=$allowed findings=$findings conf=$conf_state prefixes=${#PREFIXES[@]} paths=${#PATHS[@]} allows=${#ALLOWS[@]} mode=$mode$note"
[ "$findings" -gt 0 ] && exit 1
exit 0
