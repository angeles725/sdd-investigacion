package archtest

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const (
	moveHintNew  = " If it is a listed file that moved, change the path on its line instead (same count and kind): that is not a new entry."
	moveHintGone = ", or, if the file moved, change the path on it (same count and kind, list kept sorted):\n"
)

// A pure move of a listed file is not a new entry: the line keeps its count and kind and takes the new path. Both
// messages a stale path produces say so, because following them without it would force a split inside a move.
func TestMovedFileKeepsItsLineUnderTheNewPath(t *testing.T) {
	files := map[string]string{"core/statecheck/state.go": gen(500), "ok.go": gen(1)}
	r := check(t, files, debtLine("verify/state.go", 500, "legacy"))
	want := []string{
		"core/statecheck/state.go: 500 lines, over 400. A new file over 400 lines cannot be listed: split it." + moveHintNew,
		"verify/state.go: listed but not a production Go file in this tree. Delete this line from modularity-debt.txt" + moveHintGone +
			"verify/state.go 500 legacy " + reason,
	}
	if !sameStrings(r.Violations, want) {
		t.Errorf("stale path: violations = %q, want %q", r.Violations, want)
	}
	if r := check(t, files, debtLine("core/statecheck/state.go", 500, "legacy")); len(r.Violations) != 0 {
		t.Errorf("path changed on the existing line: violations = %q, want none", r.Violations)
	}
}

// A count over the hard limit is exact; a count at or under it keeps its slack.
func TestCountOverTheHardLimitIsExact(t *testing.T) {
	const why = " " + reason
	shrunk := func(n, recorded int, line string) string {
		return "a.go: " + strconv.Itoa(n) + " lines, below its recorded " + strconv.Itoa(recorded) +
			". A count over 400 is exact, so the file cannot grow back unseen: change its line in modularity-debt.txt to:\n" + line + why
	}
	cases := []struct {
		name            string
		lines, recorded int
		kind            string
		want            []string
		lowerable       int
	}{
		{"recorded 401, still 401", 401, 401, "legacy", nil, 0},
		{"recorded 401, now 400", 400, 401, "legacy", []string{shrunk(400, 401, "a.go 400 legacy")}, 0},
		{"recorded 401, now 201", 201, 401, "legacy", []string{shrunk(201, 401, "a.go 201 legacy")}, 0},
		{"recorded 401, now 200: the line goes", 200, 401, "legacy",
			[]string{"a.go: 200 lines, no longer over 200. Delete this line from modularity-debt.txt:\na.go 401 legacy" + why}, 0},
		{"recorded 400 keeps its slack", 399, 400, "legacy", nil, 1},
		{"accepted above the limit whose file shrank is lowered, not split", 300, 450, "accepted",
			[]string{shrunk(300, 450, "a.go 300 accepted")}, 0},
		{"accepted above the limit whose file is small is deleted, not split", 150, 450, "accepted",
			[]string{"a.go: 150 lines, no longer over 200. Delete this line from modularity-debt.txt:\na.go 450 accepted" + why}, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := check(t, map[string]string{"a.go": gen(c.lines)}, debtLine("a.go", c.recorded, c.kind))
			if !sameStrings(r.Violations, c.want) || r.Lowerable != c.lowerable {
				t.Errorf("violations = %q lowerable = %d, want %q and %d", r.Violations, r.Lowerable, c.want, c.lowerable)
			}
		})
	}
}

// The scenario the exact count closes: a file recorded at 1010 shrinks to 450 and its line is left alone; without
// the rule a later change could take it back to 1000 lines with the test green.
func TestFileOverTheHardLimitCannotGrowBackUnseen(t *testing.T) {
	stale := debtLine("m.go", 1010, "legacy")
	for _, n := range []int{450, 1000} {
		r := check(t, map[string]string{"m.go": gen(n)}, stale)
		if len(r.Violations) != 1 || !strings.HasSuffix(r.Violations[0], "\nm.go "+strconv.Itoa(n)+" legacy "+reason) {
			t.Errorf("%d lines under a stale 1010: violations = %q, want the lowered line", n, r.Violations)
		}
	}
	r := check(t, map[string]string{"m.go": gen(451)}, debtLine("m.go", 450, "legacy"))
	want := "m.go: grew from 450 to 451 lines and is over 400. A file over 400 lines may not grow: split it first."
	if len(r.Violations) != 1 || r.Violations[0] != want {
		t.Errorf("one line over the lowered count: violations = %q, want %q", r.Violations, want)
	}
}

// A file whose line is malformed is a listed file with a bad line: the line's own message is the only one, never
// "not listed" or "a new file over 400 lines cannot be listed".
func TestMalformedLineDoesNotReadAsAnUnlistedFile(t *testing.T) {
	for name, tt := range map[string]struct {
		lines int
		line  string
		want  string
	}{
		"over the hard limit, short reason": {500, "a.go 500 legacy short", "reason is shorter than 10 characters"},
		"placeholder pasted as printed":     {250, "a.go 250 accepted <reason>", "replace <reason> with the reason this file is accepted"},
		"three fields":                      {250, "a.go 250 accepted", "malformed line, fewer than four fields"},
		"bad count":                         {250, "a.go many accepted " + reason, `"many" is not a positive line count`},
	} {
		t.Run(name, func(t *testing.T) {
			r := check(t, map[string]string{"a.go": gen(tt.lines), "ok.go": gen(1)}, tt.line+"\n")
			if want := badMsg(1, tt.want); len(r.Violations) != 1 || r.Violations[0] != want {
				t.Errorf("violations = %q, want only %q", r.Violations, want)
			}
		})
	}
	// Another file is still reported: only the path the bad line names is spared.
	r := check(t, map[string]string{"a.go": gen(250), "b.go": gen(250)}, "a.go 250 accepted\n")
	if len(r.Violations) != 2 || !strings.HasPrefix(r.Violations[0], "b.go: 250 lines, over 200 and not listed.") {
		t.Errorf("violations = %q, want b.go reported as not listed and the bad line", r.Violations)
	}
}

// A directory that cannot be read is an error, never a tree with fewer files.
func TestUnreadableDirectoryIsAnError(t *testing.T) {
	root, dp := tree(t, map[string]string{"sub/a.go": gen(300), "ok.go": gen(1)}, "")
	sub := filepath.Join(root, "sub")
	if err := os.Chmod(sub, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(sub, 0o755) })
	if _, err := os.ReadDir(sub); err == nil {
		t.Skip("this user can read a directory with no permission bits")
	}
	_, err := CheckFileSizes(root, dp)
	if err == nil || !strings.HasPrefix(err.Error(), "archtest: cannot read "+sub+": ") {
		t.Errorf("err = %v, want it to name the directory that could not be read", err)
	}
}
