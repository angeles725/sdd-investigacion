#!/usr/bin/env bash
# clean-check.test.sh — suite for clean-check.sh (kit issue #1277, slice 1). Pins the contract in
# clean-check.v1.md: untracked/non-ignored detection, keep-list semantics, stale tmp.* detection
# (age, ownership, name), scratchpad exemption, exit codes, DEGRADED, read-only behaviour.
# Everything runs in trap-cleaned temp dirs: the fake repo and the fake tmp dir are both created
# here; nothing real is ever touched.
#
# Usage: clean-check.test.sh                (run the suite)
#        clean-check.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../clean-check.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
MUT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MUT"' EXIT
# mutant copies of the SUT live flat in $MUT and resolve lib/ beside themselves (kit #1659: scripts-manifest.sh)
ln -s "$HERE/../lib" "$MUT/lib"
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf "  SKIP  %s\n" "$1"; }

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain_or_count fail "$l" "$SUT" "$o" "$@" || return 1; }
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

OUT=""; RC=0
run() { OUT="$("$BASH_BIN" "$SUT" "$@" 2>&1)"; RC=$?; }
has() { grep -qF -- "$1" <<<"$OUT"; }
lines() { grep -c . <<<"$OUT"; }

# Fresh fake repo + fake tmp dir per scenario.
n=0
fresh() {
  n=$((n+1)); REPO="$TMP/repo$n"; FT="$TMP/tmp$n"
  mkdir -p "$REPO" "$FT"
  git -C "$REPO" init -q
  printf 'tracked\n' > "$REPO/tracked.txt"
  git -C "$REPO" add tracked.txt
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  unset CLEAN_CHECK_SCRATCHPAD CLEAN_CHECK_UID
}
# ago HOURS PATH — set PATH's mtime HOURS in the past; portable (GNU `date -d`, BSD `date -v`, touch -t).
ago() {
  local ts
  ts="$(date -d "$1 hours ago" +%Y%m%d%H%M.%S 2>/dev/null)" || ts="$(date -v-"$1"H +%Y%m%d%H%M.%S 2>/dev/null)" || ts=""
  [ -n "$ts" ] || { echo "FATAL: cannot compute a past timestamp" >&2; exit 2; }
  touch -t "$ts" "$2"
}
snapshot() {
  { (cd "$REPO" && find . -path ./.git -prune -o -print | sort); git -C "$REPO" status --porcelain; find "$FT" | sort; } 2>&1 | cksum
}

echo "== clean-check.test.sh (SUT: $(basename "$SUT")) =="

# ---- usage ------------------------------------------------------------------------------------
fresh
run --bogus; [ "$RC" = 2 ] && ok "unknown flag -> exit 2" || no "unknown flag" "(rc=$RC)"
run --stale-hours abc --target "$REPO" --tmp "$FT"; [ "$RC" = 2 ] && ok "non-numeric --stale-hours -> exit 2" || no "non-numeric stale" "(rc=$RC)"
run --stale-hours; [ "$RC" = 2 ] && ok "--stale-hours without value -> exit 2" || no "stale missing value" "(rc=$RC)"
run --target "$TMP/does-not-exist" --tmp "$FT"; [ "$RC" = 2 ] && ok "absent target -> exit 2" || no "absent target" "(rc=$RC)"
mkdir "$TMP/plain"; run --target "$TMP/plain" --tmp "$FT"; [ "$RC" = 2 ] && ok "target not a git work tree -> exit 2" || no "not git" "(rc=$RC)"
run --target "$REPO" --tmp "$TMP/no-such-tmp"; [ "$RC" = 2 ] && ok "absent --tmp dir -> exit 2 (not a quiet clean)" || no "absent tmp" "(rc=$RC)"

# ---- clean run --------------------------------------------------------------------------------
fresh; mkdir -p "$REPO/.research-sdd"; printf '# nothing kept\n' > "$REPO/.research-sdd/keep.txt"
run --target "$REPO" --tmp "$FT"
[ "$RC" = 0 ] && ok "clean repo + keep.txt -> exit 0" || no "clean exit" "(rc=$RC)"
{ [ "$(lines)" = 1 ] && has "CLEAN-CHECK: clean ("; } && ok "clean run prints only the summary line" || no "clean output" "($OUT)"
{ has "$REPO" && has "$FT" && has "24h" && has "keep-list entries: 0"; } && ok "summary names target, tmp, stale age, keep-list count" || no "summary content" "($OUT)"

fresh
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "ABSENT-KEEPLIST $REPO/.research-sdd/keep.txt"; } && ok "absent keep.txt -> typed ABSENT-KEEPLIST, still exit 0" || no "absent keeplist" "(rc=$RC $OUT)"

# ---- untracked --------------------------------------------------------------------------------
fresh; printf 'x\n' > "$REPO/stray.json"; mkdir -p "$REPO/sub dir/deep"; printf 'x\n' > "$REPO/sub dir/deep/a b.txt"
printf 'ignored.log\n' > "$REPO/.gitignore"; git -C "$REPO" add .gitignore
printf 'x\n' > "$REPO/ignored.log"
run --target "$REPO" --tmp "$FT"
[ "$RC" = 1 ] && ok "untracked file -> exit 1" || no "untracked exit" "(rc=$RC)"
has "GARBAGE untracked stray.json" && ok "untracked file reported with relative path" || no "untracked line" "($OUT)"
has "GARBAGE untracked sub dir/deep/a b.txt" && ok "untracked dir expanded to its files (spaces preserved)" || no "untracked dir" "($OUT)"
if has "ignored.log"; then no "gitignored file must not be reported" "($OUT)"; else ok "gitignored file not reported"; fi
if has "tracked.txt"; then no "tracked file must not be reported"; else ok "tracked file not reported"; fi
has "CLEAN-CHECK: 2 finding(s)" && ok "summary counts findings (ABSENT-KEEPLIST is not a finding)" || no "finding count" "($OUT)"

# ---- keep-list --------------------------------------------------------------------------------
fresh; mkdir -p "$REPO/.research-sdd" "$REPO/_evidence/t1" "$REPO/notes"
printf 'x\n' > "$REPO/_evidence/t1/r.json"; printf 'x\n' > "$REPO/notes/a.md"; printf 'x\n' > "$REPO/stray.json"; printf 'x\n' > "$REPO/keepme.txt"
cat > "$REPO/.research-sdd/keep.txt" <<'KL'
# comment line
   # indented comment

