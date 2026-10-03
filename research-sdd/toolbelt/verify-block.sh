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
#        verify-block.sh --possibility-sweep <corpus-dir>   (list existing bare feasibility verdicts; read-only)
#   target-dir defaults to the block's own directory (file:line citations are target-relative).
#       The POSSIBILITY-FIRST lint (§1 trait, #1265) is ADVISORY (WARN, exit unchanged — like P6/P9: it is a
#       prose-heuristic, so a hard FAIL would train operators to ignore the gate; the sweep surfaces, never edits).
# Exit: 0 = no verifiable contradiction · 1 = a cited line is out of range, OR a cited block-evidence artifact
#       (B<N>-* / bloque<N>-*) is not preserved in the target, OR a cited hash equals the digest of EMPTY
#       input (EMPTYHASH!, #1487; waive a quoted digest per line with `<!-- empty-digest: quoted -->`) · 2 = bad args.

set -uo pipefail
# --- POSSIBILITY-FIRST lint (METHODOLOGY §1 trait · kit issues #1263-#1266) ---------------------------------
# pf_scan <file>: print `LINE<TAB>PHRASE<TAB>TEXT` for each BARE defeatist feasibility verdict. A verdict is bare
# unless its SECTION (text up to the next markdown heading) carries a ROUTE LADDER: >=3 list items / table rows
# labelled `route` AND a `cheapest` next step. Fenced code is skipped; the legal measured-negative form
# `not with <route>, measured` and §11a measurement language ("physically impossible value") never fire.
pf_scan() {
  awk '
    function flush(   i) {
      if (n > 0 && !(routes >= 3 && cheapest)) {  # PF-LADDER-ACCEPT
        for (i = 1; i <= n; i++) print hl[i] "\t" hp[i] "\t" ht[i]
      }
      n = 0; routes = 0; cheapest = 0
    }
    /^```/ { fence = !fence; next }
    fence { next }
    /^#+[[:space:]]/ { flush(); next }
    {
      raw = $0; l = tolower($0)
      if (l ~ /^[[:space:]]*([-*+]|[0-9]+[.)]|\|)/ && l ~ /route/) routes++
      if (l ~ /cheapest/) cheapest = 1
      if (l ~ /not with .*measured/) next
      gsub(/physically impossible|impossible (value|reading|record|timestamp|state|combination|result)s?/, "", l)  # PF-MEASURE-EXCLUDE
      if (match(l, /not possible|no es posible|impossible|imposible|no way to|out of reach|not determinable|no se puede|cannot be (determined|done|achieved|measured|known|verified|reached|obtained|read|extracted|recovered|resolved|derived|reproduced|built|decided|established|confirmed)/)) {
        n++; hl[n] = NR; hp[n] = substr(l, RSTART, RLENGTH); ht[n] = raw
      }
    }
    END { flush() }
  ' "$1"
}

if [ "${1:-}" = "--possibility-sweep" ]; then
  sweep_dir="${2:-}"
  [ -d "$sweep_dir" ] || { echo "usage: verify-block.sh --possibility-sweep <corpus-dir>" >&2; exit 2; }
  total=0
  while IFS= read -r f; do
    while IFS=$'\t' read -r ln ph tx; do
      [ -z "$ln" ] && continue
      printf '%s:%s: %s — %s\n' "$f" "$ln" "$ph" "$(printf '%s' "$tx" | cut -c1-120)"
      total=$((total+1))
    done < <(pf_scan "$f")
  done < <(find "$sweep_dir" -type f -name '*.md' | sort)
  echo "== possibility-sweep: bare verdicts: $total =="
  [ "$total" -gt 0 ] && echo "   Reopen each as a child gap (B<n>-G<m>) with the cheapest route as NEXT, §14 back-pointer on the corrected block (METHODOLOGY §1 possibility-first self-correction). Read-only: nothing was edited."
  exit 0
fi

block="${1:-}"
[ -f "$block" ] || { echo "usage: verify-block.sh <block.md> [target-dir]" >&2; exit 2; }
target="${2:-$(dirname "$block")}"
# Nested-corpus fallback: for a block inside a corpus sub-directory, own-project source lives above
# the corpus dir and does not resolve under $target. Find the git root once (bounded — one git call,
# no filesystem walk) so the bt_cite loop can try it as a secondary location before declaring extern.
git_root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || git_root=""  # N-PROJECT-FALLBACK-INIT

# TARGET-ROOT fallback (#1325, METHODOLOGY §15): an in-project corpus lives at $TARGET/corpus/, and when that
# corpus is its own git repo `git rev-parse` returns the CORPUS root — own-project source one level up never
# resolves. Derive the TARGET root PURELY from the path string (no filesystem walk): the parent of the
# nearest ancestor-or-self directory literally named `corpus`. A layout without a `corpus` component gets
# no walk-up (the cite stays extern) — least surprising, never guesses an arbitrary parent.
# The candidate is then BOUNDED (§7: an unbounded root turns `config.sh:1` under a fake $HOME into a
# false `ok`): it is REFUSED when it is `/`, $HOME, or any ancestor of $HOME, and ACCEPTED only when it
# looks like a project root — a directory holding one of these markers (`.git`, dir or worktree file, is
# what identifies a git work-tree top):
#   package.json pyproject.toml pom.xml build.gradle go.mod Cargo.toml Makefile .git
# Only the NEAREST `corpus` ancestor is considered (no fall-through to a farther one).
target_root=""  # TARGET-ROOT-FALLBACK-INIT
_tr_c=""
_tr_d="$(cd "$target" 2>/dev/null && pwd -P)" || _tr_d=""
while [ -n "$_tr_d" ] && [ "$_tr_d" != "/" ]; do
  if [ "$(basename "$_tr_d")" = "corpus" ]; then _tr_c="$(dirname "$_tr_d")"; break; fi
  _tr_d="$(dirname "$_tr_d")"
done
if [ -n "$_tr_c" ] && [ "$_tr_c" != "/" ]; then
  _tr_home="$(cd "${HOME:-/}" 2>/dev/null && pwd -P)" || _tr_home=""
  case "$_tr_home/" in "$_tr_c"/*) _tr_c="" ;; esac  # TARGET-ROOT-HOME-GUARD
fi
if [ -n "$_tr_c" ] && [ "$_tr_c" != "/" ]; then
  for _tr_m in package.json pyproject.toml pom.xml build.gradle go.mod Cargo.toml Makefile .git; do  # TARGET-ROOT-MARKERS
    if [ -e "$_tr_c/$_tr_m" ]; then target_root="$_tr_c"; break; fi
  done
fi

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
# code_cert_total: markers that ARE expected to back file:line citations ([CERT-hw]/[CERT-live]/[CERT]).
# doc-grade markers ([CERT-doc]/[CERT-web]/[CERT-a]) cite external preserved docs/PDFs and NEVER
# produce target file:line cites — they are validated by verify-sources.sh + §5 token-check instead.
code_cert_total=$(( adj[CERT-hw] + adj[CERT-live] + adj[CERT] ))
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
_pf_ok=0; _pf_m=0  # P6-PROBE-REPORT: probe-file cites resolved vs. cited (#1325)
if [ -n "$probe_cites" ]; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    _pf_m=$((_pf_m+1))
    if [ -f "$target/$p" ]; then
      _pf_ok=$((_pf_ok+1))
      echo "   probe   $p"
      probe_found=1  # P6-PROBE-FILE-CITE
    else
      echo "   extern  $p  (probe path not in target — not script-verifiable)"
    fi
  done <<< "$probe_cites"
  echo "   probe-file cites resolved $_pf_ok of $_pf_m"  # P6-PROBE-REPORT
fi
# (e) JAR!ENTRY citations — e.g. control-rt.jar!META-INF/module.xml — recognized non-resolvable:
#     a Java archive entry path is not a local file:line. Print for visibility; P6 WARN is
#     suppressed when these are the ONLY citations present (like `extern` for backtick cites) —
#     the gate is not blind; it recognized the form. Issues #771/#774/#780.
jar_cites=$(grep -oE '[A-Za-z0-9_.-]+\.jar![A-Za-z0-9_./-]+' "$block" | sort -u)
jar_found=""
if [ -n "$jar_cites" ]; then
  while IFS= read -r jc; do
    [ -z "$jc" ] && continue
    echo "   jar-entry  $jc  (jar archive path — not file-verifiable)"  # VB1-JAR-ENTRY-CITE
  done <<< "$jar_cites"
  jar_found=1
fi
# (f) [BNNN] synthesis back-references — e.g. [B7], [B12] — recognized non-resolvable:
#     an intra-corpus back-reference token is not a local file:line. Print for visibility; P6 WARN
#     is suppressed when these are the ONLY citations present — the gate recognized the form.
#     Issues #771/#774/#780.
synth_refs=$(grep -oE '\[B[0-9]+\]' "$block" | sort -u)
synth_found=""
if [ -n "$synth_refs" ]; then
  while IFS= read -r sr; do
    [ -z "$sr" ] && continue
    echo "   synth-ref  $sr  (block back-reference — not file-verifiable)"  # VB1-SYNTH-REF
  done <<< "$synth_refs"
  synth_found=1
fi
# P9-TYPE-PARSE-EARLY: parse Type: token once, shared by P6 (zero-citation WARN) and P9 (resolved-N-of-M WARN).
# Grammar (closed, §4): standard|evidence|synthesis|mixed|absence-centred|capture|document|collaborative|audit|decision
# Strip is ORDER-INDEPENDENT: leading spaces, asterisks, backticks removed in any combination — see P6-TYPE-STRIP.
_type_raw=$(grep -iE '^\s*>\s*(\*\*)?\s*[Tt]ype:' "$block" | head -1)
_type_token=""
_type_stripped=""
if [ -n "$_type_raw" ]; then
  _type_no_bq=$(printf '%s' "$_type_raw" | sed 's/^[[:space:]]*>[[:space:]]*//')  # P6-BQ-STRIP
  _type_after=$(printf '%s' "$_type_no_bq" | sed 's/.*[Tt][Yy][Pp][Ee]://')  # P6-BQ-TYPECASE
  _type_stripped=$(printf '%s' "$_type_after" | sed 's/^[[:space:]*`]*//')  # P6-TYPE-STRIP
  _type_token=$(printf '%s' "$_type_stripped" | grep -oE '^[a-z][a-z0-9-]*')  # P1418-TYPE-DIGITS
