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
#   MISSING / placeholder `(unhashed…)` / TRUNCATED (fetch-doc.sh itself writes `${sha:0:16}…`, and legacy
#     corpora truncate) → WARN only, never a FAIL: integrity is un-checkable, but hard-failing every existing
#     corpus is worse than surfacing the debt. Parse the File cell like LEVEL 4/5 (strip backtick + ALL blanks)
#     so a tab-padded or code-fenced cell still maps; the canonical key is the path relative to sources/.
if [ -f "$sources_md" ] && command -v sha256sum >/dev/null 2>&1; then
  hverified=0; hunverif=0
  while IFS='|' read -r _ fcell _ _ _ shacell _; do
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
      # Un-checkable registration: empty or a `(…)` placeholder is MISSING; anything else (a short hex prefix, or
      # a `…`/`...`-elided hash) is TRUNCATED. Either way WARN only — never change rc.
      case "$reg" in
        '' | '('*) reason=missing ;;
        *)         reason=truncated ;;
      esac
      echo "   unverifiable-hash: ${file#"$corpus"/} — registered hash is $reason; integrity not checkable"
      hunverif=$((hunverif + 1))
    fi
  done < "$sources_md"
  [ $((hverified + hunverif)) -gt 0 ] && \
    echo "-- web-snapshot hashes: $hverified verified · $hunverif unverifiable (missing/truncated registration = WARN)"
fi

echo "== exit $rc =="
exit $rc
