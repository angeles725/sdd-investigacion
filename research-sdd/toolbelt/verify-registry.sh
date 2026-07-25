#!/usr/bin/env bash
# verify-registry.sh — living-mirror reconciler for the MASTER registry (KIT/TARGETS.md) vs REALITY.
#
# WHY: the per-corpus mirror is already linted (verify-state.sh: RESEARCH-STATE.md vs on-disk blocks),
# but the FLEET-WIDE master table in TARGETS.md drifts SILENTLY. Its Maturity column claims "N md" per
# target, and nothing recomputes that against the real corpus — e.g. the three.js row claimed "40 md"
# while the corpus held 44 blocks. research-sdd-archive.sh only PRINTS an unverified "refresh the row"
# reminder; it is CORPUS-scoped and never edits the kit. This closes that gap: it RECOMPUTES each row's
# block count from disk with the SAME canonical discriminator the rest of the toolbelt uses and WARNs on
# drift. It is the fleet analog of verify-state's per-corpus check.
#
# Mirror of the sweeps (sweep-retros.sh / sweep-audits.sh): reads the target list from TARGETS.md as
# backtick-wrapped absolute paths, DROPS truncated '...' paths and WARNs the sweep is PARTIAL.
#
# PROPOSE-NEVER-APPLY: WARN-only, READ-ONLY. It NEVER edits TARGETS.md or any corpus, and NEVER fails —
# exit is ALWAYS 0 (drift is surfaced for the human to reconcile, never auto-applied). This matches the
# archive reminder's contract ("archive is CORPUS-scoped; it never edits \$KIT/TARGETS.md").
#
# Usage: verify-registry.sh
# Exit: always 0 (WARN lines only). Env: RSDD_REGISTRY_TOL (default 2) — |claimed-real| must EXCEED this to WARN.
set -uo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS_MD="$KIT/TARGETS.md"

# Source the shared retro helper for retro_is_excluded so the §18 reachability check can
# filter excluded retros (WARN-only tool: a missing lib falls back to a no-op that never
# excludes, which may suppress the INFO for targets with only excluded retros — documented
# conservative fallback; verify-registry never aborts on a missing helper).
_vr_lib="$(cd "$(dirname "$0")" && pwd)/lib/retro-status.sh"
# shellcheck source=lib/retro-status.sh
[ -f "$_vr_lib" ] && . "$_vr_lib"
declare -F retro_is_excluded >/dev/null 2>&1 || retro_is_excluded() { return 1; }  # no-op fallback
unset _vr_lib

if [ ! -f "$TARGETS_MD" ]; then
  echo "verify-registry: cannot find $TARGETS_MD" >&2
  exit 0   # WARN-only contract: even a missing registry never fails the surfacing.
fi

# Tolerance: a small count drift is expected between a mid-run corpus and its last-committed row, so only
# a drift STRICTLY GREATER than this WARNs. Env-overridable for a stricter/looser fleet policy.
tol="${RSDD_REGISTRY_TOL:-2}"

# Absolute target paths live in the TARGETS.md table as backtick-wrapped paths (same derivation as the
# sweeps). Truncated ones (contain '...') can't be resolved to a real dir, so they're dropped — but
# COLLECT them so the summary can WARN that this reconcile is PARTIAL instead of reading complete.
all_paths=$(grep -oE '`/[^`]+`' "$TARGETS_MD" 2>/dev/null | tr -d '`' | sort -u)
paths=$(printf '%s\n' "$all_paths" | grep -v '\.\.\.')
skipped=$(printf '%s\n' "$all_paths" | grep '\.\.\.')

skipped_names=""; skipped_count=0
for s in $skipped; do
  [ -n "$s" ] || continue
  skipped_count=$((skipped_count + 1))
  skipped_names="${skipped_names:+$skipped_names, }$(basename "$s")"
done

# A single backtick, built without triggering command substitution, so we can grep for the EXACT
# backtick-wrapped path — the master-table row. (Per-target detail headers use the target NAME, not the
# backtick path, so a backtick path resolves to exactly one row.)
bt='`'

checked=0; drift=0; unresolved=0

