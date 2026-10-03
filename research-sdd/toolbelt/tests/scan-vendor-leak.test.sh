#!/usr/bin/env bash
# scan-vendor-leak.test.sh — RED-FIRST harness for scan-vendor-leak.sh (kit issue #1271, slice 1).
#
# Every repo is a throwaway git repo built under a trap-cleaned temp dir; the kit tree is never written.
# The discriminating behaviours: binary artifacts, declared path globs and declared package prefixes are
# flagged; `allow` wins; the prefix match respects the package-segment boundary (javax.bajaextra is NOT
# javax.baja); a missing conf is a TYPED ABSENT-CONF state (never a silent pass on prefixes); --staged
# reads the index, default reads tracked files; the scan never writes to the target.
#
# Usage: scan-vendor-leak.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../scan-vendor-leak.sh"
FIX="$HERE/fixtures/scan-vendor-leak"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
MUT=""
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# newrepo <dir> [conf-file] — git repo with one committed README; conf copied to .research-sdd/ if given.
newrepo(){
  local d="$1" conf="${2:-}"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf '# readme\n' > "$d/README.md"
  if [ -n "$conf" ]; then mkdir -p "$d/.research-sdd"; cp "$conf" "$d/.research-sdd/vendor-leak.conf"; fi
}
# addf <dir> <path> [content] — write a file (parents created) and `git add` it.
addf(){ mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "${3:-x}" > "$1/$2"; git -C "$1" add -- "$2"; }
commit(){ git -C "$1" add -A && git -C "$1" commit -q -m c; }
rc(){ bash "$SUT" "$@" >/dev/null 2>&1; echo $?; }
out(){ bash "$SUT" "$@" 2>&1; }
has(){ grep -qE -- "$2" <<<"$1"; }

echo "== scan-vendor-leak.test.sh =="

# 1 — clean repo with conf: exit 0, SUMMARY, zero LEAK lines.
d="$TMP/clean"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" src/Ok.java 'package com.acme.ok;'; commit "$d"
o="$(out "$d")"
[ "$(rc "$d")" = 0 ] && has "$o" '^SUMMARY scanned=[0-9]+ ' && ! has "$o" '^LEAK ' && ok "clean repo → exit 0, SUMMARY, no LEAK" || no "clean repo wrong: $o"

# 2 — binary artifacts flagged, case-insensitive, one LEAK binary line each.
d="$TMP/bin"; newrepo "$d" "$FIX/vendor-leak.conf"
for f in a.class lib/b.jar c.dll d.so e.exe F.JAR; do addf "$d" "$f"; done; commit "$d"
o="$(out "$d")"; n="$(grep -c '^LEAK binary ' <<<"$o")"
[ "$(rc "$d")" = 1 ] && [ "$n" = 6 ] && ok "6 binary artifacts → 6 LEAK binary, exit 1" || no "binary: rc/n wrong ($n): $o"

# 3 — declared path glob flagged.
d="$TMP/path"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" decompiled/a/B.java 'class B {}'; addf "$d" notes/decompiled.md; commit "$d"
o="$(out "$d")"
[ "$(rc "$d")" = 1 ] && has "$o" '^LEAK path decompiled/a/B\.java ' && ! has "$o" 'notes/decompiled\.md' && ok "path glob flags decompiled/**, not a lookalike name" || no "path glob wrong: $o"

# 4 — package prefix: flagged with :line; segment boundary respected; exact == prefix flagged.
d="$TMP/pkg"; newrepo "$d" "$FIX/vendor-leak.conf"
addf "$d" src/Vendor.java $'// header\n\npackage javax.baja.sys;\nclass V {}'
addf "$d" src/Exact.java 'package javax.baja;'
addf "$d" src/Near.java 'package javax.bajaextra.sys;'
addf "$d" src/Tri.java $'  package   com.tridium.x ;'
addf "$d" src/Commented.java $'// package javax.baja.sys;\nclass C {}'
commit "$d"
o="$(out "$d")"
has "$o" '^LEAK package src/Vendor\.java:3 ' && has "$o" '^LEAK package src/Exact\.java:1 ' && has "$o" '^LEAK package src/Tri\.java:1 ' \
  && ! has "$o" 'Near\.java' && ! has "$o" 'Commented\.java' && [ "$(rc "$d")" = 1 ] \
  && ok "package prefix: flagged with line, boundary-aware, commented decl ignored" || no "package rule wrong: $o"