_evidence/   # operator-approved evidence tree
keepme.txt # one file, with a reason
notes/*.md
KL
run --target "$REPO" --tmp "$FT"
[ "$RC" = 1 ] && ok "keep-list: leftover non-kept file still fails" || no "keep exit" "(rc=$RC)"
has "stray.json" && ok "keep-list: non-matching file still reported" || no "keep stray" "($OUT)"
if has "_evidence"; then no "keep-list: dir glob '_evidence/' must keep everything below" "($OUT)"; else ok "keep-list: trailing-slash glob keeps a tree"; fi
if has "keepme.txt"; then no "keep-list: exact entry with ' # reason' must match" "($OUT)"; else ok "keep-list: entry with trailing reason matches"; fi
if has "notes/a.md"; then no "keep-list: glob must match" "($OUT)"; else ok "keep-list: *.md glob matches"; fi
if has ".research-sdd/keep.txt"; then no "keep.txt itself must never be reported" "($OUT)"; else ok "keep.txt itself never reported"; fi
has "keep-list entries: 3" && ok "summary counts only real entries (comments/blank/reason stripped)" || no "keep count" "($OUT)"
printf '# reason-only\r\nstray.json\r\n' > "$REPO/.research-sdd/keep.txt"
run --target "$REPO" --tmp "$FT"
if has "GARBAGE untracked stray.json"; then no "CRLF keep-list line must still match" "($OUT)"; else ok "CRLF keep-list tolerated"; fi

# ---- stale tmp --------------------------------------------------------------------------------
fresh
mkdir "$FT/tmp.olddir"; ago 48 "$FT/tmp.olddir"
: > "$FT/tmp.oldfile"; ago 30 "$FT/tmp.oldfile"
: > "$FT/tmp.young"
: > "$FT/other.old"; ago 90 "$FT/other.old"
: > "$FT/xtmp.old"; ago 90 "$FT/xtmp.old"
run --target "$REPO" --tmp "$FT"
[ "$RC" = 1 ] && ok "stale tmp.* -> exit 1" || no "stale exit" "(rc=$RC)"
has "GARBAGE stale-tmp $FT/tmp.olddir age=48h" && ok "stale dir reported with age in hours" || no "stale dir" "($OUT)"
has "GARBAGE stale-tmp $FT/tmp.oldfile age=30h" && ok "stale file reported with age in hours" || no "stale file" "($OUT)"
if has "tmp.young"; then no "young tmp.* must not be reported" "($OUT)"; else ok "young tmp.* not reported"; fi
if has "other.old"; then no "non tmp.* name must not be reported" "($OUT)"; else ok "non-tmp.* name not reported"; fi
if has "xtmp.old"; then no "name must start with tmp." "($OUT)"; else ok "name must START with tmp. (xtmp.old not reported)"; fi
has "CLEAN-CHECK: 2 finding(s)" && ok "stale summary counts 2 findings" || no "stale count" "($OUT)"
run --target "$REPO" --tmp "$FT" --stale-hours 40
{ has "tmp.olddir" && ! has "tmp.oldfile"; } && ok "--stale-hours 40: only the 48h entry is stale" || no "stale 40" "($OUT)"
has "older than 40h" && ok "summary states the overridden stale age" || no "stale 40 summary" "($OUT)"
run --target "$REPO" --tmp "$FT" --stale-hours 100
[ "$RC" = 0 ] && ok "--stale-hours 100: nothing stale -> clean" || no "stale 100" "(rc=$RC $OUT)"
CLEAN_CHECK_UID=$(( $(id -u) + 1 )) run --target "$REPO" --tmp "$FT"
[ "$RC" = 0 ] && ok "entries owned by another uid are never reported" || no "ownership filter" "(rc=$RC $OUT)"

# ---- scratchpad -------------------------------------------------------------------------------
fresh; mkdir -p "$REPO/scratch"; printf 'x\n' > "$REPO/scratch/a"; mkdir "$FT/tmp.pad"; ago 48 "$FT/tmp.pad"
CLEAN_CHECK_SCRATCHPAD="$REPO/scratch" run --target "$REPO" --tmp "$FT"
if has "scratch/a"; then no "scratchpad entry (untracked) must not be reported" "($OUT)"; else ok "scratchpad untracked entry never reported"; fi
CLEAN_CHECK_SCRATCHPAD="$FT/tmp.pad" run --target "$REPO" --tmp "$FT"
has "tmp.pad" && no "scratchpad that is itself a stale tmp.* entry must not be reported" "($OUT)" || ok "scratchpad that is itself a stale tmp.* entry never reported"
run --target "$REPO" --tmp "$FT"
{ has "scratch/a" && has "tmp.pad"; } && ok "without the scratchpad declaration both are findings" || no "scratchpad control" "($OUT)"

# ---- read-only --------------------------------------------------------------------------------
fresh; printf 'x\n' > "$REPO/stray"; : > "$FT/tmp.old"; ago 48 "$FT/tmp.old"
before="$(snapshot)"; run --target "$REPO" --tmp "$FT"; after="$(snapshot)"
{ [ "$RC" = 1 ] && [ "$before" = "$after" ]; } && ok "read-only: run with findings changes nothing" || no "read-only" "(rc=$RC)"

# ---- default target is cwd --------------------------------------------------------------------
fresh; printf 'x\n' > "$REPO/stray"
OUT="$(cd "$REPO" && "$BASH_BIN" "$SUT" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && has "GARBAGE untracked stray"; } && ok "default --target is the current directory" || no "default target" "(rc=$RC $OUT)"

# ---- DEGRADED ---------------------------------------------------------------------------------
mkbin() { # mkbin DIR OMIT : PATH dir with symlinks to every tool the SUT may call except OMIT
  local d="$1" omit="$2" t p; mkdir -p "$d"
  for t in git find stat date id cat dirname basename sort grep sed awk tr mktemp; do
    [ "$t" = "$omit" ] && continue
    p="$(type -P "$t")" && ln -s "$p" "$d/$t"
  done
}
fresh
REQ="git"   # the only runtime dependency of the Go engine (the script also needed find date sort id stat)
ok "REQUIRED_TOOLS: git is the one dependency of rsdd hygiene clean-check"
for tool in $REQ; do
  mkbin "$TMP/bin-no-$tool" "$tool"
  OUT="$(PATH="$TMP/bin-no-$tool" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
  { [ "$RC" = 3 ] && has "DEGRADED" && has "$tool not found"; } && ok "$tool missing -> exit 3 with typed DEGRADED" || no "degraded without $tool" "(rc=$RC $OUT)"
done

# ---- --stale-hours is decimal, never octal ----------------------------------------------------
fresh
for v in 08 09 010; do
  run --target "$REPO" --tmp "$FT" --stale-hours "$v"
  want=$((10#$v))
  { [ "$RC" = 0 ] && has "older than ${want}h"; } && ok "--stale-hours $v parsed as decimal $want" || no "octal $v" "(rc=$RC $OUT)"
done
run --target "$REPO" --tmp "$FT" --stale-hours 99999999999999999999
[ "$RC" = 2 ] && ok "--stale-hours beyond 9 digits -> exit 2 (no arithmetic overflow)" || no "huge stale" "(rc=$RC)"
run --target "$REPO" --tmp "$FT" --stale-hours -1
[ "$RC" = 2 ] && ok "--stale-hours -1 -> exit 2" || no "negative stale" "(rc=$RC)"

# ---- --stale-hours 0 makes every owned tmp.* entry stale (documented in clean-check.v1.md) -------
fresh; : > "$FT/tmp.hour"; ago 1 "$FT/tmp.hour"
run --target "$REPO" --tmp "$FT" --stale-hours 0
{ [ "$RC" = 1 ] && has "stale-tmp $FT/tmp.hour"; } && ok "--stale-hours 0 flags a 1h-old tmp.* entry" || no "stale 0" "(rc=$RC $OUT)"
run --target "$REPO" --tmp "$FT" --stale-hours 2
{ [ "$RC" = 0 ] && ! has "tmp.hour"; } && ok "--stale-hours 2 spares the same 1h-old entry" || no "stale 2" "(rc=$RC $OUT)"

# ---- scan failures and the readdir race (shimmed git/find, first on PATH) ---------------------
mkdir -p "$TMP/shim-git" "$TMP/shim-find" "$TMP/shim-race"
REALGIT="$(type -P git)"; REALFIND="$(type -P find)"
printf '#!/bin/sh\nif [ "$1" = -C ]; then cd "$2" || exit 1; shift 2; fi\n[ "$1" = ls-files ] && { echo "shim-git-diagnostic: ls-files exploded" >&2; exit 1; }\nexec %s "$@"\n' "$REALGIT" > "$TMP/shim-git/git"
printf '#!/bin/sh\necho "shim-find-diagnostic: find exploded" >&2\nexit 1\n' > "$TMP/shim-find/find"
mkdir -p "$TMP/shim-sort" "$TMP/shim-revparse" "$TMP/shim-warn"
printf '#!/bin/sh\nif [ "$1" = -C ]; then cd "$2" || exit 1; shift 2; fi\n[ "$1" = rev-parse ] && echo "warning: shim-warn unreadable attributes file" >&2\nexec %s "$@"\n' "$REALGIT" > "$TMP/shim-warn/git"
chmod +x "$TMP/shim-warn/git"
printf '#!/bin/sh\nexit 1\n' > "$TMP/shim-sort/sort"
printf '#!/bin/sh\nif [ "$1" = -C ]; then cd "$2" || exit 1; shift 2; fi\n[ "$1" = rev-parse ] && { echo "fatal: detected dubious ownership in repository" >&2; exit 128; }\nexec %s "$@"\n' "$REALGIT" > "$TMP/shim-revparse/git"
chmod +x "$TMP/shim-sort/sort" "$TMP/shim-revparse/git"
# shim-race models an entry vanishing mid-scan: find fails UNLESS it is given -ignore_readdir_race.
# The flag is stripped before exec so the shim also works over a find that lacks it (BSD).
printf '#!/bin/sh\nf=0; n=$#\nwhile [ "$n" -gt 0 ]; do a=$1; shift; n=$((n-1)); if [ "$a" = -ignore_readdir_race ]; then f=1; else set -- "$@" "$a"; fi; done\n[ "$f" = 1 ] || exit 1\nexec %s "$@"\n' "$REALFIND" > "$TMP/shim-race/find"
chmod +x "$TMP/shim-git/git" "$TMP/shim-find/find" "$TMP/shim-race/find"
fresh; printf 'x\n' > "$REPO/stray"
OUT="$(PATH="$TMP/shim-git:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && has "git ls-files failed"; } && ok "failing git ls-files -> exit 2, never a quiet clean" || no "git scan failure" "(rc=$RC $OUT)"
{ has "shim-git-diagnostic"; } && ok "git stderr diagnostic is surfaced on failure" || no "git stderr discarded" "(rc=$RC $OUT)"
fresh
OUT="$(PATH="$TMP/shim-revparse:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && has "dubious ownership"; } && ok "git rev-parse failure reports git's own reason, not 'not a work tree'" || no "rev-parse misdiagnosis" "(rc=$RC $OUT)"
fresh; printf 'x\n' > "$REPO/stray"
OUT="$(PATH="$TMP/shim-warn:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && has "GARBAGE untracked stray"; } && ok "successful rev-parse with a stderr warning still scans normally" || no "rev-parse warning misread" "(rc=$RC $OUT)"
fresh; : > "$FT/tmp.old1"; : > "$FT/tmp.old2"; ago 48 "$FT/tmp.old1"; ago 48 "$FT/tmp.old2"
OUT="$(PATH="$TMP/shim-sort:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
skip "failing sort: retired, the sort is in process"
fresh
OUT="$(PATH="$TMP/shim-find:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
skip "failing find: TestDegradedStatesAreValues"
skip "find stderr diagnostic: stderr-passthrough scenarios (git) and TestFindErrorText"
: > "$FT/tmp.old"; ago 48 "$FT/tmp.old"
OUT="$(PATH="$TMP/shim-race:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && has "stale-tmp $FT/tmp.old"; } && ok "readdir race tolerated: scan runs with -ignore_readdir_race and completes" || no "readdir race" "(rc=$RC $OUT)"

# ---- kit #1207 part 4: scratchpad artifacts a block mentions / scripts with no manifest row ------------
# A file left in the session scratchpad that some block of the target mentions (by basename or path) is
# evidence about to be lost: UNPRESERVED-ARTIFACT <file> cited by <block>. A scratchpad SCRIPT (sh ps1 py
# java ...) listed in no sources/probes/*/SCRIPTS-MANIFEST.md is UNMANIFESTED-SCRIPT <file>. Both are
# findings (exit 1), never deletions. Absent/unset scratchpad is a typed state, never a quiet zero.
cc_scratch() { # sets REPO FT SP: fresh repo, a scratchpad dir, one committed block "notes/b1.md"
  fresh; SP="$TMP/spad$n"; mkdir -p "$SP" "$REPO/notes" "$REPO/.research-sdd"
  printf 'sources/\n' > "$REPO/.research-sdd/keep.txt"
  printf '%s\n' "$@" > "$REPO/notes/b1.md"
  git -C "$REPO" add notes/b1.md .research-sdd/keep.txt
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q -m blk
}
cc_scratch "Result came from probe_run.log [CERT-hw]"
printf 'x\n' > "$SP/probe_run.log"; printf 'x\n' > "$SP/unrelated.txt"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
[ "$RC" = 1 ] && ok "#1207: scratchpad file cited by a block -> exit 1" || no "scratch cited exit" "(rc=$RC)"
has "UNPRESERVED-ARTIFACT $SP/probe_run.log cited by notes/b1.md" && ok "#1207: typed UNPRESERVED-ARTIFACT line names file and block" || no "unpreserved line" "($OUT)"
if has "unrelated.txt"; then no "#1207: a scratchpad file no block mentions must not be reported" "($OUT)"; else ok "#1207: unmentioned scratchpad file not reported"; fi
has "scratchpad: 2 file(s)" && ok "#1207: summary states how many scratchpad files were scanned" || no "scratch count in summary" "($OUT)"

