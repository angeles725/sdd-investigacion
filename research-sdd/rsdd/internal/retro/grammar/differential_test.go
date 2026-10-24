package grammar

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Differential tests: the REAL lib/retro-grammar.sh (testdata/diff-driver.sh) and the Go port must agree byte for
// byte on stdout, stderr and the return code for every input. Bash runs under LC_ALL=C, the locale the port
// implements (doc.go). The driver fails loudly: exit 97 is a broken harness and a t.Fatal, never a skip or a pass.
// Only a missing bash binary skips, with a message saying the port is NOT proven in that run.

const (
	toolbeltRel = "../../../../toolbelt"
	harnessRC   = 97
)

// driverSlots caps concurrent bash drivers: the parallel mode subtests share a loaded host.
var driverSlots = make(chan struct{}, 4)

type bashOut struct {
	stdout, stderr string
	rc             int
}

// bashBatch runs one driver mode over inputs (one per line on stdin) and returns one result per input.
func bashBatch(t *testing.T, mode string, inputs []string) []bashOut {
	t.Helper()
	driverSlots <- struct{}{}
	defer func() { <-driverSlots }() // released on t.Fatal/t.Skip too (both unwind through defers)
	so := runDriver(t, mode, strings.Join(inputs, "\n")+"\n")
	out := make([]bashOut, 0, len(inputs))
	for len(so) > 0 {
		var r bashOut
		var no, ne int
		nl := bytes.IndexByte(so, '\n')
		if nl < 0 {
			t.Fatalf("differential %s: truncated frame header %q", mode, so)
		}
		if _, err := fmt.Sscanf(string(so[:nl]), "%d %d %d", &r.rc, &no, &ne); err != nil {
			t.Fatalf("differential %s: bad frame header %q: %v", mode, so[:nl], err)
		}
		body := so[nl+1:]
		if len(body) < no+ne {
			t.Fatalf("differential %s: frame shorter than its header says", mode)
		}
		r.stdout, r.stderr = string(body[:no]), string(body[no:no+ne])
		out = append(out, r)
		so = body[no+ne:]
	}
	if len(out) != len(inputs) {
		t.Fatalf("differential %s: %d frames for %d inputs", mode, len(out), len(inputs))
	}
	return out
}

func runDriver(t *testing.T, mode, stdin string) []byte {
	t.Helper()
	bin, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found in PATH; the Go port is NOT proven against lib/retro-grammar.sh in this run")
	}
	tb, err := filepath.Abs(toolbeltRel)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(tb, "lib", "retro-grammar.sh")); err != nil {
		t.Fatalf("differential: toolbelt not found at %s (%v); a moved package must update toolbeltRel, not skip", tb, err)
	}
	script, _ := filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	cmd := exec.Command(bin, script, tb, mode)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C"}
	cmd.Stdin = strings.NewReader(stdin)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("differential: cannot run the driver: %v", err)
		}
		t.Fatalf("differential: driver %s exited %d (harness failure): %s", mode, ee.ExitCode(), se.String())
	}
	if se.Len() != 0 {
		t.Fatalf("differential: driver %s wrote outside its frames: %s", mode, se.String())
	}
	return so.Bytes()
}

// rcOf is the shell return code of a Go predicate.
func rcOf(ok bool) int {
	if ok {
		return 0
	}
	return 1
}

// joinLines renders records the way awk prints them: each one "\n"-terminated.
func joinLines(xs []string) string {
	var b strings.Builder
	for _, x := range xs {
		b.WriteString(x)
		b.WriteByte('\n')
	}
	return b.String()
}

