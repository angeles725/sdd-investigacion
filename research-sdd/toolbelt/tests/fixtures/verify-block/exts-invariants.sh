#!/usr/bin/env bash
# exts-invariants.sh SUT — kit #1721: assertions over the `_vb_file_exts` list of a verify-block.sh (the real SUT or a
# mutant). Prints one verdict line per invariant; never exits non-zero (the caller matches the lines).
#   EXTS no-duplicates (N read)    | EXTS DUP: <entry>        (no entry appears twice)
#   EXTS set-preserved             | EXTS SET-DIFF: <+/-entry> (the SET equals the frozen origin/main list: the dedupe
#                                                               removed only duplicates and added nothing)
sut="$1"; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# the list sits between `_vb_file_exts='` and the closing quote, one entry per line
exts_dump(){ awk "/^_vb_file_exts='/{f=1; sub(/^_vb_file_exts='/,\"\")} f{l=\$0; e=(l ~ /'\$/); sub(/'\$/,\"\",l); print l; if(e) exit}" "$sut"; }
dump="$(exts_dump)"; cnt=$(printf '%s\n' "$dump" | grep -c .)
if [ "$cnt" -le 50 ]; then echo "EXTS UNREADABLE (count=$cnt)"; exit 0; fi
dups="$(printf '%s\n' "$dump" | LC_ALL=C sort | uniq -d)"
if [ -z "$dups" ]; then echo "EXTS no-duplicates ($cnt read)"; else printf '%s\n' "$dups" | sed 's/^/EXTS DUP: /'; fi
diffs="$(diff <(printf '%s\n' "$dump" | LC_ALL=C sort -u) "$here/exts-origin-main-set.txt" | grep '^[<>]' | sed 's/^< /+/; s/^> /-/')"
if [ -z "$diffs" ]; then echo "EXTS set-preserved"; else printf '%s\n' "$diffs" | sed 's/^/EXTS SET-DIFF: /'; fi
exit 0
