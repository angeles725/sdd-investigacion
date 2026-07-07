#!/usr/bin/env bash
# verify-block.test.sh — RED-FIRST harness for verify-block.sh's RAW-vs-ADJUSTED marker tally.
#
# The discriminating behaviour: the leading header blockquote (up to the FIRST `---`) DEFINES the markers
# as a legend; those tokens are NOT fresh claims and inflate the tally. ADJUSTED strips that region
# POSITIONALLY (not by backticks — real niagara blocks backtick their CLAIM markers, so a backtick-strip
# would wrongly zero them). The ratio must be computed on ADJUSTED counts. --prove-teeth neuters the header
# strip and asserts the legend fixture then shows adj==raw, proving the strip isn't theater.
#
# Usage: verify-block.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-block.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "$SUT" "$1" 2>/dev/null; }

echo "== verify-block.test.sh =="

# 1 — header legend (one of each marker before the first ---) is stripped from ADJUSTED, kept in RAW.
d="$TMP/legend.md"
{ echo "# Block 1 — t"; echo
  echo "> Method: [CERT] = verified by me; [CERT-a] = sub-agent cite; [INFER] = deduction."; echo
  echo "---"; echo
  echo "## 1.1 claim one [CERT]"; echo "The class extends BComponent [CERT]."; echo "It probably caches [INFER]."
} > "$d"
out="$(run "$d")"
# raw [CERT] = 2 (1 legend + 1 body 'extends' + ... actually: legend 1 + body 2 = 3); adj = body 2.
rawc=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | head -1)
adjc=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | sed -n '2p')
if [ "${rawc:-0}" = "3" ] && [ "${adjc:-}" = "2" ]; then ok "legend stripped: raw [CERT]=3, adj=2"
else no "legend strip: raw=[${rawc:-?}] adj=[${adjc:-none}] (want raw 3 · adj 2) :: $(printf '%s' "$out" | grep '\[CERT\]' | head -1)"; fi

# 2 — niagara-style BACKTICKED body claims must still be counted in ADJUSTED (positional strip, not backtick).
d="$TMP/backtick.md"
{ echo "# Block 2 — t"; echo
  echo "> Method: \`[CERT]\` = verified; \`[INFER]\` = deduction."; echo
  echo "---"; echo
  echo "## 2.1 \`[CERT]\`"; echo "Extends X \`[CERT]\`."; echo "Wraps Y \`[CERT]\`."
} > "$d"
out="$(run "$d")"
adjc=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | tail -1)
# body has 3 backticked [CERT]; legend 1 → raw 4, adj 3. adj must NOT be 0.
if [ "${adjc:-0}" -ge 3 ]; then ok "backticked body claims counted in adj (adj=$adjc, not zeroed)"
else no "backticked claims wrongly dropped: adj=[${adjc:-?}] (want >=3)"; fi

# 3 — a block with NO --- header fence → adjusted falls back to raw, with a note.
d="$TMP/nofence.md"
{ echo "# Block 3 — t"; echo "Just body. Extends X [CERT]. Guesses Y [INFER]."; } > "$d"
out="$(run "$d")"
if printf '%s' "$out" | grep -qiE 'no .*fence|adjusted = raw'; then ok "no --- fence → adjusted=raw fallback noted"
else no "no-fence fallback not surfaced :: $(printf '%s' "$out" | grep -i tally)"; fi

# 4 — the [INFER]/[CERT] ratio is computed on ADJUSTED counts (legend must not skew it).
d="$TMP/ratio.md"
{ echo "# Block 4 — t"; echo
  echo "> Method: [CERT] = x; [INFER] = y."; echo    # legend adds 1 CERT + 1 INFER
  echo "---"; echo
  echo "Body: a [CERT]. b [CERT]. c [INFER]."         # body: 2 CERT, 1 INFER → adjusted ratio 1/2 = 0.50
} > "$d"
out="$(run "$d")"
# raw ratio would be 2/3=0.67; adjusted 1/2=0.50. Assert the ratio line shows the adjusted 2 CERT total.
if printf '%s' "$out" | grep -E 'ratio' | grep -qE '1/2|= 0\.50'; then ok "ratio uses adjusted counts (1/2 = 0.50, not raw 2/3)"
else no "ratio not on adjusted :: $(printf '%s' "$out" | grep -i ratio | head -1)"; fi

# 5 — body section separators (extra ---) after the header must NOT strip body claims.
d="$TMP/multifence.md"
{ echo "# Block 5 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## 5.1 first [CERT]"; echo "---"; echo "## 5.2 second [CERT]"; echo "---"; echo "## 5.3 third [CERT]"
} > "$d"
out="$(run "$d")"
adjc=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | tail -1)
# legend 1 + 3 body claims across 3 sections; only the FIRST --- is the header fence → adj must be 3.
if [ "${adjc:-0}" = "3" ]; then ok "only the first --- is the header fence (body claims after later --- kept: adj=3)"
else no "multi-fence over-stripped: adj=[${adjc:-?}] (want 3)"; fi

