package sweep

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Port of research-sdd/toolbelt/sweep-breakthroughs.sh (kit issue #2360) and, in breakthroughshook.go, of
// sweep-breakthroughs-hook.sh:
//
//	rsdd sweep breakthroughs [--kit <dir>]                   the Breakthrough Ledger check (METHODOLOGY section 22)
//	rsdd sweep breakthroughs --hook [--kit <dir>] [--full]   the SessionStart hook
//
// The sweep is read-only: for every target in the kit's TARGETS.md it finds the blocks that carry the
// **Breakthrough:** marker (breakthroughsmarker.go), cross-checks them against the pointers of the kit's
// BREAKTHROUGHS.md (breakthroughsledger.go) and WARNs on a tagged block the ledger does not index and on a
// ledger pointer whose block no longer carries the marker. A finding never fails the run: it exits 1 only when
// it could not start. The shim passes the kit it lives in as --kit; run directly, the kit is resolved like
// templates/hook-kit-run.sh does. Like the script, every argument other than the flags named above is ignored.
//
// The three states a zero can hide stay distinct (CLAUDE.md section 7): a target directory that is missing is
// "absent-input", one with no block file is "empty-input", and one whose block files carry no marker is
// "no-match". A block whose marker scan failed is a fourth, typed WARN, never a zero.
//
// Declared differences from the script, each pinned by a test (the table is tool-registry.d/sweep-breakthroughs.md):
//
//   - The bash libs it sourced (target-paths, block-files) are core/kit, so the "cannot find helper" and
//     "failed to define" exits (case 10 of the old suite) have no equivalent.
//   - A BREAKTHROUGHS.md that cannot be read stops the run (exit 1); the script's grep failed silently, so every
//     tagged block read as unindexed and the ledger as empty.
//   - A target that is a symbolic link to a directory is traversed; the script's find listed the link alone and
//     the corpus read as empty-input.
//   - A ledger pointer is matched on its line NUMBER: file:07 indexes a marker on line 7 (the script compared the
//     text, so it reported a block it had just verified in the drift pass as unindexed).
//   - A block file with a NUL byte or invalid UTF-8 is scanned line by line like any other; grep printed a
//     "Binary file matches" line, which the WARN then used as a line number.
//   - A ledger pointer to a file that cannot be read is a typed WARN (counted as skipped-unreadable once per
//     file); the script reported it as a block that lost its marker.
//   - Block files sort bytewise (C collation); the script's `sort` used the caller's locale.
//   - A target path with whitespace is split into words and a glob in it is not expanded (as the other sweeps).
//   - Only ASCII whitespace is whitespace (the marker's [[:space:]] and the ledger cell trim).

// RunBreakthroughs is the `sweep breakthroughs` command.
func RunBreakthroughs(args []string, s cli.Stdio) int {
	o, err := parseOptions(args)
	if err != nil {
		return usageFailure(s, o, "breakthroughs", btHookFailedFmt, err)
	}
	if o.hook {
		return runBreakthroughsHook(o, s, os.ReadFile)
	}
	return sweepBreakthroughs(o, s, s.Out, s.Err, os.ReadFile)
}

// resolveBreakthroughsKit is resolveKit for a run without --kit: the kit of toolbelt/sweep-breakthroughs.sh.
func resolveBreakthroughsKit(o options, s cli.Stdio) (string, error) {
	if o.kit == "" {
		script, _, err := kit.ResolveKitScript("toolbelt/sweep-breakthroughs.sh", s.Env)
		if err != nil {
			return "", err
		}
		o.kit = filepath.Dir(filepath.Dir(script))
	}
	return resolveKit(o, s)
}

// isRegularFile is `[ -f p ]`: a regular file, or a symbolic link to one.
func isRegularFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// btTotals are the counters of one sweep, as the summary prints them.
type btTotals struct {
	tagged, unindexed, drift, unreadable, absent int
	skipped                                      int
	skippedNames                                 string
	unreadableSeen                               map[string]bool
}

// markUnreadable counts a block file whose marker scan failed, once per file.
func (t *btTotals) markUnreadable(f string) {
	if t.unreadableSeen[f] {
		return
	}
	if t.unreadableSeen == nil {
		t.unreadableSeen = map[string]bool{}
	}
	t.unreadableSeen[f] = true
	t.unreadable++
}

// sweepBreakthroughs runs the check, writing the report to out and the diagnostics to errw. It returns the
// exit code.
func sweepBreakthroughs(o options, s cli.Stdio, out, errw io.Writer, read readFunc) int {
	kitDir, err := resolveBreakthroughsKit(o, s)
	if err != nil {
		fmt.Fprintf(errw, "sweep-breakthroughs: %v\n", err)
		return cli.ExitOperational
	}
	// The order of the script: TARGETS.md, then BREAKTHROUGHS.md, then the paths TARGETS.md holds.
	if md := kitDir + "/TARGETS.md"; !isRegularFile(md) {
		fmt.Fprintf(errw, "sweep-breakthroughs: cannot find %s\n", md)
		return cli.ExitOperational
	}
	ledgerPath := kitDir + "/BREAKTHROUGHS.md"
	if !isRegularFile(ledgerPath) {
		fmt.Fprintf(errw, "sweep-breakthroughs: cannot find %s\n", ledgerPath)
		return cli.ExitOperational
	}
	list, err := readTargetList("sweep-breakthroughs", kitDir, kit.Getenv(s.Env))
	if err != nil {
		if te, ok := err.(*targetsError); ok {
			te.printTo(errw)
		}
		return cli.ExitOperational
	}
	data, err := read(ledgerPath)
	if err != nil {
		fmt.Fprintf(errw, "sweep-breakthroughs: cannot read %s\n", ledgerPath)
		return cli.ExitOperational
	}
	pointers := ledgerPointers(data, researchHomeOf(kit.Getenv(s.Env)))

	var t btTotals
	t.skipped, t.skippedNames = auditSkipped(list.skipped)
	index := newPointerIndex(pointers)
	for _, p := range list.words() {
		scanCorpus(out, p, index, read, &t)
	}
	driftPass(out, s.Cwd, pointers, read, &t)
	writeBreakthroughsSummary(out, t)
	return cli.ExitOK
}

// scanCorpus prints the lines of one target and adds it to the totals.
func scanCorpus(out io.Writer, p string, index pointerIndex, read readFunc, t *btTotals) {
	if !isDirectory(p) {
		fmt.Fprintf(out, "INFO: corpus not found (absent-input): %s\n", p)
		t.absent++
		return
	}
	files := blockFiles(p)
	if len(files) == 0 {
		fmt.Fprintf(out, "INFO: corpus exists, no block files (empty-input): %s\n", p)
		return
	}
	anyTagged := false
	for _, bf := range files {
		data, err := read(bf)
		if err != nil {
			fmt.Fprintf(out, "WARN: block file unreadable, marker scan skipped: %s\n", bf)
			t.markUnreadable(bf)
			continue
		}
		marks := markerLines(data)
		if len(marks) == 0 {
			continue
		}
		anyTagged = true
		t.tagged++
		if !index.indexes(bf, marks) {
			fmt.Fprintf(out, "WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: %s:%d\n", bf, marks[0])
			t.unindexed++
		}
	}
	if !anyTagged {
		fmt.Fprintf(out, "INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): %s\n", p)
	}
}

// blockFiles is `find "$p" -type f -name '*.md' | block_file_filter | sort`: the canonical block files of a
// target, bytewise sorted. A target that is a symbolic link to a directory is traversed (the script's find
// listed the link alone); the paths keep the target's own spelling.
func blockFiles(p string) []string {
	root := p
	if st, err := os.Lstat(p); err == nil && st.Mode()&os.ModeSymlink != 0 && root[len(root)-1] != '/' {
		root += "/" // find reads `p/` through the link
	}
	files, err := kit.FilterBlockFiles(findMarkdownFiles(root), false, "")
	if err != nil { // no markdown file, or none is a block: both are "no block files" here
		return nil
	}
	sort.Strings(files)
	return files
}

// writeBreakthroughsSummary prints the closing lines.
func writeBreakthroughsSummary(out io.Writer, t btTotals) {
	fmt.Fprintf(out, "\nSummary: %d tagged breakthrough(s) across corpora · %d unindexed · %d drifted · %d skipped-unreadable.\n",
		t.tagged, t.unindexed, t.drift, t.unreadable)
	if t.absent > 0 {
		fmt.Fprintf(out, "INFO: %d target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n", t.absent)
	}
	if t.skipped > 0 {
		fmt.Fprintf(out, "WARN: %d target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: %s\n", t.skipped, t.skippedNames)
	}
	if t.unindexed == 0 && t.drift == 0 && t.skipped == 0 && t.unreadable == 0 {
		fmt.Fprintf(out, "Ledger consistent — all tagged breakthroughs indexed, no drift.\n")
	}
	if t.unindexed > 0 {
		fmt.Fprintf(out, "For each unindexed breakthrough: add a row to BREAKTHROUGHS.md with the block path:line pointer.\n")
	}
	if t.drift > 0 {
		fmt.Fprintf(out, "For each drifted row: verify the block still exists and carries the **Breakthrough:** field; update or remove the ledger row.\n")
	}
}
