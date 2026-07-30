#!/usr/bin/env bash
# verify-block.sh — mechanical self-verify aid for a Research-SDD block (METHODOLOGY §11).
#
# The SUB-AGENT runs this INSIDE its own iteration and pastes the output into its §11 self-report.
# It does the MECHANICAL parts of the gate — marker tally, [INFER]/[CERT] ratio, and [CERT] `file:line`
# citation-resolution — so the counts are EXACT (computed, not remembered). This is NOT an orchestrator
# post-hoc Bash gate (§11 rejects those — they cost permission prompts and caught nothing on protocols);
# it is the agent's own calculator, run by the agent, reported by the agent.
#
# It does not judge block TYPE or escalate markers — those need reading. It hardens the COUNTING, which is
# where a from-memory self-report drifts. The token-check (does each [CERT] token appear in its source) still
# needs the agent; this resolves the CITATION (does the cited file:line exist) mechanically.
#
# Usage: verify-block.sh <block.md> [target-dir]
#   target-dir defaults to the block's own directory (file:line citations are target-relative).
# Exit: 0 = no verifiable contradiction · 1 = a cited line is out of range, OR a cited block-evidence artifact
#       (B<N>-* / bloque<N>-*) is not preserved in the target · 2 = bad args.

set -uo pipefail
block="${1:-}"
[ -f "$block" ] || { echo "usage: verify-block.sh <block.md> [target-dir]" >&2; exit 2; }
target="${2:-$(dirname "$block")}"

echo "== verify-block: $(basename "$block") (target: $target) =="

# 1. Marker tally — RAW (whole block) and ADJUSTED (claims only). `grep -oE '\[CERT\]'` does NOT match the
#    hyphenated variants, so each counts once. The leading header BLOCKQUOTE (everything up to the FIRST
#    `---` fence) is a LEGEND that DEFINES each marker — those tokens are not fresh claims and INFLATE the
#    tally (+1 per marker type). ADJUSTED strips that region POSITIONALLY (not by backticks: real blocks
#    backtick their CLAIM markers too, so a backtick-strip would wrongly zero them). Note: in-body §14
#    meta-references (a marker QUOTED from another block for a correction) still need the AGENT's judgment —
#    this strip only removes the header legend, which is the reliable, mechanical part.
# The legend lives in the leading BLOCKQUOTE, whose closing fence is a bare `---` that sits AFTER the
# `>` blockquote AND BEFORE the first `## ` body section. Bounding the fence to that header window makes it
# robust in both directions: an EARLIER bare `---` (YAML front matter / setext-H2 underline) precedes the
# blockquote so `q` is still 0 and it is ignored; a LATER bare `---` (a body section separator, e.g. right
# after a §14 quoted correction whose `>` would otherwise set `q`) is past the first `## ` so the scan has
# already exited. If no `---` closes the header before the body starts, the legend is "unfenced" → fall
# back to adjusted = raw (safe: never silently strip real body claims).
fence_line=$(awk '/^##[[:space:]]/{exit} q && /^---[[:space:]]*$/{print NR; exit} /^[[:space:]]*>/{q=1}' "$block")
if [ -n "$fence_line" ]; then
  body="$(awk -v n="$fence_line" 'NR>n' "$block")"             # claims live after the legend's closing fence
else
  body="$(cat "$block")"                                        # no leading-blockquote fence → can't isolate the legend
fi
declare -A raw adj
for m in CERT-hw CERT-live CERT CERT-doc CERT-web CERT-a INFER; do
  raw[$m]=$(grep -oE "\[$m\]" "$block" | wc -l | tr -d ' ')
  adj[$m]=$(printf '%s' "$body" | grep -oE "\[$m\]" | wc -l | tr -d ' ')
done
echo "-- marker tally (raw = whole block · adj = claims, header legend stripped) --"
for m in CERT-hw CERT-live CERT CERT-doc CERT-web CERT-a INFER; do
  if [ "${raw[$m]}" != "${adj[$m]}" ]; then
    printf "   [%s] %s  (adj %s)\n" "$m" "${raw[$m]}" "${adj[$m]}"
  else
    printf "   [%s] %s\n" "$m" "${raw[$m]}"
  fi
done
[ -z "$fence_line" ] && echo "   (no leading-blockquote '---' fence — adjusted = raw; the legend could not be isolated)"

