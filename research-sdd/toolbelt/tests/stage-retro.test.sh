#!/usr/bin/env bash
# stage-retro.test.sh — red-first regression harness for stage-retro.sh, which stages ONE pending
# §18 retro as a branch in the kit repo for supervised review (METHODOLOGY §18). Unlike sweep-retros,
# this script MUTATES a git repo: it runs `git checkout -b retro/<target>-<slug>`. That makes its
# review-status guard SAFETY-CRITICAL — an already-'applied' or 'dismissed' retro must be refused
# BEFORE any branch is created.
#
# WHY THIS SHAPE. The script sources the shared reader lib/retro-status.sh and gates on its output:
# an 'applied'/'dismissed' retro exits 2 (nothing to stage) unless $2 == --force. Existence of the
# helper is NOT enough — the source must have DEFINED retro_review_status. The script does not run
# under `set -e`, so a helper that exists and sources cleanly but defines NO function would leave the
# reader as a 'command not found', the guard would read an empty status, skip the applied|dismissed
# gate, and perform the DESTRUCTIVE `git checkout -b` on a retro that was already resolved (fail-OPEN).
# The post-source `declare -F` guard must instead ABORT non-zero BEFORE any git mutation (fail-CLOSED).
#
# This suite exercises a throwaway COPY of the SUT placed at <sandbox>/research-sdd/toolbelt/ so the
# script's KIT_REPO=dirname/../.. resolves to a HERMETIC git repo we init per case — no touching the
# real kit repo, no network. Each case asserts on `git branch --list 'retro/*'` in that sandbox repo,
# which is the ground truth for "did the destructive path run".
#
# Usage: stage-retro.test.sh                (run the suite)
#        stage-retro.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
LIB="$HERE/../lib/retro-status.sh"           # shared marker reader the SUT sources
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkrepo <name> <helper-mode> : lay down a hermetic kit git repo at <ROOT>/<name> with a runnable
# COPY of the SUT at research-sdd/toolbelt/ (so KIT_REPO=dirname/../.. resolves inside it) plus the
# shared helper. <helper-mode> = 'real' (copy the genuine helper) | 'broken' (a file that exists and
# sources cleanly but defines NO retro_review_status). Echoes the repo dir. Repo is committed clean
# on branch main so the script's clean-tree/on-main preconditions hold.
mkrepo() {
  local repo="$ROOT/$1" mode="$2"
  mkdir -p "$repo/research-sdd/toolbelt/lib"
  cp "$SUT" "$repo/research-sdd/toolbelt/stage-retro.sh"
  if [ "$mode" = broken ]; then
    printf '#!/usr/bin/env bash\n# broken helper: sources cleanly but defines no retro_review_status\n' \
      > "$repo/research-sdd/toolbelt/lib/retro-status.sh"
  else
    cp "$LIB" "$repo/research-sdd/toolbelt/lib/retro-status.sh"
  fi
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  tester
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# mkretro <repo> <target> <filename> <marker-line|-> : write a retro under <repo>/<target>/retros/
# with an optional top marker and a minimal Proposed-kit-deltas section (the block the SUT prints).
# NOTE: written AFTER the init commit so the tree may be dirty; every case commits before running.
mkretro() {
  local repo="$1" tgt="$2" fname="$3" marker="$4"
  mkdir -p "$repo/$tgt/retros"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n'
  } > "$repo/$tgt/retros/$fname"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "add retro $fname"
}

# branches <repo> : echo the retro/* local branches (empty when the destructive path never ran).
branches() { git -C "$1" branch --list 'retro/*' | tr -d ' *'; }

# run <repo> <retro-relpath> [extra-arg] : invoke the sandbox SUT copy, capture stdout+stderr/RC.
run() {
  local repo="$1" rel="$2"; shift 2
  OUT="$("$BASH_BIN" "$repo/research-sdd/toolbelt/stage-retro.sh" "$repo/$rel" "$@" 2>&1)"; RC=$?
}