# 5 — allow wins over binary, path and package.
d="$TMP/allow"; newrepo "$d" "$FIX/vendor-leak.conf"
addf "$d" docs/examples/x.jar; addf "$d" docs/examples/P.java 'package javax.baja.sys;'
printf 'path docs/**\n' >> "$d/.research-sdd/vendor-leak.conf"
commit "$d"
o="$(out "$d")"
[ "$(rc "$d")" = 0 ] && ! has "$o" '^LEAK ' && has "$o" 'allowed=2' && ok "allow wins over binary/path/package and is counted" || no "allow wrong: $o"

# 6 — ABSENT-CONF: typed line, binary rule still runs, summary says prefixes were NOT evaluated.
d="$TMP/noconf"; newrepo "$d"; addf "$d" src/V.java 'package javax.baja.sys;'; commit "$d"
o="$(out "$d")"
[ "$(rc "$d")" = 0 ] && has "$o" '^ABSENT-CONF ' && has "$o" '^SUMMARY .*conf=absent' && has "$o" 'NOT evaluated' \
  && ok "no conf → ABSENT-CONF, summary admits path/package rules did not run" || no "absent-conf wrong: $o"
addf "$d" lib/z.jar; commit "$d"
[ "$(rc "$d")" = 1 ] && has "$(out "$d")" '^LEAK binary lib/z\.jar ' && ok "no conf → built-in binary rule still fires" || no "binary rule off without conf"

# 7 — modes: default = tracked (ignores untracked), --staged = index only.
d="$TMP/modes"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" old/committed.jar; commit "$d"
printf x > "$d/untracked.jar"
[ "$(rc "$d" --tracked)" = 1 ] && has "$(out "$d")" 'committed\.jar' && ! has "$(out "$d")" 'untracked\.jar' && ok "default/--tracked: tracked leak seen, untracked ignored" || no "tracked mode wrong"
[ "$(rc "$d" --staged)" = 0 ] && ok "--staged ignores a committed-but-unstaged leak" || no "--staged saw committed leak"
addf "$d" new/staged.dll
o="$(out "$d" --staged)"
[ "$(rc "$d" --staged)" = 1 ] && has "$o" '^LEAK binary new/staged\.dll ' && ! has "$o" 'committed\.jar' && ok "--staged flags a staged leak only" || no "--staged wrong: $o"

# 8 — staged package check reads the INDEX content, not the worktree copy.
d="$TMP/idx"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" src/I.java 'package javax.baja.sys;'
printf 'package com.acme;\n' > "$d/src/I.java"
has "$(out "$d" --staged)" '^LEAK package src/I\.java:1 ' && ok "--staged reads index content" || no "--staged read the worktree copy"

# 9 — usage / environment errors.
[ "$(rc)" = 2 ] && ok "no args → exit 2" || no "no args rc"
[ "$(rc "$TMP/nonexistent")" = 2 ] && ok "missing dir → exit 2" || no "missing dir rc"
mkdir -p "$TMP/plain"; [ "$(rc "$TMP/plain")" = 2 ] && ok "non-git dir → exit 2" || no "non-git rc"
[ "$(rc "$TMP/clean" --bogus)" = 2 ] && ok "unknown flag → exit 2" || no "bogus flag rc"
d="$TMP/badconf"; newrepo "$d"; mkdir -p "$d/.research-sdd"; printf 'prefx javax.baja\n' > "$d/.research-sdd/vendor-leak.conf"
o="$(out "$d")"; [ "$(rc "$d")" = 2 ] && has "$o" '^BAD-CONF ' && ok "unknown conf directive → BAD-CONF, exit 2 (fail closed)" || no "bad conf wrong: $o"
d="$TMP/emptyarg"; newrepo "$d"; mkdir -p "$d/.research-sdd"; printf 'prefix\n' > "$d/.research-sdd/vendor-leak.conf"
[ "$(rc "$d")" = 2 ] && ok "directive without argument → exit 2" || no "argless directive rc"

# 10 — DEGRADED when git is missing (exit 3, typed).
o="$(PATH="$TMP/nopath" /bin/bash "$SUT" "$TMP/clean" 2>&1)"; r=$?
[ "$r" = 3 ] && has "$o" '^DEGRADED' && ok "git missing → DEGRADED, exit 3" || no "degraded wrong rc=$r: $o"

