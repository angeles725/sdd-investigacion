#!/usr/bin/env bash
# return-token-gate.test.sh — RED-FIRST harness for return-token-gate.sh (kit issue #1706, slice 2).
#
# The gate is a Claude Code Stop hook: it reads the hook JSON on stdin (transcript_path, cwd, session_id,
# stop_hook_active), extracts the LAST continuation token of the final assistant report, runs
# `research-sdd-status.sh <target> --next --emit-token`, and blocks ONCE when the report's token is missing or
# differs from the emitted one. It never blocks when the emitted token is `unavailable`, allows on an explicit
# `return-token-override: <reason>` line, and allows with a typed degraded line (never silently) when it could not
# look (no jq, unreadable transcript, status failure).
#
# Fixtures: tests/fixtures/return-token-gate/ (two tiny corpora + transcript JSONL files). Every case runs on a
# FRESH copy of a corpus under $TMP, because the gate writes its block-once marker under <target>/.claude.
#
# TEETH (--prove-teeth): one mutant per guard, built with lib/mutant.sh from the real gate.
#
# Usage: return-token-gate.test.sh [--prove-teeth]     Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../return-token-gate.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to build the hook JSON in this suite" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
FX="$HERE/fixtures/return-token-gate"
[ -d "$FX/corpus-next" ] && [ -d "$FX/transcripts" ] || { echo "FATAL: fixtures missing under $FX" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# A toolbelt copy: the gate resolves its sibling research-sdd-status.sh and lib/ from its own directory, so a copy
# lets a case swap the status script for a stub and lets the teeth build mutants that still find their siblings.
TB="$TMP/tb"; mkdir -p "$TB"
cp "$HERE"/../*.sh "$TB/" && cp -r "$HERE/../lib" "$TB/lib" || { echo "FATAL: could not copy the toolbelt" >&2; exit 2; }

NEXT_TOKEN='return-token: next: reconstruct the shader pipeline'
STOP_TOKEN='return-token: STOP: campaign — read-only-investigable exhausted (0)'

fresh() { # <corpus fixture name> -> prints the path of a fresh copy
  local d; d="$(mktemp -d "$TMP/c.XXXXXX")"; cp -r "$FX/$1/." "$d/"; printf '%s\n' "$d"
}
fresh_stop() { # a single state file, no campaign queue: the one shape whose STOP maps to a token
  local d; d="$(fresh corpus-stop-queue)"; sed -i '/^## Campaign queue/,$d' "$d/RESEARCH-STATE.md"; printf '%s\n' "$d"
}
tr_() { printf '%s\n' "$FX/transcripts/$1"; }
# run_gate <target> <transcript> <session> [gate] -> g_out (stdout) g_err (stderr) g_rc ; RTG_ACTIVE=true sets stop_hook_active
run_gate() {
  local c="$1" t="$2" s="$3" g="${4:-$SUT}" j
  j="$(jq -n --arg s "$s" --arg t "$t" --arg c "$c" --argjson a "${RTG_ACTIVE:-false}" '{session_id:$s,transcript_path:$t,cwd:$c,stop_hook_active:$a}')"
  g_out="$(printf '%s' "$j" | bash "$g" "$c" 2>"$TMP/g.err")"; g_rc=$?; g_err="$(cat "$TMP/g.err")"
}
is_block() { printf '%s' "$g_out" | jq -e '.decision=="block"' >/dev/null 2>&1; }
reason() { printf '%s' "$g_out" | jq -r '.reason // empty' 2>/dev/null; }
# expect_allow <label> <branch> : exit 0, nothing on stdout, a typed `state=allow branch=<branch>` line on stderr
expect_allow() {
  if [ "$g_rc" = 0 ] && [ -z "$g_out" ] && grep -q "state=allow branch=$2" <<<"$g_err"; then ok "$1"
  else no "$1 — rc=$g_rc out=[$g_out] err=[$g_err] (want allow branch=$2)"; fi
}

echo "-- allow: the report's token equals the emitted one --"
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ match.jsonl)" s1
expect_allow "G-MATCH: 'return-token: next: <gap>' equal to the emitted line allows" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ match-bare.jsonl)" s1
expect_allow "G-MATCH-BARE: the bare 'next: <gap>' form (return-token: prefix dropped) allows" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ match-decorated.jsonl)" s1
expect_allow "G-MATCH-DECORATED: a list bullet, backticks and trailing spaces around the token still allow" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ lastwins.jsonl)" s1
expect_allow "G-LAST-WINS: stale tokens earlier in the report and in earlier messages are ignored; the LAST token decides" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ tool-last.jsonl)" s1
expect_allow "G-TOOL-LAST: a tool_use-only entry after the report does not hide the final report text" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ badlines.jsonl)" s1
expect_allow "G-BADLINES: an unparseable transcript line is skipped, the valid report is still read" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ string-content.jsonl)" s1
expect_allow "G-STRING-CONTENT: a message whose content is a plain string is read" match
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ sidechain-mismatch.jsonl)" s1
expect_allow "G-SIDECHAIN: a sub-agent (isSidechain) message after the report is not the report" match
c="$(fresh_stop)"; run_gate "$c" "$(tr_ stop-token.jsonl)" s1
expect_allow "G-STOP-MATCH: STOP: campaign — <reason> equal to the emitted STOP line allows" match

echo "-- block once: mismatch, missing token --"
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ mismatch.jsonl)" s1
if is_block && [ "$g_rc" = 0 ] && grep -qxF "$NEXT_TOKEN" <<<"$(reason)" && grep -qF 'next: trivia' <<<"$(reason)" \
   && grep -q 'state=block branch=mismatch' <<<"$g_err"; then
  ok "G-MISMATCH: blocks with the exact emitted line (own line, copyable) and names the reported token"
else no "G-MISMATCH: rc=$g_rc out=[$g_out] err=[$g_err]"; fi
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ notoken.jsonl)" s1
if is_block && grep -qxF "$NEXT_TOKEN" <<<"$(reason)" && grep -qi 'no continuation token' <<<"$(reason)" \
   && grep -q 'state=block branch=missing' <<<"$g_err"; then
  ok "G-NOTOKEN: a report with no token blocks, asks for it and quotes the emitted line"
else no "G-NOTOKEN: rc=$g_rc out=[$g_out] err=[$g_err]"; fi
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ final-has-none.jsonl)" s1
is_block && grep -qi 'no continuation token' <<<"$(reason)" \
  && ok "G-FINAL-ONLY: a correct token in an EARLIER message does not satisfy the FINAL report" \
  || no "G-FINAL-ONLY: out=[$g_out] err=[$g_err]"
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ unavailable-line-only.jsonl)" s1
is_block && grep -qi 'no continuation token' <<<"$(reason)" \
  && ok "G-UNAVAIL-LINE-NOT-TOKEN: a copied 'return-token: unavailable (...)' line is not a token" \
  || no "G-UNAVAIL-LINE-NOT-TOKEN: out=[$g_out] err=[$g_err]"
c="$(fresh_stop)"; run_gate "$c" "$(tr_ match.jsonl)" s1
if is_block && grep -qxF "$STOP_TOKEN" <<<"$(reason)"; then ok "G-STOP-MISMATCH: a next: token against an emitted STOP line blocks and quotes the STOP line"
else no "G-STOP-MISMATCH: out=[$g_out] err=[$g_err]"; fi

echo "-- block once: the marker is per session and per emitted token --"
c="$(fresh corpus-next)"
run_gate "$c" "$(tr_ mismatch.jsonl)" s-once; first_block=0; is_block && first_block=1
run_gate "$c" "$(tr_ mismatch.jsonl)" s-once
{ [ "$first_block" = 1 ] && expect_allow "G-BLOCK-ONCE: the SAME session and emitted token is not blocked a second time" block-once; } || no "G-BLOCK-ONCE: first run did not block"
run_gate "$c" "$(tr_ mismatch.jsonl)" s-other
is_block && ok "G-ONCE-PER-SESSION: another session is blocked again" || no "G-ONCE-PER-SESSION: out=[$g_out] err=[$g_err]"
sed -i 's/reconstruct the shader pipeline/a different next gap/' "$c/RESEARCH-STATE.md"
run_gate "$c" "$(tr_ mismatch.jsonl)" s-once
is_block && grep -qxF 'return-token: next: a different next gap' <<<"$(reason)" \
  && ok "G-ONCE-PER-CANDIDATE: in the same session a NEW emitted token (the corpus moved on) is blocked once more" \
  || no "G-ONCE-PER-CANDIDATE: out=[$g_out] err=[$g_err]"
RTG_ACTIVE=true run_gate "$(fresh corpus-next)" "$(tr_ mismatch.jsonl)" s1
expect_allow "G-LOOP-SAFETY: stop_hook_active=true allows without looking" loop-safety

echo "-- override and unavailable never block --"
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ override.jsonl)" s1
if [ "$g_rc" = 0 ] && [ -z "$g_out" ] && grep -q 'state=allow branch=override' <<<"$g_err" \
   && grep -qF 'operator asked for trivia first' <<<"$g_err"; then ok "G-OVERRIDE: 'return-token-override: <reason>' allows and the reason is printed"
else no "G-OVERRIDE: rc=$g_rc out=[$g_out] err=[$g_err]"; fi
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ override-empty.jsonl)" s1
is_block && ok "G-OVERRIDE-EMPTY: an override line with no reason does not allow" || no "G-OVERRIDE-EMPTY: out=[$g_out] err=[$g_err]"
c="$(fresh corpus-stop-queue)"; run_gate "$c" "$(tr_ mismatch.jsonl)" s1
if [ "$g_rc" = 0 ] && [ -z "$g_out" ] && grep -q 'state=allow branch=unavailable' <<<"$g_err" \
   && grep -qF 'Campaign queue' <<<"$g_err"; then ok "G-UNAVAILABLE: an unavailable emitted token (STOP with a queue) never blocks and the reason is printed"
else no "G-UNAVAILABLE: rc=$g_rc out=[$g_out] err=[$g_err]"; fi
c="$(fresh corpus-stop-queue)"; run_gate "$c" "$(tr_ notoken.jsonl)" s1
expect_allow "G-UNAVAILABLE-NOTOKEN: unavailable also allows a report with no token" unavailable

echo "-- not a corpus target, target resolution --"
e="$TMP/empty-target"; mkdir -p "$e"; run_gate "$e" "$(tr_ mismatch.jsonl)" s1
{ [ "$g_rc" = 0 ] && [ -z "$g_out" ] && [ -z "$g_err" ]; } && ok "G-NOT-TARGET: no RESEARCH-STATE under the target allows silently (no stdout, no stderr)" || no "G-NOT-TARGET: rc=$g_rc out=[$g_out] err=[$g_err]"
[ ! -e "$e/.claude" ] && ok "G-NOT-TARGET-NOWRITE: nothing was written under a non-target" || no "G-NOT-TARGET-NOWRITE: $e/.claude exists"
c="$(fresh corpus-next)"
g_out="$(jq -n --arg t "$(tr_ mismatch.jsonl)" --arg c "$c" '{session_id:"s1",transcript_path:$t,cwd:$c}' | bash "$SUT" 2>"$TMP/g.err")"; g_rc=$?; g_err="$(cat "$TMP/g.err")"
is_block && ok "G-CWD-TARGET: with no <target> argument the hook JSON 'cwd' is the target" || no "G-CWD-TARGET: rc=$g_rc out=[$g_out] err=[$g_err]"
g_out="$(jq -n --arg t "$(tr_ mismatch.jsonl)" '{session_id:"s1",transcript_path:$t}' | bash "$SUT" 2>"$TMP/g.err")"; g_rc=$?; g_err="$(cat "$TMP/g.err")"
{ [ "$g_rc" = 0 ] && [ -z "$g_out" ] && grep -q 'branch=degraded (no target' <<<"$g_err"; } \
  && ok "G-NO-TARGET: neither argument nor cwd -> allow with a typed degraded line" || no "G-NO-TARGET: rc=$g_rc out=[$g_out] err=[$g_err]"

echo "-- degraded: could not look -> allow, typed, never silent --"
nojq="$TMP/nojq-bin"; mkdir -p "$nojq"
for t in dirname cat basename; do p="$(type -P "$t")"; [ -n "$p" ] && ln -sf "$p" "$nojq/$t"; done
c="$(fresh corpus-next)"
g_out="$(printf '{}' | PATH="$nojq" "$BASH_BIN" "$SUT" "$c" 2>"$TMP/g.err")"; g_rc=$?; g_err="$(cat "$TMP/g.err")"
{ [ "$g_rc" = 0 ] && [ -z "$g_out" ] && grep -q 'state=allow branch=degraded (jq missing' <<<"$g_err"; } \
  && ok "G-DEGRADED-NOJQ: jq missing -> allow with a typed degraded line" || no "G-DEGRADED-NOJQ: rc=$g_rc out=[$g_out] err=[$g_err]"
c="$(fresh corpus-next)"; run_gate "$c" "$TMP/does-not-exist.jsonl" s1
grep -q 'state=allow branch=degraded (transcript unreadable' <<<"$g_err" && [ -z "$g_out" ] \
  && ok "G-DEGRADED-TRANSCRIPT: a missing transcript file -> typed degraded allow" || no "G-DEGRADED-TRANSCRIPT: out=[$g_out] err=[$g_err]"
g_out="$(jq -n --arg c "$c" '{session_id:"s1",cwd:$c}' | bash "$SUT" "$c" 2>"$TMP/g.err")"; g_rc=$?; g_err="$(cat "$TMP/g.err")"
grep -q 'state=allow branch=degraded (transcript unreadable' <<<"$g_err" && [ -z "$g_out" ] \
  && ok "G-DEGRADED-NO-TRANSCRIPT-FIELD: hook JSON without transcript_path -> typed degraded allow" || no "G-DEGRADED-NO-TRANSCRIPT-FIELD: out=[$g_out] err=[$g_err]"
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ no-assistant.jsonl)" s1
grep -q 'state=allow branch=degraded (no assistant text' <<<"$g_err" && [ -z "$g_out" ] \
  && ok "G-DEGRADED-NO-ASSISTANT: a transcript with no assistant text is 'could not look', not 'no token'" || no "G-DEGRADED-NO-ASSISTANT: out=[$g_out] err=[$g_err]"
g_out="$(printf 'this is not json' | bash "$SUT" "$c" 2>"$TMP/g.err")"; g_rc=$?; g_err="$(cat "$TMP/g.err")"
grep -q 'state=allow branch=degraded (hook JSON unreadable' <<<"$g_err" && [ -z "$g_out" ] \
  && ok "G-DEGRADED-STDIN: unparseable hook JSON -> typed degraded allow" || no "G-DEGRADED-STDIN: out=[$g_out] err=[$g_err]"
# a status script that fails / prints no return-token line
cp "$TB/research-sdd-status.sh" "$TMP/status.orig"
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 3\n' > "$TB/research-sdd-status.sh"
c="$(fresh corpus-next)"; run_gate "$c" "$(tr_ mismatch.jsonl)" s1 "$TB/return-token-gate.sh"
grep -q 'state=allow branch=degraded (status produced no return-token line' <<<"$g_err" && [ -z "$g_out" ] \
  && ok "G-DEGRADED-STATUS: a failing status script -> typed degraded allow, never a block" || no "G-DEGRADED-STATUS: out=[$g_out] err=[$g_err]"
cp "$TMP/status.orig" "$TB/research-sdd-status.sh"
# a status script slower than the bounded timeout -> typed degraded, never a block (RTG-STATUS-TIMEOUT)
if command -v timeout >/dev/null 2>&1; then
  cp "$TB/research-sdd-status.sh" "$TMP/status.orig2"
  printf '#!/usr/bin/env bash\nsleep 5\n' > "$TB/research-sdd-status.sh"
  c="$(fresh corpus-next)"; RETURN_TOKEN_GATE_TIMEOUT_SECS=1 run_gate "$c" "$(tr_ mismatch.jsonl)" s1 "$TB/return-token-gate.sh"
  grep -q 'state=allow branch=degraded (status --next timed out' <<<"$g_err" && [ -z "$g_out" ] \
    && ok "G-DEGRADED-TIMEOUT: a slow status run times out -> typed degraded allow, never a block" || no "G-DEGRADED-TIMEOUT: rc=$g_rc out=[$g_out] err=[$g_err]"
  cp "$TMP/status.orig2" "$TB/research-sdd-status.sh"
else
  ok "G-DEGRADED-TIMEOUT: skipped (no timeout command)"
fi

echo "-- bounded transcript parse (kit issue #1732) --"
pad() { head -c "$1" /dev/zero | tr '\0' 'x' | fold -w "$2" | sed 's/^/{"type":"user","message":{"content":"/; s/$/"}}/'; }
# [match report][big padding]: the report lies wholly before the tail window, so it is NOT parsed
# (typed degraded, tail-bounded) -- proof the gate does not read the whole file.
big="$TMP/big-before.jsonl"; { cat "$(tr_ match.jsonl)"; pad 600000 200; } > "$big"
c="$(fresh corpus-next)"; RETURN_TOKEN_GATE_TAIL_BYTES=4096 run_gate "$c" "$big" s1
{ [ -z "$g_out" ] && grep -q 'branch=degraded (no assistant text.*tail-bounded to 4096 bytes' <<<"$g_err"; } \
  && ok "G-TAIL-BOUND: a report lying wholly before the tail window is not parsed (typed degraded, tail-bounded)" \
  || no "G-TAIL-BOUND: out=[$g_out] err=[$g_err]"
# [mismatch report][padding][match report]: the final report is inside the window; the stale head is never read.
big2="$TMP/big-after.jsonl"; { cat "$(tr_ mismatch.jsonl)"; pad 600000 200; cat "$(tr_ match.jsonl)"; } > "$big2"
c="$(fresh corpus-next)"; RETURN_TOKEN_GATE_TAIL_BYTES=4096 run_gate "$c" "$big2" s1
expect_allow "G-TAIL-FINAL-IN-WINDOW: the final report inside the tail window is still read (partial first line dropped)" match
# a ~25 MB transcript with the default window completes quickly and reads the final report
huge="$TMP/huge.jsonl"; { pad 25000000 500; cat "$(tr_ match.jsonl)"; } > "$huge"
c="$(fresh corpus-next)"; _t0=$SECONDS; run_gate "$c" "$huge" s1; _dt=$((SECONDS - _t0))
if [ "$_dt" -le 10 ]; then expect_allow "G-HUGE-TRANSCRIPT: a ~25 MB transcript is read via the default tail window (${_dt}s)" match; else no "G-HUGE-TRANSCRIPT: took ${_dt}s"; fi
rm -f "$big2" "$huge"

echo "-- block-once marker pruning (kit issue #1732) --"
c="$(fresh corpus-next)"; mkdir -p "$c/.claude"
for i in 1 2 3 4 5 6; do : > "$c/.claude/.rsdd-return-token-blocked-old$i"; touch -d "$((i + 1)) minutes ago" "$c/.claude/.rsdd-return-token-blocked-old$i"; done
: > "$c/.claude/.rsdd-return-token-blocked-ancient"; touch -d '60 days ago' "$c/.claude/.rsdd-return-token-blocked-ancient"
: > "$c/.claude/unrelated.txt"; touch -d '60 days ago' "$c/.claude/unrelated.txt"
RETURN_TOKEN_GATE_MARKER_KEEP=3 run_gate "$c" "$(tr_ mismatch.jsonl)" s-prune
_n="$(find "$c/.claude" -name '.rsdd-return-token-blocked-*' | wc -l | tr -d '[:space:]')"
if is_block && [ "$_n" = 3 ] && [ -f "$c/.claude/.rsdd-return-token-blocked-s-prune" ] && [ ! -e "$c/.claude/.rsdd-return-token-blocked-ancient" ] \
   && [ -f "$c/.claude/.rsdd-return-token-blocked-old1" ] && [ ! -e "$c/.claude/.rsdd-return-token-blocked-old6" ] && [ -f "$c/.claude/unrelated.txt" ]; then
  ok "G-PRUNE: markers past the age cap and beyond the count cap are removed; the new marker and unrelated files survive"
else no "G-PRUNE: count=$_n err=[$g_err] ls=$(ls -A "$c/.claude" | tr '\n' ' ')"; fi

# newline in a marker name must never steer a delete outside the marker set: line 2 of the name is a relative path
# that the old newline-delimited parser handed to `rm` (cwd-relative). Run the gate from a dir holding that victim.
c="$(fresh corpus-next)"; mkdir -p "$c/.claude" "$TMP/cwd-victim"; : > "$TMP/cwd-victim/victim"
: > "$c/.claude/.rsdd-return-token-blocked-a"$'\n'"victim"; touch -d '3 minutes ago' "$c/.claude/.rsdd-return-token-blocked-a"$'\n'"victim"
( cd "$TMP/cwd-victim" && RETURN_TOKEN_GATE_MARKER_KEEP=1 run_gate "$c" "$(tr_ mismatch.jsonl)" s-nl; printf '%s\n' "$g_rc" > "$TMP/nl.rc" )
if [ -f "$TMP/cwd-victim/victim" ] && [ -f "$c/.claude/.rsdd-return-token-blocked-s-nl" ] && [ "$(cat "$TMP/nl.rc")" = 0 ]; then
  ok "G-PRUNE-NEWLINE: a marker name containing a newline never deletes a file outside the marker set"
else no "G-PRUNE-NEWLINE: victim deleted or marker missing"; fi
# portability: a `find` without -printf (BSD/macOS) must not break the count cap
shim="$TMP/find-noprintf"; mkdir -p "$shim"; realfind="$(type -P find)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = -printf ] && { echo "find: unknown primary -printf" >&2; exit 1; }; done\nexec %q "$@"\n' "$realfind" > "$shim/find"; chmod +x "$shim/find"
c="$(fresh corpus-next)"; mkdir -p "$c/.claude"
for i in 1 2 3 4 5; do : > "$c/.claude/.rsdd-return-token-blocked-p$i"; touch -d "$((i + 1)) minutes ago" "$c/.claude/.rsdd-return-token-blocked-p$i"; done
PATH="$shim:$PATH" RETURN_TOKEN_GATE_MARKER_KEEP=2 run_gate "$c" "$(tr_ mismatch.jsonl)" s-noprintf
_n="$(find "$c/.claude" -name '.rsdd-return-token-blocked-*' | wc -l | tr -d '[:space:]')"
if is_block && [ "$_n" = 2 ] && [ -f "$c/.claude/.rsdd-return-token-blocked-p1" ] && ! grep -q 'prune failed' <<<"$g_err"; then
  ok "G-PRUNE-PORTABLE: the count cap works with a find that has no -printf, no prune WARN"
else no "G-PRUNE-PORTABLE: count=$_n err=[$g_err]"; fi

echo "-- hermetic: the only write under the target is the block-once marker --"
c="$(fresh corpus-next)"; ( cd "$c" && find . -path ./.claude -prune -o -type f -print | sort ) > "$TMP/before.lst"
run_gate "$c" "$(tr_ mismatch.jsonl)" s-herm
( cd "$c" && find . -path ./.claude -prune -o -type f -print | sort ) > "$TMP/after.lst"
cmp -s "$TMP/before.lst" "$TMP/after.lst" && [ -n "$(find "$c/.claude" -name '.rsdd-return-token-blocked-*' 2>/dev/null)" ] \
  && ok "G-HERMETIC: corpus files untouched; the marker lives under <target>/.claude" || no "G-HERMETIC: before/after differ or no marker"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth-RTG: each guard is load-bearing --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  RTG_CRASH='integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError'
  # The tooth driver: a fresh corpus copy per run (the marker must not leak between the good and the mutant run).
  # env: RTG_TWICE=1 runs the gate twice on one copy · RTG_BETWEEN=1 moves the corpus to a new expected token between
  # the two runs · RTG_ACTIVE=true sets stop_hook_active · RTG_STOPONLY=1 drops the campaign queue · RTG_PATH replaces PATH.
  cat > "$TMP/rtg-run.sh" <<'RUN'
#!/usr/bin/env bash
gate="$1" src="$2" tr="$3" sid="$4"
w="$(mktemp -d)"; cp -r "$src/." "$w/"
[ -z "${RTG_STOPONLY:-}" ] || sed -i '/^## Campaign queue/,$d' "$w/RESEARCH-STATE.md"
j="$(jq -n --arg s "$sid" --arg t "$tr" --arg c "$w" --argjson a "${RTG_ACTIVE:-false}" '{session_id:$s,transcript_path:$t,cwd:$c,stop_hook_active:$a}')"
if [ -n "${RTG_MARKERS:-}" ]; then
  mkdir -p "$w/.claude"; k=0
  while [ "$k" -lt "$RTG_MARKERS" ]; do k=$((k+1)); : > "$w/.claude/.rsdd-return-token-blocked-old$k"; touch -d "${RTG_MARKER_AGE:-$k minutes} ago" "$w/.claude/.rsdd-return-token-blocked-old$k"; done
fi
if [ -n "${RTG_NLFILE:-}" ]; then
  mkdir -p "$w/.claude"; : > "$w/.claude/.rsdd-return-token-blocked-a"$'\n'"x"; touch -d '5 minutes ago' "$w/.claude/.rsdd-return-token-blocked-a"$'\n'"x"
fi
runs=1; [ -z "${RTG_TWICE:-}" ] || runs=2
i=0
while [ "$i" -lt "$runs" ]; do
  i=$((i+1))
  if [ -n "${RTG_PATH:-}" ]; then printf '%s' "$j" | PATH="$RTG_PATH" "$(type -P bash)" "$gate" "$w" 2>&1
  else printf '%s' "$j" | bash "$gate" "$w" 2>&1; fi
  echo "gate-rc=$?"
  [ -z "${RTG_BETWEEN:-}" ] || sed -i 's/reconstruct the shader pipeline/a different next gap/' "$w/RESEARCH-STATE.md"
done
[ -z "${RTG_MARKERS:-}" ] || echo "markers=$(find "$w/.claude" -name '.rsdd-return-token-blocked-*' | wc -l | tr -d '[:space:]')"
[ -z "${RTG_NLFILE:-}" ] || { [ -e "$w/.claude/.rsdd-return-token-blocked-a"$'\n'"x" ] && echo "weird=kept" || echo "weird=gone"; }
rm -rf "$w"
RUN
  # a second toolbelt copy whose status script always fails (for the status-degraded tooth)
  TB2="$TMP/tb2"; mkdir -p "$TB2"; cp -r "$TB/." "$TB2/"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$TB2/research-sdd-status.sh"
  rtg_t() { # <label> <sed-expr> <good-rc> <bad-rc> <corpus> <transcript> <session> <mutant_tooth match args...>
    # the mutant is built from the REAL gate ($SUT) into $RTG_TBDIR (default $TB), so it finds the siblings there
    local lbl="$1" expr="$2" grc="$3" brc="$4" corp="$5" trn="$6" sid="$7" dir="${RTG_TBDIR:-$TB}"; shift 7
    mutant_chain "$lbl" "$SUT" "$dir/rtg.$lbl.MUTANT.sh" "$expr" || { fail=$((fail+1)); return; }
    if mutant_tooth "$lbl" "$grc" "$brc" "$dir/rtg.$lbl.MUTANT.sh" --orig "$dir/return-token-gate.sh" "$@" -- bash "$TMP/rtg-run.sh" @SUT@ "$corp" "$trn" "$sid"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  }
  NX="$FX/corpus-next"; SQ="$FX/corpus-stop-queue"; BLOCK='"decision":"block"'
  RTG_PATH="$nojq" rtg_t RTG-JQ-PROBE '/# RTG-JQ-PROBE$/s/if ! command -v jq/if false \&\& command -v jq/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'degraded \(jq missing' --bad-lacks "jq missing|$RTG_CRASH" --bad-has 'hook JSON unreadable'
  RTG_ACTIVE=true rtg_t RTG-LOOP-SAFETY '/# RTG-LOOP-SAFETY$/s/= "true"/= "never"/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'branch=loop-safety' --good-lacks "$BLOCK" --bad-has "$BLOCK" --bad-lacks "loop-safety|$RTG_CRASH"
  rtg_t RTG-NOT-TARGET '/# RTG-NOT-TARGET$/s/if \[ -z "\$_states" \]/if [ -z "$_states" ] \&\& false/' 0 0 "$TMP/empty-target" "$(tr_ mismatch.jsonl)" s1 \
    --good-lacks 'state=' --bad-has 'state=allow branch=unavailable' --bad-lacks "$RTG_CRASH"
  rtg_t RTG-TRANSCRIPT-DEGRADED '/# RTG-TRANSCRIPT-DEGRADED$/s/if \[ -z "\$_transcript" \] || \[ ! -r "\$_transcript" \]; then/if false; then/' 0 0 "$NX" "$TMP/does-not-exist.jsonl" s1 \
    --good-has 'degraded \(transcript unreadable' --bad-lacks "transcript unreadable|$RTG_CRASH" --bad-has 'no assistant text'
  rtg_t RTG-SIDECHAIN '/# RTG-SIDECHAIN$/s/ and (\.isSidechain != true)//' 0 0 "$NX" "$(tr_ sidechain-mismatch.jsonl)" s1 \
    --good-has 'branch=match' --bad-has 'branch=mismatch' --bad-lacks "branch=match|$RTG_CRASH"
  rtg_t RTG-LAST-WINS '/# RTG-LAST-WINS$/s/_reported="\$_l"/[ -n "$_reported" ] || _reported="$_l"/' 0 0 "$NX" "$(tr_ lastwins.jsonl)" s1 \
    --good-has 'branch=match' --bad-has 'branch=mismatch' --bad-lacks "branch=match|$RTG_CRASH"
  rtg_t RTG-OVERRIDE '/# RTG-OVERRIDE$/s/if \[ -n "\$_override" \]/if [ -n "" ]/' 0 0 "$NX" "$(tr_ override.jsonl)" s1 \
    --good-has 'branch=override' --good-lacks "$BLOCK" --bad-has "$BLOCK" --bad-lacks "branch=override|$RTG_CRASH"
  rtg_t RTG-OVERRIDE-REASON '/# RTG-OVERRIDE-REASON$/s/\[ -z "\$_why" \] || _override="\$_why"/_override="${_why:-empty}"/' 0 0 "$NX" "$(tr_ override-empty.jsonl)" s1 \
    --good-has "$BLOCK" --bad-has 'branch=override' --bad-lacks "$BLOCK|$RTG_CRASH"
  rtg_t RTG-UNAVAILABLE-ALLOW '/# RTG-UNAVAILABLE-ALLOW$/s/"return-token: unavailable"\*)/"return-token: never"*)/' 0 0 "$SQ" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'branch=unavailable' --good-lacks "$BLOCK" --bad-has "$BLOCK" --bad-lacks "branch=unavailable|$RTG_CRASH"
  RTG_TBDIR="$TB2" rtg_t RTG-STATUS-DEGRADED '/# RTG-STATUS-DEGRADED$/s/if \[ -z "\$_emitted" \]; then/if false; then/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'degraded \(status produced no return-token line' --bad-lacks "status produced no|$RTG_CRASH" --bad-has 'branch=missing|branch=mismatch'
  RTG_TWICE=1 rtg_t RTG-BLOCK-ONCE '/# RTG-BLOCK-ONCE$/s/-f "\$_marker" \]/-f "$_marker.never" ]/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'branch=block-once' --bad-lacks "branch=block-once|$RTG_CRASH" --bad-has "$BLOCK"
  RTG_TWICE=1 RTG_BETWEEN=1 rtg_t RTG-ONCE-PER-TOKEN '/# RTG-BLOCK-ONCE$/s/ \&\& grep -qxF -- "\$_emitted" "\$_marker" 2>\/dev\/null//' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-lacks 'branch=block-once' --bad-has 'branch=block-once' --bad-lacks "$RTG_CRASH"
  rtg_t RTG-COMPARE '/# RTG-COMPARE$/s/\[ "\$_reported" = "\$_expected" \]/[ -n "$_reported" ]/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has "$BLOCK" --bad-has 'branch=match' --bad-lacks "$BLOCK|$RTG_CRASH"
  rtg_t RTG-MISSING-BRANCH '/# RTG-MISSING-BRANCH$/s/if \[ -z "\$_reported" \]; then/if false; then/' 0 0 "$NX" "$(tr_ notoken.jsonl)" s1 \
    --good-has 'no continuation token' --bad-has "$BLOCK" --bad-lacks "no continuation token|$RTG_CRASH"
  rtg_t RTG-QUOTE-EMITTED '/^\$_emitted$/d' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'next: reconstruct the shader pipeline' --bad-has "$BLOCK" --bad-lacks "reconstruct the shader pipeline|$RTG_CRASH"
  rtg_t RTG-BULLET '/# RTG-BULLET$/s/_l:2/_l:0/' 0 0 "$NX" "$(tr_ match-decorated.jsonl)" s1 \
    --good-has 'branch=match' --bad-has "$BLOCK" --bad-lacks "branch=match|$RTG_CRASH"
  rtg_t RTG-BACKTICK '/# RTG-BACKTICK$/d' 0 0 "$NX" "$(tr_ match-decorated.jsonl)" s1 \
    --good-has 'branch=match' --bad-has "$BLOCK" --bad-lacks "branch=match|$RTG_CRASH"
  rtg_t RTG-PREFIX '/# RTG-PREFIX$/d' 0 0 "$NX" "$(tr_ match.jsonl)" s1 \
    --good-has 'branch=match' --bad-has "$BLOCK" --bad-lacks "branch=match|$RTG_CRASH"
  rtg_t RTG-TRIM '/# RTG-TRIM/d' 0 0 "$NX" "$(tr_ match-decorated.jsonl)" s1 \
    --good-has 'branch=match' --bad-has "$BLOCK" --bad-lacks "branch=match|$RTG_CRASH"
  RETURN_TOKEN_GATE_TAIL_BYTES=4096 rtg_t RTG-TAIL-BOUND '/# RTG-TAIL-BOUND$/s/-gt "\$_tail_bytes"/-gt 999999999999/' 0 0 "$NX" "$TMP/big-before.jsonl" s1 \
    --good-has 'tail-bounded' --bad-has 'branch=match' --bad-lacks "tail-bounded|$RTG_CRASH"
  RTG_MARKERS=5 RETURN_TOKEN_GATE_MARKER_KEEP=2 rtg_t RTG-PRUNE-COUNT '/# RTG-PRUNE-CAP$/s/i = keep/i = 99999/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'markers=2' --bad-has 'markers=6' --bad-lacks "markers=2|$RTG_CRASH"
  RTG_MARKERS=3 RTG_MARKER_AGE='60 days' rtg_t RTG-PRUNE-AGE '/# RTG-PRUNE-AGE$/s/-mtime +"\$max_age"/-mtime +99999/' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'markers=1' --bad-has 'markers=4' --bad-lacks "markers=1|$RTG_CRASH"
  RTG_NLFILE=1 RETURN_TOKEN_GATE_MARKER_KEEP=1 rtg_t RTG-PRUNE-NAME '/# RTG-PRUNE-NAME$/d' 0 0 "$NX" "$(tr_ mismatch.jsonl)" s1 \
    --good-has 'weird=kept' --bad-has 'weird=gone' --bad-lacks "weird=kept|$RTG_CRASH"
  RTG_STOPONLY=1 rtg_t RTG-STOP-PATTERN '/# RTG-TOKEN-PATTERN$/s/"STOP: campaign"\*/"STOP: nothing"*/' 0 0 "$SQ" "$(tr_ stop-token.jsonl)" s1 \
    --good-has 'branch=match' --bad-has 'branch=missing' --bad-lacks "branch=match|$RTG_CRASH"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