fi
if [ -z "$art_cites" ] && [ -z "$bt_cites" ] && [ -z "$short_cites" ] && [ -z "$probe_found" ]; then
  # P6-NONRESOLVABLE-SUPPRESS: when the only citations present are recognized non-resolvable forms
  # (jar archive entries and/or [BNNN] block back-references), the gate is not blind — it identified
  # the forms. Emit an informational note instead of the WARN; the visibility lines above already
  # show what was found. This suppresses the spurious WARN reported in issues #771/#774/#780.
  if [ -n "$jar_found" ] || [ -n "$synth_found" ]; then  # P6-NONRESOLVABLE-GUARD
    [ "$cert_total" -gt 0 ] && echo "   (only non-file-verifiable citations recognized: ${jar_found:+archive-entry paths }${synth_found:+[BNNN] back-references }— see entries above; token-verify inline against cited artifacts)"  # P6-NONRESOLVABLE-SUPPRESS
  else
  # P6: [CERT] body markers present but no file:line citations resolved → the citation gate
  # exits 0 silently having checked nothing. Warn so the author notices the gap.
  # P6-DOC-AWARE: when ALL cert markers are doc-grade ([CERT-doc]/[CERT-web]/[CERT-a]), file:line
  # citations are not expected — those markers cite external preserved docs validated by
  # verify-sources.sh + §5 token-check. Emitting a WARN on every doc-corpus block is a false
  # positive that trains the operator to ignore the gate (retros 2026-08-12 #1, 2026-08-18 #1).
  # Emit an informational note instead so the gate still reports rather than silently passing.
  if [ "$cert_total" -gt 0 ]; then  # P6-CERT-ZERO-CITE-WARN
    if [ "$code_cert_total" -eq 0 ]; then  # P6-DOC-AWARE-SUPPRESS
      echo "   (doc-grade citations only ([CERT-doc]/[CERT-web]/[CERT-a]) — file:line not expected; validate tokens via verify-sources.sh + §5 token-check)"
    else
      # Type: already parsed above (P9-TYPE-PARSE-EARLY); _type_raw/_type_token/_type_stripped are set.
      # Classify: INFO for no-citation declared types; WARN-by-name for unrecognised; WARN+hint for absent Type line.
      # case replaces printf|grep-qxF to avoid pipefail/SIGPIPE exit 141 on early match — same family as e727cde.
      case "$_type_token" in
        synthesis|capture|document|absence-centred|decision)  # P6-TYPE-CLASSIFY
          echo "   INFO    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — expected for declared type $_type_token."
          ;;
        standard|evidence|mixed|collaborative|audit)
          echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Expected for synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks (check your block-type declaration); otherwise add file:line citations or re-check the citation format."
          ;;
        *)
          if [ -n "$_type_raw" ]; then  # P6-TYPE-UNRECOGNISED
            # Name the real value when token is empty (uppercase/non-conformant); strip closing ** and trailing punctuation.
            _type_warn_name="${_type_token:-$(printf '%s' "$_type_stripped" | sed 's/[[:space:]]*\*.*//; s/[[:space:]]*\.[[:space:]]*$//; s/[[:space:]]*$//')}"  # P6-TYPE-DISPLAY
            echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — unrecognised Type: token '$_type_warn_name'; accepted: standard | evidence | synthesis | mixed | absence-centred | capture | document | collaborative | audit | decision."
          else
            echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Expected for synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks (check your block-type declaration); otherwise add file:line citations or re-check the citation format."
            echo "   HINT    Declare a Type: token in the header blockquote to grade this WARN: standard | evidence | synthesis | mixed | absence-centred | capture | document | collaborative | audit | decision."
          fi
          ;;
      esac
    fi
  else
    echo "   (no file:line citations found)"
  fi
  fi  # close jar_found/synth_found branch
