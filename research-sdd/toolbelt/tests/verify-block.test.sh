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
MUT=""
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT
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
if grep -qE '1/2|= 0\.50' <<<"$(grep -E 'ratio' <<<"$out")"; then ok "ratio uses adjusted counts (1/2 = 0.50, not raw 2/3)"
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
if grep -qiE 'synthesis|REMITTANCE' <<<"$warn_line" \
   && grep -qiE 'block.type|block type|declaration' <<<"$warn_line"; then
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

# ---- P6-TYPE-CLASSIFY: Type token parsing changes WARN to INFO for declared no-citation types ------------

# 51 — declared 'synthesis' block with [CERT]+no-cites → INFO, not WARN.
d="$TMP/p6-type-synthesis.md"
{ echo "# Block 51 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** synthesis (no file:line cites — cross-block refs only)"; echo
  echo "---"; echo
  echo "## Summary [CERT]"; echo "The module is initialized via [Block 5]. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*expected for declared type synthesis' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "51 P6-TYPE-CLASSIFY: declared synthesis → INFO (not WARN)"
else
  no "51 P6-TYPE-CLASSIFY: synthesis not downgraded to INFO :: $(grep -iE 'INFO|WARN.*cert|cert.*zero' <<<"$out" | head -2)"
fi

# 52 — unrecognised Type token → WARN that names the token (never silent).
d="$TMP/p6-type-unrecognised.md"
{ echo "# Block 52 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** experimental-new-type"; echo
  echo "---"; echo
  echo "## Result [CERT]"; echo "The flag is always set. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*unrecogni' <<<"$out" && grep -q 'experimental-new-type' <<<"$out"; then
  ok "52 P6-TYPE-UNRECOGNISED: unrecognised token named in WARN"
else
  no "52 P6-TYPE-UNRECOGNISED: token not named :: $(grep -iE 'WARN|experimental|INFO' <<<"$out" | head -2)"
fi

# 53 — declared 'capture' (alias of document) → INFO, not WARN.
d="$TMP/p6-type-capture.md"
{ echo "# Block 53 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** capture — §20 document mode"; echo
  echo "---"; echo
  echo "## Known state [CERT]"; echo "The configuration is X. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*expected for declared type capture' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "53 P6-TYPE-CLASSIFY: declared capture → INFO (not WARN)"
else
  no "53 P6-TYPE-CLASSIFY: capture not downgraded to INFO :: $(grep -iE 'INFO|WARN.*cert' <<<"$out" | head -2)"
fi

# 54 — no Type line → WARN fires + grammar hint emitted.
d="$TMP/p6-type-none.md"
{ echo "# Block 54 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## Result [CERT]"; echo "The flag is always set. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out" && grep -qiE 'HINT.*[Tt]ype.*token|[Hh]int.*[Dd]eclare' <<<"$out"; then
  ok "54 P6-TYPE-CLASSIFY: no Type line → WARN + grammar hint"
else
  no "54 P6-TYPE-CLASSIFY: no-type WARN or hint missing :: $(grep -iE 'WARN|HINT' <<<"$out" | head -3)"
fi

# 55 — declared 'document' type (alias of capture) → INFO, not WARN.
d="$TMP/p6-type-document.md"
{ echo "# Block 55 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** document / runbook"; echo
  echo "---"; echo
  echo "## Runbook [CERT]"; echo "Procedure is defined in the ops guide. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*expected for declared type document' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "55 P6-TYPE-CLASSIFY: declared document → INFO (not WARN)"
else
  no "55 P6-TYPE-CLASSIFY: document not downgraded to INFO :: $(grep -iE 'INFO|WARN.*cert' <<<"$out" | head -2)"
fi

# 56 — declared 'standard' type (citation-expected) → WARN still fires.
d="$TMP/p6-type-standard.md"
{ echo "# Block 56 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** standard — primary evidence block"; echo
  echo "---"; echo
  echo "## Finding [CERT]"; echo "The method is defined. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out" && ! grep -qiE 'INFO.*declared type' <<<"$out"; then
  ok "56 P6-TYPE-CLASSIFY: declared standard (citation-expected) → WARN still fires (not INFO)"
else
  no "56 P6-TYPE-CLASSIFY: standard wrongly suppressed WARN or emitted INFO :: $(grep -iE 'WARN|INFO' <<<"$out" | head -2)"
fi

# ---- P6-TYPE-STRIP fix: backtick-wrapped legal tokens must parse correctly ---------------------------
# Fleet found 5 false-positives: **Type:** `capture` and **Type:** `mixed` emitted WARN with empty
# token because the old ordered strip (s/^\*\*//; s/^`//; s/^[[:space:]]*//) ran s/^`// BEFORE
# stripping the leading space — leaving the backtick intact when the value started with " `token`".
# The fix uses an order-independent combined strip: s/^[[:space:]*`]*// (space, asterisk, backtick
# in any order). Also: uppercase/non-conformant tokens (e.g. GAP-CLOSING SWEEP) must WARN by NAME,
# not by empty token ''.

# 57 — backtick-wrapped 'capture' (fleet: bloque792/798/799 format) → INFO (not WARN).
d="$TMP/p6-type-bt-capture.md"
{ echo "# Block 57 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** \`capture\` — §20 document mode"; echo
  echo "---"; echo
  echo "## Known state [CERT]"; echo "The configuration is X. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*expected for declared type capture' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "57 P6-TYPE-STRIP: backtick-wrapped 'capture' → INFO (order-independent strip)"
else
  no "57 P6-TYPE-STRIP: backtick-wrapped 'capture' not parsed correctly :: $(grep -iE 'INFO|WARN.*cert' <<<"$out" | head -2)"
fi

# 58 — backtick-wrapped 'mixed' (citation-expected) → WARN, NOT INFO, NOT 'empty token '''.
d="$TMP/p6-type-bt-mixed.md"
{ echo "# Block 58 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** \`mixed\` — evidence + synthesis"; echo
  echo "---"; echo
  echo "## Finding [CERT]"; echo "The method is defined. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out" && ! grep -qiE 'INFO.*declared type' <<<"$out" \
   && ! grep -qE "token ''" <<<"$out"; then
  ok "58 P6-TYPE-STRIP: backtick-wrapped 'mixed' → WARN (recognized, citation-expected, not empty-token)"
else
  no "58 P6-TYPE-STRIP: backtick 'mixed' wrong output :: $(grep -iE 'INFO|WARN|token' <<<"$out" | head -2)"
fi

# 59 — uppercase non-conformant token → WARN names the raw token (not empty '').
d="$TMP/p6-type-uppercase.md"
{ echo "# Block 59 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** GAP-CLOSING SWEEP — special form"; echo
  echo "---"; echo
  echo "## Finding [CERT]"; echo "The method is defined. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*unrecogni' <<<"$out" && grep -q 'GAP-CLOSING' <<<"$out" && ! grep -qE "token ''" <<<"$out"; then
  ok "59 P6-TYPE-DISPLAY: uppercase non-conformant → WARN names 'GAP-CLOSING' (not empty '')"
else
  no "59 P6-TYPE-DISPLAY: uppercase not named in WARN :: $(grep -iE 'WARN|GAP|token' <<<"$out" | head -2)"
fi

# ---- P6-BQ-STRIP: blockquote-prefixed ALL-CAPS type line (> **TYPE: VALUE**) must name the real value ----
# bloque274 / bloque279: type line is `> **TYPE: GAP-CLOSING SWEEP.**` — blockquote prefix, uppercase TYPE,
# value INSIDE the bold. The WARN must name the real token (GAP-CLOSING SWEEP), not the blockquote marker (>).
# CRITICAL: classification is UNCHANGED — the block is still unrecognised → WARN. Not accepted, not INFO.

# 60 — blockquote-prefixed ALL-CAPS > **TYPE: VALUE.** → WARN names real value, not '>'.
d="$TMP/p6-bq-allcaps.md"
{ echo "# Block 60 — t"; echo
  echo "> **TYPE: GAP-CLOSING SWEEP.**"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "## Finding [CERT]"; echo "The method is defined. [CERT]"; } > "$d"
out="$(run "$d")"
# WARN must fire (block is still unrecognised — not a valid Type domain extension).
# WARN must name 'GAP-CLOSING SWEEP' (the real value), NOT '>'.
# INFO must NOT fire (block is not accepted).
if grep -qiE 'WARN.*unrecogni' <<<"$out" \
   && grep -q 'GAP-CLOSING SWEEP' <<<"$out" \
   && ! grep -qE "token '>'" <<<"$out" \
   && ! grep -qiE 'INFO.*declared' <<<"$out"; then
  ok "60 P6-BQ-STRIP: blockquote ALL-CAPS > **TYPE: VALUE.** → WARN names 'GAP-CLOSING SWEEP' (not '>'); still WARN'd"
else
  no "60 P6-BQ-STRIP: wrong output :: $(grep -iE 'WARN|INFO|GAP|token' <<<"$out" | head -3)"
fi

# 61 — VB1-FIX: jar!entry citation only → jar-entry visibility printed AND NO P6 WARN.
# Fix for #771/#774/#780: a jar archive path IS a recognized non-resolvable citation form
# (like `extern` for backtick cites); the gate is not blind. Suppress the false WARN;
# keep the visibility line so the author knows the form was seen.
d="$TMP/vb1-jar.md"
{ echo "# Block — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "JAR entry control-rt.jar!META-INF/module.xml pinned at v3.2. [CERT]"; } > "$d"
out="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -q 'jar-entry' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero|WARN.*nothing' <<<"$out"; then
  ok "61 VB1-FIX: jar!entry only → jar-entry printed; NO P6 WARN (non-resolvable but recognized)"
else
  no "61 VB1-FIX: wrong output: jar=$(grep -ci 'jar-entry' <<<"$out") warn=$(grep -ciE 'WARN.*CERT|WARN.*zero|WARN.*nothing' <<<"$out") :: $(grep -iE 'jar|WARN|INFO|CERT' <<<"$out" | head -3)"
fi

# 62 — VB1-FIX: [BNNN] back-reference only → synth-ref visibility printed AND NO P6 WARN.
# Fix for #771/#774/#780: a block back-reference [BNNN] is a recognized non-resolvable citation
# form; the gate is not blind. Suppress the false WARN; keep the synth-ref visibility line.
d="$TMP/vb1-synth.md"
{ echo "# Block — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "As established in [B7] and [B12], the pattern holds. [CERT]"; } > "$d"
out="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -q 'synth-ref' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert|WARN.*zero|WARN.*nothing' <<<"$out"; then
  ok "62 VB1-FIX: [BNNN] back-ref only → synth-ref printed; NO P6 WARN (non-resolvable but recognized)"
else
  no "62 VB1-FIX: wrong output: synth=$(grep -ci 'synth-ref' <<<"$out") warn=$(grep -ciE 'WARN.*CERT|WARN.*zero|WARN.*nothing' <<<"$out") :: $(grep -iE 'synth|WARN|INFO|CERT' <<<"$out" | head -3)"
fi

# 63 — T-VB1: genuinely NO citations (no jar, no synth, no file:line) → P6 WARN fires (anti-silent-zero).
d="$TMP/vb1-nocite.md"
{ echo "# Block — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "---"; echo
  echo "No citations at all. [CERT]"; } > "$d"
out="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -qiE 'WARN.*ZERO.*citation|WARN.*checked nothing' <<<"$out"; then
  ok "63 T-VB1: no citations → P6 WARN still fires (anti-silent-zero preserved)"
else
  no "63 T-VB1: P6 WARN missing on genuinely-uncited block :: $(grep -iE 'WARN|INFO|CERT' <<<"$out" | head -3)"
fi

# 64 — T-VB2: declared 'decision' block with [CERT]+no-cites → INFO, not WARN.
# A decision block (migration pick, tool selection, architecture ruling) has high [INFER] ratio and
# zero file:line citations by design — same downgrade treatment as synthesis.
d="$TMP/p6-type-decision.md"
{ echo "# Block 64 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** decision — migration pick"; echo
  echo "---"; echo
  echo "## Decision [CERT]"; echo "Chose approach A over B. [CERT]"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*expected for declared type decision' <<<"$out" && ! grep -qiE 'WARN.*\[CERT\]|WARN.*cert' <<<"$out"; then
  ok "64 T-VB2 P6-TYPE-CLASSIFY: declared decision → INFO (not WARN)"
else
  no "64 T-VB2 P6-TYPE-CLASSIFY: decision not downgraded to INFO :: $(grep -iE 'INFO|WARN.*cert|cert.*zero|unrecogni' <<<"$out" | head -2)"
fi

# ---- SOURCE_ROOT: resolve [CERT] backtick citations into a decompiled/organized source tree -----
# Retro 2026-09-20 (wb-vendor-ux wave-3, issue #853): all 12 wave-3 blocks cite into
# `organized/*/vineflower/...` paths. Without SOURCE_ROOT, every backtick cite resolves `extern`.
# With $SOURCE_ROOT set, a file found at $SOURCE_ROOT/<path> resolves as `ok` instead.

# 65 — SOURCE_ROOT set; decompiled-tree single-line cite present at $SOURCE_ROOT → ok + exit 0 (not extern).
mkdir -p "$TMP/sr-root/organized/platBase/vineflower/com/example"
seq 1 30 > "$TMP/sr-root/organized/platBase/vineflower/com/example/Foo.java"
d="$TMP/sr-ok.md"
{ echo "# Block 65 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The method is defined at \`organized/platBase/vineflower/com/example/Foo.java:10\`. \`[CERT]\`"; } > "$d"
out="$(SOURCE_ROOT="$TMP/sr-root" bash "$SUT" "$d" 2>/dev/null)"
SOURCE_ROOT="$TMP/sr-root" bash "$SUT" "$d" >/dev/null 2>/dev/null; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok.*organized/platBase/vineflower/com/example/Foo\.java:10' <<<"$out"; then
  ok "65 SOURCE_ROOT: decompiled-tree cite → ok + exit 0 (not extern)"
else
  no "65 SOURCE_ROOT: decompiled-tree cite not resolved: rc=[$rc] :: $(grep -iE 'extern|ok.*Foo|Foo' <<<"$out" | head -1)"
fi

# 66 — SOURCE_ROOT set; range cite in decompiled tree, within bounds → ok + exit 0.
d="$TMP/sr-range.md"
{ echo "# Block 66 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The class body \`organized/platBase/vineflower/com/example/Foo.java:10-20\`. \`[CERT]\`"; } > "$d"
out="$(SOURCE_ROOT="$TMP/sr-root" bash "$SUT" "$d" 2>/dev/null)"
SOURCE_ROOT="$TMP/sr-root" bash "$SUT" "$d" >/dev/null 2>/dev/null; rc=$?
if [ "$rc" = "0" ] && grep -qE 'ok.*organized/platBase/vineflower/com/example/Foo\.java:10-20' <<<"$out"; then
  ok "66 SOURCE_ROOT: range cite in decompiled tree → ok + exit 0"
else
  no "66 SOURCE_ROOT: range cite not resolved: rc=[$rc] :: $(grep -iE 'extern|ok.*Foo|Foo' <<<"$out" | head -1)"
fi

# 67 — REGRESSION: SOURCE_ROOT not set; same path → extern (no accidental resolution without the env var).
d="$TMP/sr-noenv.md"
{ echo "# Block 67 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The method \`organized/platBase/vineflower/com/example/Foo.java:10\`. \`[CERT]\`"; } > "$d"
out="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -qiE 'extern.*organized/platBase/vineflower/com/example/Foo\.java:10' <<<"$out"; then
  ok "67 SOURCE_ROOT: env unset → extern (no false resolution, regression guard)"
else
  no "67 SOURCE_ROOT: unexpected output without SOURCE_ROOT :: $(grep -iE 'extern|ok.*Foo|Foo\.java' <<<"$out" | head -1)"
fi

# ---- P9-RESOLVED-SUMMARY: resolved N of M + WARN when N=0 and M>0 (issue #956) -------------------------
# When a block has bt/art citations that all fall back to extern/unresolved the citation gate exits 0
# silently having verified nothing. P9 prints "resolved N of M" and WARNs when N=0 and M>0, graded by
# the declared Type: (same taxonomy as P6). WARN-only: exit code is never changed.

# 68 — P9: [CERT] + single extern bt_cite, no Type → "resolved 0 of 1" shown + WARN fires + exit 0.
d="$TMP/p9-extern-no-type.md"
{ echo "# Block 68 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The method \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -q 'resolved 0 of 1' <<<"$out" && grep -qiE 'WARN.*resolved 0 of' <<<"$out"; then
  ok "68 P9: extern bt_cite + no Type → 'resolved 0 of 1' + WARN + exit 0"
else
  no "68 P9: wrong output: rc=[$rc] summary=$(grep -i 'resolved' <<<"$out" | head -1) warn=$(grep -i 'WARN' <<<"$out" | head -1)"
fi

# 69 — P9: partial resolve (1 ok + 1 extern) → "resolved 1 of 2"; no P9 WARN.
d="$TMP/p9-partial.md"; seq 1 30 > "$TMP/p9-real.java"
{ echo "# Block 69 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Real file \`p9-real.java:5\`. Missing \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -q 'resolved 1 of 2' <<<"$out" && ! grep -qiE 'WARN.*resolved 0 of' <<<"$out"; then
  ok "69 P9: partial resolution (1 ok + 1 extern) → 'resolved 1 of 2'; no P9 WARN"
else
  no "69 P9: wrong output: summary=$(grep -i 'resolved' <<<"$out" | head -1) warn=$(grep -i 'WARN.*resolved' <<<"$out" | head -1)"
fi

# 70 — P9: extern cite + Type: synthesis → INFO (not WARN).
d="$TMP/p9-synthesis.md"
{ echo "# Block 70 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** synthesis — cross-block"; echo
  echo "---"; echo
  echo "As seen in [B5] \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*resolved 0 of|resolved 0 of.*INFO' <<<"$out" && ! grep -qiE 'WARN.*resolved 0 of' <<<"$out"; then
  ok "70 P9: extern + Type: synthesis → INFO resolved 0 of N (not WARN)"
else
  no "70 P9: synthesis type not downgraded to INFO :: $(grep -iE 'INFO|WARN.*resolved' <<<"$out" | head -2)"
fi

# 71 — P9: extern cite + Type: standard → WARN fires.
d="$TMP/p9-standard.md"
{ echo "# Block 71 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** standard — primary evidence"; echo
  echo "---"; echo
  echo "The method \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*resolved 0 of' <<<"$out" && ! grep -qiE 'INFO.*resolved' <<<"$out"; then
  ok "71 P9: extern + Type: standard → WARN fires (citation-expected type)"
else
  no "71 P9: standard type wrong output :: $(grep -iE 'WARN.*resolved|INFO.*resolved' <<<"$out" | head -2)"
fi

# 72 — P9: no-Type WARN must mention SOURCE_ROOT (hint for decompiled-tree blocks).
d="$TMP/p9-sourceroot-hint.md"
{ echo "# Block 72 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The class \`organized/platBase/vineflower/com/Foo.java:5\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*resolved 0 of' <<<"$out" && grep -qi 'SOURCE_ROOT' <<<"$out"; then
  ok "72 P9: no-Type WARN mentions SOURCE_ROOT (hint for decompiled-tree blocks)"
else
  no "72 P9: SOURCE_ROOT hint absent :: $(grep -iE 'WARN.*resolved|SOURCE_ROOT' <<<"$out" | head -2)"
fi

# 73 — P9: range bt_cite resolves → "resolved 1 of 1"; no P9 WARN (catches P9-VB-OK-RANGE counter).
d="$TMP/p9-range-ok.md"; seq 1 30 > "$TMP/p9-range.java"
{ echo "# Block 73 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The loop \`p9-range.java:5-15\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -q 'resolved 1 of 1' <<<"$out" && ! grep -qiE 'WARN.*resolved 0 of' <<<"$out"; then
  ok "73 P9: range bt_cite resolves → 'resolved 1 of 1'; no P9 WARN"
else
  no "73 P9: wrong output: summary=$(grep -i 'resolved' <<<"$out" | head -1) warn=$(grep -i 'WARN.*resolved' <<<"$out" | head -1)"
fi

# 74 — P9: artifact cite ok → counted in both N and M; "resolved 1 of 1" (catches P9-VB-OK-ART / P9-VB-M-ART).
d="$TMP/p9-art-ok.md"; seq 1 30 > "$TMP/B96-art-ok.txt"
{ echo "# Block 74 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Order preserved (B96-art-ok.txt:10-20). \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -q 'resolved 1 of 1' <<<"$out" && ! grep -qiE 'WARN.*resolved 0 of' <<<"$out"; then
  ok "74 P9: art-cite ok → 'resolved 1 of 1'; no P9 WARN"
else
  no "74 P9: wrong output: summary=$(grep -i 'resolved' <<<"$out" | head -1) warn=$(grep -i 'WARN.*resolved' <<<"$out" | head -1)"
fi

# 75 — P9: extern cite + unrecognised Type → WARN names the type token (catches P9-TYPE-UNRECOGNISED).
d="$TMP/p9-unrec-type.md"
{ echo "# Block 75 — t"; echo
  echo "> Method: [CERT] = x."; echo
  echo "> **Type:** experimental"; echo
  echo "---"; echo
  echo "The method \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'WARN.*resolved 0 of' <<<"$out" && grep -q 'experimental' <<<"$out"; then
  ok "75 P9: extern + unrecognised Type → WARN names the type token"
else
  no "75 P9: unrecognised type not named in P9 WARN :: $(grep -iE 'WARN.*resolved|experimental' <<<"$out" | head -2)"
fi

# 76 — P9: doc-grade-only ([CERT-doc]) with extern cite → INFO not WARN (catches P9-DOC-GRADE-GUARD).
d="$TMP/p9-doc-grade.md"
{ echo "# Block 76 — t"; echo
  echo "> Method: [CERT-doc] = x."; echo
  echo "---"; echo
  echo "The method \`NonExistent.java:10\`. \`[CERT-doc]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'INFO.*resolved 0 of' <<<"$out" && ! grep -qiE 'WARN.*resolved 0 of' <<<"$out"; then
  ok "76 P9: doc-grade-only + extern cite → INFO (not WARN)"
else
  no "76 P9: doc-grade guard wrong: $(grep -iE 'WARN.*resolved|INFO.*resolved' <<<"$out" | head -2)"
fi

# 77 — P9: no-Type extern cite → HINT line present (catches P9-NO-TYPE-HINT).
d="$TMP/p9-no-type-hint.md"
{ echo "# Block 77 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "The method \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qiE 'HINT.*Declare.*Type' <<<"$out"; then
  ok "77 P9: no-Type extern cite → HINT line present"
else
  no "77 P9: HINT line absent :: $(grep -iE 'HINT.*Declare|WARN.*resolved' <<<"$out" | head -2)"
fi

# 78 — #1325: corpus that is its own git repo under $TARGET/corpus/ → own-project cite resolves at the TARGET root.
#      (git rev-parse from the corpus returns the CORPUS root, so N-PROJECT-FALLBACK alone cannot see src/.)
pr="$TMP/p1325"; mkdir -p "$pr/src" "$pr/corpus/sub"; git -C "$pr/corpus" init -q 2>/dev/null
seq 1 60 > "$pr/src/index.js"; : > "$pr/package.json"
{ echo "# Block 78 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Handler at \`src/index.js:50-52\`. \`[CERT]\`"; } > "$pr/corpus/block-78.md"
out="$(bash "$SUT" "$pr/corpus/block-78.md" 2>/dev/null)"; rc=$?
if [ "$rc" = 0 ] && grep -qE '^\s+ok \(target-root\) src/index\.js:50-52' <<<"$out" && grep -q 'resolved 1 of 1' <<<"$out" && ! grep -q 'extern' <<<"$out"; then
  ok "78 #1325: own-git corpus under \$TARGET/corpus/ → cite resolves at the TARGET root (ok, resolved 1 of 1)"
else no "78 #1325: target-root cite not resolved: rc=$rc :: $(grep -E 'src/index|resolved' <<<"$out" | head -2)"; fi

# 78b — same layout, block in a corpus SUB-directory (target-dir = corpus/sub) → walk up to the corpus root's parent.
cp "$pr/corpus/block-78.md" "$pr/corpus/sub/block-78b.md"
out="$(bash "$SUT" "$pr/corpus/sub/block-78b.md" 2>/dev/null)"
if grep -qE '^\s+ok \(target-root\) src/index\.js:50-52' <<<"$out"; then ok "78b #1325: block in corpus/sub → cite resolves at the TARGET root"
else no "78b #1325: sub-directory block not resolved :: $(grep -E 'src/index|resolved' <<<"$out" | head -2)"; fi

# 79 — #1325 (negative half): a TARGET-root file that is TOO SHORT for the cite still FAILS (RANGE!, exit 1), never ok.
{ echo "# Block 79 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Handler at \`src/index.js:500-502\`. \`[CERT]\`"; } > "$pr/corpus/block-79.md"
out="$(bash "$SUT" "$pr/corpus/block-79.md" 2>/dev/null)"; rc=$?
if [ "$rc" = 1 ] && grep -qE 'RANGE!\s+src/index\.js:500-502' <<<"$out"; then ok "79 #1325: target-root file shorter than the cite → RANGE! + exit 1"
else no "79 #1325: out-of-range at target root not flagged: rc=$rc :: $(grep -E 'src/index|resolved' <<<"$out" | head -2)"; fi

# 79b — #1325 (regression guard): a corpus dir NOT named 'corpus' gets NO parent walk-up — the cite stays extern.
pn="$TMP/p1325n"; mkdir -p "$pn/src" "$pn/notes"; seq 1 60 > "$pn/src/index.js"
{ echo "# Block 79b — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
  echo "Handler at \`src/index.js:50-52\`. \`[CERT]\`"; } > "$pn/notes/block-79b.md"
out="$(bash "$SUT" "$pn/notes/block-79b.md" 2>/dev/null)"
if grep -qE 'extern\s+src/index\.js:50-52' <<<"$out"; then ok "79b #1325: non-'corpus' directory → no parent walk-up (still extern)"
else no "79b #1325: unexpected resolution outside a corpus/ layout :: $(grep -E 'src/index|resolved' <<<"$out" | head -2)"; fi

# 80 — #1325 P6: probe-file cites are REPORTED as 'resolved N of M', not silenced (first-present/last-missing and the reverse).
pp="$TMP/p1325p"; mkdir -p "$pp/sources/probes"; printf 'x\n' > "$pp/sources/probes/a-present.txt"
{ echo "# Block 80 — t"; echo; echo "> Method: [CERT-hw] = x."; echo; echo "---"; echo
  echo "[CERT-hw] (sources/probes/a-present.txt) and (sources/probes/z-missing.txt)"; } > "$pp/block-80.md"
out="$(bash "$SUT" "$pp/block-80.md" 2>/dev/null)"
if grep -q 'probe-file cites resolved 1 of 2' <<<"$out"; then ok "80 #1325 P6: probe cites reported as 'resolved 1 of 2' (present first, missing last)"
else no "80 #1325 P6: probe resolved-N-of-M absent :: $(grep -iE 'probe|resolved' <<<"$out" | head -3)"; fi
{ echo "# Block 80b — t"; echo; echo "> Method: [CERT-hw] = x."; echo; echo "---"; echo
  echo "[CERT-hw] (sources/probes/a-missing.txt) and (sources/probes/z-present.txt)"; } > "$pp/block-80b.md"
printf 'x\n' > "$pp/sources/probes/z-present.txt"
out="$(bash "$SUT" "$pp/block-80b.md" 2>/dev/null)"
if grep -q 'probe-file cites resolved 1 of 2' <<<"$out"; then ok "80b #1325 P6: probe cites reported as 'resolved 1 of 2' (missing first, present last)"
else no "80b #1325 P6: probe resolved-N-of-M absent :: $(grep -iE 'probe|resolved' <<<"$out" | head -3)"; fi

# 80c — a single probe cite beside several [CERT] code markers must still surface the coverage gap.
{ echo "# Block 80c — t"; echo; echo "> Method: [CERT-hw] = x."; echo; echo "---"; echo
  echo "a [CERT-hw] b [CERT-hw] c [CERT-hw] d [CERT-hw] (sources/probes/a-present.txt)"; } > "$pp/block-80c.md"
out="$(bash "$SUT" "$pp/block-80c.md" 2>/dev/null)"
if grep -q 'probe-file cites resolved 1 of 1' <<<"$out" && grep -qE 'INFO.*4 \[CERT\].*1 resolved' <<<"$out"; then ok "80c #1325 P6: one probe cite vs 4 code markers → coverage INFO, not silence"
else no "80c #1325 P6: coverage gap not surfaced :: $(grep -iE 'probe|resolved|INFO' <<<"$out" | head -3)"; fi

# 81 — #1418: an unrecognised Type token keeps its DIGITS in the WARN display (experimental-p9, not experimental-p).
for _t in "experimental-p9" "v2-draft" "p9"; do
  d="$TMP/p1418-${_t}.md"
  { echo "# Block 81 — t"; echo; echo "> Method: [CERT] = x."; echo; echo "> **Type:** $_t"; echo; echo "---"; echo
    echo "The method \`NonExistent.java:10\`. \`[CERT]\`"; } > "$d"
  out="$(run "$d")"
  if grep -qE "unrecognised Type: '$_t';" <<<"$out"; then ok "81 #1418: Type '$_t' displayed intact in the P9 WARN"
  else no "81 #1418: Type '$_t' mangled :: $(grep -E 'unrecognised' <<<"$out" | head -2)"; fi
done
# 81b — same for the P6 (zero-citation) WARN.
d="$TMP/p1418-p6.md"
{ echo "# Block 81b — t"; echo; echo "> Method: [CERT] = x."; echo; echo "> **Type:** experimental-p9"; echo; echo "---"; echo
  echo "A claim. \`[CERT]\`"; } > "$d"
out="$(run "$d")"
if grep -qE "unrecognised Type: token 'experimental-p9';" <<<"$out"; then ok "81b #1418: P6 WARN displays 'experimental-p9' intact"
else no "81b #1418: P6 Type display mangled :: $(grep -E 'unrecognised' <<<"$out" | head -1)"; fi

# ---- #1325 fix-first round: target root must be BOUNDED, VISIBLE, and must not pre-empt a fitting root ----
vbcite(){ local f="$1"; shift; { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; printf 'Cites: `%s`. `[CERT]`\n' "$@"; } > "$f"; }

# 82 — F1(a): a fake HOME that IS the parent of corpus/ is refused even when it carries a project marker.
h="$TMP/f1h/home"; mkdir -p "$h/corpus" "$h/.ssh"; : > "$h/package.json"; echo x > "$h/config.sh"; echo k > "$h/.ssh/id_rsa.pub"
vbcite "$h/corpus/b.md" "config.sh:1" ".ssh/id_rsa.pub:1"
out="$(HOME="$h" bash "$SUT" "$h/corpus/b.md" 2>/dev/null)"
if grep -qE 'extern\s+config\.sh:1' <<<"$out" && grep -qE 'extern\s+\.ssh/id_rsa\.pub:1' <<<"$out" && ! grep -qE '^\s+ok' <<<"$out"; then
  ok "82 F1a: target root == \$HOME refused (dotfile/secret cites stay extern)"
else no "82 F1a: \$HOME resolved as target root :: $(grep -E 'config|id_rsa' <<<"$out" | head -2)"; fi

# 82b — F1(a): a target root that is an ANCESTOR of $HOME is refused (marker present, so only the guard can refuse).
a="$TMP/f1a"; mkdir -p "$a/corpus/projects/foo/notes"; : > "$a/package.json"; echo p > "$a/passwd.txt"
vbcite "$a/corpus/projects/foo/notes/b.md" "passwd.txt:1"
out="$(HOME="$a/corpus/projects/foo" bash "$SUT" "$a/corpus/projects/foo/notes/b.md" 2>/dev/null)"
if grep -qE 'extern\s+passwd\.txt:1' <<<"$out" && ! grep -qE '^\s+ok' <<<"$out"; then ok "82b F1a: target root that is an ancestor of \$HOME refused"
else no "82b F1a: ancestor-of-HOME accepted :: $(grep -E 'passwd' <<<"$out" | head -2)"; fi

# 82c — F1(b): a corpus ancestor whose parent carries NO project marker is not a project root → extern.
m="$TMP/f1b"; mkdir -p "$m/corpus/x"; echo s > "$m/secret.txt"
vbcite "$m/corpus/x/b.md" "secret.txt:1"
out="$(bash "$SUT" "$m/corpus/x/b.md" 2>/dev/null)"
if grep -qE 'extern\s+secret\.txt:1' <<<"$out" && ! grep -qE '^\s+ok' <<<"$out"; then ok "82c F1b: markerless parent of corpus/ is not a project root (extern)"
else no "82c F1b: markerless parent accepted :: $(grep -E 'secret' <<<"$out" | head -2)"; fi

# 82d — F1(b): a git work-tree top (its `.git` entry is the marker) IS a project root even when corpus/ is a nested repo.
g="$TMP/f1g"; mkdir -p "$g/corpus" "$g/src"; git -C "$g" init -q 2>/dev/null; git -C "$g/corpus" init -q 2>/dev/null; seq 1 5 > "$g/src/a.sh"
vbcite "$g/corpus/b.md" "src/a.sh:2"
out="$(bash "$SUT" "$g/corpus/b.md" 2>/dev/null)"
if grep -qE 'ok \(target-root\) src/a\.sh:2' <<<"$out"; then ok "82d F1b: git work-tree top accepted as project root"
else no "82d F1b: git top refused :: $(grep -E 'src/a' <<<"$out" | head -2)"; fi

# 82e — F1(b): each documented marker file alone qualifies (list edges: first, middle, last).
for mk in package.json Makefile Cargo.toml; do
  q="$TMP/f1m-$mk"; mkdir -p "$q/corpus"; : > "$q/$mk"; seq 1 5 > "$q/z.sh"; vbcite "$q/corpus/b.md" "z.sh:2"
  out="$(bash "$SUT" "$q/corpus/b.md" 2>/dev/null)"
  if grep -qE 'ok \(target-root\) z\.sh:2' <<<"$out"; then ok "82e F1b: marker '$mk' qualifies"
  else no "82e F1b: marker '$mk' not honoured :: $(grep -E 'z\.sh' <<<"$out" | head -1)"; fi
done

# 83 — F2: the first EXISTING root must not pre-empt a root where the cited range FITS.
f2="$TMP/p2"; mkdir -p "$f2/corpus" "$TMP/p2sr"; : > "$f2/package.json"; seq 1 3 > "$f2/lib.sh"; seq 1 100 > "$TMP/p2sr/lib.sh"
vbcite "$f2/corpus/b.md" "lib.sh:50"
out="$(SOURCE_ROOT="$TMP/p2sr" bash "$SUT" "$f2/corpus/b.md" 2>/dev/null)"; rc=$?
if [ "$rc" = 0 ] && grep -qE '^\s+ok\s+lib\.sh:50' <<<"$out" && ! grep -q 'RANGE!' <<<"$out"; then ok "83 F2: short target-root file does not pre-empt a SOURCE_ROOT file that fits (ok, exit 0)"
else no "83 F2: first-existing root pre-empted :: rc=$rc $(grep -E 'lib\.sh' <<<"$out" | head -1)"; fi
# 83b — other direction: the cite fits the FIRST root → that root wins (labelled), no SOURCE_ROOT needed.
vbcite "$f2/corpus/b2.md" "lib.sh:2"
out="$(SOURCE_ROOT="$TMP/p2sr" bash "$SUT" "$f2/corpus/b2.md" 2>/dev/null)"
if grep -qE 'ok \(target-root\) lib\.sh:2' <<<"$out"; then ok "83b F2: fitting first root wins (target-root)"
else no "83b F2: first fitting root not used :: $(grep -E 'lib\.sh' <<<"$out" | head -1)"; fi
# 83c — nothing fits: RANGE! against the FIRST existing file, exit 1.
vbcite "$f2/corpus/b3.md" "lib.sh:500"
out="$(SOURCE_ROOT="$TMP/p2sr" bash "$SUT" "$f2/corpus/b3.md" 2>/dev/null)"; rc=$?
if [ "$rc" = 1 ] && grep -qE 'RANGE!\s+lib\.sh:500\s+\(file has 3 lines\)' <<<"$out"; then ok "83c F2: no root fits → RANGE! against the first existing file (3 lines), exit 1"
else no "83c F2: wrong no-fit report :: rc=$rc $(grep -E 'lib\.sh' <<<"$out" | head -1)"; fi

# 84 — F3: nested corpus/…/corpus → the NEAREST corpus ancestor decides (inner parent has the marker + file).
n3="$TMP/p3"; mkdir -p "$n3/corpus/inner/corpus"; : > "$n3/package.json"; : > "$n3/corpus/inner/package.json"
seq 1 5 > "$n3/corpus/inner/inner.sh"; seq 1 5 > "$n3/outer.sh"
vbcite "$n3/corpus/inner/corpus/b.md" "inner.sh:2" "outer.sh:2"
out="$(bash "$SUT" "$n3/corpus/inner/corpus/b.md" 2>/dev/null)"
if grep -qE 'ok \(target-root\) inner\.sh:2' <<<"$out" && grep -qE 'extern\s+outer\.sh:2' <<<"$out"; then ok "84 F3: nearest corpus ancestor wins (inner ok, outer extern)"
else no "84 F3: nested corpus resolved wrongly :: $(grep -E 'inner|outer' <<<"$out" | head -2)"; fi

# 84b — F3: a directory merely CONTAINING 'corpus' (corpus-old) is not a corpus dir → extern.
o4="$TMP/p4"; mkdir -p "$o4/corpus-old" "$o4/src"; : > "$o4/package.json"; seq 1 5 > "$o4/src/x.sh"
vbcite "$o4/corpus-old/b.md" "src/x.sh:2"
out="$(bash "$SUT" "$o4/corpus-old/b.md" 2>/dev/null)"
if grep -qE 'extern\s+src/x\.sh:2' <<<"$out"; then ok "84b F3: 'corpus-old' is not a corpus dir (extern)"
else no "84b F3: substring match on corpus :: $(grep -E 'x\.sh' <<<"$out" | head -1)"; fi

# #1487 — EMPTY-INPUT DIGEST in a cited hash. A hash equal to the digest of empty input proves nothing
# (the file was missing/empty when hashed). FAIL (exit 1) with a typed `EMPTYHASH!` finding naming the line.
# The match is on a whole hex token: a longer hex run that merely CONTAINS the digest must NOT fire.
E256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
E1=da39a3ee5e6b4b0d3255bfef95601890afd80709
EMD5=d41d8cd98f00b204e9800998ecf8427e
OKH=abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234
eh_block() { # <name> <body-line...> — header legend + body
  local f="$TMP/eh-$1.md"; shift
  { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"
}
eh_check() { # <name> <want-rc> <want-count> <label>
  local f="$TMP/eh-$1.md" out got n
  out="$(bash "$SUT" "$f" 2>&1)"; got=$?
  n="$(grep -c 'EMPTYHASH!' <<<"$out")"
  if [ "$got" = "$2" ] && [ "$n" = "$3" ]; then ok "$4 (exit $got, $n finding(s))"
  else no "$4 :: want exit $2/$3 finding(s), got $got/$n"; fi
}
eh_block single "## 1.1 [INFER] kotlin-stdlib sha256 $E256 registered."
eh_check single 1 1 "#1487 BAD: single cited sha256 empty digest"
eh_block first "sha256 $E256" "sha256 $OKH" "sha256 $OKH"
eh_check first 1 1 "#1487 BAD: empty digest on FIRST body line"
eh_block middle "sha256 $OKH" "sha256 $E256" "sha256 $OKH"
eh_check middle 1 1 "#1487 BAD: empty digest on MIDDLE body line"
eh_block last "sha256 $OKH" "sha256 $OKH" "sha256 $E256"
eh_check last 1 1 "#1487 BAD: empty digest on LAST body line"
eh_block sha1 "sha1 $E1"
eh_check sha1 1 1 "#1487 BAD: sha1 empty digest"
eh_block md5 "md5 $EMD5"
eh_check md5 1 1 "#1487 BAD: md5 empty digest"
eh_block upper "sha256 $(printf '%s' "$E256" | tr 'a-f' 'A-F')"
eh_check upper 1 1 "#1487 BAD: UPPERCASE empty digest"
eh_block tick "sha256 \`$E256\`"
eh_check tick 1 1 "#1487 BAD: backticked empty digest"
eh_block table "| kotlin-stdlib | $E256 |"
eh_check table 1 1 "#1487 BAD: empty digest in a table cell"
eh_block elided "sha256 e3b0c442…"
eh_check elided 1 1 "#1487 BAD: elided empty-digest prefix"
eh_block two "a $E256" "b $E1"
eh_check two 1 2 "#1487 BAD: two lines -> two findings"
eh_block twosame "| $E256 | again $E256 |"
eh_check twosame 1 2 "#1487 BAD: same digest twice on one line -> two findings"
# NEGATIVES — must stay exit 0 / no finding
eh_block sub-long "x ${E256}00" "y ff${E1}" "z ${EMD5}ab"
eh_check sub-long 0 0 "#1487 GOOD: digest as substring of a longer hex run"
eh_block sub-word "xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
eh_check sub-word 0 0 "#1487 GOOD: digest glued to a word char is not a hash token"
eh_block short-pfx "sha256 e3b0c4…"
eh_check short-pfx 0 0 "#1487 GOOD: short prefix (<8 hex) is no claim"
eh_block waived "n5 registered the empty digest $E256 for a missing file. <!-- empty-digest: quoted -->"
eh_check waived 0 0 "#1487 GOOD: waived quoted digest is not a FAIL"
eh_w_out="$(bash "$SUT" "$TMP/eh-waived.md" 2>&1)"
if grep -q "^   INFO    empty-digest waived on line 7" <<<"$eh_w_out"; then ok "#1487 waived hit is reported as INFO (not silent)"; else no "#1487 waived hit not reported as INFO"; fi
eh_block waive-other "n5 registered the empty digest $E256 for a missing file. <!-- empty-digest: quoted -->" "but $E1 here is unwaived"
eh_check waive-other 1 1 "#1487 BAD: waiver covers only its own line"
eh_block waive-elided "sha256 e3b0c442… <!-- empty-digest: quoted -->"
eh_check waive-elided 0 0 "#1487 GOOD: waived elided prefix"
eh_block clean "sha256 $OKH"
eh_check clean 0 0 "#1487 GOOD: ordinary hash"

# #1500 — fail-open: the awk detector must not die or go blind silently. The stub intercepts ONLY the
# empty-digest program (its text carries EMPTY-DIGEST-TABLE); every other awk call runs the real awk.
#   silent: prints nothing, exit 0 (dialect-mismatch shape); rcfail: real output but exit 3.
_eh_real_awk="$(command -v awk)"
for _eh_mode in silent rcfail; do
  _eh_stub="$TMP/stub-bin-eh-$_eh_mode"; mkdir -p "$_eh_stub"
  case "$_eh_mode" in silent) _eh_act='exit 0';; rcfail) _eh_act='"'"$_eh_real_awk"'" "$@"; exit 3';; esac
  cat > "$_eh_stub/awk" <<STUB_EH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *EMPTY-DIGEST-TABLE*) $_eh_act;; esac; done
exec "$_eh_real_awk" "\$@"
STUB_EH
  chmod +x "$_eh_stub/awk"
done
eh_degraded() { # <mode> <label>
  local out got
  out="$(PATH="$TMP/stub-bin-eh-$1:$PATH" bash "$SUT" "$TMP/eh-clean.md" 2>&1)"; got=$?
  if [ "$got" = 1 ] && grep -q 'ERROR: empty-digest scan DEGRADED' <<<"$out" && ! grep -q '(none — no unwaived' <<<"$out"
  then ok "$2 (exit 1, typed degraded line)"
  else no "$2 :: want exit 1 + DEGRADED line, got $got"; fi
}
eh_degraded silent "#1500 BAD: blind detector (no trailer) is degraded"
eh_degraded rcfail "#1500 BAD: detector exit != 0 is degraded"

# kit #1207 part 2 — EPHEMERAL-PATH cites FAIL. A cited path under /tmp, /var/tmp, $TMPDIR or a session
# scratchpad is evidence that will not exist next session. Every cite form verify-block parses (`file:N`,
# `file:N-M`, bare backticked path, parenthetical path, table cell, prose) must be covered, [CERT*] or not.
# The §5 beautified-temp view (a line carrying a sha256 anchor) stays an INFO, never a FAIL.
SPAD=/tmp/claude-1000/-home-x/0123-abcd/scratchpad
ep_block() { # <name> <body-line...> — header legend + body
  local f="$TMP/ep-$1.md"; shift
  { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"
}
ep_check() { # <name> <want-rc> <want-count> <label>
  local f="$TMP/ep-$1.md" out got n
  out="$(bash "$SUT" --strict-ephemeral "$f" 2>&1)"; got=$?
  n="$(grep -c 'EPHEMERAL!' <<<"$out")"
  if [ "$got" = "$2" ] && [ "$n" = "$3" ]; then ok "$4 (strict: exit $got, $n finding(s))"
  else no "$4 :: want exit $2/$3 finding(s), got $got/$n"; fi
}
ep_block single "Wrapper starts the loop [CERT] \`/tmp/probe/run.sh:12\`"
ep_check single 1 1 "#1207 BAD: [CERT] backticked /tmp file:N"
ep_block range "Wrapper starts the loop [CERT] \`/tmp/probe/run.sh:12-20\`"
ep_check range 1 1 "#1207 BAD: [CERT] backticked /tmp file:N-M"
ep_block bare "Output kept in \`/tmp/probe/out.txt\` [CERT-hw]"
ep_check bare 1 1 "#1207 BAD: bare backticked /tmp path (no line)"
ep_block paren "Output kept (see /tmp/probe/out.txt) [CERT-hw]"
ep_check paren 1 1 "#1207 BAD: parenthetical /tmp path"
ep_block vartmp "Dump at \`/var/tmp/dump.bin\` [INFER]"
ep_check vartmp 1 1 "#1207 BAD: /var/tmp path, non-CERT line"
ep_block spad "Captured in \`$SPAD/fidelity/t1.txt\` [CERT-hw]"
ep_check spad 1 1 "#1207 BAD: /tmp/claude-*/…/scratchpad/ path"
ep_block relspad "Evidence sits in scratchpad/fidelity/t1.txt"
ep_check relspad 1 1 "#1207 BAD: relative scratchpad/ path"
ep_block tmpdir "Built into \$TMPDIR/build/a.out"
ep_check tmpdir 1 1 "#1207 BAD: \$TMPDIR/ path"
ep_block table "| image | /tmp/img/a.png |"
ep_check table 1 1 "#1207 BAD: /tmp path in a table cell"
ep_block fence "\`\`\`" "cp /tmp/patched.bin ./x" "\`\`\`"
ep_check fence 1 1 "#1207 BAD: /tmp path inside a code fence"
ep_block first "ref \`/tmp/a.sh:1\`" "ref \`src/ok.c:1\`" "ref \`src/ok.c:2\`"
ep_check first 1 1 "#1207 BAD: ephemeral cite on FIRST body line"
ep_block middle "ref \`src/ok.c:1\`" "ref \`/tmp/a.sh:1\`" "ref \`src/ok.c:2\`"
ep_check middle 1 1 "#1207 BAD: ephemeral cite on MIDDLE body line"
ep_block last "ref \`src/ok.c:1\`" "ref \`src/ok.c:2\`" "ref \`/tmp/a.sh:1\`"
ep_check last 1 1 "#1207 BAD: ephemeral cite on LAST body line"
ep_block twoline "a \`/tmp/a.sh:1\` and \`/tmp/b.sh:2\` on one line"
ep_check twoline 1 2 "#1207 BAD: two ephemeral cites on one line are both reported"
ep_block anchored "Beautified view \`/tmp/app.beautified.js:40\` of app.min.js sha256 a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4 (4096 bytes) [CERT]"
ep_check anchored 0 0 "#1207 GOOD: sha256-anchored beautified-temp view is exempt"
ep_block anchored-other "Beautified view \`/tmp/app.beautified.js:40\` sha256 a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4" "also \`/tmp/probe/run.sh:3\`"
ep_check anchored-other 1 1 "#1207 BAD: the sha256 anchor exempts only its own line"
ep_block glued "see \`src/tmp/x.c:3\` and ./tmp/y.c:4 and /home/u/tmp/z.c:5 and my-scratchpad-notes"
ep_check glued 0 0 "#1207 GOOD: tmp as a middle path segment never fires"
ep_block nodigest "sha256 not computed, see \`/tmp/x/app.js:3\`"
ep_check nodigest 1 1 "#1207 BAD: the word sha256 without a digest is not an anchor"
ep_block shortdigest "view \`/tmp/x/app.js:3\` sha256 abcd1234"
ep_check shortdigest 1 1 "#1207 BAD: a short hex token is not a 64-hex anchor"
ep_block longhex "view \`/tmp/x/app.js:3\` sha256 a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d40"
ep_check longhex 1 1 "#1207 BAD: a 65-hex run is not a 64-hex digest"
ep_block digestwith "view \`/tmp/x/app.js:3\` sha256=a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
ep_check digestwith 0 0 "#1207 GOOD: sha256= followed by a 64-hex digest anchors the line"
ep_block spadabs "Script in \`/home/u/proj/scratchpad/x.sh\` [CERT]"
ep_check spadabs 1 1 "#1207 BAD: scratchpad segment inside a longer absolute path"
ep_block spadrel2 "Script in a/b/scratchpad/c.txt only"
ep_check spadrel2 1 1 "#1207 BAD: scratchpad segment inside a longer relative path"
ep_block spadtmpdir "Kept in \$TMPDIR/scratchpad/x.txt and \${TMPDIR}/scratchpad/y.txt"
ep_check spadtmpdir 1 2 "#1207 BAD: \$TMPDIR/scratchpad paths are owned by the tmp arm only (counted once each)"
ep_block spadglue "see my-scratchpad/x.txt and notscratchpad/y.txt"
ep_check spadglue 0 0 "#1207 GOOD: scratchpad as the tail of a longer segment name is not a segment"
ep_block clean "Plain claim [CERT] \`src/ok.c:1\`"
ep_check clean 0 0 "#1207 GOOD: block with no ephemeral path"
out="$(bash "$SUT" --strict-ephemeral "$TMP/ep-single.md" 2>&1)"
if grep -qE 'EPHEMERAL!  /tmp/probe/run\.sh:12  \(line [0-9]+; session/temp path — preserve under sources/probes/b<N>/\)' <<<"$out"
then ok "#1207: typed EPHEMERAL! line names the cited token and the preservation convention"
else no "#1207: typed line shape :: $(grep EPHEMERAL <<<"$out" | head -1)"; fi
out="$(bash "$SUT" "$TMP/ep-anchored.md" 2>&1)"
if grep -q 'INFO    ephemeral-anchored line' <<<"$out"; then ok "#1207: anchored temp view is reported as INFO, never silent"
else no "#1207: anchored INFO line missing"; fi
out="$(bash "$SUT" "$TMP/ep-clean.md" 2>&1)"
if grep -q '(none — no unanchored ephemeral path cited; sha256-anchored: 0, ephemeral-ok: 0, invalid markers: 0)' <<<"$out"; then ok "#1207: clean block prints an explicit none line (looked, found zero)"
else no "#1207: clean none line missing"; fi


# staged enforcement (kit #1207): default = typed WARN EPHEMERAL? (exit unchanged); --strict-ephemeral / env = FAIL.
ep_default() { # <name> <want-warns> <label>
  local out got n
  out="$(bash "$SUT" "$TMP/ep-$1.md" 2>&1)"; got=$?
  n="$(grep -c 'EPHEMERAL?' <<<"$out")"
  if [ "$got" = 0 ] && [ "$n" = "$2" ] && ! grep -q 'EPHEMERAL!' <<<"$out"; then ok "$3 (default: exit 0, $n WARN)"
  else no "$3 :: want exit 0 + $2 WARN, got $got/$n"; fi
}
ep_default single 1 "#1207 staged: /tmp cite is a WARN by default"
ep_default twoline 2 "#1207 staged: two cites on one line are two WARNs"
ep_default middle 1 "#1207 staged: WARN for a cite on the MIDDLE line"
out="$(RSDD_STRICT_EPHEMERAL=1 bash "$SUT" "$TMP/ep-single.md" 2>&1)"; got=$?
{ [ "$got" = 1 ] && grep -q 'EPHEMERAL!' <<<"$out"; } && ok "#1207 staged: RSDD_STRICT_EPHEMERAL=1 makes it a FAIL" || no "#1207 staged: env strict (rc=$got)"
out="$(RSDD_STRICT_EPHEMERAL=0 bash "$SUT" "$TMP/ep-single.md" 2>&1)"; got=$?
{ [ "$got" = 0 ] && grep -q 'EPHEMERAL?' <<<"$out"; } && ok "#1207 staged: RSDD_STRICT_EPHEMERAL=0 keeps the WARN" || no "#1207 staged: env 0 (rc=$got)"
out="$(bash "$SUT" "$TMP/ep-single.md" 2>&1)"
grep -q 'ephemeral-path cites: 1 (WARN' <<<"$out" && ok "#1207 staged: summary says WARN and how to go strict" || no "#1207 staged: summary line"
# per-line marker `<!-- ephemeral-ok: <reason> -->` (mirrors `<!-- empty-digest: quoted -->`)
ep_block mk-ok "So the add-on receives \`/tmp/blender_screenshot_<pid>.png\` from the server <!-- ephemeral-ok: path string produced by the subject, not evidence -->"
ep_block mk-no "So the add-on receives \`/tmp/blender_screenshot_<pid>.png\` from the server"
ep_block mk-empty "So the add-on receives \`/tmp/blender_screenshot_<pid>.png\` <!-- ephemeral-ok: -->"
ep_block mk-blank "So the add-on receives \`/tmp/blender_screenshot_<pid>.png\` <!-- ephemeral-ok:    -->"
ep_block mk-other "ok \`/tmp/a.txt\` <!-- ephemeral-ok: prose -->" "bad \`/tmp/b.txt\`"
out="$(bash "$SUT" "$TMP/ep-mk-ok.md" 2>&1)"
{ ! grep -q 'EPHEMERAL?' <<<"$out" && grep -q 'INFO    ephemeral-ok line' <<<"$out"; } && ok "#1207 marker: reasoned marker waives the WARN (INFO, never silent)" || no "#1207 marker: ok"
out="$(bash "$SUT" "$TMP/ep-mk-no.md" 2>&1)"
grep -q 'EPHEMERAL?' <<<"$out" && ok "#1207 marker: same line without marker WARNs" || no "#1207 marker: no marker"
out="$(bash "$SUT" "$TMP/ep-mk-empty.md" 2>&1)"
{ grep -q 'EPHEMERAL?' <<<"$out" && grep -q 'invalid marker line' <<<"$out"; } && ok "#1207 marker: empty reason -> WARN still fires + typed invalid marker" || no "#1207 marker: empty"
out="$(bash "$SUT" "$TMP/ep-mk-blank.md" 2>&1)"
{ grep -q 'EPHEMERAL?' <<<"$out" && grep -q 'invalid marker line' <<<"$out"; } && ok "#1207 marker: blank reason is invalid too" || no "#1207 marker: blank"
out="$(bash "$SUT" --strict-ephemeral "$TMP/ep-mk-empty.md" 2>&1)"; got=$?
{ [ "$got" = 1 ] && grep -q 'EPHEMERAL!' <<<"$out" && grep -q 'invalid marker' <<<"$out"; } && ok "#1207 marker: strict + invalid marker -> FAIL" || no "#1207 marker: strict invalid (rc=$got)"
out="$(bash "$SUT" --strict-ephemeral "$TMP/ep-mk-other.md" 2>&1)"; got=$?
{ [ "$got" = 1 ] && [ "$(grep -c 'EPHEMERAL!' <<<"$out")" = 1 ]; } && ok "#1207 marker: waives only its own line" || no "#1207 marker: scope (rc=$got)"

# Anti-silent-zero: a dead or blind ephemeral detector must be a typed degraded state, not a clean pass.
_ep_real_awk="$(command -v awk)"
for _ep_mode in silent rcfail; do
  _ep_stub="$TMP/stub-bin-ep-$_ep_mode"; mkdir -p "$_ep_stub"
  case "$_ep_mode" in silent) _ep_act='exit 0';; rcfail) _ep_act='"'"$_ep_real_awk"'" "$@"; exit 3';; esac
  cat > "$_ep_stub/awk" <<STUB_EP
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *VB-EP-ANCHOR*) $_ep_act;; esac; done
exec "$_ep_real_awk" "\$@"
STUB_EP
  chmod +x "$_ep_stub/awk"
done
ep_degraded() { # <mode> <label>
  local out got
  out="$(PATH="$TMP/stub-bin-ep-$1:$PATH" bash "$SUT" "$TMP/ep-clean.md" 2>&1)"; got=$?
  if [ "$got" = 1 ] && grep -q 'ERROR: ephemeral-path scan DEGRADED' <<<"$out" && ! grep -q '(none — no unanchored' <<<"$out"
  then ok "$2 (exit 1, typed degraded line)"
  else no "$2 :: want exit 1 + DEGRADED line, got $got"; fi
}
ep_degraded silent "#1207 BAD: blind ephemeral detector (no trailer) is degraded"
ep_degraded rcfail "#1207 BAD: ephemeral detector exit != 0 is degraded"

# kit #1207 (b) — SCRIPTS-MANIFEST. A preserved script cited under sources/probes/ needs a manifest row whose
# sha256 equals the file's, but only when the corpus has >= 1 manifest; with none, a typed INFO (never silent).
mf_sha() { sha256sum "$1" | awk '{print $1}'; }
mf_corpus() { # <name> <block-body-line...> — fresh corpus dir with scripts a.sh b.sh c.sh under sources/probes/b1/
  MFD="$TMP/mf-$1"; shift; mkdir -p "$MFD/sources/probes/b1"
  local s; for s in a b c; do printf '#!/bin/sh\necho %s\n' "$s" > "$MFD/sources/probes/b1/$s.sh"; done
  { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$MFD/block.md"
}
mf_manifest() { # <dir> <row-script> <sha-or-@file> ... (pairs) — writes sources/probes/<dir>/SCRIPTS-MANIFEST.md
  local d="$1"; shift; mkdir -p "$MFD/sources/probes/$d"
  { echo "| script | sha256 | run/step | block | executed-on | remote-sha256 | role |"; echo "|---|---|---|---|---|---|---|"
    while [ $# -gt 1 ]; do
      local sh="$2"; case "$sh" in @*) sh="$(mf_sha "$MFD/sources/probes/b1/${sh#@}")";; esac
      echo "| \`$1\` | $sh | sh $1 --go | B1 | host | - | EXECUTED |"; shift 2
    done; } > "$MFD/sources/probes/$d/SCRIPTS-MANIFEST.md"
}
mf_check() { # <want-rc> <want-regex> <label>
  local out got
  out="$(bash "$SUT" "$MFD/block.md" 2>&1)"; got=$?
  if [ "$got" = "$1" ] && grep -qE "$2" <<<"$out"; then ok "$3 (exit $got)"
  else no "$3 :: want exit $1 + /$2/, got $got :: $(grep -E 'MANIFEST|manifest' <<<"$out" | head -2)"; fi
}
mf_corpus nomf "Ran \`sources/probes/b1/a.sh\` [CERT]"
mf_check 0 'INFO    no SCRIPTS-MANIFEST' "#1207 GOOD: corpus with no manifest keeps today's behaviour, typed INFO"
mf_corpus ok "Ran \`sources/probes/b1/a.sh\` [CERT]"; mf_manifest b1 a.sh @a.sh
mf_check 0 'manifest-ok  sources/probes/b1/a.sh' "#1207 GOOD: cited script with matching manifest row"
mf_corpus norow "Ran \`sources/probes/b1/a.sh\` [CERT]"; mf_manifest b1 b.sh @b.sh
mf_check 1 'MANIFEST!  sources/probes/b1/a.sh  \(no valid SCRIPTS-MANIFEST row' "#1207 BAD: cited script has no manifest row"
mf_corpus badsha "Ran \`sources/probes/b1/a.sh\` [CERT]"; mf_manifest b1 a.sh "$(printf 'f%.0s' $(seq 64))"
mf_check 1 'MANIFEST!  sources/probes/b1/a.sh  \(manifest sha256 differs' "#1207 BAD: manifest sha256 differs from the file"
mf_corpus shortsha "Ran \`sources/probes/b1/a.sh\` [CERT]"; mf_manifest b1 a.sh abc123
mf_check 1 'no valid SCRIPTS-MANIFEST row' "#1207 BAD: truncated sha256 is not a valid row"
mf_corpus absent "Ran \`sources/probes/b1/gone.sh\` [CERT]"; mf_manifest b1 gone.sh "$(printf 'a%.0s' $(seq 64))"
mf_check 1 'MANIFEST!  sources/probes/b1/gone.sh  \(manifest sha256 differs' "#1207 BAD: row exists but the preserved file is absent"
mf_corpus first "Ran \`sources/probes/b1/a.sh\`"; mf_manifest b1 a.sh @a.sh b.sh @b.sh c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/a.sh' "#1207 GOOD: cited script is the FIRST manifest row"
mf_corpus middle "Ran \`sources/probes/b1/b.sh\`"; mf_manifest b1 a.sh @a.sh b.sh @b.sh c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/b.sh' "#1207 GOOD: cited script is the MIDDLE manifest row"
mf_corpus last "Ran \`sources/probes/b1/c.sh\`"; mf_manifest b1 a.sh @a.sh b.sh @b.sh c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/c.sh' "#1207 GOOD: cited script is the LAST manifest row"
mf_corpus single "Ran \`sources/probes/b1/c.sh\`"; mf_manifest b1 c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/c.sh' "#1207 GOOD: single-row manifest"
mf_corpus onebad "Ran \`sources/probes/b1/a.sh\` then \`sources/probes/b1/c.sh\`"; mf_manifest b1 a.sh @a.sh
mf_check 1 'MANIFEST!  sources/probes/b1/c.sh' "#1207 BAD: last of two cited scripts lacks a row"
mf_corpus othermf "Ran \`sources/probes/b1/a.sh\`"; mf_manifest b2 a.sh @a.sh
mf_check 1 'MANIFEST!  sources/probes/b1/a.sh  \(no valid SCRIPTS-MANIFEST row' "#1207 BAD: a row in another probes dir does not list this dir's script"
mf_corpus othermf-full "Ran \`sources/probes/b1/a.sh\`"; mf_manifest b2 sources/probes/b1/a.sh @a.sh
mf_check 0 'manifest-ok  sources/probes/b1/a.sh' "#1207 GOOD: a target-relative sources/ cell in another dir's manifest lists it"
mf_corpus nested "Ran \`sources/probes/b1/sub/n.sh\`"; mkdir -p "$MFD/sources/probes/b1/sub"; printf 'echo n\n' > "$MFD/sources/probes/b1/sub/n.sh"
{ echo "| script | sha256 |"; echo "|---|---|"; echo "| \`sub/n.sh\` | $(mf_sha "$MFD/sources/probes/b1/sub/n.sh") |"; } > "$MFD/sources/probes/b1/SCRIPTS-MANIFEST.md"
mf_check 0 'manifest-ok  sources/probes/b1/sub/n.sh' "#1207 GOOD: a nested cell resolves relative to its manifest dir"
mf_corpus dotslash "Ran \`sources/probes/b1/a.sh\`"; mf_manifest b1 ./a.sh @a.sh
mf_check 0 'manifest-ok  sources/probes/b1/a.sh' "#1207 GOOD: ./a.sh cell lists a.sh"
mkdir -p "$TMP/stub-bin-mf"; printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = SCRIPTS-MANIFEST.md ] && exit 1; done\nexec %s "$@"\n' "$(command -v find)" > "$TMP/stub-bin-mf/find"; chmod +x "$TMP/stub-bin-mf/find"
mf_corpus findfail "Ran \`sources/probes/b1/a.sh\`"; mf_manifest b1 a.sh @a.sh
MFD_FF="$MFD"
out="$(PATH="$TMP/stub-bin-mf:$PATH" bash "$SUT" "$MFD/block.md" 2>&1)"; got=$?
{ [ "$got" = 1 ] && grep -q 'DEGRADED manifest scan failed' <<<"$out" && ! grep -q 'INFO    no SCRIPTS-MANIFEST' <<<"$out"; } && ok "#1207 BAD: failed manifest scan is typed DEGRADED (exit 1), not 'no manifest'" || no "#1207: manifest find failure (rc=$got)"
mf_corpus noscript "Plain claim [CERT] \`src/x.c:1\`"; mf_manifest b1 a.sh @a.sh
mf_check 0 'none — no preserved script cited' "#1207 GOOD: manifests present, no script cited -> explicit none line"
mf_corpus proseend "Ran sources/probes/b1/a.sh." ; mf_manifest b1 a.sh @a.sh
mf_check 0 'manifest-ok  sources/probes/b1/a.sh' "#1207 GOOD: cite followed by sentence period"
# kit #1659: a manifest the shared parser cannot read is a typed DEGRADED (exit 1), never "no valid row" / "no manifest".
# (chmod 000 is not an obstacle to root, so the case is skipped there; the tooth below is skipped with it.)
mf_corpus unreadable "Ran \`sources/probes/b1/a.sh\` [CERT]"; mf_manifest b1 a.sh @a.sh; chmod 000 "$MFD/sources/probes/b1/SCRIPTS-MANIFEST.md"
if [ "$(id -u)" = 0 ]; then ok "#1659 (skipped: running as root, chmod 000 does not block reads)"
else mf_check 1 'DEGRADED manifest parse failed' "#1659 BAD: an unreadable manifest is a typed DEGRADED parse failure, not 'no row'"; fi
# kit #1659: the cite must end at a path terminator — a.sh.bak / run.py.log are NOT a phantom a.sh / run.py cite
P=sources/probes/b1
mf_corpus bak-single "Saved \`$P/a.sh.bak\` aside"; mf_manifest b1 b.sh @b.sh
mf_check 0 'none — no preserved script cited' "#1659 GOOD: a lone a.sh.bak is no cite at all (no phantom MANIFEST! for a.sh)"
mf_corpus log-single "Saved $P/c.py.log aside"; mf_manifest b1 b.sh @b.sh
mf_check 0 'none — no preserved script cited' "#1659 GOOD: a lone c.py.log is no cite at all (no phantom c.py)"
mf_corpus bak-first "Ran \`$P/a.sh.bak\`, then \`$P/b.sh\`"; mf_manifest b1 b.sh @b.sh
mf_check 0 'manifest-ok  sources/probes/b1/b.sh' "#1659 GOOD: .bak cite FIRST of two, the real cite after it is still checked"
mf_corpus log-middle "Ran \`$P/b.sh\`, \`$P/a.sh.log\`, \`$P/c.sh\`"; mf_manifest b1 b.sh @b.sh c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/c.sh' "#1659 GOOD: .log cite in the MIDDLE does not break its neighbours"
mf_corpus bak-last "Ran \`$P/c.sh\` and \`$P/a.sh.bak\`"; mf_manifest b1 c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/c.sh' "#1659 GOOD: .bak cite LAST, no phantom a.sh row demanded"
mf_corpus bak-real-missing "Ran \`$P/a.sh.bak\` and \`$P/c.sh\`"; mf_manifest b1 b.sh @b.sh
mf_check 1 'MANIFEST!  sources/probes/b1/c.sh' "#1659 BAD: the real cite next to a .bak is still a FAIL when it lacks a row"
mf_corpus term-eol "Ran $P/a.sh"; mf_manifest b1 a.sh @a.sh
mf_check 0 'manifest-ok  sources/probes/b1/a.sh' "#1659 GOOD: cite at end of line (no trailing char) is still a cite"
mf_corpus term-mix "Ran $P/a.sh, $P/b.sh; ($P/c.sh)"; mf_manifest b1 a.sh @a.sh b.sh @b.sh c.sh @c.sh
mf_check 0 'manifest-ok  sources/probes/b1/c.sh' "#1659 GOOD: comma / semicolon / paren terminated cites are all still cites"
mf_corpus term-mix-miss "Ran $P/a.sh, $P/b.sh; ($P/c.sh)"; mf_manifest b1 a.sh @a.sh b.sh @b.sh
mf_check 1 'MANIFEST!  sources/probes/b1/c.sh' "#1659 BAD: a paren-terminated cite is still checked"

# NEGATIVE CONTROLS — every mutant is a COPY of the SUT under $MUT built by lib/mutant.sh, which REFUSES an
# empty, byte-identical, syntax-broken or live-tree mutant. Each control asserts the GOOD verdict on the
# original (rc + output) AND the SPECIFIC BAD verdict on the mutant (rc + output, plus the end-of-run
# '== exit N ==' line, so a mutant that crashed mid-run cannot read as teeth). Kit issues #943, #1299.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
    || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth ($HERE/lib/mutant.sh)" >&2; exit 2; }
  MUT="$(mktemp -d)"
  # mutant copies of the SUT live flat in $MUT and resolve lib/ beside themselves (kit #1659: scripts-manifest.sh)
  ln -s "$HERE/../lib" "$MUT/lib"
  # mk_sed LABEL OUT EXPR...  build $OUT from $SUT with one sed stage per EXPR (the shared mutant_chain
  # refuses a dead stage); a refusal is counted as a failure here, the helper never touches the counters.
  mk_sed(){
    mutant_chain "$1" "$SUT" "$2" "${@:3}" || { fail=$((fail+1)); return 1; }
  }
  # tooth LABEL GOOD_RC BAD_RC MUTANT [--good-has RE] [--good-lacks RE] [--bad-lacks RE] [--bad-has RE] -- ARGV...
  # Counting wrapper over the shared mutant_tooth (which prints its own PASS/FAIL line): '@SUT@' is replaced by
  # the original, then by the mutant; PASS only when each side returns its EXACT rc and its output verdict.
  # The pre-migration local helper matched patterns case-insensitively, so MUTANT_TOOTH_ICASE keeps that exact.
  tooth(){
    if MUTANT_TOOTH_ICASE=1 mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  }
  # fixture: header blockquote legend + '---' + body lines (the shape most teeth share)
  vbfix(){ local f="$1"; shift; { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }
  EXIT0='== exit 0 =='
  NOCITE='ZERO file:line citations resolved'

  echo "-- teeth: neuter the fence detection so adjusted == raw --"
  if mk_sed "teeth" "$MUT/fence.sh" 's#^fence_line=\$(awk.*#fence_line=""#'; then
    vbfix "$TMP/teeth.md" "Body a [CERT]. b [CERT]."
    tooth "teeth" 0 0 "$MUT/fence.sh" --good-has '\[CERT\] 3  \(adj 2\)' --good-lacks 'adjusted = raw' \
      --bad-lacks '\(adj [0-9]' --bad-has 'adjusted = raw' -- bash @SUT@ "$TMP/teeth.md"
  fi

  echo "-- teeth-d6: neuter D6-PATH-FALLBACK; path-prefixed cite must go MISSING + exit 1 --"
  if mk_sed "teeth-d6" "$MUT/d6.sh" '/# D6-PATH-FALLBACK/ s/.*/      : # D6-PATH-FALLBACK [NEUTERED]/'; then
    mkdir -p "$TMP/sources/probes"; seq 1 200 > "$TMP/sources/probes/B10-x.txt"
    vbfix "$TMP/d6-teeth.md" "Option order fixed (sources/probes/B10-x.txt:146). \`[CERT]\`"
    tooth "teeth-d6" 0 1 "$MUT/d6.sh" --good-lacks 'MISSING' --bad-has 'MISSING.*B10-x' \
      -- bash @SUT@ "$TMP/d6-teeth.md"
  fi

  echo "-- teeth-p6: neuter P6-CERT-ZERO-CITE-WARN; [CERT]+no-cites block must NOT WARN --"
  if mk_sed "teeth-p6" "$MUT/p6.sh" '/# P6-CERT-ZERO-CITE-WARN/ s/.*/  if false; then  # P6-CERT-ZERO-CITE-WARN [NEUTERED]/'; then
    vbfix "$TMP/p6-teeth.md" "The flag is always set. [CERT]"
    tooth "teeth-p6" 0 0 "$MUT/p6.sh" --good-has "$NOCITE" --bad-lacks "$NOCITE" --bad-has "$EXIT0" \
      -- bash @SUT@ "$TMP/p6-teeth.md"
  fi

  echo "-- teeth-p6-short-tbl: neuter P6-SHORT-FORM-CITE-TABLE; table :NNN must revert to WARN --"
  if mk_sed "teeth-p6-short-tbl" "$MUT/sft.sh" '/# P6-SHORT-FORM-CITE-TABLE/ s/.*/_tbl_shorts=""  # P6-SHORT-FORM-CITE-TABLE [NEUTERED]/'; then
    vbfix "$TMP/p6-sft-teeth.md" "## Field map [CERT]" "| Field | Line |" "|---|---|" "| FIELD_A | :10 |"
    tooth "teeth-p6-short-tbl" 0 0 "$MUT/sft.sh" --good-lacks "$NOCITE" --bad-has "$NOCITE" \
      -- bash @SUT@ "$TMP/p6-sft-teeth.md"
  fi

  echo "-- teeth-p6-short-cmt: neuter P6-SHORT-FORM-CITE-COMMENT; comment :NNN must revert to WARN --"
  if mk_sed "teeth-p6-short-cmt" "$MUT/sfc.sh" '/# P6-SHORT-FORM-CITE-COMMENT/ s/.*/_cmt_shorts=""  # P6-SHORT-FORM-CITE-COMMENT [NEUTERED]/'; then
    vbfix "$TMP/p6-sfc-teeth.md" "## Constants [CERT]" '```csharp' "CONST_A = 15;  // :157" '```'
    tooth "teeth-p6-short-cmt" 0 0 "$MUT/sfc.sh" --good-lacks "$NOCITE" --bad-has "$NOCITE" \
      -- bash @SUT@ "$TMP/p6-sfc-teeth.md"
  fi

  echo "-- teeth-p7-range-extract: neuter P7-BT-RANGE-EXTRACT; range-only block must revert to WARN --"
  if mk_sed "teeth-p7-range-extract" "$MUT/rng.sh" '/# P7-BT-RANGE-EXTRACT/ s/.*/bt_cites=""  # P7-BT-RANGE-EXTRACT [NEUTERED]/'; then
    vbfix "$TMP/p7-rng-teeth.md" "The method \`BinaryEncoder.java:10-20\`. \`[CERT]\`"
    tooth "teeth-p7-range-extract" 0 0 "$MUT/rng.sh" --good-lacks "$NOCITE" --bad-has "$NOCITE" \
      -- bash @SUT@ "$TMP/p7-rng-teeth.md"
  fi

  echo "-- teeth-p7-cmt-secondary: neuter P7-CMT-SECONDARY; // :NNN,:MMM must lose :MMM --"
  if mk_sed "teeth-p7-cmt-secondary" "$MUT/cmtsec.sh" '/# P7-CMT-SECONDARY/ s/.*/_cmt_shorts=""  # P7-CMT-SECONDARY [NEUTERED]/'; then
    vbfix "$TMP/p7-cmtsec-teeth.md" "## Constants [CERT]" '```csharp' "CONST_A = 15;  // :159,:161" '```'
    tooth "teeth-p7-cmt-secondary" 0 0 "$MUT/cmtsec.sh" --good-has 'short.*:161|:161.*short' \
      --bad-lacks 'short.*:161|:161.*short' --bad-has "$EXIT0" -- bash @SUT@ "$TMP/p7-cmtsec-teeth.md"
  fi

  echo "-- teeth-p6-probe: neuter P6-PROBE-FILE-CITE; probe-cited block must revert to WARN --"
  if mk_sed "teeth-p6-probe" "$MUT/probe.sh" '/# P6-PROBE-FILE-CITE/ s/.*/      probe_found=""  # P6-PROBE-FILE-CITE [NEUTERED]/'; then
    mkdir -p "$TMP/sources/probes/test-probe"
    printf 'probe content\n' > "$TMP/sources/probes/test-probe/probe-20260729.txt"
    { echo "# Block — t"; echo; echo "> Method: [CERT-hw] = live device response."; echo; echo "---"; echo
      echo "## Live response [CERT-hw]"; echo "[CERT-hw] (sources/probes/test-probe/probe-20260729.txt)"; } > "$TMP/p6-probe-teeth.md"
    tooth "teeth-p6-probe" 0 0 "$MUT/probe.sh" --good-lacks 'WARN.*(\[CERT\]|zero)' --bad-has 'WARN.*(\[CERT\]|zero)' \
      -- bash @SUT@ "$TMP/p6-probe-teeth.md"
  fi

  echo "-- teeth-n-project-fallback: neuter N-PROJECT-FALLBACK; nested cite must revert to extern --"
  # The sentinel is on the _bt_resolve reassignment line only (end of line); the init line uses
  # N-PROJECT-FALLBACK-INIT and is NOT neutered so git_root is still derived.
  if mk_sed "teeth-n-project-fallback" "$MUT/npf.sh" '/# N-PROJECT-FALLBACK$/ s/.*/:  # N-PROJECT-FALLBACK [NEUTERED]/'; then
    mkdir -p "$TMP/npf-nested/src" "$TMP/npf-nested/docs"
    git -C "$TMP/npf-nested" init -q 2>/dev/null
    seq 1 50 > "$TMP/npf-nested/src/tool.sh"
    { echo "# Block NPF — nested layout"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "## NPF Observation [CERT]"; echo "The function is defined at \`src/tool.sh:10\`. \`[CERT]\`"; } > "$TMP/npf-nested/docs/block-npf.md"
    tooth "teeth-n-project-fallback" 0 0 "$MUT/npf.sh" --good-lacks 'extern.*src/tool' --bad-has 'extern.*src/tool' \
      -- bash @SUT@ "$TMP/npf-nested/docs/block-npf.md"
  fi

  echo "-- teeth-p6-doc-aware: neuter P6-DOC-AWARE-SUPPRESS; [CERT-doc]-only block must revert to WARN --"
  if mk_sed "teeth-p6-doc-aware" "$MUT/doc.sh" '/# P6-DOC-AWARE-SUPPRESS/ s/.*/    if false; then  # P6-DOC-AWARE-SUPPRESS [NEUTERED]/'; then
    { echo "# Block — doc corpus"; echo; echo "> Method: [CERT-doc] = preserved PDF+page; [INFER] = deduction."; echo; echo "---"; echo
      echo "## Config [CERT-doc]"; echo "The panel accepts BACnet/IP over UDP. [CERT-doc]"; } > "$TMP/p6-docaware-teeth.md"
    tooth "teeth-p6-doc-aware" 0 0 "$MUT/doc.sh" --good-lacks 'WARN.*(\[CERT\]|zero)' --bad-has 'WARN.*(\[CERT\]|zero)' \
      -- bash @SUT@ "$TMP/p6-docaware-teeth.md"
  fi

  # Type-declaring fixtures: header carries a '> **Type:** <token>' blockquote line.
  vbtype(){ local f="$1" typeline="$2"; shift 2; { echo "# Block — t"; echo; echo "> Method: [CERT] = x."; echo; printf '%s\n' "$typeline"; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }

  echo "-- teeth-p6-type-classify: neuter P6-TYPE-CLASSIFY; synthesis block must revert to WARN --"
  if mk_sed "teeth-p6-type-classify" "$MUT/type.sh" '/# P6-TYPE-CLASSIFY/ s/synthesis|[^)]*/NOTYPE_MATCH/'; then
    vbtype "$TMP/p6-type-teeth.md" '> **Type:** synthesis' "## Summary [CERT]" "The module is initialized via [Block 5]. [CERT]"
    tooth "teeth-p6-type-classify" 0 0 "$MUT/type.sh" --good-has 'INFO.*declared type' --good-lacks "WARN.*$NOCITE" \
      --bad-has "WARN.*$NOCITE" --bad-lacks 'INFO.*declared type' -- bash @SUT@ "$TMP/p6-type-teeth.md"
  fi

  echo "-- teeth-p6-type-unrecognised: neuter P6-TYPE-UNRECOGNISED; unrecognised token must stop naming itself --"
  if mk_sed "teeth-p6-type-unrecognised" "$MUT/unrec.sh" '/# P6-TYPE-UNRECOGNISED/ s/if .*/if false; then  # P6-TYPE-UNRECOGNISED [NEUTERED]/'; then
    vbtype "$TMP/p6-unrec-teeth.md" '> **Type:** experimental-new-type' "## Result [CERT]" "The flag is always set. [CERT]"
    tooth "teeth-p6-type-unrecognised" 0 0 "$MUT/unrec.sh" --good-has "experimental-new-type" --bad-lacks "experimental-new-type" \
      --bad-has "$NOCITE" -- bash @SUT@ "$TMP/p6-unrec-teeth.md"
  fi

  echo "-- teeth-p6-type-strip: clear combined strip; backtick-capture must revert to WARN --"
  if mk_sed "teeth-p6-type-strip" "$MUT/tstrip.sh" '/# P6-TYPE-STRIP/ s/.*/        _type_stripped=""  # P6-TYPE-STRIP [NEUTERED]/'; then
    vbtype "$TMP/p6-type-strip-teeth.md" '> **Type:** `capture`' "## Known state [CERT]" "The config is X. [CERT]"
    tooth "teeth-p6-type-strip" 0 0 "$MUT/tstrip.sh" --good-has 'INFO.*declared type' --good-lacks "WARN.*$NOCITE" \
      --bad-has "WARN.*$NOCITE" --bad-lacks 'INFO.*declared type' -- bash @SUT@ "$TMP/p6-type-strip-teeth.md"
  fi

  echo "-- teeth-p6-type-display: null display-name fallback; uppercase token must print '' (not named) --"
  if mk_sed "teeth-p6-type-display" "$MUT/tdisp.sh" '/# P6-TYPE-DISPLAY/ s/.*/        _type_warn_name=$_type_token  # P6-TYPE-DISPLAY [NEUTERED]/'; then
    vbtype "$TMP/p6-type-disp-teeth.md" '> **Type:** GAP-CLOSING SWEEP — special form' "## Finding [CERT]" "The method is defined. [CERT]"
    tooth "teeth-p6-type-display" 0 0 "$MUT/tdisp.sh" --good-has 'GAP-CLOSING' --good-lacks "token ''" \
      --bad-has "token ''" --bad-lacks 'GAP-CLOSING' -- bash @SUT@ "$TMP/p6-type-disp-teeth.md"
  fi

  echo "-- teeth-p6-wording: strip 'synthesis / REMITTANCE' phrase from P6 WARN --"
  if mk_sed "teeth-p6-wording" "$MUT/wording.sh" 's/Expected for synthesis \/ REMITTANCE[^"]*;//'; then
    vbfix "$TMP/p6-wording-teeth.md" "The flag is always set. [CERT]"
    # the HINT line legitimately lists 'synthesis', so the discriminating token is REMITTANCE
    tooth "teeth-p6-wording" 0 0 "$MUT/wording.sh" --good-has 'Expected for synthesis / REMITTANCE' \
      --bad-lacks 'REMITTANCE' --bad-has "$NOCITE" -- bash @SUT@ "$TMP/p6-wording-teeth.md"
  fi

  echo "-- teeth-vb49: neutralize _vb_grep_err; -nF exit-2 must pass silently --"
  if mk_sed "teeth-vb49" "$MUT/vb49.sh" 's/_vb_grep_err=\$_vb_h_rc/_vb_grep_err=0/'; then
    tooth "teeth-vb49" 0 0 "$MUT/vb49.sh" --good-has 'citation resolution FAILED|unresolved.*grep exit' \
      --bad-lacks 'citation resolution FAILED|unresolved.*grep exit' --bad-has "$EXIT0" \
      -- env "PATH=$_stub_vb49:$PATH" bash @SUT@ "$block_vb49" "$d_vb49"
  fi

  echo "-- teeth-vb50: neutralize _vb_dedup_rc; -vE exit-2 must pass silently --"
  if mk_sed "teeth-vb50" "$MUT/vb50.sh" 's/_vb_dedup_rc=\$?/_vb_dedup_rc=0/'; then
    tooth "teeth-vb50" 0 0 "$MUT/vb50.sh" --good-has 'citation dedup FAILED|unresolved.*grep exit' \
      --bad-lacks 'citation dedup FAILED|unresolved.*grep exit' --bad-has "$EXIT0" \
      -- env "PATH=$_stub_vb50:$PATH" bash @SUT@ "$block_vb50" "$d_vb50"
  fi

  echo "-- teeth-p6-bq-strip: neuter BQ-STRIP + TYPE-case sed; fixture must revert to naming '>' --"
  # Both sentinels are one logical fix: the strip is a no-op if the sed still extracts the value.
  if mk_sed "teeth-p6-bq-strip" "$MUT/bqs.sh" \
      '/# P6-BQ-STRIP/ s/.*/        _type_no_bq="$_type_raw"  # P6-BQ-STRIP [NEUTERED]/' \
      '/# P6-BQ-TYPECASE/ s/\[Tt\]\[Yy\]\[Pp\]\[Ee\]/[Tt]ype/'; then
    { echo "# Block — t"; echo; echo "> **TYPE: GAP-CLOSING SWEEP.**"; echo; echo "> Method: [CERT] = x."; echo; echo "---"; echo
      echo "## Finding [CERT]"; echo "The method is defined. [CERT]"; } > "$TMP/p6-bq-strip-teeth.md"
    tooth "teeth-p6-bq-strip" 0 0 "$MUT/bqs.sh" --good-has 'GAP-CLOSING SWEEP' --good-lacks "token '>'" \
      --bad-has "token '>'" --bad-lacks 'GAP-CLOSING SWEEP' -- bash @SUT@ "$TMP/p6-bq-strip-teeth.md"
  fi

  echo "-- teeth-p6-type-classify-decision: remove decision from P6-TYPE-CLASSIFY; block must revert to WARN --"
  if mk_sed "teeth-p6-type-classify-decision" "$MUT/tdec.sh" '/# P6-TYPE-CLASSIFY/ s/|decision//'; then
    vbtype "$TMP/p6-type-decision-teeth.md" '> **Type:** decision' "## Decision [CERT]" "Chose approach A over B. [CERT]"
    tooth "teeth-p6-type-classify-decision" 0 0 "$MUT/tdec.sh" --good-has 'INFO.*declared type' --good-lacks "WARN.*$NOCITE" \
      --bad-has "WARN.*$NOCITE" --bad-lacks 'INFO.*declared type' -- bash @SUT@ "$TMP/p6-type-decision-teeth.md"
  fi

  echo "-- teeth-p6-nonresolvable: neuter P6-NONRESOLVABLE-GUARD; jar-only block must revert to P6 WARN --"
  if mk_sed "teeth-p6-nonresolvable" "$MUT/p6nr.sh" '/# P6-NONRESOLVABLE-GUARD/ s/if .*/if false; then  # P6-NONRESOLVABLE-GUARD [MUTANT]/'; then
    tooth "teeth-p6-nonresolvable" 0 0 "$MUT/p6nr.sh" --good-has 'non-file-verifiable|jar-entry paths|BNNN.*back-ref' --good-lacks "$NOCITE" \
      --bad-has "$NOCITE" --bad-lacks 'non-file-verifiable|jar-entry paths|BNNN.*back-ref' \
      -- bash @SUT@ "$TMP/vb1-jar.md"
  fi

  echo "-- teeth-vb1-jar-entry: neuter VB1-JAR-ENTRY-CITE echo; jar!entry visibility must disappear --"
  if mk_sed "teeth-vb1-jar-entry" "$MUT/vb1.sh" 's/echo.*jar-entry.*# VB1-JAR-ENTRY-CITE/: # VB1-JAR-ENTRY-CITE [MUTANT]/'; then
    tooth "teeth-vb1-jar-entry" 0 0 "$MUT/vb1.sh" --good-has 'jar-entry' --bad-lacks 'jar-entry' --bad-has "$EXIT0" \
      -- bash @SUT@ "$TMP/vb1-jar.md"
  fi

  echo "-- teeth-vb1-synth-ref: neuter VB1-SYNTH-REF echo; back-ref visibility must disappear --"
  if mk_sed "teeth-vb1-synth-ref" "$MUT/vb1s.sh" 's/echo.*synth-ref.*# VB1-SYNTH-REF/: # VB1-SYNTH-REF [MUTANT]/'; then
    tooth "teeth-vb1-synth-ref" 0 0 "$MUT/vb1s.sh" --good-has 'synth-ref' --bad-lacks 'synth-ref' --bad-has "$EXIT0" \
      -- bash @SUT@ "$TMP/vb1-synth.md"
  fi

  echo "-- teeth-source-root-fallback: neuter SOURCE_ROOT-FALLBACK; decompiled-tree cite must revert to extern --"
  if mk_sed "teeth-source-root-fallback" "$MUT/sr.sh" '/# SOURCE_ROOT-FALLBACK/ s/.*/: # SOURCE_ROOT-FALLBACK [NEUTERED]/'; then
    mkdir -p "$TMP/sr-root/organized/platBase/vineflower/com/example"
    seq 1 30 > "$TMP/sr-root/organized/platBase/vineflower/com/example/Foo.java"
    vbfix "$TMP/sr-teeth.md" "The method \`organized/platBase/vineflower/com/example/Foo.java:10\`. \`[CERT]\`"
    srcite='organized/platBase/vineflower/com/example/Foo\.java:10'
    tooth "teeth-source-root-fallback" 0 0 "$MUT/sr.sh" --good-has "ok.*$srcite" --good-lacks "extern.*$srcite" \
      --bad-has "extern.*$srcite" --bad-lacks "ok.*$srcite" \
      -- env "SOURCE_ROOT=$TMP/sr-root" bash @SUT@ "$TMP/sr-teeth.md"
  fi

  echo "-- teeth-p9: neuter P9-RESOLVED-SUMMARY; all-extern block must stop emitting resolved/WARN --"
  if mk_sed "teeth-p9" "$MUT/p9.sh" '/# P9-RESOLVED-SUMMARY/ s/if.*/if false; then  # P9-RESOLVED-SUMMARY [NEUTERED]/'; then
    vbfix "$TMP/p9-teeth.md" "The method \`NonExistent.java:10\`. \`[CERT]\`"
    tooth "teeth-p9" 0 0 "$MUT/p9.sh" --good-has 'WARN.*resolved 0 of' --bad-lacks 'resolved 0 of' --bad-has "$EXIT0" \
      -- bash @SUT@ "$TMP/p9-teeth.md"
  fi

  echo "-- teeth-p9-type-classify: neuter P9-TYPE-CLASSIFY; synthesis+extern must revert to WARN --"
  if mk_sed "teeth-p9-type-classify" "$MUT/p9tc.sh" '/# P9-TYPE-CLASSIFY/ s/synthesis|[^)]*/NOTYPE_MATCH/'; then
    vbtype "$TMP/p9-type-classify-teeth.md" '> **Type:** synthesis' "As seen in \`NonExistent.java:10\`. \`[CERT]\`"
    tooth "teeth-p9-type-classify" 0 0 "$MUT/p9tc.sh" --good-has 'INFO.*resolved' --good-lacks 'WARN.*resolved 0 of' \
      --bad-has 'WARN.*resolved 0 of' --bad-lacks 'INFO.*resolved' -- bash @SUT@ "$TMP/p9-type-classify-teeth.md"
  fi

  echo "-- teeth-p9-type-unrecognised: neuter P9-TYPE-UNRECOGNISED; type name must vanish from WARN --"
  if mk_sed "teeth-p9-type-unrecognised" "$MUT/p9tu.sh" '/# P9-TYPE-UNRECOGNISED/ s/if .*/if false; then  # P9-TYPE-UNRECOGNISED [NEUTERED]/'; then
    vbtype "$TMP/p9-type-unrec-teeth.md" '> **Type:** experimental-pnine' "The method \`NonExistent.java:10\`. \`[CERT]\`"
    tooth "teeth-p9-type-unrecognised" 0 0 "$MUT/p9tu.sh" --good-has 'WARN.*experimental-pnine' \
      --bad-lacks 'experimental-pnine' --bad-has 'WARN.*resolved 0 of' -- bash @SUT@ "$TMP/p9-type-unrec-teeth.md"
  fi

  echo "-- teeth-p9-range-ok: neuter P9-VB-OK-RANGE; range-resolved cite must count as 0 --"
  if mk_sed "teeth-p9-range-ok" "$MUT/p9ro.sh" '/# P9-VB-OK-RANGE/ s/+1/+0/'; then
    seq 1 30 > "$TMP/p9-range-teeth.java"
    vbfix "$TMP/p9-range-ok-teeth.md" "The loop \`p9-range-teeth.java:5-15\`. \`[CERT]\`"
    tooth "teeth-p9-range-ok" 0 0 "$MUT/p9ro.sh" --good-has 'resolved 1 of 1' --bad-has 'resolved 0 of 1' --bad-lacks 'resolved 1 of 1' \
      -- bash @SUT@ "$TMP/p9-range-ok-teeth.md"
  fi

  echo "-- teeth-p9-art-ok: neuter P9-VB-OK-ART; art-cite ok must count as 0 --"
  if mk_sed "teeth-p9-art-ok" "$MUT/p9ao.sh" '/# P9-VB-OK-ART/ s/+1/+0/'; then
    vbfix "$TMP/p9-art-ok-teeth.md" "Order preserved (B96-art-ok.txt:10-20). \`[CERT]\`"
    tooth "teeth-p9-art-ok" 0 0 "$MUT/p9ao.sh" --good-has 'resolved 1 of 1' --bad-has 'resolved 0 of 1' --bad-lacks 'resolved 1 of 1' \
      -- bash @SUT@ "$TMP/p9-art-ok-teeth.md"
  fi

  echo "-- teeth-p9-art-m: neuter P9-VB-M-ART; art cite must not increment M --"
  if mk_sed "teeth-p9-art-m" "$MUT/p9am.sh" '/# P9-VB-M-ART/ s/+1/+0/'; then
    vbfix "$TMP/p9-art-m-teeth.md" "Order preserved (B96-art-ok.txt:10-20). \`[CERT]\`"
    tooth "teeth-p9-art-m" 0 0 "$MUT/p9am.sh" --good-has 'resolved [0-9]+ of' --bad-lacks 'resolved [0-9]+ of' --bad-has "$EXIT0" \
      -- bash @SUT@ "$TMP/p9-art-m-teeth.md"
  fi

  echo "-- teeth-p9-doc-grade-guard: neuter P9-DOC-GRADE-GUARD; doc-grade block must revert to WARN --"
  if mk_sed "teeth-p9-doc-grade-guard" "$MUT/p9dg.sh" '/# P9-DOC-GRADE-GUARD/ s/if .*/if false; then  # P9-DOC-GRADE-GUARD [NEUTERED]/'; then
    { echo "# Block — t"; echo; echo "> Method: [CERT-doc] = x."; echo; echo "---"; echo
      echo "The method \`NonExistent.java:10\`. \`[CERT-doc]\`"; } > "$TMP/p9-doc-grade-teeth.md"
    tooth "teeth-p9-doc-grade-guard" 0 0 "$MUT/p9dg.sh" --good-has 'INFO.*resolved' --good-lacks 'WARN.*resolved 0 of' \
      --bad-has 'WARN.*resolved 0 of' --bad-lacks 'INFO.*resolved' -- bash @SUT@ "$TMP/p9-doc-grade-teeth.md"
  fi

  echo "-- teeth-p9-no-type-hint: neuter P9-NO-TYPE-HINT; HINT must not appear in output --"
  if mk_sed "teeth-p9-no-type-hint" "$MUT/p9nh.sh" '/# P9-NO-TYPE-HINT/ s/echo.*/: # P9-NO-TYPE-HINT [NEUTERED]/'; then
    vbfix "$TMP/p9-no-type-hint-teeth.md" "The method \`NonExistent.java:10\`. \`[CERT]\`"
    tooth "teeth-p9-no-type-hint" 0 0 "$MUT/p9nh.sh" --good-has 'HINT.*Declare' --bad-lacks 'HINT.*Declare' \
      --bad-has 'WARN.*resolved 0 of' -- bash @SUT@ "$TMP/p9-no-type-hint-teeth.md"
  fi

  echo "-- teeth-target-root-fallback: neuter TARGET-ROOT-FALLBACK; corpus-parent cite must revert to extern --"
  if mk_sed "teeth-target-root-fallback" "$MUT/trf.sh" '/# TARGET-ROOT-FALLBACK$/ s/.*/:  # TARGET-ROOT-FALLBACK [NEUTERED]/'; then
    tooth "teeth-target-root-fallback" 0 0 "$MUT/trf.sh" --good-has 'ok \(target-root\) src/index\.js:50-52' --good-lacks 'extern.*src/index' \
      --bad-has 'extern +src/index\.js:50-52' --bad-lacks 'ok .*src/index\.js' -- bash @SUT@ "$TMP/p1325/corpus/block-78.md"
  fi

  echo "-- teeth-target-root-walkup: neuter the ancestor walk; a block in corpus/sub must revert to extern (corpus/ itself still ok) --"
  if mk_sed "teeth-target-root-walkup" "$MUT/trw.sh" 's/^  _tr_d="\$(dirname "\$_tr_d")"/  _tr_d=""/'; then
    tooth "teeth-target-root-walkup" 0 0 "$MUT/trw.sh" --good-has 'ok \(target-root\) src/index\.js:50-52' --good-lacks 'extern.*src/index' \
      --bad-has 'extern +src/index\.js:50-52' --bad-lacks 'ok .*src/index\.js' -- bash @SUT@ "$TMP/p1325/corpus/sub/block-78b.md"
  fi

  echo "-- teeth-target-root-derive: neuter the corpus-name test; no target root is ever derived --"
  if mk_sed "teeth-target-root-derive" "$MUT/trd.sh" 's/= "corpus" \]; then _tr_c=/= "NO-SUCH-DIR" ]; then _tr_c=/'; then
    tooth "teeth-target-root-derive" 0 0 "$MUT/trd.sh" --good-has 'ok \(target-root\) src/index\.js:50-52' \
      --bad-has 'extern +src/index\.js:50-52' --bad-lacks 'ok .*src/index\.js' -- bash @SUT@ "$TMP/p1325/corpus/block-78.md"
  fi

  echo "-- teeth-p6-probe-report: neuter P6-PROBE-REPORT; the probe resolved-N-of-M line must vanish --"
  if mk_sed "teeth-p6-probe-report" "$MUT/pfr.sh" '/# P6-PROBE-REPORT$/ s/echo.*/: # P6-PROBE-REPORT [NEUTERED]/'; then
    tooth "teeth-p6-probe-report" 0 0 "$MUT/pfr.sh" --good-has 'probe-file cites resolved 1 of 2' \
      --bad-lacks 'probe-file cites resolved' -- bash @SUT@ "$TMP/p1325p/block-80.md"
  fi

  echo "-- teeth-p6-probe-count: neuter the resolved-probe counter; N must read 0 --"
  if mk_sed "teeth-p6-probe-count" "$MUT/pfc.sh" 's/_pf_ok=\$((_pf_ok+1))/_pf_ok=$((_pf_ok+0))/'; then
    tooth "teeth-p6-probe-count" 0 0 "$MUT/pfc.sh" --good-has 'probe-file cites resolved 1 of 2' \
      --bad-has 'probe-file cites resolved 0 of 2' --bad-lacks 'resolved 1 of 2' -- bash @SUT@ "$TMP/p1325p/block-80b.md"
  fi

  echo "-- teeth-p6-probe-coverage: neuter P6-PROBE-COVERAGE; the coverage-gap INFO must vanish --"
  if mk_sed "teeth-p6-probe-coverage" "$MUT/pfcov.sh" '/# P6-PROBE-COVERAGE/ s/if .*/if false; then  # P6-PROBE-COVERAGE [NEUTERED]/'; then
    tooth "teeth-p6-probe-coverage" 0 0 "$MUT/pfcov.sh" --good-has 'INFO.*4 \[CERT\] code marker' \
      --bad-lacks 'INFO.*4 \[CERT\] code marker' --bad-has 'probe-file cites resolved 1 of 1' -- bash @SUT@ "$TMP/p1325p/block-80c.md"
  fi

  echo "-- teeth-p1418-type-digits: revert the Type-token regex to letters-only; digits must be dropped again --"
  if mk_sed "teeth-p1418-type-digits" "$MUT/p1418.sh" '/# P1418-TYPE-DIGITS/ s/\[a-z0-9-\]/[a-z-]/'; then
    tooth "teeth-p1418-type-digits" 0 0 "$MUT/p1418.sh" --good-has "unrecognised Type: token 'experimental-p9';" \
      --bad-has "unrecognised Type: token 'experimental-p';" --bad-lacks 'experimental-p9' -- bash @SUT@ "$TMP/p1418-p6.md"
  fi

  echo "-- teeth-tr-home-guard: neuter the HOME guard; fake-HOME and ancestor-of-HOME roots must resolve ok again --"
  if mk_sed "teeth-tr-home-guard" "$MUT/trhg.sh" '/# TARGET-ROOT-HOME-GUARD/ s/.*/  : # TARGET-ROOT-HOME-GUARD [NEUTERED]/'; then
    tooth "teeth-tr-home-guard (equal)" 0 0 "$MUT/trhg.sh" --good-has 'extern +config\.sh:1' --good-lacks '^ +ok' \
      --bad-has 'ok \(target-root\) config\.sh:1' -- env "HOME=$TMP/f1h/home" bash @SUT@ "$TMP/f1h/home/corpus/b.md"
    tooth "teeth-tr-home-guard (ancestor)" 0 0 "$MUT/trhg.sh" --good-has 'extern +passwd\.txt:1' --good-lacks '^ +ok' \
      --bad-has 'ok \(target-root\) passwd\.txt:1' -- env "HOME=$TMP/f1a/corpus/projects/foo" bash @SUT@ "$TMP/f1a/corpus/projects/foo/notes/b.md"
  fi

  echo "-- teeth-tr-home-equal-only: guard only the equal case; an ANCESTOR of HOME must resolve again --"
  if mk_sed "teeth-tr-home-equal-only" "$MUT/trhe.sh" '/# TARGET-ROOT-HOME-GUARD/ s#"\$_tr_c"/\*#"$_tr_c/"#'; then
    tooth "teeth-tr-home-equal-only" 0 0 "$MUT/trhe.sh" --good-has 'extern +passwd\.txt:1' --good-lacks '^ +ok' \
      --bad-has 'ok \(target-root\) passwd\.txt:1' -- env "HOME=$TMP/f1a/corpus/projects/foo" bash @SUT@ "$TMP/f1a/corpus/projects/foo/notes/b.md"
  fi

  echo "-- teeth-tr-any-parent: accept any parent as project root; the markerless layout must resolve again --"
  if mk_sed "teeth-tr-any-parent" "$MUT/trap.sh" '/target_root="\$_tr_c"; break/ s/if \[ -e "[^"]*" \]/if true/'; then
    tooth "teeth-tr-any-parent" 0 0 "$MUT/trap.sh" --good-has 'extern +secret\.txt:1' --good-lacks '^ +ok' \
      --bad-has 'ok \(target-root\) secret\.txt:1' -- bash @SUT@ "$TMP/f1b/corpus/x/b.md"
  fi

  echo "-- teeth-tr-marker-*: drop one marker from the list; a project carrying only that marker must stop resolving --"
  if mk_sed "teeth-tr-marker-first" "$MUT/trm1.sh" '/# TARGET-ROOT-MARKERS/ s/package\.json //'; then
    tooth "teeth-tr-marker-first" 0 0 "$MUT/trm1.sh" --good-has 'ok \(target-root\) z\.sh:2' --bad-has 'extern +z\.sh:2' \
      --bad-lacks 'ok .*z\.sh' -- bash @SUT@ "$TMP/f1m-package.json/corpus/b.md"
  fi
  if mk_sed "teeth-tr-marker-middle" "$MUT/trm2.sh" '/# TARGET-ROOT-MARKERS/ s/Makefile //'; then
    tooth "teeth-tr-marker-middle" 0 0 "$MUT/trm2.sh" --good-has 'ok \(target-root\) z\.sh:2' --bad-has 'extern +z\.sh:2' \
      --bad-lacks 'ok .*z\.sh' -- bash @SUT@ "$TMP/f1m-Makefile/corpus/b.md"
  fi
  if mk_sed "teeth-tr-marker-last" "$MUT/trm3.sh" '/# TARGET-ROOT-MARKERS/ s/ \.git;/;/'; then
    tooth "teeth-tr-marker-last" 0 0 "$MUT/trm3.sh" --good-has 'ok \(target-root\) src/a\.sh:2' --bad-has 'extern +src/a\.sh:2' \
      --bad-lacks 'ok .*src/a\.sh' -- bash @SUT@ "$TMP/f1g/corpus/b.md"
  fi

  echo "-- teeth-tr-label: neuter the (target-root) label; the matching root must no longer be visible --"
  if mk_sed "teeth-tr-label" "$MUT/trl.sh" '/# TARGET-ROOT-LABEL/ s/.*/    _bt_okp="ok      "  # TARGET-ROOT-LABEL [NEUTERED]/'; then
    tooth "teeth-tr-label" 0 0 "$MUT/trl.sh" --good-has 'ok \(target-root\) src/index\.js:50-52' \
      --bad-has 'ok +src/index\.js:50-52' --bad-lacks 'target-root' -- bash @SUT@ "$TMP/p1325/corpus/block-78.md"
  fi

  echo "-- teeth-bt-range-fit: neuter the range-fit test; the first EXISTING root pre-empts again (RANGE!) --"
  if mk_sed "teeth-bt-range-fit" "$MUT/brf.sh" '/# BT-RANGE-FIT/ s/if .*/if true; then  # BT-RANGE-FIT [NEUTERED]/'; then
    tooth "teeth-bt-range-fit" 0 1 "$MUT/brf.sh" --good-has '^ +ok +lib\.sh:50' --good-lacks 'RANGE!' \
      --bad-has 'RANGE!.*lib\.sh:50' -- env "SOURCE_ROOT=$TMP/p2sr" bash @SUT@ "$f2/corpus/b.md"
  fi

  echo "-- teeth-bt-range-break: drop the break; a later fitting root must not override the first fitting one --"
  if mk_sed "teeth-bt-range-break" "$MUT/brb.sh" '/# BT-RANGE-FIT/,+1 s/; break//'; then
    tooth "teeth-bt-range-break" 0 0 "$MUT/brb.sh" --good-has 'ok \(target-root\) lib\.sh:2' \
      --bad-lacks 'target-root' --bad-has '^ +ok +lib\.sh:2' -- env "SOURCE_ROOT=$TMP/p2sr" bash @SUT@ "$f2/corpus/b2.md"
  fi

  echo "-- teeth-bt-first-existing: drop the first-existing fallback; a no-fit cite must not degrade to extern --"
  if mk_sed "teeth-bt-first-existing" "$MUT/bfe.sh" '/-z "\$_bt_resolve" \] && \[ -n "\$_bt_first"/ s/.*/    : # [NEUTERED]/'; then
    tooth "teeth-bt-first-existing" 1 0 "$MUT/bfe.sh" --good-has 'RANGE!.*lib\.sh:500.*3 lines' \
      --bad-has 'extern +lib\.sh:500' --bad-lacks 'RANGE!' -- env "SOURCE_ROOT=$TMP/p2sr" bash @SUT@ "$f2/corpus/b3.md"
  fi

  echo "-- teeth-tr-nearest: drop the break; the FARTHEST corpus ancestor must win again --"
  if mk_sed "teeth-tr-nearest" "$MUT/trn.sh" 's/_tr_c="\$(dirname "\$_tr_d")"; break; fi/_tr_c="$(dirname "$_tr_d")"; fi/'; then
    tooth "teeth-tr-nearest" 0 0 "$MUT/trn.sh" --good-has 'extern +outer\.sh:2' \
      --bad-has 'ok \(target-root\) outer\.sh:2' -- bash @SUT@ "$n3/corpus/inner/corpus/b.md"
  fi

  echo "-- teeth-tr-exact-name: substring match on 'corpus'; corpus-old must be a corpus dir again --"
  if mk_sed "teeth-tr-exact-name" "$MUT/trx.sh" 's/\[ "\$(basename "\$_tr_d")" = "corpus" \]/[[ "$(basename "$_tr_d")" == *corpus* ]]/'; then
    tooth "teeth-tr-exact-name" 0 0 "$MUT/trx.sh" --good-has 'extern +src/x\.sh:2' --good-lacks '^ +ok' \
      --bad-has 'ok \(target-root\) src/x\.sh:2' -- bash @SUT@ "$o4/corpus-old/b.md"
  fi
  # #1487 empty-digest teeth: detector off, exact-run match widened to substring, glued-char guard dropped,
  # elided-prefix arm dropped, md5 table entry dropped, and the per-line scan cut to one token per line.
  echo "-- teeth-eh-off: empty-digest match disabled --"
  if mk_sed "teeth-eh-off" "$MUT/eho.sh" '/# VB-EMPTY-DIGEST-MATCH$/s/if (tok == d\[k\] .*$/if (0)   # VB-EMPTY-DIGEST-MATCH/'; then
    tooth "teeth-eh-off" 1 0 "$MUT/eho.sh" --good-has 'EMPTYHASH!' --bad-lacks 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-single.md"
  fi
  echo "-- teeth-eh-substr: exact hex-run match widened to substring --"
  if mk_sed "teeth-eh-substr" "$MUT/ehs.sh" '/# VB-EMPTY-DIGEST-MATCH$/s/tok == d\[k\]/index(tok, d[k]) > 0/'; then
    tooth "teeth-eh-substr" 0 1 "$MUT/ehs.sh" --bad-has 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-sub-long.md"
  fi
  echo "-- teeth-eh-glue: drop the preceding-word-char guard --"
  if mk_sed "teeth-eh-glue" "$MUT/ehg.sh" 's/if (before !~ \/\[a-z0-9_\]\/) {/if (1) {/'; then
    tooth "teeth-eh-glue" 0 1 "$MUT/ehg.sh" --bad-has 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-sub-word.md"
  fi
  echo "-- teeth-eh-nopfx: elided-prefix arm dropped --"
  if mk_sed "teeth-eh-nopfx" "$MUT/ehp.sh" '/# VB-EMPTY-DIGEST-MATCH$/s/ || (elided .*index(d\[k\], tok) == 1))/)/'; then
    tooth "teeth-eh-nopfx" 1 0 "$MUT/ehp.sh" --good-has 'EMPTYHASH!' --bad-lacks 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-elided.md"
  fi
  echo "-- teeth-eh-md5: md5 digest dropped from the table --"
  if mk_sed "teeth-eh-md5" "$MUT/ehm.sh" '/d\["md5"\]=/s/d41d8cd98f00b204e9800998ecf8427e/00000000000000000000000000000000/'; then
    tooth "teeth-eh-md5" 1 0 "$MUT/ehm.sh" --good-has 'EMPTYHASH!' --bad-lacks 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-md5.md"
  fi
  echo "-- teeth-eh-waiver: waiver ignored; a marked line must FAIL again --"
  if mk_sed "teeth-eh-waiver" "$MUT/ehw.sh" 's/if (index(\$0, "<!-- empty-digest: quoted -->") > 0)/if (0)/'; then
    tooth "teeth-eh-waiver" 0 1 "$MUT/ehw.sh" --good-has 'INFO +empty-digest waived' --bad-has 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-waived.md"
  fi
  # #1500: the verdict rides the machine tag, not the printed text. Rewording the INFO message must NOT turn a
  # waived hit into a FAIL (the old prefix match would have), and dropping the W branch must.
  echo "-- teeth-eh-tag: waived verdict is decided by the W tag, not the INFO text --"
  if mk_sed "teeth-eh-tag-reword" "$MUT/ehr.sh" 's/W\\t   INFO    empty-digest waived/W\\t   NOTE: empty-digest waived/'; then
    _eh_r_out="$(bash "$MUT/ehr.sh" "$TMP/eh-waived.md" 2>&1)"; _eh_r_rc=$?
    if [ "$_eh_r_rc" = 0 ] && grep -q 'NOTE: empty-digest waived' <<<"$_eh_r_out"; then ok "teeth-eh-tag: reworded INFO text still waived (exit 0)"
    else no "teeth-eh-tag: reworded INFO text changed the verdict (exit $_eh_r_rc)"; fi
  fi
  if mk_sed "teeth-eh-tag" "$MUT/eht.sh" '/# VB-EH-WAIVED-TAG$/d'; then
    tooth "teeth-eh-tag" 0 1 "$MUT/eht.sh" --good-has 'INFO +empty-digest waived' --bad-has 'EMPTYHASH|empty-digest waived' -- bash @SUT@ "$TMP/eh-waived.md"
  fi
  echo "-- teeth-eh-norc / teeth-eh-notrailer: a failing or blind detector must read as degraded --"
  if mk_sed "teeth-eh-norc" "$MUT/ehrc.sh" 's/_vb_eh_rc=$?/_vb_eh_rc=0/'; then
    tooth "teeth-eh-norc" 1 0 "$MUT/ehrc.sh" --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-eh-rcfail:$PATH" bash @SUT@ "$TMP/eh-clean.md"
  fi
  if mk_sed "teeth-eh-notrailer" "$MUT/ehtr.sh" 's/ || \[ -n "\$_vb_eh_trailer" \]; then/; then/'; then
    tooth "teeth-eh-notrailer" 1 0 "$MUT/ehtr.sh" --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-eh-silent:$PATH" bash @SUT@ "$TMP/eh-clean.md"
  fi
  echo "-- teeth-eh-waiver-global: waiver also exempts every other line (one marker disables the check) --"
  if mk_sed "teeth-eh-waiver-global" "$MUT/ehwg.sh" 's/if (index(\$0, "<!-- empty-digest: quoted -->") > 0)/if (1)/'; then
    tooth "teeth-eh-waiver-global" 1 0 "$MUT/ehwg.sh" --good-has 'EMPTYHASH! line 8' --bad-lacks 'EMPTYHASH!' -- bash @SUT@ "$TMP/eh-waive-other.md"
  fi
  echo "-- teeth-eh-oneperline: stop after the first token on a line --"
  if mk_sed "teeth-eh-oneperline" "$MUT/eh1.sh" '/^      rest = after$/s/.*/      rest = ""/'; then
    tooth "teeth-eh-oneperline" 1 1 "$MUT/eh1.sh" --good-has 'cited: 2 \(FAIL\)' --bad-has 'cited: 1 \(FAIL\)' -- bash @SUT@ "$TMP/eh-twosame.md"
  fi
  # kit #1207 ephemeral-path teeth: detector off, tmp arm dropped, scratchpad arm dropped, glue guard dropped,
  # sha256 exemption dropped, exemption widened to the whole block, and a blind/failing detector read as clean.
  echo "-- teeth-ep-tmp: /tmp arm disabled --"
  if mk_sed "teeth-ep-tmp" "$MUT/ept.sh" '/# VB-EP-TMP$/s/^    spad = 0; scan(.*$/    # VB-EP-TMP/'; then
    tooth "teeth-ep-tmp" 1 0 "$MUT/ept.sh" --good-has 'EPHEMERAL!' --bad-lacks 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-single.md"
  fi
  echo "-- teeth-ep-spad: scratchpad arm disabled --"
  if mk_sed "teeth-ep-spad" "$MUT/eps.sh" '/# VB-EP-SCRATCHPAD$/s/^    spad = 1; scan(.*$/    # VB-EP-SCRATCHPAD/'; then
    tooth "teeth-ep-spad" 1 0 "$MUT/eps.sh" --good-has 'EPHEMERAL!' --bad-lacks 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-relspad.md"
  fi
  echo "-- teeth-ep-glue: preceding-path-char guard dropped --"
  if mk_sed "teeth-ep-glue" "$MUT/epg.sh" '/# VB-EP-GLUE$/s/before !~ glue \&\& //'; then
    tooth "teeth-ep-glue" 0 1 "$MUT/epg.sh" --good-has '== exit 0 ==' --bad-has 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-glued.md"
  fi
  echo "-- teeth-ep-anchor-off: sha256 exemption dropped --"
  if mk_sed "teeth-ep-anchor-off" "$MUT/epa.sh" '/# VB-EP-ANCHOR$/s/hasdigest(\$0)/0/'; then
    tooth "teeth-ep-anchor-off" 0 1 "$MUT/epa.sh" --good-has 'ephemeral-anchored' --bad-has 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-anchored.md"
  fi
  echo "-- teeth-ep-digest64: the word sha256 alone anchors (digest requirement dropped) --"
  if mk_sed "teeth-ep-digest64" "$MUT/epd.sh" '/# VB-EP-DIGEST64$/s/length(run) == 64/1/'; then
    tooth "teeth-ep-digest64" 1 0 "$MUT/epd.sh" --good-has 'EPHEMERAL!' --bad-lacks 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-nodigest.md"
  fi
  echo "-- teeth-ep-anchor-global: sha256 anywhere in the block exempts every line --"
  if mk_sed "teeth-ep-anchor-global" "$MUT/epag.sh" '/# VB-EP-ANCHOR$/s/hasdigest(\$0)/1/'; then
    tooth "teeth-ep-anchor-global" 1 0 "$MUT/epag.sh" --good-has 'EPHEMERAL!' --bad-lacks 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-anchored-other.md"
  fi
  echo "-- teeth-ep-strict: --strict-ephemeral ignored (stays a WARN) --"
  if mk_sed "teeth-ep-strict" "$MUT/epst.sh" '/# VB-EP-STRICT$/s/if (strict == "1")/if (0)/'; then
    tooth "teeth-ep-strict" 1 0 "$MUT/epst.sh" --good-has 'EPHEMERAL!' --bad-lacks 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-single.md"
  fi
  echo "-- teeth-ep-strict-flag: the flag is no longer consumed/honoured --"
  if mk_sed "teeth-ep-strict-flag" "$MUT/epsf.sh" '/# VB-EP-STRICT-FLAG$/s/STRICT_EP=1/STRICT_EP=0/'; then
    tooth "teeth-ep-strict-flag" 1 0 "$MUT/epsf.sh" --good-has 'EPHEMERAL!' --bad-lacks 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-single.md"
  fi
  echo "-- teeth-ep-warn-rc: a default WARN flips the exit code (must stay unchanged) --"
  if mk_sed "teeth-ep-warn-rc" "$MUT/epw.sh" 's/    W) echo "\$_vb_ep_text"; _vb_ep_n=\$((_vb_ep_n + 1)); continue;;/    W) echo "$_vb_ep_text"; _vb_ep_n=$((_vb_ep_n + 1)); rc=1; continue;;/'; then
    tooth "teeth-ep-warn-rc" 0 1 "$MUT/epw.sh" --good-has 'EPHEMERAL\?' --bad-has '== exit 1 ==' -- bash @SUT@ "$TMP/ep-single.md"
  fi
  echo "-- teeth-ep-marker: marker ignored --"
  if mk_sed "teeth-ep-marker" "$MUT/epm.sh" '/# VB-EP-MARKER$/s/index(\$0, "<!-- ephemeral-ok:")/0/'; then
    tooth "teeth-ep-marker" 0 0 "$MUT/epm.sh" --good-lacks 'EPHEMERAL\?' --bad-has 'EPHEMERAL\?' -- bash @SUT@ "$TMP/ep-mk-ok.md"
  fi
  echo "-- teeth-ep-reason: empty reason accepted as a valid waiver --"
  if mk_sed "teeth-ep-reason" "$MUT/epr.sh" '/# VB-EP-REASON$/s/if (reason != "") ok = 1/ok = 1/'; then
    tooth "teeth-ep-reason" 0 0 "$MUT/epr.sh" --good-has 'EPHEMERAL\?' --good-has 'invalid marker' --bad-lacks 'EPHEMERAL\?' -- bash @SUT@ "$TMP/ep-mk-empty.md"
  fi
  echo "-- teeth-ep-invalid-line: invalid marker no longer typed --"
  if mk_sed "teeth-ep-invalid-line" "$MUT/epi.sh" 's/if (mk > 0 \&\& !flagged\[NR\])/if (0)/'; then
    tooth "teeth-ep-invalid-line" 0 0 "$MUT/epi.sh" --good-has 'invalid marker' --bad-lacks 'invalid marker' -- bash @SUT@ "$TMP/ep-mk-empty.md"
  fi
  echo "-- teeth-ep-norc / teeth-ep-notrailer: a failing or blind detector must read as degraded --"
  if mk_sed "teeth-ep-norc" "$MUT/eprc.sh" 's/_vb_ep_rc=\$?/_vb_ep_rc=0/'; then
    tooth "teeth-ep-norc" 1 0 "$MUT/eprc.sh" --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-ep-rcfail:$PATH" bash @SUT@ "$TMP/ep-clean.md"
  fi
  if mk_sed "teeth-ep-notrailer" "$MUT/eptr.sh" 's/ || \[ -n "\$_vb_ep_trailer" \]; then/; then/'; then
    tooth "teeth-ep-notrailer" 1 0 "$MUT/eptr.sh" --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-ep-silent:$PATH" bash @SUT@ "$TMP/ep-clean.md"
  fi
  echo "-- teeth-ep-rc: findings no longer flip the exit code --"
  if mk_sed "teeth-ep-rc" "$MUT/eprc2.sh" 's/_vb_ep_n=\$((_vb_ep_n + 1)); rc=1/_vb_ep_n=$((_vb_ep_n + 1))/'; then
    tooth "teeth-ep-rc" 1 0 "$MUT/eprc2.sh" --good-has 'ephemeral-path cites: 1 \(FAIL\)' --bad-has '== exit 0 ==' -- bash @SUT@ --strict-ephemeral "$TMP/ep-single.md"
  fi
  # kit #1207 (b) manifest teeth: sha compare off, row lookup widened, sha64 validity dropped, FAIL rc dropped.
  echo "-- teeth-mf-sha: sha256 comparison always passes --"
  if mk_sed "teeth-mf-sha" "$MUT/mfs.sh" '/# VB-MF-SHA$/s/if grep -qxF "\$_vb_mf_have" <<<"\$_vb_mf_want"; then/if true; then/'; then
    tooth "teeth-mf-sha" 1 0 "$MUT/mfs.sh" --good-has 'MANIFEST!.*differs' --bad-lacks 'MANIFEST!' -- bash @SUT@ "$TMP/mf-badsha/block.md"
  fi
  echo "-- teeth-mf-lookup: every script matches every row --"
  if mk_sed "teeth-mf-lookup" "$MUT/mfl.sh" '/# VB-MF-LOOKUP$/s/\$1 == b/1/'; then
    tooth "teeth-mf-lookup" 1 1 "$MUT/mfl.sh" --good-has 'no valid SCRIPTS-MANIFEST row' --bad-lacks 'no valid SCRIPTS-MANIFEST row' -- bash @SUT@ "$TMP/mf-norow/block.md"
  fi
  # the row grammar itself (64-hex sha cell, path resolution) now lives in lib/scripts-manifest.sh and is pinned by
  # scripts-manifest.test.sh; the two teeth below pin that verify-block really consults the shared parser (kit #1659).
  echo "-- teeth-mf-parser-unwired: rows no longer read from the shared parser --"
  if mk_sed "teeth-mf-parser-unwired" "$MUT/mfpu.sh" '/# VB-MF-PARSE$/s/_vb_mf_one=\$(scripts_manifest_rows "\$target" "\$_vb_mf_f")/_vb_mf_one=""/'; then
    tooth "teeth-mf-parser-unwired" 0 1 "$MUT/mfpu.sh" --good-has 'manifest-ok' --bad-has 'MANIFEST!  sources/probes/b1/a.sh  \(no valid SCRIPTS-MANIFEST row' -- bash @SUT@ "$TMP/mf-ok/block.md"
  fi
  echo "-- teeth-mf-parser-fail: a failing shared parser must read as degraded --"
  if [ "$(id -u)" = 0 ]; then echo "  (skipped: running as root, an unreadable manifest cannot be built)"
  elif mk_sed "teeth-mf-parser-fail" "$MUT/mfpf.sh" '/# VB-MF-PARSE$/s/ || { _vb_mf_prc=1; break; }//'; then
    tooth "teeth-mf-parser-fail" 1 1 "$MUT/mfpf.sh" --good-has 'DEGRADED manifest parse failed' --bad-lacks 'DEGRADED manifest parse failed' -- bash @SUT@ "$TMP/mf-unreadable/block.md"
  fi
  echo "-- teeth-mf-cite-boundary: cite terminator dropped (phantom a.sh from a.sh.bak) --"
  if mk_sed "teeth-mf-cite-boundary" "$MUT/mfcb.sh" '/# VB-MF-CITE$/{n;s/\\.?(\[^A-Za-z0-9_.\/-]|\$)/\\b/;}'; then
    tooth "teeth-mf-cite-boundary" 0 1 "$MUT/mfcb.sh" --good-has 'none — no preserved script cited' --bad-has 'MANIFEST!  sources/probes/b1/a.sh' -- bash @SUT@ "$TMP/mf-bak-single/block.md"
  fi
  echo "-- teeth-mf-findrc: manifest scan status ignored --"
  if mk_sed "teeth-mf-findrc" "$MUT/mffr.sh" 's/_vb_mf_frc=\${_vb_mf_raw##\*@@RC=}/_vb_mf_frc=0/'; then
    tooth "teeth-mf-findrc" 1 0 "$MUT/mffr.sh" --good-has 'DEGRADED manifest scan failed' --bad-lacks 'DEGRADED' -- env PATH="$TMP/stub-bin-mf:$PATH" bash @SUT@ "$MFD_FF/block.md"
  fi
  echo "-- teeth-mf-dir: path-resolved comparison replaced by a BASENAME comparison (directory scoping lost) --"
  if mk_sed "teeth-mf-dir" "$MUT/mfd.sh" '/# VB-MF-LOOKUP$/s#\$1 == b#(n=split($1,q,"/")) \&\& (m=split(b,r,"/")) \&\& q[n]==r[m]#'; then
    tooth "teeth-mf-dir" 1 0 "$MUT/mfd.sh" --good-has 'MANIFEST!.*no valid SCRIPTS-MANIFEST row' --bad-lacks 'MANIFEST!' -- bash @SUT@ "$TMP/mf-othermf/block.md"
  fi
  echo "-- teeth-ep-segment: scratchpad as a tail of a longer name counts as a segment --"
  if mk_sed "teeth-ep-segment" "$MUT/epsg.sh" '/# VB-EP-SEGMENT$/s/if (!(i == 1 || substr(tok, i - 1, 1) == "\/")) return 1/if (0) return 1/'; then
    tooth "teeth-ep-segment" 0 1 "$MUT/epsg.sh" --good-has '== exit 0 ==' --bad-has 'EPHEMERAL!' -- bash @SUT@ --strict-ephemeral "$TMP/ep-spadglue.md"
  fi
  echo "-- teeth-ep-owned: scratchpad arm also claims /tmp-owned tokens (double count) --"
  if mk_sed "teeth-ep-owned" "$MUT/epo.sh" '/# VB-EP-OWNED$/s/return 1/return 0/'; then
    tooth "teeth-ep-owned" 1 1 "$MUT/epo.sh" --good-has 'ephemeral-path cites: 1 \(FAIL\)' --bad-has 'ephemeral-path cites: 2 \(FAIL\)' -- bash @SUT@ --strict-ephemeral "$TMP/ep-spad.md"
  fi
  echo "-- teeth-mf-rc: manifest findings no longer flip the exit code --"
  if mk_sed "teeth-mf-rc" "$MUT/mfrc.sh" 's/(manifest sha256 differs from the file.s: \${_vb_mf_have:0:16})"; rc=1;/(manifest sha256 differs from the file'"'"'s: ${_vb_mf_have:0:16})";/'; then
    tooth "teeth-mf-rc" 1 0 "$MUT/mfrc.sh" --good-has 'MANIFEST!' --bad-has '== exit 0 ==' -- bash @SUT@ "$TMP/mf-badsha/block.md"
  fi
  echo "-- teeth-mf-nomf: absence of any manifest is no longer announced --"
  if mk_sed "teeth-mf-nomf" "$MUT/mfn.sh" 's/echo "   INFO    no SCRIPTS-MANIFEST under/echo "   (silent) under/'; then
    tooth "teeth-mf-nomf" 0 0 "$MUT/mfn.sh" --good-has 'INFO    no SCRIPTS-MANIFEST' --bad-lacks 'no SCRIPTS-MANIFEST' -- bash @SUT@ "$TMP/mf-nomf/block.md"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
