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
fi


# ==== NR-C: synthesis remission gate (8 cases + mutation controls) ====

# 45 — C1: non-synthesis block → no synthesis gate output (regression guard).
d="$TMP/c1-nonsyn.md"
{ echo "# Block 50 — evidence block"; echo
  echo "> Method: [CERT] = verified."; echo
  echo "---"; echo
  echo "## 50.1 claim [CERT]"; echo "The class does X [CERT]."; } > "$d"
out="$(run "$d")"
if ! grep -qiE 'synthesis remission gate|remission-ok|remission summary|SYN-ZERO-REM' <<<"$out"; then
  ok "C1: non-synthesis block → no synthesis gate output (regression guard)"
else no "C1: synthesis gate fired on non-synthesis block :: $(grep -iE 'synthesis|remission' <<<"$out" | head -1)"; fi

# 46 — C2a: form 1 `[Block N]` §N.x → remission-ok (block file + section heading present).
printf '# Block 295\n\n## 295.7 — TCP socket\nContent.\n' > "$TMP/block295.md"
d="$TMP/c2a-f1.md"
{ echo "# Block 315 — SYNTHESIS of the modbus focus"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 315.1 cross-ref"; echo "\`[Block 295]\` §295.7 — the transport"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'remission-ok.*295|295.*remission-ok' <<<"$out"; then
  ok "C2a: form 1 \`[Block N]\` §N.x → remission-ok, exit 0"
else no "C2a: form 1 not resolved: rc=[$rc] :: $(grep -iE 'remission|295' <<<"$out" | head -2)"; fi

# 47 — C2b: form 2 B N §N.x → remission-ok.
printf '# Block 2\n\n## 2.3 — inventory\nContent.\n' > "$TMP/block2.md"
d="$TMP/c2b-f2.md"
{ echo "# Block 9 — DESIGN / SYNTHESIS"; echo
  echo "> BLOCK TYPE: DESIGN / SYNTHESIS. High [INFER] expected."; echo
  echo "---"; echo
  echo "## 9.1 site facts"; echo "36,239 points (B2 §2.3)"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'remission-ok.*\b2\b' <<<"$out"; then
  ok "C2b: form 2 B N §N.x → remission-ok, exit 0"
else no "C2b: form 2 not resolved: rc=[$rc] :: $(grep -iE 'remission|B2' <<<"$out" | head -2)"; fi

# 48 — C2c: form 3 [Bloque N] §N.x → remission-ok (Spanish).
printf '# Bloque 253\n\n## 253.2 — finding\nContent.\n' > "$TMP/logosoft-bloque253.md"
d="$TMP/c2c-f3.md"
{ echo "# Bloque 270 — SÍNTESIS del corpus"; echo
  echo "> BLOQUE TIPO SÍNTESIS. Las citas son remisiones."; echo
  echo "---"; echo
  echo "## 270.1 hallazgos"; echo "[Bloque 253] §253.2 — el hallazgo"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'remission-ok.*253|253.*remission-ok' <<<"$out"; then
  ok "C2c: form 3 [Bloque N] §N.x → remission-ok, exit 0"
else no "C2c: form 3 not resolved: rc=[$rc] :: $(grep -iE 'remission|253' <<<"$out" | head -2)"; fi

# 49 — C2d: form 4 [Block N §N.x] (section inside brackets) → remission-ok.
printf '# Block 4\n\n## 4.1 — VID\nContent.\n' > "$TMP/block4.md"
d="$TMP/c2d-f4.md"
{ echo "# Block 12 — Synthesis: the USB model"; echo
  echo "> BLOCK TYPE: design/synthesis (per METHODOLOGY §11)."; echo
  echo "---"; echo
  echo "## 12.1 topology"; echo "VID confirmed [Block 4 §4.1]."; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'remission-ok.*\b4\b' <<<"$out"; then
  ok "C2d: form 4 [Block N §N.x] → remission-ok, exit 0"
else no "C2d: form 4 not resolved: rc=[$rc] :: $(grep -iE 'remission|block 4' <<<"$out" | head -2)"; fi

# 50 — C3: remission with MISSING SECTION → exit 1, message names "section" not "file".
printf '# Block 8\n\n## 8.1 — heading only\nContent.\n' > "$TMP/block8.md"
d="$TMP/c3-missec.md"
{ echo "# Block 12 — Synthesis"; echo
  echo "> BLOCK TYPE: design/synthesis."; echo
  echo "---"; echo
  echo "## 12.1 findings"; echo "[Block 8] §8.5 — section does not exist"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qiE 'REMISSION-MISSING-SECTION|missing.section|section.*not found' <<<"$out" \
   && ! grep -qiE 'REMISSION-MISSING-FILE|file.*not found' <<<"$out"; then
  ok "C3: section missing → exit 1, section message (not file message)"
else no "C3: section-missing not caught or wrong message: rc=[$rc] :: $(grep -iE 'MISSING|remission' <<<"$out" | head -2)"; fi

# 51 — C4: remission with MISSING FILE → exit 1, message names "file" (distinct from C3).
d="$TMP/c4-misfile.md"
{ echo "# Block 12 — Synthesis"; echo
  echo "> BLOCK TYPE: design/synthesis."; echo
  echo "---"; echo
  echo "## 12.1 findings"; echo "[Block 99] §99.3 — block 99 does not exist"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "1" ] && grep -qiE 'REMISSION-MISSING-FILE|file.*not found' <<<"$out" \
   && ! grep -qiE 'REMISSION-MISSING-SECTION|section.*not found' <<<"$out"; then
  ok "C4: file missing → exit 1, file message (distinct from C3 section message)"
else no "C4: file-missing not caught or non-distinct message: rc=[$rc] :: $(grep -iE 'MISSING|remission' <<<"$out" | head -2)"; fi

# 52 — C5: self-reference (block number == current block) → skipped, exit 0, not resolved.
d="$TMP/syn-block315.md"
{ echo "# Block 315 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 315.1 self"; echo "[Block 315] §315.1 — self-reference to same block"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -qiE 'remission-ok.*315|REMISSION-MISSING.*315' <<<"$out"; then
  ok "C5: [Block N] §N.x where N=current block → skipped (self-ref), exit 0"
else no "C5: self-reference not skipped: rc=[$rc] :: $(grep -iE 'remission.*315|315.*remission' <<<"$out" | head -2)"; fi

# 53 — C6: [Block N] §N.x entirely inside a backtick code span → not parsed, exit 0.
# block295.md already exists in TMP (from C2a) with §295.7; if parsed, remission-ok would fire.
d="$TMP/c6-codespan.md"
{ echo "# Block 315 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 315.1 example"; echo "Use the format \`[Block 295] §295.7\` for citations."; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && ! grep -qiE 'remission-ok.*295|REMISSION-MISSING.*295' <<<"$out"; then
  ok "C6: [Block N] §N.x inside backtick code span → not parsed, exit 0"
else no "C6: code-span remission was parsed: rc=[$rc] :: $(grep -iE 'remission.*295|295.*remission' <<<"$out" | head -2)"; fi

# 54 — C7: unrecognised block-ref+§ form (form 5) → WARN emitted, exit stays 0.
d="$TMP/c7-unrecog.md"
{ echo "# Block 400 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 400.1 kidcad"; echo "[[bloque32]] §321 — kidcad form (form 5, deferred)"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'WARN.*unrecog|unrecog.*WARN|unrecognised|unrecognized' <<<"$out"; then
  ok "C7: unrecognised form → WARN, exit 0"
else no "C7: unrecognised form not warned: rc=[$rc] :: $(grep -iE 'WARN|unrecog|form' <<<"$out" | head -2)"; fi

# 55 — C8: synthesis block with ZERO remission-shaped text → distinct "no remissions" summary
#      (not confused with C7 which has candidates but they are unrecognised).
d="$TMP/c8-zerorems.md"
{ echo "# Block 500 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block. Editorial only."; echo
  echo "---"; echo
  echo "## 500.1 editorial"; echo "Commentary with no cross-block references at all."; } > "$d"
out="$(run "$d")"
if grep -qiE 'NO remission-shaped|no remission|zero remission' <<<"$out" \
   && ! grep -qiE 'WARN.*unrecog|unrecog.*WARN' <<<"$out"; then
  ok "C8: zero remission-shaped text → 'no remissions' summary (distinct from C7 unrecognised)"
else no "C8: zero-remission summary not distinct :: $(grep -iE 'remission|WARN|summary' <<<"$out" | head -2)"; fi

# ---- Synthesis mutation controls (--prove-teeth) ----
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth-C1: neuter SYN-GATE-DETECT; synthesis gate must not fire on synthesis block --"
  mutant_C1="$TMP/vb.C1MUT.sh"
  if grep -q '# SYN-GATE-DETECT' "$SUT"; then
    sed '/# SYN-GATE-DETECT/ s/.*/if false; then  # SYN-GATE-DETECT [NEUTERED]/' "$SUT" > "$mutant_C1"
    bash -n "$mutant_C1" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C1: mutant syntax error (rc=$_syn)"
    else
      d_C1="$TMP/c1t.md"
      { echo "# Block 315 — SYNTHESIS"; echo; echo "> this is a SYNTHESIS block."; echo
        echo "---"; echo; echo "## 315.1 x"; echo "[Block 295] §295.7 — ref"; } > "$d_C1"
      mout="$(bash "$mutant_C1" "$d_C1" 2>/dev/null)"
      if ! grep -qiE 'synthesis remission|remission-ok' <<<"$mout"; then
        ok "teeth-C1: neutered gate → no gate output for synthesis block (test 46 has teeth)"
      else no "teeth-C1: neutered gate still shows gate output :: $(grep -iE 'synthesis|remission' <<<"$mout" | head -1)"; fi
    fi
  else no "teeth-C1: SYN-GATE-DETECT sentinel not found in SUT"; fi

  echo "-- teeth-C3: neuter SYN-MISSING-SECTION; section-missing must revert to exit 0 --"
  mutant_C3="$TMP/vb.C3MUT.sh"
  if grep -q '# SYN-MISSING-SECTION' "$SUT"; then
    sed '/# SYN-MISSING-SECTION/ s/.*/      echo "   remission-warn  missing"  # SYN-MISSING-SECTION [NEUTERED]/' "$SUT" > "$mutant_C3"
    bash -n "$mutant_C3" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C3: mutant syntax error"
    else
      d_C3="$TMP/c3t.md"
      printf '# Block 8\n\n## 8.1 — heading\nContent.\n' > "$TMP/block8.md"
      { echo "# Block 12 — Synthesis"; echo; echo "> BLOCK TYPE: design/synthesis."; echo
        echo "---"; echo; echo "## 12.1 x"; echo "[Block 8] §8.5 — missing section"; } > "$d_C3"
      bash "$mutant_C3" "$d_C3" >/dev/null 2>/dev/null; mc3_rc=$?
      if [ "$mc3_rc" = "0" ]; then ok "teeth-C3: neutered section-missing → exit 0 (test 50 has teeth)"
      else no "teeth-C3: neutered mutant still exits 1: rc=[$mc3_rc]"; fi
    fi
  else no "teeth-C3: SYN-MISSING-SECTION sentinel not found in SUT"; fi

  echo "-- teeth-C4: neuter SYN-MISSING-FILE; file-missing message must collapse (C3/C4 not distinct) --"
  mutant_C4="$TMP/vb.C4MUT.sh"
  if grep -q '# SYN-MISSING-FILE' "$SUT"; then
    sed '/# SYN-MISSING-FILE/ s/.*/      echo "   REMISSION-MISSING-SECTION  neutered"  # SYN-MISSING-FILE [NEUTERED]/' "$SUT" > "$mutant_C4"
    bash -n "$mutant_C4" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C4: mutant syntax error"
    else
      d_C4="$TMP/c4t.md"
      { echo "# Block 12 — Synthesis"; echo; echo "> BLOCK TYPE: design/synthesis."; echo
        echo "---"; echo; echo "## 12.1 x"; echo "[Block 99] §99.3 — no such file"; } > "$d_C4"
      mout="$(bash "$mutant_C4" "$d_C4" 2>/dev/null)"
      if grep -qiE 'REMISSION-MISSING-SECTION' <<<"$mout" && ! grep -qiE 'REMISSION-MISSING-FILE' <<<"$mout"; then
        ok "teeth-C4: neutered file-missing → C3/C4 messages collapse (test 51 has teeth)"
      else no "teeth-C4: messages did not collapse :: $(grep -iE 'MISSING' <<<"$mout" | head -2)"; fi
    fi
  else no "teeth-C4: SYN-MISSING-FILE sentinel not found in SUT"; fi

  echo "-- teeth-C5: neuter SYN-SELF-SKIP; self-reference must now be counted --"
  mutant_C5="$TMP/vb.C5MUT.sh"
  if grep -q '# SYN-SELF-SKIP' "$SUT"; then
    sed '/# SYN-SELF-SKIP/ s/.*/:  # SYN-SELF-SKIP [NEUTERED]/' "$SUT" > "$mutant_C5"
    bash -n "$mutant_C5" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C5: mutant syntax error"
    else
      d_C5="$TMP/c5t.md"; cp "$TMP/syn-block315.md" "$d_C5"
      mout="$(bash "$mutant_C5" "$d_C5" 2>/dev/null)"
      if grep -qiE 'remission-ok.*315|REMISSION-MISSING.*315' <<<"$mout"; then
        ok "teeth-C5: neutered self-skip → self-ref counted (test 52 has teeth)"
      else no "teeth-C5: neutered self-skip didn't count self-ref :: $(grep -iE 'remission.*315|315.*remission' <<<"$mout" | head -2)"; fi
    fi
  else no "teeth-C5: SYN-SELF-SKIP sentinel not found in SUT"; fi

  echo "-- teeth-C6: neuter SYN-CODE-SPAN-FILTER; code-span remission must now be parsed --"
  mutant_C6="$TMP/vb.C6MUT.sh"
  if grep -q '# SYN-CODE-SPAN-FILTER' "$SUT"; then
    sed '/# SYN-CODE-SPAN-FILTER/ s/.*/_bt_spans=""  # SYN-CODE-SPAN-FILTER [NEUTERED]/' "$SUT" > "$mutant_C6"
    bash -n "$mutant_C6" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C6: mutant syntax error"
    else
      # block295.md (with §295.7 heading) must exist for the neutered parse to resolve
      printf '# Block 295\n\n## 295.7 — TCP socket\nContent.\n' > "$TMP/block295.md"
      d_C6="$TMP/c6t.md"
      { echo "# Block 315 — SYNTHESIS"; echo; echo "> this is a SYNTHESIS block."; echo
        echo "---"; echo; echo "## 315.1 example"
        echo "Use the format \`[Block 295] §295.7\` for citations."; } > "$d_C6"
      mout="$(bash "$mutant_C6" "$d_C6" 2>/dev/null)"
      if grep -qiE 'remission-ok.*295|REMISSION-MISSING.*295' <<<"$mout"; then
        ok "teeth-C6: neutered code-span filter → code-span remission now parsed (test 53 has teeth)"
      else no "teeth-C6: neutered filter didn't parse code-span remission :: $(grep -iE 'remission.*295|295.*remission' <<<"$mout" | head -2)"; fi
    fi
  else no "teeth-C6: SYN-CODE-SPAN-FILTER sentinel not found in SUT"; fi

  echo "-- teeth-C7: neuter SYN-UNRECOG; unrecognised form WARN must not fire --"
  mutant_C7="$TMP/vb.C7MUT.sh"
  if grep -q '# SYN-UNRECOG' "$SUT"; then
    sed '/# SYN-UNRECOG/ s/.*/:  # SYN-UNRECOG [NEUTERED]/' "$SUT" > "$mutant_C7"
    bash -n "$mutant_C7" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C7: mutant syntax error"
    else
      d_C7="$TMP/c7t.md"
      { echo "# Block 400 — SYNTHESIS"; echo; echo "> this is a SYNTHESIS block."; echo
        echo "---"; echo; echo "## 400.1 x"; echo "[[bloque32]] §321 — unrecognised"; } > "$d_C7"
      mout="$(bash "$mutant_C7" "$d_C7" 2>/dev/null)"
      if ! grep -qiE 'WARN.*unrecog|unrecog.*WARN|unrecognised' <<<"$mout"; then
        ok "teeth-C7: neutered SYN-UNRECOG → no WARN for unrecognised form (test 54 has teeth)"
      else no "teeth-C7: neutered WARN still fires :: $(grep -iE 'WARN|unrecog' <<<"$mout" | head -1)"; fi
    fi
  else no "teeth-C7: SYN-UNRECOG sentinel not found in SUT"; fi

  echo "-- teeth-C8: neuter SYN-ZERO-REM; zero-remission distinct summary must disappear --"
  mutant_C8="$TMP/vb.C8MUT.sh"
  if grep -q '# SYN-ZERO-REM' "$SUT"; then
    sed '/# SYN-ZERO-REM/ s/.*/:  # SYN-ZERO-REM [NEUTERED]/' "$SUT" > "$mutant_C8"
    bash -n "$mutant_C8" 2>/dev/null; _syn=$?
    if [ "$_syn" != "0" ]; then no "teeth-C8: mutant syntax error"
    else
      d_C8="$TMP/c8t.md"
      { echo "# Block 500 — SYNTHESIS"; echo; echo "> this is a SYNTHESIS block."; echo
        echo "---"; echo; echo "## 500.1 editorial"; echo "No cross-block references."; } > "$d_C8"
      mout="$(bash "$mutant_C8" "$d_C8" 2>/dev/null)"
      if ! grep -qiE 'NO remission-shaped|no remission|zero remission' <<<"$mout"; then
        ok "teeth-C8: neutered zero-rem → no distinct 'no remissions' message (test 55 has teeth)"
      else no "teeth-C8: neutered zero-rem still shows distinct message :: $(grep -iE 'no remission|zero' <<<"$mout" | head -1)"; fi
    fi
  else no "teeth-C8: SYN-ZERO-REM sentinel not found in SUT"; fi
fi

# ==== NR-C correction: pair-based dedup for unrecognised remissions ====

# 56 — NR-C dedup: same remission 4 times → parsed counts it once, unrecog=0, no false WARN.
printf '# Block 7\n\n## 7.1 heading\nContent.\n' > "$TMP/block7.md"
d="$TMP/nrc-dedup.md"
{ echo "# Block 316 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 316.1 first";   echo "B7 §7.1 — first mention"
  echo "## 316.2 second";  echo "B7 §7.1 — second mention"
  echo "## 316.3 third";   echo "B7 §7.1 — third mention"
  echo "## 316.4 fourth";  echo "B7 §7.1 — fourth mention"; } > "$d"
out="$(run "$d")"
if grep -qE 'unrecog=0' <<<"$out" && ! grep -qiE 'WARN.*unrecog' <<<"$out"; then
  ok "NR-C dedup: same remission ×4 → unrecog=0 (no false WARN)"
else no "NR-C dedup: crying wolf on duplicate :: $(grep -E 'unrecog|WARN' <<<"$out" | head -2)"; fi

# 57 — NR-C range-both: §N.x-§N.y where BOTH components parsed → unrecog=0.
printf '# Block 8\n\n## 8.2 alpha\nContent.\n\n## 8.3 beta\nContent.\n' > "$TMP/block8.md"
d="$TMP/nrc-range-both.md"
{ echo "# Block 316 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 316.1"; echo "B8 §8.2 — standalone alpha"
  echo "## 316.2"; echo "B8 §8.3 — standalone beta"
  echo "## 316.3"; echo "B8 §8.2-§8.3 — compound range (both already parsed)"; } > "$d"
out="$(run "$d")"
if grep -qE 'unrecog=0' <<<"$out" && ! grep -qiE 'WARN.*unrecog' <<<"$out"; then
  ok "NR-C range-both: §N.x-§N.y with both components parsed → unrecog=0"
else no "NR-C range-both: range with both parsed still flagged :: $(grep -E 'unrecog|WARN' <<<"$out" | head -2)"; fi

# 58 — NR-C range-one: §N.x-§N.y where only §N.x parsed → unrecog≥1, WARN, verbatim printed, exit 0.
# block8.md already has §8.2; create a fresh one without §8.3.
printf '# Block 8\n\n## 8.2 alpha\nContent.\n' > "$TMP/block8.md"
d="$TMP/nrc-range-one.md"
{ echo "# Block 316 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 316.1"; echo "B8 §8.2-§8.3 — range; only §8.2 parsed, §8.3 not independently verified"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'WARN.*unrecog' <<<"$out" && grep -qF 'B8 §8.2-§8.3' <<<"$out"; then
  ok "NR-C range-one: range with unresolved endpoint → WARN, verbatim printed, exit 0"
else no "NR-C range-one: rc=[$rc] :: $(grep -E 'unrecog|WARN|B8' <<<"$out" | head -2)"; fi

# 59 — NR-C unknown: genuinely unknown form [[bloque27]] §277 (no dotted section) →
#       unrecog=1, WARN, verbatim printed verbatim in output, exit 0.
d="$TMP/nrc-unknown.md"
{ echo "# Block 400 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 400.1"; echo "[[bloque27]] §277 — kidcad form (form 5, no dotted section)"; } > "$d"
out="$(run "$d")"; rrc "$d"; rc=$?
if [ "$rc" = "0" ] && grep -qiE 'WARN.*unrecog' <<<"$out" && grep -qF '[[bloque27]] §277' <<<"$out"; then
  ok "NR-C unknown: [[bloque27]] §277 → unrecog=1, WARN, verbatim printed, exit 0"
else no "NR-C unknown: rc=[$rc] :: $(grep -iE 'WARN|unrecog|bloque27' <<<"$out" | head -2)"; fi

# 60 — NR-C long-gap: broad detector's gap limit blocks long-gap false positives.
# [Block N]** — prose longer than 20 chars §M.x must NOT be treated as a cross-block remission
# (the §M.x is a self-reference to the current block, not block N's section).
d="$TMP/nrc-longgap.md"
{ echo "# Block 502 — SYNTHESIS"; echo
  echo "> this is a SYNTHESIS block."; echo
  echo "---"; echo
  echo "## 502.1 audit"
  echo "[Block 10]** — this prose is definitely longer than twenty chars §502.2"; } > "$d"
out="$(run "$d")"
# After the gap fix the long-gap form is not captured at all: either "unrecog=0" appears
# in the summary line, or the block has no parseable forms so "NO remission-shaped text" fires
# instead. In either case WARN must be absent.
if ! grep -qiE 'WARN.*unrecog' <<<"$out" && \
    (grep -qE 'unrecog=0' <<<"$out" || grep -qiE 'NO remission-shaped' <<<"$out"); then
  ok "NR-C long-gap: [Block N]** long prose §M.x (gap>20) → not captured, no false WARN"
else no "NR-C long-gap: false positive from long gap :: $(grep -iE 'WARN|unrecog|remission' <<<"$out" | head -2)"; fi

# ---- Mutation control for NR-C correction (--prove-teeth) ----
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth-NRC: neuter SYN-PAIR-CHECK; duplicate (×4) must revert to WARN --"
  mutant_nrc="$TMP/vb.NRCMUT.sh"
  if grep -q '# SYN-PAIR-CHECK' "$SUT"; then
    sed '/# SYN-PAIR-CHECK/ s/.*/:  # SYN-PAIR-CHECK [NEUTERED]/' "$SUT" > "$mutant_nrc"
    bash -n "$mutant_nrc" 2>/dev/null; _nrc_syn=$?
    if [ "$_nrc_syn" != "0" ]; then
      no "teeth-NRC: mutant syntax error (rc=$_nrc_syn) — cannot run"
    else
      printf '# Block 7\n\n## 7.1 heading\nContent.\n' > "$TMP/block7.md"
      d_nrc="$TMP/nrc-dedup-mut.md"
      { echo "# Block 316 — SYNTHESIS"; echo
        echo "> this is a SYNTHESIS block."; echo
        echo "---"; echo
        echo "## 316.1 first";  echo "B7 §7.1 — first mention"
        echo "## 316.2 second"; echo "B7 §7.1 — second mention"
        echo "## 316.3 third";  echo "B7 §7.1 — third mention"
        echo "## 316.4 fourth"; echo "B7 §7.1 — fourth mention"; } > "$d_nrc"
      mout_nrc="$(bash "$mutant_nrc" "$d_nrc" 2>/dev/null)"
      if grep -qiE 'WARN.*unrecog' <<<"$mout_nrc"; then
        ok "teeth-NRC: neutered pair-check → WARN fires on ×4 duplicate (test 56 has teeth)"
      else
        no "teeth-NRC: WARN did not fire with pair-check neutered :: $(grep -iE 'WARN|unrecog' <<<"$mout_nrc" | head -1)"
      fi
    fi
  else
    no "teeth-NRC: SYN-PAIR-CHECK sentinel not found in SUT"
  fi

  echo "-- teeth-NRC-GAP: neuter SYN-GAP-LIMIT; long-gap form must revert to WARN --"
  mutant_nrcgap="$TMP/vb.NRCGAPMUT.sh"
  if grep -q '# SYN-GAP-LIMIT' "$SUT"; then
    sed '/# SYN-GAP-LIMIT/ s/{0,20}/*/' "$SUT" > "$mutant_nrcgap"
    bash -n "$mutant_nrcgap" 2>/dev/null; _ngap_syn=$?
    if [ "$_ngap_syn" != "0" ]; then
      no "teeth-NRC-GAP: mutant syntax error (rc=$_ngap_syn) — cannot run"
    else
      d_ngap="$TMP/nrc-longgap-mut.md"
      { echo "# Block 502 — SYNTHESIS"; echo
        echo "> this is a SYNTHESIS block."; echo
        echo "---"; echo
        echo "## 502.1 audit"
        echo "[Block 10]** — this prose is definitely longer than twenty chars §502.2"; } > "$d_ngap"
      mout_ngap="$(bash "$mutant_nrcgap" "$d_ngap" 2>/dev/null)"
      if grep -qiE 'WARN.*unrecog' <<<"$mout_ngap"; then
        ok "teeth-NRC-GAP: neutered gap limit → WARN fires on long-gap form (test 60 has teeth)"
      else
        no "teeth-NRC-GAP: WARN did not fire with gap limit neutered :: $(grep -iE 'WARN|unrecog' <<<"$mout_ngap" | head -1)"
      fi
    fi
  else
    no "teeth-NRC-GAP: SYN-GAP-LIMIT sentinel not found in SUT"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
