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
#       source (fabricated citation, LEVEL 4), or a web-snapshot on disk is not registered in SOURCES.md
#       (LEVEL 5) · 2 = bad args.

set -uo pipefail
target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-sources.sh <target-dir>" >&2; exit 2; }
# Resolve the CORPUS ROOT: blocks/sources may live at the target root OR in a subdir (e.g. corpus/,
# as pruebas-dashboards does). PREFER the target root when it directly holds blocks; only descend when
# it has none. When descending, pick the SHALLOWEST match deterministically (depth, then lexical) —
# never rely on find's traversal order, since a flat target (e.g. niagara-research) also has
# notes/bloque*.md that must NOT hijack the corpus root.
corpus="$target"
if ! find "$target" -maxdepth 1 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) -not -name '*.template.md' 2>/dev/null | grep -q .; then
  anchor="$(find "$target" -maxdepth 3 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null \
            | awk '{print gsub(/\//,"/") "\t" $0}' | sort -t"$(printf '\t')" -k1,1n -k2,2 | head -1 | cut -f2-)"
  [ -n "$anchor" ] && corpus="$(dirname "$anchor")"
fi
sources_md="$corpus/sources/SOURCES.md"
rc=0
echo "== verify-sources: $(basename "$target") =="
[ "$corpus" != "$target" ] && echo "-- corpus root: ${corpus#"$target"/}/ (blocks in a subdir)"