// fileModes maps a driver file mode to the Go rendering of the same call. Every mode reads through Read, so an
// absent or unreadable path takes the typed-error branch the mode documents.
var fileModes = map[string]func(path string) bashOut{
	"defenced": func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		return bashOut{stdout: joinLines(d.Lines), stderr: d.FenceWarning()}
	},
	// delta_info: bash prints a zero line for an absent file (rc 0, the silent zero Go reports as ErrAbsentInput)
	// and a typed stderr line plus the zero line, rc 1, for an unreadable one.
	"delta": func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrAbsentInput):
			return bashOut{stdout: DeltaInfo{Form: FormNone}.Line()}
		case err != nil:
			return bashOut{stdout: DeltaInfo{Form: FormNone}.Line(), rc: 1,
				stderr: "retro-grammar: cannot read " + p + " (unreadable) — delta count is UNKNOWN, not zero\n"}
		}
		return bashOut{stdout: Delta(d).Line(), stderr: d.FenceWarning()}
	},
	"canon": func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		h, ok := CanonicalHeading(d)
		if !ok {
			return bashOut{}
		}
		return bashOut{stdout: h + "\n"}
	},
	"unrec":     readThen(func(d *Doc) []string { return UnrecHeadings(d) }),
	"entryrows": readThen(func(d *Doc) []string { return rowLines(EntryRows(d)) }),
	// entry_ids prints nothing for no entries; its read failure is entry_rows' rc 1.
	"entryids": readThen(EntryIDs),
	// entry_warn always returns 0; on an unreadable file only its delta_info call speaks.
	"entrywarn": func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrUnreadable):
			return bashOut{stderr: "retro-grammar: cannot read " + p + " (unreadable) — delta count is UNKNOWN, not zero\n"}
		case err != nil:
			return bashOut{}
		}
		return bashOut{stdout: EntryWarn(d)}
	},
}

// rowLines renders rows as their bash records, without the trailing newline joinLines adds back.
func rowLines(rows []Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = strings.TrimSuffix(r.Line(), "\n")
	}
	return out
}

// readThen renders a mode that prints one line per result and returns 1, silently, on a failed read.
func readThen(f func(*Doc) []string) func(string) bashOut {
	return func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		return bashOut{stdout: joinLines(f(d))}
	}
}

// checkFileModes runs every file mode over paths on both sides and reports each disagreement.
// With requireSignal, a mode on which bash gives one outcome for every input fails: that corpus would prove nothing.
func checkFileModes(t *testing.T, label string, paths []string, requireSignal bool) {
	t.Helper()
	modes := make([]string, 0, len(fileModes))
	for m := range fileModes {
		modes = append(modes, m)
	}
	sort.Strings(modes)
	for _, mode := range modes {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			bash := bashBatch(t, mode, paths)
			distinct := map[bashOut]bool{}
			bad := 0
			for i, p := range paths {
				distinct[bash[i]] = true
				if got := fileModes[mode](p); got != bash[i] {
					if bad++; bad <= 5 {
						t.Errorf("%s %s %s:\n  go=%+v\nbash=%+v", label, mode, p, got, bash[i])
					}
				}
			}
			if bad > 5 {
				t.Errorf("%s %s: %d more disagreements not shown", label, mode, bad-5)
			}
			if requireSignal && len(distinct) < 2 {
				t.Errorf("%s %s: bash gave one outcome for all %d inputs: the corpus is vacuous for this mode", label, mode, len(paths))
			}
			t.Logf("%s %s: %d inputs, %d distinct bash outcomes", label, mode, len(paths), len(distinct))
		})
	}
}

// fixturePaths lists every markdown fixture of the kit's test suites (the frozen retro corpora live there).
func fixturePaths(t *testing.T) []string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join(toolbeltRel, "tests", "fixtures"))
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	err = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(p, ".md") {
			out = append(out, p)
		}
		return err
	})
	if err != nil || len(out) == 0 {
		t.Fatalf("fixtures under %s: %d files, %v", root, len(out), err)
	}
	return out
}

func TestDifferentialFixtures(t *testing.T) {
	paths := fixturePaths(t)
	checkFileModes(t, "fixture", paths, false)
	t.Logf("fixtures: %d files x %d modes", len(paths), len(fileModes))
}

func TestDifferentialGenerated(t *testing.T) {
	dir := t.TempDir()
	docs := generatedDocs(200)
	paths := make([]string, len(docs))
	for i, src := range docs {
		paths[i] = filepath.Join(dir, "g"+strconv.Itoa(i)+".md")
		if err := os.WriteFile(paths[i], []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	checkFileModes(t, "generated", paths, true)
}

func TestDifferentialAbsentAndEmpty(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty.md")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	paths := []string{"", filepath.Join(dir, "missing.md"), dir, empty}
	if os.Geteuid() != 0 { // root reads a mode-000 file: the unreadable premise is then unavailable
		locked := filepath.Join(dir, "locked.md")
		if err := os.WriteFile(locked, []byte("## Proposed kit deltas\n"), 0); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, locked)
	}
	checkFileModes(t, "edge", paths, true)
}
