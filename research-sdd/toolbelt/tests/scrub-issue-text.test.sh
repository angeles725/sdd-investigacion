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

# --- quoted / lowercase credential assignments; widened path boundaries (RDD round 1) ---------------
chk "29 double-quoted credential value: redacted INSIDE the quotes" 'run GH_TOKEN="abc123" now' 'run GH_TOKEN="<redacted>" now' 1
chk "30 single-quoted value after export" "export API_KEY='xyz' ok" "export API_KEY='<redacted>' ok" 1
chk "31 backtick-quoted value" 'use `PASSWORD=pw` ok' 'use `PASSWORD=<redacted>` ok' 1
chk "32 lowercase credential key" 'set api_key=zz and session=abc' 'set api_key=<redacted> and session=<redacted>' 2
chk "33 author=/AUTHOR= are not credentials" 'author=bob AUTHOR=bob' 'author=bob AUTHOR=bob' 0
chk "34 key: value prose is not matched (documented)" 'password: hunter2 token: the parser' 'password: hunter2 token: the parser' 0
chk "35 empty and already-redacted quoted values are not counted" 'A_TOKEN="" B_TOKEN= C_TOKEN="<redacted>" D_TOKEN=<redacted>' 'A_TOKEN="" B_TOKEN= C_TOKEN="<redacted>" D_TOKEN=<redacted>' 0
chk "36 unterminated quote redacts to end of line (never leaks)" 'GH_TOKEN="unterminated and more' 'GH_TOKEN="<redacted>' 1
for c in "'" ':' '*' '(' '[' '<' '`' '='; do
  chk "37 path boundary [$c]" "A${c}/home/u/x B" "A${c}<path> B" 1
done
chk "38 a rejected candidate does not hide a later real path" 'x/home/a(/home/b) end' 'x/home/a(<path> end' 1
chk "39 path tail stops at ]" 'see [/home/u/z] ok' 'see [<path>] ok' 1

chk "40 Authorization: Bearer <tok> → token redacted" 'Authorization: Bearer abcdefghijklmnop1234 end' 'Authorization: Bearer <redacted> end' 1
chk "41 Authorization: token <tok>" 'authorization: token abcdefghijklmnop1234' 'authorization: token <redacted>' 1
chk "42 standalone Bearer <jwt>" 'curl Bearer eyJhbGciOiJIUzI1NiJ9.abc.def now' 'curl Bearer <redacted> now' 1
chk "43 short value and prose 'bearer of' are not tokens" 'Bearer short and the bearer of bad news' 'Bearer short and the bearer of bad news' 0
chk "44 word-internal xbearer is not a header" 'xbearer abcdefghijklmnopqrstu' 'xbearer abcdefghijklmnopqrstu' 0
chk "45 header match is case-insensitive" 'AUTHORIZATION: BEARER abcdefghijklmnop1234' 'AUTHORIZATION: BEARER <redacted>' 1
chk "46 Bearer + a ghp_ token counts once" 'Bearer ghp_abcdefghij1234' 'Bearer <redacted>' 1
chk "47 an already-redacted Bearer value is not re-counted" 'Authorization: Bearer <redacted>' 'Authorization: Bearer <redacted>' 0
for c in '|' '>' '{' ';' ')' ']' '!' '?' '&' '+' '#' '}'; do
  chk "48 path fails closed after [$c]" "A${c}/home/u/x B" "A${c}<path> B" 1
done
for c in '.' '_' '~' '%' '-' '/' 'a' '9'; do
  chk "49 path kept inside a URL/path segment after [$c]" "A${c}/home/u/x B" "A${c}/home/u/x B" 0
done

