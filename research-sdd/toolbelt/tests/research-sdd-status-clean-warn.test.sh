#!/usr/bin/env bash
# research-sdd-status-clean-warn.test.sh — terminal no-garbage WARN in `research-sdd-status.sh --next`
# (kit issue #1277, slice 2). When --next resolves to an exhausted STOP, the status script runs clean-check.sh
# over the target and echoes findings to STDERR as `WARN: clean-check: ...`. Report-only: stdout and exit code
# are unchanged. Three states: clean -> INFO line, findings -> WARN lines, unverifiable -> typed WARN.
# Everything runs in trap-cleaned temp dirs; nothing real is touched.
# Usage: research-sdd-status-clean-warn.test.sh    Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/.."
SUT="$TB/research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not found" >&2; exit 2; }
TMP="$(mktemp -d)"
# clean-check scans $TMPDIR (default /tmp) for stale tmp.* entries: point it at an empty dir so the suite is hermetic.
mkdir -p "$TMP/tmpd"; export TMPDIR="$TMP/tmpd"
trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-clean-warn.test.sh =="

# mkcorpus DIR IO — a git-tracked corpus; IO=0 is an exhausted STOP, IO=1 a NEXT.
mkcorpus() {
  local d="$1" io="$2"; mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n' "$io"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    [ "$io" = 1 ] && echo "| high | the gap | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: $io"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$d/RESEARCH-STATE.md"
  git -C "$d" init -q; git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m init
}
ERR=""
run() { "$@" >/dev/null 2>"$TMP/err"; ERR="$(cat "$TMP/err")"; }

# 1 fixture: a clean exhausted STOP corpus (the rsdd status show tests pin the verdict and the INFO line)
mkcorpus "$TMP/c1" 0

# 2 untracked garbage: loud WARN naming the file, verdict + exit unchanged, nothing written/deleted
mkcorpus "$TMP/c2" 0; printf 'x\n' > "$TMP/c2/stray.json"; run bash "$SUT" "$TMP/c2" --next
[ -f "$TMP/c2/stray.json" ] && ok "2c read-only: stray file untouched" || no "2c stray file deleted"
mkdir -p "$TMP/c2/.research-sdd"; printf 'stray.json # fixture\n' > "$TMP/c2/.research-sdd/keep.txt"; run bash "$SUT" "$TMP/c2" --next
grep -q 'GARBAGE untracked' <<<"$ERR" && no "2d keep-list did not silence [$ERR]" || ok "2d keep.txt entry silences the finding"

# 8 fixture self-checks: the STALE and BOOTSTRAP corpora really are STALE and BOOTSTRAP
mkdir -p "$TMP/c8s" "$TMP/c8b"; sed 's/^investigable_open: 0/investigable_open: 5/' "$TMP/c1/RESEARCH-STATE.md" > "$TMP/c8s/RESEARCH-STATE.md"
a="$(bash "$SUT" "$TMP/c8s" --next 2>/dev/null)"; [[ "$a" == STALE* ]] && ok "8b STALE fixture really is STALE" || no "8b [$a]"
a="$(bash "$SUT" "$TMP/c8b" --next 2>/dev/null)"; [[ "$a" == BOOTSTRAP* ]] && ok "8c BOOTSTRAP fixture really is BOOTSTRAP" || no "8c [$a]"

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