# 2. [INFER]/[CERT] ratio — INFER over ALL cert-family markers, on ADJUSTED counts (the legend's one-of-each
#    otherwise skews a low-count block).
cert_total=$(( adj[CERT-hw] + adj[CERT-live] + adj[CERT] + adj[CERT-doc] + adj[CERT-web] + adj[CERT-a] ))
infer=${adj[INFER]}
if [ "$cert_total" -gt 0 ]; then
  ratio=$(awk "BEGIN{printf \"%.2f\", $infer/$cert_total}")
else
  ratio="n/a (no CERT markers)"
fi
echo "-- ratio -- [INFER]/[CERT*] = $infer/$cert_total = $ratio"
echo "   (>~0.5 in an EVIDENCE block signals investigable evidence nearly exhausted; EXPECTED and healthy in a"
echo "    DESIGN/synthesis block — DECLARE the block TYPE so the ratio is read right, §11)"

# 3. Citation resolution — `file:line` tokens (target-relative).
# Two passes with DIFFERENT teeth:
#   (a) BLOCK-EVIDENCE-ARTIFACT cites — dumps named `B<N>-*` / `bloque<N>-*` a [CERT] seals to BY ARTIFACT NAME,
#       cited inside a parenthetical `(...)` or backticks, single line OR a RANGE (`start-end`; the real corpus
#       uses a U+2011 non-breaking hyphen, also accept ASCII `-` and U+2013 en-dash). Convention (§11): such
#       evidence MUST be preserved in the corpus, so an unresolvable artifact cite is a FAIL, not `extern` —
#       bloque125 sealed load-bearing [CERT]s to `B125-*.txt` dumps that were never preserved and the old parser
#       (which only saw backticked single-line cites) let them pass clean.
#   (b) GENERIC backticked single-line cites — unchanged ok / RANGE! / extern; a non-artifact bare cite
#       (foreign binary, offset) is still NOT a citation the script resolves, so prose stays false-positive free.
echo "-- [CERT] file:line citation resolution --"
rc=0
# The EXTENSION IS OPTIONAL: ~45% of the real corpus omits it (bloque128 declares `cited as B128-triage:LINE`),
# so the filename run carries `.ext` when present and stops at `:` when not — matching BOTH
# `B124-native-triage.txt:135` and `B128-triage:103`. The run MUST contain AT LEAST ONE LETTER
# (`[a-z0-9_.-]*[a-z][a-z0-9_.-]*`): every real dump has letters (`triage`, `ghidra-njre`), whereas an
# all-DIGIT remainder is ordinary numeric prose (`B12-3:44` section, `B5-10:20` range) — not an artifact cite.
art_name='(b[0-9]+|bloque[0-9]+)-[a-z0-9_.-]*[a-z][a-z0-9_.-]*'          # artifact filename shape (case-insens.)
art_tail=':[0-9]+((-|‑|–)[0-9]+)?'                                       # :line or :start-end (real dash = U+2011)
# An artifact cite only counts when it sits in a CITATION-SHAPED span: inside a parenthetical `(...)` OR inside
# backticks. The real corpus (bloque124/129) puts TEXT between the `(` and the token — `(cf. … B124-x.txt:…)`,
# `(KERNEL32; B124-x.txt:…)` — so the token may sit anywhere inside the span, not only right after `(`. Within
# a span the token must start at a WORD BOUNDARY (`\b`), which keeps it OFF mid-word look-alikes whether bare
# (`verbB12-record.txt`) or parenthesised (`(verbB12-record.txt:44)`), and prose OUTSIDE any span never fires.
# Known limitation (not in corpus today): `\([^)]*\)` does not span a NESTED paren, so a cite in
# `(outer (inner) B124-x.txt:5)` is dropped — documented here so it is a known blind spot, not a silent one.
art_spans=$(grep -oE '\([^)]*\)|`[^`]*`' "$block")                       # parenthetical + backtick spans, one per line
art_cites=$(printf '%s\n' "$art_spans" | grep -oiE "\\b${art_name}${art_tail}" | sort -u)
bt_cites=$(grep -oE '`[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?`' "$block" | tr -d '`' | sort -u)  # P7-BT-RANGE-EXTRACT
# (c) Short-form :NNN citations — a bare colon + line number where the file is named in
# surrounding prose or a table header. Two corpus-confirmed patterns:
#   table rows  (pi5-decoding-block1: | :29 |)         — :NNN preceded by [|,[:space:]]
#   code-block comments (pi5-decoding-block2: // :157) — :NNN after a // or # marker
# Not file-verifiable (no filename present) but VISIBLE so the P6 WARN does not fire on
# a well-cited block. Scope restricted to these two contexts: IP ports like 127.0.0.1:46272
# have a digit before the colon and fall outside [[:space:]|,] → no match.
_tbl_shorts=$(grep -E '^\s*\|' "$block" | grep -oE '[[:space:]|,]:[0-9]+' | grep -oE ':[0-9]+')  # P6-SHORT-FORM-CITE-TABLE
_cmt_shorts=$(grep -oE '(//|#)[[:space:]]*:[0-9]+(,[[:space:]]*:[0-9]+)*' "$block" | grep -oE ':[0-9]+')  # P6-SHORT-FORM-CITE-COMMENT  # P7-CMT-SECONDARY
short_cites=$(printf '%s\n%s\n' "${_tbl_shorts:-}" "${_cmt_shorts:-}" | sort -u | grep -v '^$')
# (d) PROBE FILE citations — `sources/probes/<path>` appearing in the block body (parenthetical or
#     backtick-wrapped, NO line number required). §3's canonical `[CERT-hw]`/`[CERT-live]` citation
#     format cites probe output files without a line number (e.g. `[CERT-hw]` (`sources/probes/<dir>/<file>.txt`)).
#     A cited-and-existing sources/probes/ file satisfies the citation gate; the P6 WARN is suppressed
#     when at least one such path resolves on disk (retro 2026-07-29 #6 / §3 alignment).
probe_cites=$(grep -oE 'sources/probes/[A-Za-z0-9_./-]+' "$block" | sort -u)
probe_found=""
if [ -n "$probe_cites" ]; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if [ -f "$target/$p" ]; then
      echo "   probe   $p"
      probe_found=1  # P6-PROBE-FILE-CITE
    else
      echo "   extern  $p  (probe path not in target — not script-verifiable)"
    fi
  done <<< "$probe_cites"