# 6 — an EARLIER bare `---` (setext-H2 underline) before the legend blockquote must NOT be mistaken for the
#     header fence (the fence is the first `---` AFTER a `>` blockquote line, so the legend is still stripped).
d="$TMP/setext.md"
{ echo "# Block 6 — t"; echo; echo "Intro heading"; echo "---"; echo   # a setext-style `---` BEFORE the legend
  echo "> Method: [CERT] = def."; echo; echo "---"; echo               # the REAL header fence (after the blockquote)
  echo "Body a [CERT]. Body b [CERT]."
} > "$d"
out="$(run "$d")"
adjc=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | tail -1)
if [ "${adjc:-0}" = "2" ]; then ok "earlier setext '---' not mistaken for the header fence (adj=2, legend stripped)"
else no "setext '---' fooled the fence: adj=[${adjc:-?}] (want 2) :: $(printf '%s' "$out" | grep '\[CERT\]' | head -1)"; fi

# 7 — YAML front matter (leading `---...---`) before the block must NOT be mistaken for the header fence.
d="$TMP/frontmatter.md"
{ echo "---"; echo "title: t"; echo "---"; echo                        # YAML front matter (two bare ---)
  echo "# Block 7 — t"; echo; echo "> Method: [CERT] = def."; echo; echo "---"; echo
  echo "Body a [CERT]. Body b [CERT]. Body c [CERT]."
} > "$d"
out="$(run "$d")"
adjc=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | tail -1)
if [ "${adjc:-0}" = "3" ]; then ok "YAML front matter '---' not mistaken for the header fence (adj=3, legend stripped)"
else no "front-matter '---' fooled the fence: adj=[${adjc:-?}] (want 3) :: $(printf '%s' "$out" | grep '\[CERT\]' | head -1)"; fi

# 8 — REWORK REGRESSION: a body blockquote (§14 quote) before a body `---`, with NO header legend, must NOT
#     turn the body `---` into a bogus fence and silently drop the claims before it. Falls back to raw + note.
d="$TMP/bodyquote.md"
{ echo "## 1. real [CERT]. also [CERT]."; echo; echo "> §14 quote: a prior [CERT] retracted."; echo
  echo "---"; echo; echo "## 2. more [CERT]."; } > "$d"
out="$(run "$d")"; cline=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ')
if ! printf '%s' "$cline" | grep -q '(adj' && printf '%s' "$out" | grep -qiE 'adjusted = raw|no leading'; then
  ok "body-quote before body-'---' (no header legend) → fallback raw, claims not dropped"
else no "body-quote regression: [$cline] · note=$(printf '%s' "$out" | grep -ci 'adjusted = raw')"; fi

# 9 — REWORK REGRESSION: a real header legend that is UNFENCED (no '---' before the first '## '), followed by
#     a body quote + body '---', must fall back to raw — never fold real body claims into a phantom legend.
d="$TMP/unfenced.md"
{ echo "> Method: [CERT] = x; [INFER] = y."; echo; echo "## 1. claim [CERT]. claim [CERT]."; echo
  echo "> §14 quote referencing [CERT]."; echo; echo "---"; echo; echo "## 2. more [CERT]."; } > "$d"
out="$(run "$d")"; cline=$(printf '%s' "$out" | grep -E '^\s+\[CERT\] ')
if ! printf '%s' "$cline" | grep -q '(adj' && printf '%s' "$out" | grep -qiE 'adjusted = raw|no leading'; then
  ok "unfenced legend + body quote/'---' → fallback raw (no phantom-legend claim drop)"
else no "unfenced-legend regression: [$cline] · note=$(printf '%s' "$out" | grep -ci 'adjusted = raw')"; fi

# NEGATIVE CONTROL — neuter the header strip; the legend fixture must then show adj==raw (legend NOT stripped).
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the fence detection so adjusted == raw; expect the legend fixture to stop distinguishing --"
  mutant="$TMP/verify-block.MUTANT.sh"
  # Break fence detection: force fence_line empty so the body is the whole file and adj can never drop the legend.
  sed 's#^fence_line=\$(awk.*#fence_line=""#' "$SUT" > "$mutant"
  d="$TMP/teeth.md"
  { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; echo "Body a [CERT]. b [CERT]."; } > "$d"
  mout="$(bash "$mutant" "$d" 2>/dev/null)"
  mraw=$(printf '%s' "$mout" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | head -1)
  madj=$(printf '%s' "$mout" | grep -E '^\s+\[CERT\] ' | grep -oE '[0-9]+' | sed -n '2p')
  # With the strip neutered, either adj==raw (no second number shown) or the numbers match → no distinction.
  if [ -z "$madj" ] || [ "$mraw" = "$madj" ]; then ok "teeth: neutered mutant stops distinguishing legend → strip has teeth"
  else no "teeth: mutant still distinguished (raw=$mraw adj=$madj) — strip not exercised (THEATER)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
