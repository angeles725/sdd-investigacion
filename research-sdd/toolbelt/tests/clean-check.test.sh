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
REQ="$(sed -n 's/^REQUIRED_TOOLS="\([^"]*\)".*/\1/p' "$SUT")"
[ -n "$REQ" ] && ok "REQUIRED_TOOLS list extracted from the SUT: $REQ" || no "REQUIRED_TOOLS extraction (would loop over nothing)"
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
{ [ "$RC" = 2 ] && has "sort failed"; } && ok "failing sort -> exit 2, never a quiet clean" || no "sort failure" "(rc=$RC $OUT)"
fresh
OUT="$(PATH="$TMP/shim-find:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && has "find failed"; } && ok "failing find -> exit 2, never a quiet clean" || no "find scan failure" "(rc=$RC $OUT)"
{ has "shim-find-diagnostic"; } && ok "find stderr diagnostic is surfaced on failure" || no "find stderr discarded" "(rc=$RC $OUT)"
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
{ [ "$RC" = 2 ] && has "Permission denied" && has "find failed"; } && ok "#1207 live scratchpad: a non-ENOENT find error is still a failed scan (exit 2)" || no "scratch hard error" "(rc=$RC $OUT)"

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

# manifest scan failure is typed DEGRADED, never 'no manifests'
mkdir -p "$TMP/shim-mffind"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = SCRIPTS-MANIFEST.md ] && { echo "shim-mffind: find exploded" >&2; exit 1; }; done\nexec %s "$@"\n' "$(type -P find)" > "$TMP/shim-mffind/find"
chmod +x "$TMP/shim-mffind/find"
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/run.sh"; mkdir -p "$REPO/sources/probes/b1"; printf 'x\n' > "$REPO/sources/probes/b1/f"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-mffind:$PATH" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 2 ] && has "manifest scan failed" && ! grep -q "^UNMANIFESTED-SCRIPT" <<<"$OUT"; } && ok "#1659: failed manifest scan -> exit 2 (scan failure, header contract), not 'no manifests'" || no "manifest find rc" "(rc=$RC $OUT)"
# the probes scan (preserved copies) fails the same way: exit 2, never a quiet 'nothing preserved'
mkdir -p "$TMP/shim-pbfind"
printf '#!/bin/sh\ncase "$*" in *SCRIPTS-MANIFEST.md*) exec %s "$@";; *sources/probes*) echo "shim-pbfind: find exploded" >&2; exit 1;; esac\nexec %s "$@"\n' "$(type -P find)" "$(type -P find)" > "$TMP/shim-pbfind/find"
chmod +x "$TMP/shim-pbfind/find"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/shim-pbfind:$PATH" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 2 ] && has "probes scan failed"; } && ok "#1659: failed probes scan -> exit 2, preserved copies not silently skipped" || no "probes find rc" "(rc=$RC $OUT)"

# #1659: DEGRADED-NO-SHA256 is a counted degraded state (exit 3 when otherwise clean, 1 when findings stand)
mkbin "$TMP/bin-nosha" ""
cc_scratch "nothing mentioned"; printf 'x\n' > "$SP/data.dat"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/bin-nosha" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 3 ] && has "DEGRADED-NO-SHA256" && has "CLEAN-CHECK: degraded" && ! has "CLEAN-CHECK: clean"; } && ok "#1659: no sha256 tool, no findings -> exit 3 + degraded summary (never 'clean')" || no "no-sha256 clean run" "(rc=$RC $OUT)"
printf 'echo\n' > "$SP/loose.sh"
CLEAN_CHECK_SCRATCHPAD="$SP" PATH="$TMP/bin-nosha" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && has "UNMANIFESTED-SCRIPT $SP/loose.sh" && has "DEGRADED-NO-SHA256" && has "degraded: preserved-copy check skipped"; } && ok "#1659: no sha256 tool + findings -> exit 1, summary still names the degradation" || no "no-sha256 with findings" "(rc=$RC $OUT)"
CLEAN_CHECK_SCRATCHPAD="$SP" run --target "$REPO" --tmp "$FT"
{ [ "$RC" = 1 ] && ! has "DEGRADED"; } && ok "#1659: with a sha256 tool the same run carries no degraded state" || no "sha256 control" "(rc=$RC $OUT)"

