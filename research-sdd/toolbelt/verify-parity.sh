#!/usr/bin/env bash
# verify-parity.sh — corpus↔derived-artifact PARITY gate for a Research-SDD corpus (retro delta #1).
#
# Catches the DRIFT that verify-block/sources/state all miss: a corpus ships a downstream deliverable
# (e.g. prototypes/*/tokens.css) whose LOAD-BEARING values are COPIED from a certified block's palette,
# and that deliverable silently diverges from the block it claims to derive from. That exact miss is
# what let pruebas-dashboards ship a broken prototype: the realign commits 6a9bc78 and c27ec63 pushed a
# tokens.css whose hex palette had drifted from the certified block while EVERY existing gate exited 0
# (verify-block checks block structure, verify-sources checks the registry, verify-state checks the
# mirror — none cross-checks a downstream deliverable against the block's values). This gate does.
#
# APPROACH — subset check (not a role→role mapping manifest): every load-bearing value in the
# DELIVERABLE must EXIST somewhere in the certified BLOCK set it derives from. A hex present in the
# deliverable but in NO block value is drift ⇒ FAIL. This catches a changed or invented value without
# needing a per-role manifest. Load-bearing values here are hex color tokens (#RRGGBB and #RGB,
# case-insensitive; #RGB is expanded to #RRGGBB so #FFF matches #ffffff).
#
# Usage: verify-parity.sh <deliverable-file> <block-file-or-dir>
# Exit: 0 = parity (every deliverable value present in the block set, or the deliverable has none) ·
#       1 = drift (a deliverable hex is absent from the block set — each is listed) · 2 = bad args /
#       missing files.
set -uo pipefail

deliverable="${1:-}"
block="${2:-}"
[ -n "$deliverable" ] && [ -n "$block" ] || { echo "usage: verify-parity.sh <deliverable-file> <block-file-or-dir>" >&2; exit 2; }
[ -f "$deliverable" ] || { echo "verify-parity: deliverable file not found: $deliverable" >&2; exit 2; }
[ -e "$block" ]       || { echo "verify-parity: block file/dir not found: $block" >&2; exit 2; }

# norm <hex-token> — normalize a raw hex token (`#abc` or `#AABBCC`, any case) to canonical
# lowercase `#rrggbb`. #RGB is expanded by doubling each nibble so #FFF ≡ #ffffff. A token whose
# hex run is not exactly 3 or 6 digits (e.g. an 8-digit #RRGGBBAA) is NOT a plain color token here
# and is rejected (return 1) rather than half-matched.
norm() {
  local t="${1#\#}"
  t="$(printf '%s' "$t" | tr 'A-F' 'a-f')"
  case "${#t}" in
    3) printf '#%s%s%s%s%s%s\n' "${t:0:1}" "${t:0:1}" "${t:1:1}" "${t:1:1}" "${t:2:1}" "${t:2:1}" ;;
    6) printf '#%s\n' "$t" ;;
    *) return 1 ;;
  esac
}

# extract_hexes <file...> — print one canonical #rrggbb per line for every hex color token in the
# given file(s). grep -oiE pulls raw runs of 3-8 hex digits (leftmost-longest, so #ffffff is one
# 6-run, not #fff + fff); norm then keeps only the exact 3/6-digit ones and canonicalizes them.
extract_hexes() {
  local f tok
  for f in "$@"; do
    [ -f "$f" ] || continue
    while IFS= read -r tok; do
      norm "$tok"
    done < <(grep -oiE '#[0-9a-f]{3,8}' -- "$f" 2>/dev/null)
  done
}

# Resolve the BLOCK file set. Use the STRICT canonical discriminator (gen-catalog.py BLOCK_RE:
# `<prefix>-(block|bloque)<N>[-suffix].md`, case-sensitive), NOT a loose `*block*` glob — a parity check
# unions block VALUES, so a decoy like `blocked-notes.md` (or a mixed-case non-block) must not inject stray
# hexes that let an invented deliverable value pass. This is the count/catalog family's definition, so a
# value's provenance is checked against exactly the canonical blocks. (Known limit: a BESPOKE corpus's
# non-numbered thematic blocks are excluded here, same as from the catalog count — pass such a block as an
# explicit file argument to parity-check it.) A plain file argument is used as-is.
block_files=()
if [ -d "$block" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && block_files+=("$f")
  done < <(find "$block" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | sort)
  [ "${#block_files[@]}" -gt 0 ] || { echo "verify-parity: no <prefix>-(block|bloque)<N>.md under $block" >&2; exit 2; }
else
  block_files=("$block")
fi

echo "== verify-parity: $(basename "$deliverable") vs $(basename "$block") =="

# Canonical, de-duplicated sets.
mapfile -t deliv_hexes < <(extract_hexes "$deliverable" | sort -u)
mapfile -t block_hexes < <(extract_hexes "${block_files[@]}" | sort -u)

echo "-- deliverable load-bearing hexes: ${#deliv_hexes[@]} · block palette hexes: ${#block_hexes[@]} (across ${#block_files[@]} block file(s))"

# Empty deliverable — nothing load-bearing to check. Do NOT false-fail.
if [ "${#deliv_hexes[@]}" -eq 0 ]; then
  echo "   note: deliverable has no extractable hex color tokens — nothing to check."
  echo "== exit 0 =="
  exit 0
fi

# SUBSET CHECK — every deliverable hex must exist in the block palette set; each miss is drift.
# Pre-join to a string so the per-hex lookup uses a here-string (no pipe) — removing the pipe
# eliminates the SIGPIPE race: `printf|grep -qxF` under pipefail was the same pattern as
# verify-sources.sh:214; grep exits early, printf takes SIGPIPE, the pipeline fails, and `!`
# inverts the failure to TRUE, falsely labelling a present hex as DRIFT. Measured: 45/50
# spurious exits at 1000 entries (8 KB) on this machine. The here-string has no producer
# process, so no SIGPIPE can fire regardless of palette size.
_block_hex_list="$(printf '%s\n' "${block_hexes[@]}")"
rc=0
for h in "${deliv_hexes[@]}"; do
  if ! grep -qxF -- "$h" <<< "$_block_hex_list"; then  # PARITY-CHECK
    echo "   DRIFT  $h present in the deliverable but in NO certified block value."
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo "   ok     every deliverable hex is present in the certified block palette (parity holds)."
else
  echo "          The deliverable has diverged from the block it claims to derive from — re-derive it"
  echo "          from the certified palette (or re-certify the block) before shipping the prototype."
fi

echo "== exit $rc =="
exit $rc
