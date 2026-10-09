#!/usr/bin/env bash
# hook-prepush-vendor-leak.sh — pre-push vendor-leak guard (kit issue #1271). NOT copied into targets: the git pre-push hook
# written by `research-sdd-init.sh --wire` (or a line you add to your own hook) runs THIS file from the kit, so the logic tracks the kit.
#
# git feeds a pre-push hook one line per ref on stdin: `<local ref> <local sha> <remote ref> <remote sha>`. This guard scans
# every commit that would be PUSHED, not the current checkout and not only the tip: a vendor binary added in one commit and
# deleted in the next still reaches a PUBLIC history. For each ref the commits are `git rev-list <local> --not <remote sha>`
# (a new remote ref, all-zero remote sha, uses `--not --remotes`: everything no remote-tracking ref has). Every path ADDED or
# MODIFIED in those commits is collected with its blob (submodule entries are skipped), deduplicated by blob + path across all
# refs, and ONLY those blobs are materialised into a throw-away repository and scanned with scan-vendor-leak.sh --tracked (not
# --strict: the CI workflow is the strict gate, a comment-only stub conf must not block every local push). A path that has
# several pushed versions is scanned one version per round. COST: proportional to the changed blobs of the pushed range, never
# the whole tree; a `--all` / `--tags` push scans each distinct blob once. The conf is read from the first pushed tip, falling
# back to the working tree's .research-sdd/vendor-leak.conf. A deleted ref (all-zero local sha) has nothing to scan.
# Exit: 0 = nothing to block · 1 = a leak found / the range or content could not be scanned (fail closed, "push BLOCKED") ·
# scanner exit codes 2/3 are passed through. The ONE exit-0-without-checking case is a missing scanner: typed "NOT checked".
set -uo pipefail
# RSDD-SELF-DIR (kit #1675/#2042): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd
# (the scanner is a sibling in the KIT checkout, so a link to this file must resolve to the kit, not to the link's directory).
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
here="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
SCAN="${RSDD_VENDOR_LEAK_SCANNER:-$here/../toolbelt/scan-vendor-leak.sh}"
[ -f "$SCAN" ] || { echo "research-sdd vendor-leak guard: scanner not found at $SCAN — this push was NOT checked (scanner missing; reinstall the kit or delete this hook)" >&2; exit 0; }

block() { echo "research-sdd vendor-leak guard: push BLOCKED — $1" >&2; exit "${2:-1}"; }
top="$(git rev-parse --show-toplevel 2>/dev/null)" || block "not inside a git work tree, the pushed content cannot be scanned"
gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || block "cannot resolve the git dir, the pushed content cannot be scanned"
tmp="$(mktemp -d)" || block "mktemp failed, the pushed content cannot be scanned"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
G=(git --git-dir="$gitdir")
# git exports GIT_DIR / GIT_INDEX_FILE to hooks in some flows; the throw-away repository must not inherit them.
TG=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git)

declare -A VERS=() SEEN=()
order=(); conf_from=""
while read -r _lref lsha _rref rsha; do
  [ -n "$lsha" ] || continue
  case "$lsha" in *[!0]*) ;; *) continue ;; esac            # all zeros: a ref deletion
  [ -n "$conf_from" ] || conf_from="$lsha"
  commits=""
  case "${rsha:-}" in
    ''|*[!0]*) [ -n "${rsha:-}" ] && commits="$("${G[@]}" rev-list "$lsha" --not "$rsha" 2>/dev/null)" ;;
  esac
  if [ -z "$commits" ]; then   # new remote ref, or a remote sha this clone does not have: everything no remote-tracking ref has
    commits="$("${G[@]}" rev-list "$lsha" --not --remotes 2>/dev/null)" || block "could not list the commits being pushed for $lsha"
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    "${G[@]}" diff-tree -r -m --root --no-commit-id --no-renames --diff-filter=AMT -z "$c" > "$tmp/dt" 2>/dev/null \
      || block "could not read the changes of commit $c"
    while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
      read -r _om nm _os nb _st <<<"$meta"
      [ "$nm" = 160000 ] && continue                         # a submodule pointer has no blob here
      key="$nb $p"; [ -z "${SEEN[$key]+x}" ] || continue; SEEN[$key]=1
      if [ -z "${VERS[$p]+x}" ]; then order+=("$p"); VERS[$p]="$nb"; else VERS[$p]="${VERS[$p]} $nb"; fi
    done < "$tmp/dt"
  done <<<"$commits"
done

[ "${#order[@]}" -gt 0 ] || { echo "research-sdd vendor-leak guard: no added or modified files in the pushed range — nothing to scan"; exit 0; }

rc=0; round=0
while :; do
  round=$((round+1)); n=0; work="$tmp/w$round"; mkdir -p "$work"
  for p in "${order[@]}"; do
    read -ra bl <<<"${VERS[$p]}"
    [ "${#bl[@]}" -ge "$round" ] || continue
    mkdir -p "$work/$(dirname -- "$p")" && "${G[@]}" cat-file blob "${bl[$((round-1))]}" > "$work/$p" 2>/dev/null \
      || block "could not materialise $p (${bl[$((round-1))]}) for scanning"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || break
  mkdir -p "$work/.research-sdd"
  "${G[@]}" show "$conf_from:.research-sdd/vendor-leak.conf" > "$work/.research-sdd/vendor-leak.conf" 2>/dev/null \
    || { rm -f "$work/.research-sdd/vendor-leak.conf"; [ ! -f "$top/.research-sdd/vendor-leak.conf" ] || cp "$top/.research-sdd/vendor-leak.conf" "$work/.research-sdd/vendor-leak.conf"; }
  { "${TG[@]}" -C "$work" init -q && "${TG[@]}" -C "$work" add -f -A; } >/dev/null 2>&1 || block "could not stage the pushed blobs for scanning"
  echo "research-sdd vendor-leak guard: scanning $n pushed file version(s) (round $round)"
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "$SCAN" "$work" --tracked; s=$?
  if [ "$s" -ne 0 ]; then echo "research-sdd vendor-leak guard: push BLOCKED — a pushed commit carries a flagged file (scanner exit $s)" >&2; [ "$rc" -eq 1 ] || rc="$s"; fi
done
exit "$rc"
