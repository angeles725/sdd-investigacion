package cli

import (
	"bytes"
	"fmt"
	"io"
	"sort"
)

// Exit codes of the rsdd process contract (research-sdd/toolbelt/json-envelope.v1.md).
const (
	ExitOK          = 0 // any state except degraded; findings are advisory and never change the code
	ExitOperational = 1 // operational failure (unreadable input, internal error)
	ExitUsage       = 2 // usage error: unknown command, bad flags, no arguments
	ExitDegraded    = 3 // degraded: a runtime dependency is missing; stderr carries a DEGRADED: line
)

// Command is one registry entry: `rsdd [<group>] <name>`.
type Command struct {
	Name    string
	Group   string
	Summary string
	Run     func(args []string, s Stdio) int
	// ExitMap optionally translates the code Run returns into the process exit
	// code, for legacy instruments whose contract differs from the default
	// (e.g. verify-state: 1 = stale). Codes absent from the map pass through.
	ExitMap map[int]int
}

// Validate rejects a table that would shadow or cannot dispatch: an empty
// name, a missing Run, a duplicate (group, name), or a group whose name is
// also an ungrouped command.
func Validate(table []Command) error {
	seen := map[[2]string]bool{}
	ungrouped := map[string]bool{}
	for _, c := range table {
		switch {
		case c.Name == "":
			return fmt.Errorf("command with empty name (group %q)", c.Group)
		case c.Run == nil:
			return fmt.Errorf("command %q has no Run", label(c))
		case seen[[2]string{c.Group, c.Name}]:
			return fmt.Errorf("duplicate command %q", label(c))
		}
		seen[[2]string{c.Group, c.Name}] = true
		if c.Group == "" {
			ungrouped[c.Name] = true
		}
	}
	for _, c := range table {
		if c.Group != "" && ungrouped[c.Group] {
			return fmt.Errorf("group %q collides with the ungrouped command of the same name", c.Group)
		}
	}
	return nil
}

// Run dispatches args against table and returns the process exit code.
// `rsdd <name>` runs an ungrouped command; `rsdd <group> <name>` a grouped one.
//
// Contract: a command's stdout is buffered and released only when it returns,
// so a panic discards partial output instead of leaving a fragment that looks
// like a complete result. The panic itself is an operational failure: exit 1
// with the typed stderr line "rsdd: internal-error", never a stack trace.
// A degraded exit (3) always carries a "DEGRADED:" line on stderr.
func Run(table []Command, args []string, s Stdio) int {
	if err := Validate(table); err != nil {
		fmt.Fprintf(s.Err, "rsdd: invalid command table: %v\n", err)
		return ExitOperational
	}
	if len(args) == 0 {
		writeUsage(s.Err, table)
		return ExitUsage
	}
	first := args[0]
	if isHelp(first) {
		writeUsage(s.Out, table)
		return ExitOK
	}
	if cmd, ok := find(table, "", first); ok {
		return exec(cmd, args[1:], s)
	}
	if hasGroup(table, first) {
		if len(args) == 1 {
			writeGroupUsage(s.Err, table, first)
			return ExitUsage
		}
		if isHelp(args[1]) {
			writeGroupUsage(s.Out, table, first)
			return ExitOK
		}
		if cmd, ok := find(table, first, args[1]); ok {
			return exec(cmd, args[2:], s)
		}
		fmt.Fprintf(s.Err, "rsdd: unknown command %q in group %q\nRun 'rsdd %s --help' for the list.\n", args[1], first, first)
		return ExitUsage
	}
	fmt.Fprintf(s.Err, "rsdd: unknown command %q\nRun 'rsdd --help' for the list.\n", first)
	return ExitUsage
}

// exec runs one command behind the panic boundary and the output contract.
func exec(cmd Command, args []string, s Stdio) (code int) {
	var out bytes.Buffer
	errw := &lineTracker{w: s.Err}
	inner := s
	inner.Out, inner.Err = &out, errw
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(s.Err, "rsdd: internal-error: %v\n", r)
			code = ExitOperational
			return
		}
		s.Out.Write(out.Bytes())
		if code == ExitDegraded && !errw.sawDegraded {
			fmt.Fprintln(s.Err, "DEGRADED: command reported a degraded state without a reason")
		}
		if mapped, ok := cmd.ExitMap[code]; ok {
			code = mapped
		}
	}()
	return cmd.Run(args, inner)
}

// lineTracker forwards writes and records whether a "DEGRADED:" line passed.
type lineTracker struct {
	w           io.Writer
	sawDegraded bool
}

func (l *lineTracker) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte("DEGRADED:")) {
		l.sawDegraded = true
	}
	return l.w.Write(p)
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
