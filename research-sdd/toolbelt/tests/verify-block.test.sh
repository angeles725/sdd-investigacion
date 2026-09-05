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
rawc=$(grep -E '^\s+\[CERT\] ' <<<"$out" | grep -oE '[0-9]+' | head -1)
adjc=$(grep -E '^\s+\[CERT\] ' <<<"$out" | grep -oE '[0-9]+' | sed -n '2p')
if [ "${rawc:-0}" = "3" ] && [ "${adjc:-}" = "2" ]; then ok "legend stripped: raw [CERT]=3, adj=2"
else no "legend strip: raw=[${rawc:-?}] adj=[${adjc:-none}] (want raw 3 · adj 2) :: $(grep '\[CERT\]' <<<"$out" | head -1)"; fi

# 2 — niagara-style BACKTICKED body claims must still be counted in ADJUSTED (positional strip, not backtick).
d="$TMP/backtick.md"
{ echo "# Block 2 — t"; echo
  echo "> Method: \`[CERT]\` = verified; \`[INFER]\` = deduction."; echo
  echo "---"; echo
  echo "## 2.1 \`[CERT]\`"; echo "Extends X \`[CERT]\`."; echo "Wraps Y \`[CERT]\`."
} > "$d"
out="$(run "$d")"
adjc=$(grep -E '^\s+\[CERT\] ' <<<"$out" | grep -oE '[0-9]+' | tail -1)
# body has 3 backticked [CERT]; legend 1 → raw 4, adj 3. adj must NOT be 0.
if [ "${adjc:-0}" -ge 3 ]; then ok "backticked body claims counted in adj (adj=$adjc, not zeroed)"
else no "backticked claims wrongly dropped: adj=[${adjc:-?}] (want >=3)"; fi

# 3 — a block with NO --- header fence → adjusted falls back to raw, with a note.
d="$TMP/nofence.md"
{ echo "# Block 3 — t"; echo "Just body. Extends X [CERT]. Guesses Y [INFER]."; } > "$d"
out="$(run "$d")"
if grep -qiE 'no .*fence|adjusted = raw' <<<"$out"; then ok "no --- fence → adjusted=raw fallback noted"
else no "no-fence fallback not surfaced :: $(grep -i tally <<<"$out")"; fi

# 4 — the [INFER]/[CERT] ratio is computed on ADJUSTED counts (legend must not skew it).
d="$TMP/ratio.md"
{ echo "# Block 4 — t"; echo
  echo "> Method: [CERT] = x; [INFER] = y."; echo    # legend adds 1 CERT + 1 INFER
  echo "---"; echo
  echo "Body: a [CERT]. b [CERT]. c [INFER]."         # body: 2 CERT, 1 INFER → adjusted ratio 1/2 = 0.50
} > "$d"
out="$(run "$d")"
# raw ratio would be 2/3=0.67; adjusted 1/2=0.50. Assert the ratio line shows the adjusted 2 CERT total.
if grep -E 'ratio' <<<"$out" | grep -qE '1/2|= 0\.50'; then ok "ratio uses adjusted counts (1/2 = 0.50, not raw 2/3)"
else no "ratio not on adjusted :: $(grep -i ratio <<<"$out" | head -1)"; fi

# 5 — body section separators (extra ---) after the header must NOT strip body claims.
d="$TMP/multifence.md"
{ echo "# Block 5 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## 5.1 first [CERT]"; echo "---"; echo "## 5.2 second [CERT]"; echo "---"; echo "## 5.3 third [CERT]"
} > "$d"
out="$(run "$d")"
adjc=$(grep -E '^\s+\[CERT\] ' <<<"$out" | grep -oE '[0-9]+' | tail -1)
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
adjc=$(grep -E '^\s+\[CERT\] ' <<<"$out" | grep -oE '[0-9]+' | tail -1)
if [ "${adjc:-0}" = "2" ]; then ok "earlier setext '---' not mistaken for the header fence (adj=2, legend stripped)"
else no "setext '---' fooled the fence: adj=[${adjc:-?}] (want 2) :: $(grep '\[CERT\]' <<<"$out" | head -1)"; fi

# 7 — YAML front matter (leading `---...---`) before the block must NOT be mistaken for the header fence.
d="$TMP/frontmatter.md"
{ echo "---"; echo "title: t"; echo "---"; echo                        # YAML front matter (two bare ---)
  echo "# Block 7 — t"; echo; echo "> Method: [CERT] = def."; echo; echo "---"; echo
  echo "Body a [CERT]. Body b [CERT]. Body c [CERT]."
} > "$d"
out="$(run "$d")"
adjc=$(grep -E '^\s+\[CERT\] ' <<<"$out" | grep -oE '[0-9]+' | tail -1)
if [ "${adjc:-0}" = "3" ]; then ok "YAML front matter '---' not mistaken for the header fence (adj=3, legend stripped)"
else no "front-matter '---' fooled the fence: adj=[${adjc:-?}] (want 3) :: $(grep '\[CERT\]' <<<"$out" | head -1)"; fi

# 8 — REWORK REGRESSION: a body blockquote (§14 quote) before a body `---`, with NO header legend, must NOT
#     turn the body `---` into a bogus fence and silently drop the claims before it. Falls back to raw + note.
d="$TMP/bodyquote.md"
{ echo "## 1. real [CERT]. also [CERT]."; echo; echo "> §14 quote: a prior [CERT] retracted."; echo
  echo "---"; echo; echo "## 2. more [CERT]."; } > "$d"
out="$(run "$d")"; cline=$(grep -E '^\s+\[CERT\] ' <<<"$out")
if ! grep -q '(adj' <<<"$cline" && grep -qiE 'adjusted = raw|no leading' <<<"$out"; then
  ok "body-quote before body-'---' (no header legend) → fallback raw, claims not dropped"
else no "body-quote regression: [$cline] · note=$(grep -ci 'adjusted = raw' <<<"$out")"; fi

# 9 — REWORK REGRESSION: a real header legend that is UNFENCED (no '---' before the first '## '), followed by
#     a body quote + body '---', must fall back to raw — never fold real body claims into a phantom legend.
d="$TMP/unfenced.md"
{ echo "> Method: [CERT] = x; [INFER] = y."; echo; echo "## 1. claim [CERT]. claim [CERT]."; echo
  echo "> §14 quote referencing [CERT]."; echo; echo "---"; echo; echo "## 2. more [CERT]."; } > "$d"
out="$(run "$d")"; cline=$(grep -E '^\s+\[CERT\] ' <<<"$out")
if ! grep -q '(adj' <<<"$cline" && grep -qiE 'adjusted = raw|no leading' <<<"$out"; then
  ok "unfenced legend + body quote/'---' → fallback raw (no phantom-legend claim drop)"
else no "unfenced-legend regression: [$cline] · note=$(grep -ci 'adjusted = raw' <<<"$out")"; fi

# ---- block-evidence-artifact citation gate (§11: dumps a [CERT] cites by artifact name MUST be preserved) ----
# The real bloque125 hole: a load-bearing [CERT] seals to a BARE parenthetical RANGE cite of a B<N>-*.txt dump
# that does not exist. Today's parser only sees BACKTICKED single-line cites, so a [CERT] sealed to vanished
# evidence passes clean. The gate must FAIL an unresolvable artifact cite (not print `extern`), while leaving
# generic non-artifact bare cites (foreign binaries, offsets) untouched so prose stays false-positive free.
rrc(){ bash "$SUT" "$1" 2>/dev/null >/dev/null; }   # run for exit code only