cc_scratch "Used the helper at $TMP/spad$((n+1))/deep/dir/tool.out for it"
mkdir -p "$SP/deep/dir"; printf 'x\n' > "$SP/deep/dir/tool.out"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
has "UNPRESERVED-ARTIFACT $SP/deep/dir/tool.out cited by notes/b1.md" && ok "#1207: nested scratchpad file mentioned by full path is found" || no "nested/full path" "($OUT)"

cc_scratch "first.dat" "mid.dat" "last.dat"
for f in first mid last; do printf 'x\n' > "$SP/$f.dat"; done
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ has "$SP/first.dat" && has "$SP/mid.dat" && has "$SP/last.dat"; } && ok "#1207: first/middle/last mentioned files all reported" || no "first/mid/last" "($OUT)"

cc_scratch "Ran /tmp/x/probe_run.log"
printf 'x\n' > "$SP/probe_run.log"
unset CLEAN_CHECK_SCRATCHPAD
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "scratchpad: not set"; } && ok "#1207: unset scratchpad is a typed 'not set' state in the summary, not a pass-by-silence" || no "unset state" "(rc=$RC $OUT)"
CLEAN_CHECK_SCRATCHPAD="$TMP/no-such-spad" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "ABSENT-SCRATCHPAD $TMP/no-such-spad" && has "scratchpad: absent"; } && ok "#1207: configured-but-absent scratchpad -> typed ABSENT-SCRATCHPAD, not 0 files" || no "absent state" "(rc=$RC $OUT)"
run --target "$REPO" --tmp "$FT" --scratchpad "$SP"
{ [ "$RC" = 1 ] && has "UNPRESERVED-ARTIFACT $SP/probe_run.log"; } && ok "#1207: --scratchpad flag works like the env var" || no "flag" "(rc=$RC $OUT)"

