#!/usr/bin/env bash
# verify-sources.sh — SOURCES.md preservation linter for a Research-SDD corpus (METHODOLOGY §5).
#
# §5's golden rule: if a claim leans on a datasheet / manual / forum / link, the document is DOWNLOADED,
# PRESERVED, and REGISTERED in sources/SOURCES.md with a sha256 — "URLs die; evidence does not". This linter
# checks a corpus actually did it, instead of trusting convention (lesson: logosoft cited [CERT-doc] PDFs
# with NO SOURCES.md at all). Run it at loop STOP or during a supervised review — it reads the whole corpus.
#
# Usage: verify-sources.sh <target-dir>
# Exit: 0 = ok · 1 = preserved-source markers exist but SOURCES.md is missing, or a cited sources/ file is
#       absent on disk · 2 = bad args.

set -uo pipefail
target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-sources.sh <target-dir>" >&2; exit 2; }
sources_md="$target/sources/SOURCES.md"
rc=0
echo "== verify-sources: $(basename "$target") =="

# How many blocks lean on a PRESERVED source? ([CERT-web] shown for context; §5 only forces preservation
# for [CERT-doc]/[CERT-a] and for LOAD-BEARING [CERT-web]-via-MCP, which the §11 snapshot check covers.)
doc=$(grep -rlF '[CERT-doc]' "$target"/*.md 2>/dev/null | wc -l | tr -d ' ')
a=$(grep -rlF '[CERT-a]'   "$target"/*.md 2>/dev/null | wc -l | tr -d ' ')
web=$(grep -rlF '[CERT-web]' "$target"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "-- blocks citing preserved-source markers: [CERT-doc] $doc · [CERT-a] $a · [CERT-web] $web"

# LEVEL 1 — preserved-source markers demand a registry. This is the logosoft case.
if [ $((doc + a)) -gt 0 ] && [ ! -f "$sources_md" ]; then
  echo "   FAIL: $((doc + a)) block(s) cite [CERT-doc]/[CERT-a] but $sources_md is MISSING."
  echo "         §5: preserved sources MUST be registered (file · type · origin · date · sha256 · blocks)."
  rc=1
fi

if [ -f "$sources_md" ]; then
  # LEVEL 2 — the registry has real DATA rows, not just header/separator. (sha256 is often TRUNCATED in the
  # display, e.g. three.js '04adf2b…', so count populated table rows rather than full 64-hex hashes.)
  rows=$(grep -E '^\| ' "$sources_md" 2>/dev/null | grep -vcE '^\| *File|^\|[-:| ]+$' || true)
  echo "-- SOURCES.md present · registered data rows: ${rows:-0}"
  if [ $((doc + a)) -gt 0 ] && [ "${rows:-0}" -eq 0 ]; then
    echo "   WARN: preserved-source markers exist but SOURCES.md has 0 data rows (registry unpopulated)."
  fi
  # LEVEL 2b — preserved files on disk that are NOT named in the registry.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    grep -qF "$(basename "$f")" "$sources_md" || echo "   unregistered on disk: ${f#"$target"/} (not named in SOURCES.md)"
  done < <(find "$target/sources" -type f \( -name '*.pdf' -o -name '*.html' -o -name '*.htm' \) 2>/dev/null)
fi

# LEVEL 3 — sources/ paths cited in blocks must exist on disk.
missing=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  [ -f "$target/$ref" ] || { echo "   cited-but-missing: $ref"; missing=1; rc=1; }
done < <(grep -rhoE 'sources/[A-Za-z0-9_./-]+\.(pdf|md|html|htm|txt|json)' "$target"/*.md 2>/dev/null \
           | grep -vF '...' | grep -vF 'SOURCES.md' | sort -u)
[ "$missing" = 0 ] && echo "-- all sources/ paths cited in blocks exist on disk (or none cited)"

echo "== exit $rc =="
exit $rc
