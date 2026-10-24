// Package git runs git bounded, through core/proc, and answers the repository questions the status, retro-gate
// and merge-gate instruments ask. The bash has no shared git helper: every call is an inline `git -C <dir> ...`,
// unbounded, with the caller's environment. Runner.Run is that call with a bound (Timeout, then TERM, a grace,
// and KILL of the whole process group) and an output cap; the typed questions are the calls that more than one
// caller asks, or that the ported domain will ask through this package:
//
//	Remotes, RemoteURL  research-sdd-status.sh remote_visibility_block (`git remote`, `git remote get-url`)
//	ResolveCommit       merge-gate.sh (`rev-parse --verify [--quiet] <rev>[^{commit}]`, `cat-file -e
//	                    <rev>^{commit}`) and retro-gate.sh (`rev-parse -q --verify <sha>^{commit}`)
//	MergeBase           merge-gate.sh (`merge-base HEAD <base>`, `merge-base HEAD <pr-base>`)
//	IsAncestor          merge-gate.sh (`merge-base --is-ancestor`)
//	CountRange          merge-gate.sh (`rev-list --count <range>`)
//
// Not given a typed helper (one caller each, and their parsing moves with that instrument's port, which calls
// Runner.Run): merge-gate's `rev-parse --git-dir`, `ls-tree --name-only` and `show <tree>:<path>`; retro-gate's
// `diff --cached --relative --name-only [--diff-filter=A -M]`, `ls-files -s -z`, `ls-files -o
// --exclude-standard -z` and `ls-files --others`. The other retro scripts (stage-retro, sweep-retros,
// stage-retro-issues) branch, fetch and read history in ways no status/retro-gate/merge-gate path shares; they
// are ported with their own units.
//
// Errors are typed: ErrMissing (git not found), ErrTimeout and ErrOutputCap (the run was stopped), and
// *ExitError for a non-zero exit, whose Code is the shell's (128+N for signal N). A question whose "no" is an
// exit status (exit 1 of rev-parse --verify --quiet, merge-base, merge-base --is-ancestor) answers it as a value
// instead of an error, so a caller can tell "no" from "could not ask".
//
// Differences, by design: every run is bounded (the bash never bounds git); stdin is /dev/null; the caller's
// environment is passed whole (Runner.Env), as the bash inherits it, and nothing is read from the process.
package git
