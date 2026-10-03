#!/usr/bin/env bash
# block-files.test.sh — unit harness for lib/block-files.sh (U11).
#
# Tests block_file_filter: forward mode (canonical block files pass through), inverse
# mode (-v: non-canonical pass through), prefix mode (scope to a focus prefix), stdin
# error when tty, and exit-code fidelity (grep's status passed verbatim — 0/1/2).
#
# Usage: block-files.test.sh                (run the suite)
#        block-files.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = all assertions held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/../lib/block-files.sh"
[ -f "$HELPER" ] || { echo "FATAL: helper under test not found: $HELPER" >&2; exit 2; }

# shellcheck source=../lib/block-files.sh
. "$HELPER"
declare -F block_file_filter >/dev/null 2>&1 || { echo "FATAL: block_file_filter not defined after sourcing" >&2; exit 2; }

pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== block-files.test.sh (SUT: lib/$(basename "$HELPER")) =="

# Helper: run filter on a newline-separated string; return stdout.
run_filter() { printf '%s\n' "$@" | block_file_filter; }
run_filter_v() { printf '%s\n' "$@" | block_file_filter -v; }
run_filter_pfx() { local pfx="$1"; shift; printf '%s\n' "$@" | block_file_filter "$pfx"; }

# --- 1. Canonical forms PASS through (forward mode) ---
got="$(run_filter "/corpus/tema3-block1.md")"
[ "$got" = "/corpus/tema3-block1.md" ] \
  && ok "1 canonical block1 passes" || no "1 canonical block1 passes" "got='$got'"

got="$(run_filter "/corpus/prefix-bloque12.md")"
[ "$got" = "/corpus/prefix-bloque12.md" ] \
  && ok "2 canonical bloque12 passes" || no "2 canonical bloque12 passes" "got='$got'"

got="$(run_filter "/corpus/ab-block3-foo-bar.md")"
[ "$got" = "/corpus/ab-block3-foo-bar.md" ] \
  && ok "3 canonical block with suffix passes" || no "3 canonical block with suffix passes" "got='$got'"

# --- 2. Decoys are BLOCKED (forward mode) ---
got="$(printf '%s\n' "/corpus/blocked-notes.md" | block_file_filter || true)"
[ -z "$got" ] \
  && ok "4 decoy blocked-notes.md blocked" || no "4 decoy blocked-notes.md blocked" "got='$got'"

got="$(printf '%s\n' "/corpus/block12.md" | block_file_filter || true)"
[ -z "$got" ] \
  && ok "5 decoy block12.md (no prefix) blocked" || no "5 decoy block12.md (no prefix) blocked" "got='$got'"

got="$(printf '%s\n' "/corpus/x-bloque3.md" | block_file_filter || true)"
[ "$got" = "/corpus/x-bloque3.md" ] \
  && ok "6 x-bloque3.md PASSES — prefix 'x' is valid; single-char prefix allowed" \
  || no "6 x-bloque3.md PASSES — prefix 'x' is valid; single-char prefix allowed" "got='$got'"
# Extra: a file WITHOUT the required prefix-dash does NOT pass
got2="$(printf '%s\n' "/corpus/bloque3.md" | block_file_filter || true)"
[ -z "$got2" ] \
  && ok "6b bloque3.md (no prefix-dash) blocked" || no "6b bloque3.md (no prefix-dash) blocked" "got='$got2'"

# --- 3. Nested path (retros/) PASSES when file is canonical ---
got="$(run_filter "/corpus/retros/subfocus-block5.md")"
[ "$got" = "/corpus/retros/subfocus-block5.md" ] \
  && ok "7 nested canonical in retros/ passes" || no "7 nested canonical in retros/ passes" "got='$got'"

# --- 4. Bare filename (git-log --name-only output) PASSES ---
got="$(run_filter "prefix-block7.md")"
[ "$got" = "prefix-block7.md" ] \
  && ok "8 bare filename (no slash) passes — (^|/) anchor" \
  || no "8 bare filename (no slash) passes — (^|/) anchor" "got='$got'"