# --- #1728: AUTHORIZATION=<value> is a credential assignment (the AUTHOR exclusion must not eat AUTHORIZATION) ---
chk "50 AUTHORIZATION=opaque is redacted (mid-line)" 'run AUTHORIZATION=opaque123 now' 'run AUTHORIZATION=<redacted> now' 1
chk "51 AUTHORIZATION= at line START (FIRST position)" 'AUTHORIZATION=opaque123 then text' 'AUTHORIZATION=<redacted> then text' 1
chk "52 authorization= at line END (LAST position)" 'text then authorization=opaque123' 'text then authorization=<redacted>' 1
chk "53 AUTHORIZATION= single element (only token on the line)" 'AUTHORIZATION=opaque123' 'AUTHORIZATION=<redacted>' 1
chk "54 AUTHORIZATION quoted value, lowercase key" 'x authorization="opaque 123" y' 'x authorization="<redacted>" y' 1
chk "55 prefixed key X_AUTHORIZATION=" 'X_AUTHORIZATION=opaque ok' 'X_AUTHORIZATION=<redacted> ok' 1
chk "56 AUTH= (plain) still redacted" 'AUTH=opaque ok' 'AUTH=<redacted> ok' 1
chk "57 AUTHOR=Jane / author= / AUTHOR_NAME= are NOT credentials" 'AUTHOR=Jane author=bob AUTHOR_NAME=Jo' 'AUTHOR=Jane author=bob AUTHOR_NAME=Jo' 0
chk "58 AUTHORIZATION and AUTHOR on one line: only the credential goes" 'AUTHOR=Jane AUTHORIZATION=opaque' 'AUTHOR=Jane AUTHORIZATION=<redacted>' 1
chk "59 header form still redacted: first, middle, last" $'Authorization: Bearer abcdefghijklmnop1234\nmid\ncurl -H Authorization: Bearer abcdefghijklmnop1234' $'Authorization: Bearer <redacted>\nmid\ncurl -H Authorization: Bearer <redacted>' 2
chk "60 AUTHORIZATION=<redacted> is not re-counted" 'AUTHORIZATION=<redacted>' 'AUTHORIZATION=<redacted>' 0

# --- fleet-measured real shape (retros/2026-08-03-document-unregistered-bootstrap-incident.md) ------
chk "28 fleet shape: prose path in backticks" 'DOCUMENT mode received the arbitrary project path `/home/cristian/TRADINGVIEW`, which was not yet' 'DOCUMENT mode received the arbitrary project path `<path>`, which was not yet' 1

