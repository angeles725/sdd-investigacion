// Package stage is the Go port of toolbelt/stage-retro.sh (`rsdd retro stage`, kit issue #2663): it stages ONE
// pending §18 retro as a branch of the kit repo for supervised review. The supervisor, not the target run, runs it:
// the branch isolates each proposal so conflicts, duplication and necessity are judged before merge. It does the
// git plumbing only (create the branch from origin/main, print the deltas and the next steps); applying a delta
// is the supervisor's judgment and nothing here edits kit prose, commits, pushes or opens a PR.
//
// Usage: rsdd retro stage [--toolbelt DIR] <retro.md> [--force]
//
// Exit codes (unchanged where a caller can depend on them): 0 staged; 1 usage, an unreadable retro or an unknown
// option; 2 the retro opts out (`<!-- kit-retro: exclude -->`) or is already applied|dismissed (and no --force);
// 3 the kit repo has uncommitted changes; 4 git cannot report the state of the kit repo; 5 the branch cannot be
// created or checked out (or its name is not a valid ref); 6 `git fetch origin` failed; 7 the retro lives in the
// kit repo itself and origin/main does not hold the same content; 8 the retro is unreadable on the branch after
// the checkout.
//
// The marker logic comes from core/retrogrammar (the review-status marker and the kit-retro opt-out), the target
// label from core/kit (the nearest registered ancestor of TARGETS.md, the same name stage-retro-issues and
// reconcile use) and every git call from core/git, bounded and with the caller's environment.
//
// Every observable of the script is kept (stdout and stderr byte for byte, the exit codes, and the git side
// effects: the new branch, its base, no upstream, the checkout it leaves) except the intended divergences below;
// the frozen script is the oracle of the differential test, and the divergences are pinned in divergence_test.go
// and documented in tool-registry.d/stage-retro.md.
//
// Intended divergences from the script:
//   - The kit checkout is not switched to main first. The script ran `git checkout -q main` before anything
//     else, which moved a shared checkout for nothing (the branch is created from origin/main) and failed with
//     exit 4 when main was held by another worktree. The port starts from where it is, and on exit 8 returns
//     there (a branch name, or the commit when detached) instead of to main. The self-referential guard compares
//     the branch `main` with origin/main, as it did once the script had switched to it.
//   - A branch name git refuses (`a..b.md`, `x.lock.md`) is refused before the fetch and before any change,
//     exit 5; an empty slug (a file name with no ASCII letters) is `retro-<8 hex of the name's SHA-256>`.
//   - A word after the retro that is not --force is refused (exit 1) instead of ignored; staging a retro that is
//     already applied|dismissed with --force says so instead of printing "Use --force".
//   - A section that runs to the end of the file keeps its last line (the script's `sed '$d'` dropped it), and a
//     retro with no `## Proposed kit deltas` section warns on stderr instead of printing nothing.
//   - A kit root that is not a git repository, or git missing, is exit 4 with a typed degraded line (the script
//     read it as a clean tree); `git fetch origin` is bounded (120 s); an unreadable retro is refused before any
//     git call (the script created the branch and failed after the checkout).
//   - A single quote in the target label or the retro's file name is escaped in the suggested commands.
//   - The "cannot find helper" and "failed to define" exits are shell wiring: the grammar and the registry reader
//     are linked in, so they cannot happen. The shim reports a missing rsdd binary instead.
package stage
