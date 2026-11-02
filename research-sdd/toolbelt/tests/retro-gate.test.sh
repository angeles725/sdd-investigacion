#!/usr/bin/env bash
# retro-gate.test.sh — black-box harness for the retro-gate.sh SHIM (U17 / #479; ported to Go in kit issues #2367, #2368).
#
# retro-gate.sh is a compatibility shim over `rsdd gate retro` now. What stays here is what only a shell can prove:
#   - the shim passes its own directory (--toolbelt), so a COPIED toolbelt decides the kit root, the verify-retro.sh
#     it runs and the stage-retro-issues.sh it seeds with (the siblings are still bash);
#   - the hook contract survives a missing binary: the default mode never fails the Stop it guards (exit 0, typed
#     stderr line), --json keeps the CLI degrade (rc 2);
#   - the shim runs through a symlink (RSDD-SELF-DIR) and templates/hook-stop-retro-gate.sh still execs it;
#   - one end-to-end Stop per verdict through the real binary: BLOCK, block-once, loop-safety, --json, seeding.
# Every behaviour of the gate itself (the scans, the session-sha scope, nested worktrees, directory symlinks, the
# stop log, the envelope, issue-seeding accounting, signals) is a Go test: research-sdd/rsdd/internal/gate/retrogate_*_test.go,
# each one run against the frozen original (testdata/legacy/retro-gate.sh) by the differential test.
#
# TEETH: none here. The gate is `rsdd gate retro`; its mutants are Go tests (internal/gate, kit issue #2367).
#
# Usage: retro-gate.test.sh [--prove-teeth]     Exit: 0 = all held · 1 = regression

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../retro-gate.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required (the gate reads the hook JSON with it)" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# Hermetic git: no user or system config, fixed identity and dates.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A kit-shaped copy: the shim resolves rsdd from <toolbelt>/../rsdd (lib/rsdd-exec.sh), so the copy sits in a kit dir
# whose rsdd/ links to the real module; a rebuild (RSDD_BIN unset, as in CI) lands in $TMP/kit/bin, never in the tree.
mkdir -p "$TMP/kit/templates" && ln -s "$(CDPATH='' cd -P -- "$HERE/../../rsdd" && pwd -P)" "$TMP/kit/rsdd" \
  || { echo "FATAL: could not link the rsdd module" >&2; exit 2; }
