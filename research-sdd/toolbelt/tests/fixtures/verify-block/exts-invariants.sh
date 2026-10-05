#!/usr/bin/env bash
# exts-invariants.sh SUT [EXPECTED_SET] — kit #1721/#1742: assertions over the `_vb_file_exts` and `_vb_tlds` lists of a
# verify-block.sh (the real SUT or a mutant). Prints verdict lines; never exits non-zero (the caller matches the lines).
#   EXTS no-duplicates (N read)    | EXTS DUP: <entry>        (no entry appears twice)
#   EXTS tlds-subset (N read)      | EXTS TLD-NOT-EXT: <entry> (every `_vb_tlds` entry is also in `_vb_file_exts`: the list
#                                                               holds only the overlap)
#   EXTS set-preserved             | EXTS SET-DIFF: <+/-entry> (the SET equals the expected set: the dedupe removed only
#                                                               duplicates and added nothing)
#                                  | EXTS UNREADABLE-EXPECTED  (the expected-set fixture is missing/unreadable: could not run)
#                                  | EXTS DIFF-ERROR           (diff itself failed, exit >= 2: could not run)
#                                  | EXTS GREP-ERROR           (grep failed, exit >= 2, in the tlds-subset check: could not run)
# A could-not-run state is a typed failure, never `set-preserved` (CLAUDE.md §7).
# EXPECTED_SET defaults to exts-expected-set.txt beside this script.
sut="$1"; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected="${2:-$here/exts-expected-set.txt}"
# Sanity floor: the real list has ~220 entries; at or below this the awk range read the wrong span.
min_entries=50
# a list sits between `<name>='` and the closing quote, one entry per line
list_dump(){ awk -v name="$1" 'BEGIN{open=name "=\x27"} index($0,open)==1{f=1; $0=substr($0,length(open)+1)} f{l=$0; e=(l ~ /\x27$/); sub(/\x27$/,"",l); print l; if(e) exit}' "$sut"; }
dump="$(list_dump _vb_file_exts)"; cnt=$(printf '%s\n' "$dump" | grep -c .)
if [ "$cnt" -le "$min_entries" ]; then echo "EXTS UNREADABLE (count=$cnt)"; exit 0; fi
dups="$(printf '%s\n' "$dump" | LC_ALL=C sort | uniq -d)"
if [ -z "$dups" ]; then echo "EXTS no-duplicates ($cnt read)"; else printf '%s\n' "$dups" | sed 's/^/EXTS DUP: /'; fi
tl="$(list_dump _vb_tlds)"; tcnt=$(printf '%s\n' "$tl" | grep -c .)
if [ "$tcnt" -lt 1 ]; then echo "EXTS UNREADABLE (tlds count=$tcnt)"
else
  # grep exits 1 for "entry absent" (a finding) and >= 2 for a real error (could not run): only the latter is a failure
  notext=""; nrc=0
  while IFS= read -r e; do
    grep -qxF "$e" <<<"$dump"; r=$?
    if [ "$r" -ge 2 ]; then nrc=$r; elif [ "$r" -eq 1 ]; then notext="$notext$e"$'\n'; fi
  done <<<"$tl"
  if [ "$nrc" -ge 2 ]; then
    echo "EXTS GREP-ERROR (grep rc=$nrc)"
  elif [ -z "$notext" ]; then
    echo "EXTS tlds-subset ($tcnt read)"
  else
    printf '%s' "$notext" | sed 's/^/EXTS TLD-NOT-EXT: /'
  fi
fi
if [ ! -f "$expected" ] || [ ! -r "$expected" ]; then echo "EXTS UNREADABLE-EXPECTED ($expected)"; exit 0; fi
raw="$(diff <(printf '%s\n' "$dump" | LC_ALL=C sort -u) "$expected")"; drc=$?
if [ "$drc" -ge 2 ]; then echo "EXTS DIFF-ERROR (diff rc=$drc)"; exit 0; fi
diffs="$(printf '%s\n' "$raw" | sed -n 's/^< /+/p; s/^> /-/p')"
if [ -z "$diffs" ]; then echo "EXTS set-preserved"; else echo "EXTS HINT: intentional extension change? update tests/fixtures/verify-block/exts-expected-set.txt"; printf '%s\n' "$diffs" | sed 's/^/EXTS SET-DIFF: /'; fi
exit 0