fi
if [ -z "$art_cites" ] && [ -z "$bt_cites" ] && [ -z "$short_cites" ] && [ -z "$probe_found" ]; then
  # P6: [CERT] body markers present but no file:line citations resolved → the citation gate
  # exits 0 silently having checked nothing. Warn so the author notices the gap.
  if [ "$cert_total" -gt 0 ]; then  # P6-CERT-ZERO-CITE-WARN
    echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Add file:line citations or re-check the citation format."
  else
    echo "   (no file:line citations found)"
  fi
fi
# (a) artifact cites — strict: MISSING (unpreserved evidence) and out-of-range both FAIL.
if [ -n "$art_cites" ]; then
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    n=$(printf '%s' "$c" | sed 's/‑/-/g; s/–/-/g')                       # normalise range dash to ASCII
    f="${n%:*}"; rng="${n##*:}"
    case "$rng" in
      *-*) start="${rng%-*}"; end="${rng##*-}";;                         # a range: bounds-check BOTH ends
      *)   start="$rng"; end="$rng";;                                    # single line
    esac
    # D6: the art_name regex extracts the bare filename; if the cite carries a PATH prefix
    # (sources/probes/B10-x.txt:146) search the block text for the full cited path.
    if [ ! -f "$target/$f" ]; then
      _esc_f="$(printf '%s' "$f" | sed 's/\./\\./g')"
      _full_path="$(grep -oiE "[a-zA-Z0-9_./-]+/${_esc_f}" "$block" 2>/dev/null | head -1)"
      [ -n "$_full_path" ] && [ -f "$target/$_full_path" ] && f="$_full_path"  # D6-PATH-FALLBACK
    fi
    if [ ! -f "$target/$f" ]; then
      echo "   MISSING! $c  (evidence artifact not preserved)"; rc=1
    else
      total=$(wc -l < "$target/$f")
      # FAIL if either endpoint is past EOF or the range is reversed (start > end).
      if [ "$start" -le "$total" ] && [ "$end" -le "$total" ] && [ "$start" -le "$end" ]; then
        echo "   ok      $c"
      else
        echo "   RANGE!  $c  (file has $total lines) — cited line out of range"; rc=1
      fi
    fi
  done <<< "$art_cites"
