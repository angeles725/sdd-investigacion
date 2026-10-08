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
# Usage: verify-block.sh [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]
#   Ephemeral-path cites FAIL by default (EPHEMERAL!, exit 1; kit #1660, the end of the kit #1207 staged rollout).
#   Opt-out, for a corpus not yet cleaned: `--ephemeral=warn` or env RSDD_STRICT_EPHEMERAL=0 — each cite is then a typed WARN
#   (EPHEMERAL?, counted and listed, exit unchanged). `--strict-ephemeral` / `--ephemeral=fail` / RSDD_STRICT_EPHEMERAL=1 force the
#   FAIL. Precedence: the last flag, then the env (only the exact value 0 opts out), then the default (FAIL). An unknown
#   --ephemeral value is a usage error (exit 2).
#        verify-block.sh --possibility-sweep <corpus-dir>   (list existing bare feasibility verdicts; read-only)
#   target-dir defaults to the block's own directory (file:line citations are target-relative). `sources/…`
#       cites resolve against the target-dir, so for a NESTED corpus (`$TARGET/corpus/…`) pass the CORPUS ROOT as
#       target-dir — running with the project root leaves every `sources/…` cite `extern` (kit #1905).
#   --extern-check (kit #1906, opt-in): a cross-target corpus cites mostly files OUTSIDE the corpus by ABSOLUTE
#       path (`/abs/file.py:12-14`); by default they are `extern` and never looked at. With the flag an absolute
#       backticked cite whose file is a regular readable file has its END line checked against the file's line
#       count: `ok extern` (counted resolved) or `RANGE!` + exit 1 past EOF. The file is only COUNTED — NO content
#       is ever printed (a block is agent-authored; echoing cited files could leak secrets). A missing, non-regular
#       or unreadable file stays a typed `extern`. A final `extern-check: verified N of A absolute backticked
#       name.ext:N cite(s); R relative cite(s) cannot be resolved` line states what was checked; the token-check
#       (does the line say what the block claims) still needs the agent. Without the flag: unchanged.
#   §14 BACK-POINTER (kit #1962, section 12): a sentence that corrects an earlier block ("corrige B5", "refutes [Block 5]") whose cited
#       block file holds no pointer back to this block is a candidate; --backptr=high (default) prints a per-line `BACKPTR?` only for
#       the high-confidence shape (a correction act within 25 characters of a `[Block N]` / `Block N` / `Bloque N` cite) and counts the
#       rest in ONE line, --backptr=all lists everything, --backptr=off skips it. Advisory, exit unchanged; not-found / ambiguous /
#       degraded candidates are typed lines, never silent. Only canonical block file names (<prefix>-(block|bloque)<N>[-slug].md) are checked.
#       The POSSIBILITY-FIRST lint (§1 trait, #1265) is ADVISORY (WARN, exit unchanged — like P6/P9: it is a
#       prose-heuristic, so a hard FAIL would train operators to ignore the gate; the sweep surfaces, never edits).
# Exit: 0 = no verifiable contradiction · 1 = a cited line is out of range, OR a cited block-evidence artifact
#       (B<N>-* / bloque<N>-*) is not preserved in the target, OR a cited hash equals the digest of EMPTY
#       input (EMPTYHASH!, #1487; waive a quoted digest per line with `<!-- empty-digest: quoted -->`), OR a cited path is ephemeral (EPHEMERAL!,
#       kit #1207/#1660; under the --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 opt-out it is a WARN EPHEMERAL?, exit unchanged)
#       — under /tmp, /var/tmp, $TMPDIR or a session scratchpad/ (any cite form, [CERT*] or not; a line
#       carrying a REAL sha256 anchor — the word `sha256` AND a 64-hex digest on that same line, the word alone
#       is NOT an anchor — the §5 beautified-temp view, is exempt, as an INFO; a `<!-- ephemeral-ok: <reason> -->`
#       marker anywhere on the line waives it per line as an INFO, the reason is mandatory and an empty one
#       leaves the finding standing plus a typed `invalid marker` line), OR a preserved script cited under sources/probes/ has no valid SCRIPTS-MANIFEST row / a row whose
#       sha256 differs from the file's (MANIFEST!, kit #1207; only when the corpus has >= 1 manifest — with none
#       the line is `INFO no SCRIPTS-MANIFEST`; a failed manifest scan is the typed `DEGRADED manifest scan failed`
#       line with exit 1, like the other operational degraded states here — never read as "no manifest") · 2 = bad args.
#   SCRIPTS-MANIFEST.md (one per sources/probes/<dir>/, kit #1207) — a markdown table, one row per preserved script:
#       | script | sha256 | run/step | block | executed-on | remote-sha256 | role |
#     script = file name or path relative to the manifest dir (resolved against THAT manifest's directory and
#     matched to the cited path; a row in another probes dir never lists this dir's script — a bare name also
#     matches its own dir only; a cell starting with `sources/` is target-relative) · sha256 = 64 hex of the preserved file · run/step =
#     the exact command (with arguments) or step number that ran it · block = B<N> that relies on it · executed-on =
#     host/device where it ran · remote-sha256 = digest of the copy that ran remotely (or `-`) ·
#     role = EXECUTED | RECIPE | FAILED-ATTEMPT. Only columns 1-2 are machine-checked; the rest is for humans.

