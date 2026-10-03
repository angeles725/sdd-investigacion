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
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth" >&2; exit 2; }
mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain "$l" "$SUT" "$o" "$@" || { fail=$((fail+1)); return 1; }; }
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
mkdir "$FT/tmp.olddir"; touch -d '48 hours ago' "$FT/tmp.olddir"
: > "$FT/tmp.oldfile"; touch -d '30 hours ago' "$FT/tmp.oldfile"
: > "$FT/tmp.young"
: > "$FT/other.old"; touch -d '90 hours ago' "$FT/other.old"
: > "$FT/xtmp.old"; touch -d '90 hours ago' "$FT/xtmp.old"
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
fresh; mkdir -p "$REPO/scratch"; printf 'x\n' > "$REPO/scratch/a"; mkdir "$FT/tmp.pad"; touch -d '48 hours ago' "$FT/tmp.pad"
CLEAN_CHECK_SCRATCHPAD="$REPO/scratch" run --target "$REPO" --tmp "$FT"
if has "scratch/a"; then no "scratchpad entry (untracked) must not be reported" "($OUT)"; else ok "scratchpad untracked entry never reported"; fi
CLEAN_CHECK_SCRATCHPAD="$FT/tmp.pad" run --target "$REPO" --tmp "$FT"
has "tmp.pad" && no "scratchpad that is itself a stale tmp.* entry must not be reported" "($OUT)" || ok "scratchpad that is itself a stale tmp.* entry never reported"
run --target "$REPO" --tmp "$FT"
{ has "scratch/a" && has "tmp.pad"; } && ok "without the scratchpad declaration both are findings" || no "scratchpad control" "($OUT)"

# ---- read-only --------------------------------------------------------------------------------
fresh; printf 'x\n' > "$REPO/stray"; : > "$FT/tmp.old"; touch -d '48 hours ago' "$FT/tmp.old"
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
for tool in git find; do
  mkbin "$TMP/bin-no-$tool" "$tool"
  OUT="$(PATH="$TMP/bin-no-$tool" "$BASH_BIN" "$SUT" --target "$REPO" --tmp "$FT" 2>&1)"; RC=$?
  { [ "$RC" = 3 ] && has "DEGRADED"; } && ok "$tool missing -> exit 3 with typed DEGRADED" || no "degraded without $tool" "(rc=$RC $OUT)"
done

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
  : > "$WT/tmp.old"; touch -d '48 hours ago' "$WT/tmp.old"; : > "$WT/tmp.young"
  : > "$WT/other.old"; touch -d '48 hours ago' "$WT/other.old"
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
  fresh; CL="$REPO"
  mt "ownership filter removed" 's/ -uid "\$OWNER_UID"//' 0 1 \
    --good-has 'CLEAN-CHECK: clean' --bad-has 'stale-tmp' -- env "CLEAN_CHECK_UID=$(( $(id -u) + 1 ))" "$BASH_BIN" @SUT@ --target "$CL" --tmp "$WT"
  mt "age printed in minutes, not hours" 's|/ 3600|/ 60|' 1 1 \
    --good-has 'age=48h' --bad-lacks 'age=48h' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$WT"
  # Scratchpad: both classes. SP_REPO holds an untracked scratch dir, SP_TMP a stale tmp.* scratchpad.
  fresh; SP="$REPO"; SPT="$FT"; mkdir -p "$SP/scratch"; printf 'x\n' > "$SP/scratch/a"
  mkdir "$SPT/tmp.pad"; touch -d '48 hours ago' "$SPT/tmp.pad"
  mt "scratchpad exemption removed (untracked class)" 's/_in_scratch "\$TARGET_P\/\$_p" && continue/:/' 1 1 \
    --good-lacks 'scratch/a' --bad-has 'GARBAGE untracked scratch/a' -- env "CLEAN_CHECK_SCRATCHPAD=$SP/scratch" "$BASH_BIN" @SUT@ --target "$SP" --tmp "$SPT"
  mt "scratchpad exemption removed (tmp class)" 's/_in_scratch "\$_p" && continue/:/' 1 1 \
    --good-lacks 'tmp\.pad' --bad-has 'GARBAGE stale-tmp .*tmp\.pad' -- env "CLEAN_CHECK_SCRATCHPAD=$SPT/tmp.pad" "$BASH_BIN" @SUT@ --target "$E" --tmp "$SPT"
  mt "findings no longer change the exit code" 's/^exit 1$/exit 0/' 1 0 \
    --good-has 'finding' -- "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  # DEGRADED probe: with git absent the mutant must NOT report exit 3 + DEGRADED.
  mt "DEGRADED probe disabled" 's/command -v "\$_tool" >\/dev\/null 2>&1 ||/true ||/' 3 2 \
    --good-has 'DEGRADED' --bad-lacks 'DEGRADED' -- env "PATH=$TMP/bin-no-git" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  # Truncated/failed scans: a git or find that fails must be exit 2, never a quiet clean.
  mkdir -p "$TMP/shim-git" "$TMP/shim-find"
  printf '#!/bin/sh\nif [ "$1" = -C ]; then cd "$2" || exit 1; shift 2; fi\n[ "$1" = ls-files ] && exit 1\nexec %s "$@"\n' "$(type -P git)" > "$TMP/shim-git/git"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/shim-find/find"; chmod +x "$TMP/shim-git/git" "$TMP/shim-find/find"
  mt "git failure no longer detected (RC marker ignored, untracked scan)" '/git ls-files failed/s/"\${_items\[\$_last\]}" = "RC=0"/"x" = "x"/' 2 0 \
    --good-has 'git ls-files failed' -- env "PATH=$TMP/shim-git:$PATH" "$BASH_BIN" @SUT@ --target "$E" --tmp "$ET"
  mt "find failure no longer detected (RC marker ignored, tmp scan)" '/find failed/s/"\${_items\[\$_last\]}" = "RC=0"/"x" = "x"/' 2 0 \
    --good-has 'find failed' -- env "PATH=$TMP/shim-find:$PATH" "$BASH_BIN" @SUT@ --target "$CL" --tmp "$WT"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