fi
# (b) generic backticked cites — skip any whose filename is an artifact (already handled strictly above).
# A range `file.ext:NNN-MMM` asserts lines NNN through MMM exist: valid when NNN>=1, NNN<=MMM, MMM<=lines.
# Degenerate :0-MMM (zero start) and :NNN-MMM reversed (start>end) are block defects → RANGE! + exit 1.
# Degenerate :NNN-NNN (equal endpoints) is a single-line range and resolves as ok when in bounds.
if [ -n "$bt_cites" ]; then
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    f="${c%:*}"; rng="${c##*:}"
    case "$rng" in
      *-*) start="${rng%-*}"; end="${rng##*-}";;   # range form NNN-MMM
      *)   start="$rng"; end="$rng";;               # single line
    esac
    printf '%s' "$f" | grep -qiE "^${art_name}$" && continue
    if [ "$start" -eq 0 ]; then
      echo "   RANGE!  $c  (start 0 is invalid — lines are 1-indexed)"; rc=1; continue
    fi
    if [ "$start" -gt "$end" ]; then
      echo "   RANGE!  $c  (reversed range: start $start > end $end — defect in block)"; rc=1; continue
    fi
    if [ -f "$target/$f" ]; then
      total=$(wc -l < "$target/$f")
      if [ "$end" -le "$total" ]; then
        if [ "$start" = "$end" ]; then
          echo "   ok      $c"
        else
          echo "   ok      $c  (range end verified; file has $total lines)"
        fi
      else
        echo "   RANGE!  $c  (file has $total lines) — cited line out of range"; rc=1
      fi
    else
      echo "   extern  $c  (not in target: beautified-temp / decompiled / snapshot — not script-verifiable)"
    fi
  done <<< "$bt_cites"
fi
# (c) Short-form cites — advisory only; not script-verifiable (no filename to resolve).
if [ -n "$short_cites" ]; then
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    echo "   short   $c  (short form — file implied by context; not script-verifiable)"
  done <<< "$short_cites"
fi

# 4. OCR-provenance flag — a [CERT-doc] citation sourced from an OCR'd (scanned) PDF is LOSSY
#    (extract-pdf.sh tier 2). Cross-reference sources/extracted/*.md front-matter tagged
#    `reliability: ocr-lossy` and flag any block citation tracing to those sources for EXTRA §11
#    scrutiny — OCR errors in numbers/serials/exact quotes do NOT surface as a bad file:line, so
#    they must be re-checked against the page image before the claim is trusted. Advisory (no rc change).
echo "-- OCR-provenance flag (reliability: ocr-lossy) --"
ext_dir="$target/sources/extracted"
lossy_hits=0
if [ -d "$ext_dir" ]; then
  while IFS= read -r ext; do
    [ -f "$ext" ] || continue
    # Match the tag whether it is a YAML field (extract-pdf.sh output) or prose (hand-made mirrors).
    grep -qiE 'reliability:[[:space:]]*ocr-lossy|extracted via OCR' "$ext" || continue
    ext_stem=$(basename "$ext" .md)
    loose=$(printf '%s' "$ext_stem" | cut -d- -f1-2)          # e.g. tufte-vdqi-... -> tufte-vdqi
    src=$(awk -F': ' '/source_pdf:/{print $2; exit}' "$ext")
    pdf_base=""; [ -n "$src" ] && { pdf_base=$(basename "$src"); pdf_base="${pdf_base%.*}"; }
    # A block may cite the PDF, the extracted/ file, OR a web-snapshots/ mirror of the same OCR —
    # so match on the pdf stem, the extract stem, AND the loose key (grep -F: literal, brackets-safe).
    hits=""
    for tok in "$pdf_base" "$ext_stem" "$loose"; do
      [ -n "$tok" ] || continue
      h=$(grep -nF "$tok" "$block" 2>/dev/null || true)
      [ -n "$h" ] && hits="${hits}${h}"$'\n'
    done
    hits=$(printf '%s' "$hits" | grep -vE '^[[:space:]]*$' | sort -t: -k1n -u || true)
    if [ -n "$hits" ]; then
      echo "   OCR!    lines citing OCR-lossy '$ext_stem' — re-verify numbers/quotes/serials vs page image:"
      printf '%s\n' "$hits" | sed 's/^/           /'
      lossy_hits=$((lossy_hits+1))
    fi
  done < <(find "$ext_dir" -maxdepth 1 -name '*.md' 2>/dev/null)
fi
[ "$lossy_hits" -eq 0 ] && echo "   (none — no citation traces to an OCR-lossy extract)"

echo "== exit $rc =="
exit $rc