cc_scratch "no mention here"
printf 'echo hi\n' > "$SP/run.sh"; printf 'print(1)\n' > "$SP/calc.py"; printf 'x\n' > "$SP/data.bin"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && has "UNMANIFESTED-SCRIPT $SP/run.sh" && has "UNMANIFESTED-SCRIPT $SP/calc.py"; } && ok "#1207: scratchpad scripts with no manifest are UNMANIFESTED-SCRIPT" || no "unmanifested" "(rc=$RC $OUT)"
if has "data.bin"; then no "#1207: a non-script, unmentioned file must not be reported" "($OUT)"; else ok "#1207: non-script file not an UNMANIFESTED-SCRIPT"; fi
mkdir -p "$REPO/sources/probes/b1"
printf '| script | sha256 | run/step | block | executed-on | remote-sha256 | role |\n|---|---|---|---|---|---|---|\n| `run.sh` | %064d | sh run.sh | B1 | h | - | EXECUTED |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
git -C "$REPO" add sources/probes/b1/SCRIPTS-MANIFEST.md
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
if has "UNMANIFESTED-SCRIPT $SP/run.sh"; then no "#1207: a script with a manifest row must not be reported" "($OUT)"; else ok "#1207: manifest row silences UNMANIFESTED-SCRIPT"; fi
has "UNMANIFESTED-SCRIPT $SP/calc.py" && ok "#1207: a script with no row is still reported when other rows exist" || no "calc still unmanifested" "($OUT)"

cc_scratch "uses mentioned.sh here"
printf 'echo hi\n' > "$SP/mentioned.sh"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ has "UNPRESERVED-ARTIFACT $SP/mentioned.sh cited by notes/b1.md" && has "UNMANIFESTED-SCRIPT $SP/mentioned.sh" && has "CLEAN-CHECK: 2 finding(s)"; } && ok "#1207: a mentioned unmanifested script yields both typed lines" || no "both lines" "($OUT)"

# ---- kit #1207 RDD round 1: boundaries, exact manifest cell, manifests excluded, preserved copies -------
cc_scratch "Ran prerun.sh first, then tuned."
printf 'x\n' > "$SP/run.sh"; printf 'x\n' > "$SP/prerun.sh"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
has "UNPRESERVED-ARTIFACT $SP/prerun.sh cited by notes/b1.md" && ok "#1207 boundary: prerun.sh mention reports prerun.sh" || no "boundary prerun" "($OUT)"
if has "UNPRESERVED-ARTIFACT $SP/run.sh"; then no "#1207 boundary: run.sh is not mentioned by 'prerun.sh'" "($OUT)"; else ok "#1207 boundary: run.sh is not a substring match of prerun.sh"; fi
cc_scratch "The layout was about the banana."
printf 'x\n' > "$SP/out"; printf 'x\n' > "$SP/a"; printf 'x\n' > "$SP/ana"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
if has "UNPRESERVED-ARTIFACT"; then no "#1207 boundary: short names 'out'/'a'/'ana' inside words must not match" "($OUT)"; else ok "#1207 boundary: short names inside other words do not match"; fi
cc_scratch 'See `out` and (a) then ana, done.'
printf 'x\n' > "$SP/out"; printf 'x\n' > "$SP/a"; printf 'x\n' > "$SP/ana"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ has "UNPRESERVED-ARTIFACT $SP/out " && has "UNPRESERVED-ARTIFACT $SP/a " && has "UNPRESERVED-ARTIFACT $SP/ana "; } && ok "#1207 boundary: backtick / paren / comma delimited whole-word mentions match" || no "boundary delimiters" "($OUT)"
cc_scratch "Kept in probe.log." "also probe.log.bak and /deep/path/other.dat:12"
printf 'x\n' > "$SP/probe.log"; printf 'x\n' > "$SP/other.dat"; printf 'x\n' > "$SP/probe.lo"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ has "$SP/probe.log cited" && has "$SP/other.dat cited"; } && ok "#1207 boundary: sentence-final period and path:line mentions match" || no "period / path:line" "($OUT)"
if has "$SP/probe.lo cited"; then no "#1207 boundary: probe.lo must not match probe.log" "($OUT)"; else ok "#1207 boundary: a prefix of a longer name does not match"; fi

# live scratchpad: a file vanishing mid-walk must not abort the run (RDD round 3)
mkdir -p "$TMP/shim-benign" "$TMP/shim-hard"
# shim-benign: a find WITHOUT -ignore_readdir_race (BSD-like) whose scratchpad walk lists the files, then reports an
# ENOENT for a vanished entry and exits 1. shim-hard: same but the error is a permission failure (must stay fatal).
for _mode in benign hard; do
  case "$_mode" in benign) _msg="find: './vanished.tmp': No such file or directory";; hard) _msg="find: './locked': Permission denied";; esac
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -ignore_readdir_race ] && exit 1; done\ncase "$1" in "$CC_SHIM_DIR"*) %s "$@"; echo "%s" >&2; exit 1;; esac\nexec %s "$@"\n' "$REALFIND" "$_msg" "$REALFIND" > "$TMP/shim-$_mode/find"
  chmod +x "$TMP/shim-$_mode/find"
done
cc_scratch "Result in probe_run.log"; printf 'x\n' > "$SP/probe_run.log"; printf 'x\n' > "$SP/other.txt"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-race:$PATH" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && has "UNPRESERVED-ARTIFACT $SP/probe_run.log"; } && ok "#1207 live scratchpad: -ignore_readdir_race is passed to the scratchpad walk" || no "scratch race flag" "(rc=$RC $OUT)"
CC_SHIM_DIR="$SP" CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-benign:$PATH" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && has "UNPRESERVED-ARTIFACT $SP/probe_run.log" && has "scratchpad: 2 file(s)"; } && ok "#1207 live scratchpad: ENOENT-only errors from a flagless find are benign" || no "scratch ENOENT fallback" "(rc=$RC $OUT)"
CC_SHIM_DIR="$SP" CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-hard:$PATH" run --target "$REPO" --tmp "$FT"
skip "#1207 live scratchpad hard error: unreadable-scratchpad scenarios (internal/core/cleancheck)"

# quoted / bracketed / unpadded-table citations (RDD round 2)
for _form in '"x.sh"' "'x.sh'" '[x.sh]' '[label](x.sh)' '|x.sh|' '<x.sh>' '(x.sh)'; do
  cc_scratch "see $_form here"; printf 'x\n' > "$SP/x.sh"
  CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
  has "UNPRESERVED-ARTIFACT $SP/x.sh cited by notes/b1.md" && ok "#1207 boundary: mention written as $_form matches" || no "boundary form $_form" "($OUT)"
done
cc_scratch "see xx.sh and x.shx and .x.sh"; printf 'x\n' > "$SP/x.sh"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
if has "UNPRESERVED-ARTIFACT"; then no "#1207 boundary: xx.sh / x.shx / .x.sh are not x.sh" "($OUT)"; else ok "#1207 boundary: look-alike names still do not match"; fi

# manifest: first cell, exact
cc_scratch "nothing mentioned"
printf 'echo\n' > "$SP/run.sh"
mkdir -p "$REPO/sources/probes/b1"
printf '| script | sha256 | run/step | block | executed-on | remote-sha256 | role |\n|---|---|---|---|---|---|---|\n| `prerun.sh` | %064d | sh run.sh --go | B1 | h | - | EXECUTED |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
has "UNMANIFESTED-SCRIPT $SP/run.sh" && ok "#1207 manifest: run.sh is not listed by a prerun.sh row or by a later cell naming it" || no "manifest exact" "($OUT)"
printf '| `run.sh` | %064d | x | B1 | h | - | EXECUTED |\n' 0 >> "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
if has "UNMANIFESTED-SCRIPT $SP/run.sh"; then no "#1207 manifest: an exact first-cell row lists the script" "($OUT)"; else ok "#1207 manifest: exact first-cell row lists the script"; fi

# the manifest is a preservation record, not a block that cites the scratchpad
cc_scratch "nothing mentioned"
printf 'x\n' > "$SP/data.csv"; mkdir -p "$REPO/sources/probes/b1"
printf '| script | sha256 | run/step | block | executed-on | remote-sha256 | role |\n|---|---|---|---|---|---|---|\n| `x.sh` | %064d | python x.sh data.csv | B1 | h | - | RECIPE |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
if has "UNPRESERVED-ARTIFACT $SP/data.csv"; then no "#1207: SCRIPTS-MANIFEST.md must not count as a citing block" "($OUT)"; else ok "#1207: SCRIPTS-MANIFEST.md is excluded from the citing blocks"; fi

