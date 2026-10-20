package cli

import (
	"fmt"
	"io"
	"sort"
)

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

// Run dispatches args against table and returns the process exit code.
// `rsdd <name>` runs an ungrouped command; `rsdd <group> <name>` a grouped one.
// A panic inside a command is recovered and reported as
// "degraded: internal-error" with exit 2 - never exit 0, never a stack trace.
func Run(table []Command, args []string, s Stdio) (code int) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(s.Err, "degraded: internal-error: %v\n", r)
			code = ExitCannot
		}
	}()

	if len(args) == 0 {
		writeUsage(s.Err, table)
		return ExitCannot
	}
	first := args[0]
	if isHelp(first) {
		writeUsage(s.Out, table)
		return ExitOK
	}
	if cmd, ok := find(table, "", first); ok {
		return cmd.Run(args[1:], s)
	}
	if hasGroup(table, first) {
		if len(args) == 1 || isHelp(args[1]) {
			if len(args) == 1 {
				writeGroupUsage(s.Err, table, first)
				return ExitCannot
			}
			writeGroupUsage(s.Out, table, first)
			return ExitOK
		}
		if cmd, ok := find(table, first, args[1]); ok {
			return cmd.Run(args[2:], s)
		}
		fmt.Fprintf(s.Err, "rsdd: unknown command %q in group %q\nRun 'rsdd %s --help' for the list.\n", args[1], first, first)
		return ExitCannot
	}
	fmt.Fprintf(s.Err, "rsdd: unknown command %q\nRun 'rsdd --help' for the list.\n", first)
	return ExitCannot
}

func isHelp(a string) bool { return a == "--help" || a == "-h" || a == "help" }

func find(table []Command, group, name string) (Command, bool) {
	for _, c := range table {
		if c.Group == group && c.Name == name {
			return c, true
		}
	}
	return Command{}, false
}

func hasGroup(table []Command, group string) bool {
	for _, c := range table {
		if c.Group == group && group != "" {
			return true
		}
	}
	return false
}

func writeUsage(w io.Writer, table []Command) {
	fmt.Fprint(w, "Usage:\n  rsdd <command> [args]\n  rsdd <group> <command> [args]\n\nCommands:\n")
	sorted := append([]Command(nil), table...)
	sort.SliceStable(sorted, func(i, j int) bool { return label(sorted[i]) < label(sorted[j]) })
	for _, c := range sorted {
		fmt.Fprintf(w, "  %-24s %s\n", label(c), c.Summary)
	}
}

func writeGroupUsage(w io.Writer, table []Command, group string) {
	fmt.Fprintf(w, "Usage:\n  rsdd %s <command> [args]\n\nCommands:\n", group)
	var in []Command
	for _, c := range table {
		if c.Group == group {
			in = append(in, c)
		}
	}
	sort.SliceStable(in, func(i, j int) bool { return in[i].Name < in[j].Name })
	for _, c := range in {
		fmt.Fprintf(w, "  %-24s %s\n", c.Name, c.Summary)
	}
}

func label(c Command) string {
	if c.Group == "" {
		return c.Name
	}
	return c.Group + " " + c.Name
}
