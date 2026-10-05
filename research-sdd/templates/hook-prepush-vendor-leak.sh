#!/usr/bin/env bash
# hook-prepush-vendor-leak.sh — pre-push vendor-leak guard (kit issue #1271). NOT copied into targets: the git pre-push hook
# written by `research-sdd-init.sh --wire` (or a line you add to your own hook) runs THIS file from the kit, so the logic tracks the kit.
#
# git feeds a pre-push hook one line per ref on stdin: `<local ref> <local sha> <remote ref> <remote sha>`. This guard scans
# the content being PUSHED, not the current checkout: for every distinct local sha it materialises that commit's tree into a
# throw-away repository and runs scan-vendor-leak.sh --tracked on it (not --strict: the CI workflow is the strict gate, a
# comment-only stub conf must not block every local push). The target's .research-sdd/vendor-leak.conf is read from the pushed
# tree, falling back to the working tree's when that commit carries none.
# A deleted ref (all-zero local sha) has nothing to scan and is skipped. A sha that cannot be materialised BLOCKS the push
# (fail closed, never a silent pass). Exit: 0 = nothing to block · 1 = a leak found / content not scannable · scanner exit
# codes 2/3 are passed through. A scanner that is missing is a typed warning and exit 0 (a moved kit must not brick pushes).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SCAN="${RSDD_VENDOR_LEAK_SCANNER:-$here/../toolbelt/scan-vendor-leak.sh}"
[ -f "$SCAN" ] || { echo "research-sdd vendor-leak guard: scanner not found at $SCAN — this push was NOT checked (reinstall the kit or delete this hook)" >&2; exit 0; }

# git exports GIT_DIR / GIT_INDEX_FILE to hooks in some flows; the throw-away repository must not inherit them.
top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "research-sdd vendor-leak guard: not inside a git work tree — push NOT checked" >&2; exit 1; }
gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { echo "research-sdd vendor-leak guard: cannot resolve the git dir — push NOT checked" >&2; exit 1; }

rc=0; seen=" "
while read -r _lref lsha _rref _rsha; do
  [ -n "$lsha" ] || continue
  case "$lsha" in *[!0]*) ;; *) continue ;; esac            # all zeros: a ref deletion
  case "$seen" in *" $lsha "*) continue ;; esac
  seen="$seen$lsha "
  tmp="$(mktemp -d)" || { echo "research-sdd vendor-leak guard: mktemp failed — push NOT checked" >&2; exit 1; }
  work="$tmp/tree"; mkdir -p "$work"
  if ! { GIT_DIR="$gitdir" GIT_INDEX_FILE="$tmp/index" git read-tree "$lsha" \
         && GIT_DIR="$gitdir" GIT_INDEX_FILE="$tmp/index" git checkout-index -a -f --prefix="$work/"; } >/dev/null 2>&1; then
    echo "research-sdd vendor-leak guard: could not materialise $lsha — push BLOCKED (content not scannable)" >&2
    rm -rf "$tmp"; rc=1; continue
  fi
  if [ ! -e "$work/.research-sdd/vendor-leak.conf" ] && [ -f "$top/.research-sdd/vendor-leak.conf" ]; then
    mkdir -p "$work/.research-sdd" && cp "$top/.research-sdd/vendor-leak.conf" "$work/.research-sdd/vendor-leak.conf"
  fi
  if ! { env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$work" init -q \
         && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$work" add -f -A; } >/dev/null 2>&1; then
    echo "research-sdd vendor-leak guard: could not stage $lsha for scanning — push BLOCKED" >&2
    rm -rf "$tmp"; rc=1; continue
  fi
  echo "research-sdd vendor-leak guard: scanning pushed commit $lsha"
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "$SCAN" "$work" --tracked; s=$?
  rm -rf "$tmp"
  if [ "$s" -ne 0 ]; then echo "research-sdd vendor-leak guard: push BLOCKED — commit $lsha (scanner exit $s)" >&2; [ "$rc" -ne 1 ] && rc="$s"; fi
done
exit "$rc"