cp "$HERE/../../templates/hook-stop-retro-gate.sh" "$TMP/kit/templates/" || { echo "FATAL: hook template missing" >&2; exit 2; }
TB="$TMP/kit/toolbelt"; mkdir -p "$TB"
cp "$HERE"/../*.sh "$TB/" && cp -r "$HERE/../lib" "$TB/lib" || { echo "FATAL: could not copy the toolbelt" >&2; exit 2; }
GATE="$TB/retro-gate.sh"
# Mock gh: authenticated, every call a no-op. Stub seeder (swapped in per case): logs its arguments.
MOCKBIN="$TMP/mockbin"; mkdir -p "$MOCKBIN"; printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/gh"; chmod +x "$MOCKBIN/gh"
SEED_LOG="$TMP/seed.log"; export SEED_LOG

# mktarget <name>: a git target with a session start at HEAD, then one block committed (research advanced).
mktarget() {
  local d="$TMP/$1"
  mkdir -p "$d"; git -C "$d" init -q -b main; : > "$d/.gitkeep"; git -C "$d" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" git -C "$d" commit -q -m init
  mkdir -p "$d/.claude"; git -C "$d" rev-parse HEAD > "$d/.claude/.rsdd-session-s1"
  printf '# Block\n' > "$d/niagara-block1.md"; git -C "$d" add niagara-block1.md
  GIT_AUTHOR_DATE="2026-09-05T10:00:00" GIT_COMMITTER_DATE="2026-09-05T10:00:00" git -C "$d" commit -q -m block
  printf '%s' "$d"
}
hookjson() { printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}"; }
# run <sut> <target> <json> [args...] → OUT ERR RC
run() {
  local sut="$1" tgt="$2" json="$3"; shift 3
  [ "$tgt" = "-" ] && set -- "$@" || set -- "$@" "$tgt"   # "-" = no target argument at all
  OUT="$(printf '%s' "$json" | PATH="$MOCKBIN:$PATH" "$BASH_BIN" "$sut" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
}
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

echo "== retro-gate.test.sh (SUT: $(basename "$SUT")) =="

# S1: the script is a shim, not a second implementation.
{ grep -q 'rsdd_exec_hook gate gate retro --toolbelt "\$_RSDD_SELF"' "$SUT" && grep -q 'rsdd_exec gate retro --toolbelt "\$_RSDD_SELF"' "$SUT" \
    && [ "$(grep -vc '^#' "$SUT")" -lt 20 ]; } \
  && ok "S1: retro-gate.sh is a shim over rsdd gate retro (passes --toolbelt, no gate logic left)" || no "S1: retro-gate.sh is not a shim"

# S2: argument errors keep the hook contract.
run "$GATE" "-" ""; { [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "missing <target>"; } && ok "S2a: no argument → exit 0, typed error on stderr" || no "S2a: rc=$RC err=$ERR"
run "$GATE" "$TMP/nope" ""; { [ "$RC" -eq 0 ] && has "$ERR" "target not found"; } && ok "S2b: nonexistent target → exit 0, typed error" || no "S2b: rc=$RC err=$ERR"

# S3: BLOCK end to end; the kit root and the toolbelt are the COPY's (the shim's --toolbelt), not the live kit's.
T3="$(mktarget t3)"
run "$GATE" "$T3" "$(hookjson s1)"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null && has "$OUT" "$TMP/kit/templates/retro.template.md"; } \
  && ok "S3a: BLOCK end to end through the shim; the reason names the copy's kit templates" || no "S3a: rc=$RC out=$OUT err=$ERR"
has "$ERR" "state=block branch=retro-pending changed=1 changed retro=(none) target=t3" && ok "S3b: typed state line on stderr" || no "S3b: $ERR"
LASTLOG="$(tail -n1 "$T3/.claude/.rsdd-retro-gate-stops.log")"
[ -f "$T3/.claude/.rsdd-retro-blocked-s1" ] && has "$LASTLOG" 'branch=retro-pending' \
  && ok "S3c: block-once state file and stop-log line written under .claude" || no "S3c: state files missing"
run "$GATE" "$T3" "$(hookjson s1)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "branch=block-once"; } && ok "S3d: the second Stop of the session allows (block-once)" || no "S3d: rc=$RC out=$OUT err=$ERR"
run "$GATE" "$T3" "$(hookjson s2 true)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "branch=loop-safety"; } && ok "S3e: stop_hook_active allows (loop-safety)" || no "S3e: rc=$RC out=$OUT err=$ERR"

# S4: siblings resolve beside the shim: a stub verify-retro.sh decides conformance, a stub seeder is called with --apply.
T4="$(mktarget t4)"; mkdir -p "$T4/retros"; printf '# Retro\n' > "$T4/retros/2026-09-05-r.md"
git -C "$T4" add retros && GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" git -C "$T4" commit -q -m retro
printf '#!/usr/bin/env bash\necho "STUBFINDING: nothing conforms"\nexit 1\n' > "$TB/verify-retro.sh"
run "$GATE" "$T4" "$(hookjson s1)"
{ printf '%s' "$OUT" | jq -e '.decision == "block" and (.reason | contains("missing elements: STUBFINDING: nothing conforms"))' >/dev/null; } \
  && ok "S4a: the sibling verify-retro.sh beside the shim decides conformance" || no "S4a: out=$OUT err=$ERR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TB/verify-retro.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SEED_LOG"\nprintf "summary: created=1 skipped-duplicate=0\\n"\n' > "$TB/stage-retro-issues.sh"
rm -f "$SEED_LOG" "$T4/.claude/.rsdd-retro-blocked-s1"
run "$GATE" "$T4" "$(hookjson s1)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "branch=retro-conforming" && has "$ERR" "issue-seeding: ran=1 created=1" && grep -q -- "--apply" "$SEED_LOG"; } \
  && ok "S4b: a conforming close seeds through the sibling stage-retro-issues.sh --apply (ran=1 created=1)" || no "S4b: rc=$RC out=$OUT err=$ERR"
cp "$HERE/../verify-retro.sh" "$HERE/../stage-retro-issues.sh" "$TB/"

# S5: --json through the shim: one envelope, rc 0.
T5="$(mktarget t5)"
run "$GATE" "$T5" "$(hookjson s1)" --json
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.schema == "research-sdd.retro-gate/v1" and .items[0].verdict == "block" and .counts.blocked == 1' >/dev/null; } \
  && ok "S5: --json prints ONE research-sdd.retro-gate/v1 envelope (block), rc 0" || no "S5: rc=$RC out=$OUT err=$ERR"

# S6: the binary is unavailable. A hook never fails its Stop; --json is a machine reader and says rc 2.
RSDD_BIN="$TMP/no-such-rsdd" run "$GATE" "$T5" "$(hookjson s9)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "degraded: rsdd-unavailable" && has "$ERR" "rsdd-exec-gate: state=allow branch=degraded"; } \
  && ok "S6a: binary unavailable → the hook degrades to an allow (exit 0, typed stderr)" || no "S6a: rc=$RC out=$OUT err=$ERR"
RSDD_BIN="$TMP/no-such-rsdd" run "$GATE" "$T5" "$(hookjson s9)" --json
{ [ "$RC" -eq 2 ] && [ -z "$OUT" ] && has "$ERR" "degraded: rsdd-unavailable"; } \
  && ok "S6b: binary unavailable with --json → rc 2, nothing on stdout" || no "S6b: rc=$RC out=$OUT err=$ERR"
mkdir -p "$TMP/nolib/toolbelt" && cp "$GATE" "$TMP/nolib/toolbelt/retro-gate.sh"
run "$TMP/nolib/toolbelt/retro-gate.sh" "$T5" "$(hookjson s9)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "rsdd-exec.sh missing beside"; } && ok "S6c: lib/rsdd-exec.sh missing → exit 0, typed stderr (hook)" || no "S6c: rc=$RC err=$ERR"
run "$TMP/nolib/toolbelt/retro-gate.sh" "$T5" "$(hookjson s9)" --json
[ "$RC" -eq 2 ] && ok "S6d: lib/rsdd-exec.sh missing with --json → rc 2" || no "S6d: rc=$RC"

# S7: through a symlink (RSDD-SELF-DIR): the shim finds its toolbelt, the copy decides again.
T7="$(mktarget t7)"; ln -s "$GATE" "$TMP/link-retro-gate.sh"
run "$TMP/link-retro-gate.sh" "$T7" "$(hookjson s1)"
{ printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null && has "$OUT" "$TMP/kit/templates/retro.template.md"; } \
  && ok "S7: the shim runs through a symlink and still resolves its own toolbelt" || no "S7: out=$OUT err=$ERR"

# S8: the installable hook wrapper (templates/hook-stop-retro-gate.sh) still execs the shim unchanged.
T8="$(mktarget t8)"
sed -e "s#<KIT>#$TMP/kit#" -e "s#<TARGET>#$T8#" "$TMP/kit/templates/hook-stop-retro-gate.sh" > "$T8/hook.sh"; chmod +x "$T8/hook.sh"
OUT="$(printf '%s' "$(hookjson s1)" | PATH="$MOCKBIN:$PATH" "$BASH_BIN" "$T8/hook.sh" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null; } && ok "S8: the Stop-hook wrapper execs the shim and BLOCKS end to end" || no "S8: rc=$RC out=$OUT err=$ERR"

# S9: the real sibling seeder (itself a shim) still runs under the gate: whatever it says, the verdict stays an allow.
T9="$(mktarget t9)"; mkdir -p "$T9/retros"
printf '<!-- review-status: pending -->\n# Retro — test\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta fixture row | file.sh | evidence | fix | low |\n' > "$T9/retros/2026-09-05-r.md"
git -C "$T9" add retros && GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" git -C "$T9" commit -q -m retro
HOME="$TMP/nohome" run "$GATE" "$T9" "$(hookjson s1)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && has "$ERR" "branch=retro-conforming" && has "$ERR" "retro-gate: issue-seeding: ran=1 "; } \
  && ok "S9: a conforming close runs the real sibling seeder; the verdict is still an allow (exit 0)" || no "S9: rc=$RC out=$OUT err=$ERR"

# --prove-teeth: the gate is the Go command `rsdd gate retro` (kit issues #2367, #2368); its mutation controls live in
# research-sdd/rsdd/internal/gate (retrogate_*_test.go), so this suite runs the shim black-box only.

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
