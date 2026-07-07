#!/usr/bin/env bash
# research-sdd-init.test.sh — RED-FIRST regression harness for research-sdd-init.sh.
#
# These fixtures back the scaffolder's SAFETY CLAIMS (never clobber, never duplicate,
# fail loud, don't corrupt the user's .gitignore) — not just the happy path. An earlier
# version of this suite was theater: it passed while three real data-loss/duplication/
# silent-failure defects were present (two fresh-context reviews caught them). Each BAD
# fixture below reproduces one of those and asserts the scaffolder REFUSES or ABORTS.
# --prove-teeth mutates the corpus-present guard and asserts a data-loss fixture then
# clobbers — proving the refuse tests depend on the guard.
#
# Usage: research-sdd-init.test.sh [--prove-teeth]      Exit: 0 = all held · 1 = regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-init.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
assert_exit()   { local w="$1" l="$2"; shift 2; local g; bash "$SUT" "$@" >/dev/null 2>&1; g=$?; [ "$g" = "$w" ] && ok "$l (exit $g)" || no "$l — expected $w, got $g"; }
assert_file()   { [ -f "$2" ] && ok "$1" || no "$1 (missing: $2)"; }
assert_absent() { [ ! -e "$2" ] && ok "$1" || no "$1 (should NOT exist: $2)"; }
assert_grep()   { grep -qF "$2" "$3" 2>/dev/null && ok "$1" || no "$1 (pattern '$2' not in $3)"; }

echo "== research-sdd-init.test.sh (SUT: $(basename "$SUT")) =="

# GOOD 1 — flat scaffold on an empty target → full skeleton at root
d="$TMP/good-flat"; mkdir -p "$d"
assert_exit 0 "GOOD flat: scaffolds empty target" "$d" --corpus flat
for f in INDEX.md RESEARCH-STATE.md sources/SOURCES.md tools/gen-catalog.py .claude/hooks/research-protocol.sh; do
  assert_file "  flat: $f" "$d/$f"
done
[ -d "$d/retros" ] && ok "  flat: retros/ at target root" || no "  flat: retros/ at target root"
assert_grep "  flat: .gitignore has .atl/"    ".atl/"    "$d/.gitignore"
assert_grep "  flat: .gitignore has .claude/" ".claude/" "$d/.gitignore"
[ -d "$d/.git" ] && ok "  flat: git initialized" || no "  flat: git initialized"

# GOOD 2 — auto nests when subject material is present; root stays clean
d="$TMP/good-nested"; mkdir -p "$d"; : > "$d/app.html"
assert_exit 0 "GOOD auto: nests on subject material" "$d" --corpus auto
assert_file   "  nested: corpus/INDEX.md"     "$d/corpus/INDEX.md"
assert_absent "  nested: NO root INDEX.md"    "$d/INDEX.md"
[ -d "$d/retros" ] && ok "  nested: retros/ at target root" || no "  nested: retros/ at root"

# GOOD 3 — auto on empty target → flat
d="$TMP/good-auto-empty"; mkdir -p "$d"
assert_exit 0 "GOOD auto: flat when empty" "$d" --corpus auto
assert_file "  auto-empty: root INDEX.md" "$d/INDEX.md"

# GOOD 4 — auto sees a HIDDEN subject file (dotglob) → nests
d="$TMP/good-dotfile"; mkdir -p "$d"; : > "$d/.env"
assert_exit 0 "GOOD auto: nests on a hidden subject file" "$d" --corpus auto
assert_file "  dotfile: corpus/INDEX.md" "$d/corpus/INDEX.md"

# GOOD 5 — auto on a dir whose only entry is .git/ (infra, skip-listed) → flat
d="$TMP/good-onlygit"; mkdir -p "$d/.git"
assert_exit 0 "GOOD auto: flat when only .git present" "$d" --corpus auto
assert_file "  onlygit: root INDEX.md" "$d/INDEX.md"

# BAD 1 — refuse over an existing INDEX
d="$TMP/bad-index"; mkdir -p "$d"; printf 'SENTINEL\n' > "$d/INDEX.md"
assert_exit 3 "BAD: refuses over existing INDEX.md" "$d" --corpus flat
assert_grep "  refuse: INDEX untouched" "SENTINEL" "$d/INDEX.md"

# BAD 2 (DATA-LOSS) — INDEX deleted but RESEARCH-STATE holds real curated data → must refuse, not clobber
d="$TMP/bad-dataloss"; mkdir -p "$d"; printf 'REAL HAND-CURATED GAPS\n' > "$d/RESEARCH-STATE.md"
assert_exit 3 "BAD: refuses when only RESEARCH-STATE exists (data-loss)" "$d" --corpus flat
assert_grep "  data-loss: RESEARCH-STATE untouched" "REAL HAND-CURATED GAPS" "$d/RESEARCH-STATE.md"