set -uo pipefail
# kit #1659: the one shared SCRIPTS-MANIFEST row parser (also used by clean-check.sh). It is loaded LAZILY by
# _vb_load_smlib (section 11 only), from the directory of THIS script with symlinks followed (BASH_SOURCE, never the
# caller's cwd or a lib/ beside a symlink). Returns 1 with a message when it cannot be loaded.
_vb_load_smlib() {
  local src="${BASH_SOURCE[0]}" n=0 lt d here
  while [ -L "$src" ] && [ "$n" -lt 40 ]; do   # VB-LIB-RESOLVE
    n=$((n + 1)); lt="$(readlink -- "$src")" || { echo "verify-block: cannot read symlink $src" >&2; return 1; }
    case "$lt" in /*) src="$lt" ;; *) d="${src%/*}"; [ "$d" = "$src" ] && d=.; src="$d/$lt" ;; esac
  done
  d="${src%/*}"; [ "$d" = "$src" ] && d=.
  here="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || { echo "verify-block: cannot resolve the script directory of $src" >&2; return 1; }
  [ -f "$here/lib/scripts-manifest.sh" ] || { echo "verify-block: cannot find helper $here/lib/scripts-manifest.sh" >&2; return 1; }
  # shellcheck source=lib/scripts-manifest.sh
  . "$here/lib/scripts-manifest.sh"
  declare -F scripts_manifest_rows >/dev/null 2>&1 || { echo "verify-block: helper lib/scripts-manifest.sh failed to define scripts_manifest_rows" >&2; return 1; }
}
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

# Ephemeral-path cites FAIL (EPHEMERAL!) by default (kit #1660); the opt-out is a WARN (EPHEMERAL?, exit unchanged):
# `--ephemeral=warn` or RSDD_STRICT_EPHEMERAL=0 (exact value; anything else keeps the default). A flag beats the env.
STRICT_EP=1; [ "${RSDD_STRICT_EPHEMERAL:-}" = "0" ] && STRICT_EP=0   # VB-EP-DEFAULT
# A set-but-malformed value (anything except exactly 0 or 1, the empty string included) keeps the default and says so once.
if [ -n "${RSDD_STRICT_EPHEMERAL+x}" ] && [ "${RSDD_STRICT_EPHEMERAL}" != "0" ] && [ "${RSDD_STRICT_EPHEMERAL}" != "1" ]; then   # VB-EP-ENVNOTICE
  echo "verify-block.sh: RSDD_STRICT_EPHEMERAL='${RSDD_STRICT_EPHEMERAL}' is not 0 or 1 — ignored, ephemeral cites FAIL (set 0 to opt out)" >&2
fi
BACKPTR_MODE=high  # kit #1962: --backptr=high (default: per-line BACKPTR? only for the high-confidence shape) | all | off
EXTERN_CHECK=0  # kit #1906: opt-in, no env form (it reads and counts files outside the target and never prints their content)
_vb_args=(); for _vb_a in "$@"; do
  case "$_vb_a" in
    --strict-ephemeral|--ephemeral=fail) STRICT_EP=1 ;;  # VB-EP-STRICT-FLAG
    --ephemeral=warn) STRICT_EP=0 ;;  # VB-EP-WARN-FLAG
    --ephemeral|--ephemeral=*) echo "verify-block.sh: unknown --ephemeral value '${_vb_a#--ephemeral}' (expected --ephemeral=warn or --ephemeral=fail)" >&2; exit 2 ;;  # VB-EP-BADVALUE
    --extern-check) EXTERN_CHECK=1 ;;  # VB-EXTERN-CHECK-FLAG
    --backptr=high|--backptr=all|--backptr=off) BACKPTR_MODE="${_vb_a#--backptr=}" ;;  # VB-BACKPTR-FLAG
    --backptr|--backptr=*) echo "verify-block.sh: unknown --backptr value '${_vb_a#--backptr}' (expected --backptr=high, --backptr=all or --backptr=off)" >&2; exit 2 ;;  # VB-BACKPTR-BADVALUE
    *) _vb_args+=("$_vb_a") ;;
  esac
done
set -- ${_vb_args[@]+"${_vb_args[@]}"}
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
[ -f "$block" ] || { echo "usage: verify-block.sh [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]  (sources/… cites resolve against target-dir: for a NESTED corpus pass the corpus root)" >&2; exit 2; }
target="${2:-$(dirname "$block")}"
# VB-LINECOUNT (kit #1919): the ONE line counter for every cite path (artifact, backtick, --extern-check). awk NR counts an
# UNTERMINATED last line (`wc -l` counts newline characters and was one short; CR is not a line terminator: CRLF counts like LF).
# `_vb_lines FILE [END]` prints the line count; with END it stops reading at that line (prints END when the file
# reaches it), so a fit check does not read past the cited line (a fitting cite is still counted in full afterwards, for the
# `file has N lines` message). A counter that fails (non-zero status, or no number)
# prints nothing and returns 1: callers treat that as a typed DEGRADED, never as a verdict. Only COUNTS, never file content.
_vb_lines() {
  local _vb_lc_n _vb_lc_s
  _vb_lc_n=$(awk -v e="${2:-0}" 'e>0&&NR>=e{exit} END{print NR}' "$1"); _vb_lc_s=$?
  [ "$_vb_lc_s" -eq 0 ] || return 1  # VB-LINECOUNT-STATUS
  [[ "$_vb_lc_n" =~ ^[0-9]+$ ]] || return 1  # VB-LINECOUNT-NUMERIC
  printf '%s\n' "$_vb_lc_n"
}
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
#       ip:port / host:port / qualified-class tokens and unresolvable Class.method:NNN are `nonpath` (kit #973): listed, never counted
#       in the P9 `resolved N of M (E extern, F failed[, D degraded])` summary; its SOURCE_ROOT hint appears only when E > 0.
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
# kit #973 (P973-NONPATH-SPLIT): some backticked `name.ext:NNN` tokens are not file citations at all — `ip:port`
# (127.0.0.1:46272), `host:port` (a host with >= 2 dots ending in a TLD) and a fully-qualified class (>= 2 dots,
# last label capitalised: javax.baja.Foo:238). They would inflate M in P9 and no SOURCE_ROOT can resolve them, so
# they are split off HERE (before the P6 emptiness tests, so a block citing only such tokens still reads as citing
# nothing) and LISTED by the resolution loop as `nonpath`, never silently dropped. `Class.method:NNN` has no
# structural tell; it is classified in the loop only when no root holds the file (P973-NONPATH-METHOD).
_vb_np_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:|^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.(com|io|net|org|dev|edu|gov|mx|local|lan|internal|cloud|app):|^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.[A-Z][A-Za-z0-9_]*:'
_vb_np_cites=""; _vb_np_n=0; _vb_np_err=0
# TLD list for P1721-TLD-GUARD: it holds ONLY the overlap of real TLDs with _vb_file_exts (the guard reads it solely for
# an extension that is also a TLD). A TLD that is not an extension (com, io, net, ...) never reaches the guard, so it is
# not listed here; the host alternation in _vb_np_re is a separate list with a different job. exts-invariants.sh asserts
# that every entry below is also in _vb_file_exts (kit #1742).
_vb_tlds='org
pl
md
rs
sh
sc
ml
tf
cc'
# Known file extensions (lower-case, one per line). Matching is case-INSENSITIVE in the Class.method branch of the
# resolution loop (the ext is lower-cased first) but EXACT-CASE in the pre-split (P1721-NONPATH-EXT), where the last
# label is compared as written so a Java class named `Log` / `Bin` is never read as an extension. A path-less
# `name.ext:NNN` token whose file is not found is read as `Class.method:NNN` (P973-NONPATH-METHOD) ONLY when ALL hold:
# the ext is NOT in this list, the ext is a method-like identifier (starts lower-case, letters/digits, not digits-only), and the name carries an
# upper-case letter (Class or lowerCamel). A MISSING entry is NOT harmless: an unresolved real cite with an unlisted
# extension would leave M and E and lose the SOURCE_ROOT hint, hiding a fixable WARN. So the list is broad and every
# doubt falls toward `extern` (the WARN). Resolved files are never reclassified (RANGE! and exit codes are safe).
_vb_file_exts='java
md
js
mjs
cjs
ts
tsx
jsx
html
htm
css
scss
txt
go
py
csv
properties
xml
kt
kts
vue
sh
ps1
psm1
cs
bat
cmd
px
yaml
yml
json
jsonc
c
h
cc
cpp
hpp
rs
rb
php
lua
sql
toml
ini
cfg
conf
log
rst
ttl
lexicon
license
bajadoc
vm
xsl
xsd
svg
gradle
mk
class
jar
dll
exe
bin
dat
hex
mf
pdf
diff
patch
proto
scala
sc
sbt
swift
dart
r
rmd
ex
exs
erl
hrl
hs
lhs
clj
cljs
edn
groovy
gvy
pl
pm
t
jl
nim
zig
v
sv
vhd
vhdl
tcl
awk
bash
zsh
fish
ksh
m
mm
ml
mli
fs
fsx
vb
vbs
lisp
el
rkt
scm
svelte
astro
mts
cts
cxx
hh
hxx
inl
asm
s
tf
tfvars
hcl
nix
bzl
cmake
make
dockerfile
env
lock
sum
mod
plist
strings
storyboard
xib
pom
iml
sln
csproj
vbproj
props
targets
resx
xaml
aspx
asp
jsp
jspx
erb
ejs
hbs
pug
less
sass
styl
coffee
tex
bib
adoc
org
text
rtf
mdx
markdown
json5
jsonl
ndjson
tsv
xls
xlsx
doc
docx
ppt
pptx
odt
ods
ipynb
graphql
gql
prisma
thrift
avsc
sol
wasm
wat
j2
jinja
tmpl
tpl
mustache
out
err
trc
dmp
pcap
pcapng
rpt
cnf
bog
zip
tar
gz
tgz
png
jpg
jpeg
gif
bmp
ico
xhtml
pyw
pyi
pyx'
# P1766-VERSION-LABEL: the ONE definition of "version-like label" (`v1`, `v2`: a whole dot-separated label) shared by the R rescue
# and the TLD guard below. Argument = the dotted labels BEFORE the extension; a `vN` label at the first, middle, last or only
# position counts (end-of-string accepted), so `notes.v1.org`, `v1.org` and `de.report.v2.R` agree. `v2x` is not version-like.
_vb_np_versioned() { grep -qE '(^|\.)v[0-9]+(\.|$)' <<<"$1"; }
if [ -n "$bt_cites" ]; then
  _vb_np_cites=$(grep -E "$_vb_np_re" <<<"$bt_cites"); _vb_np_h=$?   # P973-NONPATH-SPLIT
  if [ "$_vb_np_h" -ge 2 ]; then _vb_np_err=$_vb_np_h; _vb_np_cites=""
  elif [ -n "$_vb_np_cites" ]; then
    # P973-NONPATH-EXISTS: a shape match is only a candidate. A token whose file EXISTS under any source root is a real
    # cite (`analysis.v2.R`, `x.app`) and stays in bt_cites, so RANGE! / ok and the exit code are untouched.
    _vb_np_cand="$_vb_np_cites"; _vb_np_cites=""
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      _vb_np_hit=0
      for _vb_np_r in "$target" "$git_root" "$target_root" "${SOURCE_ROOT:-}"; do
        if [ -n "$_vb_np_r" ] && [ -f "$_vb_np_r/${c%:*}" ]; then _vb_np_hit=1; break; fi
      done
      # P1721-NONPATH-EXT: an unresolved shape match that is really a missing extern source cite stays in bt_cites so the
      # loop reports it `extern` (WARN + SOURCE_ROOT hint), the same rule as the Class.method branch below. Exact case, so
      # a Java FQCN whose class name merely spells an extension (`org.foo.Log`, `x.y.Class`, `x.y.Bin`, `a.b.T`) stays
      # nonpath: (1) the last label is a LOWER-case known extension (`notes.v1.org`), or (2) the last label is the
      # upper-case `R` (R scripts, `analysis.v2.R`) UNLESS it reads as an Android/Java package: the first label is a known
      # package root or any 2-letter label (a ccTLD: de, uk, fr, me, co) AND no path label is version-like (`v2`). So
      # `com.example.my_app.R`, `de.example.app.R`, `uk.co.acme.R` stay nonpath, while `data.clean.R`, `my_analysis.final.R`,
      # `de.v2.report.R`, `analysis.v2.R` are rescued to extern (kit #1742). Trade-off: an R script under a package-like
      # root (`co.report.R`) reads as a package.
      # Variables: _vb_np_stem = cite without `:NNN`, _vb_np_last = its last label, _vb_np_labels = the labels before it.
      _vb_np_stem="${c%:*}"; _vb_np_last="${_vb_np_stem##*.}"; _vb_np_labels="${_vb_np_stem%.*}"; _vb_np_first="${_vb_np_stem%%.*}"
      if [ "$_vb_np_hit" = 0 ]; then
        if grep -qxF "$_vb_np_last" <<<"$_vb_file_exts"; then
          _vb_np_hit=1
          # P1721-TLD-GUARD: an extension that is ALSO a TLD (the overlap of _vb_file_exts and _vb_tlds: org, pl, md, ...)
          # is rescued only when a label is version-like (`v1`, as in `notes.v1.org`); `api.example.org:443` is a
          # host:port and stays nonpath. Trade-off: a missing `x.y.org:N` file cite without a `vN` label reads as a host.
          if grep -qxF "$_vb_np_last" <<<"$_vb_tlds" && ! _vb_np_versioned "$_vb_np_labels"; then _vb_np_hit=0; fi
        elif [ "$_vb_np_last" = R ]; then
          _vb_np_pkg=0
          case "$_vb_np_first" in com|org|net|io|java|javax|jakarta|android|androidx|edu|gov|kotlin|scala|sun|jdk|[a-z][a-z]) _vb_np_pkg=1 ;; esac
          if _vb_np_versioned "$_vb_np_labels"; then _vb_np_pkg=0; fi
          if [ "$_vb_np_pkg" = 0 ]; then _vb_np_hit=1; fi
        fi
      fi
      [ "$_vb_np_hit" = 0 ] && _vb_np_cites="${_vb_np_cites:+$_vb_np_cites$'\n'}$c"
    done <<<"$_vb_np_cand"
    if [ -n "$_vb_np_cites" ]; then
      _vb_np_keep=$(grep -vxF -f <(printf '%s\n' "$_vb_np_cites") <<<"$bt_cites"); _vb_np_h=$?
      if [ "$_vb_np_h" -ge 2 ]; then _vb_np_err=$_vb_np_h; _vb_np_cites=""; else bt_cites="$_vb_np_keep"; fi
    fi
  fi
fi
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
# Grammar (closed, §4): standard|evidence|synthesis|mixed|absence-centred|capture|document|collaborative|audit|decision|design-applied
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
        synthesis|capture|document|absence-centred|decision|design-applied)  # P6-TYPE-CLASSIFY
          echo "   INFO    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — expected for declared type $_type_token."
          ;;
        standard|evidence|mixed|collaborative|audit)
          echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Expected for synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks (check your block-type declaration); otherwise add file:line citations or re-check the citation format."
          ;;
        *)
          if [ -n "$_type_raw" ]; then  # P6-TYPE-UNRECOGNISED
            # Name the real value when token is empty (uppercase/non-conformant); strip closing ** and trailing punctuation.
            _type_warn_name="${_type_token:-$(printf '%s' "$_type_stripped" | sed 's/[[:space:]]*\*.*//; s/[[:space:]]*\.[[:space:]]*$//; s/[[:space:]]*$//')}"  # P6-TYPE-DISPLAY
            echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — unrecognised Type: token '$_type_warn_name'; accepted: standard | evidence | synthesis | mixed | absence-centred | capture | document | collaborative | audit | decision | design-applied."
          else
            echo "   WARN    [CERT] markers present ($cert_total) but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Expected for synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks (check your block-type declaration); otherwise add file:line citations or re-check the citation format."
            echo "   HINT    Declare a Type: token in the header blockquote to grade this WARN: standard | evidence | synthesis | mixed | absence-centred | capture | document | collaborative | audit | decision | design-applied."
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
_vb_e=0; _vb_f=0   # P9-SPLIT: extern (file not found anywhere) vs. failed (RANGE!/MISSING!: the cite itself is wrong)
_vb_d=0            # VB-DEGRADED (kit #1919): cites NOT judged because the line counter failed (the instrument, not the cite); exit 1, counted apart from failed
_vb_xa=0; _vb_xr=0; _vb_xrel=0  # VB-EXTERN-CHECK counters: absolute extern cites seen / verified, relative extern cites
# kit #973: tokens split off as non-path are listed here, visibly, and never counted in M.
[ "$_vb_np_err" -ge 2 ] && printf '   WARN: non-path token split FAILED (grep exit %d) — ip:port / host:port tokens are counted as file cites\n' "$_vb_np_err"
if [ -n "$_vb_np_cites" ]; then
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    echo "   nonpath  $c  (not a file path: ip:port / host:port / qualified class — excluded from M)"; _vb_np_n=$((_vb_np_n+1))  # P973-NONPATH-LIST
  done <<< "$_vb_np_cites"
fi
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
      echo "   MISSING! $c  (evidence artifact not preserved)"; rc=1; _vb_f=$((_vb_f+1))  # P9-VB-F-MISSING
    else
      total=$(_vb_lines "$target/$f") || { echo "   linecount DEGRADED  $c (line count failed)"; rc=1; _vb_d=$((_vb_d+1)); continue; }  # VB-LINECOUNT-ART
      # FAIL if either endpoint is past EOF or the range is reversed (start > end).
      if [ "$start" -le "$total" ] && [ "$end" -le "$total" ] && [ "$start" -le "$end" ]; then
        echo "   ok      $c"; _vb_ok=$((_vb_ok+1))  # P9-VB-OK-ART
      else
        echo "   RANGE!  $c  (file has $total lines) — cited line out of range"; rc=1; _vb_f=$((_vb_f+1))
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
      echo "   RANGE!  $c  (start 0 is invalid — lines are 1-indexed)"; rc=1; _vb_f=$((_vb_f+1)); continue
    fi
    if [ "$start" -gt "$end" ]; then
      echo "   RANGE!  $c  (reversed range: start $start > end $end — defect in block)"; rc=1; _vb_f=$((_vb_f+1)); continue
    fi
    # Roots are tried IN ORDER; the first where the file exists AND the cited range fits wins (F2: a short
    # file at an earlier root must not pre-empt a fitting one later). If none fits, RANGE! is reported
    # against the FIRST existing file.
    _bt_roots=("$target"); _bt_lbl=("")
    [ -n "$git_root" ] && [ "$git_root" != "$target" ] && { _bt_roots+=("$git_root"); _bt_lbl+=(""); }  # N-PROJECT-FALLBACK
    [ -n "$target_root" ] && { _bt_roots+=("$target_root"); _bt_lbl+=("(target-root) "); }  # TARGET-ROOT-FALLBACK
    [ -n "${SOURCE_ROOT:-}" ] && { _bt_roots+=("$SOURCE_ROOT"); _bt_lbl+=(""); }  # SOURCE_ROOT-FALLBACK
    _bt_resolve=""; _bt_first=""; _bt_tag=""; _bt_cdeg=0
    for _bt_i in "${!_bt_roots[@]}"; do
      [ -f "${_bt_roots[$_bt_i]}/$f" ] || continue
      [ -z "$_bt_first" ] && { _bt_first="${_bt_roots[$_bt_i]}/$f"; _bt_first_tag="${_bt_lbl[$_bt_i]}"; }
      # a counter that fails here is not a "does not fit": it sets _bt_cdeg. If a LATER root fits, the cite resolves there;
      # if none fits, the cite is DEGRADED (below) rather than judged RANGE! from another root's successful count.
      if _vb_fit=$(_vb_lines "${_bt_roots[$_bt_i]}/$f" "$end"); then
        if [ "$end" -le "$_vb_fit" ]; then  # BT-RANGE-FIT
          _bt_resolve="${_bt_roots[$_bt_i]}/$f"; _bt_tag="${_bt_lbl[$_bt_i]}"; break
        fi
      else
        _bt_cdeg=1  # BT-FIT-DEGRADED
      fi
    done
    if [ -z "$_bt_resolve" ] && [ "$_bt_cdeg" = 1 ]; then
      echo "   linecount DEGRADED  $c (line count failed)"; rc=1; _vb_d=$((_vb_d+1)); continue
    fi
    [ -z "$_bt_resolve" ] && [ -n "$_bt_first" ] && { _bt_resolve="$_bt_first"; _bt_tag="$_bt_first_tag"; }
    _bt_okp="ok      "; [ -n "$_bt_tag" ] && _bt_okp="ok $_bt_tag"  # TARGET-ROOT-LABEL
    if [ -f "$_bt_resolve" ]; then
      total=$(_vb_lines "$_bt_resolve") || { echo "   linecount DEGRADED  $c (line count failed)"; rc=1; _vb_d=$((_vb_d+1)); continue; }  # VB-LINECOUNT-BT
      if [ "$end" -le "$total" ]; then
        if [ "$start" = "$end" ]; then
          echo "   $_bt_okp$c"; _vb_ok=$((_vb_ok+1))  # P9-VB-OK-BT
        else
          echo "   $_bt_okp$c  (range end verified; file has $total lines)"; _vb_ok=$((_vb_ok+1))  # P9-VB-OK-RANGE
        fi
      else
        echo "   RANGE!  $c  (file has $total lines) — cited line out of range"; rc=1; _vb_f=$((_vb_f+1))
      fi
    else
      # P973-NONPATH-METHOD: `Class.method:NNN` — no root holds the file AND the name has no path and an extension
      # that is not a known file extension. Only reached for an UNRESOLVED cite, so an existing file (any extension)
      # is never reclassified and ok / RANGE! / the exit code are untouched. It was counted in M above: take it back.
      # VB-EXTERN-CHECK (kit #1906): opt-in line-count check of an ABSOLUTE extern cite (never prints file content). Reached only for an unresolved cite and only
      # with --extern-check, so the default verdict, counts and exit code are untouched. A path with `/` never reaches the
      # Class.method branch below, so this cannot steal a nonpath token. In range -> ok (counted resolved, not extern);
      # past EOF -> RANGE! + exit 1 like an in-target cite; not a readable file -> typed extern, still counted E.
      if [ "$EXTERN_CHECK" = 1 ] && [ "${f:0:1}" = "/" ]; then
        _vb_xa=$((_vb_xa+1))
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
          echo "   extern  $c  (absolute path not found or unreadable — not script-verifiable)"; _vb_e=$((_vb_e+1)); continue
        fi
        # The file is only COUNTED (awk NR: an unterminated last line counts, CR is not a line terminator); no byte of it is ever echoed.
        # awk exits at the cited END line (NR then equals END), so an in-range cite does not read the rest of the file; past EOF it
        # prints the full count. A counter that fails (non-zero status, or no number) is NEVER a verdict: typed DEGRADED, exit 1.
        total=$(_vb_lines "$f" "$end") || {  # VB-LINECOUNT-EXTERN
          echo "   extern-check DEGRADED  $c (line count failed)"; rc=1; _vb_d=$((_vb_d+1)); continue
        }
        _vb_xr=$((_vb_xr+1))
        if [ "$end" -gt "$total" ]; then
          echo "   RANGE!  $c  (file has $total lines) — cited line out of range"; rc=1; _vb_f=$((_vb_f+1)); continue
        fi
        if [ "$start" = "$end" ]; then echo "   ok extern $c"; else echo "   ok extern $c  (range end verified)"; fi
        _vb_ok=$((_vb_ok+1))
        continue
      fi
      _vb_np_ext="${f##*.}"; _vb_np_ext="${_vb_np_ext,,}"
      # method-like: no path, ext = lower-case identifier (not digits-only, never a bare `R`/`M`), name has an upper-case letter
      _vb_np_m=0
      case "$f" in
        */*) ;;
        *) case "${f##*.}" in [a-z]*) case "${f%.*}" in *[A-Z]*) _vb_np_m=1 ;; esac ;; esac ;;
      esac
      if [ "$_vb_np_m" = 1 ] && ! grep -qxF "$_vb_np_ext" <<<"$_vb_file_exts"; then
        echo "   nonpath  $c  (not a file path: unknown extension '$_vb_np_ext', no such file — likely Class.method:NNN; excluded from M)"
        _vb_m=$((_vb_m-1)); _vb_np_n=$((_vb_np_n+1)); continue  # P973-NONPATH-METHOD
      fi
      [ "$EXTERN_CHECK" = 1 ] && _vb_xrel=$((_vb_xrel+1))  # a relative extern cite: no root to read it from
      echo "   extern  $c  (not in target: beautified-temp / decompiled / snapshot — not script-verifiable)"; _vb_e=$((_vb_e+1))  # P9-VB-E-EXTERN
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
# VB-EXTERN-CHECK-SUMMARY: with the flag, always say what was looked at — a zero read must be distinguishable from "not asked".
[ "$EXTERN_CHECK" = 1 ] && echo "   extern-check: verified $_vb_xr of $_vb_xa absolute backticked name.ext:N cite(s); $_vb_xrel relative cite(s) cannot be resolved"
# P9-RESOLVED-SUMMARY: print resolved N of M and WARN when N=0 and M>0 (issue #956, §7 false-negative).
# Fires when citations were attempted but none resolved — distinct from P6 (no citations at all).
# WARN is graded by the block's declared Type:, using the same taxonomy as P6 (P9-TYPE-PARSE-EARLY above).
# WARN-only: exit code is NOT changed (a finding is advisory, CLAUDE.md §8).
if [ "$_vb_m" -gt 0 ]; then  # P9-RESOLVED-SUMMARY
  _p9_deg=""; [ "$_vb_d" -gt 0 ] && _p9_deg=", $_vb_d degraded"  # VB-DEGRADED-SUMMARY
  echo "   resolved $_vb_ok of $_vb_m ($_vb_e extern, $_vb_f failed$_p9_deg)"  # P9-SPLIT
  # P9-HINT-SCOPE: SOURCE_ROOT can only help a cite whose file was NOT FOUND (extern). A RANGE!/MISSING! cite
  # already resolved its file (or names an unpreserved artifact), so a block with no extern cite gets a different cause.
  _p9_why="no file paths resolved."
  if [ "$_vb_d" -gt 0 ]; then _p9_why="line count failed — instrument, not the cite (see the DEGRADED lines above); those cites were not judged."  # VB-DEGRADED-WHY
  elif [ "$_vb_e" -gt 0 ]; then _p9_why="no file paths resolved. Set SOURCE_ROOT if source files live in a separate tree."
  elif [ "$_vb_f" -gt 0 ]; then _p9_why="every cite failed (RANGE!/MISSING!, listed above) — fix those cites; SOURCE_ROOT would not help."; fi
  if [ "$_vb_ok" -eq 0 ]; then
    # case replaces printf|grep-qxF to avoid pipefail/SIGPIPE exit 141 on early match — same family as e727cde.
    if [ "$cert_total" -gt 0 ] && [ "$code_cert_total" -eq 0 ]; then  # P9-DOC-GRADE-GUARD: mirror P6-CERT-ZERO-CITE-WARN/P6-DOC-AWARE-SUPPRESS
      echo "   INFO    resolved 0 of $_vb_m — doc-grade markers only; file:line citations not expected."
    else
      case "$_type_token" in
        synthesis|capture|document|absence-centred|decision|design-applied)  # P9-TYPE-CLASSIFY
          echo "   INFO    resolved 0 of $_vb_m — expected for declared type $_type_token."
          ;;
        standard|evidence|mixed|collaborative|audit)
          echo "   WARN    resolved 0 of $_vb_m — $_p9_why"
          ;;
        *)
          if [ -n "$_type_raw" ]; then  # P9-TYPE-UNRECOGNISED
            _type_warn_name="${_type_token:-$(printf '%s' "$_type_stripped" | sed 's/[[:space:]]*\*.*//; s/[[:space:]]*\.[[:space:]]*$//; s/[[:space:]]*$//')}"  # P9-TYPE-DISPLAY
            echo "   WARN    resolved 0 of $_vb_m — unrecognised Type: '$_type_warn_name'; $_p9_why"
          else
            echo "   WARN    resolved 0 of $_vb_m — $_p9_why"
            echo "   HINT    Declare a Type: token to grade this WARN: standard | evidence | synthesis | mixed | absence-centred | capture | document | collaborative | audit | decision | design-applied."  # P9-NO-TYPE-HINT
          fi
          ;;
      esac
    fi
  fi
elif [ "$_vb_np_n" -gt 0 ]; then  # P973-NONPATH-INFO: tokens were excluded and nothing else was cited — say so, never a silent zero
  echo "   INFO    0 file citations counted — $_vb_np_n non-path token(s) excluded from M (listed above as nonpath)."
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
_vb_eh_trailer=""; grep -q $'^T\t@@scanned [0-9][0-9]*$' <<<"$_vb_eh_out" || _vb_eh_trailer=", no scan trailer"
if [ "$_vb_eh_rc" -ne 0 ] || [ -n "$_vb_eh_trailer" ]; then
  printf '   ERROR: empty-digest scan DEGRADED (awk exit %d%s) — block NOT checked for empty-input digests\n' "$_vb_eh_rc" "$_vb_eh_trailer"
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

# 10. EPHEMERAL-PATH CITES (kit #1207, METHODOLOGY §5/§7 anti-ephemeral-artifact) — a cited path under /tmp,
#     /var/tmp (also /private/tmp, /private/var/tmp, $TMPDIR/, ${TMPDIR}/) or a session `scratchpad/` dir is
#     evidence that will not exist in the next session: FAIL (rc=1), one typed `EPHEMERAL!` line per occurrence
#     with the block line number (WARN `EPHEMERAL?` only under the opt-out, see POLICY). Enumerated cite forms — ALL covered because the scan reads every path-shaped
#     token on every line, whatever wraps it: `file:N`, `file:N-M`, bare backticked path, parenthetical path,
#     table cell, prose, code fence, `[CERT*]`-marked or not. The tmp prefix must not be glued to a preceding
#     path char (so `src/tmp/x` and `./tmp/x` never fire). Verification is NOT limited to [CERT*] lines.
#     POLICY (kit #1660): by default each hit is a FAIL `EPHEMERAL!` (rc=1). The opt-out `--ephemeral=warn` /
#     RSDD_STRICT_EPHEMERAL=0 makes it a WARN `EPHEMERAL?` (counted, listed, exit unchanged); the flag beats the env.
#     EXCEPTION (the §5 beautified-temp view): a line carrying a REAL sha256 anchor (the word `sha256` plus a 64-hex
#     digest on the same line — the word alone is not an anchor) is reported as `INFO
#     ephemeral-anchored` and does not change the exit code — the temp is a working view whose identity is
#     pinned by the hash of the ORIGINAL file. Preserve everything else under sources/probes/b<N>/.
_vb_ep_n=0; _vb_ep_a=0; _vb_ep_deg=0; _vb_ep_k=0; _vb_ep_i=0
_vb_ep_out=$(awk -v strict="$STRICT_EP" '
  function hasdigest(line,   l, run) {   # a real anchor: the word sha256 AND a maximal 64-hex run on the line
    l = tolower(line)
    if (index(l, "sha256") == 0) return 0
    while (match(l, /[0-9a-f]+/)) {
      run = substr(l, RSTART, RLENGTH)
      if (length(run) == 64) return 1   # VB-EP-DIGEST64
      l = substr(l, RSTART + RLENGTH)
    }
    return 0
  }
  function skipspad(tok,   i) {   # scratchpad arm only: needs a `scratchpad` PATH SEGMENT and must not be /tmp-owned
    if (!spad) return 0
    i = index(tok, "scratchpad/")
    if (!(i == 1 || substr(tok, i - 1, 1) == "/")) return 1   # VB-EP-SEGMENT
    if (tok ~ /^(\$\{?TMPDIR\}?|\/private\/var\/tmp|\/private\/tmp|\/var\/tmp|\/tmp)\//) return 1   # VB-EP-OWNED
    return 0
  }
  function scan(re, glue,   rest, tok, before, after, anchored, mk, reason, ok) {
    rest = $0
    anchored = hasdigest($0)   # VB-EP-ANCHOR
    ok = 0; reason = ""
    mk = index($0, "<!-- ephemeral-ok:")   # VB-EP-MARKER
    if (mk > 0) {
      reason = substr($0, mk + 18); sub(/-->.*$/, "", reason); gsub(/^[[:space:]]+|[[:space:]]+$/, "", reason)
      if (reason != "") ok = 1   # VB-EP-REASON
    }
    while (match(rest, re)) {
      tok = substr(rest, RSTART, RLENGTH)
      before = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
      after = substr(rest, RSTART + RLENGTH)
      if (before !~ glue && !skipspad(tok)) {   # VB-EP-GLUE
        sub(/[.,:;]+$/, "", tok)
        if (anchored)
          printf "A\t   INFO    ephemeral-anchored line %d: %s (sha256-anchored beautified-temp view, METHODOLOGY §5)\n", NR, tok
        else if (ok)
          printf "K\t   INFO    ephemeral-ok line %d: %s (waived on purpose: %s)\n", NR, tok, reason
        else {
          if (mk > 0 && !flagged[NR]) { flagged[NR] = 1; printf "I\t   WARN    invalid marker line %d: `<!-- ephemeral-ok: <reason> -->` needs a non-empty reason — marker ignored\n", NR }
          if (strict == "1")   # VB-EP-STRICT
            printf "F\t   EPHEMERAL!  %s  (line %d; session/temp path — preserve under sources/probes/b<N>/)\n", tok, NR
          else
            printf "W\t   EPHEMERAL?  %s  (line %d; session/temp path — preserve under sources/probes/b<N>/; opt-out --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 is active, the default is FAIL)\n", tok, NR
        }
      }
      rest = after
    }
  }
  {
    spad = 0; scan("(\\$\\{?TMPDIR\\}?|/private/var/tmp|/private/tmp|/var/tmp|/tmp)/[A-Za-z0-9_./@+=:~-]*", "[A-Za-z0-9_./~$-]")   # VB-EP-TMP
    spad = 1; scan("[A-Za-z0-9_./@+=:~-]*scratchpad/[A-Za-z0-9_./@+=:~-]*", "[$}A-Za-z0-9_@+=:~-]")   # VB-EP-SCRATCHPAD
  }
  END { print "T\t@@scanned " NR }   # coverage trailer: absent => the detector did not run to completion
' "$block")
_vb_ep_rc=$?
_vb_ep_trailer=""; grep -q $'^T\t@@scanned [0-9][0-9]*$' <<<"$_vb_ep_out" || _vb_ep_trailer=", no scan trailer"
echo "-- ephemeral-path cites (kit #1207/#1660: /tmp, /var/tmp, scratchpad — FAIL by default, WARN under --ephemeral=warn or RSDD_STRICT_EPHEMERAL=0; exempt: sha256 anchor, <!-- ephemeral-ok: <reason> --> marker) --"
if [ "$_vb_ep_rc" -ne 0 ] || [ -n "$_vb_ep_trailer" ]; then
  printf '   ERROR: ephemeral-path scan DEGRADED (awk exit %d%s) — block NOT checked for ephemeral cites\n' "$_vb_ep_rc" "$_vb_ep_trailer"
  rc=1; _vb_ep_deg=1
fi
while IFS= read -r _vb_ep_line; do
  [ -z "$_vb_ep_line" ] && continue
  _vb_ep_tag=${_vb_ep_line%%$'\t'*}; _vb_ep_text=${_vb_ep_line#*$'\t'}
  case "$_vb_ep_tag" in
    T) continue;;
    A) echo "$_vb_ep_text"; _vb_ep_a=$((_vb_ep_a + 1)); continue;;
    K) echo "$_vb_ep_text"; _vb_ep_k=$((_vb_ep_k + 1)); continue;;
    I) echo "$_vb_ep_text"; _vb_ep_i=$((_vb_ep_i + 1)); continue;;
    W) echo "$_vb_ep_text"; _vb_ep_n=$((_vb_ep_n + 1)); continue;;
  esac
  echo "$_vb_ep_text"
  _vb_ep_n=$((_vb_ep_n + 1)); rc=1   # VB-EP-FAIL