# How many blocks lean on a PRESERVED source? ([CERT-web] shown for context; §5 only forces preservation
# for [CERT-doc]/[CERT-a] and for LOAD-BEARING [CERT-web]-via-MCP. The MCP-specific "was this snapshotted?"
# self-report stays in the §11 in-iteration check — it is not mechanizable here (no signal distinguishes an
# MCP citation from a plain web-fetch). LEVEL 5 below instead mechanizes the WEAKER, verifiable-today
# web-snapshot INTEGRITY invariant: every snapshot on disk is registered + cited. It does NOT detect MCP.)
# count_marker <marker> — how many block files USE the marker in their BODY (not the header legend). EVERY
# block opens with a blockquote LEGEND that DEFINES these markers (`> [CERT-a] = asserted by a source; …`), so a
# bare `grep -lF` counts the legend as a citation and a legend-only corpus with no SOURCES.md FALSE-FAILS LEVEL
# 1. Reuse verify-block.sh's positional legend-strip (see verify-block.sh §1): the legend is the leading `>`
# blockquote whose closing bare `---` fence sits AFTER the blockquote and BEFORE the first `## ` body section —
# count the marker only in what follows. If no such fence closes the header, fall back to the whole file
# (unfenced legend can't be isolated → never silently zero a real citation).
count_marker() {
  local marker="$1" n=0 f fence body
  for f in "$corpus"/*.md; do
    [ -f "$f" ] || continue
    fence=$(awk '/^##[[:space:]]/{exit} q && /^---[[:space:]]*$/{print NR; exit} /^[[:space:]]*>/{q=1}' "$f")
    if [ -n "$fence" ]; then
      body="$(awk -v n="$fence" 'NR>n' "$f")"   # LEGEND-STRIP: count markers only after the header-legend fence
    else
      body="$(cat "$f")"                         # no leading-blockquote fence → can't isolate the legend
    fi
    printf '%s' "$body" | grep -qF "$marker" && n=$((n + 1))
  done
  printf '%s' "$n"
}
doc=$(count_marker '[CERT-doc]')
a=$(count_marker '[CERT-a]')
web=$(count_marker '[CERT-web]')
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
  # MALFORMED-ROW pre-check — §7 false-negative direction. SCOPED TO THE REGISTRY TABLE:
  # SOURCES.md may contain multiple tables (secondary local-file inventories, etc.). The pre-check
  # locates the FIRST table block that contains a "sha256" header cell (the registry marker in the
  # 6-col template) and checks ONLY that block. Secondary tables after a non-table line are never
  # reached. Two severity paths are distinguished (neither exits with rc=1 — both are §8 findings):
  #   Schema non-conforming (registry header column count != 6): ONE WARN per file. Every data row
  #     under that header is internally consistent with it, so per-row WARNs would be noise.
  #   Conforming header + disagreeing row: per-row WARN with original SOURCES.md line number.
  # L4/L6/D2 loops are also anchored to the registry block via process substitution (see below).
  awk -F'|' '
    !in_reg && /^\|/ && / sha256 / { in_reg=1; reg_nf=NF
      if (NF!=8) { printf "   WARN: SOURCES.md registry header has %d columns (expected 6 per template); schema non-conforming (data rows not individually checked)\n", NF-2; bad_schema=1 }
      next }
    in_reg && !/^\|/ { in_reg=0; next }   # REGISTRY-BLOCK-EXIT
    in_reg && $2~/^[- :]+$/ { next }
    in_reg && !bad_schema && NF!=reg_nf {
      printf "   WARN: SOURCES.md line %d — malformed row (got %d columns, expected 6); sha256/Blocks cells untrustworthy — fix the registry\n", NR, NF-2 }
  ' "$sources_md"
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
  while IFS= read -r _row; do
    pipes="${_row//[^|]/}"; [ "${#pipes}" -ne 7 ] && continue   # L4-FIELD-GUARD: skip malformed rows (registry-block scope)
    IFS='|' read -r _ fcell _ _ _ _ bcell _ <<< "$_row"
    file=$(printf '%s' "$fcell" | tr -d '[:blank:]')   # strip space AND tab: a tab-padded File cell must not spoof a FABRICATED-CITE
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
      # B4 FIX: in a multi-focus corpus, several *block${n}.md files may match (one per focus). The old
      # `head -1` picked one arbitrarily and false-FAILed when the wrong focus's file was chosen. Check ALL
      # matching files: the citation is valid if ANY focus's block${n}.md references the source.
      mapfile -t _bfs < <(find "$corpus" -maxdepth 1 -type f \( -iname "*block${n}.md" -o -iname "*bloque${n}.md" \) 2>/dev/null)
      if [ "${#_bfs[@]}" -eq 0 ]; then
        echo "   WARN: SOURCES.md names B$n for '$base', but no *block${n}.md/*bloque${n}.md resolves (naming mismatch — not checked)."
      else
        _cited_ok=0
        for _bf in "${_bfs[@]}"; do grep -qF "$base" "$_bf" && { _cited_ok=1; break; }; done
        if [ "$_cited_ok" -eq 0 ]; then
          echo "   FABRICATED-CITE: SOURCES.md claims B$n cites '$base', but none of ${#_bfs[@]} *block${n}.md file(s) reference it."
          rc=1
        fi
      fi
    done
  done < <(awk '/^\|/&&/ sha256 /{r=1} r&&/^\|/{print} r&&!/^\|/{r=0}' "$sources_md" 2>/dev/null)
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

# LEVEL 5 — web-snapshot INTEGRITY. Lives OUTSIDE the `[ -f "$sources_md" ]` block on purpose: it must also
# fire the "web-snapshots/ populated but SOURCES.md missing" case (every snapshot is then an orphan).
# WHY THIS IS HARDER THAN LEVEL 2b (which only warns for a stray .pdf/.html): a web-snapshot file carries NO
# embedded provenance — its origin URL, fetch date, and sha256 live ONLY in the SOURCES.md row (verified: the
# snapshot files are raw fetched content, e.g. an html <div>… body, with no header). So an UNREGISTERED
# snapshot is evidence with a BROKEN chain of custody — you can no longer say where it came from or prove it
# was not tampered with. A .pdf is self-identifying; a headerless snapshot is not. That is why registration
# is a FAIL (rc=1) here, while a merely-uncited (but registered) snapshot is only a WARN.
#
# The canonical KEY for a snapshot is its path relative to sources/ (e.g. `web-snapshots/x.md`, possibly with
# subdirs). That is exactly what the SOURCES.md `File` column holds and what blocks cite as `sources/<key>`.
# Match on that full relpath, NEVER on a bare basename: a basename SUBSTRING test false-passes a real orphan
# `report.md` against a registered `annual-report.md`, and false-flags a correctly-cited nested snapshot.
snaps=0
# Registered File-column values (parsed like LEVEL 4: split rows on '|', take the File cell, strip ALL
# horizontal whitespace — space AND tab — plus backticks, drop header/separator rows). Stripping tabs matters:
# a hand-edited SOURCES.md that pads the cell with tabs would otherwise make a REGISTERED snapshot report as an
# orphan (a false positive in a fail-closed, archive-blocking gate). Missing SOURCES.md ⇒ empty set ⇒ orphans.
registered=""
if [ -f "$sources_md" ]; then
  registered="$(awk -F'|' '/^\|/ { v=$2; gsub(/[`[:blank:]]/,"",v); if (v!="" && v!="File" && v !~ /^[-:]+$/) print v }' "$sources_md")"
fi
# Elided citations present in blocks: capture the <tail> after `web-snapshots/...`. The kit writes display-only
# elided paths (LEVEL 3 excludes them too); a snapshot counts as ELIDED-cited iff its real name ends with <tail>.
elided_tails="$(grep -rhoE 'web-snapshots/\.\.\.[^ )`]+' "$corpus"/*.md 2>/dev/null | sed 's#web-snapshots/\.\.\.##' | sort -u)"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  snaps=$((snaps + 1))
  rel="${f#"$corpus"/sources/}"   # canonical key, e.g. web-snapshots/example.com/page.md
  rel="${rel#"${rel%%[![:blank:]]*}"}"; rel="${rel%"${rel##*[![:blank:]]}"}"   # trim leading/trailing blanks
  base="$(basename "$f")"
  # Registration (HARD): rel must EXACTLY equal a registered File-column value — not a substring.
  if ! printf '%s\n' "$registered" | grep -qxF "$rel"; then
    echo "   orphan-snapshot: ${f#"$corpus"/} (in web-snapshots/ but not registered in SOURCES.md — provenance lost)"
    rc=1
    continue
  fi
  # Citation (SOFT, WARN only). EXACT-cited iff a block contains the literal full relpath (the `sources/` prefix
  # is optional — a block citing `sources/web-snapshots/x` contains `web-snapshots/x`).
  grep -rlF "$rel" "$corpus"/*.md >/dev/null 2>&1 && continue
  # ELIDED-cited iff a block cites `web-snapshots/...<tail>` and the real name ends with <tail> (elision-tolerant).
  # Reject DEGENERATE tails first: a stray `web-snapshots/...md` or a 4-dot typo `web-snapshots/....md`
  # (captured tail `.md`) would end-match essentially every snapshot and silently kill the uncited WARN
  # corpus-wide. Require a real filename tail — after stripping leading dots, `<name>.<ext>` with NON-EMPTY name.
  cited_elided=0
  while IFS= read -r tail; do
    [ -z "$tail" ] && continue
    t="${tail#"${tail%%[!.]*}"}"                  # strip leading dots (`.md`→`md`, `....md`→`md` after prior strip)
    case "$t" in *.*) ;; *) continue;; esac       # must contain a dot (name.ext)
    [ -z "${t%.*}" ] && continue                  # name before the final dot must be non-empty
    case "$base" in *"$tail") cited_elided=1; break;; esac
    case "$rel"  in *"$tail") cited_elided=1; break;; esac
  done <<EOF
$elided_tails
EOF
  [ "$cited_elided" = 1 ] && continue
  echo "   uncited-snapshot: ${f#"$corpus"/} (registered but no block references it — dead weight?)"
done < <(find "$corpus/sources/web-snapshots" -type f 2>/dev/null)
[ "$snaps" -gt 0 ] && echo "-- web-snapshots: $snaps file(s) checked (registration = FAIL if orphaned, citation = WARN)"

# LEVEL 6 — web-snapshot HASH integrity. LEVEL 5 proves a snapshot is REGISTERED + CITED (chain of custody), but
# never RECOMPUTES the sha256 the registry stores against the file on disk — so the hash fetch-doc.sh collects is
# dead weight and a tampered/corrupted snapshot passes silently ("provenance-hash theatre"). This makes the
# registered hash LOAD-BEARING: for each REGISTERED web-snapshot row, recompute sha256sum of the on-disk file and
# compare against the registered cell (column 5). Only REGISTERED rows are checked — an on-disk snapshot that is
# NOT registered is already LEVEL 5's orphan FAIL and must NOT be double-reported here.
#   FULL 64-hex registered hash → recompute + compare; a MISMATCH is a FAIL (rc=1), like a broken chain.
#   HEX PREFIX + `…` elision (e.g. `04adf2b071e479b2…`) → verify by PREFIX: recompute and check the disk
#     hash starts with the registered prefix (case-insensitive). Mismatch → FAIL. Prefix < MIN_PREFIX hex
#     chars → WEAK/unverifiable WARN. A 7-char prefix has only 28 bits of entropy, meaning birthday collisions
#     at corpus scale; MIN_PREFIX = 8 (32 bits, ~1-in-4B per file) is the practical minimum.
#   MISSING / placeholder `(unhashed…)` → WARN only: integrity is un-checkable, but hard-failing every
#     existing corpus is worse than surfacing the debt.
#   sha256sum unavailable → explicit notice; never a silent clean pass over unverified snapshots.
#   Parse the File cell like LEVEL 4/5 (strip backtick + ALL blanks); canonical key = path relative to sources/.
MIN_PREFIX=8
if [ -f "$sources_md" ] && command -v sha256sum >/dev/null 2>&1; then
  hverified=0; hunverif=0
  while IFS= read -r _raw; do
    pipes="${_raw//[^|]/}"; [ "${#pipes}" -ne 7 ] && continue   # L6-FIELD-GUARD: skip malformed rows (registry-block scope)
    IFS='|' read -r _ fcell _ _ _ shacell _ <<< "$_raw"
    key=$(printf '%s' "$fcell" | tr -d '`[:blank:]')
    case "$key" in web-snapshots/*) ;; *) continue;; esac   # only web-snapshot rows
    file="$corpus/sources/$key"
    [ -f "$file" ] || continue   # registered but absent on disk is out of scope here (not an integrity mismatch)
    reg=$(printf '%s' "$shacell" | tr -d '`[:blank:]')
    if printf '%s' "$reg" | grep -qiE '^[0-9a-f]{64}$'; then
      reg_full=$(printf '%s' "$reg" | tr 'A-F' 'a-f')                 # normalize case for the compare
      disk_full=$(sha256sum "$file" | cut -d' ' -f1)
      if [ "$reg_full" != "$disk_full" ]; then   # HASH-INTEGRITY compare
        echo "   hash-mismatch: ${file#"$corpus"/} — registered ${reg_full:0:16}… but file hashes ${disk_full:0:16}… (tampered/corrupted or stale registration)"
        rc=1
      else
        hverified=$((hverified + 1))
      fi
    else
      # Not a full 64-hex. Distinguish empty/placeholder (unverifiable), valid prefix (checkable by prefix),
      # and too-short or non-hex (weak/unverifiable).
      case "$reg" in
        '' | '('*)
          echo "   unverifiable-hash: ${file#"$corpus"/} — registered hash is missing; integrity not checkable"
          hunverif=$((hunverif + 1))
          ;;
        *)
          # Strip trailing ellipsis (Unicode … or ASCII ...) and spaces to extract the raw hex prefix.
          pfx="${reg%%…*}"; pfx="${pfx%%[.][.][.]*}"; pfx="$(printf '%s' "$pfx" | tr -d '[:space:]')"
          pfx_lower="$(printf '%s' "$pfx" | tr 'A-F' 'a-f')"
          if printf '%s' "$pfx_lower" | grep -qE '^[0-9a-f]+$' && [ "${#pfx_lower}" -ge "$MIN_PREFIX" ]; then
            disk_pfx="$(sha256sum "$file" | cut -d' ' -f1 | cut -c1-"${#pfx_lower}")"   # PREFIX-COMPARISON compare
            if [ "$pfx_lower" = "$disk_pfx" ]; then
              hverified=$((hverified + 1))
            else
              echo "   prefix-mismatch: ${file#"$corpus"/} — registered prefix ${pfx_lower}… but file hashes ${disk_pfx}… (tampered or stale registration)"
              rc=1
            fi
          else
            echo "   unverifiable-hash: ${file#"$corpus"/} — registered hash is truncated (prefix ${#pfx} chars < $MIN_PREFIX; too short to verify)"
            hunverif=$((hunverif + 1))
          fi
          ;;
      esac
    fi
  done < <(awk '/^\|/&&/ sha256 /{r=1} r&&/^\|/{print} r&&!/^\|/{r=0}' "$sources_md" 2>/dev/null)
  [ $((hverified + hunverif)) -gt 0 ] && \
    echo "-- web-snapshot hashes: $hverified verified · $hunverif unverifiable (missing/short-prefix = WARN)"
elif [ -f "$sources_md" ] && grep -qE '^\| web-snapshots/' "$sources_md" 2>/dev/null; then
  echo "-- web-snapshot hashes: sha256sum not found — hash integrity cannot be checked (WARN)"
fi

# DEFECT-2 VISIBILITY — §7: a count of 0 that collapses "no non-web-snapshot rows with hashes"
# and "N rows present but not checked" is the bug. LEVEL 6 covers web-snapshots/ only; datasheets/,
# manuals/, extracted/, and other subdirs may carry hash-like cells that are never verified. Count
# those rows (6-col, file on disk, starts with a hex char) so the operator sees the uncovered surface.
# Scope is intentionally NOT widened: a fleet scan found 4 would-be FAIL rows across active corpora
# (gateway-ug67, impresora-samsung-m2070, niagara-research, pruebas-dashboards); widening would cause
# disruptive rc=1 regressions. Making the gap visible is the safe, correct action here.
if [ -f "$sources_md" ]; then
  _nskip=0
  while IFS= read -r _raw; do
    pipes="${_raw//[^|]/}"; [ "${#pipes}" -ne 7 ] && continue   # skip malformed rows (registry-block scope)
    IFS='|' read -r _ fcell _ _ _ shacell _ <<< "$_raw"
    key=$(printf '%s' "$fcell" | tr -d '`[:blank:]')
    case "$key" in ''|File|*---*|web-snapshots/*) continue;; esac   # skip header, separator, web-snap
    [ -f "$corpus/sources/$key" ] || continue                       # file not on disk — nothing to verify
    reg=$(printf '%s' "$shacell" | tr -d '`[:blank:]')
    case "$reg" in ''|'('*) continue;; esac                         # empty or placeholder
    printf '%s' "$reg" | grep -qiE '^[0-9a-f]' || continue          # not hex-looking
    _nskip=$((_nskip + 1))
  done < <(awk '/^\|/&&/ sha256 /{r=1} r&&/^\|/{print} r&&!/^\|/{r=0}' "$sources_md" 2>/dev/null)
  [ "$_nskip" -gt 0 ] && \
    echo "-- non-web-snapshot rows with on-disk files and hashes: $_nskip not hash-verified (LEVEL 6 covers web-snapshots/ only)"
fi

echo "== exit $rc =="
exit $rc
