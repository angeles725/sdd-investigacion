package consumers

// The strings of the class table and of the lines around it.
const (
	rowFormat    = "%-25s %8s  %8s  %8s  %10s  %9s\n"
	rowHeadClass = "class"
	rowHeadFiles = "files"
	rowHeadWith  = "with-ref"
	rowHeadPairs = "pairs"
	rowHeadRefs  = "references"
	rowHeadSelf  = "self-only"
	wordNoFiles  = "no files"
	wordNoneRead = "none read"
	wordNoMatch  = "no-match"
	wordNone     = "none"
	wordNA       = "n/a"

	unclassifiedHead   = "unclassified files with a reference:\n"
	unclassifiedLine   = "  %s %d\n"
	unclassifiedNoFile = "unclassified files with a reference: no files\n"
	unclassifiedNoRef  = "unclassified files with a reference: no-match\n"

	notReadLine = "not read: fixtures %d, Go module %d, binary %d, not regular %d (read %d of %d listed)\n"

	scriptLive    = "script: %s (live)\n"
	scriptNotLive = "script: %s (not live)\n"

	errCannotRead = "consumers: error: cannot read %s: %s\n"

	refsLine       = "%s\t%s\t%s\t%d\n"
	refsNoMatch    = "consumers: no-match: no file names a live script\n"
	refsNoMatchOne = "consumers: no-match: no file names %s\n"
	refsNotLive    = "consumers: script %s is not live\n"
)