# preserved byte-identical copy
cc_scratch "Result in probe_run.log [CERT-hw]"
printf 'same bytes\n' > "$SP/probe_run.log"; mkdir -p "$REPO/sources/probes/b1"; printf 'same bytes\n' > "$REPO/sources/probes/b1/probe_run.log"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && ! has "UNPRESERVED-ARTIFACT"; } && ok "#1207: byte-identical copy under sources/probes/ -> not UNPRESERVED" || no "preserved copy" "(rc=$RC $OUT)"
has "preserved-copies: 1" && ok "#1207: preserved copies are counted in the summary" || no "preserved count" "($OUT)"
printf 'different\n' > "$REPO/sources/probes/b1/probe_run.log"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
has "UNPRESERVED-ARTIFACT $SP/probe_run.log" && ok "#1207: a same-named but different preserved file does not count" || no "different copy" "($OUT)"

# #2190: a backslash in the SCRATCHPAD file name makes GNU sha256sum print "\<hex>" for the positional form,
# so the digest never matched the (unescaped) preserved copy and a genuinely preserved artifact read UNPRESERVED.
cc_scratch 'Result in probe\run.log [CERT-hw]'
printf 'same bytes\n' > "$SP/probe\\run.log"; mkdir -p "$REPO/sources/probes/b1"; printf 'same bytes\n' > "$REPO/sources/probes/b1/copy.log"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && ! has "UNPRESERVED-ARTIFACT" && has "preserved-copies: 1"; } && ok "#2190: backslash scratchpad name still matches its byte-identical preserved copy" || no "#2190 backslash name" "(rc=$RC $OUT)"

# manifest scan failure is typed DEGRADED, never 'no manifests'
mkdir -p "$TMP/shim-mffind"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = SCRIPTS-MANIFEST.md ] && { echo "shim-mffind: find exploded" >&2; exit 1; }; done\nexec %s "$@"\n' "$(type -P find)" > "$TMP/shim-mffind/find"
chmod +x "$TMP/shim-mffind/find"
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/run.sh"; mkdir -p "$REPO/sources/probes/b1"; printf 'x\n' > "$REPO/sources/probes/b1/f"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-mffind:$PATH" run --target "$REPO" --tmp "$FT"
skip "#1659 manifest scan failure: TestUnreadableManifestAndProbesRefuse"
# the probes scan (preserved copies) fails the same way: exit 2, never a quiet 'nothing preserved'
mkdir -p "$TMP/shim-pbfind"
printf '#!/bin/sh\ncase "$*" in *SCRIPTS-MANIFEST.md*) exec %s "$@";; *sources/probes*) echo "shim-pbfind: find exploded" >&2; exit 1;; esac\nexec %s "$@"\n' "$(type -P find)" "$(type -P find)" > "$TMP/shim-pbfind/find"
chmod +x "$TMP/shim-pbfind/find"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-pbfind:$PATH" run --target "$REPO" --tmp "$FT"
skip "#1659 probes scan failure: TestUnreadableManifestAndProbesRefuse"

# #1659: DEGRADED-NO-SHA256 is a counted degraded state (exit 3 when otherwise clean, 1 when findings stand)
mkbin "$TMP/bin-nosha" ""
cc_scratch "nothing mentioned"; printf 'x\n' > "$SP/data.dat"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/bin-nosha" run --target "$REPO" --tmp "$FT"
skip "#1659 no-sha256 clean run: retired, DEGRADED-NO-SHA256 no longer exists"
printf 'echo\n' > "$SP/loose.sh"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/bin-nosha" run --target "$REPO" --tmp "$FT"
skip "#1659 no-sha256 with findings: retired, the hash is computed in process"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && ! has "DEGRADED"; } && ok "#1659: with a sha256 tool the same run carries no degraded state" || no "sha256 control" "(rc=$RC $OUT)"

# kit #1676: the shared manifest parser is loaded LAZILY — only when the target holds a SCRIPTS-MANIFEST (the
# scratchpad UNMANIFESTED-SCRIPT check is its only consumer). A copy of the SUT with NO lib/ beside it must still
# run on a manifest-free target, and must still fail closed (exit 2) as soon as a manifest needs parsing.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/clean-check.sh"
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/loose.sh"; mkdir -p "$REPO/sources/probes"   # probes dir present, NO manifest
OUT="$(CLEAN_CHECK_SCRATCHPAD="$SP" "$BASH_BIN" "$TMP/nolib/clean-check.sh" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
skip "#1676 eager helper load: retired, no bash helper is loaded"
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/loose.sh"; mkdir -p "$REPO/sources/probes/b1"   # a fresh repo: this one HAS a manifest
printf '| `loose.sh` | %064d | x |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
OUT="$(CLEAN_CHECK_SCRATCHPAD="$SP" "$BASH_BIN" "$TMP/nolib/clean-check.sh" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
skip "#1676 helper missing: retired, the manifest is read in process (TestUnreadableManifestAndProbesRefuse)"
# fixture for the lib-resolution controls: a target whose manifest forces the helper to load, run CLEAN
cc_scratch "nothing mentioned"; mkdir -p "$REPO/sources/probes/b1"; printf 'echo\n' > "$SP/run.sh"
printf '| `run.sh` | %064d | x |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"; LKR="$REPO"; LKT="$FT"; LKS="$SP"

# #1659 lib resolution: the script's own dir (symlinks followed), never the caller's cwd or the link's dir
mkdir -p "$TMP/lnk-ok" "$TMP/lnk-plant/lib" "$TMP/cwd-plant/lib"
ln -s "$SUT" "$TMP/lnk-ok/clean-check.sh"; ln -s "$SUT" "$TMP/lnk-plant/clean-check.sh"
for _pd in "$TMP/lnk-plant/lib" "$TMP/cwd-plant/lib"; do
  printf 'echo PLANTED-LIB-SOURCED\nscripts_manifest_rows() { return 0; }\n' > "$_pd/scripts-manifest.sh"
done
fresh
OUT="$(cd "$TMP/cwd-plant" && CLEAN_CHECK_SCRATCHPAD="$LKS" "$BASH_BIN" "$TMP/lnk-ok/clean-check.sh" --target "$LKR" --tmp "$LKT" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && has "CLEAN-CHECK: clean"; } && ok "#1659: a symlinked invocation resolves lib/ through the link" || no "symlink invocation" "(rc=$RC $OUT)"
OUT="$(cd "$TMP/cwd-plant" && CLEAN_CHECK_SCRATCHPAD="$LKS" "$BASH_BIN" "$TMP/lnk-plant/clean-check.sh" --target "$LKR" --tmp "$LKT" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && ! has "PLANTED-LIB-SOURCED"; } && ok "#1659: a lib planted beside the link or in the cwd is never sourced" || no "planted lib sourced" "(rc=$RC $OUT)"
# CC-MF-PARSE fail-closed: a manifest the shared parser cannot read is exit 2, never 'no rows'
if [ "$(id -u)" = 0 ]; then echo "  (skipped, not counted: running as root, chmod 000 does not block reads)"; else   # #1676: a skip is not a pass
  cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/run.sh"; mkdir -p "$REPO/sources/probes/b1"
  printf '| `run.sh` | %064d | x |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"; chmod 000 "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
  CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
  { [ "$RC" = 2 ] && has "cannot parse manifest" && ! has "UNMANIFESTED-SCRIPT"; } && ok "#1659: an unreadable manifest -> exit 2 'cannot parse manifest' (parser fails closed)" || no "manifest parse failure" "(rc=$RC $OUT)"