# --- 5. Prefix mode scopes to the prefix ---
got="$(run_filter_pfx "tema3-" "/corpus/tema3-block1.md" "/corpus/tema4-block2.md")"
[ "$got" = "/corpus/tema3-block1.md" ] \
  && ok "5a prefix 'tema3-' keeps tema3, drops tema4" \
  || no "5a prefix 'tema3-' keeps tema3, drops tema4" "got='$got'"

got="$(run_filter_pfx "tema4-" "/corpus/tema3-block1.md" "/corpus/tema4-block2.md")"
[ "$got" = "/corpus/tema4-block2.md" ] \
  && ok "5b prefix 'tema4-' keeps tema4, drops tema3" \
  || no "5b prefix 'tema4-' keeps tema4, drops tema3" "got='$got'"

# --- 6. Inverse mode (-v) ---
got="$(run_filter_v "/corpus/blocked-notes.md" "/corpus/tema3-block1.md")"
[ "$got" = "/corpus/blocked-notes.md" ] \
  && ok "6a -v passes decoy, blocks canonical" \
  || no "6a -v passes decoy, blocks canonical" "got='$got'"

# --- 7. Exit code fidelity ---
# grep exit 0 (match): block_file_filter must exit 0
printf '%s\n' "/x/prefix-block1.md" | block_file_filter >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "7a exit 0 on match" || no "7a exit 0 on match" "rc=$rc"

# grep exit 1 (no match): block_file_filter must exit 1
printf '%s\n' "/x/blocked-notes.md" | block_file_filter >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "7b exit 1 on no-match" || no "7b exit 1 on no-match" "rc=$rc"

# --- 8. Idempotent source ---
# shellcheck source=../lib/block-files.sh
. "$HELPER"
declare -F block_file_filter >/dev/null 2>&1 \
  && ok "8 idempotent double-source" || no "8 idempotent double-source"

# --- 9. Nested worktree helpers (kit issue #1223) ---
# nw_fixture <dir>: .claude/worktrees/<name>, a linked-worktree .git file, a submodule-style .git
# file, a nested clone (.git dir) and a corpus root with its OWN .git file.
nw_fixture() {
  local d="$1"
  mkdir -p "$d/.claude/worktrees/agent-1" "$d/side-wt" "$d/sub" "$d/clone/.git" "$d/deep/er/wt2"
  # A linked worktree is recognised by its gitdir's `commondir` file, so the fake gitdirs carry one.
  mkdir -p "$d/.fakegit/worktrees/side-wt" "$d/.fakegit/worktrees/wt2" "$d/.fakegit/worktrees/self"
  : > "$d/.fakegit/worktrees/side-wt/commondir"; : > "$d/.fakegit/worktrees/wt2/commondir"
  : > "$d/.fakegit/worktrees/self/commondir"
  printf 'gitdir: %s/.fakegit/worktrees/side-wt\n' "$d" > "$d/side-wt/.git"
  printf 'gitdir: %s/.fakegit/worktrees/wt2\n' "$d" > "$d/deep/er/wt2/.git"
  # git also writes the BACK-POINTER <gitdir>/gitdir (absolute path of the worktree's .git file) for
  # every linked worktree; a worktree is only proven when it points back at the .git file naming it.
  printf '%s/side-wt/.git\n' "$d" > "$d/.fakegit/worktrees/side-wt/gitdir"
  printf '%s/deep/er/wt2/.git\n' "$d" > "$d/.fakegit/worktrees/wt2/gitdir"
  # contrived (#1301 item 2): `gitdir: .` + a stray commondir in the SAME dir passes the commondir
  # test, but nothing points back at it → not a worktree
  mkdir -p "$d/contrived"; : > "$d/contrived/commondir"
  printf 'gitdir: .\n' > "$d/contrived/.git"
  # commondir present but NO back-pointer file → unprovable → not a root
  mkdir -p "$d/nobp" "$d/.fakegit/worktrees/nobp"; : > "$d/.fakegit/worktrees/nobp/commondir"
  printf 'gitdir: %s/.fakegit/worktrees/nobp\n' "$d" > "$d/nobp/.git"
  # back-pointer names ANOTHER worktree's .git file → this one is not proven
  mkdir -p "$d/wrongbp" "$d/.fakegit/worktrees/wrongbp"; : > "$d/.fakegit/worktrees/wrongbp/commondir"
  printf 'gitdir: %s/.fakegit/worktrees/wrongbp\n' "$d" > "$d/wrongbp/.git"
  printf '%s/side-wt/.git\n' "$d" > "$d/.fakegit/worktrees/wrongbp/gitdir"
  # relative back-pointer (git >= 2.48 worktree.useRelativePaths) is resolved against the gitdir
  mkdir -p "$d/relbp" "$d/.fakegit/worktrees/relbp"; : > "$d/.fakegit/worktrees/relbp/commondir"
  printf 'gitdir: %s/.fakegit/worktrees/relbp\n' "$d" > "$d/relbp/.git"
  printf '../../../relbp/.git\n' > "$d/.fakegit/worktrees/relbp/gitdir"
  printf 'gitdir: ../.git/modules/sub\n' > "$d/sub/.git"
  # look-alike: gitdir text contains /worktrees/ but there is no commondir (submodule of a worktree)
  mkdir -p "$d/sub2" "$d/.fakegit/worktrees/wtx/modules/notes"
  printf 'gitdir: %s/.fakegit/worktrees/wtx/modules/notes\n' "$d" > "$d/sub2/.git"
  # …even with a (forged) back-pointer, only the commondir proof rejects it (isolates TOOTH-5)
  printf '%s/sub2/.git\n' "$d" > "$d/.fakegit/worktrees/wtx/modules/notes/gitdir"
  printf 'gitdir: %s/.fakegit/worktrees/self\n' "$d" > "$d/.git"   # the root's own .git FILE
  # its gitdir carries commondir AND a back-pointer to the root, so only the own-.git skip rejects
  # it (isolates TOOTH-7)
  printf '%s/.git\n' "$d" > "$d/.fakegit/worktrees/self/gitdir"
}