for p in $paths; do
  [ -n "$p" ] || continue
  # The master-table row is the line carrying the EXACT backtick-wrapped path. Pull the FIRST such line.
  needle="${bt}${p}${bt}"
  row="$(grep -F -- "$needle" "$TARGETS_MD" 2>/dev/null | head -1)"

  # Claimed count: the Maturity column's leading "N md" (or "N blocks") token in that row.
  claimed="$(printf '%s' "$row" | grep -oiE '[0-9]+[[:space:]]*(md|blocks)\b' | head -1 | grep -oE '[0-9]+' | head -1)"

  # Non-directory backtick tokens are silently skipped, exactly like the sweeps ([ -d ] || continue):
  # the TARGETS.md table also carries non-path backtick tokens (e.g. the context7 library id
  # `/mrdoob/three.js` in the three.js row) that match the `/...` shape but are not corpora. Only the
  # truncated-'...' PARTIAL WARN reports "couldn't check"; a bare non-dir token is just not a corpus.
  [ -d "$p" ] || continue

  # NON-CORPUS SHORT-CIRCUIT: check for the 'nc' flag BEFORE the expensive state-finding find, so
  # nc-marked targets (tooling, doc, production app) never trigger a deep filesystem search.
  # Convention: 'N md' for nc rows counts root-level .md only (maxdepth 1 — package-manager-safe;
  # excludes .venv/node_modules without any hardcoded exclusion list). Targets WITHOUT the nc flag
  # and no RESEARCH-STATE still receive the 'not resolvable' WARN — the anti-blank-silencer guarantee
  # enforced by tests 6 and 13. '/ nc' is detected by the ERE below; the sentinel comment is the
  # mutation target for the --prove-teeth nc teeth test.
  if printf '%s' "$row" | grep -qE '/ nc[ /;)|]'; then  # NC-EXEMPT-CHECK
    name="$(basename "$p")"
    checked=$((checked + 1))
    # NC-CONTRADICTION CHECK: the nc flag asserts there is no corpus here. If a RESEARCH-STATE.md
    # is resolvable under the target, the assertion contradicts disk — flag it so the operator
    # can correct either the row (remove nc) or the repository layout. Uses the same find params
    # as the regular state resolver; the sentinel comment is the mutation target for teeth-nc-contradiction.
    _nc_state="$(find "$p" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
    if [ -n "$_nc_state" ] && [ -f "$_nc_state" ]; then  # NC-CONTRADICTION-CHECK
      echo "WARN  $name — row carries the nc flag but a RESEARCH-STATE.md was found at ${_nc_state}; remove nc if this is a real corpus target."
      unresolved=$((unresolved + 1))
      continue
    fi
    real="$(find "$p" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    if [ -z "$claimed" ]; then
      echo "WARN  $name — non-corpus (nc) target has no claimed 'N md' count in TARGETS.md row (real root-level: $real); add the count."
      unresolved=$((unresolved + 1))
    else
      d=$(( 10#${claimed:-0} - 10#${real:-0} )); [ "$d" -lt 0 ] && d=$(( -d ))
      if [ "$d" -gt "$tol" ]; then
        echo "WARN  $name — TARGETS.md row claims ${claimed} md but the non-corpus target has ${real} real .md file(s) at root (drift ${d} > tol ${tol}) — refresh the row."
        drift=$((drift + 1))
      fi
    fi
    continue
  fi

  # Resolve the corpus root EXACTLY like research-sdd-archive.sh / verify-state.sh: the shallowest
  # RESEARCH-STATE*.md under the target, deterministically. This transparently handles a flat corpus
  # (<path>/), a nested one (<path>/research/, e.g. three.js) or (<path>/corpus/) — the corpus is
  # wherever the state file lives, no per-layout guessing.
  state="$(find "$p" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
  if [ -z "$state" ] || [ ! -f "$state" ]; then
    echo "WARN  $p — corpus layout not resolvable (no RESEARCH-STATE*.md under target); cannot recount blocks."
    unresolved=$((unresolved + 1))
    continue
  fi
  corpus="$(dirname "$state")"

  # Count real block files with the CANONICAL discriminator (gen-catalog.py's BLOCK_RE == archive ==
  # verify-state): `<prefix>-(block|bloque)<N>[-suffix].md` at the corpus root. NOT a loose `*block*`
  # glob — a decoy like `blocked-notes.md` must not inflate the count. Single definition, no drift.
  real="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | wc -l | tr -d ' ')"

  # LOCAL-GENERATOR AUTHORITY (Feature #37): a target with its OWN catalog generator
  # (<corpus>/tools/gen-catalog.py) legitimately produces a CATALOG total that differs from the raw
  # canonical discriminator (niagara: CATALOG 239 vs discriminator 237 — the generator counts blocks the
  # flat root-glob does not, e.g. sub-series or nested block files). When that generator EXISTS and
  # CATALOG.md carries a "Total: N" (or "N bloques/blocks") line, trust THAT N as the authoritative real
  # count so a justified local total reconciles against its OWN authority instead of false-drifting.
  # Otherwise keep the canonical discriminator count. WARN-only/read-only is unchanged.
  cat_authority=""
  gen="$corpus/tools/gen-catalog.py"
  cat_md="$corpus/CATALOG.md"
  if [ -f "$gen" ] && [ -f "$cat_md" ]; then
    # A "Total: N" line first; else the first "N bloques/blocks" token anywhere in CATALOG.md.
    cat_total="$(grep -iE 'total' "$cat_md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    [ -n "$cat_total" ] || cat_total="$(grep -oiE '[0-9]+[[:space:]]*(bloques?|blocks?)' "$cat_md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    if [ -n "$cat_total" ]; then real="$cat_total"; cat_authority=" (CATALOG.md total via local gen-catalog.py)"; fi
  fi

  checked=$((checked + 1))
  name="$(basename "$p")"

  if [ -z "$claimed" ]; then
    echo "WARN  $name — no claimed '<N> md' count in its TARGETS.md row (real: $real blocks); add the count so it can be reconciled."
    unresolved=$((unresolved + 1))
    continue
  fi

  # Absolute drift. Force base-10 (10#) so a leading-zero claimed count (e.g. "08") is never
  # misparsed as octal by bash arithmetic, which would error/misdrift on 08/09.
  d=$(( 10#${claimed:-0} - 10#${real:-0} )); [ "$d" -lt 0 ] && d=$(( -d ))
  if [ "$d" -gt "$tol" ]; then
    echo "WARN  $name — TARGETS.md row claims ${claimed} md but the corpus has ${real} real block file(s)${cat_authority} (drift ${d} > tol ${tol}) — refresh the row (propose-never-apply; not auto-edited)."
    drift=$((drift + 1))
  fi

  # Reachability sanity: a corpus with blocks but NO §18 kit retros anywhere means the §18 feedback
  # loop can't be reached from this target. Advisory only (incipient targets legitimately have none)
  # — fires solely when the corpus actually advanced (real > tol) yet no non-excluded retro exists.
  # Files carrying '<!-- kit-retro: exclude -->' are not §18 kit retros and are filtered out, so a
  # target with ONLY excluded retros correctly fires this INFO.
  if [ "$real" -gt "$tol" ]; then
    _vr_has_kit_retro=0
    while IFS= read -r _vr_rf; do
      [ -n "$_vr_rf" ] || continue
      retro_is_excluded "$_vr_rf" && continue
      _vr_has_kit_retro=1; break
    done < <(find "$p" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' 2>/dev/null)
    if [ "$_vr_has_kit_retro" -eq 0 ]; then
      echo "INFO  $name — ${real} block(s) on disk but no retros/*.md reachable under the target (§18 feedback not wired)."
    fi
  fi
done

# --- Master-table ROW HYGIENE lint (WARN-only) --------------------------------------------------------
# CONVENTION (TARGETS.md legend): a master-table row is ONE scannable line per target
# (name · path · maturity · artifact · language). SKILL.md renders this table as the first-run
# target-picker, so an oversized cell (run-by-run narrative crammed into the master row) makes it
# unusable — that narrative belongs in the target's detail `###` section. This lints each master-table
# row's cells and WARNs when a single cell exceeds RSDD_ROW_MAXLEN (default 200). A master-table row is
# the only line whose FIRST cell is the numeric '#' column (`| N | ... |`); the header (`| # |`), the
# separator (`|---|`), and detail-section prose never match. PROPOSE-NEVER-APPLY: WARN-only, exit stays 0
# — the over-long content is human-tracked state and is the human's to collapse, never auto-edited.
row_max="${RSDD_ROW_MAXLEN:-200}"
rowlint=0
while IFS= read -r line; do
  [[ "$line" =~ ^\|[[:space:]]*[0-9]+[[:space:]]*\| ]] || continue
  # Report the FIRST cell exceeding the threshold; the 2nd cell (awk $3) is the target name label.
  reported="$(printf '%s' "$line" | awk -F'|' -v max="$row_max" '
    { name=$3; gsub(/^ +| +$/,"",name);
      for (i=2;i<=NF;i++){ c=$i; gsub(/^ +| +$/,"",c); if (length(c) > max){ print name "\t" length(c); exit } } }')"
  if [ -n "$reported" ]; then
    rname="${reported%%$'\t'*}"; rlen="${reported##*$'\t'}"
    echo "WARN  TARGETS row ${rname:-?} master cell is ${rlen} chars (> ${row_max}) — collapse to one line; narrative belongs in the detail section."
    rowlint=$((rowlint + 1))
  fi
done < "$TARGETS_MD"

echo ""
echo "Summary: reconciled ${checked} target(s) · ${drift} count drift(s) · ${unresolved} unresolvable · ${rowlint} oversized row(s)."
if [ "$skipped_count" -gt 0 ]; then
  echo "WARN: ${skipped_count} target(s) skipped — truncated/unresolvable path in TARGETS.md; this reconcile is PARTIAL: ${skipped_names}"
fi
if [ "$drift" -eq 0 ] && [ "$unresolved" -eq 0 ]; then
  echo "Registry consistent with reality (within tolerance ${tol})."
else
  echo "For each drift: recount the corpus and refresh that target's 'N md' in \$KIT/TARGETS.md by hand (WARN-only; never auto-edited)."
fi

# WARN-only contract: NEVER signal failure. A drift is a surfaced advisory, not an error.
exit 0