echo "== stage-retro.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — HAPPY PATH baseline (real helper, PENDING retro) → the destructive branch IS created. This
#     anchors the suite: proves the sandbox genuinely reaches `git checkout -b` when the gate allows
#     it, so a later "no branch" assertion means the guard REFUSED, not that staging was inert.
repo="$(mkrepo happy real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 0 ] \
   && grep -q 'staging retro for supervised review' <<<"$OUT" \
   && [ "$(branches "$repo")" = "retro/targetA-r1" ]; then
  ok "1 pending retro (real helper) → branch created (destructive path reached)" "(exit $RC)"
else
  no "1 pending retro (real helper) → branch created (destructive path reached)" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 2 — GUARD baseline (real helper, APPLIED retro) → refused with exit 2, NO branch. The genuine
#     review-status gate must keep an already-resolved retro out of staging without mutating git.
repo="$(mkrepo applied real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 2 ] \
   && grep -qi "already 'applied'" <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "2 applied retro (real helper) → refused exit 2, no branch" "(exit $RC)"
else
  no "2 applied retro (real helper) → refused exit 2, no branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 3 — FAIL-CLOSED on a broken helper over the DESTRUCTIVE path (the core contract). Helper EXISTS and
#     sources cleanly but defines NO retro_review_status. The retro is already 'applied'. WITHOUT the
#     post-source `declare -F` guard the reader is 'command not found', status reads empty, the
#     applied|dismissed gate is skipped, and `git checkout -b` runs — staging an already-resolved
#     retro (fail-OPEN on the dangerous path). WITH the guard the script MUST abort non-zero with the
#     helper-error message and create NO branch. This is the assertion the whole suite exists for.
repo="$(mkrepo broken-applied broken)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define retro_review_status' <<<"$OUT" \
   && ! grep -q 'staging retro for supervised review' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "3 broken helper + applied retro → fail-closed, NO retro/* branch" "(exit $RC)"
else
  no "3 broken helper + applied retro → fail-closed, NO retro/* branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 4 — FAIL-CLOSED even for a PENDING retro. The guard is unconditional: a broken helper aborts before
#     ANY staging regardless of the (unreadable) status. So even a retro that WOULD be stageable must
#     be refused non-zero with no branch — the script never proceeds on an undefined reader.
repo="$(mkrepo broken-pending broken)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define retro_review_status' <<<"$OUT" \
   && [ -z "$(branches "$repo")" ]; then
  ok "4 broken helper + pending retro → fail-closed, NO branch" "(exit $RC)"
else
  no "4 broken helper + pending retro → fail-closed, NO branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 5 — Guard fires BEFORE the missing-file usage error is the only exit. A nonexistent retro path still
#     exits non-zero via the arg check (that check precedes the source), so this case pins that the
#     broken-helper guard does not REGRESS the ordinary usage guard: bad arg → non-zero, no branch.
repo="$(mkrepo broken-badarg broken)"
run "$repo" "targetA/retros/does-not-exist.md"
if [ "$RC" != 0 ] && [ -z "$(branches "$repo")" ]; then
  ok "5 broken helper + missing retro arg → non-zero, no branch" "(exit $RC)"
else
  no "5 broken helper + missing retro arg → non-zero, no branch" "exit=$RC branches=[$(branches "$repo")] out=[$OUT]"
fi

# 6 — TRACEABILITY BACKLINK (Feature #27): the SUGGESTED commit line carries a `Retro:` trailer pointing back
#     to the source retro as <target>/retros/<file>@<target-sha>. The happy-path retro is committed in the
#     sandbox repo, so stage-retro resolves a short sha and prints the full ref. SUGGESTED message only — the
#     script still auto-commits nothing (assert no retro/* branch is required; case 1 already covers staging).
repo="$(mkrepo trailer real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
run "$repo" "targetA/retros/r1.md"
if [ "$RC" = 0 ] && grep -qE 'Retro: targetA/retros/r1\.md@[0-9a-f]+' <<<"$OUT"; then
  ok "6 suggested commit carries Retro: <target>/retros/<file>@<sha> trailer" "(exit $RC)"
else
  no "6 suggested commit carries Retro: <target>/retros/<file>@<sha> trailer" "exit=$RC out=[$OUT]"
fi

# 6b — FIX-2 REGRESSION PIN: the SAME trailer, but invoked with a RELATIVE retro path (relative to the repo
#      root, not target_root). Pre-fix, `git -C "$target_root" log -- "$retro"` re-resolved that relative
#      pathspec AGAINST the rebased -C cwd (target_root), effectively looking for
#      "$target_root/targetA/retros/r1.md" — never matches a genuinely TRACKED retro, so the sha silently
#      comes back empty and the '@<sha>' suffix is dropped (misreported as untracked). Absolutizing the
#      retro path before the git log call fixes it; this must still resolve the sha under a relative arg.
repo="$(mkrepo trailer-relative real)"
mkretro "$repo" "targetA" "r1.md" "<!-- review-status: pending -->"
relOUT="$(cd "$repo" && "$BASH_BIN" "research-sdd/toolbelt/stage-retro.sh" "targetA/retros/r1.md" 2>&1)"; relRC=$?
if [ "$relRC" = 0 ] && grep -qE 'Retro: targetA/retros/r1\.md@[0-9a-f]+' <<<"$relOUT"; then
  ok "6b RELATIVE retro path still resolves the Retro: <sha> trailer (FIX-2 regression pin)" "(exit $relRC)"
else
  no "6b RELATIVE retro path still resolves the Retro: <sha> trailer (FIX-2 regression pin)" "exit=$relRC out=[$relOUT]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Case 3 claims the post-source `declare -F` guard is what turns a broken
# helper into a fail-CLOSED abort on the destructive path. Neuter the guard on a throwaway copy so its
# check can never fail (force it always-true), pair it with the broken helper + an APPLIED retro, and
# re-run: with the guard dead the script MUST fall back to the OLD fail-OPEN — it reaches the staging
# banner and CREATES the retro/* branch on an already-resolved retro. If the mutant stayed closed
# (no branch), case 3 would be theater — the guard would not be what protects the destructive path.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the fail-closed guard, expect a broken helper to fail-OPEN and BRANCH --"
  anchor='declare -F retro_review_status >/dev/null 2>&1 || { echo "stage-retro: helper $LIB failed to define retro_review_status" >&2; exit 1; }'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate fail-closed guard" "anchor not found — SUT drifted?"
  else
    repo="$(mkrepo teeth-guard broken)"
    mkretro "$repo" "targetA" "r1.md" "<!-- review-status: applied 2026-01-01 -->"
    mutant="$repo/research-sdd/toolbelt/stage-retro.sh"   # replace the sandbox copy with the mutant
    # Neuter the guard to a no-op ':' — a literal replacement with NO '&' (bash 5.1+ expands an
    # unescaped '&' in the replacement to the matched text, which would corrupt the mutant).
    neutered=':'
    printf '%s\n' "${content/"$anchor"/$neutered}" > "$mutant"
    # Overwriting the committed SUT copy dirties the tree; commit it so the script's clean-tree
    # precondition holds and the ONLY thing that can stop staging is the (neutered) guard.
    git -C "$repo" add -A; git -C "$repo" commit -qm mutant
    outm="$("$BASH_BIN" "$mutant" "$repo/targetA/retros/r1.md" 2>&1)"
    if grep -q 'staging retro for supervised review' <<<"$outm" \
       && [ "$(branches "$repo")" = "retro/targetA-r1" ]; then
      ok "teeth: guard-neutered mutant fails OPEN and creates retro/* branch" "(case 3 has teeth)"
    else
      no "teeth: guard-neutered mutant fails OPEN and creates retro/* branch" "mutant stayed closed — case 3 is THEATER: branches=[$(branches "$repo")] [$outm]"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
