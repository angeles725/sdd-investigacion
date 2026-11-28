package reconcile

import (
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/issuesdue"
)

var reUntrackedRow = regexp.MustCompile(`^untracked: row (\S+) — `)

// TestProbeAgreesWithTheCommand is the equivalence behind `rsdd status show --next` answering its cached probes in
// process (kit issue #2644): for every case of the table that is one retro audited against an --issues-cache (no
// closed cache, no gh, no --all), core/issuesdue.Probe gives the verdict the command gives. A command that exits 1
// is a Failure with the very stderr; an exit 0 is the same untracked rows in the same order (and the out-of-scope
// finding, when the command reports one).
func TestProbeAgreesWithTheCommand(t *testing.T) {
	n := 0
	for _, c := range allCases() {
		if c.live || c.all || c.raw || c.useClosed || c.noRetro && c.retroArg == "" {
			continue
		}
		n++
		b := mkBox(t, c)
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			want := runGo(t, b)
			env := b.environ()
			got := issuesdue.Probe(issuesdue.Query{Retro: b.arg, Cache: b.cache, Toolbelt: filepath.Join(b.root, "research-sdd", "toolbelt"),
				Cwd: b.cwd, Env: func(k string) string { return env[k] }})
			norm := func(s string) string { return strings.ReplaceAll(s, b.root, "@BOX@") }
			if want.RC != 0 {
				if norm(got.Failure)+"\n" != want.Stderr || got.OutOfScope != "" || len(got.Untracked) != 0 {
					t.Errorf("command exits %d with stderr %q; Probe = %+v", want.RC, want.Stderr, got)
				}
				return
			}
			var rows []string
			for _, l := range strings.Split(want.Stdout, "\n") {
				if m := reUntrackedRow.FindStringSubmatch(l); m != nil {
					rows = append(rows, m[1])
				}
			}
			if strings.Join(rows, " ") != strings.Join(got.Untracked, " ") || got.Failure != "" {
				t.Errorf("command reports untracked rows %q; Probe = %+v", rows, got)
			}
			oos := ""
			for _, l := range strings.Split(want.Stderr, "\n") {
				if strings.HasPrefix(l, "out-of-scope-marker:") {
					oos = l
				}
			}
			if norm(got.OutOfScope) != oos {
				t.Errorf("command out-of-scope line %q; Probe = %q", oos, got.OutOfScope)
			}
		})
	}
	if n < 50 {
		t.Errorf("only %d cache-only cases are compared: the table or the filter drifted", n)
	}
}
