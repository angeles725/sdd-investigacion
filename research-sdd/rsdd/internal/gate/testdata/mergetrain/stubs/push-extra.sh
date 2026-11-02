#!/usr/bin/env bash
# another actor lands a commit on origin/main
sq="$CASE/sq"
git -C "$sq" fetch -q origin && git -C "$sq" checkout -q -B main origin/main
echo "$1" > "$sq/extra-$1.txt"; git -C "$sq" add -A && git -C "$sq" commit -q -m "extra $1" && git -C "$sq" push -q origin HEAD:main
