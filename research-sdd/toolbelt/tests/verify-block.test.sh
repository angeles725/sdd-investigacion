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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