# 11 — conf tolerance: comments, blanks, CRLF, trailing spaces.
d="$TMP/crlf"; newrepo "$d"; mkdir -p "$d/.research-sdd"
printf '# c\r\n\r\n  prefix javax.baja  \r\npath vendor/**\r\n' > "$d/.research-sdd/vendor-leak.conf"
addf "$d" src/V.java 'package javax.baja.x;'; addf "$d" vendor/q.txt; commit "$d"
o="$(out "$d")"; has "$o" '^LEAK package src/V\.java:1 ' && has "$o" '^LEAK path vendor/q\.txt ' && ok "conf with comments/CRLF/blank lines parsed" || no "crlf conf wrong: $o"

# 12 — paths with spaces; empty scope is typed, not a silent zero.
d="$TMP/space"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" "my dir/a b.jar"; commit "$d"
has "$(out "$d")" '^LEAK binary my dir/a b\.jar ' && ok "path with spaces reported intact" || no "space path wrong"
d="$TMP/empty"; newrepo "$d" "$FIX/vendor-leak.conf"
o="$(out "$d" --staged)"; [ "$(rc "$d" --staged)" = 0 ] && has "$o" '^EMPTY-INPUT ' && has "$o" 'scanned=0' && ok "nothing staged → typed EMPTY-INPUT (not a silent zero)" || no "empty scope wrong: $o"

# 13 — read-only: the target's status and index are byte-identical after a run; no stray files.
d="$TMP/ro"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" a.jar; addf "$d" src/V.java 'package javax.baja.s;'; printf y > "$d/loose.txt"
before="$(git -C "$d" status --porcelain=v1 -z | sha1sum)$(find "$d" -path "$d/.git" -prune -o -type f -print | sort | xargs sha1sum | sha1sum)"
bash "$SUT" "$d" >/dev/null 2>&1; bash "$SUT" "$d" --staged >/dev/null 2>&1
after="$(git -C "$d" status --porcelain=v1 -z | sha1sum)$(find "$d" -path "$d/.git" -prune -o -type f -print | sort | xargs sha1sum | sha1sum)"
[ "$before" = "$after" ] && ok "scan leaves the target tree and index unchanged" || no "target mutated by scan"

# 14 — sub-directory target: paths are relative to the target and files outside it are not scanned.
d="$TMP/sub"; newrepo "$d"; mkdir -p "$d/corpus/.research-sdd"; printf 'path gen/**\n' > "$d/corpus/.research-sdd/vendor-leak.conf"
addf "$d" corpus/gen/x.txt; addf "$d" outside/y.jar; commit "$d"
o="$(out "$d/corpus")"; has "$o" '^LEAK path gen/x\.txt ' && ! has "$o" 'y\.jar' && ok "subdir target: paths relative to the target, outside files not scanned" || no "subdir wrong: $o"

# 15 — fail-closed paths (review round 1).
# 15a unreadable index content is typed UNREADABLE, counted, and never exit 0.
d="$TMP/unread"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" src/U.java 'package com.acme;'; commit "$d"
h="$(git -C "$d" rev-parse :src/U.java)"; rm -f "$d/.git/objects/${h:0:2}/${h:2}"
o="$(out "$d")"
[ "$(rc "$d")" = 2 ] && has "$o" '^UNREADABLE src/U\.java ' && has "$o" 'unreadable=1' && ok "unreadable index blob → UNREADABLE line, unreadable=1, exit 2 (never clean)" || no "unreadable blob wrong: $o"
# a real finding elsewhere still wins the exit code (1) but UNREADABLE is still printed
cp -r "$d" "$TMP/unreadmix"; d="$TMP/unreadmix"; addf "$d" z.jar; o="$(out "$d")"
[ "$(rc "$d")" = 1 ] && has "$o" '^UNREADABLE ' && has "$o" '^LEAK binary z\.jar' && ok "finding + unreadable → exit 1, both reported" || no "mixed wrong: $o"
# 15b unreadable conf is never ABSENT (skipped when running as a user that ignores chmod).
d="$TMP/confperm"; newrepo "$d" "$FIX/vendor-leak.conf"; chmod 000 "$d/.research-sdd/vendor-leak.conf"
if [ -r "$d/.research-sdd/vendor-leak.conf" ]; then echo "  SKIP  unreadable conf (chmod 000 still readable here)"
else o="$(out "$d")"; [ "$(rc "$d")" = 2 ] && has "$o" '^UNREADABLE-CONF ' && ! has "$o" '^ABSENT-CONF' && ok "chmod 000 conf → UNREADABLE-CONF exit 2, not ABSENT" || no "unreadable conf wrong: $o"; fi
chmod 644 "$d/.research-sdd/vendor-leak.conf"
# 15c conf that is a symlink or a directory is refused.
d="$TMP/conflink"; newrepo "$d"; mkdir -p "$d/.research-sdd"; printf 'prefix javax.baja\n' > "$TMP/outside.conf"; ln -s "$TMP/outside.conf" "$d/.research-sdd/vendor-leak.conf"
o="$(out "$d")"; [ "$(rc "$d")" = 2 ] && has "$o" '^BAD-CONF .*symlink' && ok "symlinked conf → BAD-CONF exit 2" || no "symlink conf wrong: $o"
d="$TMP/confdir"; newrepo "$d"; mkdir -p "$d/.research-sdd/vendor-leak.conf"
[ "$(rc "$d")" = 2 ] && ok "conf path is a directory → exit 2 (not ABSENT)" || no "conf dir wrong"
# 15d conf values that could never match are refused, not silently dead.
d="$TMP/hard"; newrepo "$d"; mkdir -p "$d/.research-sdd"
for bad in 'prefix javax.*' 'prefix .javax' 'prefix javax..baja' 'path /etc/**' 'path ../x/**' 'allow ../y'; do
  printf '%s\n' "$bad" > "$d/.research-sdd/vendor-leak.conf"
  [ "$(rc "$d")" = 2 ] && has "$(out "$d")" '^BAD-CONF ' && ok "conf '$bad' → BAD-CONF exit 2" || no "conf '$bad' accepted"
