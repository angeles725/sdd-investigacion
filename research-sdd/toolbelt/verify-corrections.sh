#!/usr/bin/env bash
# verify-corrections.sh — §14 reciprocal-backlink lint for a Research-SDD corpus (retro delta).
#
# WHY: §14 self-correction is BI-directional by design — a later block that refutes/refines an earlier one
# must "keep the original text, add a note 'corrected in BN'" IN THE CORRECTED BLOCK, not only cross-ref it
# FROM the correcting block. In practice only the forward half gets written: the correcting block declares
# "Corrects [Block N] §N.x", but the target block file is never touched — and a self-report can even CLAIM the
# backlink was added when the git diff proves otherwise (the exact B33→B8 gap this lint was born from). This
# mechanizes the reciprocal check, mirroring how §11/§5 mechanized the marker tally / source registry.
#
# It reads each block file, finds CORRECTION DECLARATIONS (a `corrects`/`corrige…` verb bound to a
# [Block N]/[Bloque N] reference on the same line), and for each declared target requires that block's file to
# carry a reciprocal "corrected in B<this>" (or "corregido en B<this>") note. A one-directional correction
# (declared, not back-linked) is a FAIL. Uses the SAME block-file discriminator as gen-catalog/verify-state/
# archive so "a block file" means one thing corpus-wide.
#
# Usage: verify-corrections.sh <target-dir>
# Exit: 0 = every declared correction is reciprocated (or none) · 1 = a one-directional correction · 2 = bad
#       args / no block files.
set -uo pipefail

target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-corrections.sh <target-dir>" >&2; exit 2; }

# Block files: `<prefix>-(block|bloque)<N>[-suffix].md` (the corpus-wide discriminator). Exclude templates/.git.
mapfile -t blocks < <(find "$target" -maxdepth 3 -type f -name '*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null \
  | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | sort)
[ "${#blocks[@]}" -gt 0 ] || { echo "verify-corrections: no block files under $target" >&2; exit 2; }

# Trailing block NUMBER from a block filename (t-block33.md → 33; ug67-bloque8-foo.md → 8).
blocknum() { basename "$1" | sed -E 's/.*-(block|bloque)0*([0-9]+).*/\2/'; }

# number → file map (last one wins; corpora keep one file per block number).
declare -A numfile
for f in "${blocks[@]}"; do numfile["$(blocknum "$f")"]="$f"; done

rc=0
echo "== verify-corrections: $(basename "$target") =="
for f in "${blocks[@]}"; do
  c="$(blocknum "$f")"
  # Correction-declaring lines: a real correction VERB (`corrects` / Spanish `corrig…`) — NOT the adjective
  # "correct" and NOT the backlink phrase "corrected in" — AND a [Block N]/[Bloque N] reference on the line.
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qiE '\b(corrects|corrig[a-z]*)\b' || continue
    # TIGHT VERB→REFERENCE BINDING: the correction verb governs ONLY the FIRST [Block N]/[Bloque N] that
    # FOLLOWS it on the line. Slice the line from the first verb, then take just that first bracketed ref — a
    # trailing `cf. [Block M]` / `see [Block M]` after the governed target is a CROSS-REFERENCE, not a
    # correction target (else `Corrects [Block 8]; cf. [Block 12]` falsely demands a backlink in B12 — the
    # exact B33 false-FAIL the retro caught). `head -1` on the bracket list is the first-ref binding.
    gov="$(printf '%s' "$line" | grep -oiE '\b(corrects|corrig[a-z]*)\b.*')"
    for n in $(printf '%s' "$gov" | grep -oiE '\[[[:space:]]*(block|bloque)[[:space:]]*[0-9]+[[:space:]]*\]' | head -1 | grep -oE '[0-9]+'); do
      n="$((10#$n))"                      # normalize any zero-padding
      [ "$n" = "$c" ] && continue         # a block correcting itself is not a cross-block backlink
      tgt="${numfile[$n]:-}"
      if [ -z "$tgt" ]; then
        echo "   WARN   B$c declares a correction of [Block $n] but no block-$n file exists on disk"
        continue
      fi
      # Reciprocal backlink: the target file must mention "corrected in"/"corregido en" AND B<c>/Block <c>.
      if grep -iE 'corrected|corregido' "$tgt" 2>/dev/null | grep -qiE "\bb0*$c\b|\bblock[[:space:]]*0*$c\b|\bbloque[[:space:]]*0*$c\b"; then
        : # reciprocated
      else
        echo "   FAIL   B$c corrects [Block $n] but $(basename "$tgt") has no reciprocal 'corrected in B$c' backlink (§14)"
        rc=1
      fi
    done
  done < <(grep -iE '\b(corrects|corrig[a-z]*)\b' "$f" 2>/dev/null)
done

[ "$rc" -eq 0 ] && echo "   ok     every declared correction has its reciprocal 'corrected in BN' backlink."
echo "== exit $rc =="
exit $rc
