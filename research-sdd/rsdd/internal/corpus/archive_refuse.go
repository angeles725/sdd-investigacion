package corpus

import (
	"os"
	"path/filepath"
	"strings"
)

// archiveRefusal prints the REFUSED block (exit 3). The git-state classification mirrors the one the secrets gate used,
// including the ambiguous-failure case, so the hint never names a command the gate did not run.
func (e *archiveEnv) archiveRefusal() int {
	e.say("  REFUSED: reconcile the failing gate(s) before archiving. Run for detail:")
	e.say("    %s/verify-state.sh %s", e.here, e.corpus)
	e.say("    %s/verify-sources.sh %s", e.here, e.corpus)
	e.say("    %s/verify-corrections.sh %s", e.here, e.corpus)
	if !e.archiveHaveGit() {
		e.say("    git probe failed — fix git first (git not found on PATH)")
		return 3
	}
	topOut, topRC := e.archiveGitCombined(e.target, "rev-parse", "--show-toplevel")
	topOut = archiveCmdSub(topOut)
	topPhys := ""
	if topRC == 0 {
		topPhys = e.archivePhysOf(topOut)
	}
	if e.ssPhys == "" { // SS-UNRESOLVABLE-HINT
		e.say("    target unresolvable — cd -P failed on %s, so the scan command cannot be printed; fix the path/permissions first", e.target)
	} else {
		utf := archiveUTF8Locale(e.s.Env)
		qPhys, qHere, qTarget := archiveQuote(e.ssPhys, utf), archiveQuote(e.here, utf), archiveQuote(e.target, utf)
		hintWT := "find " + qPhys + " \\( -name .git -type d \\) -prune -o -type f -print0 | " + qHere + "/scan-secrets.sh --files-from - " + qPhys
		_, dotGitErr := os.Stat(filepath.Join(e.target, ".git"))
		switch {
		case topRC == 0 && topPhys == e.ssPhys:
			e.say("    %s   # working tree (dirty/untracked/ignored — file scope: *.md + config)", hintWT)
			e.say("    %s/scan-secrets.sh --committed %s   # + committed history", qHere, qTarget)
		case topRC == 0:
			e.say("    %s   # working tree only — target is nested inside %s", hintWT, archiveQuote(topOut, utf))
		case strings.Contains(strings.ToLower(topOut), "not a git repository") && dotGitErr != nil:
			e.say("    %s", hintWT)
		default:
			e.say("    git probe failed — fix git first")
		}
	}
	if e.ssLeakWT { // SS-REMEDY-HINT
		e.say("    A secret in a git-ignored file still refuses (the gate reads the working tree as it sits on disk): move the")
		e.say("    secret store OUTSIDE the target directory and keep only its path/structure in the corpus. There is no override.")
	}
	if e.ssLeakHist { // SS-HIST-HINT
		e.say("    A secret in committed history is not fixed by editing the tree: the history must be rewritten (e.g. git filter-repo),")
		e.say("    then rotate the credential. ensure-remote.sh refuses the same way.")
	}
	return 3
}