fi
if [ -n "$probe_found" ] && [ -z "$art_cites" ] && [ -z "$bt_cites" ] && [ -z "$short_cites" ] && [ "$code_cert_total" -gt "$_pf_ok" ]; then  # P6-PROBE-COVERAGE
  # #1325: probe-file cites satisfy the gate (no WARN) but must not read as full coverage — name the gap.
  echo "   INFO    $code_cert_total [CERT] code marker(s) but only $_pf_ok resolved probe-file cite(s) — a probe cite verifies its file, not each marker; token-verify the rest inline."
fi
_vb_ok=0; _vb_m=0  # P9-RESOLVED-SUMMARY: ok resolutions vs. total attempted (bt + art cites)
# (a) artifact cites — strict: MISSING (unpreserved evidence) and out-of-range both FAIL.
if [ -n "$art_cites" ]; then
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    _vb_m=$((_vb_m+1))  # P9-VB-M-ART
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
        echo "   ok      $c"; _vb_ok=$((_vb_ok+1))  # P9-VB-OK-ART
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
    # fixed under #1444: here-string, no printf | grep -q pipe, so no SIGPIPE race is possible.
    grep -qiE "^${art_name}$" <<<"$f" && continue
    _vb_m=$((_vb_m+1))  # P9-VB-M-BT
    if [ "$start" -eq 0 ]; then
      echo "   RANGE!  $c  (start 0 is invalid — lines are 1-indexed)"; rc=1; continue
    fi
    if [ "$start" -gt "$end" ]; then
      echo "   RANGE!  $c  (reversed range: start $start > end $end — defect in block)"; rc=1; continue
    fi
    # Roots are tried IN ORDER; the first where the file exists AND the cited range fits wins (F2: a short
    # file at an earlier root must not pre-empt a fitting one later). If none fits, RANGE! is reported
    # against the FIRST existing file.
    _bt_roots=("$target"); _bt_lbl=("")
    [ -n "$git_root" ] && [ "$git_root" != "$target" ] && { _bt_roots+=("$git_root"); _bt_lbl+=(""); }  # N-PROJECT-FALLBACK
    [ -n "$target_root" ] && { _bt_roots+=("$target_root"); _bt_lbl+=("(target-root) "); }  # TARGET-ROOT-FALLBACK
    [ -n "${SOURCE_ROOT:-}" ] && { _bt_roots+=("$SOURCE_ROOT"); _bt_lbl+=(""); }  # SOURCE_ROOT-FALLBACK
    _bt_resolve=""; _bt_first=""; _bt_tag=""
    for _bt_i in "${!_bt_roots[@]}"; do
      [ -f "${_bt_roots[$_bt_i]}/$f" ] || continue
      [ -z "$_bt_first" ] && { _bt_first="${_bt_roots[$_bt_i]}/$f"; _bt_first_tag="${_bt_lbl[$_bt_i]}"; }
      if [ "$end" -le "$(wc -l < "${_bt_roots[$_bt_i]}/$f")" ]; then  # BT-RANGE-FIT
        _bt_resolve="${_bt_roots[$_bt_i]}/$f"; _bt_tag="${_bt_lbl[$_bt_i]}"; break
      fi
    done
    [ -z "$_bt_resolve" ] && [ -n "$_bt_first" ] && { _bt_resolve="$_bt_first"; _bt_tag="$_bt_first_tag"; }
    _bt_okp="ok      "; [ -n "$_bt_tag" ] && _bt_okp="ok $_bt_tag"  # TARGET-ROOT-LABEL
    if [ -f "$_bt_resolve" ]; then
      total=$(wc -l < "$_bt_resolve")
      if [ "$end" -le "$total" ]; then
        if [ "$start" = "$end" ]; then
          echo "   $_bt_okp$c"; _vb_ok=$((_vb_ok+1))  # P9-VB-OK-BT
        else
          echo "   $_bt_okp$c  (range end verified; file has $total lines)"; _vb_ok=$((_vb_ok+1))  # P9-VB-OK-RANGE
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
# P9-RESOLVED-SUMMARY: print resolved N of M and WARN when N=0 and M>0 (issue #956, §7 false-negative).
# Fires when citations were attempted but none resolved — distinct from P6 (no citations at all).
# WARN is graded by the block's declared Type:, using the same taxonomy as P6 (P9-TYPE-PARSE-EARLY above).
# WARN-only: exit code is NOT changed (a finding is advisory, CLAUDE.md §8).
if [ "$_vb_m" -gt 0 ]; then  # P9-RESOLVED-SUMMARY
  echo "   resolved $_vb_ok of $_vb_m"
  if [ "$_vb_ok" -eq 0 ]; then
    # case replaces printf|grep-qxF to avoid pipefail/SIGPIPE exit 141 on early match — same family as e727cde.
    if [ "$cert_total" -gt 0 ] && [ "$code_cert_total" -eq 0 ]; then  # P9-DOC-GRADE-GUARD: mirror P6-CERT-ZERO-CITE-WARN/P6-DOC-AWARE-SUPPRESS
      echo "   INFO    resolved 0 of $_vb_m — doc-grade markers only; file:line citations not expected."
    else
      case "$_type_token" in
        synthesis|capture|document|absence-centred|decision)  # P9-TYPE-CLASSIFY
          echo "   INFO    resolved 0 of $_vb_m — expected for declared type $_type_token."
          ;;
        standard|evidence|mixed|collaborative|audit)
          echo "   WARN    resolved 0 of $_vb_m — no file paths resolved. Set SOURCE_ROOT if source files live in a separate tree."
          ;;
        *)
          if [ -n "$_type_raw" ]; then  # P9-TYPE-UNRECOGNISED
            _type_warn_name="${_type_token:-$(printf '%s' "$_type_stripped" | sed 's/[[:space:]]*\*.*//; s/[[:space:]]*\.[[:space:]]*$//; s/[[:space:]]*$//')}"  # P9-TYPE-DISPLAY
            echo "   WARN    resolved 0 of $_vb_m — unrecognised Type: '$_type_warn_name'; no file paths resolved. Set SOURCE_ROOT if source files live in a separate tree."
          else
            echo "   WARN    resolved 0 of $_vb_m — no file paths resolved. Set SOURCE_ROOT if source files live in a separate tree."
            echo "   HINT    Declare a Type: token to grade this WARN: standard | evidence | synthesis | mixed | absence-centred | capture | document | collaborative | audit | decision."  # P9-NO-TYPE-HINT
          fi
          ;;
      esac
    fi
  fi