fi

# #1659 shared manifest parser: a row needs a 64-hex sha cell; a path-bearing first cell lists its basename
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/tool.sh"; printf 'echo\n' > "$SP/deep.sh"
mkdir -p "$REPO/sources/probes/b1"
printf '| script | sha256 | run/step | block | executed-on | remote-sha256 | role |\n|---|---|---|---|---|---|---|\n| `tool.sh` | TODO | x | B1 | h | - | EXECUTED |\n| `sub/deep.sh` | %064d | x | B1 | h | - | EXECUTED |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ has "UNMANIFESTED-SCRIPT $SP/tool.sh" && ! has "UNMANIFESTED-SCRIPT $SP/deep.sh"; } && ok "#1659: a row without a 64-hex sha cell does not list its script; a valid path row does" || no "shared parser in clean-check" "(rc=$RC $OUT)"

# a tracked block deleted from disk is skipped and counted, not a crash
cc_scratch "mentions gone.dat"
printf 'x\n' > "$SP/gone.dat"; rm -f "$REPO/notes/b1.md"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "blocks-missing-on-disk: 1"; } && ok "#1207: deleted tracked block skipped and counted (no abort)" || no "missing block" "(rc=$RC $OUT)"

# ---- kit #1277 slice 3: report-only retention scans (worktrees, merged branches, _evidence backups) --------
GIT=(git -c user.name=t -c user.email=t@example.invalid)
fresh_main() { fresh; git -C "$REPO" branch -M main; }
# ---- clean repo: nothing to report, summary names the new states, exit 0
fresh_main
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && [ "$(lines)" -le 2 ] && has "warnings: 0" && has "evidence: none found" && has "branches: base main, 0 local, 0 remote"; } \
  && ok "retention: clean repo -> exit 0, summary states each scan, warnings: 0" || no "retention clean" "(rc=$RC $OUT)"
# ---- merged branches
fresh_main; git -C "$REPO" branch mergedbr; git -C "$REPO" switch -q -c wip; printf 'w\n' > "$REPO/w.txt"; git -C "$REPO" add w.txt; "${GIT[@]}" -C "$REPO" commit -q -m w; git -C "$REPO" switch -q main
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "WARN merged-branch mergedbr merged into main"; } && ok "merged local branch -> WARN line, exit code unchanged (0)" || no "merged branch" "(rc=$RC $OUT)"
{ ! has "merged-branch wip" && ! has "merged-branch main"; } && ok "unmerged branch and the base itself are never reported" || no "merged false positive" "($OUT)"
fresh_main; git -C "$REPO" switch -q -c cur
run --target "$REPO" --tmp "$FT" --base main
{ [ "$RC" = 0 ] && ! has "merged-branch cur"; } && ok "the branch HEAD is on is never reported as merged" || no "current branch reported" "(rc=$RC $OUT)"
fresh_main; git -C "$REPO" branch livewt; WTL="$TMP/wt-live-$n"; git -C "$REPO" worktree add -q "$WTL" livewt
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && ! has "merged-branch livewt" && ! has "stale-worktree"; } && ok "a branch checked out in a live worktree is not reported; live worktree not stale" || no "worktree-checked-out branch" "(rc=$RC $OUT)"
fresh_main; run --target "$REPO" --tmp "$FT" --base nope
{ [ "$RC" = 2 ] && has "--base ref not found"; } && ok "unknown --base -> exit 2" || no "bad base" "(rc=$RC $OUT)"
fresh; git -C "$REPO" branch -M trunk
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "ABSENT-BASE" && has "branches: no base"; } && ok "no resolvable base -> typed ABSENT-BASE, scan skipped, exit 0" || no "absent base" "(rc=$RC $OUT)"
run --target "$REPO" --tmp "$FT" --base trunk
{ [ "$RC" = 0 ] && ! has "ABSENT-BASE" && has "base trunk"; } && ok "--base names the base explicitly" || no "explicit base" "(rc=$RC $OUT)"
# remote-tracking refs
fresh_main; RB="$TMP/remote$n.git"; git init -q --bare "$RB"; git -C "$REPO" remote add origin "$RB"; git -C "$REPO" push -q origin main; git -C "$REPO" push -q origin main:refs/heads/rdone
git -C "$REPO" fetch -q origin; git -C "$REPO" remote set-head origin main >/dev/null
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "WARN merged-remote-branch origin/rdone merged into origin/main"; } && ok "merged remote-tracking ref -> WARN line (base = origin/HEAD)" || no "merged remote" "(rc=$RC $OUT)"
{ ! has "origin/main merged" && ! has "origin/HEAD" && ! has "merged-branch main"; } && ok "base twins (origin/main, origin/HEAD, local main) are never reported" || no "base twin reported" "($OUT)"
# ---- stale worktrees
fresh_main; WTG="$TMP/wt-gone-$n"; git -C "$REPO" worktree add -q "$WTG" -b gonebr; rm -rf "$WTG"
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "WARN stale-worktree" && has "wt-gone-$n missing"; } && ok "worktree whose path is gone -> WARN stale-worktree ... missing, exit 0" || no "stale worktree" "(rc=$RC $OUT)"
has "worktrees: 2 registered, 1 stale" && ok "summary counts registered and stale worktrees" || no "worktree summary" "($OUT)"
fresh_main; WTK="$TMP/wt-locked-$n"; git -C "$REPO" worktree add -q --lock "$WTK" -b lockedbr; rm -rf "$WTK"
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "stale-worktree $WTK missing (locked)"; } && ok "locked worktree with a missing path is still reported (git does not mark it prunable)" || no "locked missing" "(rc=$RC $OUT)"
fresh_main; WTB="$TMP/wt-broken-$n"; git -C "$REPO" worktree add -q "$WTB" -b brokenbr; rm "$WTB/.git"
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "stale-worktree $WTB prunable (gitdir file"; } && ok "worktree git marks prunable (path exists) -> WARN ... prunable (<git's reason>)" || no "prunable worktree" "(rc=$RC $OUT)"
# ---- _evidence backups
fresh_main; mkdir -p "$REPO/_evidence/t1" "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"
: > "$REPO/_evidence/t1/rollback-old.tar"; ago 480 "$REPO/_evidence/t1/rollback-old.tar"
: > "$REPO/_evidence/t1/ROLLBACK-new.tar"; : > "$REPO/_evidence/t1/notes-old.txt"; ago 480 "$REPO/_evidence/t1/notes-old.txt"
mkdir -p "$REPO/_evidence/t1/Backup-dir"; ago 480 "$REPO/_evidence/t1/Backup-dir"
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "WARN stale-backup $REPO/_evidence/t1/rollback-old.tar age=20d retention=14d" && has "stale-backup $REPO/_evidence/t1/Backup-dir"; } && ok "old rollback/backup entries -> WARN stale-backup with age and retention, exit 0" || no "stale backup" "(rc=$RC $OUT)"
{ ! has "ROLLBACK-new" && ! has "notes-old"; } && ok "young backups and non-backup names are not reported" || no "backup false positive" "($OUT)"
run --target "$REPO" --tmp "$FT" --backup-days 30
{ [ "$RC" = 0 ] && ! has "stale-backup" && has "0 older than 30d"; } && ok "--backup-days overrides the retention age" || no "backup-days" "(rc=$RC $OUT)"
run --target "$REPO" --tmp "$FT" --backup-days abc; [ "$RC" = 2 ] && ok "non-numeric --backup-days -> exit 2" || no "bad backup-days" "(rc=$RC)"
EV2="$TMP/ev-explicit-$n"; mkdir -p "$EV2/x"; : > "$EV2/x/my-backup.sql"; ago 480 "$EV2/x/my-backup.sql"
run --target "$REPO" --tmp "$FT" --evidence "$EV2"
{ [ "$RC" = 0 ] && has "stale-backup $EV2/x/my-backup.sql" && ! has "t1/rollback-old"; } && ok "--evidence DIR scans only that directory" || no "explicit evidence" "(rc=$RC $OUT)"
run --target "$REPO" --tmp "$FT" --evidence "$TMP/no-such-evidence"
{ [ "$RC" = 0 ] && has "ABSENT-EVIDENCE $TMP/no-such-evidence" && has "evidence: absent"; } && ok "explicit --evidence dir missing -> typed ABSENT-EVIDENCE (not a silent zero)" || no "absent evidence" "(rc=$RC $OUT)"
# WARNs never turn a clean run into findings, and never hide a real finding
printf 'x\n' > "$REPO/stray.json"
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && has "GARBAGE untracked stray.json" && has "stale-backup" && has "1 finding(s)"; } && ok "WARN lines coexist with a real finding: exit 1, count unchanged by WARNs" || no "warn+finding" "(rc=$RC $OUT)"
# ---- read-only
fresh_main; git -C "$REPO" branch mergedbr; mkdir -p "$REPO/_evidence/t"; : > "$REPO/_evidence/t/rollback.tar"; ago 480 "$REPO/_evidence/t/rollback.tar"; printf '_evidence/\n' > "$REPO/.gitignore"
before="$(snapshot)"; brefs="$(git -C "$REPO" for-each-ref | cksum)"
run --target "$REPO" --tmp "$FT"
{ [ "$before" = "$(snapshot)" ] && [ "$brefs" = "$(git -C "$REPO" for-each-ref | cksum)" ] && has "merged-branch mergedbr" && has "stale-backup"; } && ok "retention scans delete nothing (files, branches, worktrees untouched)" || no "retention not read-only" "($OUT)"
# ---- DEGRADED retention scans (shimmed git / find)
mkdir -p "$TMP/shim-wtfail" "$TMP/shim-brfail" "$TMP/shim-evfail"
printf '#!/bin/sh\nif [ "$1" = -C ]; then cd "$2" || exit 1; shift 2; fi\n[ "$1" = worktree ] && { echo "shim-git-diagnostic: worktree exploded" >&2; exit 1; }\nexec %s "$@"\n' "$REALGIT" > "$TMP/shim-wtfail/git"
printf '#!/bin/sh\nif [ "$1" = -C ]; then cd "$2" || exit 1; shift 2; fi\n[ "$1" = for-each-ref ] && { echo "shim-git-diagnostic: for-each-ref exploded" >&2; exit 1; }\nexec %s "$@"\n' "$REALGIT" > "$TMP/shim-brfail/git"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -iname ] && { echo "shim-find-diagnostic: evidence find exploded" >&2; exit 1; }; done\nexec %s "$@"\n' "$REALFIND" > "$TMP/shim-evfail/find"
chmod +x "$TMP/shim-wtfail/git" "$TMP/shim-brfail/git" "$TMP/shim-evfail/find"
fresh_main; mkdir -p "$REPO/_evidence/t" "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"
OUT="$(PATH="$TMP/shim-wtfail:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 3 ] && has "DEGRADED-WORKTREE-SCAN" && has "worktree exploded" && has "CLEAN-CHECK: degraded" && has "worktree scan failed"; } && ok "failing git worktree -> typed DEGRADED-WORKTREE-SCAN, exit 3 (not clean)" || no "worktree degraded" "(rc=$RC $OUT)"
OUT="$(PATH="$TMP/shim-brfail:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 3 ] && has "DEGRADED-BRANCH-SCAN" && has "for-each-ref exploded" && has "CLEAN-CHECK: degraded"; } && ok "failing git for-each-ref -> typed DEGRADED-BRANCH-SCAN, exit 3" || no "branch degraded" "(rc=$RC $OUT)"
OUT="$(PATH="$TMP/shim-evfail:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
skip "#failing evidence find: TestDegradedStatesAreValues (DEGRADED-EVIDENCE-SCAN)"
printf 'x\n' > "$REPO/stray.json"
OUT="$(PATH="$TMP/shim-wtfail:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && has "DEGRADED-WORKTREE-SCAN" && has "GARBAGE untracked stray.json"; } && ok "degraded retention scan + real finding -> findings still win (exit 1)" || no "degraded+finding" "(rc=$RC $OUT)"
if [ "$(id -u)" != 0 ]; then
  fresh_main; mkdir -p "$REPO/_evidence/t/locked" "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"; chmod 000 "$REPO/_evidence/t/locked"
  run --target "$REPO" --tmp "$FT"
  chmod 755 "$REPO/_evidence/t/locked"
  { [ "$RC" = 3 ] && has "DEGRADED-EVIDENCE-SCAN"; } && ok "really unreadable evidence subdir -> DEGRADED-EVIDENCE-SCAN, exit 3" || no "unreadable evidence" "(rc=$RC $OUT)"
