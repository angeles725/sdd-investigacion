#!/usr/bin/env bash
# merge-gate stub: a real squash onto origin/main (via the $CASE/sq clone) so main actually moves.
while [ $# -gt 0 ]; do case "$1" in --cwd) cwd="$2"; shift 2 ;; --merge) pr="$2"; shift 2 ;; *) shift ;; esac; done
echo "MERGE $pr head=$(git -C "$cwd" rev-parse HEAD)" >> "$CASE/calls.log"
echo "CWD $pr $cwd" >> "$CASE/calls.log"
# RDD authority is bound to the worktree where the review ran: allow only from the registered cwd, when one is registered
if [ -e "$CASE/only-cwd-$pr" ] && [ "$(cd "$cwd" && pwd -P)" != "$(cat "$CASE/only-cwd-$pr")" ]; then
  echo "merge-gate: refuse: review_due (high_risk) — review this exact head before merging"; exit 1
fi
if [ -e "$CASE/mg-degrade-$pr" ]; then echo "merge-gate: degraded: simulated"; exit 3; fi
if [ -e "$CASE/mg-fail-$pr" ]; then echo "merge-gate: refuse: review_due (high_risk)"; exit 1; fi
if [ -e "$CASE/mg-pending-$pr" ] && [ ! -e "$CASE/mg-pending-done-$pr" ]; then touch "$CASE/mg-pending-done-$pr"; echo "merge-gate: refuse: ci_pending"; exit 1; fi
sq="$CASE/sq"
git -C "$sq" fetch -q origin "refs/pull/$pr/head" && git -C "$sq" checkout -q -B main origin/main || exit 1
[ -e "$CASE/mg-race-$pr" ] && bash "$CASE/push-extra.sh" "race-$pr"
git -C "$sq" fetch -q origin && git -C "$sq" checkout -q -B main origin/main
git -C "$sq" merge --squash "$(cat "$CASE/head-$pr")" >/dev/null || exit 1
[ -e "$CASE/mg-tweak-$pr" ] && echo tweak > "$sq/tweak.txt"
git -C "$sq" add -A && git -C "$sq" commit -q -m "squash #$pr" && git -C "$sq" push -q origin HEAD:main || exit 1
touch "$CASE/merged-$pr"; echo "merge-gate: allow (merged)"
