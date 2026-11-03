package sweep

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// btMarker is the marker line of the standard tagged test block; it sits on line 7.
const (
	btMarker     = "> **Breakthrough:** the technique that cracked it — details here.\n"
	btMarkerLine = 7
)

// btBlockText is the standard test block: seven header lines, the marker on the last when tagged.
func btBlockText(tagged bool) string {
	s := "# Block 1\n\n> Research of **module**: scope.\n>\n> Sources: file. Method: reading.\n>\n"
	if tagged {
		return s + btMarker + "\n---\n\n## 1.1 — Section\n\nContent.\n"
	}
	return s + "> Plain header line.\n\n---\n\n## 1.1 — Section\n\nContent.\n"
}

// block writes <dir>/<name> and returns the line of its marker (0 when untagged).
func (w *world) block(dir, name string, tagged bool) int {
	w.t.Helper()
	w.put(dir+"/"+name, btBlockText(tagged))
	if tagged {
		return btMarkerLine
	}
	return 0
}

// btLedger writes <kit>/BREAKTHROUGHS.md: the header, the separator, the skeleton row and the given rows.
func (w *world) btLedger(rows ...string) {
	w.t.Helper()
	var b strings.Builder
	b.WriteString("# Research-SDD — Breakthrough Ledger\n\n")
	b.WriteString("| # | target | what (cracked) | how — block `path:line` | memory — engram topic-key |\n")
	b.WriteString("|---|--------|----------------|-------------------------|---------------------------|\n")
	b.WriteString("| — | _(no entries yet)_ | | | |\n")
	for _, r := range rows {
		b.WriteString(r + "\n")
	}
	w.put(w.kit+"/BREAKTHROUGHS.md", b.String())
}

// btRow is one ledger row whose "how" cell holds the given tokens.
func btRow(how ...string) string {
	return "| 1 | tgt | what | " + strings.Join(how, " ; ") + " | key |"
}

// ptr is the backtick-wrapped path:line token of a ledger cell.
func ptr(path string, line int) string { return fmt.Sprintf("`%s:%d`", path, line) }

// runBT runs `rsdd sweep breakthroughs --kit <kit> <args>` in process.
func (w *world) runBT(args ...string) result {
	w.t.Helper()
	return w.runBTCmd(false, args)
}

// runBTHook runs `rsdd sweep breakthroughs --hook`.
func (w *world) runBTHook(args ...string) result {
	w.t.Helper()
	return w.runBTCmd(true, args)
}

// runBTCmd goes through the command table, except for a world with unreadable files, which has to hand its
// reader to the sweep: the table only knows os.ReadFile.
func (w *world) runBTCmd(hook bool, args []string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	argv := []string{"sweep", "breakthroughs", "--kit", w.kit}
	if hook {
		argv = append(argv, "--hook")
	}
	argv = append(argv, args...)
	if len(w.unreadablePaths()) == 0 {
		rc := cli.Run(Commands, argv, w.stdio(&o, &e))
		return result{o.String(), e.String(), rc}
	}
	opts, err := parseOptions(argv[2:])
	w.must(err)
	var rc int
	if hook {
		rc = runBreakthroughsHook(opts, w.stdio(&o, &e), w.readFile())
	} else {
		rc = sweepBreakthroughs(opts, w.stdio(&o, &e), &o, &e, w.readFile())
	}
	return result{o.String(), e.String(), rc}
}