fi

# ---- review round: W1 discovery scope, W2 early --base, S4 suppressed branches, S5 pruned backups, S7 newline worktree path
mkdir -p "$TMP/shim-evdisc" "$TMP/shim-evperm"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = _evidence ] && { echo "shim-find-diagnostic: discovery exploded" >&2; exit 1; }; done\nexec %s "$@"\n' "$REALFIND" > "$TMP/shim-evdisc/find"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = _evidence ] && { %s "$@"; echo "$SHIM_ERR_LINE" >&2; exit 1; }; done\nexec %s "$@"\n' "$REALFIND" "$REALFIND" > "$TMP/shim-evperm/find"
chmod +x "$TMP/shim-evdisc/find" "$TMP/shim-evperm/find"
if [ "$(id -u)" != 0 ]; then
  fresh_main; mkdir -p "$REPO/other/locked" "$REPO/.research-sdd"; printf '_evidence/\nother/\n' > "$REPO/.research-sdd/keep.txt"; chmod 000 "$REPO/other/locked"
  run --target "$REPO" --tmp "$FT"
  chmod 755 "$REPO/other/locked"
  { [ "$RC" = 0 ] && has "INFO evidence-discovery skipped unreadable directory" && has "other/locked" && ! has "DEGRADED"; } \
    && ok "unreadable NON-_evidence dir -> typed INFO naming the path, not DEGRADED (exit 0)" || no "unreadable non-evidence dir" "(rc=$RC $OUT)"
  fresh_main; mkdir -p "$REPO/_evidence/t/locked" "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"; chmod 000 "$REPO/_evidence/t/locked"
  run --target "$REPO" --tmp "$FT"
  chmod 755 "$REPO/_evidence/t/locked"
  { [ "$RC" = 3 ] && has "DEGRADED-EVIDENCE-SCAN" && has "_evidence/t/locked"; } && ok "unreadable dir UNDER _evidence still degrades and names the path" || no "unreadable evidence names path" "(rc=$RC $OUT)"