# kit #1676: the shared manifest parser is loaded LAZILY — only when the target holds a SCRIPTS-MANIFEST (the
# scratchpad UNMANIFESTED-SCRIPT check is its only consumer). A copy of the SUT with NO lib/ beside it must still
# run on a manifest-free target, and must still fail closed (exit 2) as soon as a manifest needs parsing.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/clean-check.sh"
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/loose.sh"; mkdir -p "$REPO/sources/probes"   # probes dir present, NO manifest
NLR="$REPO"; NLT="$FT"; NLS="$SP"
OUT="$(CLEAN_CHECK_SCRATCHPAD="$SP" "$BASH_BIN" "$TMP/nolib/clean-check.sh" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 1 ] && has "UNMANIFESTED-SCRIPT $SP/loose.sh" && ! has "helper"; } && ok "#1676: a manifest-free target never needs the helper (lib/ absent, findings still reported)" || no "#1676 eager helper load" "(rc=$RC $OUT)"
cc_scratch "nothing mentioned"; printf 'echo\n' > "$SP/loose.sh"; mkdir -p "$REPO/sources/probes/b1"   # a fresh repo: this one HAS a manifest
printf '| `loose.sh` | %064d | x |\n' 0 > "$REPO/sources/probes/b1/SCRIPTS-MANIFEST.md"
OUT="$(CLEAN_CHECK_SCRATCHPAD="$SP" "$BASH_BIN" "$TMP/nolib/clean-check.sh" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && has "cannot find helper"; } && ok "#1676: a manifest-bearing target with the helper missing fails closed (exit 2 'cannot find helper')" || no "#1676 helper-missing must fail closed" "(rc=$RC $OUT)"
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
{ [ "$RC" = 3 ] && has "DEGRADED-EVIDENCE-SCAN" && has "evidence find exploded" && has "CLEAN-CHECK: degraded"; } && ok "failing evidence find -> typed DEGRADED-EVIDENCE-SCAN, exit 3" || no "evidence degraded" "(rc=$RC $OUT)"
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
{ [ "$RC" = 3 ] && has "DEGRADED-EVIDENCE-SCAN" && has "discovery exploded"; } && ok "failing discovery find (unattributable error) -> DEGRADED-EVIDENCE-SCAN with the message" || no "discovery degrade" "(rc=$RC $OUT)"
# round 2: summary counts skipped dirs; classification is anchored and relative to the target
evperm() { OUT="$(SHIM_ERR_LINE="$1" PATH="$TMP/shim-evperm:$PATH" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?; }
fresh_main; mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
evperm "find: '$REPO/other/locked': Permission denied"
{ [ "$RC" = 0 ] && has "INFO evidence-discovery" && has "evidence: none found, 1 unreadable dir(s) skipped"; } && ok "skipped unreadable dir -> summary says so, never a bare 'none found'" || no "none found suffix" "(rc=$RC $OUT)"
fresh_main; mkdir -p "$REPO/_evidence/t" "$REPO/.research-sdd"; printf '_evidence/\n' > "$REPO/.research-sdd/keep.txt"
evperm "find: '$REPO/other/locked': Permission denied"
{ [ "$RC" = 0 ] && has "1 dir(s) scanned, 0 older than 14d, 1 unreadable dir(s) skipped"; } && ok "skip suffix also on a run that found evidence dirs" || no "scanned suffix" "(rc=$RC $OUT)"
fresh_main; mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
evperm "find: '$REPO/Permission denied': No such file or directory"
{ [ "$RC" = 3 ] && has "DEGRADED-EVIDENCE-SCAN"; } && ok "a non-permission error on a dir named 'Permission denied' is not skipped (anchored match)" || no "anchor" "(rc=$RC $OUT)"
evperm "find: '$REPO/_evidence/t/locked': Permission denied"
{ [ "$RC" = 3 ] && has "DEGRADED-EVIDENCE-SCAN" && has "_evidence/t/locked"; } && ok "permission error under an _evidence dir degrades (root-independent)" || no "evidence arm" "(rc=$RC $OUT)"
CE="$TMP/case_evidence_$n/_evidence"; mkdir -p "$CE"; REPO_SAVE="$REPO"; REPO="$CE/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" branch -M main 2>/dev/null
mkdir -p "$REPO/.research-sdd"; printf '# none\n' > "$REPO/.research-sdd/keep.txt"
"${GIT[@]}" -C "$REPO" add -A >/dev/null 2>&1; "${GIT[@]}" -C "$REPO" commit -q -m i 2>/dev/null
evperm "find: '$REPO/other/locked': Permission denied"
{ [ "$RC" = 0 ] && has "INFO evidence-discovery" && ! has "DEGRADED"; } && ok "a target path containing '_evidence' as a substring does not misclassify" || no "target path substring" "(rc=$RC $OUT)"
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
  echo "-- teeth --"
  # Each control deletes or inverts ONE guard in a COPY of the SUT (lib/mutant.sh refuses a no-op,
  # empty, syntax-broken or live-tree mutant) and asserts the exact GOOD verdict on the original
  # and the exact BAD verdict on the mutant.
  # mt LABEL SED-EXPR GOOD-RC BAD-RC [tooth flags...] -- ARGV...   (@SUT@ is substituted)
  mt() {
    local label="$1" expr="$2" grc="$3" brc="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }

  # World: ignored + stray + kept files, one stale and one young tmp.* entry.
  fresh; W="$REPO"; WT="$FT"
  mkdir -p "$W/.research-sdd" "$W/keep/sub" "$W/notes"
  printf 'ignored.log\n' > "$W/.gitignore"; git -C "$W" add .gitignore
  printf 'x\n' > "$W/ignored.log"; printf 'x\n' > "$W/stray.json"; printf 'x\n' > "$W/keep/sub/f"
  printf 'x\n' > "$W/one.txt"; printf 'x\n' > "$W/notes/a.md"
  : > "$WT/tmp.old"; ago 48 "$WT/tmp.old"; : > "$WT/tmp.young"
  : > "$WT/other.old"; ago 48 "$WT/other.old"
  cat > "$W/.research-sdd/keep.txt" <<'KL'
# a comment
keep/ # tree
one.txt # single file with a reason
notes/*.md
KL
  fresh; E="$REPO"; ET="$FT"            # a second repo with NO keep-list
  printf 'x\n' > "$E/stray.json"

  mt "untracked scan includes gitignored files without --exclude-standard" 's/ --exclude-standard//' 1 1 \
    --good-lacks 'ignored\.log' --bad-has 'ignored\.log' -- "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"
  mt "keep-list exact/glob matching disabled" 's/\[\[ "\$p" == \$g \]\] && return 0/false/' 1 1 \
    --good-lacks 'one\.txt' --bad-has 'GARBAGE untracked one\.txt' -- "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"
  mt "keep-list trailing-slash tree matching disabled" 's/\[\[ "\$p" == \$g\* \]\] && return 0/false/' 1 1 \
    --good-lacks 'keep/sub/f' --bad-has 'GARBAGE untracked keep/sub/f' -- "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"
  mt "keep.txt self-exemption removed" 's/\[ "\$p" = "\$KEEP_REL" \] && return 0/:/' 1 1 \
    --good-lacks 'research-sdd/keep\.txt' --bad-has 'GARBAGE untracked \.research-sdd/keep\.txt' -- "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"
  mt "comment lines counted as keep entries" "s/''|'#'\*) continue/'') continue/" 1 1 \
    --good-has 'keep-list entries: 3' --bad-lacks 'keep-list entries: 3' -- "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"
  mt "' # reason' suffix no longer stripped" "s/_line=\"\\\${_line%% #\*}\"/:/" 1 1 \
    --good-lacks 'one\.txt' --bad-has 'GARBAGE untracked one\.txt' -- "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"
  mt "ABSENT-KEEPLIST line suppressed" 's/\[ "\$KEEP_PRESENT" = 1 \] ||/true ||/' 1 1 \
    --good-has 'ABSENT-KEEPLIST' --bad-lacks 'ABSENT-KEEPLIST' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  mt "stale comparison inverted (-mmin -N)" 's/-mmin "+\$((STALE_H \* 60))"/-mmin "-$((STALE_H * 60))"/' 1 1 \
    --good-has 'stale-tmp .*tmp\.old' --good-lacks 'tmp\.young' --bad-has 'tmp\.young' --bad-lacks 'tmp\.old' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$WT"
  mt "tmp name filter widened to every entry" "s/-name 'tmp\\.\\*'/-name '*'/" 1 1 \
    --good-lacks 'other\.old' --bad-has 'other\.old' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$WT"
  fresh; CL="$REPO"; CLT="$FT"
  fresh; RT="$FT"; : > "$RT/tmp.old"; ago 48 "$RT/tmp.old"
  mt "ownership filter removed" 's/ -uid "\$OWNER_UID"//' 0 1 \
    --good-has 'CLEAN-CHECK: clean' --bad-has 'stale-tmp' -- env "CLEAN_CHECK_UID=$(( $(id -u) + 1 ))" "$BASH_BIN" @SUT@ --target "$CL" --tmp "$WT"
  mt "age printed in minutes, not hours" 's|/ 3600|/ 60|' 1 1 \
    --good-has 'age=48h' --bad-lacks 'age=48h' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$WT"
  # Scratchpad: both classes. SP holds an untracked scratch dir, SPT a stale tmp.* scratchpad.
  fresh; SP="$REPO"; SPT="$FT"; mkdir -p "$SP/scratch"; printf 'x\n' > "$SP/scratch/a"
  mkdir "$SPT/tmp.pad"; ago 48 "$SPT/tmp.pad"
  mt "scratchpad exemption removed (untracked class)" 's/_in_scratch "\$TARGET_P\/\$_rel" && continue/:/' 1 1 \
    --good-lacks 'scratch/a' --bad-has 'GARBAGE untracked scratch/a' -- env "CLEAN_CHECK_SCRATCHPAD=$SP/scratch" "$BASH_BIN" @SUT@ --target "$SP" --tmp "$SPT"
  mt "scratchpad exemption removed (tmp class)" 's/_in_scratch "\$_p" && continue/:/' 1 1 \
    --good-lacks 'tmp\.pad' --bad-has 'GARBAGE stale-tmp .*tmp\.pad' -- env "CLEAN_CHECK_SCRATCHPAD=$SPT/tmp.pad" "$BASH_BIN" @SUT@ --target "$E" --tmp "$SPT"
  mt "findings no longer change the exit code" 's/^exit 1$/exit 0/' 1 0 \
    --good-has 'finding' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  # DEGRADED probe: with git absent the mutant must NOT report exit 3 + DEGRADED.
  mt "tool-presence probe disabled" 's/command -v "\$_tool" >\/dev\/null 2>&1 ||/true ||/' 3 2 \
    --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env "PATH=$TMP/bin-no-git" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  mt "decimal normalization of --stale-hours removed (octal 08 breaks)" 's/STALE_H=\$((10#\$STALE_H))/:/' 0 2 \
    --good-has 'older than 8h' --bad-lacks 'CLEAN-CHECK: clean' -- "$BASH_BIN" @SUT@ --target "$CL" --tmp "$CLT" --stale-hours 08
  # Truncated/failed scans: a git, find or sort that fails must be exit 2, never a quiet clean.
  mt "readdir-race flag no longer passed to the scan" 's/\${FIND_RACE\[@\]+"\${FIND_RACE\[@\]}"}//' 1 2 \
    --good-has 'stale-tmp' --bad-has 'find failed' -- env "PATH=$TMP/shim-race:$PATH" "$BASH_BIN" @SUT@ --target "$E" --tmp "$RT"
  mt "git failure no longer detected (RC marker ignored, untracked scan)" '/git ls-files failed/s/"\${_items\[\$_last\]}" = "RC=0"/"x" = "x"/' 2 0 \
    --good-has 'git ls-files failed' -- env "PATH=$TMP/shim-git:$PATH" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  mt "find failure no longer detected (RC marker ignored, tmp scan)" '/find failed/s/"\${_items\[\$_last\]}" = "RC=0"/"x" = "x"/' 2 3 \
    --good-has 'find failed' --bad-lacks 'find failed' -- env "PATH=$TMP/shim-find:$PATH" "$BASH_BIN" @SUT@ --target "$CL" --tmp "$WT"
  fresh; ST="$FT"; : > "$ST/tmp.a"; : > "$ST/tmp.b"; ago 48 "$ST/tmp.a"; ago 48 "$ST/tmp.b"
  mt "sort failure no longer detected (RC marker ignored, sort step)" '/sort failed/s/"\${_sorted\[\$_slast\]}" = "RC=0"/"x" = "x"/' 2 1 \
    --good-has 'sort failed' -- env "PATH=$TMP/shim-sort:$PATH" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ST"
  mt "git stderr discarded again" 's|ls-files --others --exclude-standard -z$|ls-files --others --exclude-standard -z 2>/dev/null|' 2 2 \
    --good-has 'shim-git-diagnostic' --bad-lacks 'shim-git-diagnostic' -- env "PATH=$TMP/shim-git:$PATH" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  mt "find stderr discarded again" 's|-print0$|-print0 2>/dev/null|' 2 2 \
    --good-has 'shim-find-diagnostic' --bad-lacks 'shim-find-diagnostic' -- env "PATH=$TMP/shim-find:$PATH" "$BASH_BIN" @SUT@ --target "$CL" --tmp "$WT"
  mt "rev-parse reason dropped from the error" 's/: \${_gmsg:-git exited non-zero without output}//' 2 2 \
    --good-has 'dubious ownership' --bad-lacks 'dubious ownership' -- env "PATH=$TMP/shim-revparse:$PATH" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  mt "rev-parse stderr merged into the stdout comparison" 's/rev-parse --is-inside-work-tree 2>\/dev\/null)"/rev-parse --is-inside-work-tree 2>\&1)"/' 1 2 \
    --good-has 'GARBAGE untracked stray' --bad-has 'not inside a git work tree' -- env "PATH=$TMP/shim-warn:$PATH" "$BASH_BIN" @SUT@ --target "$W" --tmp "$WT"

  # kit #1207: scratchpad artifact teeth. World: a repo whose block mentions probe_run.log, plus an
  # unmentioned script; the scratchpad holds both. A second case has the scratchpad configured but absent.
  fresh; CR="$REPO"; CRT="$FT"; CSP="$TMP/cc-spad"; mkdir -p "$CSP" "$CR/notes" "$CR/.research-sdd"
  printf '# n\n' > "$CR/.research-sdd/keep.txt"; printf 'see probe_run.log\n' > "$CR/notes/b1.md"
  git -C "$CR" add notes/b1.md .research-sdd/keep.txt; git -C "$CR" -c user.name=t -c user.email=t@example.invalid commit -q -m b
  printf 'x\n' > "$CSP/probe_run.log"; printf 'echo\n' > "$CSP/tool.sh"
  mt "scratchpad citation match always misses" 's/_mentions "\$_b" "\$TARGET_P\/\$_bp"; _g=\$?/false; _g=1/' 1 1 \
    --good-has 'UNPRESERVED-ARTIFACT' --bad-lacks 'UNPRESERVED-ARTIFACT' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "$BASH_BIN" @SUT@ --target "$CR" --tmp "$CRT"
  mt "script extension filter matches everything" 's/\*\.sh|\*\.ps1|\*\.py|\*\.java|\*\.js|\*\.rb|\*\.pl|\*\.bat|\*\.cmd|\*\.groovy|\*\.kts)   # CC-SCRIPT-EXT/*)   # CC-SCRIPT-EXT/' 1 1 \
    --good-lacks 'UNMANIFESTED-SCRIPT .*probe_run' --bad-has 'UNMANIFESTED-SCRIPT .*probe_run' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "$BASH_BIN" @SUT@ --target "$CR" --tmp "$CRT"
  fresh; CM="$REPO"; CMT="$FT"; mkdir -p "$CM/sources/probes/b1" "$CM/.research-sdd"; printf '# n\n' > "$CM/.research-sdd/keep.txt"
  printf '| `tool.sh` | %064d | x | B1 | h | - | EXECUTED |\n' 0 > "$CM/sources/probes/b1/SCRIPTS-MANIFEST.md"
  git -C "$CM" add .research-sdd/keep.txt sources; git -C "$CM" -c user.name=t -c user.email=t@example.invalid commit -q -m m
  mt "manifest lookup always misses" '/# CC-MANIFEST-LOOKUP$/s/if ! grep -qxF -- "\$_b" <<<"\$_mf_names"; then/if true; then/' 0 1 \
    --good-lacks 'UNMANIFESTED-SCRIPT' --bad-has 'UNMANIFESTED-SCRIPT' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "$BASH_BIN" @SUT@ --target "$CM" --tmp "$CMT"
  mt "absent scratchpad no longer typed" '/# CC-ABSENT$/s/-d "\$SCRATCH_P"/-e "\/"/' 0 0 \
    --good-has 'ABSENT-SCRATCHPAD' --bad-lacks 'ABSENT-SCRATCHPAD' -- env "CLEAN_CHECK_SCRATCHPAD=$TMP/cc-no-spad" "$BASH_BIN" @SUT@ --target "$CR" --tmp "$CRT"

  # RDD round 1 teeth: substring matching, substring manifest lookup, manifest-as-block, preserved copy, find rc, missing block.
  fresh; RB="$REPO"; RBT="$FT"; RSP="$TMP/rb-spad"; mkdir -p "$RSP" "$RB/notes" "$RB/.research-sdd" "$RB/sources/probes/b1"
  printf 'sources/\n' > "$RB/.research-sdd/keep.txt"; printf 'Ran prerun.sh first.\n' > "$RB/notes/b1.md"
  printf 'x\n' > "$RSP/run.sh"; printf 'x\n' > "$RSP/prerun.sh"; printf 'same\n' > "$RSP/data.csv"
  printf '| `prerun.sh` | %064d | python x.sh data.csv | B1 | h | - | RECIPE |\n' 0 > "$RB/sources/probes/b1/SCRIPTS-MANIFEST.md"
  git -C "$RB" add notes/b1.md .research-sdd/keep.txt sources; git -C "$RB" -c user.name=t -c user.email=t@example.invalid commit -q -m rb
  mt "citation match degraded to bare substring" '/grep -qE -- "(^|/s/.*/  grep -qF -- "\$1" "\$2"/' 1 1 \
    --good-lacks 'UNPRESERVED-ARTIFACT .*/run\.sh ' --bad-has 'UNPRESERVED-ARTIFACT .*/run\.sh ' -- env "CLEAN_CHECK_SCRATCHPAD=$RSP" "$BASH_BIN" @SUT@ --target "$RB" --tmp "$RBT"
  mt "manifest lookup degraded to substring" '/# CC-MANIFEST-LOOKUP$/s/grep -qxF/grep -qF/' 1 1 \
    --good-has 'UNMANIFESTED-SCRIPT .*/run\.sh' --bad-lacks 'UNMANIFESTED-SCRIPT .*/run\.sh' -- env "CLEAN_CHECK_SCRATCHPAD=$RSP" "$BASH_BIN" @SUT@ --target "$RB" --tmp "$RBT"
  mt "manifest files counted as citing blocks" '/\[ "\${_bp##\*\/}" = "SCRIPTS-MANIFEST.md" \] \&\& continue/d' 1 1 \
    --good-lacks 'UNPRESERVED-ARTIFACT .*data\.csv' --bad-has 'UNPRESERVED-ARTIFACT .*data\.csv' -- env "CLEAN_CHECK_SCRATCHPAD=$RSP" "$BASH_BIN" @SUT@ --target "$RB" --tmp "$RBT"
  printf 'Ran prerun.sh and probe_run.log\n' > "$RB/notes/b1.md"; printf 'same\n' > "$RSP/probe_run.log"; printf 'same\n' > "$RB/sources/probes/b1/probe_run.log"
  mt "preserved-copy check disabled" '/# CC-PRESERVED$/s/if \[ -n "\$_h" \] \&\& grep -qxF -- "\$_h" <<<"\$_probe_shas"; then _same=1; fi/:/' 1 1 \
    --good-lacks 'UNPRESERVED-ARTIFACT .*probe_run\.log' --bad-has 'UNPRESERVED-ARTIFACT .*probe_run\.log' -- env "CLEAN_CHECK_SCRATCHPAD=$RSP" "$BASH_BIN" @SUT@ --target "$RB" --tmp "$RBT"
  mt "manifest scan RC ignored" '/# CC-MF-RC$/s/"\${_mf\[\$_mlast\]}" = "RC=0"/"x" = "x"/' 2 1 \
    --good-has 'manifest scan failed' --bad-lacks 'manifest scan failed' -- env "CLEAN_CHECK_SCRATCHPAD=$RSP" "PATH=$TMP/shim-mffind:$PATH" "$BASH_BIN" @SUT@ --target "$RB" --tmp "$RBT"
  mt "probes scan RC ignored" '/# CC-PB-RC$/s/"\${_pl\[\$_plast\]}" = "RC=0"/"x" = "x"/' 2 1 \
    --good-has 'probes scan failed' --bad-lacks 'probes scan failed' -- env "CLEAN_CHECK_SCRATCHPAD=$RSP" "PATH=$TMP/shim-pbfind:$PATH" "$BASH_BIN" @SUT@ --target "$RB" --tmp "$RBT"
  # kit #1659: a run without sha256sum/shasum is a counted degraded state, never a clean exit 0
  mt "missing sha256 tool no longer marks the run degraded" '/# CC-NO-SHA$/,/^    fi$/s/DEGRADED=1/:/' 3 0 \
    --good-has 'CLEAN-CHECK: degraded' --bad-has 'CLEAN-CHECK: clean' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "PATH=$TMP/bin-nosha" "$BASH_BIN" @SUT@ --target "$CM" --tmp "$CMT"
  mt "degraded run exits 0 after the summary" '/# CC-DEGRADED-EXIT/,/^    exit 3$/s/exit 3/exit 0/' 3 0 \
    --good-has 'CLEAN-CHECK: degraded' --bad-has 'CLEAN-CHECK: degraded' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "PATH=$TMP/bin-nosha" "$BASH_BIN" @SUT@ --target "$CM" --tmp "$CMT"
  # kit #1659 lib resolution: symlinks followed (the mutant is run THROUGH a symlink; the original resolves the real lib/)
  LNKRUN='d="$(mktemp -d)"; ln -s "$1" "$d/clean-check.sh"; bash "$d/clean-check.sh" "${@:2}"; r=$?; rm -rf "$d"; exit $r'
  mt "script symlink no longer followed when locating lib/" '/# CC-LIB-RESOLVE$/s/while \[ -L "\$_src" \]/while false/' 0 2 \
    --good-has 'CLEAN-CHECK: clean' --bad-has 'cannot find helper' -- env "CLEAN_CHECK_SCRATCHPAD=$LKS" "$BASH_BIN" -c "$LNKRUN" _ @SUT@ --target "$LKR" --tmp "$LKT"
  # kit #1676: lazy helper load — a manifest-free target (probes dir present, no manifest) must run with lib/ absent
  mt "helper loaded eagerly: every sources/probes target needs lib/" '/# CC-LIB-LAZY/s/if \[ "\$_mlast" -gt 0 \]/if true/' 1 2 \
    --good-has 'UNMANIFESTED-SCRIPT' --bad-has 'cannot find helper' -- env "CLEAN_CHECK_SCRATCHPAD=$NLS" "$BASH_BIN" -c 'd="$(mktemp -d)"; cp "$1" "$d/clean-check.sh"; bash "$d/clean-check.sh" "${@:2}"; r=$?; rm -rf "$d"; exit $r' _ @SUT@ --target "$NLR" --tmp "$NLT"
  if [ "$(id -u)" != 0 ]; then
    fresh; PW="$REPO"; PWT="$FT"; PWS="$TMP/pw-spad"; mkdir -p "$PWS" "$PW/sources/probes/b1" "$PW/.research-sdd"
    printf 'sources/\n' > "$PW/.research-sdd/keep.txt"; printf 'echo\n' > "$PWS/run.sh"
    printf '| `run.sh` | %064d | x |\n' 0 > "$PW/sources/probes/b1/SCRIPTS-MANIFEST.md"; chmod 000 "$PW/sources/probes/b1/SCRIPTS-MANIFEST.md"
    mt "manifest parse failure no longer fails closed" '/# CC-MF-PARSE$/s/ || { _err "cannot parse manifest \${_mf\[\$_j\]}"; exit 2; }//' 2 1 \
      --good-has 'cannot parse manifest' --bad-lacks 'cannot parse manifest' -- env "CLEAN_CHECK_SCRATCHPAD=$PWS" "$BASH_BIN" @SUT@ --target "$PW" --tmp "$PWT"
  fi
  mt "manifest rows no longer read from the shared parser" '/# CC-MF-PARSE$/s/_rows="\$(scripts_manifest_rows "\$TARGET_P" "\${_mf\[\$_j\]}")"/_rows=""/' 0 1 \
    --good-lacks 'UNMANIFESTED-SCRIPT' --bad-has 'UNMANIFESTED-SCRIPT' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "$BASH_BIN" @SUT@ --target "$CM" --tmp "$CMT"
  fresh; RM="$REPO"; RMT="$FT"; RMS="$TMP/rm-spad"; mkdir -p "$RMS" "$RM/.research-sdd" "$RM/notes"; printf '# n\n' > "$RM/.research-sdd/keep.txt"
  printf 'x\n' > "$RM/notes/gone.md"; git -C "$RM" add notes/gone.md .research-sdd/keep.txt; git -C "$RM" -c user.name=t -c user.email=t@example.invalid commit -q -m g; rm "$RM/notes/gone.md"
  printf 'x\n' > "$RMS/unrelated.dat"
  mt "missing-on-disk blocks no longer skipped" '/# CC-MISSING$/d' 0 2 \
    --good-has 'blocks-missing-on-disk: 1' -- env "CLEAN_CHECK_SCRATCHPAD=$RMS" "$BASH_BIN" @SUT@ --target "$RM" --tmp "$RMT"

  # RDD round 3 teeth: the scratchpad walk's race handling.
  mt "scratchpad walk loses -ignore_readdir_race" '/# CC-SCRATCH-FIND$/s/ \${FIND_RACE\[@\]+"\${FIND_RACE\[@\]}"}//' 1 2 \
    --good-has 'UNPRESERVED-ARTIFACT' --bad-has 'find failed' -- env "CLEAN_CHECK_SCRATCHPAD=$CSP" "PATH=$TMP/shim-race:$PATH" "$BASH_BIN" @SUT@ --target "$CR" --tmp "$CRT"
  mt "ENOENT-only errors no longer benign" '/# CC-ENOENT-BENIGN$/s/_frc=0; fi/:; fi/' 1 2 \
    --good-has 'UNPRESERVED-ARTIFACT' --bad-has 'find failed' -- env "CC_SHIM_DIR=$CSP" "CLEAN_CHECK_SCRATCHPAD=$CSP" "PATH=$TMP/shim-benign:$PATH" "$BASH_BIN" @SUT@ --target "$CR" --tmp "$CRT"
  mt "every find error treated as benign" '/# CC-ENOENT-BENIGN$/s/\[ "\$_other" -eq 0 \]/true/' 2 1 \
    --good-has 'find failed' --bad-has 'UNPRESERVED-ARTIFACT' -- env "CC_SHIM_DIR=$CSP" "CLEAN_CHECK_SCRATCHPAD=$CSP" "PATH=$TMP/shim-hard:$PATH" "$BASH_BIN" @SUT@ --target "$CR" --tmp "$CRT"

  # kit #1277 slice 3 teeth: the report-only retention scans.
  # World R: merged branch, live + gone worktrees, old + young rollback backups, an old non-backup file.
  fresh_main; R="$REPO"; RT="$FT"; mkdir -p "$R/_evidence/t1" "$R/.research-sdd"; printf '_evidence/\n' > "$R/.research-sdd/keep.txt"
  git -C "$R" branch mergedbr; git -C "$R" branch livewt; git -C "$R" worktree add -q "$TMP/rw-live" livewt
  git -C "$R" worktree add -q "$TMP/rw-gone" -b gonebr; rm -rf "$TMP/rw-gone"
  git -C "$R" worktree add -q --lock "$TMP/rw-locked" -b lockedbr; rm -rf "$TMP/rw-locked"   # locked + missing: git does NOT mark it prunable
  git -C "$R" worktree add -q "$TMP/rw-broken" -b brokenbr; rm "$TMP/rw-broken/.git"          # path exists, git marks it prunable
  : > "$R/_evidence/t1/rollback-old.tar"; ago 480 "$R/_evidence/t1/rollback-old.tar"; : > "$R/_evidence/t1/ROLLBACK-new.tar"
  mt "stale worktree detection (missing path) removed" '/# CC-WT-MISSING/s/\[ ! -e "\$_wp" \]/false/' 0 0 \
    --good-has 'rw-locked missing \(locked\)' --bad-lacks 'rw-locked missing' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "git's prunable marker no longer reported" 's/elif \[ -n "\$_wprun" \]/elif false/' 0 0 \
    --good-has 'rw-broken prunable \(gitdir file' --bad-lacks 'rw-broken prunable' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "branches checked out in a worktree are reported as merged" 's/\[ "\$_chk" = 1 \] && continue/:/' 0 0 \
    --good-lacks 'merged-branch livewt' --bad-has 'merged-branch livewt' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "backup retention age filter removed" '/# CC-EV-FIND/s/ -mmin "+\$((BACKUP_D \* 1440))"//' 0 0 \
    --good-lacks 'ROLLBACK-new' --bad-has 'ROLLBACK-new' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "backup retention default changed from 14 days" 's/BACKUP_D=14$/BACKUP_D=30/' 0 0 \
    --good-has 'stale-backup' --bad-lacks 'stale-backup' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "a WARN is counted as a finding (exit code changes)" '/^_warn()/s/WARNINGS=\$((WARNINGS + 1))/FINDINGS=$((FINDINGS + 1))/' 0 1 \
    --good-has 'WARN merged-branch mergedbr' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "failed worktree list no longer degrades the run" '/^  _degrade "DEGRADED-WORKTREE-SCAN/s/.*/  :/' 3 0 \
    --good-has 'DEGRADED-WORKTREE-SCAN' --bad-lacks 'DEGRADED-WORKTREE-SCAN' -- env "PATH=$TMP/shim-wtfail:$PATH" "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "failed branch listing no longer degrades the run" '/^    _degrade "DEGRADED-BRANCH-SCAN/s/.*/    :/' 3 0 \
    --good-has 'DEGRADED-BRANCH-SCAN' --bad-lacks 'DEGRADED-BRANCH-SCAN' -- env "PATH=$TMP/shim-brfail:$PATH" "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "failed evidence find no longer degrades the run" '/^      _degrade "DEGRADED-EVIDENCE-SCAN find failed or was truncated/s/_degrade .*/:; _evbad=$((_evbad + 1))/' 3 0 \
    --good-has 'DEGRADED-EVIDENCE-SCAN' --bad-lacks 'DEGRADED-EVIDENCE-SCAN' -- env "PATH=$TMP/shim-evfail:$PATH" "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  mt "absent explicit --evidence dir is no longer typed" "s/printf 'ABSENT-EVIDENCE %s\\\\n' \"\\\$EVID_ARG\"; //" 0 0 \
    --good-has 'ABSENT-EVIDENCE' --bad-lacks 'ABSENT-EVIDENCE' -- "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT" --evidence "$TMP/no-such-evidence"
  # Review-round teeth. Worlds: NB = no base + no _evidence; PR = nested old backup dir.
  fresh; git -C "$REPO" branch -M trunk; NB="$REPO"; NBT="$FT"
  fresh_main; mkdir -p "$REPO/_evidence/rollback-d"; : > "$REPO/_evidence/rollback-d/rollback-inner.tar"; ago 480 "$REPO/_evidence/rollback-d/rollback-inner.tar"; ago 480 "$REPO/_evidence/rollback-d"; PR="$REPO"; PRT="$FT"
  mkdir -p "$PR/.research-sdd"; printf '_evidence/\n' > "$PR/.research-sdd/keep.txt"
  mt "ABSENT-BASE line removed" "/^  printf 'ABSENT-BASE/s/.*/  :/" 0 0 \
    --good-has 'ABSENT-BASE' --bad-lacks 'ABSENT-BASE' -- "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "unattributable discovery find failure no longer degrades" '/^    _degrade "DEGRADED-EVIDENCE-SCAN find for _evidence directories/s/_degrade .*/:/' 3 0 \
    --good-has 'DEGRADED-EVIDENCE-SCAN' --bad-lacks 'DEGRADED-EVIDENCE-SCAN' -- env "PATH=$TMP/shim-evdisc:$PATH" "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "evidence: none found state lost" 's/EV_STATE="none found"/EV_STATE="not evaluated"/' 0 0 \
    --good-has 'evidence: none found' --bad-lacks 'evidence: none found' -- "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "backup-dir prune removed (children double-reported)" '/# CC-EV-FIND/s/ -prune//' 0 0 \
    --good-lacks 'rollback-inner' --bad-has 'rollback-inner' -- "$BASH_BIN" @SUT@ --target "$PR" --tmp "$PRT"
  mt "degraded worktree scan no longer suppresses local branch WARNs" 's/\[ "\$_wt_ok" = 1 \] || { continue; }/:/' 3 3 \
    --good-lacks 'WARN merged-branch' --bad-has 'WARN merged-branch' -- env "PATH=$TMP/shim-wtfail:$PATH" "$BASH_BIN" @SUT@ --target "$R" --tmp "$RT"
  CEW="$TMP/case_evidence_w/_evidence/repo"; mkdir -p "$CEW/.research-sdd"; git -C "$CEW" init -q; git -C "$CEW" branch -M main 2>/dev/null; printf '# none\n' > "$CEW/.research-sdd/keep.txt"
  "${GIT[@]}" -C "$CEW" add -A >/dev/null 2>&1; "${GIT[@]}" -C "$CEW" commit -q -m i 2>/dev/null
  mt "skipped non-evidence dir degrades the run" 's/\*) _ev_fatal=0; _ev_unread/*) _ev_fatal=1; _ev_unread/' 0 3 \
    --good-lacks 'DEGRADED' --bad-has 'DEGRADED' -- env "SHIM_ERR_LINE=find: '$NB/other/locked': Permission denied" "PATH=$TMP/shim-evperm:$PATH" "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "skip count missing from the summary (quiet none found)" 's/\[ "\$_ev_unread" -eq 0 \] || _ev_sfx=/: || _ev_sfx=/' 0 0 \
    --good-has 'none found, 1 unreadable dir\(s\) skipped' --bad-lacks 'unreadable dir\(s\) skipped' -- env "SHIM_ERR_LINE=find: '$NB/other/locked': Permission denied" "PATH=$TMP/shim-evperm:$PATH" "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "_evidence safety arm removed (permission error under _evidence skipped)" '/CC-EV-ARM/d' 3 0 \
    --good-has 'DEGRADED-EVIDENCE-SCAN' --bad-lacks 'DEGRADED-EVIDENCE-SCAN' -- env "SHIM_ERR_LINE=find: '$NB/_evidence/t/locked': Permission denied" "PATH=$TMP/shim-evperm:$PATH" "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "Permission denied match no longer anchored to the line end" 's/\[\[ "\$_fl" == "\$_pre"\*"\$_suf" \]\]/[[ "$_fl" == "$_pre"* ]]/' 3 0 \
    --good-has 'DEGRADED-EVIDENCE-SCAN' --bad-lacks 'DEGRADED-EVIDENCE-SCAN' -- env "SHIM_ERR_LINE=find: '$NB/Permission denied': No such file or directory" "PATH=$TMP/shim-evperm:$PATH" "$BASH_BIN" @SUT@ --target "$NB" --tmp "$NBT"
  mt "classification no longer relative to the target (case_evidence in the target path)" 's/; _fp="\${_fp#"\$TARGET_P"\/}"//' 0 3 \
    --good-lacks 'DEGRADED' --bad-has 'DEGRADED' -- env "SHIM_ERR_LINE=find: '$CEW/other/locked': Permission denied" "PATH=$TMP/shim-evperm:$PATH" "$BASH_BIN" @SUT@ --target "$CEW" --tmp "$NBT"
  # World R2: origin/HEAD base with a local twin of the base and a merged remote branch.
  fresh_main; R2="$REPO"; R2T="$FT"; RB2="$TMP/r2-remote.git"; git init -q --bare "$RB2"; git -C "$R2" remote add origin "$RB2"
  git -C "$R2" push -q origin main; git -C "$R2" push -q origin main:refs/heads/rdone; git -C "$R2" fetch -q origin; git -C "$R2" remote set-head origin main >/dev/null; git -C "$R2" switch -q -c other   # HEAD off main, so main is a reportable twin
  mt "the base's local twin is reported as merged" 's/\[ -n "\$_bb" \] && \[ "\$_bn" = "\$_bb" \] && continue/:/' 0 0 \
    --good-lacks 'merged-branch main' --bad-has 'merged-branch main' -- "$BASH_BIN" @SUT@ --target "$R2" --tmp "$R2T"
  mt "origin/HEAD alias is reported as a merged remote branch" 's/\[ "\$_bn" = "HEAD" \] && continue/:/' 0 0 \
    --good-lacks 'origin/HEAD merged' --bad-has 'origin/HEAD merged' -- "$BASH_BIN" @SUT@ --target "$R2" --tmp "$R2T"
  mt "origin/HEAD no longer chosen as the base" 's/refs\/remotes\/origin\/HEAD/refs\/remotes\/origin\/NOHEAD/' 0 0 \
    --good-has 'merged-remote-branch origin/rdone merged into origin/main' --bad-lacks 'merged into origin/main' -- "$BASH_BIN" @SUT@ --target "$R2" --tmp "$R2T"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
