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

# Shared target-path derivation (handles /abs and $RESEARCH_HOME/... forms).
# WARN-only contract: a missing or broken lib is still a loud signal, but exits 0 like all
# other operational notices in this script. A missing lib before the TARGETS.md check is the
# only case where target_paths_all can't be defined; callers get the clear error message.
_vr_tp_lib="$(cd "$(dirname "$0")" && pwd)/lib/target-paths.sh"
if [ ! -f "$_vr_tp_lib" ]; then
  echo "verify-registry: cannot find helper $_vr_tp_lib" >&2; exit 0
fi
# shellcheck source=lib/target-paths.sh
. "$_vr_tp_lib"
# Fail closed: source must DEFINE both functions — a partial source is otherwise swallowed.
declare -F target_paths_all >/dev/null 2>&1 || { echo "verify-registry: helper $_vr_tp_lib failed to define target_paths_all" >&2; exit 0; }
declare -F target_paths_pairs >/dev/null 2>&1 || { echo "verify-registry: helper $_vr_tp_lib failed to define target_paths_pairs" >&2; exit 0; }
unset _vr_tp_lib

if [ ! -f "$TARGETS_MD" ]; then
  echo "verify-registry: cannot find $TARGETS_MD" >&2
  exit 0   # WARN-only contract: even a missing registry never fails the surfacing.
fi

# Tolerance: a small count drift is expected between a mid-run corpus and its last-committed row, so only
# a drift STRICTLY GREATER than this WARNs. Env-overridable for a stricter/looser fleet policy.
tol="${RSDD_REGISTRY_TOL:-2}"

# Absolute target paths live in the TARGETS.md table as backtick-wrapped paths (same derivation as the
# sweeps). target_paths_pairs emits "<raw>\t<expanded>" per entry so we can use the expanded path for
# all filesystem operations while recovering the raw (as-written) token for row lookup — needed when
# TARGETS.md stores `$RESEARCH_HOME/...` forms that do not match an expanded-path needle.
# Truncated '...' entries pass through so the summary can WARN this reconcile is PARTIAL.
all_pairs=$(target_paths_pairs "$TARGETS_MD")
paths=$(printf '%s\n' "$all_pairs" | awk -F'\t' '{print $2}' | grep -v '\.\.\.')
skipped=$(printf '%s\n' "$all_pairs" | awk -F'\t' '{print $2}' | grep '\.\.\.')
# ANTI-SILENT-ZERO: zero usable paths is a loud error, not a silent empty reconcile.
if [ -z "$paths" ]; then
  echo "verify-registry: ERROR — no usable target paths in $TARGETS_MD" >&2
  echo "verify-registry: check TARGETS.md has backtick-wrapped absolute or \$RESEARCH_HOME/... paths" >&2
  exit 0  # WARN-only contract: never signals failure, but the error is explicit.