done
# 15e --staged: a staged deletion is skipped explicitly; a typechange to a symlink is scanned.
d="$TMP/sdel"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" gone.jar; addf "$d" tc.jar; commit "$d"
git -C "$d" rm -q --cached gone.jar
o="$(out "$d" --staged)"
[ "$(rc "$d" --staged)" = 0 ] && ! has "$o" 'gone\.jar' && ok "--staged: staged deletion not reported" || no "staged deletion wrong: $o"
rm -f "$d/tc.jar"; ln -s README.md "$d/tc.jar"; git -C "$d" add tc.jar
o="$(out "$d" --staged)"
[ "$(rc "$d" --staged)" = 1 ] && has "$o" '^LEAK binary tc\.jar ' && ok "--staged: typechange (file → symlink) is scanned" || no "typechange wrong: $o"
# 15f versioned shared objects.
d="$TMP/so"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" lib/libz.so.1.2; addf "$d" docs/x.so.md; commit "$d"
o="$(out "$d")"; has "$o" '^LEAK binary lib/libz\.so\.1\.2 ' && ! has "$o" 'x\.so\.md' && ok "versioned .so.N flagged, .so.md not" || no "versioned so wrong: $o"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant of the SUT must flip a specific verdict --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
    || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth" >&2; exit 2; }
  MUT="$(mktemp -d)"
  mk(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # A: binary rule neutered → built-in binary artifacts pass.
  mk "A binary" "$SUT" "$MUT/a.sh" 's/\*\.class|\*\.jar|\*\.dll|\*\.so|\*\.so\.\[0-9\]\*|\*\.exe)/*.zzznomatch)/' \
    && tt "A binary rule neutered → jar passes" 1 0 "$MUT/a.sh" --bad-lacks '^LEAK binary' --good-has '^LEAK binary' -- bash @SUT@ "$TMP/bin"
  # B: package boundary dropped → javax.bajaextra false positive.
  mk "B boundary" "$SUT" "$MUT/b.sh" 's/"\$pkg" == "\$pre"\.\*/"$pkg" == "$pre"*/' \
    && tt "B package boundary dropped → Near.java flagged" 1 1 "$MUT/b.sh" --good-lacks 'Near\.java' --bad-has 'Near\.java' -- bash @SUT@ "$TMP/pkg"
  # C: allow ignored.
  mk "C allow" "$SUT" "$MUT/c.sh" 's/if is_allowed "\$p"; then/if false; then/' \
    && tt "C allow ignored → allowlisted file flagged" 0 1 "$MUT/c.sh" -- bash @SUT@ "$TMP/allow"
  # D: path rule off.
  mk "D path" "$SUT" "$MUT/d.sh" 's/\&\& matches_any "\$p" "\${PATHS\[@\]}"; then/\&\& false; then/' \
    && tt "D path rule off → decompiled/** passes" 1 0 "$MUT/d.sh" --good-has '^LEAK path' --bad-lacks '^LEAK path' -- bash @SUT@ "$TMP/path"
  # E: findings do not change the exit code.
  mk "E exit" "$SUT" "$MUT/e.sh" 's/^\[ "\$findings" -gt 0 \] && exit 1/[ "$findings" -gt 0 ] \&\& exit 0/' \
    && tt "E findings exit 0 → gate cannot fail" 1 0 "$MUT/e.sh" -- bash @SUT@ "$TMP/bin"
  # F: ABSENT-CONF typed line removed.
  mk "F absent" "$SUT" "$MUT/f.sh" 's/echo "ABSENT-CONF /echo "XABSENT /' \
    && tt "F ABSENT-CONF line dropped → silent pass on prefixes" 1 1 "$MUT/f.sh" --good-has '^ABSENT-CONF' --bad-lacks '^ABSENT-CONF' -- bash @SUT@ "$TMP/noconf"
  # G: --staged lists tracked files instead of the index diff.
  d="$TMP/modes2"; newrepo "$d" "$FIX/vendor-leak.conf"; addf "$d" old/committed.jar; commit "$d"
  mk "G staged" "$SUT" "$MUT/g.sh" 's/git -C "\$target" diff --cached --name-only --relative -z --diff-filter=ACMRT/git -C "$target" ls-files -z/' \
    && tt "G --staged reads tracked set → committed leak flagged" 0 1 "$MUT/g.sh" -- bash @SUT@ "$TMP/modes2" --staged
  # H: git probe removed → no typed DEGRADED.
  mk "H probe" "$SUT" "$MUT/h.sh" 's/command -v git >\/dev\/null 2>&1 ||/true ||/' \
    && tt "H git probe removed → no DEGRADED" 3 2 "$MUT/h.sh" --good-has '^DEGRADED' --bad-lacks '^DEGRADED' -- env PATH="$TMP/nopath" /bin/bash @SUT@ "$TMP/clean"
  # I: package line number dropped.
  mk "I lineno" "$SUT" "$MUT/i.sh" 's/"\$p:\$ln"/"$p"/' \
    && tt "I :line dropped from package finding" 1 1 "$MUT/i.sh" --good-has 'Vendor\.java:3 ' --bad-lacks 'Vendor\.java:3 ' -- bash @SUT@ "$TMP/pkg"
  # J: bad conf directive accepted silently.
  mk "J badconf" "$SUT" "$MUT/j.sh" 's/BAD-CONF unknown directive/NOTE unknown directive/;s/^      bad_conf=1/      bad_conf=0/' \
    && tt "J unknown directive tolerated → exit 0" 2 0 "$MUT/j.sh" -- bash @SUT@ "$TMP/badconf"
  # K: unreadable content no longer fails the run.
  mk "K unreadable" "$SUT" "$MUT/k.sh" 's/^\[ "\$unreadable" -gt 0 \] && exit 2/:/' \
    && tt "K unreadable ignored → exit 0 on a blob that could not be read" 2 0 "$MUT/k.sh" -- bash @SUT@ "$TMP/unread"
  # L: typechange dropped from the staged filter.
  mk "L typechange" "$SUT" "$MUT/l.sh" 's/--diff-filter=ACMRT/--diff-filter=ACMR/' \
    && tt "L typechange dropped → symlinked .jar passes --staged" 1 0 "$MUT/l.sh" -- bash @SUT@ "$TMP/sdel" --staged
  # N: versioned shared objects not matched.
  mk "N so" "$SUT" "$MUT/n.sh" 's/|\*\.so\.\[0-9\]\*//' \
    && tt "N versioned .so dropped → libz.so.1.2 passes" 1 0 "$MUT/n.sh" --good-has 'libz\.so\.1\.2' --bad-lacks 'libz\.so\.1\.2' -- bash @SUT@ "$TMP/so"
  # O: symlinked conf accepted.
  mk "O conflink" "$SUT" "$MUT/o.sh" 's/if \[ -L "\$conf" \] ||/if false ||/' \
    && tt "O symlinked conf accepted → read through the link" 2 0 "$MUT/o.sh" -- bash @SUT@ "$TMP/conflink"
  # P: unsafe conf globs accepted.
  mk "P globs" "$SUT" "$MUT/p.sh" 's/path:\/\*|allow:\/\*|path:\*\.\.\*|allow:\*\.\.\*)/path:ZZZ)/' \
    && { printf 'path ../x/**\n' > "$TMP/hard/.research-sdd/vendor-leak.conf"
         tt "P ../ glob accepted → silently dead rule" 2 0 "$MUT/p.sh" -- bash @SUT@ "$TMP/hard"; }
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
