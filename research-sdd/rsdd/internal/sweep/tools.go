package sweep

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Port of research-sdd/toolbelt/sweep-tools.sh (kit issue #2361) and, in toolshook.go, of sweep-tools-hook.sh:
//
//	rsdd sweep tools [--kit <dir>]          the census
//	rsdd sweep tools --hook [--kit <dir>]   the SessionStart hook
//
// The census is read-only: for every target in the kit's TARGETS.md it counts the tools under <target>/tools
// (toolsfs.go), how many are RECORDED in a T-row of a retro or in the ledger tools/README.md and how many are
// UNRECORDED (toolsledger.go). The shim passes the kit it lives in as --kit; run directly, the kit is resolved
// like templates/hook-kit-run.sh does. Like the script, every argument other than the flags named above is
// ignored, and the census exits 0 for any finding (1 only when it could not start).
//
// The three states a zero can hide stay distinct (CLAUDE.md section 7): a target directory that is missing is
// "absent-input", a tools/ that is missing or holds no file is "empty-input", and a tools/ whose files are all
// recorded is a count with no unrecorded.
//
// Declared differences from the script, each pinned by a test (L4 of odd/tasks/sweep-tools-go.md):
//
//   - The bash lib it sourced (target-paths) is core/kit, so the "cannot find helper" and "failed to define"
//     exits (case 10 of the old suite) have no equivalent.
//   - The dependency-directory exclusion (node_modules, __pycache__, .venv, .git) is judged on the path below
//     tools/; the script matched the whole path, so a target living under a .venv/ read as having no tools.
//   - A tools/ that is a symbolic link to a directory is followed; the script's find read it as empty.
//   - A tool name is matched as a literal against the T-rows and the ledger: the script handed it to grep as
//     an option (-F, a name that starts with a dash) and as a regex with only the dot escaped (a+b.sh).
//   - A file that cannot be read is the same state as for grep exiting 2 (a WARN, never a zero); a file
//     with a NUL byte is read as grep reads it: its lines match nothing.
//   - The grep stubs of the old cases 18-19b have no equivalent: the read seam (readFunc) replaces them.

// RunTools is the `sweep tools` command.
func RunTools(args []string, s cli.Stdio) int {
	o, err := parseOptions(args)
	if err != nil {
		fmt.Fprintf(s.Err, "sweep-tools: %v\n", err)
		return cli.ExitUsage
	}
	if o.hook {
		return runToolsHook(o, s, os.ReadFile)
	}
	return sweepTools(o, s, s.Out, s.Err, os.ReadFile)
}

// resolveToolsKit is resolveKit for a run without --kit: the kit of toolbelt/sweep-tools.sh.
func resolveToolsKit(o options, s cli.Stdio) (string, error) {
	if o.kit == "" {
		script, _, err := kit.ResolveKitScript("toolbelt/sweep-tools.sh", s.Env)
		if err != nil {
			return "", err
		}
		o.kit = filepath.Dir(filepath.Dir(script))
	}
	return resolveKit(o, s)
}

// toolsTotals are the counters of one census, as the summary prints them.
type toolsTotals struct {
	tools, retro, ledger, unrecorded int
	targets, absent                  int
	skipped                          int
	skippedNames                     string
}

// sweepTools runs the census, writing the report to out and the diagnostics to errw. It returns the exit code.
func sweepTools(o options, s cli.Stdio, out, errw io.Writer, read readFunc) int {
	kitDir, err := resolveToolsKit(o, s)
	if err != nil {
		fmt.Fprintf(errw, "sweep-tools: %v\n", err)
		return cli.ExitOperational
	}
	list, err := readTargetList("sweep-tools", kitDir, kit.Getenv(s.Env))
	if err != nil {
		var te *targetsError
		if errors.As(err, &te) {
			te.printTo(errw)
		}
		return cli.ExitOperational
	}
	var t toolsTotals
	t.skipped, t.skippedNames = auditSkipped(list.skipped) // the same `for s in $skipped` naming as the audit sweep
	for _, p := range list.words() {
		if !isDirectory(p) {
			fmt.Fprintf(out, "INFO: corpus not found (absent-input): %s\n", p)
			t.absent++
			continue
		}
		t.targets++
		censusTarget(out, p, read, &t)
	}
	fmt.Fprintf(out, "\nSummary: %d tool(s) across %d target(s) · %d recorded (retro) · %d recorded (ledger) · %d unrecorded.\n",
		t.tools, t.targets, t.retro, t.ledger, t.unrecorded)
	if t.absent > 0 {
		fmt.Fprintf(out, "INFO: %d target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n", t.absent)
	}
	if t.skipped > 0 {
		fmt.Fprintf(out, "WARN: %d target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: %s\n", t.skipped, t.skippedNames)
	}
	return cli.ExitOK
}

// censusTarget prints the block of one target and adds it to the totals.
func censusTarget(out io.Writer, p string, read readFunc, t *toolsTotals) {
	name := filepath.Base(p)
	tdir := p + "/tools"
	fmt.Fprintf(out, "TARGET  %s\n", name)
	if !isDirectory(tdir) {
		fmt.Fprintf(out, "        INFO: no tools/ directory (empty-input)\n")
		return
	}
	root, files := toolsFiles(tdir)
	if len(files) == 0 {
		fmt.Fprintf(out, "        INFO: tools/ directory exists but is empty (empty-input)\n")
		return
	}
	var tools []string
	libs, rejects := 0, 0
	for _, f := range files {
		switch {
		case !isToolFile(f):
			rejects++
		case isLibModule(f, root):
			libs++
		default:
			tools = append(tools, f)
		}
	}

	rows, found, withTable, unreadable := retroRows(p, read)
	if unreadable > 0 {
		fmt.Fprintf(out, "   WARN: %d retro(s) unreadable during T-row scan (grep error)\n", unreadable)
	}
	state, lrows := readLedger(tdir+"/README.md", read)

	retro, ledger, unrecorded := 0, 0, 0
	for _, f := range tools {
		base := filepath.Base(f)
		switch {
		case inTRows(rows, base):
			retro++
		case state == ledgerParsed && inLedger(lrows, base):
			ledger++
		default:
			unrecorded++
		}
	}
	t.tools += len(tools)
	t.retro += retro
	t.ledger += ledger
	t.unrecorded += unrecorded

	fmt.Fprintf(out, "        tools: %d found", len(tools))
	if libs > 0 {
		fmt.Fprintf(out, " (%d library module(s) not counted as tools)", libs)
	}
	if rejects > 0 {
		fmt.Fprintf(out, " (%d non-tool file(s) in tools/ not counted)", rejects)
	}
	fmt.Fprintf(out, "\n")
	switch state {
	case ledgerError:
		fmt.Fprintf(out, "        WARN: tools/README.md scan FAILED (grep error) — ledger count unavailable\n")
	case ledgerNoTable:
		fmt.Fprintf(out, "        WARN: tools/README.md has no table — ledger unreadable\n")
	}
	if state == ledgerError || state == ledgerNoTable {
		fmt.Fprintf(out, "        recorded (retro): %d  ·  unrecorded: %d", retro, unrecorded)
	} else {
		fmt.Fprintf(out, "        recorded (retro): %d  ·  recorded (ledger): %d  ·  unrecorded: %d", retro, ledger, unrecorded)
	}
	switch {
	case found == 0:
		fmt.Fprintf(out, "  ·  no retros found")
	case withTable == 0:
		fmt.Fprintf(out, "  ·  no retro has a tools table")
	}
	fmt.Fprintf(out, "\n")
}

// retroRows collects the T-rows of every retro of the target (the retro walk of sweep-retros.sh, index files
// skipped): the rows, how many retros were found, how many held a T-row and how many could not be read.
func retroRows(p string, read readFunc) (rows []string, found, withTable, unreadable int) {
	for _, rf := range findRetros(p, true) {
		found++
		data, err := read(rf)
		if err != nil {
			unreadable++
			continue
		}
		if r := retroTRows(data); len(r) > 0 {
			withTable++
			rows = append(rows, r...)
		}
	}
	return rows, found, withTable, unreadable
}

// readLedger is the ledger tools/README.md: its state and its rows. Only a regular file is a ledger.
func readLedger(path string, read readFunc) (ledgerState, []string) {
	if st, err := os.Stat(path); err != nil || !st.Mode().IsRegular() {
		return ledgerNone, nil
	}
	data, err := read(path)
	if err != nil {
		return ledgerError, nil
	}
	rows := ledgerRows(data)
	if len(rows) == 0 {
		return ledgerNoTable, nil
	}
	return ledgerParsed, rows
}