fi

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
  # The master-table row is the line carrying the EXACT backtick-wrapped path. Use the raw
  # (as-written) token from TARGETS.md as the needle — not the expanded path — so rows written
  # in `$RESEARCH_HOME/...` form are matched even after $RESEARCH_HOME has been expanded.
  raw_p="$(printf '%s\n' "$all_pairs" | awk -F'\t' -v p="$p" '$2==p{print $1;exit}')"  # RH-ROW-LOOKUP
  needle="${bt}${raw_p:-$p}${bt}"
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
  #
  # CATALOG FRESHNESS CHECK: reading the CATALOG total without verifying it against disk means a sweep
  # can transcribe a stale number and stamp [CERT] on it — confirmed defect (issue #104 §2). For each
  # CATALOG-authority target, compare the CATALOG total against the on-disk discriminator count already
  # computed above. A diff within tolerance is treated as disk-consistent (fresh). Beyond tolerance the
  # CATALOG may be stale OR the generator legitimately counts differently (sub-series blocks, etc.) —
  # both require operator verification. PROPOSE-NEVER-APPLY: never regenerate; report for the operator.
  # Four distinguishable states: (1) CATALOG absent → discriminator used, silent; (2) CATALOG present +
  # parseable total + diff ≤ tol → fresh, disk-consistent annotation; (3) CATALOG present + parseable
  # total + diff > tol → WARN fires, with two sub-cases distinguished by whether the discriminator
  # found anything: (3a) discriminator > 0 → CATALOG plausibly stale; (3b) discriminator == 0 →
  # cannot prove which side is wrong (non-canonical naming OR stale CATALOG — opposite remedies);
  # (4) CATALOG present + no parseable total → freshness undeterminable, WARN fires.
  _vr_disc_was_zero=0   # set to 1 when disc=0 overrides real; signals the unclassifiable guard
  cat_authority=""
  gen="$corpus/tools/gen-catalog.py"
  cat_md="$corpus/CATALOG.md"
  if [ -f "$gen" ] && [ -f "$cat_md" ]; then
    _cat_discriminator="$real"   # save before CATALOG may override; used for freshness check
    _cat_name="$(basename "$p")" # name not yet assigned at this point in the loop
    # A "Total: N" line first; else the first "N bloques/blocks" token anywhere in CATALOG.md.
    cat_total="$(grep -iE 'total' "$cat_md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    [ -n "$cat_total" ] || cat_total="$(grep -oiE '[0-9]+[[:space:]]*(bloques?|blocks?)' "$cat_md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    if [ -n "$cat_total" ]; then
      _cat_diff=$(( 10#${cat_total} - 10#${_cat_discriminator:-0} ))
      [ "$_cat_diff" -lt 0 ] && _cat_diff=$(( -_cat_diff ))
      if [ "$_cat_diff" -le "$tol" ]; then
        cat_authority=" (CATALOG.md total via local gen-catalog.py; disk-consistent: discriminator=${_cat_discriminator})"
      elif [ "$_cat_discriminator" -eq 0 ] && [ "$cat_total" -gt 0 ]; then
        # Discriminator classified nothing; CATALOG claims a positive count. The two candidates have
        # OPPOSITE remedies: non-canonical naming (discriminator requires <prefix>-(block|bloque)<N>.md)
        # fixes with a rename; a stale CATALOG fixes with regeneration. Asserting either without proof
        # is false inference — state the discrepancy and name both. Leave cat_authority empty so the
        # unclassifiable guard can run and provide concrete file-level evidence.
        echo "WARN  $_cat_name — discriminator found 0 classifiable blocks; CATALOG.md claims ${cat_total}; possible causes: non-canonical block naming (discriminator requires <prefix>-(block|bloque)<N>.md) or stale CATALOG — verify before trusting this count."  # CATALOG-DISC-ZERO
        _vr_disc_was_zero=1  # tell the unclassifiable guard to run despite real > 0
        # cat_authority intentionally left empty so the unclassifiable guard condition triggers
      else
        echo "WARN  $_cat_name — CATALOG.md total ${cat_total} vs on-disk discriminator ${_cat_discriminator} (diff ${_cat_diff} > tol ${tol}); CATALOG may be stale — regenerate and recheck before trusting this count."  # CATALOG-FRESHNESS-CHECK
        cat_authority=" (CATALOG.md total via local gen-catalog.py; catalog-disk diff=${_cat_diff} — verify freshness)"
      fi
      real="$cat_total"
    else
      # CATALOG.md present but no parseable total — freshness undeterminable; use discriminator.
      echo "WARN  $_cat_name — CATALOG.md present (gen-catalog.py registered) but no parseable total found; freshness undeterminable; using discriminator count (${_cat_discriminator})."  # CATALOG-NOPARSE
    fi
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

  # UNCLASSIFIABLE-BLOCK GUARD: when the canonical discriminator returns 0 yet the corpus root
  # holds files whose names contain "block"/"bloque" but do not satisfy the canonical
  # <prefix>-(block|bloque)<N>.md form, those files are completely invisible to the drift and §18
  # checks — "could not classify" is indistinguishable from "nothing here" and the silence is total.
  #
  # First filter: require the basename to start with block/bloque followed by an optional separator
  # (_/-) and a DIGIT. This admits bare numbered blocks (block1.md, bloque3.md, block_07.md) while
  # correctly excluding plausible corpus documents — the ACTUAL false-positive surface, all of which
  # the old '/(block|bloque)' rule fired on:
  #   blocking-issues.md     — 'block' then 'i', no digit → excluded ✓
  #   block-diagram.md       — 'block' then '-d', no digit after separator → excluded ✓
  #   bloques-pendientes.md  — 'bloque' then 's', not a digit → excluded ✓
  #   roadblock.md           — path separator is before 'roadblock', not before 'block'; this name
  #                            never fired even under the old rule (the old comment was wrong).
  # Residual false-positive: block-01.md fires (block + separator + digit). That shape looks like an
  # attempt at a numbered block without a canonical prefix; the rename advisory is appropriate.
  # Residual false-negative: un-numbered names (block-intro.md) do not fire; out of scope for a guard
  # targeting the numbered-block corpus convention.
  #
  # No '|| true' on the first grep: the script runs set -uo pipefail WITHOUT -e, so grep exit-1
  # (no match) does not abort the assignment and ${unclassifiable:-0} absorbs empty output. Adding
  # '|| true' would convert grep exit-2 (ENOMEM/SIGPIPE) into silent success — exactly the confident
  # zero this guard exists to prevent, reintroduced inside the guard itself.
  #
  # The check runs when the discriminator found 0 AND no authority has set cat_authority. Two triggers:
  # (a) real==0 with no CATALOG authority (original case — bare discriminator returns 0, no CATALOG);
  # (b) _vr_disc_was_zero==1 (CATALOG present but discriminator=0 — cannot classify; both candidates
  #     named in the freshness WARN; cat_authority left empty so this guard runs to add concrete evidence).
  unclassifiable=0
  if { [ "$real" -eq 0 ] || [ "$_vr_disc_was_zero" -eq 1 ]; } && [ -z "$cat_authority" ]; then
    unclassifiable="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
      | grep -iE '/(block|bloque)[_-]?[0-9]' \
      | grep -vE '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' \
      | wc -l | tr -d ' ')"
    unclassifiable="${unclassifiable:-0}"
    if [ "$unclassifiable" -gt 0 ]; then  # UNCLASSIFIABLE-CHECK
      echo "WARN  $name — ${unclassifiable} unclassifiable candidate block file(s): names contain 'block'/'bloque' but do not match the canonical discriminator (<prefix>-(block|bloque)<N>.md); the block counter returns 0 — rename to make them visible to drift and §18 checks."
    fi
  fi

  # Reachability sanity: a corpus with blocks but NO §18 kit retros anywhere means the §18 feedback
  # loop can't be reached from this target. Advisory only (incipient targets legitimately have none)
  # — fires solely when the corpus actually advanced (real > tol) yet no non-excluded retro exists.
  # Files carrying '<!-- kit-retro: exclude -->' are not §18 kit retros and are filtered out, so a
  # target with ONLY excluded retros correctly fires this INFO.
  # Also fires when the canonical discriminator sees 0 but unclassifiable candidates exist: a target
  # with 13 bare block files and no retro must not be silenced by its own non-canonical naming.
  if [ "$real" -gt "$tol" ] || [ "$unclassifiable" -gt 0 ]; then
    _vr_has_kit_retro=0
    while IFS= read -r _vr_rf; do
      [ -n "$_vr_rf" ] || continue
      retro_is_excluded "$_vr_rf" && continue
      _vr_has_kit_retro=1; break
    done < <(find "$p" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' 2>/dev/null)
    if [ "$_vr_has_kit_retro" -eq 0 ]; then
      # When canonical count is 0 but unclassifiable candidates exist, substitute both the count
      # AND the noun so the INFO line is true standing alone. Reading "0 block(s) on disk" while
      # the drift WARN above says 0 misleads the operator into editing TARGETS.md to 0 rather than
      # renaming files. Reading "13 block(s) on disk" while the drift WARN says 0 suggests the drift
      # is stale. Both half-readings produce the wrong action; changing the noun eliminates the
      # contradiction: "13 candidate block file(s) (unclassifiable)" is unambiguous.
      # When real > 0 (canonical case) the noun and count are unchanged — existing assertions hold.
      _vr_effective_count="$real"
      _vr_count_noun="block(s) on disk"
      if [ "$real" -eq 0 ] && [ "$unclassifiable" -gt 0 ]; then  # SUBST-COUNT-CHECK
        _vr_effective_count="$unclassifiable"
        _vr_count_noun="candidate block file(s) (unclassifiable) on disk"
      fi
      echo "INFO  $name — ${_vr_effective_count} ${_vr_count_noun} but no retros/*.md reachable under the target (§18 feedback not wired)."
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

# KIT-SELF-REGISTRATION GATE (kit-sup #6): warn if the kit repo itself is absent from TARGETS.md.
# A fleet supervisor that omits itself is blind to its own state and cannot be supervised by the
# same instruments it runs over all other corpora. WARN-only, PROPOSE-NEVER-APPLY (exit stays 0).
_kit_parent="$(dirname "$KIT")"
_kit_found=0
while IFS=$'\t' read -r _rv_raw _rv_expanded; do
  { [ "$_rv_expanded" = "$KIT" ] || [ "$_rv_expanded" = "$_kit_parent" ]; } && { _kit_found=1; break; }  # KIT-PARENT-MATCH
done <<< "$all_pairs"
if [ "$_kit_found" -eq 0 ]; then
  echo "WARN  $(basename "$KIT") — kit repo is NOT in its own TARGETS.md; fleet instruments cannot supervise it. Add a row with the kit's path (kit-sup #6 gate)."  # KIT-SELF-REG-CHECK
fi

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