done <<<"$_vb_ep_out"
if [ "$_vb_ep_deg" -eq 1 ]; then :
elif [ "$_vb_ep_n" -eq 0 ]; then echo "   (none — no unanchored ephemeral path cited; sha256-anchored: $_vb_ep_a, ephemeral-ok: $_vb_ep_k, invalid markers: $_vb_ep_i)"
elif [ "$STRICT_EP" = 1 ]; then echo "-- ephemeral-path cites: $_vb_ep_n (FAIL — preserve under sources/probes/b<N>/, waive a non-evidence line with <!-- ephemeral-ok: <reason> -->, or opt out with --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 while the corpus is cleaned, kit #1660)"
else echo "-- ephemeral-path cites: $_vb_ep_n (WARN — exit unchanged; opt-out --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 in force, the default is FAIL, kit #1660)"; fi

# 11. SCRIPTS-MANIFEST (kit #1207) — a preserved script cited under sources/probes/ must be traceable to a row of
#     a `sources/probes/**/SCRIPTS-MANIFEST.md` of the target, and the row's sha256 must equal the file's. Rules:
#       - the corpus has NO manifest at all  -> typed `INFO    no SCRIPTS-MANIFEST` (today's behaviour kept, but
#         never a silent pass), exit unchanged;
#       - the corpus has >= 1 manifest       -> each cited script (ext sh ps1 py java js rb pl bat cmd groovy kts)
#         without a valid row, or whose every row's sha256 differs from the file's actual sha256 (an absent file
#         counts as a difference), is a FAIL (rc=1) with a typed `MANIFEST!` line.
#     A script cite is the cited path matched EXACTLY against the row's resolved location: the first cell is
#     resolved against the directory of ITS OWN manifest (a `sources/…` cell is target-relative; the bare
#     basename inside that same dir also matches). A row in another probes dir never lists this dir's script.
_vb_mf_n=0; _vb_mf_deg=0
# A cite ends at a PATH TERMINATOR (kit #1659): the extension must be followed by an optional sentence period and then a
# character outside the path alphabet (or end of line) — a trailing `\b` let `a.sh.bak` / `run.py.log` backtrack to a
# phantom `a.sh` / `run.py`. The terminator is consumed by -o, so it is stripped (a cite always ends in an alnum).
# VB-MF-CITE
_vb_mf_cites=$(grep -oE 'sources/probes/[A-Za-z0-9_./-]*\.(sh|ps1|py|java|js|rb|pl|bat|cmd|groovy|kts)\.?([^A-Za-z0-9_./-]|$)' "$block" | sed -E 's/[^A-Za-z0-9]+$//' | sort -u)
_vb_mf_files=""; _vb_mf_frc=0
# a `corpus/` target makes find print `corpus//sources/...`; the shared parser canonicalises both spellings (SM-SLASH).
if [ -d "$target/sources/probes" ]; then
  _vb_mf_raw=$(find "$target/sources/probes" -type f -name SCRIPTS-MANIFEST.md 2>/dev/null; echo "@@RC=$?")   # VB-MF-FIND-RC
  _vb_mf_frc=${_vb_mf_raw##*@@RC=}
  _vb_mf_files=$(printf '%s\n' "${_vb_mf_raw%@@RC=*}" | grep . | sort)
fi
echo "-- preserved-script manifest (kit #1207: SCRIPTS-MANIFEST.md rows with sha256) --"
if [ "$_vb_mf_frc" != 0 ]; then
  echo "   ERROR: DEGRADED manifest scan failed (find exit $_vb_mf_frc under $target/sources/probes) — cited scripts NOT manifest-checked"; rc=1; _vb_mf_deg=1
elif [ -z "$_vb_mf_files" ]; then
  echo "   INFO    no SCRIPTS-MANIFEST under $target/sources/probes — preserved-script cites are not manifest-checked ($( [ -n "$_vb_mf_cites" ] && printf '%s' "$_vb_mf_cites" | grep -c . || echo 0) cited)"
elif [ -z "$_vb_mf_cites" ]; then
  echo "   (none — no preserved script cited under sources/probes/; manifests present: $(printf '%s\n' "$_vb_mf_files" | grep -c .))"
else
  _vb_mf_sha=""
  if command -v sha256sum >/dev/null 2>&1; then _vb_mf_sha="sha256sum"; elif command -v shasum >/dev/null 2>&1; then _vb_mf_sha="shasum -a 256"; fi
  if [ -z "$_vb_mf_sha" ]; then
    echo "   ERROR: manifest check DEGRADED (neither sha256sum nor shasum on PATH) — cited scripts NOT checked"; rc=1; _vb_mf_deg=1
  else
    # rows: `<target-relative path>\t<sha256 lowercase>` per valid manifest row, from the SHARED parser (kit #1659,
    # lib/scripts-manifest.sh: 64-hex sha cell required, cell resolved against ITS manifest's dir, `sources/…` cells
    # target-relative, the dir/basename form emitted too). A parse failure is a typed DEGRADED, never "no rows".
    # The helper is loaded HERE, only when a manifest exists AND a preserved script is cited: every other path (the
    # --possibility-sweep, a block citing no script, a corpus with no manifest) never needs lib/. A helper that cannot
    # be loaded is a typed DEGRADED (exit 1), never a quiet pass: the stub makes the parse below fail.
    if ! _vb_load_smlib; then
      echo "   ERROR: DEGRADED manifest helper unavailable (see above) — manifests cannot be parsed"; rc=1
      scripts_manifest_rows() { return 2; }
    fi
    _vb_mf_rows=""; _vb_mf_prc=0
    while IFS= read -r _vb_mf_f; do
      _vb_mf_one=$(scripts_manifest_rows "$target" "$_vb_mf_f") || { _vb_mf_prc=1; break; }   # VB-MF-PARSE
      _vb_mf_rows="$_vb_mf_rows"$'\n'"$_vb_mf_one"
    done <<<"$_vb_mf_files"
    if [ "$_vb_mf_prc" != 0 ]; then
      echo "   ERROR: DEGRADED manifest parse failed (shared parser, under $target/sources/probes) — cited scripts NOT manifest-checked"; rc=1; _vb_mf_deg=1; _vb_mf_cites=""
    fi
    while IFS= read -r _vb_mf_c; do
      [ -z "$_vb_mf_c" ] && continue
      _vb_mf_want=$(awk -F'\t' -v b="$_vb_mf_c" '$1 == b { print $2 }' <<<"$_vb_mf_rows")   # VB-MF-LOOKUP
      if [ -z "$_vb_mf_want" ]; then
        echo "   MANIFEST!  $_vb_mf_c  (no valid SCRIPTS-MANIFEST row for this script — add script|sha256|run/step|block|executed-on|remote-sha256|role)"; rc=1; _vb_mf_n=$((_vb_mf_n+1)); continue
      fi
      _vb_mf_have=ABSENT
      [ -f "$target/$_vb_mf_c" ] && _vb_mf_have=$($_vb_mf_sha "$target/$_vb_mf_c" 2>/dev/null | awk '{print tolower($1)}')
      if grep -qxF "$_vb_mf_have" <<<"$_vb_mf_want"; then   # VB-MF-SHA
        echo "   manifest-ok  $_vb_mf_c  (sha256 matches a row)"
      else
        echo "   MANIFEST!  $_vb_mf_c  (manifest sha256 differs from the file's: ${_vb_mf_have:0:16})"; rc=1; _vb_mf_n=$((_vb_mf_n+1))
      fi
    done <<<"$_vb_mf_cites"
    [ "$_vb_mf_n" -gt 0 ] && echo "-- preserved-script manifest findings: $_vb_mf_n (FAIL)"
  fi
fi

# 12. §14 BACK-POINTER (kit #1962, METHODOLOGY §14 "corrected in BN") — a block that CORRECTS an earlier block must leave a
#     back-pointer on the old one. When one SENTENCE of the checked block carries a correction act (refut* / corrig* / correg* /
#     correcci* / supersed* / the verb forms corrects|corrected|correcting|correction, case-insensitive) AND cites an EARLIER
#     block within 60 characters of it, the cited block's file is resolved in the same corpus and the candidate is reported when
#     that file holds no pointer to the checked block. ADVISORY: the exit code never changes (a missing pointer is a finding for
#     the human to verify by hand; the kit edits nothing, propose-never-apply).
#     --backptr=high (default) prints a per-line `BACKPTR?` only for the HIGH-CONFIDENCE shape (the correction act within 25
#     characters of a keyword cite: `[Block N]` / `Block N` / `Bloque N`); every other candidate is ONE count line
#     (`N low-confidence candidate(s)`). --backptr=all lists them all; --backptr=off skips the section.
#     MEASURED PRECISION (hand-classified sample of the DEFAULT output on the real fleet): 2026-10-07, 1390 real blocks, default mode: 50 per-line candidates, all 50
#     hand-classified, 38 true corrections lacking a pointer = 76% (the first design printed 207 lines at roughly 55%); the low-confidence
#     candidates are counted, not listed. Cost: the section roughly doubles a run (200 blocks: 30 s with --backptr=off, 64-78 s by default).
#     Enumerated cite forms (~/niagara-research + ~/niagara5-research, 1404 files of which 14 are lint fixtures): `[Block N]` ·
#     `Block N` · `Bloque N` · `blockN` / `bloqueN` · `BN` · `Block RN` / `Bloque RN`; a BARE `RN` counts only when the checked
#     block's H1 is `# Block R<n>`. TWO SERIES coexist in one corpus (niagara-reflow-block5 `# Block R5` vs
#     niagara-mental-model-bloque5): a cite carries its series (`R` or numeric), is resolved only against files of that series
#     (the file's H1 decides), and the forward test (a cite of a LATER block is a forward pointer) compares within one series only.
#     A pointer in the OLD block names the checked block's number in the checked block's own series: `B<n>` / `Block <n>` in the
#     numeric series, `R<n>` / `Block R<n>` in the R series (bare `R<n>` is accepted nowhere else: it is a register or revision
#     name), bounded so B11 is not satisfied by B110 / B11a / 5.11.
#     Sentences: paragraphs end at a blank line, a heading, a list item or a table row; fenced code is skipped; a paragraph
#     is split at `. ` / `! ` / `? ` / `; `.
#     NOT a correction act by THIS block (each narrowing came from classifying the fleet sweep by hand; each has a tooth and each
#     suppressed sentence is COUNTED in the summary as skipped: neg · self · passive · noun · list; corrector and far count each dropped CITE):
#     the bare adjective "correct" / "correctly" / "correcto", the noun "corrigendum" (noun), negations ("No §14 correction",
#     "Nothing here refutes", "corrects nothing"; "not only/just corrects" is NOT a negation) (neg), self-corrections (self), a
#     third-party correction narrated passively ("was corrected") (passive), the CORRECTOR itself ("corrected by B96" /
#     "corregido en B4" name the block that fixed it) (corrector), a cite more than 60 characters from the act (far), and
#     cross-reference-list sentences: 3+ distinct blocks, or 2 under a "Connects"/"Related"/"see also" lead or with 2+ " · "
#     separators (list). Cites of the block itself or of a LATER block of the same series are skipped and counted as forward=N.
#     Candidates: canonical block files (lib/block-files.sh), listed ONCE per run, directly in the block's dir, else in
#     target-dir, same file-name prefix first. Typed non-verdicts (never silent): not found (INFO) · several candidates
#     (BACKPTR-AMBIGUOUS) · unreadable / failed scan / helper missing (DEGRADED) — none of them moves the exit code.
_vb_bp_load() {
  local src="${BASH_SOURCE[0]}" n=0 lt d here
  while [ -L "$src" ] && [ "$n" -lt 40 ]; do
    n=$((n + 1)); lt="$(readlink -- "$src")" || return 1
    case "$lt" in /*) src="$lt" ;; *) d="${src%/*}"; [ "$d" = "$src" ] && d=.; src="$d/$lt" ;; esac
  done
  d="${src%/*}"; [ "$d" = "$src" ] && d=.
  here="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
  [ -f "$here/lib/block-files.sh" ] || return 1
  # shellcheck source=lib/block-files.sh
  . "$here/lib/block-files.sh"
  declare -F block_file_filter >/dev/null 2>&1
}
# _vb_bp_pairs <self-number>: one `C<TAB>line<TAB>series<TAB>N<TAB>conf<TAB>sentence-excerpt` per distinct earlier-block cite sitting in
# a correction sentence (series R|N, conf high|low), then one `S<TAB>sentences<TAB>forward<TAB>list<TAB>neg<TAB>self<TAB>passive<TAB>noun<TAB>corrector<TAB>far<TAB>rmode`
# trailer (correction sentences seen, cites skipped as forward, then the sentences suppressed by each filter, then 1 when the block is R-numbered).
_vb_bp_pairs() {
  awk -v self="$1" '
    function isw(c) { return c ~ /[A-Za-z0-9_]/ }
    function flush(   rest, sent) {
      if (para == "") return
      rest = para
      while (rest != "") {
        if (match(rest, /[.!?;]+[[:space:]]+/)) { sent = substr(rest, 1, RSTART - 1); rest = substr(rest, RSTART + RLENGTH) }
        else { sent = rest; rest = "" }
        scan(sent)
      }
      para = ""
    }
    # blank(s, re): s with every match of re overwritten by spaces of the SAME length (positions stay comparable).
    function blank(s, re,   out, pad) {
      out = ""
      while (match(s, re)) { pad = sprintf("%" RLENGTH "s", ""); out = out substr(s, 1, RSTART - 1) pad; s = substr(s, RSTART + RLENGTH) }
      return out s
    }
    # neuter(s, re): the first 3 characters of every match become "xxx" (same length) so a later pattern cannot see them.
    function neuter(s, re,   out) {
      out = ""
      while (match(s, re)) { out = out substr(s, 1, RSTART - 1) "xxx" substr(s, RSTART + 3, RLENGTH - 3); s = substr(s, RSTART + RLENGTH) }
      return out s
    }
    function scan(sent,   low, off, rest, tok, pre, post, num, keep, ex, nd, i, dn, ds, dc, k, kx, key, vs, vl, n, cs, gap, mg, ctx, kw, ser, cdrop, fdrop, conf, VERB, selfser, bvs, bvl, before, tail) {
      VERB = "refut|corrig|correg|correcci|correct(s|ed|ing|ion)|supersed"   # BP-VERBS: the bare word "correct" is mostly the adjective ("the correct template") and "correctly" the adverb
      if (tolower(sent) !~ VERB) return
      low = " " tolower(sent)   # the leading space is the left word boundary of the negation words below; stripped again before positions are used
      low = blank(low, "corrigend[a-z]*")   # BP-CORRIGEND: the NOUN "corrigendum" labels a correction note, it is not a correction act (fleet sweep, kit #1962)
      if (low !~ VERB) { c_noun++; return }
      low = blank(low, "[^a-z](no|not a|without|ninguna?)[[:space:]]+(§14[ -]?[a-z]*[[:space:]]+)?([^[:space:]]+[[:space:]]+)?([^[:space:]]+[[:space:]]+)?(correction|correcci.n|refut[a-z]*)")   # BP-NEG: "No §14 correction" asserts the absence
      low = blank(neuter(low, "[^a-z]not (only|just|merely)"), "[^a-z](nothing|without|never|rather than|instead of|not|no|nada)[[:space:]]+([a-z]+[[:space:]]+)?(here[[:space:]]+)?(correct|refut|supersed|corrig)[a-z]*")   # BP-NEG2: "Nothing here refutes", "without correcting"; neuter() first overwrites the boundary character and the "no" of "not only/just/merely" with xxx (same length), so the "not" alternative cannot match there and the correcting verb after it survives
      low = blank(low, "(correct|refut|supersed|corrig)[a-z]*[[:space:]]+(nothing|nada|no[[:space:]]+(earlier|prior|previous))")   # BP-NEG3: "corrects nothing in B21"
      if (low !~ VERB) { c_neg++; return }
      low = blank(low, "self-correct[a-z]*|auto-?correc[a-z]*")   # BP-SELF: a block correcting ITSELF corrects no earlier block
      if (low !~ VERB) { c_self++; return }
      low = blank(low, "[^a-z](was|were|been|already|got|is|are|be)[[:space:]]+(also[[:space:]]+)?(corrected|refuted|superseded)")   # BP-PASSIVE: a third-party correction, narrated here
      if (low !~ VERB) { c_passive++; return }
      low = substr(low, 2)
      nsent++
      selfser = rmode ? "R" : "N"
      rest = sent; off = 0; nd = 0; cdrop = 0; fdrop = 0; split("", dn); split("", ds); split("", dc); split("", k)
      while (match(rest, /([Bb]lock|[Bb]loque) ?R?[0-9]+|B[0-9]+|R[0-9]+/)) {
        tok = substr(rest, RSTART, RLENGTH)
        cs = off + RSTART
        pre = (cs > 1) ? substr(sent, cs - 1, 1) : ""
        post = substr(rest, RSTART + RLENGTH, 1)
        off += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
        keep = 1
        if (pre != "" && isw(pre)) keep = 0   # BP-PRETOK: no cite glued to a preceding word (AB5, xR5)
        if (tok ~ /^[BR][0-9]/ && post ~ /[A-Za-z_]/) keep = 0   # BP-POSTTOK: no cite glued to a following word (B5x)
        if (tok ~ /^R[0-9]/ && !rmode) keep = 0   # BP-RMODE: a bare RN is a block cite only in an R-numbered corpus
        if (!keep) continue
        kw = (tok ~ /^[Bb]lo/)
        ser = (tok ~ /R[0-9]+$/) ? "R" : "N"
        # the CORRECTOR, not the corrected: "corrected by B96" / "corregido en [Block 11]" name the block that fixed it
        ctx = substr(low, (cs > 40 ? cs - 40 : 1), (cs > 40 ? 40 : cs - 1))
        if (ctx ~ /(corrected|refuted|superseded|corregid[oa]s?|refutad[oa]s?|supersedid[oa]s?)[[:space:]]+(by|in|en|por)[[:space:]]*[\[(*]*$/) { c_corr++; continue }   # BP-CORRECTOR: counted per dropped cite
        # proximity: the nearest correction act, in characters between it and the cite
        mg = 99999; n = low; bvs = 0; bvl = 0
        while (match(n, VERB)) {
          vs = length(low) - length(n) + RSTART; vl = RLENGTH
          gap = (cs > vs) ? cs - (vs + vl) : vs - (cs + length(tok))
          if (gap < mg) { mg = gap; bvs = vs; bvl = vl }
          n = substr(n, RSTART + RLENGTH)
        }
        if (mg > 60) { c_far++; continue }   # BP-PROXIMITY: a verb further away belongs to another clause of a long sentence
        # HIGH confidence = a keyword cite with the act within 25 characters AND the act BEFORE the cite ("Corrección al Bloque 28", "corrects
        # [Block 5]"), or AFTER it only as a list-item tail ("[Block 21] — corregido en …"). An act after the cite otherwise belongs to the
        # cite ("[Block 95] §95.9 correction", "[Block 790] §14 corrections", "[Block 476] … supersedes it"): the cite is the corrector.
        before = (bvs + bvl <= cs)
        tail = before ? "" : substr(low, cs + length(tok), bvs - (cs + length(tok)))
        conf = (kw && mg <= 25 && (before || tail ~ /^(\]|\*|\)|[[:space:]]|:|-|—|–)*$/)) ? "high" : "low"   # BP-CONF
        num = tok; gsub(/[^0-9]/, "", num); num += 0
        key = ser SUBSEP num
        if (!(key in k)) { nd++; k[key] = nd; ds[nd] = ser; dn[nd] = num; dc[nd] = conf }
        else if (conf == "high") dc[k[key]] = "high"
      }
      if (nd == 0) return
      # a sentence naming 3+ distinct blocks, or 2 under a "Connects" / "Related" lead or with 2+ " · " separators, is a cross-reference list
      # ("Connects [B1] · [B2] · ... corrected"), not a correction of a specific block: skipped and COUNTED (fleet sweep, kit #1962).
      if (nd >= 3 || (nd >= 2 && (low ~ /connects|conecta|related|see also/ || gsub(/ · /, "&", sent) >= 2))) { listed++; return }   # BP-LIST
      for (i = 1; i <= nd; i++) {
        if (ds[i] == selfser && dn[i] >= self) { fwd++; continue }   # BP-FORWARD: same series only; R5 and 5 are different blocks
        key = ds[i] SUBSEP dn[i]
        # one record per (series, block) for the WHOLE block: confidence is the MAX over its sentences (a later high-confidence sentence upgrades
        # an earlier low one, and then also supplies the line and excerpt); emitted in first-seen order at END
        ex = sent; gsub(/[\t"]+/, " ", ex); gsub(/^[[:space:]]+/, "", ex); ex = substr(ex, 1, 110)
        if (!(key in seen)) { seen[key] = ++ne; eline[ne] = firstline; eser[ne] = ds[i]; enum[ne] = dn[i]; econf[ne] = dc[i]; eex[ne] = ex }
        else if (dc[i] == "high" && econf[seen[key]] != "high") { econf[seen[key]] = "high"; eline[seen[key]] = firstline; eex[seen[key]] = ex }   # BP-MAXCONF
      }
    }
    /^```/ { fence = !fence; flush(); next }
    fence { next }
    /^[[:space:]]*$/ { flush(); next }
    /^#/ { flush(); if (!hseen) { hseen = 1; if ($0 ~ /^#+[[:space:]]*(Block|Bloque)[[:space:]]+R[0-9]/) rmode = 1 }; para = $0; firstline = NR; flush(); next }
    /^[[:space:]]*([-*+]|[0-9]+[.)]|\|)/ { flush(); para = $0; firstline = NR; next }
    { if (para == "") firstline = NR; para = (para == "" ? $0 : para " " $0) }
    END { flush(); for (i = 1; i <= ne; i++) print "C\t" eline[i] "\t" eser[i] "\t" enum[i] "\t" econf[i] "\t" eex[i]; print "S\t" (nsent + 0) "\t" (fwd + 0) "\t" (listed + 0) "\t" (c_neg + 0) "\t" (c_self + 0) "\t" (c_passive + 0) "\t" (c_noun + 0) "\t" (c_corr + 0) "\t" (c_far + 0) "\t" (rmode + 0) }
  ' "$block"
}
# _vb_bp_fser <file>: prints R when the file H1 is `# Block R<n>` (the R series), else N; rc 2 when the file cannot be read.
_vb_bp_fser() {
  local h rc
  h="$(grep -m1 -E '^#' -- "$1" 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 2 ]; then return 2; fi
  if [[ "$h" =~ ^#+[[:space:]]*(Block|Bloque)[[:space:]]+R[0-9] ]]; then echo R; else echo N; fi
}
_vb_bp_w=0; _vb_bp_i=0; _vb_bp_a=0; _vb_bp_d=0; _vb_bp_ok=0; _vb_bp_low=0
echo "-- §14 back-pointer (kit #1962: a block that corrects an earlier block must be pointed back to from it; advisory, exit unchanged) --"
_vb_bp_base="$(basename "$block")"
_vb_bp_re='^(.*-)?(block|bloque)([0-9]+)(-[[:alnum:]_-]+)?\.md$'
if [ "$BACKPTR_MODE" = off ]; then
  echo "   (back-pointer check off — --backptr=off)"
elif ! [[ "$_vb_bp_base" =~ $_vb_bp_re ]]; then
  echo "   (back-pointer check skipped — '$_vb_bp_base' is not a canonical block file name: <prefix>-(block|bloque)<N>[-slug].md)"
elif ! _vb_bp_load; then
  echo "   DEGRADED backptr: helper lib/block-files.sh unavailable — back-pointers NOT checked"; _vb_bp_d=$((_vb_bp_d+1))
else
  _vb_bp_pfx="${BASH_REMATCH[1]}"; _vb_bp_self=$((10#${BASH_REMATCH[3]}))
  _vb_bp_dirs=()
  for _vb_bp_x in "$(dirname "$block")" "$target"; do
    _vb_bp_x="$(cd -P -- "$_vb_bp_x" 2>/dev/null && pwd -P)" || continue
    [ "${_vb_bp_dirs[0]:-}" = "$_vb_bp_x" ] && continue
    _vb_bp_dirs+=("$_vb_bp_x")
  done
  _vb_bp_pairs_out="$(_vb_bp_pairs "$_vb_bp_self")"; _vb_bp_prc=$?
  if [ "$_vb_bp_prc" != 0 ] || [ "${#_vb_bp_dirs[@]}" -eq 0 ]; then
    echo "   DEGRADED backptr: the sentence scan or the candidate directory failed (awk exit $_vb_bp_prc, ${#_vb_bp_dirs[@]} directories) — back-pointers NOT checked"; _vb_bp_d=$((_vb_bp_d+1))
    _vb_bp_pairs_out=""
  fi
  # the canonical block files of each directory, listed ONCE per run (parallel arrays: path, directory index, number, prefix)
  _vb_bp_fl=(); _vb_bp_fdx=(); _vb_bp_fnum=(); _vb_bp_fpf=(); _vb_bp_dbad=()
  if [ -n "$_vb_bp_pairs_out" ]; then
    for _vb_bp_di in "${!_vb_bp_dirs[@]}"; do
      _vb_bp_ls="$(find "${_vb_bp_dirs[$_vb_bp_di]}" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort; echo "@@RC=${PIPESTATUS[0]}")"
      if [ "${_vb_bp_ls##*@@RC=}" != 0 ]; then _vb_bp_dbad[_vb_bp_di]=1; continue; fi
      _vb_bp_ls="$(printf '%s\n' "${_vb_bp_ls%@@RC=*}" | block_file_filter)"; _vb_bp_frc=$?
      if [ "$_vb_bp_frc" -ge 2 ]; then _vb_bp_dbad[_vb_bp_di]=1; continue; fi
      while IFS= read -r _vb_bp_f; do
        [ -z "$_vb_bp_f" ] && continue
        [[ "${_vb_bp_f##*/}" =~ $_vb_bp_re ]] || continue
        _vb_bp_fl+=("$_vb_bp_f"); _vb_bp_fdx+=("$_vb_bp_di"); _vb_bp_fnum+=("$((10#${BASH_REMATCH[3]}))"); _vb_bp_fpf+=("${BASH_REMATCH[1]}")
      done <<<"$_vb_bp_ls"
    done
  fi
  # the S trailer first: the checked block's series decides the pointer form and the labels
  _vb_bp_ns=0; _vb_bp_fw=0; _vb_bp_sl=0; _vb_bp_sn=0; _vb_bp_ss=0; _vb_bp_sp=0; _vb_bp_so=0; _vb_bp_sc=0; _vb_bp_sf=0; _vb_bp_rm=0
  while IFS=$'\t' read -r _vb_bp_t _vb_bp_v1 _vb_bp_v2 _vb_bp_v3 _vb_bp_v4 _vb_bp_v5 _vb_bp_v6 _vb_bp_v7 _vb_bp_v8 _vb_bp_v9 _vb_bp_v10; do
    [ "$_vb_bp_t" = "S" ] || continue
    _vb_bp_ns="$_vb_bp_v1"; _vb_bp_fw="$_vb_bp_v2"; _vb_bp_sl="$_vb_bp_v3"; _vb_bp_sn="$_vb_bp_v4"; _vb_bp_ss="$_vb_bp_v5"
    _vb_bp_sp="$_vb_bp_v6"; _vb_bp_so="$_vb_bp_v7"; _vb_bp_sc="$_vb_bp_v8"; _vb_bp_sf="$_vb_bp_v9"; _vb_bp_rm="$_vb_bp_v10"
  done <<<"$_vb_bp_pairs_out"
  if [ "$_vb_bp_rm" = 1 ]; then
    _vb_bp_slab="R$_vb_bp_self"
    # R series: R<n> or Block R<n>; a bare R<n> is accepted ONLY here (elsewhere it is a register or revision name)
    _vb_bp_ptr="(^|[^A-Za-z0-9_])((([Bb]lock|[Bb]loque) ?)?R)0*${_vb_bp_self}([^0-9A-Za-z_]|\$)"   # BP-BOUNDARY
  else
    _vb_bp_slab="B$_vb_bp_self"
    _vb_bp_ptr="(^|[^A-Za-z0-9_])(([Bb]lock|[Bb]loque) ?|B)0*${_vb_bp_self}([^0-9A-Za-z_]|\$)"   # BP-BOUNDARY
  fi
  while IFS=$'\t' read -r _vb_bp_t _vb_bp_l _vb_bp_ser _vb_bp_n _vb_bp_conf _vb_bp_ex; do
    [ "$_vb_bp_t" = "C" ] || continue
    _vb_bp_cl="$_vb_bp_n"; [ "$_vb_bp_ser" = R ] && _vb_bp_cl="R$_vb_bp_n"
    # resolve the cited block: same-prefix canonical files first, then any prefix; per directory, only files of the cited SERIES
    _vb_bp_cand=(); _vb_bp_scanbad=0; _vb_bp_state=""; _vb_bp_msg=""
    for _vb_bp_pass in same any; do
      for _vb_bp_di in "${!_vb_bp_dirs[@]}"; do
        if [ "${_vb_bp_dbad[$_vb_bp_di]:-0}" = 1 ]; then _vb_bp_scanbad=1; continue; fi
        for _vb_bp_fi in "${!_vb_bp_fl[@]}"; do
          [ "${_vb_bp_fdx[$_vb_bp_fi]}" = "$_vb_bp_di" ] || continue
          [ "${_vb_bp_fnum[$_vb_bp_fi]}" = "$_vb_bp_n" ] || continue
          if [ "$_vb_bp_pass" = same ] && [ "${_vb_bp_fpf[$_vb_bp_fi]}" != "$_vb_bp_pfx" ]; then continue; fi   # BP-PREFIX
          _vb_bp_fs="$(_vb_bp_fser "${_vb_bp_fl[$_vb_bp_fi]}")"; _vb_bp_frc=$?
          # an unreadable file has no knowable series: it stays a candidate so the unreadable state is typed below, never dropped
          if [ "$_vb_bp_frc" -eq 0 ] && [ "$_vb_bp_fs" != "$_vb_bp_ser" ]; then continue; fi   # BP-SERIES
          _vb_bp_cand+=("${_vb_bp_fl[$_vb_bp_fi]}")
        done
        [ "${#_vb_bp_cand[@]}" -gt 0 ] && break
      done
      [ "${#_vb_bp_cand[@]}" -gt 0 ] && break
    done
    if [ "${#_vb_bp_cand[@]}" -eq 0 ]; then
      if [ "$_vb_bp_scanbad" = 1 ]; then   # BP-SCANBAD
        _vb_bp_state=degraded; _vb_bp_msg="   DEGRADED backptr: line $_vb_bp_l: block $_vb_bp_cl — the candidate scan under ${_vb_bp_dirs[*]} failed; back-pointer NOT checked"
      else
        _vb_bp_state=notfound; _vb_bp_msg="   INFO    backptr: line $_vb_bp_l cites block $_vb_bp_cl but its block file is not found under ${_vb_bp_dirs[*]} — back-pointer NOT checked"   # BP-NOTFOUND
      fi
    elif [ "${#_vb_bp_cand[@]}" -gt 1 ]; then   # BP-AMBIG
      _vb_bp_names=""; for _vb_bp_f in "${_vb_bp_cand[@]}"; do _vb_bp_names="$_vb_bp_names${_vb_bp_names:+, }${_vb_bp_f##*/}"; done
      _vb_bp_state=ambig; _vb_bp_msg="   BACKPTR-AMBIGUOUS  line $_vb_bp_l: block $_vb_bp_cl matches ${#_vb_bp_cand[@]} files ($_vb_bp_names) — back-pointer NOT checked; disambiguate by hand"
    else
      _vb_bp_old="${_vb_bp_cand[0]}"
      if [ ! -r "$_vb_bp_old" ]; then   # BP-UNREADABLE
        _vb_bp_state=degraded; _vb_bp_msg="   DEGRADED backptr: line $_vb_bp_l: block $_vb_bp_cl (${_vb_bp_old##*/}) is unreadable — back-pointer NOT checked"
      elif grep -Eq "$_vb_bp_ptr" "$_vb_bp_old" 2>/dev/null; then   # BP-POINTER
        _vb_bp_state=ok; _vb_bp_msg="   backptr-ok  line $_vb_bp_l: block $_vb_bp_cl (${_vb_bp_old##*/}) points back to $_vb_bp_slab"
      else
        _vb_bp_grc=$?
        if [ "$_vb_bp_grc" -ge 2 ]; then   # BP-GREPRC
          _vb_bp_state=degraded; _vb_bp_msg="   DEGRADED backptr: line $_vb_bp_l: block $_vb_bp_cl (${_vb_bp_old##*/}) could not be read by grep (exit $_vb_bp_grc) — back-pointer NOT checked"
        else
          _vb_bp_state=missing; _vb_bp_msg="   BACKPTR?  line $_vb_bp_l: possible correction of block $_vb_bp_cl (${_vb_bp_old##*/}); verify by hand, then consider a back-pointer to $_vb_bp_slab in ${_vb_bp_old##*/} (§14; advisory, exit unchanged) — sentence: \"$_vb_bp_ex\""
        fi
      fi
    fi
    case "$_vb_bp_state" in
      missing) _vb_bp_w=$((_vb_bp_w+1)) ;; ok) _vb_bp_ok=$((_vb_bp_ok+1)) ;; ambig) _vb_bp_a=$((_vb_bp_a+1)) ;;
      notfound) _vb_bp_i=$((_vb_bp_i+1)) ;; degraded) _vb_bp_d=$((_vb_bp_d+1)) ;;
    esac
    # default (high): per-line output only for the high-confidence shape; every other candidate is counted, never dropped
    # not-found / ambiguous / degraded are typed non-verdicts: printed as their own lines in EVERY mode, whatever the confidence
    if [ "$BACKPTR_MODE" = all ] || [ "$_vb_bp_conf" = high ] || { [ "$_vb_bp_state" != missing ] && [ "$_vb_bp_state" != ok ]; }; then echo "$_vb_bp_msg"   # BP-TYPED
    elif [ "$_vb_bp_state" = missing ]; then _vb_bp_low=$((_vb_bp_low+1)); fi
  done <<<"$_vb_bp_pairs_out"
  _vb_bp_skipped="forward=$_vb_bp_fw neg=$_vb_bp_sn self=$_vb_bp_ss passive=$_vb_bp_sp noun=$_vb_bp_so corrector=$_vb_bp_sc far=$_vb_bp_sf list=$_vb_bp_sl"
  if [ "$((_vb_bp_w + _vb_bp_i + _vb_bp_a + _vb_bp_d + _vb_bp_ok))" -eq 0 ]; then
    echo "   (none — no correction sentence cites an earlier block; correction sentences scanned: $_vb_bp_ns; skipped: $_vb_bp_skipped)"
  else
    echo "-- back-pointer: $_vb_bp_w possibly missing · $_vb_bp_ok present · $_vb_bp_a ambiguous · $_vb_bp_i not found · $_vb_bp_d degraded (correction sentences: $_vb_bp_ns; skipped: $_vb_bp_skipped) — advisory, exit unchanged"
    if [ "$_vb_bp_low" -gt 0 ]; then
      echo "-- back-pointer: $_vb_bp_low low-confidence candidate(s) (--backptr=all to list)"
    fi
  fi
fi

echo "== exit $rc =="
exit $rc