# 10 — bare artifact RANGE cite whose dump file is ABSENT → MISSING + exit 1 (the real bloque125 defect).
d="$TMP/art-missing.md"
{ echo "# Block 10 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The verbatim option order is fixed (B99-njre.txt:10-20). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -q 'MISSING' <<<"$out"; then ok "absent artifact cite → MISSING + exit 1 (teeth)"
else no "absent artifact cite not caught: rc=[$rc] :: $(grep -iE 'MISSING|extern|B99' <<<"$out" | head -1)"; fi

# 11 — bare artifact cite whose dump EXISTS with enough lines → ok + exit 0.
d="$TMP/art-ok.md"; seq 1 30 > "$TMP/B98-present.txt"
{ echo "# Block 11 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Order preserved (B98-present.txt:10-20). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok +B98-present' <<<"$out"; then ok "present artifact cite in range → ok + exit 0"
else no "present artifact cite not ok: rc=[$rc] :: $(grep -iE 'B98|MISSING|RANGE' <<<"$out" | head -1)"; fi

# 12 — artifact RANGE whose END exceeds the dump's line count → RANGE + exit 1.
d="$TMP/art-range.md"; seq 1 15 > "$TMP/B97-short.txt"
{ echo "# Block 12 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Spans the whole block (B97-short.txt:10-40). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'RANGE.*B97-short' <<<"$out"; then ok "artifact range END past EOF → RANGE + exit 1"
else no "artifact over-range not caught: rc=[$rc] :: $(grep -iE 'B97|RANGE|MISSING' <<<"$out" | head -1)"; fi

# 13 — REGRESSION GUARD: a legit NON-artifact bare cite (foreign binary, no file present) must NOT FAIL —
#      it is not a B<N>-*/bloque<N>-* dump, so it stays ignored/extern and never turns into a false positive.
d="$TMP/nonart.md"
{ echo "# Block 13 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Bridges into (mod.exe:100) at the shim. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ]; then ok "non-artifact bare cite stays ignored (no false FAIL, exit 0)"
else no "non-artifact bare cite wrongly FAILed: rc=[$rc] :: $(grep -iE 'mod.exe|MISSING' <<<"$out" | head -1)"; fi

# 14 — the REAL bloque125 dash: absent artifact RANGE cite using U+2011 (‑) as the range separator → MISSING+exit1.
d="$TMP/art-realdash.md"
{ echo "# Block 14 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  printf '%s\n' "In this verbatim order (B125-ghidra-njre.txt:421‑488). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -q 'MISSING' <<<"$out"; then ok "real bloque125 U+2011-dash range cite (absent) → MISSING + exit 1"
else no "U+2011-dash artifact cite not caught: rc=[$rc] :: $(grep -iE 'MISSING|B125|extern' <<<"$out" | head -1)"; fi

# ---- artifact-cite gate hardening: citation-shaped context + full range bounds ----
# The artifact pass must only fire on cites in a CITATION-SHAPED context (backticked OR parenthesized) — an
# unanchored scan matches mid-word (`verbB12-record.txt`) and hard-fails prose that merely EXPLAINS the
# convention. And a range must bounds-check its START, not only its END (a reversed/overflow start is a defect).

# 15 — backticked artifact cite whose dump is ABSENT → still MISSING + exit 1 (backtick is a citation context).
d="$TMP/art-backtick.md"
{ echo "# Block 15 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Order preserved \`B5-x.txt:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'MISSING.*B5-x' <<<"$out"; then ok "backticked artifact cite (absent) → MISSING + exit 1"
else no "backticked artifact cite not caught: rc=[$rc] :: $(grep -iE 'B5-x|MISSING' <<<"$out" | head -1)"; fi

# 16 — REGRESSION: an artifact-shaped substring MID-WORD in prose (verbB12-record.txt:44), not a real cite,
#      must NOT fire — no parens/backticks, and it starts mid-word. [CERT] present so the block is otherwise valid.
d="$TMP/art-midword.md"
{ echo "# Block 16 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Our naming convention for verbB12-record.txt:44 dumps the trace. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "mid-word artifact-shaped prose does NOT fire (no false MISSING, exit 0)"
else no "mid-word prose wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# 17 — REGRESSION: prose that EXPLAINS the convention (bare `bloque12-dump.txt:5`, no parens/backticks) must
#      NOT hard-fail the gate — a block discussing the convention is legitimate, not a vanished-evidence seal.
d="$TMP/art-conv.md"
{ echo "# Block 17 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "A bloque12-dump.txt:5 citation would look like this in a self-report. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "convention-discussion prose does NOT fire (no false MISSING, exit 0)"
else no "convention prose wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# 18 — range START must be bounds-checked too: file has 10 lines, cite (B1-short.txt:9999-2) has START past
#      EOF and is reversed → RANGE! + exit 1 (checking only END, 2<=10, would wrongly pass).
d="$TMP/art-startrange.md"; seq 1 10 > "$TMP/B1-short.txt"
{ echo "# Block 18 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Spans (B1-short.txt:9999-2) of the dump. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'RANGE.*B1-short' <<<"$out"; then ok "range START past EOF / reversed → RANGE + exit 1"
else no "range START not bounds-checked: rc=[$rc] :: $(grep -iE 'B1-short|ok|RANGE' <<<"$out" | head -1)"; fi

# ---- artifact cite must be caught ANYWHERE inside a paren/backtick span (real corpus: `(cf. … B124-x:…)`) ----
# The real niagara format puts TEXT between the `(` and the token (bloque124/129). The gate must catch a
# word-boundary artifact token anywhere inside a parenthetical span (or backticks), not only right after `(`.

# 19 — text BEFORE the token inside parens (`(cf. …)`), dump absent → MISSING + exit 1 (real B124 format).
d="$TMP/art-cf.md"
{ echo "# Block 19 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Its linked-libs list has no njre.dll (cf. B124-triage.txt:839-854). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'MISSING.*B124-triage' <<<"$out"; then ok "text-before-token in parens ((cf. …)) caught → MISSING + exit 1"
else no "(cf. …) cite dropped: rc=[$rc] :: $(grep -iE 'B124|MISSING|ok' <<<"$out" | head -1)"; fi

# 20 — text before token + trailing colon after the paren (`(see …):`), dump absent → MISSING + exit 1.
d="$TMP/art-see.md"
{ echo "# Block 20 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Imports are only JavaLauncher (see B129-plat.txt:689-696): the shim. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'MISSING.*B129-plat' <<<"$out"; then ok "text-before-token + trailing colon ((see …):) caught → MISSING + exit 1"
else no "(see …): cite dropped: rc=[$rc] :: $(grep -iE 'B129|MISSING|ok' <<<"$out" | head -1)"; fi

# 21 — REGRESSION: a mid-word artifact-shaped substring INSIDE parens ((verbB12-record.txt:44)) must still NOT
#      fire — the token is preceded by a letter, so it is not at a word boundary and is not a real cite.
d="$TMP/art-midword-paren.md"
{ echo "# Block 21 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The suffix appears (verbB12-record.txt:44) inside a word here. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "mid-word token inside parens does NOT fire (word-boundary guard, exit 0)"
else no "mid-word-in-parens wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# 22 — a valid in-bounds range inside parens resolves ok (2-9 within a 10-line dump) → exit 0.
d="$TMP/art-goodrange.md"; seq 1 10 > "$TMP/B1-short.txt"
{ echo "# Block 22 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Spans (B1-short.txt:2-9) of the dump. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok +B1-short.txt:2-9' <<<"$out"; then ok "in-bounds range (2-9 of 10 lines) → ok + exit 0"
else no "in-bounds range not ok: rc=[$rc] :: $(grep -iE 'B1-short|RANGE' <<<"$out" | head -1)"; fi

# ---- EXTENSIONLESS artifact cites (bloque128 declares `cited as B128-triage:LINE`) must be caught too ----
# ~45% of the real corpus omits the file extension (`B128-triage:103`). The gate must resolve `target/B128-triage`
# just like an extensioned dump — an absent one is the same silent-pass defect the feature exists to kill.

# 23 — extensionless single-line cite, dump absent → MISSING + exit 1.
d="$TMP/art-extless.md"
{ echo "# Block 23 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "sha256 distinct (B128-triage:103). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'MISSING.*B128-triage:103' <<<"$out"; then ok "extensionless single-line cite (absent) → MISSING + exit 1"
else no "extensionless single cite dropped: rc=[$rc] :: $(grep -iE 'B128|MISSING|ok' <<<"$out" | head -1)"; fi

# 24 — extensionless RANGE cite with the real U+2011 dash, dump absent → MISSING + exit 1.
d="$TMP/art-extless-range.md"
{ echo "# Block 24 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  printf '%s\n' "headers (B128-triage:12‑34). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'MISSING.*B128-triage' <<<"$out"; then ok "extensionless U+2011-range cite (absent) → MISSING + exit 1"
else no "extensionless range cite dropped: rc=[$rc] :: $(grep -iE 'B128|MISSING|ok' <<<"$out" | head -1)"; fi

# 25 — extensionless cite with TEXT BEFORE the token inside the span, dump absent → MISSING + exit 1.
d="$TMP/art-extless-text.md"
{ echo "# Block 25 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  printf '%s\n' "the PE header set (rabin2 out; B128-triage:100‑113). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'MISSING.*B128-triage' <<<"$out"; then ok "extensionless text-before-token cite (absent) → MISSING + exit 1"
else no "extensionless text-before cite dropped: rc=[$rc] :: $(grep -iE 'B128|MISSING|ok' <<<"$out" | head -1)"; fi

# 26 — REGRESSION (looser pattern makes this more important): a mid-word EXTENSIONLESS look-alike inside parens
#      ((verbB12-triage:44)) must STILL NOT fire — the token is preceded by a letter (no word boundary).
d="$TMP/art-extless-midword.md"
{ echo "# Block 26 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The suffix (verbB12-triage:44) appears mid-word here. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "mid-word extensionless token inside parens does NOT fire (word-boundary guard, exit 0)"
else no "mid-word extensionless wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# 27 — extensionless in-bounds range resolves ok (2-9 within a 10-line dump named with NO extension) → exit 0.
d="$TMP/art-extless-ok.md"; seq 1 10 > "$TMP/B1-short"
{ echo "# Block 27 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Spans (B1-short:2-9) of the dump. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok +B1-short:2-9' <<<"$out"; then ok "extensionless in-bounds range (2-9 of 10 lines) → ok + exit 0"
else no "extensionless in-bounds range not ok: rc=[$rc] :: $(grep -iE 'B1-short|RANGE|MISSING' <<<"$out" | head -1)"; fi

# ---- FALSE-POSITIVE guards: a DIGIT-ONLY filename remainder is ordinary numeric prose, not an artifact cite ----
# All 44 real dumps carry letters (`triage`, `native-triage`, `ghidra-njre`). Ranges/sections written as
# `B12-3:44`, `B5-10:20`, `B7-2:1` are prose, not `B<N>-*` dumps — the filename run must require >=1 letter.

# 28 — a section reference (B12-3:44) — digit-only remainder in prose — must NOT fire.
d="$TMP/fp-section.md"
{ echo "# Block 28 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "It is defined (see section B12-3:44 of the annex). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "digit-only filename part (B12-3:44) does NOT fire (no false MISSING, exit 0)"
else no "B12-3:44 wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# 29 — a table range (B5-10:20) — digit-only remainder — must NOT fire.
d="$TMP/fp-range.md"
{ echo "# Block 29 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Shown in (the range B5-10:20 of the table). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "digit-only range (B5-10:20) does NOT fire (no false MISSING, exit 0)"
else no "B5-10:20 wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# 30 — two digit-only build refs (B7-2:1 vs B7-3:1) in one paren span — neither must fire.
d="$TMP/fp-build.md"
{ echo "# Block 30 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Compared (build B7-2:1 vs B7-3:1 here). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "digit-only build refs (B7-2:1 vs B7-3:1) do NOT fire (no false MISSING, exit 0)"
else no "B7-x:1 wrongly fired: rc=[$rc] :: $(grep -i 'MISSING' <<<"$out" | head -1)"; fi

# ---- D6: artifact cites that carry a PATH PREFIX must resolve via the full path ---------------------
# nav2 D6: when a cite is written as (sources/probes/B10-x.txt:146) the art_name regex extracts only
# the bare basename B10-x.txt. The file exists under <target>/sources/probes/B10-x.txt but NOT at
# <target>/B10-x.txt. Current behaviour: MISSING! + exit 1. Fixed behaviour: ok + exit 0.

# 31 — D6: path-prefixed cite (sources/probes/B10-x.txt:146) — file at that subpath, not bare.
#      Must resolve via the full cited path → ok + exit 0 (not MISSING).
d="$TMP/d6-pathcite.md"; mkdir -p "$TMP/sources/probes"; seq 1 200 > "$TMP/sources/probes/B10-x.txt"
{ echo "# Block 31 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Option order fixed (sources/probes/B10-x.txt:146). \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -q 'MISSING' <<<"$out"; then ok "D6: path-prefixed cite (sources/probes/B10-x.txt:146) resolved → ok + exit 0"
else no "D6: path-prefixed cite not resolved: rc=[$rc] :: $(grep -iE 'B10-x|MISSING|ok' <<<"$out" | head -1)"; fi

# ---- P6: [CERT] markers present but ZERO file:line citations → WARN (second half of pi5 P6) --------
# When a block has [CERT] body markers but neither art_cites nor bt_cites resolve any file:line
# citation, the citation gate exits 0 silently having checked nothing. P6 adds a WARN for that case.

# 32 — P6: block has [CERT] in body, no file:line citations anywhere → WARN must fire.
d="$TMP/p6-certnoncite.md"
{ echo "# Block 32 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The flag is always set. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|\[CERT\].*WARN|WARN.*cert.*citation|WARN.*cert.*zero' <<<"$out"; then ok "P6: [CERT] with zero citations → WARN emitted"
else no "P6: [CERT] with zero citations — no WARN :: $(grep -iE 'WARN|cert|citation' <<<"$out" | head -1)"; fi

# ---- P6 deferred: short-form :NNN in table cells and code-block comments -------------------
# The citation parser was not recognising two corpus-confirmed forms:
#   (a) | :29 | in table rows  (pi5-decoding-block1: 38 columns of :NNN in a | row)
#   (b) // :157 in code-block comments  (pi5-decoding-block2: constants block)
# Either form suppresses the P6 WARN correctly; an IP port (127.0.0.1:46272) in a table
# cell must NOT fire (the digit before the colon is outside [[:space:]|,]).

# 33 — P6-table: short-form :NNN inside a table cell → reported as "short"; no WARN fires.
d="$TMP/p6-short-table.md"
{ echo "# Block 33 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## Field map [CERT]"
  echo "Every row cites its line in the source file."
  echo "| Field | Line |"
  echo "|---|---|"
  echo "| FIELD_A | :10 |"
  echo "| FIELD_B | :15 |"
} > "$d"
out="$(run "$d")"
if grep -qiE 'short.*:10|:10.*short' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert|no file:line' <<<"$out"; then
  ok "P6-table: short-form :NNN in table cell → 'short' reported; no false WARN"
else no "P6-table: table-cell short form missed :: $(grep -iE 'short|WARN|citation' <<<"$out" | head -2)"; fi

# 34 — P6-comment: short-form :NNN in a code-block comment (// :NNN) → "short"; no WARN.
d="$TMP/p6-short-comment.md"
{ echo "# Block 34 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## Constants [CERT]"
  printf '```csharp\n'
  echo "CONST_A = 15;  // :157"
  echo "CONST_B = 0;   // :159"
  printf '```\n'
} > "$d"
out="$(run "$d")"
if grep -qiE 'short.*:157|:157.*short' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert|no file:line' <<<"$out"; then
  ok "P6-comment: short-form :NNN in code-block comment → 'short' reported; no false WARN"
else no "P6-comment: code-comment short form missed :: $(grep -iE 'short|WARN|citation' <<<"$out" | head -2)"; fi

# 35 — REGRESSION: IP:port in a table cell (127.0.0.1:46272) must NOT fire as a short cite.
#      The digit before the colon is outside [[:space:]|,] → no match. WARN must still fire
#      because cert_total > 0 and no real citation was found.
d="$TMP/p6-no-ipport.md"
{ echo "# Block 35 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## Network scan [CERT]"
  echo "| Host | Purpose |"
  echo "|---|---|"
  echo "| 127.0.0.1:46272 | gateway |"
} > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out" && ! grep -qiE 'short.*:46272|:46272.*short' <<<"$out"; then
  ok "P6-regression: IP:port in table cell NOT a short cite; WARN still fires (no false positive)"
else no "P6-regression: IP:port wrongly fired or WARN suppressed :: $(grep -iE 'short|WARN|:46272' <<<"$out" | head -2)"; fi

# ---- P7: range form `file.ext:NNN-MMM` in backtick cites -----------------------------------------------
# The corpus overwhelmingly uses range citations (`BinaryEncoder.java:10-20`). The parser was blind to
# every one of them: the old bt_cites pattern anchored on `:[0-9]+` only (no `-[0-9]+` continuation),
# so a block with ONLY range cites triggered the P6 zero-citation WARN — a false positive on a
# well-cited block. The extension adds `(-[0-9]+)?` to the extraction and validates both endpoints.

# 36 — range cite in backticks, file absent → extern + NO false P6 WARN (the pre-fix false-positive case).
d="$TMP/bt-range-extern.md"
{ echo "# Block 36 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The method signature \`BinaryEncoder.java:10-20\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'extern.*BinaryEncoder\.java:10-20' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "bt range cite (absent file) → extern; no false P6 WARN"
else no "bt range extern: got :: $(grep -iE 'extern|WARN|BinaryEncoder' <<<"$out" | head -2)"; fi

# 37 — range cite in backticks, file present, end within bounds → ok + exit 0.
d="$TMP/bt-range-ok.md"; seq 1 30 > "$TMP/bt-range-file.java"
{ echo "# Block 37 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The method signature \`bt-range-file.java:10-20\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok.*bt-range-file\.java:10-20' <<<"$out"; then ok "bt range cite in-bounds → ok + exit 0"
else no "bt range in-bounds not ok: rc=[$rc] :: $(grep -iE 'ok|RANGE|extern|bt-range-file' <<<"$out" | head -1)"; fi

# 38 — range cite in backticks, file present, end past EOF → RANGE! + exit 1.
d="$TMP/bt-range-overflow.md"; seq 1 15 > "$TMP/bt-short.java"
{ echo "# Block 38 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The entry point \`bt-short.java:10-25\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'RANGE.*bt-short\.java:10-25' <<<"$out"; then ok "bt range cite end past EOF → RANGE! + exit 1"
else no "bt range overflow not caught: rc=[$rc] :: $(grep -iE 'RANGE|ok|bt-short' <<<"$out" | head -1)"; fi

# 39 — degenerate: :0-NNN (start is 0, invalid — lines are 1-indexed) → RANGE! + exit 1.
d="$TMP/bt-range-zero.md"; seq 1 30 > "$TMP/bt-range-file.java"
{ echo "# Block 39 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "From top \`bt-range-file.java:0-10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'RANGE.*bt-range-file\.java:0-10' <<<"$out"; then ok "bt range :0-NNN (zero start, invalid) → RANGE! + exit 1"
else no "bt range zero-start not caught: rc=[$rc] :: $(grep -iE 'RANGE|ok|bt-range-file' <<<"$out" | head -1)"; fi

# 40 — degenerate: :10-3 reversed (start > end — defect in block) → RANGE! + exit 1.
d="$TMP/bt-range-reversed.md"; seq 1 30 > "$TMP/bt-range-file.java"
{ echo "# Block 40 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Reversed range \`bt-range-file.java:10-3\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qE 'RANGE.*bt-range-file\.java:10-3' <<<"$out"; then ok "bt range :10-3 reversed (defect) → RANGE! + exit 1"
else no "bt range reversed not caught: rc=[$rc] :: $(grep -iE 'RANGE|ok|bt-range-file' <<<"$out" | head -1)"; fi

# 41 — degenerate: :5-5 (single-line range, valid) → ok + exit 0.
d="$TMP/bt-range-same.md"; seq 1 30 > "$TMP/bt-range-file.java"
{ echo "# Block 41 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "One-line range \`bt-range-file.java:5-5\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok.*bt-range-file\.java:5-5' <<<"$out"; then ok "bt range :5-5 (degenerate single-line range) → ok + exit 0"
else no "bt range :5-5 not ok: rc=[$rc] :: $(grep -iE 'ok|RANGE|bt-range-file' <<<"$out" | head -1)"; fi

# ---- P7: secondary short-form citation after a comma in a comment (// :NNN,:MMM) -------------------
# `// :159,:161` captures :159 but the old pattern stopped there; :161 after the comma was invisible.
# The fix extends the pattern with `(,[[:space:]]*:[0-9]+)*` so all comma-joined cites in one
# comment token are captured. Discipline: the comma continuation is ONLY valid when a comment marker
# already established the citation context — arbitrary prose is not affected.

# 42 — secondary comment cite: // :NNN,:MMM → both :NNN and :MMM as short; no false WARN.
d="$TMP/p7-cmt-secondary.md"
{ echo "# Block 42 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## Constants [CERT]"
  printf '```csharp\n'
  echo "CONST_A = 15;  // :159,:161"
  printf '```\n'
} > "$d"
out="$(run "$d")"
if grep -qiE 'short.*:159|:159.*short' <<<"$out" && grep -qiE 'short.*:161|:161.*short' <<<"$out" \
   && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "P7-cmt-secondary: // :NNN,:MMM → both :159 and :161 as short; no WARN"
else no "P7-cmt-secondary: secondary cite missed or WARN fires :: $(grep -iE 'short|WARN|:15[0-9]|:16[0-9]' <<<"$out" | head -3)"; fi

# ---- P6-probe: sources/probes/ file citation suppresses P6 WARN (two-sided) -------------------------
# §3's canonical [CERT-hw]/[CERT-live] format cites probe files WITHOUT a line number.
# P6 must NOT fire when a cited sources/probes/ file EXISTS on disk.
# P6 MUST still fire when ZERO citations of any kind exist — a one-sided test re-opens the defect.

# 43 — P6-probe: [CERT-hw] body marker + existing sources/probes/ cite → no P6 WARN.
d="$TMP/p6-probe-ok.md"; mkdir -p "$TMP/sources/probes/test-probe"
printf 'probe content\n' > "$TMP/sources/probes/test-probe/probe-20260729.txt"
{ echo "# Block 43 — t"; echo
  echo "> Method: [CERT-hw] = live device response."; echo
  echo "---"; echo
  echo "## 43.1 Live response [CERT-hw]"
  echo "[CERT-hw] (sources/probes/test-probe/probe-20260729.txt)"; } > "$d"
out="$(run "$d")"
if grep -qiE 'probe.*sources/probes' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero' <<<"$out"; then
  ok "P6-probe: [CERT-hw] + existing probe file → cited, no P6 WARN"
else no "P6-probe: probe-cited block wrongly WARNed or probe not reported :: $(grep -iE 'WARN|probe' <<<"$out" | head -2)"; fi

# 44 — P6-probe (negative half): [CERT-hw] + zero citations of any kind → P6 WARN still fires.
d="$TMP/p6-probe-nocite.md"
{ echo "# Block 44 — t"; echo
  echo "> Method: [CERT-hw] = live device response."; echo
  echo "---"; echo
  echo "## 44.1 Live response [CERT-hw]"
  echo "The station answered unknown-object. [CERT-hw]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero' <<<"$out"; then
  ok "P6-probe (negative): [CERT-hw] + zero citations → P6 WARN still fires"
else no "P6-probe (negative): P6 WARN not emitted for [CERT-hw]+no-cites :: $(grep -iE 'WARN|cert|citation' <<<"$out" | head -1)"; fi

# 45 — NESTED LAYOUT: block inside a corpus sub-directory; the cited source file lives ABOVE the corpus dir.
#      target defaults to the corpus dir; the file is at <project>/<f>, not <corpus>/<f>.
#      Pre-fix: extern + no P6 WARN (bt_cites non-empty suppresses P6). Fixed: ok + no P6 WARN.
#      Requires a git repo at the project level so git rev-parse --show-toplevel works from the corpus.
mkdir -p "$TMP/nested/src" "$TMP/nested/corpus"
git -C "$TMP/nested" init -q 2>/dev/null
seq 1 50 > "$TMP/nested/src/tool.sh"
d="$TMP/nested/corpus/block45.md"
{ echo "# Block 45 — nested layout"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## 45.1 Observation [CERT]"
  echo "The function is defined at \`src/tool.sh:10\`. \`[CERT]\`"; } > "$d"
out45="$(bash "$SUT" "$d" 2>/dev/null)"
bash "$SUT" "$d" >/dev/null 2>/dev/null; rc45=$?
if [ "$rc45" = "0" ] && grep -qE 'ok.*src/tool\.sh:10' <<<"$out45" \
   && ! grep -qiE 'extern.*src/tool|WARN.*\[CERT\]|WARN.*cert' <<<"$out45"; then
  ok "nested layout: own-source cite above corpus resolves ok + no P6 WARN"
else
  no "nested layout: cite went extern or P6 WARN fired: rc=[$rc45] :: $(grep -iE 'extern.*src/tool|ok.*src/tool|WARN' <<<"$out45" | head -2)"
fi

# ---- P6-doc-aware: doc-grade-only blocks ([CERT-doc]/[CERT-web]/[CERT-a]) → P6 WARN suppressed ------
# A doc/DESIGN corpus block legitimately cites preserved PDF/HTML via [CERT-doc]/[CERT-web]/[CERT-a]
# and never cites a target file:line. The P6 WARN was a false positive on every such block, training
# the operator to ignore it (retros 2026-08-12 web-hmi10cf #1, 2026-08-18 forense #1: all 9/9 and
# 6/6 blocks tripped it respectively). Fix: detect doc-grade-only cert markers and suppress with an
# informational note. Code-grade markers ([CERT-hw]/[CERT-live]/[CERT]) still trigger the WARN.

# 46 — P6-doc-aware: [CERT-doc]-only block (doc corpus, no code artifacts) → no P6 WARN; info note instead.
d="$TMP/p6-doconly.md"
{ echo "# Block 46 — doc corpus"; echo
  echo "> Method: [CERT-doc] = preserved PDF+page; [INFER] = deduction from doc."; echo
  echo "---"; echo
  echo "## 46.1 Config [CERT-doc]"
  echo "The panel accepts BACnet/IP over UDP (Honeywell guide §3.2). [CERT-doc]"
  echo "Default port is 47808 (Honeywell guide §3.2). [CERT-doc]"
} > "$d"
out="$(run "$d")"
if ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero' <<<"$out"; then
  ok "P6-doc-aware: [CERT-doc]-only block → no P6 WARN (doc-grade, file:line not expected)"
else no "P6-doc-aware: false-positive WARN on doc-only block :: $(grep -iE 'WARN' <<<"$out" | head -1)"; fi

# 47 — P6-doc-aware (negative): mixed [CERT-doc] + [CERT] with no file:line → P6 WARN still fires.
#      Code-grade marker present → suppressor must NOT engage; WARN must still notify the operator.
d="$TMP/p6-docmixed.md"
{ echo "# Block 47 — mixed"; echo
  echo "> Method: [CERT-doc] = PDF; [CERT] = code verified."; echo
  echo "---"; echo
  echo "## 47.1 Mixed [CERT-doc] + [CERT]"
  echo "Config from spec (guide §3.2). [CERT-doc]"
  echo "Flag always set in firmware. [CERT]"
} > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero' <<<"$out"; then
  ok "P6-doc-aware (negative): mixed [CERT-doc]+[CERT] with no file:line → P6 WARN still fires"
else no "P6-doc-aware (negative): P6 WARN wrongly suppressed for mixed block :: $(grep -iE 'WARN|cert' <<<"$out" | head -1)"; fi

# 48 — P6 WARN wording (jace8000 D3): the WARN message must name the expected file:line-free case
#      (synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks) and point the author to
#      their block-type declaration, so a legitimate citation-free block does not read as a defect.
#      It must NOT advise "add file:line citations" as the sole remedy.
d="$TMP/p6-wording.md"
{ echo "# Block 48 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The flag is always set. [CERT]"; } > "$d"
out="$(run "$d")"
warn_line="$(grep -iE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out" | head -1)"
if echo "$warn_line" | grep -qiE 'synthesis|REMITTANCE' \
   && echo "$warn_line" | grep -qiE 'block.type|block type|declaration'; then
  ok "P6 WARN wording: names expected file:line-free case and points to block-type declaration"
else
  no "P6 WARN wording: expected-case phrase or block-type pointer missing :: [$warn_line]"
fi

# 49 — OCR citation resolution grep error (site 257): grep -nF exits 2 → WARN emitted (not silent).
#       Stubs grep so any -nF call (used only for OCR token-in-block lookup) exits 2.
_vb_real_grep=/usr/bin/grep
_stub_vb49="$TMP/stub-bin-vb49"; mkdir -p "$_stub_vb49"
cat > "$_stub_vb49/grep" << STUB_VB49
#!/usr/bin/env bash
[ "\$1" = "-nF" ] && exit 2
exec "$_vb_real_grep" "\$@"
STUB_VB49
chmod +x "$_stub_vb49/grep"
d_vb49="$TMP/vb49-ocr-target"; mkdir -p "$d_vb49/sources/extracted"
printf 'source_pdf: somepaper.pdf\nreliability: ocr-lossy\n\nContent.\n' \
  > "$d_vb49/sources/extracted/somepaper-pp1.md"
block_vb49="$d_vb49/target-block1.md"
{ echo "# Block 1 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "## Result [CERT]"; echo "See somepaper-pp1 for details. [CERT]"; } > "$block_vb49"
out_vb49="$(PATH="$_stub_vb49:$PATH" bash "$SUT" "$block_vb49" "$d_vb49" 2>&1)"
grep -qiE 'citation resolution FAILED|unresolved.*grep exit' <<<"$out_vb49" \
  && ok "49 OCR cite grep -nF exit-2 → citation resolution WARN (not silent)" \
  || no "49 OCR cite grep -nF exit-2 not reported :: $out_vb49"

# 50 — OCR citation dedup grep error (site 260): dedup pipeline grep -vE exits 2 → WARN emitted.
#       Stubs grep so any -vE call with the blank-line filter pattern exits 2.
_stub_vb50="$TMP/stub-bin-vb50"; mkdir -p "$_stub_vb50"
cat > "$_stub_vb50/grep" << STUB_VB50
#!/usr/bin/env bash
[ "\$1" = "-vE" ] && [ "\$2" = '^[[:space:]]*$' ] && exit 2
exec "$_vb_real_grep" "\$@"
STUB_VB50
chmod +x "$_stub_vb50/grep"
# Fixture: same as vb49 but we need grep -nF to succeed so dedup is reached.
# Use the real grep for -nF; only stub the -vE blank-line filter.
d_vb50="$TMP/vb50-ocr-target"; mkdir -p "$d_vb50/sources/extracted"
printf 'source_pdf: otherpaper.pdf\nreliability: ocr-lossy\n\nContent.\n' \
  > "$d_vb50/sources/extracted/otherpaper-pp2.md"
block_vb50="$d_vb50/target-block2.md"
{ echo "# Block 2 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "## Result [CERT]"; echo "See otherpaper-pp2 for details. [CERT]"; } > "$block_vb50"
out_vb50="$(PATH="$_stub_vb50:$PATH" bash "$SUT" "$block_vb50" "$d_vb50" 2>&1)"
grep -qiE 'citation dedup FAILED|unresolved.*grep exit' <<<"$out_vb50" \
  && ok "50 OCR cite dedup grep -vE exit-2 → dedup WARN emitted (not silent)" \
  || no "50 OCR cite dedup grep -vE exit-2 not reported :: $out_vb50"

# NEGATIVE CONTROL — neuter the header strip; the legend fixture must then show adj==raw (legend NOT stripped).
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the fence detection so adjusted == raw; expect the legend fixture to stop distinguishing --"
  mutant="$TMP/verify-block.MUTANT.sh"
  # Break fence detection: force fence_line empty so the body is the whole file and adj can never drop the legend.
  sed 's#^fence_line=\$(awk.*#fence_line=""#' "$SUT" > "$mutant"
  d="$TMP/teeth.md"
  { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; echo "Body a [CERT]. b [CERT]."; } > "$d"
  mout="$(bash "$mutant" "$d" 2>/dev/null)"
  mraw=$(grep -E '^\s+\[CERT\] ' <<<"$mout" | grep -oE '[0-9]+' | head -1)
  madj=$(grep -E '^\s+\[CERT\] ' <<<"$mout" | grep -oE '[0-9]+' | sed -n '2p')
  # With the strip neutered, either adj==raw (no second number shown) or the numbers match → no distinction.
  if [ -z "$madj" ] || [ "$mraw" = "$madj" ]; then ok "teeth: neutered mutant stops distinguishing legend → strip has teeth"
  else no "teeth: mutant still distinguished (raw=$mraw adj=$madj) — strip not exercised (THEATER)"; fi

  # teeth-d6: neuter the D6 path-prefix fallback (D6-PATH-FALLBACK sentinel); the path-prefixed
  # cite must go back to MISSING + exit 1, proving test 31 depends on the real fallback.
  echo "-- teeth-d6: neuter D6-PATH-FALLBACK; path-prefixed cite must go MISSING + exit 1 --"
  mutant_d6="$TMP/verify-block.D6MUTANT.sh"
  if grep -q '# D6-PATH-FALLBACK' "$SUT"; then
    sed '/# D6-PATH-FALLBACK/ s/.*/      : # D6-PATH-FALLBACK [NEUTERED]/' "$SUT" > "$mutant_d6"
    mkdir -p "$TMP/sources/probes"; seq 1 200 > "$TMP/sources/probes/B10-x.txt"
    d_d6="$TMP/d6-teeth.md"
    { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "Option order fixed (sources/probes/B10-x.txt:146). \`[CERT]\`"; } > "$d_d6"
    bash "$mutant_d6" "$d_d6" >/dev/null 2>/dev/null; md6_rc=$?
    mout_d6="$(bash "$mutant_d6" "$d_d6" 2>/dev/null)"
    if [ "$md6_rc" = "1" ] && grep -q 'MISSING' <<<"$mout_d6"; then
      ok "teeth-d6: neutered D6 fallback → path-prefixed cite is MISSING + exit 1 (test 31 has teeth)"
    else
      no "teeth-d6: neutered D6 mutant did not produce MISSING: rc=[$md6_rc] :: $(grep -iE 'MISSING|ok|B10' <<<"$mout_d6" | head -1)"
    fi
  else
    no "teeth-d6: D6-PATH-FALLBACK sentinel not found in SUT (D6 not implemented or marker missing)"
  fi

  # teeth-p6: neuter the P6 CERT-zero-cite WARN (P6-CERT-ZERO-CITE-WARN sentinel); the [CERT]+
  # no-citations block must stop emitting the WARN, proving test 32 depends on the real branch.
  echo "-- teeth-p6: neuter P6-CERT-ZERO-CITE-WARN; [CERT]+no-cites block must NOT WARN --"
  mutant_p6="$TMP/verify-block.P6MUTANT.sh"
  if grep -q '# P6-CERT-ZERO-CITE-WARN' "$SUT"; then
    sed '/# P6-CERT-ZERO-CITE-WARN/ s/.*/  if false; then  # P6-CERT-ZERO-CITE-WARN [NEUTERED]/' "$SUT" > "$mutant_p6"
    d_p6="$TMP/p6-teeth.md"
    { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "The flag is always set. [CERT]"; } > "$d_p6"
    mout_p6="$(bash "$mutant_p6" "$d_p6" 2>/dev/null)"
    if ! grep -qiE 'WARN.*\[CERT\]|\[CERT\].*WARN|WARN.*cert' <<<"$mout_p6"; then
      ok "teeth-p6: neutered P6 branch → no WARN emitted for [CERT]+no-cites (test 32 has teeth)"
    else
      no "teeth-p6: neutered P6 mutant STILL emitted WARN :: $(grep -iE 'WARN' <<<"$mout_p6" | head -1)"
    fi
  else
    no "teeth-p6: P6-CERT-ZERO-CITE-WARN sentinel not found in SUT (P6 not implemented or marker missing)"
  fi

  # teeth-p6-short-tbl: neuter P6-SHORT-FORM-CITE-TABLE; table-cell :NNN must revert to WARN.
  echo "-- teeth-p6-short-tbl: neuter P6-SHORT-FORM-CITE-TABLE; table :NNN must revert to WARN --"
  mutant_sft="$TMP/verify-block.P6SFTTBL.sh"
  if grep -q '# P6-SHORT-FORM-CITE-TABLE' "$SUT"; then
    sed '/# P6-SHORT-FORM-CITE-TABLE/ s/.*/_tbl_shorts=""  # P6-SHORT-FORM-CITE-TABLE [NEUTERED]/' "$SUT" > "$mutant_sft"
    d_sft="$TMP/p6-sft-teeth.md"
    { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "## Field map [CERT]"
      echo "| Field | Line |"; echo "|---|---|"; echo "| FIELD_A | :10 |"; } > "$d_sft"
    mout_sft="$(bash "$mutant_sft" "$d_sft" 2>/dev/null)"
    if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$mout_sft"; then
      ok "teeth-p6-short-tbl: neutered table extractor → table :NNN reverts to WARN (test 33 has teeth)"
    else
      no "teeth-p6-short-tbl: neutered mutant did NOT revert to WARN :: $(grep -iE 'WARN|short' <<<"$mout_sft" | head -1)"
    fi
  else
    no "teeth-p6-short-tbl: P6-SHORT-FORM-CITE-TABLE sentinel not found in SUT"
  fi

  # teeth-p6-short-cmt: neuter P6-SHORT-FORM-CITE-COMMENT; comment :NNN must revert to WARN.
  echo "-- teeth-p6-short-cmt: neuter P6-SHORT-FORM-CITE-COMMENT; comment :NNN must revert to WARN --"
  mutant_sfc="$TMP/verify-block.P6SFCMT.sh"
  if grep -q '# P6-SHORT-FORM-CITE-COMMENT' "$SUT"; then
    sed '/# P6-SHORT-FORM-CITE-COMMENT/ s/.*/_cmt_shorts=""  # P6-SHORT-FORM-CITE-COMMENT [NEUTERED]/' "$SUT" > "$mutant_sfc"
    d_sfc="$TMP/p6-sfc-teeth.md"
    { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "## Constants [CERT]"
      printf '```csharp\n'; echo "CONST_A = 15;  // :157"; printf '```\n'; } > "$d_sfc"
    mout_sfc="$(bash "$mutant_sfc" "$d_sfc" 2>/dev/null)"
    if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$mout_sfc"; then
      ok "teeth-p6-short-cmt: neutered comment extractor → comment :NNN reverts to WARN (test 34 has teeth)"
    else
      no "teeth-p6-short-cmt: neutered mutant did NOT revert to WARN :: $(grep -iE 'WARN|short' <<<"$mout_sfc" | head -1)"
    fi
  else
    no "teeth-p6-short-cmt: P6-SHORT-FORM-CITE-COMMENT sentinel not found in SUT"
  fi

  # teeth-p7-range-extract: neuter P7-BT-RANGE-EXTRACT; range-only block must revert to P6 WARN.
  echo "-- teeth-p7-range-extract: neuter P7-BT-RANGE-EXTRACT; range-only block must revert to WARN --"
  mutant_rng="$TMP/verify-block.P7RNGEXTRACT.sh"
  if grep -q '# P7-BT-RANGE-EXTRACT' "$SUT"; then
    sed '/# P7-BT-RANGE-EXTRACT/ s/.*/bt_cites=""  # P7-BT-RANGE-EXTRACT [NEUTERED]/' "$SUT" > "$mutant_rng"
    d_rng="$TMP/p7-rng-teeth.md"
    { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "The method \`BinaryEncoder.java:10-20\`. \`[CERT]\`"; } > "$d_rng"
    mout_rng="$(bash "$mutant_rng" "$d_rng" 2>/dev/null)"
    if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$mout_rng"; then
      ok "teeth-p7-range-extract: neutered bt_cites → range-only block reverts to WARN (test 36 has teeth)"
    else
      no "teeth-p7-range-extract: neutered mutant did not revert to WARN :: $(grep -iE 'WARN|cert|extern' <<<"$mout_rng" | head -1)"
    fi
  else
    no "teeth-p7-range-extract: P7-BT-RANGE-EXTRACT sentinel not found in SUT"
  fi

  # teeth-p7-cmt-secondary: neuter P7-CMT-SECONDARY; secondary :161 must not be captured.
  echo "-- teeth-p7-cmt-secondary: neuter P7-CMT-SECONDARY; // :NNN,:MMM must lose :MMM --"
  mutant_cmtsec="$TMP/verify-block.P7CMTSEC.sh"
  if grep -q '# P7-CMT-SECONDARY' "$SUT"; then
    sed '/# P7-CMT-SECONDARY/ s/.*/_cmt_shorts=""  # P7-CMT-SECONDARY [NEUTERED]/' "$SUT" > "$mutant_cmtsec"
    d_cmtsec="$TMP/p7-cmtsec-teeth.md"
    { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "## Constants [CERT]"
      printf '```csharp\n'; echo "CONST_A = 15;  // :159,:161"; printf '```\n'; } > "$d_cmtsec"
    mout_cmtsec="$(bash "$mutant_cmtsec" "$d_cmtsec" 2>/dev/null)"
    if ! grep -qiE 'short.*:161|:161.*short' <<<"$mout_cmtsec"; then
      ok "teeth-p7-cmt-secondary: neutered secondary → :161 not captured (test 42 has teeth)"
    else
      no "teeth-p7-cmt-secondary: neutered mutant STILL captured :161 :: $(grep -iE ':161|short' <<<"$mout_cmtsec" | head -1)"
    fi
  else
    no "teeth-p7-cmt-secondary: P7-CMT-SECONDARY sentinel not found in SUT"
  fi

  # teeth-p6-probe: neuter P6-PROBE-FILE-CITE; a probe-cited block must revert to P6 WARN.
  # bash -n is run on the mutant first — a mutant with a syntax error cannot run and its control
  # passes for the wrong reason (that exact defect was caught in this repo).
  echo "-- teeth-p6-probe: neuter P6-PROBE-FILE-CITE; probe-cited block must revert to WARN --"
  mutant_probe="$TMP/verify-block.P6PROBE.sh"
  if grep -q '# P6-PROBE-FILE-CITE' "$SUT"; then
    sed '/# P6-PROBE-FILE-CITE/ s/.*/      probe_found=""  # P6-PROBE-FILE-CITE [NEUTERED]/' "$SUT" > "$mutant_probe"
    bash -n "$mutant_probe" 2>/dev/null; syntax_rc=$?
    if [ "$syntax_rc" != "0" ]; then
      no "teeth-p6-probe: mutant has syntax error (bash -n failed rc=$syntax_rc) — cannot run"
    else
      d_probe="$TMP/p6-probe-teeth.md"; mkdir -p "$TMP/sources/probes/test-probe"
      printf 'probe content\n' > "$TMP/sources/probes/test-probe/probe-20260729.txt"
      { echo "# Block — t"; echo
        echo "> Method: [CERT-hw] = live device response."; echo
        echo "---"; echo
        echo "## Live response [CERT-hw]"
        echo "[CERT-hw] (sources/probes/test-probe/probe-20260729.txt)"; } > "$d_probe"
      mout_probe="$(bash "$mutant_probe" "$d_probe" 2>/dev/null)"
      if grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero' <<<"$mout_probe"; then
        ok "teeth-p6-probe: neutered probe detection → probe-cited block reverts to WARN (test 43 has teeth)"
      else
        no "teeth-p6-probe: neutered probe mutant did NOT revert to WARN :: $(grep -iE 'WARN|probe|cert' <<<"$mout_probe" | head -2)"
      fi
    fi
  else
    no "teeth-p6-probe: P6-PROBE-FILE-CITE sentinel not found in SUT (probe detection not implemented or marker missing)"
  fi

  # teeth-n-project-fallback: neuter N-PROJECT-FALLBACK; nested-layout cite must revert to extern.
  # The sentinel is on the _bt_resolve reassignment line only (# N-PROJECT-FALLBACK, end of line);
  # the init line uses # N-PROJECT-FALLBACK-INIT and is NOT neutered so git_root is still derived.
  echo "-- teeth-n-project-fallback: neuter N-PROJECT-FALLBACK; nested cite must revert to extern --"
  mutant_npf="$TMP/verify-block.NPFMUTANT.sh"
  if grep -q '# N-PROJECT-FALLBACK$' "$SUT"; then
    sed '/# N-PROJECT-FALLBACK$/ s/.*/:  # N-PROJECT-FALLBACK [NEUTERED]/' "$SUT" > "$mutant_npf"
    bash -n "$mutant_npf" 2>/dev/null; npf_syntax=$?
    if [ "$npf_syntax" != "0" ]; then
      no "teeth-n-project-fallback: mutant has syntax error (bash -n rc=$npf_syntax) — cannot run"
    else
      mkdir -p "$TMP/npf-nested/src" "$TMP/npf-nested/corpus"
      git -C "$TMP/npf-nested" init -q 2>/dev/null
      seq 1 50 > "$TMP/npf-nested/src/tool.sh"
      d_npf="$TMP/npf-nested/corpus/block-npf.md"
      { echo "# Block NPF — nested layout"; echo
        echo "> Method: [CERT] = x."; echo
        echo "---"; echo
        echo "## NPF Observation [CERT]"
        echo "The function is defined at \`src/tool.sh:10\`. \`[CERT]\`"; } > "$d_npf"
      mout_npf="$(bash "$mutant_npf" "$d_npf" 2>/dev/null)"
      if grep -qiE 'extern.*src/tool' <<<"$mout_npf"; then
        ok "teeth-n-project-fallback: neutered fallback → nested cite goes extern (test 45 has teeth)"
      else
        no "teeth-n-project-fallback: neutered mutant did NOT revert to extern :: $(grep -iE 'extern|ok.*src|WARN' <<<"$mout_npf" | head -2)"
      fi
    fi
  else
    no "teeth-n-project-fallback: N-PROJECT-FALLBACK sentinel not found in SUT (fallback not implemented or marker missing)"
  fi

  # teeth-p6-doc-aware: neuter P6-DOC-AWARE-SUPPRESS; a [CERT-doc]-only block must revert to P6 WARN,
  # proving test 46 depends on the real doc-awareness branch (not a structural no-op).
  echo "-- teeth-p6-doc-aware: neuter P6-DOC-AWARE-SUPPRESS; [CERT-doc]-only block must revert to WARN --"
  mutant_doc="$TMP/verify-block.P6DOCAWARE.sh"
  if grep -q '# P6-DOC-AWARE-SUPPRESS' "$SUT"; then
    sed '/# P6-DOC-AWARE-SUPPRESS/ s/.*/    if false; then  # P6-DOC-AWARE-SUPPRESS [NEUTERED]/' "$SUT" > "$mutant_doc"
    bash -n "$mutant_doc" 2>/dev/null; doc_syntax=$?
    if [ "$doc_syntax" != "0" ]; then
      no "teeth-p6-doc-aware: mutant has syntax error (bash -n rc=$doc_syntax) — cannot run"
    else
      d_doc="$TMP/p6-docaware-teeth.md"
      { echo "# Block — doc corpus"; echo
        echo "> Method: [CERT-doc] = preserved PDF+page; [INFER] = deduction."; echo
        echo "---"; echo
        echo "## Config [CERT-doc]"
        echo "The panel accepts BACnet/IP over UDP. [CERT-doc]"; } > "$d_doc"
      mout_doc="$(bash "$mutant_doc" "$d_doc" 2>/dev/null)"
      if grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero' <<<"$mout_doc"; then
        ok "teeth-p6-doc-aware: neutered suppressor → [CERT-doc]-only block reverts to WARN (test 46 has teeth)"
      else
        no "teeth-p6-doc-aware: neutered mutant did NOT revert to WARN :: $(grep -iE 'WARN|cert|doc' <<<"$mout_doc" | head -2)"
      fi
    fi
  else
    no "teeth-p6-doc-aware: P6-DOC-AWARE-SUPPRESS sentinel not found in SUT (doc-awareness not implemented or marker missing)"
  fi
  # teeth-p6-wording: mutate the new P6 WARN message by stripping the "synthesis / REMITTANCE" expected-case
  # phrase; the warn line must then lack it, proving test 48's assertion bites (would fail on this mutant).
  echo "-- teeth-p6-wording: strip 'synthesis / REMITTANCE' phrase from P6 WARN; test 48 must detect absence --"
  mutant_wording="$TMP/verify-block.P6WORDING.sh"
  sed 's/Expected for synthesis \/ REMITTANCE[^"]*;//' "$SUT" > "$mutant_wording"
  d_wording="$TMP/p6-wording-teeth.md"
  { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
    echo "The flag is always set. [CERT]"; } > "$d_wording"
  mout_wording="$(bash "$mutant_wording" "$d_wording" 2>/dev/null)"
  mwarn_wording="$(grep -iE 'WARN.*\[CERT\]|WARN.*cert' <<<"$mout_wording" | head -1)"
  if ! echo "$mwarn_wording" | grep -qiE 'synthesis|REMITTANCE'; then
    ok "teeth-p6-wording: mutant lacks 'synthesis / REMITTANCE' → test 48 assertion would fail (has teeth)"
  else
    no "teeth-p6-wording: mutant STILL contains 'synthesis/REMITTANCE' — mutation did not take :: [$mwarn_wording]"
  fi

  # Tooth vb49: neutralize _vb_grep_err so cite-resolution error passes silently → test 49 goes red.
  echo "-- teeth-vb49: neutralize _vb_grep_err; -nF exit-2 must pass silently → test 49 goes red --"
  mutant_vb49="$TMP/verify-block.MUTANT-VB49.sh"
  sed 's/_vb_grep_err=\$_vb_h_rc/_vb_grep_err=0/' "$SUT" > "$mutant_vb49"
  out_vb49m="$(PATH="$_stub_vb49:$PATH" bash "$mutant_vb49" "$block_vb49" "$d_vb49" 2>&1)"
  grep -qiE 'citation resolution FAILED|unresolved.*grep exit' <<<"$out_vb49m" \
    && no "teeth-vb49: rc-zeroed mutant still emitted WARN — test 49 is THEATER" \
    || ok "teeth-vb49: rc-zeroed mutant passes silently — cite-resolution guard has teeth"

  # Tooth vb50: neutralize _vb_dedup_rc so dedup error passes silently → test 50 goes red.
  echo "-- teeth-vb50: neutralize _vb_dedup_rc; -vE exit-2 must pass silently → test 50 goes red --"
  mutant_vb50="$TMP/verify-block.MUTANT-VB50.sh"
  sed 's/_vb_dedup_rc=\$?/_vb_dedup_rc=0/' "$SUT" > "$mutant_vb50"
  out_vb50m="$(PATH="$_stub_vb50:$PATH" bash "$mutant_vb50" "$block_vb50" "$d_vb50" 2>&1)"
  grep -qiE 'citation dedup FAILED|unresolved.*grep exit' <<<"$out_vb50m" \
    && no "teeth-vb50: rc-zeroed mutant still emitted WARN — test 50 is THEATER" \
    || ok "teeth-vb50: rc-zeroed mutant passes silently — dedup guard has teeth"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
