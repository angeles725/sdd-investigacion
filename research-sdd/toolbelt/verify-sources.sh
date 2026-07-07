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
#       absent on disk, or a block NAMED in the registry's "cite it" column does not actually reference the
#       source (fabricated citation, LEVEL 4) · 2 = bad args.

set -uo pipefail
target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-sources.sh <target-dir>" >&2; exit 2; }
# Resolve the CORPUS ROOT: blocks/sources may live at the target root OR in a subdir (e.g. corpus/,
# as pruebas-dashboards does). PREFER the target root when it directly holds blocks; only descend when
# it has none. When descending, pick the SHALLOWEST match deterministically (depth, then lexical) —
# never rely on find's traversal order, since a flat target (e.g. niagara-research) also has
# notes/bloque*.md that must NOT hijack the corpus root.
corpus="$target"
if ! find "$target" -maxdepth 1 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) 2>/dev/null | grep -q .; then
  anchor="$(find "$target" -maxdepth 3 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) -not -path '*/.git/*' 2>/dev/null \
            | awk '{print gsub(/\//,"/") "\t" $0}' | sort -t"$(printf '\t')" -k1,1n -k2,2 | head -1 | cut -f2-)"
  [ -n "$anchor" ] && corpus="$(dirname "$anchor")"
fi
sources_md="$corpus/sources/SOURCES.md"
rc=0
echo "== verify-sources: $(basename "$target") =="
[ "$corpus" != "$target" ] && echo "-- corpus root: ${corpus#"$target"/}/ (blocks in a subdir)"

# How many blocks lean on a PRESERVED source? ([CERT-web] shown for context; §5 only forces preservation
# for [CERT-doc]/[CERT-a] and for LOAD-BEARING [CERT-web]-via-MCP, which the §11 snapshot check covers.)
doc=$(grep -rlF '[CERT-doc]' "$corpus"/*.md 2>/dev/null | wc -l | tr -d ' ')
a=$(grep -rlF '[CERT-a]'   "$corpus"/*.md 2>/dev/null | wc -l | tr -d ' ')
web=$(grep -rlF '[CERT-web]' "$corpus"/*.md 2>/dev/null | wc -l | tr -d ' ')
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
    grep -qF "$(basename "$f")" "$sources_md" || echo "   unregistered on disk: ${f#"$corpus"/} (not named in SOURCES.md)"
  done < <(find "$corpus/sources" -type f \( -name '*.pdf' -o -name '*.html' -o -name '*.htm' \) 2>/dev/null)

  # LEVEL 4 — the "Blocks that cite it" column must not FABRICATE citations: every block a registry row
  # NAMES must actually reference that source file. LEVELs 1-3 check the registry exists, is populated, and
  # its files are present — NONE cross-checks the last column against block CONTENT, so a made-up
  # "B55, B57 cite this" cell passes silently (real lesson: a logosoft row claimed two blocks cited a
  # preserved HTML they never mention — the [CERT-a] token in those blocks was legend boilerplate, not a
  # citation). This is the content cross-check. Parses both `B60` and `[Block 21]`/`Bloque 7`; empty and
  # em-dash cells yield no block and are skipped. Positive miss ⇒ FAIL; unresolvable block name ⇒ WARN only.
  cited=0
  while IFS='|' read -r _ fcell _ _ _ _ bcell _; do
    file=$(printf '%s' "$fcell" | tr -d ' ')
    file=${file//\`/}          # strip markdown code backticks so the basename greps cleanly
    [ -z "$file" ] && continue
    case "$file" in File|*---*) continue;; esac
    base=$(basename "$file")
    # drop free-form parenthetical notes first — an incidental "B12" inside a note (e.g. "(cross-ref vs B12)")
    # is prose, not a cited block, and must not be mistaken for one. (An unparenthesized stray "B12" in the
    # cell would still over-match, but parentheses are the observed note convention across corpora.)
    bcell=$(printf '%s' "$bcell" | sed 's/([^)]*)//g')
    for n in $(printf '%s' "$bcell" | grep -oiE '\bB(lock|loque)? ?[0-9]+' | grep -oE '[0-9]+' | sort -un); do
      cited=$((cited + 1))
      bf=$(find "$corpus" -maxdepth 1 -type f \( -iname "*block${n}.md" -o -iname "*bloque${n}.md" \) 2>/dev/null | head -1)
      if [ -z "$bf" ]; then
        echo "   WARN: SOURCES.md names B$n for '$base', but no *block${n}.md/*bloque${n}.md resolves (naming mismatch — not checked)."
      elif ! grep -qF "$base" "$bf"; then
        echo "   FABRICATED-CITE: SOURCES.md claims B$n cites '$base', but $(basename "$bf") never references it."
        rc=1
      fi
    done
  done < "$sources_md"
  [ "$cited" -gt 0 ] && echo "-- cross-checked $cited registry→block citation claim(s) against block content"
fi

# LEVEL 3 — sources/ paths cited in blocks must exist on disk.
missing=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  [ -f "$corpus/$ref" ] || { echo "   cited-but-missing: $ref"; missing=1; rc=1; }
done < <(grep -rhoE 'sources/[A-Za-z0-9_./-]+\.(pdf|md|html|htm|txt|json)' "$corpus"/*.md 2>/dev/null \
           | grep -vF '...' | grep -vF 'SOURCES.md' | sort -u)
[ "$missing" = 0 ] && echo "-- all sources/ paths cited in blocks exist on disk (or none cited)"

echo "== exit $rc =="
exit $rc