fi

# 3b. POSSIBILITY-FIRST (§1) — a bare "not possible / cannot / no way / out of reach / no se puede" verdict with no
#     >=3-route ladder in its section. ADVISORY: WARN only, exit code unchanged.
echo "-- possibility-first (§1: no bare feasibility verdict) --"
_pf_n=0
while IFS=$'\t' read -r _pf_ln _pf_ph _pf_tx; do
  [ -z "$_pf_ln" ] && continue
  echo "   WARN    possibility-first line $_pf_ln: bare verdict '$_pf_ph' — rewrite as a route ladder (>=3 routes of different classes, cost + needs each, ending with the cheapest next step; unexecuted routes are [INFER]/proposed)."
  _pf_n=$((_pf_n+1))
done < <(pf_scan "$block")
[ "$_pf_n" -eq 0 ] && echo "   (none — no bare feasibility verdict)"

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
    _vb_grep_err=0
    for tok in "$pdf_base" "$ext_stem" "$loose"; do
      [ -n "$tok" ] || continue
      # No '|| true': grep exit-1 (tok absent from block) is benign; exit ≥2 must surface — §7.
      h=$(grep -nF "$tok" "$block" 2>/dev/null)
      _vb_h_rc=$?
      [ "$_vb_h_rc" -ge 2 ] && { _vb_grep_err=$_vb_h_rc; continue; }
      [ -n "$h" ] && hits="${hits}${h}"$'\n'
    done
    if [ "$_vb_grep_err" -ge 2 ]; then
      printf '   WARN: citation resolution FAILED (grep exit %d) — unresolved (grep exit R)\n' "$_vb_grep_err"
    else
      # No '|| true': with pipefail, exit ≥2 must surface — §7.
      hits=$(printf '%s' "$hits" | grep -vE '^[[:space:]]*$' | sort -t: -k1n -u)
      _vb_dedup_rc=$?
      if [ "$_vb_dedup_rc" -ge 2 ]; then
        printf '   WARN: citation dedup FAILED (grep exit %d) — unresolved (grep exit R)\n' "$_vb_dedup_rc"
        hits=""
      fi
      if [ -n "$hits" ]; then
        echo "   OCR!    lines citing OCR-lossy '$ext_stem' — re-verify numbers/quotes/serials vs page image:"
        printf '%s\n' "$hits" | sed 's/^/           /'
        lossy_hits=$((lossy_hits+1))
      fi
    fi
  done < <(find "$ext_dir" -maxdepth 1 -name '*.md' 2>/dev/null)
