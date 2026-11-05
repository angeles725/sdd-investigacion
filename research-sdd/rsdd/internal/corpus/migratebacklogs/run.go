package migratebacklogs

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"
)

// Options is one run. Args is the argument list after the command name: exactly one corpus directory.
type Options struct {
	Args     []string
	Out, Err io.Writer
	// FS is the corpus tree. nil reads the target directory from the disk; a test hands in a tree whose reads
	// fail to reach the degraded paths without depending on file permissions.
	FS fs.FS
}

const usage = "usage: rsdd corpus migrate-backlogs <corpus-dir>"

// session is the state of one run: where it reads and the counters of the closing line.
type session struct {
	o                        Options
	fsys                     fs.FS
	target                   string
	files, proposals, manual int
}

// Run proposes the §8b migration of a corpus. It only reads the target: every transform is computed in memory
// and printed as a unified diff. Exit: 0 inspected (proposals are findings, not failures) · 1 operational
// failure, with a typed `degraded:` line on stderr · 2 bad arguments or a target that is not a directory.
func Run(o Options) int {
	if len(o.Args) != 1 || o.Args[0] == "" {
		fmt.Fprintln(o.Err, usage)
		return 2
	}
	target := o.Args[0]
	if fi, err := os.Stat(target); err != nil || !fi.IsDir() {
		fmt.Fprintf(o.Err, "absent-input: %s is not a directory\n", target)
		return 2
	}
	s := &session{o: o, fsys: o.FS, target: target}
	if s.fsys == nil {
		s.fsys = os.DirFS(target)
	}
	inv := scan(s.fsys)
	switch {
	case inv.rootFail != nil:
		fmt.Fprintf(o.Err, "degraded: migrate-backlogs: %s is not readable/traversable (%v) — cannot scan\n", target, inv.rootFail)
		return 1
	case inv.scanErr != nil:
		fmt.Fprintf(o.Err, "degraded: migrate-backlogs: scanning %s failed (%v) — cannot tell absent from unreadable\n", target, inv.scanErr)
		return 1
	}
	if len(inv.states) == 0 {
		fmt.Fprintf(o.Out, "absent-input: no RESEARCH-STATE*.md under %s — nothing to migrate\n", target)
	} else if !s.migrateAll(inv) {
		return 1
	}
	fmt.Fprintln(o.Out, summaryLine(s.files, s.proposals, s.manual))
	return 0
}

// migrateAll proposes for every state file, then for every FOCUSES.md. It stops at the first file it cannot read.
func (s *session) migrateAll(inv inventory) bool {
	for _, rel := range inv.states {
		label := labelOf(rel)
		skip := label != "(root)" && s.isDocumentFocus(path.Join(path.Dir(rel), "FOCUSES.md"), label)
		s.files++
		if !s.propose(label, rel, func(l []line) ([]line, []manualItem) { return migrateBacklog(l, skip) }) {
			return false
		}
	}
	for _, rel := range inv.focuses {
		s.files++
		if !s.propose("FOCUSES", rel, migrateFocuses) {
			return false
		}
	}
	return true
}

// isDocumentFocus reads the FOCUSES.md next to a state file. A FOCUSES.md that cannot be read is not a
// registry that says `document`: the file gets its backlog proposal, and the FOCUSES pass reports the read error.
func (s *session) isDocumentFocus(rel, label string) bool {
	data, err := fs.ReadFile(s.fsys, rel)
	return err == nil && isDocumentFocus(string(data), label)
}

// propose prints the diff and the MANUAL lines of one file. It returns false after a degraded line.
func (s *session) propose(label, rel string, transform func([]line) ([]line, []manualItem)) bool {
	data, err := fs.ReadFile(s.fsys, rel)
	if err != nil {
		fmt.Fprintf(s.o.Err, "degraded: migrate-backlogs: cannot read %s — proposal not computed\n", strings.TrimRight(s.target, "/")+"/"+rel)
		return false
	}
	if len(data) == 0 {
		fmt.Fprintf(s.o.Out, "empty-input: %s (%s is empty)\n", label, rel)
		return true
	}
	oldL := splitLines(string(data))
	newL, items := transform(oldL)
	diff := unifiedDiff(rel, oldL, newL)
	if diff != "" {
		s.proposals++
		fmt.Fprintf(s.o.Out, "PROPOSE %s %s\n%s", label, rel, diff)
	}
	lines := manualLines(label, items)
	for _, m := range lines {
		fmt.Fprintln(s.o.Out, m)
	}
	s.manual += len(lines)
	if diff == "" && len(lines) == 0 {
		fmt.Fprintf(s.o.Out, "ok %s: nothing to migrate\n", label)
	}
	return true
}
