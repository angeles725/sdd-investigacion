package cli

// Exit codes of the rsdd process contract (json-envelope.v1.md).
const (
	ExitOK       = 0 // ran, nothing to report or advisory output only
	ExitFindings = 1 // ran, findings reported
	ExitCannot   = 2 // could not run: usage error, unknown command, internal error
	ExitDegraded = 3 // degraded: ran with a typed envelope, result is not a zero
)

// Command is one registry entry: `rsdd [<group>] <name>`.
type Command struct {
	Name    string
	Group   string
	Summary string
	Run     func(args []string, s Stdio) int
}

// Run dispatches args against table. Skeleton: behaviour lands test-first.
func Run(table []Command, args []string, s Stdio) int {
	return ExitCannot
}