# nw_checks <helper-file>: source <helper-file> in a subshell and run every #1223 assertion;
# prints one "FAIL:<name>" line per broken assertion (empty output = all held). Used for the
# real helper AND for each mutant, so a mutant that leaves the output empty has no teeth.
nw_checks() {
  (
    # The helper is idempotent (declare -F guard): the copy sourced at the top of this suite
    # would shadow a mutant, so drop it first — otherwise every mutant silently tests the original.
    unset -f block_file_filter block_files_nested_worktree_roots block_files_path_in_nested_worktree
    # shellcheck disable=SC1090
    . "$1"
    d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
    nw_fixture "$d"
    roots="$(block_files_nested_worktree_roots "$d")"; rc=$?
    [ "$rc" -eq 0 ] || echo "FAIL:roots-rc($rc)"
    <<<"$roots" grep -qxF "$d/.claude/worktrees" || echo "FAIL:fixed-claude-worktrees-root"
    <<<"$roots" grep -qxF "$d/side-wt" || echo "FAIL:linked-worktree-root"
    <<<"$roots" grep -qxF "$d/deep/er/wt2" || echo "FAIL:deep-linked-worktree-root"
    <<<"$roots" grep -qxF "$d/sub" && echo "FAIL:submodule-must-not-be-root"
    <<<"$roots" grep -qxF "$d/sub2" && echo "FAIL:worktrees-lookalike-gitdir-without-commondir-must-not-be-root"
    <<<"$roots" grep -qxF "$d/contrived" && echo "FAIL:contrived-gitdir-dot-with-stray-commondir-must-not-be-root"
    <<<"$roots" grep -qxF "$d/nobp" && echo "FAIL:commondir-without-backpointer-must-not-be-root"
    <<<"$roots" grep -qxF "$d/wrongbp" && echo "FAIL:backpointer-naming-another-worktree-must-not-be-root"
    <<<"$roots" grep -qxF "$d/relbp" || echo "FAIL:relative-backpointer-worktree-must-be-root"
    <<<"$roots" grep -qxF "$d/clone" && echo "FAIL:nested-clone-must-not-be-root"
    <<<"$roots" grep -qxF "$d" && echo "FAIL:own-git-file-must-not-make-root-a-root"
    # predicate: root itself, under it, FIRST / MIDDLE / LAST / ONLY roots, sibling-prefix trap
    block_files_path_in_nested_worktree "$d/side-wt/x-block1.md" "$roots" || echo "FAIL:under-linked-worktree"
    block_files_path_in_nested_worktree "$d/.claude/worktrees/agent-1/x-block1.md" "$roots" || echo "FAIL:under-claude-worktrees"
    block_files_path_in_nested_worktree "$d/deep/er/wt2/a/b/x-block1.md" "$roots" || echo "FAIL:under-deep-worktree"
    block_files_path_in_nested_worktree "$d/side-wt" "$roots" || echo "FAIL:root-itself-counts"
    block_files_path_in_nested_worktree "$d/x-block1.md" "$roots" && echo "FAIL:corpus-file-not-under"
    block_files_path_in_nested_worktree "$d/side-wt-old/x-block1.md" "$roots" && echo "FAIL:sibling-prefix-trap(side-wt-old)"
    block_files_path_in_nested_worktree "$d/.claude/worktrees-old/x-block1.md" "$roots" && echo "FAIL:sibling-prefix-trap(worktrees-old)"
    block_files_path_in_nested_worktree "$d/sub/x-block1.md" "$roots" && echo "FAIL:submodule-file-not-under"
    block_files_path_in_nested_worktree "$d/x-block1.md" "" && echo "FAIL:empty-roots-means-not-under"
    block_files_path_in_nested_worktree "$d/side-wt/x" "$d/side-wt" || echo "FAIL:single-root-only-entry"
    block_files_path_in_nested_worktree "$d/b/x" "$d/a
$d/b
$d/c" || echo "FAIL:middle-root"
    block_files_path_in_nested_worktree "$d/c/x" "$d/a
$d/b
$d/c" || echo "FAIL:last-root"
    block_files_path_in_nested_worktree "$d/a/x" "$d/a
$d/b
$d/c" || echo "FAIL:first-root"
    # a corpus that itself lives under .claude/worktrees/ is NOT excluded wholesale
    mkdir -p "$d/.claude/worktrees/agent-9/corpus"
    r2="$(block_files_nested_worktree_roots "$d/.claude/worktrees/agent-9/corpus")"
    block_files_path_in_nested_worktree "$d/.claude/worktrees/agent-9/corpus/x-block1.md" "$r2" \
      && echo "FAIL:corpus-inside-a-worktree-is-not-excluded"
    # absent root: typed failure, not an empty-success
    block_files_nested_worktree_roots "$d/does-not-exist" >/dev/null 2>&1; [ "$?" -eq 2 ] || echo "FAIL:absent-root-rc2"
    # incomplete traversal (unreadable dir): rc 3 + typed WARN, roots found so far still printed.
    # chmod 000 does not stop root, so the case is a counted SKIP there. Needs bash >= 4.4.
    if [ "$(id -u)" -eq 0 ]; then
      echo "SKIP:incomplete-traversal (running as root)"
    elif [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
      echo "SKIP:incomplete-traversal (bash < 4.4 cannot recover find's status)"
    else
      mkdir -p "$d/locked"; chmod 000 "$d/locked"
      r3="$(block_files_nested_worktree_roots "$d" 2>"$d/r3.err")"; rc3=$?
      chmod 755 "$d/locked"
      [ "$rc3" -eq 3 ] || echo "FAIL:incomplete-traversal-rc3(rc=$rc3)"
      grep -q 'find exited' "$d/r3.err" || echo "FAIL:incomplete-traversal-typed-warn"
      <<<"$r3" grep -qxF "$d/side-wt" || echo "FAIL:incomplete-traversal-keeps-partial-roots"
    fi
  )
}
# nw_real_checks <helper-file>: REAL git fixtures (review of PR #1300, B1). A linked worktree is
# told apart from a submodule by the gitdir's `commondir` file, never by the path text:
#  (a) target is itself a linked worktree and carries a submodule whose gitdir is
#      <main>/.git/worktrees/<wt>/modules/notes — contains "/worktrees/" but is NOT a worktree;
#  (b) a submodule checked out at a path containing "worktrees" (research/worktrees/x);
#  (c) a real nested linked worktree IS a root; (d) a stale one (gitdir gone) is NOT excluded.
nw_real_checks() {
  (
    unset -f block_file_filter block_files_nested_worktree_roots block_files_path_in_nested_worktree
    # shellcheck disable=SC1090
    . "$1"
    d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
    g() { git -c protocol.file.allow=always -c user.email=t@e.com -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
    # sub: a repo to use as a submodule source
    mkdir "$d/subsrc"; g -C "$d/subsrc" init -q; : > "$d/subsrc/f"; g -C "$d/subsrc" add f; g -C "$d/subsrc" commit -q -m i
    # main repo with submodule `notes` and a submodule at research/worktrees/x
    mkdir "$d/main"; g -C "$d/main" init -q; : > "$d/main/.keep"; g -C "$d/main" add .keep; g -C "$d/main" commit -q -m i
    g -C "$d/main" submodule add "file://$d/subsrc" notes
    g -C "$d/main" submodule add "file://$d/subsrc" research/worktrees/x
    g -C "$d/main" commit -q -m subs
    # (a) the target is a linked worktree of main; init its submodules
    g -C "$d/main" worktree add "$d/wt" -b wtb
    g -C "$d/wt" submodule update --init
    [ -f "$d/wt/notes/.git" ] || echo "FAIL:fixture-a-submodule-missing"
    ra="$(block_files_nested_worktree_roots "$d/wt" 2>/dev/null)"
    <<<"$ra" grep -qxF "$d/wt/notes" && echo "FAIL:a-submodule-in-linked-worktree-target-must-not-be-root"
    block_files_path_in_nested_worktree "$d/wt/notes/x-block1.md" "$ra" && echo "FAIL:a-submodule-file-must-not-be-excluded"
    # (b) submodule at a path containing "worktrees", target = main
    g -C "$d/main" submodule update --init
    rb="$(block_files_nested_worktree_roots "$d/main" 2>/dev/null)"
    <<<"$rb" grep -qxF "$d/main/research/worktrees/x" && echo "FAIL:b-submodule-under-worktrees-path-must-not-be-root"
    <<<"$rb" grep -qxF "$d/main/notes" && echo "FAIL:b-plain-submodule-must-not-be-root"
    # (c) a real nested linked worktree under the target IS a root
    g -C "$d/main" worktree add "$d/main/side" -b sideb
    rc="$(block_files_nested_worktree_roots "$d/main" 2>/dev/null)"
    <<<"$rc" grep -qxF "$d/main/side" || echo "FAIL:c-real-linked-worktree-must-be-root"
    # (d) stale: gitdir removed → cannot be proven a worktree → NOT excluded (blocking-safe)
    rm -rf "$d/main/.git/worktrees/side"
    rd="$(block_files_nested_worktree_roots "$d/main" 2>/dev/null)"
    <<<"$rd" grep -qxF "$d/main/side" && echo "FAIL:d-stale-worktree-must-not-be-excluded"
    # symlinked target: probe must still see the tree (find -H)
    g -C "$d/main" worktree add "$d/main/side2" -b side2b
    ln -s "$d/main" "$d/link"
    rl="$(block_files_nested_worktree_roots "$d/link" 2>/dev/null)"; rcl=$?
    [ "$rcl" -eq 0 ] || echo "FAIL:symlinked-target-rc($rcl)"
    <<<"$rl" grep -qxF "$d/link/side2" || echo "FAIL:symlinked-target-sees-worktrees"
  )
}
nwr_out="$(nw_real_checks "$HELPER")"
nwr_fails="$(<<<"$nwr_out" grep '^FAIL:' | tr '\n' ' ')"
[ -z "$nwr_fails" ] \
  && ok "9b nested-worktree roots on REAL git fixtures (linked-worktree target + submodule, submodule under worktrees/ path, stale, symlinked target)" \
  || no "9b nested-worktree roots on real git fixtures" "$nwr_fails"

nw_out="$(nw_checks "$HELPER")"
nw_fails="$(<<<"$nw_out" grep '^FAIL:' | tr '\n' ' ')"
[ -z "$nw_fails" ] \
  && ok "9 nested-worktree helpers: roots + predicate hold (edges, traps, absent root, incomplete traversal)" \
  || no "9 nested-worktree helpers" "$nw_fails"
<<<"$nw_out" grep '^SKIP:' | while IFS= read -r _s; do
  printf '  SKIP  9 nested-worktree helpers: %s\n' "${_s#SKIP:}"
done

echo ""
echo "== $pass passed · $fail failed =="

# ---- MUTATION TEETH (--prove-teeth) -------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo ""
  echo "== mutation controls =="
  t_pass=0; t_fail=0
  tok() { printf '  TOOTH-PASS  %s\n' "$1"; t_pass=$((t_pass+1)); }
  tno() { printf '  TOOTH-FAIL  %s\n' "$1"; t_fail=$((t_fail+1)); }

  MUTANT="$(mktemp /tmp/block-files-mutant.XXXXXX.sh)"
  trap 'rm -f "$MUTANT"' EXIT

  # TOOTH-1: anchor '^' only → absolute paths like /corpus/prefix-block1.md no longer match
  # (^|/) matches the '/' before the basename; bare '^' cannot match inside an absolute path.
  mutant_t1() { grep -E '^[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'; }
  out_t1="$(printf '%s\n' '/corpus/prefix-block1.md' | mutant_t1 2>/dev/null || true)"
  [ -z "$out_t1" ] && tok "TOOTH-1: ^-only mutant blocks absolute path ((^|/) is load-bearing)" \
                   || tno "TOOTH-1: ^-only mutant still passed absolute path — TOOTH DID NOT BITE"

  # TOOTH-2: prefix [^/]+- optional → block12.md decoy passes
  # Prove: a mutant without the required prefix-dash would match bare 'block12.md'
  mutant_t2() { grep -E '(^|/)(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$'; }
  out_t2="$(printf '%s\n' '/corpus/block12.md' | mutant_t2 2>/dev/null || true)"
  [ -n "$out_t2" ] && tok "TOOTH-2: optional-prefix mutant passes block12.md decoy (prefix is load-bearing)" \
                   || tno "TOOTH-2: optional-prefix mutant did NOT pass block12.md — TOOTH DID NOT BITE"

  # TOOTH-3: remove declare -F guard in verify-parity.sh → broken lib no longer exits 1
  # Simulate: source a lib that does NOT define block_file_filter, then run the guard-stripped script fragment
  BROKEN_LIB="$(mktemp /tmp/broken-bf.XXXXXX.sh)"
  printf '#!/usr/bin/env bash\n# intentionally empty\n' > "$BROKEN_LIB"
  GUARD_STRIPPED="$(mktemp /tmp/guard-stripped.XXXXXX.sh)"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "%s"\necho "guard absent — no exit 1"\n' "$BROKEN_LIB" > "$GUARD_STRIPPED"
  bash "$GUARD_STRIPPED" >/dev/null 2>&1; rc=$?
  # With guard removed the script exits 0 (no error), so we expect exit 0 = the PROBLEM
  # The tooth proves that adding the guard WOULD catch it; without the guard, rc is 0 (bad)
  [ "$rc" -eq 0 ] && tok "TOOTH-3: guard-absent fragment exits 0 (proves guard is load-bearing)" \
                  || tno "TOOTH-3: guard-absent fragment did NOT exit 0 (tooth logic error)"
  rm -f "$BROKEN_LIB" "$GUARD_STRIPPED"

  # TOOTH-4..11 (#1223, #1301): sed mutants of the REAL helper file. Each must (a) differ from the
  # original (a no-op sed is theater) and (b) make its checker (nw_checks, or nw_real_checks when named) report the named failure.
  nw_tooth() { # <label> <sed-expr> <expected FAIL: token> [checker: nw_checks|nw_real_checks]
    local label="$1" expr="$2" want="$3" chk="${4:-nw_checks}" mf out
    mf="$(mktemp /tmp/block-files-nwmut.XXXXXX.sh)"
    sed "$expr" "$HELPER" > "$mf"
    if cmp -s "$HELPER" "$mf"; then
      tno "$label: mutant identical to helper — sed did not match (TOOTH NOT BUILT)"; rm -f "$mf"; return
    fi
    out="$("$chk" "$mf")"
    if <<<"$out" grep -qF "FAIL:$want"; then
      tok "$label: mutant makes $chk report FAIL:$want"
    else
      tno "$label: mutant did NOT trip FAIL:$want — got [$(printf '%s' "$out" | tr '\n' ' ')]"
    fi
    rm -f "$mf"
  }
  nw_tooth "TOOTH-4 sibling-prefix (case \"\$_r\"* instead of \"\$_r\"/*)" \
    's#"\$_r"|"\$_r"/\*) return 0#"$_r"*) return 0#' "sibling-prefix-trap(side-wt-old)"
  nw_tooth "TOOTH-5 commondir proof dropped (look-alike gitdir counted as worktree)" \
    '/SENTINEL-COMMONDIR-START/,/SENTINEL-COMMONDIR-END/d' "worktrees-lookalike-gitdir-without-commondir-must-not-be-root"
  # A real submodule has no back-pointer either, so BOTH proofs must go for it to be miscounted.
  nw_tooth "TOOTH-9 commondir AND back-pointer proofs dropped (real submodule of a linked-worktree target)" \
    '/SENTINEL-COMMONDIR-START/,/SENTINEL-COMMONDIR-END/d;/SENTINEL-BACKPOINTER-START/,/SENTINEL-BACKPOINTER-END/d' "a-submodule-in-linked-worktree-target-must-not-be-root" nw_real_checks
  nw_tooth "TOOTH-11a back-pointer proof dropped (gitdir: . + stray commondir counted as worktree)" \
    '/SENTINEL-BACKPOINTER-START/,/SENTINEL-BACKPOINTER-END/d' "contrived-gitdir-dot-with-stray-commondir-must-not-be-root"
  nw_tooth "TOOTH-11b back-pointer proof dropped (commondir without a back-pointer counted)" \
    '/SENTINEL-BACKPOINTER-START/,/SENTINEL-BACKPOINTER-END/d' "commondir-without-backpointer-must-not-be-root"
  nw_tooth "TOOTH-11c back-pointer proof dropped (back-pointer naming another worktree counted)" \
    '/SENTINEL-BACKPOINTER-START/,/SENTINEL-BACKPOINTER-END/d' "backpointer-naming-another-worktree-must-not-be-root"
  nw_tooth "TOOTH-11d back-pointer compared as TEXT only (relative back-pointer no longer a root)" \
    's/\[ "\$_bp" -ef "\$_gf" \] || continue/[ "$_bp" = "$_gf" ] || continue/' "relative-backpointer-worktree-must-be-root"
  nw_tooth "TOOTH-10 symlinked target not followed (find -H dropped)" \
    's/find -H "\$_root"/find "$_root"/' "symlinked-target-sees-worktrees" nw_real_checks
  nw_tooth "TOOTH-6 fixed .claude/worktrees root dropped" \
    '/printf .%s\\n. "\$_root\/.claude\/worktrees"/d' "fixed-claude-worktrees-root"
  nw_tooth "TOOTH-7 own .git file not skipped" \
    '/\[ "\${_gf%\/.git}" = "\$_root" \] && continue/d' "own-git-file-must-not-make-root-a-root"
  if [ "$(id -u)" -eq 0 ]; then
    printf '  SKIP  TOOTH-8 incomplete-traversal rc3 (running as root — chmod 000 does not protect)\n'
  else
    nw_tooth "TOOTH-8 incomplete traversal reported as success (return 3 → return 0)" \
      's/return 3$/return 0/' "incomplete-traversal-rc3(rc=0)"
  fi

  echo ""
  echo "  teeth passed: $t_pass  teeth failed: $t_fail"
  [ "$t_fail" -eq 0 ] || fail=$((fail+1))
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1
