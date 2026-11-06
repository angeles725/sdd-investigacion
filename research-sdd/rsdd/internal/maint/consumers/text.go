package consumers

// Every string the command prints is here, apart from the limits (limits.go) and the help text (help.txt).
const (
	usageLine = "usage: rsdd maint consumers [--repo DIR] [--refs] [--script NAME]\n"

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
	usageProblem     = "consumers: %s\n"
)