# BAD 3 (DUPLICATION) — a nested corpus exists; auto must NOT scaffold a second flat one
d="$TMP/bad-dup"; mkdir -p "$d/corpus" "$d/retros"; printf 'REAL NESTED CORPUS\n' > "$d/corpus/INDEX.md"
assert_exit 3 "BAD: refuses to duplicate an existing nested corpus" "$d" --corpus auto
assert_absent "  dup: NO second root INDEX.md" "$d/INDEX.md"
assert_grep   "  dup: nested corpus untouched" "REAL NESTED CORPUS" "$d/corpus/INDEX.md"

# BAD 4 (SILENT FAILURE) — read-only target → FATAL exit 2, tree left empty
d="$TMP/bad-readonly"; mkdir -p "$d"; chmod 555 "$d"
assert_exit 2 "BAD: read-only target fails loud (exit 2)" "$d" --corpus flat
assert_absent "  readonly: no INDEX created" "$d/INDEX.md"
chmod u+w "$d"

# BAD 5 — nonexistent target dir
assert_exit 2 "BAD: nonexistent target dir" "$TMP/does-not-exist" --corpus flat

# GITIGNORE 6 — pre-existing .gitignore with NO trailing newline must not fuse
d="$TMP/gi-nonewline"; mkdir -p "$d"; printf 'node_modules/' > "$d/.gitignore"   # no trailing \n
assert_exit 0 "GITIGNORE: appends without fusing the last line" "$d" --corpus flat
assert_grep "  gitignore: node_modules/ intact on its own line" "node_modules/" "$d/.gitignore"
grep -qxF 'node_modules/' "$d/.gitignore" && ok "  gitignore: node_modules/ not fused" || no "  gitignore: node_modules/ FUSED with next pattern"

# ROLLBACK 7 — a template fails mid-scaffold → clean up what THIS run created, leave NO partial tree
cp -r "$HERE/../../templates" "$TMP/rbk-templates"
mkdir -p "$TMP/rbk/toolbelt"; cp "$SUT" "$TMP/rbk/toolbelt/init.sh"; ln -sfn "$TMP/rbk-templates" "$TMP/rbk/templates"
chmod 000 "$TMP/rbk-templates/RESEARCH-STATE.template.md"   # 2nd cp fails after INDEX is copied
d="$TMP/rollback"; mkdir -p "$d"
bash "$TMP/rbk/toolbelt/init.sh" "$d" --corpus flat >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "ROLLBACK: mid-scaffold failure exits non-zero (exit $rc)" || no "ROLLBACK: mid-scaffold failure exited 0"
assert_absent "  rollback: partial INDEX.md removed" "$d/INDEX.md"
assert_absent "  rollback: partial tools/ removed"   "$d/tools"
assert_absent "  rollback: no orphaned .claude/"     "$d/.claude"
assert_absent "  rollback: no orphaned retros/"      "$d/retros"
# the tree must be COMPLETELY clean after rollback (no leftover of any kind)
[ -z "$(ls -A "$d" 2>/dev/null)" ] && ok "  rollback: target dir fully clean" || no "  rollback: leftovers: $(ls -A "$d" | tr '\n' ' ')"
chmod u+w "$TMP/rbk-templates/RESEARCH-STATE.template.md"

# --force overrides the refuse
d="$TMP/force"; mkdir -p "$d"; printf 'SENTINEL\n' > "$d/INDEX.md"
assert_exit 0 "--force re-scaffolds over existing" "$d" --corpus flat --force

# NEGATIVE CONTROL — prove the corpus-present guard has TEETH.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth proof: neuter the corpus-present guard, expect the data-loss fixture to CLOBBER --"
  mkdir -p "$TMP/mk/toolbelt"; ln -sfn "$HERE/../../templates" "$TMP/mk/templates"
  mutant="$TMP/mk/toolbelt/init.sh"
  awk '/^corpus_present\(\) \{/ { print "corpus_present() { return 1; }  # MUTANT: guard neutered"; next } { print }' "$SUT" > "$mutant"
  if ! grep -q 'MUTANT: guard neutered' "$mutant"; then
    no "teeth: could not build mutant (guard line not found)"
  else
    d="$TMP/teeth"; mkdir -p "$d"; printf 'REAL HAND-CURATED GAPS\n' > "$d/RESEARCH-STATE.md"
    bash "$mutant" "$d" --corpus flat >/dev/null 2>&1; mg=$?
    if [ "$mg" = 0 ] && ! grep -qF 'REAL HAND-CURATED GAPS' "$d/RESEARCH-STATE.md"; then
      ok "teeth: mutant clobbers curated state (exit 0, gone) → refuse tests have teeth"
    else
      no "teeth: mutant exit $mg / data present — refuse tests do NOT depend on the guard (THEATER)"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
