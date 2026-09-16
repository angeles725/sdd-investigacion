# Design: Improve Research-SDD Target Onboarding

## Technical Approach

Text-only edit of the `# --- report ---` block in `research-sdd-init.sh` (lines 139-159),
plus new stdout assertions in `research-sdd-init.test.sh`. No control flow, no git
introspection, no corpus writes — only `echo` wording and one `if/else` reshape. Implements
proposal items 1-3 and the `init-onboarding-report` capability. Strict TDD: RED assertions on
report text first, then amend the echoes, then prove teeth by mutating each new echo.

## Architecture Decisions

### Decision: Keep the numbered follow-up scheme; add advisory cross-refs (approach A+D)
**Choice**: Append `(PROMPT-LOOP §b)`/`(§e)`/`(§c follow-up)` to steps 1/3/4, matching step
2's existing `(PROMPT-LOOP §b/§b2)` style. Do NOT switch to PROMPT-LOOP letter labels and do
NOT reorder to match PROMPT-LOOP's b/b2-before-c sequence.
**Alternatives**: (B) letter labels — rejected: labels arrive out of order and `c` collides
with the scaffold step; (C) note only in PROMPT-LOOP.md — rejected: lives in a doc, not at the
operator's terminal, and PROMPT-LOOP.md is frozen out of scope.
**Rationale**: Minimal delta, one-directional refs (init → doc), no parallel-session overlap.
The b/b2 order tension is acknowledged as pre-existing and left as a pointer, not papered over.

### Decision: Make conditional step 5 transparent via an explicit else-branch
**Choice**: Line 158 becomes an `if [ -n "$prefix" ]; then <step 5> else <note> fi`, so a
no-prefix run prints a note that step 5 is skipped for want of `--prefix`.
**Rationale**: §7 anti-silent-zero at the UX layer — "complete" must be distinguishable from
"step silently skipped". The note proves the omission was intentional.

### Decision: Item 2 is a factual wording split, not runtime detection
**Choice**: Split the already-git branch into two echoes: untracked corpus files vs the
gitignored `.claude/` hook (`git add --force`, or leave ignored). No `git check-ignore`.
**Rationale**: init itself appends `.claude/` to `.gitignore` (line 116) and lands the hook
under `.claude/` (line 108), so the fact is statically known. Adding introspection would be
out-of-scope runtime cost for a known-true statement.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `research-sdd/toolbelt/research-sdd-init.sh` | Modify | Report block lines 146-159, all 3 items (~≤15 lines) |
| `research-sdd/toolbelt/tests/research-sdd-init.test.sh` | Modify | New stdout assertions + already-git fixture + 4 teeth mutants (~≤25 lines) |

## Exact before → after (init.sh)

**Item 2 — git branch (146-147):** replace the `&& … || …` idiom with an if/else:
```
if [ "$git_did_init" = 1 ]; then
  echo "  git    : initialized a new repo in the target"
else
  echo "  git    : target is ALREADY under git — corpus files land untracked (git add as needed)"
  echo "           the .claude/ hook is gitignored (init appended .claude/ to .gitignore) — git add --force to track it, or leave it ignored"
fi
```

**Item 1 — steps 1/3/4 cross-refs (151, 154, 155):**
- 151 `…wrapper·language)` → `…wrapper·language) (PROMPT-LOOP §b)`
- 154 `…(audit-first for a mature corpus).` → `…(audit-first for a mature corpus) (§e).`
- 155 `4. REGISTER + ADAPT the hook:` → `4. REGISTER + ADAPT the hook (§c follow-up):`

**Item 1 — step-5 conditional (158):**
```
if [ -n "$prefix" ]; then echo "  5. Block files use the prefix: ${prefix}-blockN.md"
else echo "  (no --prefix given — step 5, block-file prefix, is skipped; pass --prefix to enable it)"; fi
```

**Item 3 — before `== done ==` (159):**
```
echo
echo "NEXT: run $KIT/toolbelt/research-sdd-status.sh $target — it reports BOOTSTRAP until the follow-ups above are done."
echo "  mental model: you now have a VALID-but-EMPTY corpus; the JUDGMENT follow-ups turn it into a real research target."
echo "== done =="
```

## Testing Strategy

Capture stdout: `bash "$SUT" "$d" … >"$d/.out" 2>/dev/null`, then `assert_grep` against `.out`.

| Item | Assertions | Fixture |
|------|-----------|---------|
| 1 | no-prefix run: `(PROMPT-LOOP §b)`, `(§e)`, `(§c follow-up)` present; `no --prefix given` note present; `5. Block files use the prefix` ABSENT. `--prefix foo` run: `5. Block files use the prefix: foo-blockN.md` present; no-prefix note ABSENT | reuse empty `$TMP` flat target |
| 2 | already-git run: `corpus files land untracked`, `.claude/ hook is gitignored`, `git add --force` all present | new `$TMP/already-git` dir with `git -C "$d" init -q` before running init |
| 3 | any run: `NEXT:`, `research-sdd-status.sh`, `mental model` present | reuse a flat target |

Fixture note: the already-git fixture is a dynamic `git init` in `$TMP` (the suite's convention
for stateful fixtures); `tests/fixtures/` stays reserved for static template trees. Never git-init
a live target.

Teeth (`--prove-teeth`, one awk-mutant per item, matching the existing negative-control pattern):
- M1: strip `(PROMPT-LOOP §b)` from step 1 → item-1 step-1 grep must go absent.
- M2: force `else` off / always print step 5 → no-prefix "step-5 ABSENT" assertion must flip.
- M3: revert the git else-branch to the old single `land as untracked` line → item-2 `--force`/`gitignored` greps must go absent.
- M4: delete the `NEXT:` echo → item-3 grep must go absent.
Each mutant proves its assertion bites; report lines use the runner's `  FAIL  ` prefix.

## Threat Matrix

N/A — no routing, subprocess spawn, VCS/PR automation, executable-file classification, or
process-integration boundary is added. The change is `echo` wording only; item 2 explicitly adds
no `git check-ignore` or other runtime git call.

## Migration / Rollout

No migration. Single-PR two-file change; `git revert` restores prior wording + suite.

## Open Questions

None — all four explore questions resolved by the proposal (one-directional refs, no renumber,
split git message, next-step before `== done ==`).
