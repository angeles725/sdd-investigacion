package consumers

// Every string the command prints is here, apart from the limits (limits.go) and the help text (help.txt).
const (
	usageLine = "usage: rsdd maint consumers [--repo DIR]\n"

	reportRepository = "consumers: repository %s\n"
	reportKit        = "kit: %s/research-sdd\n"
	reportFiles      = "files: %d listed (tracked, and untracked but not ignored)\n"
	reportScripts    = "scripts: %d (%s)\n"
	reportAmbiguous  = "ambiguous basenames: %d (%s)\n"
	reportNoAmbig    = "ambiguous basenames: none\n"
	reportExcluded   = "excluded from the script list: %s\n"
	reportGoClasses  = "Go classes: not enumerated by this version (production code, tests, generated, assembled, embedded).\n"
	reportLimitsHead = "limits:\n"

	stateDegradedOut = "consumers: degraded\n"
	stateNoGit       = "DEGRADED: git is not installed; nothing was counted\n"
	stateNoWorkTree  = "DEGRADED: %s is not inside a git work tree; nothing was counted\n"
	stateAbsent      = "consumers: absent-input: no file under research-sdd/toolbelt/, research-sdd/templates/ or research-sdd/install/ in %s\n"
	stateEmpty       = "consumers: empty-input: %d files under research-sdd/toolbelt/, research-sdd/templates/ and research-sdd/install/, none is a live script (excluded from the script list: %s)\n"
	stateListFailed  = "consumers: error: git ls-files failed (exit code %d) in %s\n"
	stateListStderr  = "DEGRADED: git ls-files wrote to stderr, so the file list may be incomplete: %s (and %d more stderr lines); nothing was counted\n"
	stateRepoNotDir  = "consumers: absent-input: --repo %s is not a directory (missing, a file, or unreachable)\n"
	stateGitTimeout  = "consumers: error: git %s timed out after %v in %s\n"
	stateGitCap      = "consumers: error: git %s produced more than %d bytes of output in %s\n"
	stateGitFailed   = "consumers: error: git %s could not run: %v (in %s)\n"
	usageProblem     = "consumers: %s\n"
)
