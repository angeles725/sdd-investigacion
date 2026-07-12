#!/usr/bin/env bash
# discriminator-parity.test.sh — pins the TWO intentional block-file discriminators so they can't silently
# drift into each other. The "what is a block file" definition was forked once already (a loose *block* glob
# vs the strict canonical regex); this mechanizes the boundary instead of trusting comments.
#
# FAMILY 1 — STRICT CANONICAL (counts / STOP / catalog / parity): `<prefix>-(block|bloque)<N>[-suffix].md`,
#   case-sensitive, mirroring gen-catalog.py BLOCK_RE. Must be BYTE-IDENTICAL everywhere it appears.
#   Sites: verify-state.sh, research-sdd-status.sh (x2), research-sdd-archive.sh, verify-parity.sh.
#   (gen-catalog.py's Python BLOCK_RE is cross-checked separately by gen-catalog.test.sh.)
# FAMILY 2 — LOOSE DETECTION (is-this-a-corpus anchor): case-insensitive `*block*.md`/`*bloque*.md`. Over-
#   inclusion is SAFE for a mere "does a block-ish file exist here" anchor (it never misses a bespoke
#   non-numbered block), so this predicate is INTENTIONAL and allowlisted to EXACTLY two scripts. It must
#   NEVER appear in a count/parity script — that is the re-fork this test exists to catch.
#
# Usage: discriminator-parity.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$(cd "$HERE/.." && pwd)"
[ -d "$TB" ] || { echo "FATAL: toolbelt dir not found: $TB" >&2; exit 2; }
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== discriminator-parity.test.sh =="

# The exact canonical regex literal (grepped as a fixed string, so a single char change is caught).
STRICT='/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'
# The loose detection-glob signature (ERE): `-iname '*block*.md'`.
LOOSE_RE="iname '\*block\*\.md'"
ALLOW="verify-sources.sh scan-secrets.sh"   # the only scripts allowed to carry the loose glob

# 1 — every STRICT-family script carries the exact canonical regex (byte-identical, no drift).
strict_family=(verify-state.sh research-sdd-status.sh research-sdd-archive.sh verify-parity.sh)
missing=""
for s in "${strict_family[@]}"; do
  [ -f "$TB/$s" ] || { missing="$missing $s(absent)"; continue; }
  grep -qF "$STRICT" "$TB/$s" || missing="$missing $s"
done
[ -z "$missing" ] && ok "strict discriminator byte-identical across all count/parity sites" \
  || no "strict discriminator missing/drifted in:$missing"

# helper: list basenames of toolbelt *.sh (maxdepth 1) carrying the loose glob but NOT allowlisted.
loose_offenders() {
  local dir="$1" f b out=""
  while IFS= read -r f; do
    b="$(basename "$f")"
    grep -qE "$LOOSE_RE" "$f" || continue
    case " $ALLOW " in *" $b "*) ;; *) out="$out $b";; esac
  done < <(find "$dir" -maxdepth 1 -name '*.sh' 2>/dev/null | sort)
  printf '%s' "$out"
}

# 2 — the loose detection glob appears ONLY in the two allowlisted anchor scripts.
off="$(loose_offenders "$TB")"
[ -z "$off" ] && ok "loose detection glob confined to the allowlisted anchors ($ALLOW)" \
  || no "loose glob leaked into a non-anchor script:$off"

# ================================ NEGATIVE CONTROL — teeth ==========================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: inject the loose glob into a count-family script; check 2 must flag it --"
  tmp="$(mktemp -d)"; cp "$TB"/*.sh "$tmp/" 2>/dev/null
  printf "\n# mutant: find x \\( -iname '*block*.md' \\)\n" >> "$tmp/verify-state.sh"
  moff="$(loose_offenders "$tmp")"
  printf '%s' "$moff" | grep -q 'verify-state.sh' \
    && ok "teeth: loose glob injected into verify-state.sh is caught (allowlist has teeth)" \
    || no "teeth: mutant NOT caught — the allowlist check is theater [$moff]"
  rm -rf "$tmp"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