# =====================================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: scrub-issue-text.sh --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_or_count mutant_chain_or_count || exit 2
  MUT="$ROOT/mut"; mkdir -p "$MUT"
  CRASH="$(mutant_crash_re bash py awk cmd)" || exit 2
  # tooth <label> <input> <good-has> <sed-expr...>: the mutant must keep the raw text the original removed.
  tooth() {
    local label="$1" in="$2" rx="$3"; shift 3
    local m="$MUT/m$((++mi)).sh"
    if mutant_chain_or_count fail "$label" "$SUT" "$m" "$@"; then
      if mutant_tooth "$label" 0 0 "$m" --good-has "$rx" --bad-lacks "$rx|$CRASH" -- \
           "$BASH_BIN" -c '. "$1"; printf "%s\n" "$2" | "${3:-scrub_issue_text}"' _ @SUT@ "$in" "$TFN"; then pass=$((pass+1)); else fail=$((fail+1)); fi
    fi
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
  tooth "T-redact-guard: already-redacted guard off → re-counted" 'A_TOKEN="<redacted>" B_TOKEN=<redacted>' 'redactions: 0' 's/ || v == "<redacted>"//'
  TFN=scrub_issue_text
  # --- RDD round 1: quoted/lowercase assignments and widened boundaries ---
  tooth "T-quoted-dq: quote branch dead → quoted value leaks" 'run GH_TOKEN="abc123" now' 'GH_TOKEN="<redacted>" now' 's/if (q == "\\"" || q == "\\047" || q == "`") {/if (0) {/'
  tooth "T-quoted-sq: single-quote form dead" "export API_KEY='xyz' ok" "API_KEY='<redacted>' ok" 's/ || q == "\\047"//'
  tooth "T-quoted-bt: backtick form dead" 'use X_PASSWORD=`two words` ok' 'X_PASSWORD=`<redacted>` ok' 's/ || q == "`"//'
  tooth "T-lowercase: case-sensitive key test → api_key leaks" 'set api_key=zz ok' 'api_key=<redacted> ok' 's/u = toupper(k);/u = k;/'
  tooth "T-author: AUTHOR exclusion dead → author= redacted" 'author=bob ok' 'author=bob ok' 's/gsub(\/AUTHOR\/, "", u)/u = u/'
  tooth "T-authz: AUTHORIZ guard dropped → AUTHORIZATION= value leaks" 'run AUTHORIZATION=opaque123 now' 'AUTHORIZATION=<redacted> now' 's/gsub(\/AUTHORIZ\/, "AUTH_Z", u); //'
  tooth "T-unterminated: no-closing-quote branch dead" 'GH_TOKEN="open and more' 'GH_TOKEN="<redacted>$' 's/if (e == 0) { v = line; rest = "" ; pre = q }/if (e == 0) { v = ""; rest = line; pre = q }/'
  # fail-closed boundary: reverting to an allowlist leaks `x>/home/..`; dropping a segment character redacts inside a URL/path
  tooth "T-bd-failopen: boundary reverted to an allowlist → '>' prefix leaks" 'x>/home/bob y' 'x><path> y' 's#!~ /\[A-Za-z0-9\._~%\\/-\]/#~ /[[:space:]"(=,]/#'
  tooth "T-seg-alnum: alnum not a segment char" 'u https://g.com/home/u/x ok' 'https://g.com/home/u/x ok' 's#A-Za-z0-9\._~%\\/-#._~%\\/-#'
  tooth "T-seg-dot" 'a./home/u/x ok' 'a./home/u/x ok' 's#A-Za-z0-9\._~%\\/-#A-Za-z0-9_~%\\/-#'
  tooth "T-seg-underscore" 'a_/home/u/x ok' 'a_/home/u/x ok' 's#A-Za-z0-9\._~%\\/-#A-Za-z0-9.~%\\/-#'
  tooth "T-seg-tilde" 'a~/home/u/x ok' 'a~/home/u/x ok' 's#A-Za-z0-9\._~%\\/-#A-Za-z0-9._%\\/-#'
  tooth "T-seg-percent" 'a%/home/u/x ok' 'a%/home/u/x ok' 's#A-Za-z0-9\._~%\\/-#A-Za-z0-9._~\\/-#'
  tooth "T-seg-slash" 'a//home/u/x ok' 'a//home/u/x ok' 's#A-Za-z0-9\._~%\\/-#A-Za-z0-9._~%-#'
  tooth "T-seg-hyphen" 'a-/home/u/x ok' 'a-/home/u/x ok' 's#A-Za-z0-9\._~%\\/-#A-Za-z0-9._~%\\/#'
  # Authorization headers
  tooth "T-bearer-header: Authorization Bearer rule dead" 'Authorization: Bearer abcdefghijklmnop1234 end' 'Bearer <redacted> end' 's/KWRE = ".*"/KWRE = "NEVERMATCH_ZZ"/'
  tooth "T-bearer-token: token alternative dropped" 'authorization: token abcdefghijklmnop1234' 'token <redacted>' 's/(bearer|token)/(bearer)/'
  tooth "T-bearer-minlen: 16-char floor dropped → short value redacted" 'Bearer short and more' 'Bearer short and more' 's/i < 16/i < 0/'
  tooth "T-bearer-case: case-insensitive match dropped" 'AUTHORIZATION: BEARER abcdefghijklmnop1234' 'BEARER <redacted>' 's/low = tolower(line)/low = line/'
  tooth "T-bearer-wordint: word-boundary guard dropped" 'xbearer abcdefghijklmnopqrstu' 'xbearer abcdefghijklmnopqrstu' 's#s0 == 1 || substr(low, s0 - 1, 1) !~ /\[a-z0-9_\]/#1#'
  tooth "T-skip: rejected candidate skips past a later real path" 'x/home/a(/home/b) end' 'x/home/a\(<path> end' 's/off += st; rest = substr(rest, st + 1)/rest = ""/'
  tooth "T-tail-bracket: ] allowed in path tail" 'see [/home/u/z] ok' 'see \[<path>\] ok' 's/\[^\]\[:space:\]`/[^[:space:]`/g'
  # count tooth: the path rule stops incrementing → the typed count lies
  m="$MUT/mcount.sh"
  if mutant_chain_or_count fail "T-count: path rule stops counting" "$SUT" "$m" 's/"<path>"; line = substr(line, RSTART + RLENGTH); count++/"<path>"; line = substr(line, RSTART + RLENGTH)/'; then
    if mutant_tooth "T-count: path rule stops counting → count reads 0" 0 0 "$m" --good-has 'redactions: 1' --bad-lacks "redactions: 1|$CRASH" -- \
         "$BASH_BIN" -c '. "$1"; printf "%s\n" "/home/u/x" | scrub_issue_text_count' _ @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