fi
[ "$lossy_hits" -eq 0 ] && echo "   (none — no citation traces to an OCR-lossy extract)"

# 9. EMPTY-INPUT DIGEST (#1487, METHODOLOGY §11a) — a cited hash equal to the digest of EMPTY input (sha256
#    e3b0c442…, sha1 da39a3ee…, md5 d41d8cd9…) proves nothing: it is what a hasher prints when the file was
#    missing or empty. FAIL (rc=1), one typed `EMPTYHASH!` line per occurrence, with the line number.
#    Match unit = a MAXIMAL hex run (so a longer hex string that merely contains the digest never fires),
#    not glued to a preceding word char, whole block scanned (a hash may sit in prose, a table or a code
#    span). An elided prefix (`e3b0c442…` / `e3b0c442...`) of >= 8 hex chars counts too — the corpus's own
#    display convention truncates hashes; shorter prefixes are no claim.
#    WAIVER (a block that legitimately QUOTES the empty digest, e.g. to document the n5 incident): end THAT
#    line with the marker `<!-- empty-digest: quoted -->`. A waived hit is reported as `INFO` (never silent)
#    and does not change the exit code; an unwaived hit on any other line still FAILs.
_vb_eh_n=0; _vb_eh_w=0; _vb_eh_deg=0
_vb_eh_out=$(awk '
  BEGIN { d["sha256"]="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
          d["sha1"]="da39a3ee5e6b4b0d3255bfef95601890afd80709"
          d["md5"]="d41d8cd98f00b204e9800998ecf8427e" }   # VB-EMPTY-DIGEST-TABLE
  {
    rest = tolower($0)
    while (match(rest, /[0-9a-f]+/)) {
      tok = substr(rest, RSTART, RLENGTH)
      before = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
      after = substr(rest, RSTART + RLENGTH)
      elided = (after ~ /^…/ || after ~ /^\.\.\./)
      if (before !~ /[a-z0-9_]/) {
        for (k in d) {
          if (tok == d[k] || (elided && length(tok) >= 8 && length(tok) < length(d[k]) && index(d[k], tok) == 1))   # VB-EMPTY-DIGEST-MATCH
            if (index($0, "<!-- empty-digest: quoted -->") > 0)   # VB-EH-WAIVER
              printf "W\t   INFO    empty-digest waived on line %d (%s digest quoted on purpose, marker present)\n", NR, k
            else
            printf "F\t   EMPTYHASH! line %d: %s digest of EMPTY input (%s%s) — proves nothing (file missing/empty when hashed); re-hash the real file\n", NR, k, substr(tok, 1, 16), (length(tok) > 16 ? "…" : "")
        }
      }
      rest = after
    }
  }
  END { print "T\t@@scanned " NR }   # coverage trailer: absent => the detector did not run to completion
' "$block")
_vb_eh_rc=$?
# Anti-silent-zero (#1500): an aborted detector, or one that never reached END, is a typed degraded state.
if [ "$_vb_eh_rc" -ne 0 ] || ! grep -q $'^T\t@@scanned [0-9][0-9]*$' <<<"$_vb_eh_out"; then
  printf '   ERROR: empty-digest scan DEGRADED (awk exit %d, no scan trailer) — block NOT checked for empty-input digests\n' "$_vb_eh_rc"
  rc=1; _vb_eh_deg=1
fi
# Each awk line is `<tag><TAB><text>`: W = waived INFO, F = FAIL, T = trailer. The tag, not the printed text,
# decides the verdict (#1500), so rewording the message cannot flip the exit code.
while IFS= read -r _vb_eh_line; do
  [ -z "$_vb_eh_line" ] && continue
  _vb_eh_tag=${_vb_eh_line%%$'\t'*}; _vb_eh_text=${_vb_eh_line#*$'\t'}
  case "$_vb_eh_tag" in
    T) continue;;
    W) echo "$_vb_eh_text"; _vb_eh_w=$((_vb_eh_w + 1)); continue;;   # VB-EH-WAIVED-TAG
  esac
  echo "$_vb_eh_text"
  _vb_eh_n=$((_vb_eh_n + 1)); rc=1
done <<<"$_vb_eh_out"
if [ "$_vb_eh_deg" -eq 1 ]; then :   # degraded: the ERROR line above is the verdict — never also print a clean "(none)"
elif [ "$_vb_eh_n" -eq 0 ]; then echo "   (none — no unwaived cited hash equals the digest of empty input; waived: $_vb_eh_w)"; else echo "-- empty-input digests cited: $_vb_eh_n (FAIL)"; fi

echo "== exit $rc =="
exit $rc