fi
fresh_main; OUT="$(PATH="$TMP/shim-evdisc:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
skip "#discovery degrade: TestClassifyDiscovery (fatal arm) and TestDegradedStatesAreValues"
# round 2: summary counts skipped dirs; classification is anchored and relative to the target
evperm() { OUT="$(SHIM_ERR_LINE="$1" PATH="$TMP/shim-evperm:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?; }
fresh_main; mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
evperm "find: '$REPO/other/locked': Permission denied"
skip "#none found suffix with unreadable dirs: scenario evidence-unreadable-and-none-found"
fresh_main; mkdir -p "$REPO/_evidence/t" "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"
evperm "find: '$REPO/other/locked': Permission denied"
skip "#skip suffix on a run with evidence dirs: scenario evidence-unreadable-and-none-found and TestClassifyDiscovery"
fresh_main; mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
evperm "find: '$REPO/Permission denied': No such file or directory"
skip "#anchored Permission denied match: TestClassifyDiscovery (a dir named Permission denied)"
evperm "find: '$REPO/_evidence/t/locked': Permission denied"
skip "#permission error under an _evidence dir degrades: TestClassifyDiscovery and scenario evidence-unreadable-inside-an-evidence-dir"
CE="$TMP/case_evidence_$n/_evidence"; mkdir -p "$CE"; REPO_SAVE="$REPO"; REPO="$CE/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" branch -M main 2>/dev/null
mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
"${GIT[@]}" -C "$REPO" add -A >/dev/null 2>&1; "${GIT[@]}" -C "$REPO" commit -q -m i 2>/dev/null
evperm "find: '$REPO/other/locked': Permission denied"
skip "#target path containing _evidence: TestAnEvidenceNamedTargetStillSkipsAnUnreadableDir (internal/core/cleancheck)"
REPO="$REPO_SAVE"
# W2: --base validated before any scan prints
fresh_main; printf 'x\n' > "$REPO/stray.json"
run --target "$REPO" --tmp "$FT" --base nope
{ [ "$RC" = 2 ] && has "--base ref not found" && ! has "GARBAGE" && ! has "ABSENT-KEEPLIST" && ! has "CLEAN-CHECK"; } && ok "bad --base -> exit 2 with no partial scan output" || no "base early" "(rc=$RC $OUT)"
# S4: degraded worktree scan -> checked-out branches unknown -> local merged-branch WARNs suppressed
fresh_main; git -C "$REPO" branch mergedbr; mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
OUT="$(PATH="$TMP/shim-wtfail:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 3 ] && has "DEGRADED-WORKTREE-SCAN" && ! has "WARN merged-branch" && has "INFO merged-branch scan of local branches skipped"; } && ok "worktree scan degraded -> local merged-branch WARNs suppressed (typed INFO)" || no "S4 suppress" "(rc=$RC $OUT)"
# S5: a matching backup dir and its matching children are reported once
fresh_main; mkdir -p "$REPO/_evidence/rollback-d"; : > "$REPO/_evidence/rollback-d/rollback-inner.tar"; ago 480 "$REPO/_evidence/rollback-d/rollback-inner.tar"; ago 480 "$REPO/_evidence/rollback-d"
mkdir -p "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"
run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 0 ] && has "stale-backup $REPO/_evidence/rollback-d age" && ! has "rollback-inner" && has "warnings: 1"; } && ok "matching backup dir reported once; its matching children are pruned" || no "S5 prune" "(rc=$RC $OUT)"
# S7: a newline inside a worktree path survives (git worktree list -z)
fresh_main; mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"; WNL="$TMP/wtnl$n/a"$'\n'"b"
if git -C "$REPO" worktree add -q "$WNL" -b nlbr 2>/dev/null; then
  rm -rf "$TMP/wtnl$n"
  run --target "$REPO" --tmp "$FT"
  { [ "$RC" = 0 ] && [[ "$OUT" == *"a"$'\n'"b missing"* ]] && has "warnings: 1"; } && ok "worktree path containing a newline is reported whole" || no "S7 newline path" "(rc=$RC $OUT)"
else echo "  (skipped, not counted: git cannot create a worktree with a newline in its path)"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for clean-check.sh (shim) --"
  # The retired controls sed the old script body, which is gone: each is a typed SKIP naming the Go tests that replace it.
  skip "teeth (old scan mutants) --exclude-standard, keep-list globs, trees, comments, self-exemption: TestCleanCheckDifferential keep-* and untracked-* cases and TestGlobMatch (internal/core/cleancheck)"
  skip "teeth (old stale-tmp mutants) age comparison, name filter, ownership, hours: TestCleanCheckDifferential stale-* cases and the olderThan unit tests"
  skip "teeth (old scratchpad mutants) exemption classes, citations, manifests, preserved copies: TestCleanCheckDifferential scratch-* cases and the blocks/probes unit tests"
  skip "teeth (old failure-channel mutants) git/find/sort markers, readdir race, discovery classification: TestClassifyDiscovery, TestDegradedStatesAreValues and the gitStub scenarios"
  skip "teeth (old retention mutants) branches, worktrees, base choice, backups: TestCleanCheckDifferential branch-*, worktree-*, evidence-* cases"
  # mkshim NAME [SEDEXPR] -> a (mutant) shim with the lib beside it: $MUT/NAME/clean-check.sh, $MUT/NAME/lib/rsdd-exec.sh
  mkshim() {
    local d="$MUT/$1"
    mkdir -p "$d/lib" && cp "$HERE/../lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
    if [ -z "${2:-}" ]; then cp "$SUT" "$d/clean-check.sh"; return 0; fi
    mutant_sed "$SUT" "$d/clean-check.sh" "$2" >/dev/null 2>&1 || { no "teeth $1: could not build the mutant (refused by lib/mutant.sh)"; return 1; }
  }
  fresh; SW="$REPO"; SWT="$FT"; printf 'x\n' > "$SW/stray.json"
  SHIM_LINE='^rsdd_exec hygiene clean-check "\$@"'
  GOODSHIM="$MUT/good/clean-check.sh"
  mkshim good "" || exit 2
  fresh; SWC="$REPO"; printf 'x\n' > "$SWC/other.json"   # the cwd the argument-less mutant scans instead of --target
  if mkshim A 's#'"$SHIM_LINE"'#rsdd_exec hygiene clean-check#'; then
    tooth "teeth(shim-args): arguments no longer forwarded -> the scan reads the working directory, not --target" 1 1 "$MUT/A/clean-check.sh" \
      --orig "$GOODSHIM" --good-has 'GARBAGE untracked stray.json' --bad-lacks 'GARBAGE untracked stray.json' -- "$BASH_BIN" -c 'cd "$0" && exec "$BASH" "$@"' "$SWC" @SUT@ --target "$SW" --tmp "$SWT"
  fi
  if mkshim B 's#^rsdd_exec hygiene clean-check #rsdd_exec hygiene clean-checks #'; then
    tooth "teeth(shim-command): wrong subcommand name -> an unknown command, not a scan" 1 2 "$MUT/B/clean-check.sh" \
      --orig "$GOODSHIM" -- "$BASH_BIN" @SUT@ --target "$SW" --tmp "$SWT"
  fi
  if mkshim D 's#'"$SHIM_LINE"'#( rsdd_exec hygiene clean-check "$@" ); exit 0#'; then
    tooth "teeth(shim-exit): exit code laundered to 0 -> a finding no longer fails the caller" 1 0 "$MUT/D/clean-check.sh" \
      --orig "$GOODSHIM" -- "$BASH_BIN" @SUT@ --target "$SW" --tmp "$SWT"
  fi
  # the library guard: a shim with no lib beside it says so and exits 2; a mutant that exits 0 there hides a missing binary
  mkdir -p "$MUT/Cgood" "$MUT/C"
  cp "$SUT" "$MUT/Cgood/clean-check.sh"
  if mutant_sed "$SUT" "$MUT/C/clean-check.sh" 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#' >/dev/null 2>&1; then
    tooth "teeth(shim-guard): missing-library guard exits 0 -> a missing rsdd reads as a clean scan" 2 0 "$MUT/C/clean-check.sh" \
      --orig "$MUT/Cgood/clean-check.sh" --good-has 'rsdd-exec.sh missing' -- "$BASH_BIN" @SUT@ --target "$SW" --tmp "$SWT"
  else no "teeth(shim-guard): could not build the mutant (refused by lib/mutant.sh)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
