#!/usr/bin/env bash
# scrub-issue-text.test.sh — regression harness for lib/scrub-issue-text.sh (kit issue #1707).
#
# Covers: each redaction class (home paths in every rooted form, emails, credential-named KEY=VALUE,
# credential-shaped tokens); the allowlist (repo-relative paths, $RESEARCH_HOME, URLs, issue refs,
# non-credential NAME=value, word-internal look-alikes); the typed `redactions: N` count (matches the
# replacements made; `redactions: 0` for clean and for empty input; idempotent); purity (empty
# environment, silent stderr); and the fleet-measured real shapes.
#
# Usage: scrub-issue-text.test.sh                (run the suite)
#        scrub-issue-text.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/scrub-issue-text.sh"
[ -f "$SUT" ] || { echo "FATAL: lib under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FATAL: awk not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== scrub-issue-text.test.sh =="

# shellcheck source=../lib/scrub-issue-text.sh
# shellcheck source=../lib/scrub-issue-text.sh
. "$SUT"
declare -F scrub_issue_text >/dev/null 2>&1 && declare -F scrub_issue_text_count >/dev/null 2>&1 \
  || { echo "FATAL: scrub_issue_text / scrub_issue_text_count not defined after sourcing $SUT" >&2; exit 2; }

# chk <label> <input> <expected-scrubbed> <expected-count>
chk() {
  local label="$1" in="$2" want="$3" wantn="$4" got gotn
  got="$(printf '%s\n' "$in" | scrub_issue_text 2>&1)"
  gotn="$(printf '%s\n' "$in" | scrub_issue_text_count 2>&1)"
  if [ "$got" = "$want" ] && [ "$gotn" = "redactions: $wantn" ]; then ok "$label"
  else no "$label" "got=[$got] count=[$gotn] want=[$want] n=$wantn"; fi
}

# --- redaction classes ---------------------------------------------------------------------------
chk "1 home path (/home/<u>/...) → <path>, tail and user gone" 'see /home/bob/proj/x.sh:12 now' 'see <path> now' 1
chk "2 /Users/<u>/..." 'at /Users/al/q/z' 'at <path>' 1
chk "3 /mnt/c/Users/<u>/..." 'at /mnt/c/Users/al/q' 'at <path>' 1
chk "4 C:\\Users\\<u>\\..." 'at C:\Users\bob\x\y.txt end' 'at <path> end' 1
chk "5 /root/..." 'at /root/.ssh/id' 'at <path>' 1
chk "6 email" 'ping a.b+c@ex-ample.co.uk please' 'ping <email> please' 1
chk "7 credential-named KEY=VALUE keeps the key" 'run GH_TOKEN=abc123 now' 'run GH_TOKEN=<redacted> now' 1
chk "8 ghp_ token" 'tok ghp_abcdefghij1234 end' 'tok <redacted> end' 1
chk "9 github_pat_ token" 'tok github_pat_11AAAA_bbbCCC end' 'tok <redacted> end' 1
chk "10 sk- key" 'k sk-abcdefghijklmnop end' 'k <redacted> end' 1
chk "11 AWS AKIA id" 'k AKIAABCDEFGHIJKLMNOP end' 'k <redacted> end' 1
chk "12 several classes on one line, three lines" $'/home/a/b x@y.io\nGH_TOKEN=z\nclean' $'<path> <email>\nGH_TOKEN=<redacted>\nclean' 3
chk "13 boundary forms: backtick, paren, equals, comma" 'a `/home/u/x`, (/home/u/y) p=/home/u/z' 'a `<path>`, (<path>) p=<path>' 3

# --- allowlist -----------------------------------------------------------------------------------
chk "14 repo-relative path untouched" 'edit research-sdd/toolbelt/home/x.sh' 'edit research-sdd/toolbelt/home/x.sh' 0
chk "15 \$RESEARCH_HOME and \${RESEARCH_HOME} untouched" 'in $RESEARCH_HOME/x and ${RESEARCH_HOME}/y' 'in $RESEARCH_HOME/x and ${RESEARCH_HOME}/y' 0
chk "16 GitHub URL with /home/ segment untouched" 'see https://github.com/o/r/home/x and #1707 o/r#12' 'see https://github.com/o/r/home/x and #1707 o/r#12' 0
chk "17 non-credential NAME=value untouched" 'MUTANT_SYNTAX=none STAGE_RETRO_ISSUES_LIST_LIMIT=5 NIAGARA_HOME=mutation' 'MUTANT_SYNTAX=none STAGE_RETRO_ISSUES_LIST_LIMIT=5 NIAGARA_HOME=mutation' 0
chk "18 /rootfs/x is not /root/" 'at /rootfs/x and /usr/bin/env' 'at /rootfs/x and /usr/bin/env' 0
chk "19 word-internal token look-alike untouched" 'xghp_abcdefgh and task-abcdefghijklmnop' 'xghp_abcdefgh and task-abcdefghijklmnop' 0
chk "20 @handle and a bare @ are not emails" 'thanks @angeles725, a @ b' 'thanks @angeles725, a @ b' 0

# --- count / idempotence / empties ----------------------------------------------------------------
chk "21 clean input → redactions: 0" 'nothing private here' 'nothing private here' 0
if [ "$(scrub_issue_text_count </dev/null)" = "redactions: 0" ] && [ -z "$(scrub_issue_text </dev/null)" ]; then
  ok "22 empty input → empty text and redactions: 0 (looked, found nothing)"
else no "22 empty input"; fi
dirty=$'a /home/u/x b@c.io\nSECRET_KEY=v ghp_abcdefghij'
once="$(printf '%s\n' "$dirty" | scrub_issue_text)"
twice="$(printf '%s\n' "$once" | scrub_issue_text)"
if [ "$once" = "$twice" ] && [ "$(printf '%s\n' "$once" | scrub_issue_text_count)" = "redactions: 0" ]; then
  ok "23 idempotent: scrubbing scrubbed text changes nothing, counts 0"
else no "23 idempotent" "once=[$once] twice=[$twice]"; fi
chk "24 an already-redacted KEY=<redacted> is not re-counted" 'GH_TOKEN=<redacted>' 'GH_TOKEN=<redacted>' 0
chk "25 count equals replacements (4 distinct)" 'a /home/u/x b@c.io GH_TOKEN=1 ghp_abcdefghij' 'a <path> <email> GH_TOKEN=<redacted> <redacted>' 4

# --- purity --------------------------------------------------------------------------------------
purity_out="$(env -i "$BASH_BIN" -c '. "$1"; printf "%s\n" "/home/u/x a@b.io" | scrub_issue_text' _ "$SUT" 2>"$ROOT/purity.err")"
if [ "$purity_out" = "<path> <email>" ] && [ ! -s "$ROOT/purity.err" ]; then
  ok "26 pure: works with an empty environment, stderr silent"
else no "26 purity" "out=[$purity_out] err=[$(cat "$ROOT/purity.err")]"; fi
# shellcheck source=../lib/scrub-issue-text.sh
. "$SUT"
declare -F scrub_issue_text >/dev/null && ok "27 sourcing twice is safe (idempotent definition)" || no "27 re-source"

# --- fleet-measured real shape (retros/2026-08-03-document-unregistered-bootstrap-incident.md) ------
chk "28 fleet shape: prose path in backticks" 'DOCUMENT mode received the arbitrary project path `/home/cristian/TRADINGVIEW`, which was not yet' 'DOCUMENT mode received the arbitrary project path `<path>`, which was not yet' 1

# =====================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: scrub-issue-text.sh --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MUT="$ROOT/mut"; mkdir -p "$MUT"
  CRASH='integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError|awk: |command not found'
  # tooth <label> <input> <good-has> <sed-expr...>: the mutant must keep the raw text the original removed.
  tooth() {
    local label="$1" in="$2" rx="$3"; shift 3
    local m="$MUT/m$((++mi)).sh"
    if mutant_chain "$label" "$SUT" "$m" "$@"; then
      if mutant_tooth "$label" 0 0 "$m" --good-has "$rx" --bad-lacks "$rx|$CRASH" -- \
           "$BASH_BIN" -c '. "$1"; printf "%s\n" "$2" | "${3:-scrub_issue_text}"' _ @SUT@ "$in" "$TFN"; then pass=$((pass+1)); else fail=$((fail+1)); fi
    else fail=$((fail+1)); fi
  }
  mi=0; TFN=scrub_issue_text
  tooth "T-path-off: home path rule disabled → raw path leaks" 'at /home/bob/x end' 'at <path> end' 's/while (bmatch(line)) {/while (0) {/'
  tooth "T-home-alt: /home alternative dead" 'at /home/bob/x end' 'at <path> end' 's#(/home/\[#(/hxme/[#'
  tooth "T-users-alt: /Users alternative dead" 'at /Users/al/q end' 'at <path> end' 's#|/Users/#|/Uxers/#'
  tooth "T-mnt-alt: /mnt/<d>/Users alternative dead" 'at /mnt/c/Users/al/q end' 'at <path> end' 's#/mnt/#/mxt/#'
  tooth "T-win-alt: C:\\Users alternative dead" 'at C:\Users\bob\x end' 'at <path> end' 's#\[A-Za-z\]:\[#[A-Za-z]X[#'
  tooth "T-root-alt: /root/ alternative dead" 'at /root/.ssh/id end' 'at <path> end' 's#|/root/#|/rxxt/#'
  tooth "T-boundary: boundary check off → URL /home/ segment mangled" 'see https://g.com/o/r/home/x ok' 'https://g.com/o/r/home/x ok' 's/if (st + off == 1 ||/if (1 ||/'
  tooth "T-email-off: email rule dead" 'ping a@ex.com ok' 'ping <email> ok' 's/\[A-Za-z0-9._%+-\]+@/NEVER_AT_NEVER@/'
  for kw in SECRET TOKEN PASSWORD PASSWD CREDENTIAL APIKEY API_KEY PRIVATE_KEY ACCESS_KEY AUTH COOKIE BEARER SESSION; do
    tooth "T-kv-$kw: credential keyword $kw dropped → value leaks" "X_${kw}=hunter2 z" "X_${kw}=<redacted> z" "s/\\([(|]\\)$kw\\([|)]\\)/\\1ZZ_NOPE\\2/"
  done
  tooth "T-ghp: ghp_ shape dead" 'tok ghp_abcdefghij end' 'tok <redacted> end' 's/gh\[pousr\]_/gX[pousr]_/'
  tooth "T-pat: github_pat_ shape dead" 'tok github_pat_11AAAA end' 'tok <redacted> end' 's/|github_pat_\[/|github_pXt_[/'
  tooth "T-sk: sk- shape dead" 'k sk-abcdefghijklmnop end' 'k <redacted> end' 's/|sk-\[/|sX-[/'
  tooth "T-akia: AKIA shape dead" 'k AKIAABCDEFGHIJKLMNOP end' 'k <redacted> end' 's/|AKIA\[/|AKXA[/'
  tooth "T-wordint: word-internal guard off → xghp_ is redacted" 'a xghp_abcdefgh b' 'a xghp_abcdefgh b' 's/if (RSTART > 1 \&\& substr(line, RSTART - 1, 1)/if (0 \&\& substr(line, RSTART - 1, 1)/'
  TFN=scrub_issue_text_count
  tooth "T-redact-guard: already-redacted guard off → re-counted" 'GH_TOKEN=<redacted>' 'redactions: 0' 's/ \&\& tok != k "=<redacted>"//'
  TFN=scrub_issue_text
  # count tooth: the path rule stops incrementing → the typed count lies
  m="$MUT/mcount.sh"
  if mutant_chain "T-count: path rule stops counting" "$SUT" "$m" 's/"<path>"; line = substr(line, RSTART + RLENGTH); count++/"<path>"; line = substr(line, RSTART + RLENGTH)/'; then
    if mutant_tooth "T-count: path rule stops counting → count reads 0" 0 0 "$m" --good-has 'redactions: 1' --bad-lacks "redactions: 1|$CRASH" -- \
         "$BASH_BIN" -c '. "$1"; printf "%s\n" "/home/u/x" | scrub_issue_text_count' _ @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
  else fail=$((fail+1)); fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
